// CefApp for every process. The browser half forwards to OEEngine; the
// renderer half injects profile user scripts at V8 context creation. Media
// and audible state come from the fork (CefMediaController, OEMediaSession.mm).

#import "OEInternal.h"
#import "OEOpenWorld.h"
#include "include/cef_open_world.h"

#include <map>
#include <algorithm>
#include <set>
#include <mutex>

#include "include/cef_parser.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

const char kOEMsgScriptsUpdate[] = "oe.scripts.update";
const char kOEMsgScriptsPatch[] = "oe.scripts.patch";
const char kOEExtraScripts[] = "oe.scripts";
const char kOEMsgUserStyleSheet[] = "oe.userStyleSheet";
const char kOEExtraUserStyles[] = "oe.userStyles";

namespace {

// Glob match where '*' matches any run of characters.
bool GlobMatch(const char* p, const char* s) {
  const char* star = nullptr;
  const char* resume = nullptr;
  while (*s) {
    if (*p == '*') {
      star = p++;
      resume = s;
    } else if (*p == *s) {
      ++p;
      ++s;
    } else if (star) {
      p = star + 1;
      s = ++resume;
    } else {
      return false;
    }
  }
  while (*p == '*') {
    ++p;
  }
  return *p == 0;
}

struct UrlParts {
  std::string scheme, host, path;
};

bool SplitUrl(const std::string& url, UrlParts& out, bool is_pattern) {
  size_t sep = url.find("://");
  if (sep == std::string::npos) {
    return false;
  }
  out.scheme = url.substr(0, sep);
  size_t host_start = sep + 3;
  size_t path_start = url.find('/', host_start);
  std::string authority = url.substr(
      host_start, path_start == std::string::npos ? std::string::npos
                                                  : path_start - host_start);
  if (!is_pattern) {
    size_t at = authority.rfind('@');
    if (at != std::string::npos) {
      authority = authority.substr(at + 1);
    }
    if (authority.empty() || authority[0] != '[') {
      size_t colon = authority.find(':');
      if (colon != std::string::npos) {
        authority = authority.substr(0, colon);
      }
    }
  }
  out.host = authority;
  out.path = path_start == std::string::npos ? "/" : url.substr(path_start);
  return true;
}

}  // namespace

// Chrome match patterns: "<all_urls>", "*://*.example.com/*",
// "https://example.com/path*". The host "*.example.com" also matches
// "example.com".
bool OEMatchesPattern(const std::string& pattern, const std::string& url) {
  UrlParts u;
  if (!SplitUrl(url, u, false)) {
    return false;
  }
  if (pattern == "<all_urls>") {
    return u.scheme == "http" || u.scheme == "https" || u.scheme == "file";
  }
  UrlParts p;
  if (!SplitUrl(pattern, p, true)) {
    return false;
  }
  if (p.scheme == "*") {
    if (u.scheme != "http" && u.scheme != "https") {
      return false;
    }
  } else if (p.scheme != u.scheme) {
    return false;
  }
  if (p.host != "*") {
    if (p.host.rfind("*.", 0) == 0) {
      std::string base = p.host.substr(2);
      bool same = u.host == base;
      bool sub = u.host.size() > base.size() &&
                 u.host.compare(u.host.size() - base.size(), base.size(),
                                base) == 0 &&
                 u.host[u.host.size() - base.size() - 1] == '.';
      if (!same && !sub) {
        return false;
      }
    } else if (p.host != u.host) {
      return false;
    }
  }
  return GlobMatch(p.path.c_str(), u.path.c_str());
}

namespace {

struct RendererScript {
  std::string identifier;
  std::string source;
  bool css = false;
  bool open_world = false;
  bool document_end = false;
  bool main_frame_only = true;
  std::vector<std::string> patterns;
};

class OEApp : public CefApp,
              public CefBrowserProcessHandler,
              public CefRenderProcessHandler {
 public:
  explicit OEApp(std::vector<std::string> switches)
      : switches_(std::move(switches)) {}

  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override {
    return this;
  }
  CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override {
    return this;
  }

  void OnBeforeCommandLineProcessing(
      const CefString& process_type,
      CefRefPtr<CefCommandLine> command_line) override {
    if (!process_type.empty()) {
      return;
    }
    // Non-official Chromium builds (our fork's dev build) apply the
    // field-trial testing config, which breaks child-process launch on
    // macOS 27.2 beta (docs/followups.md, lead 2026-10-25). Harmless for the
    // official CDN build. Remove once dev.args.gn sets
    // disable_fieldtrial_testing_config=true.
    command_line->AppendSwitch("disable-field-trial-config");
    for (const std::string& s : switches_) {
      std::string sw = s.rfind("--", 0) == 0 ? s.substr(2) : s;
      size_t eq = sw.find('=');
      if (eq == std::string::npos) {
        command_line->AppendSwitch(sw);
      } else {
        command_line->AppendSwitchWithValue(sw.substr(0, eq),
                                            sw.substr(eq + 1));
      }
    }
    // CEF retains the initial Profile as its process-wide request context.
    // Chromium's macOS startup otherwise chooses Local State's last_used
    // Profile (GetStartupProfilePath), which would pin a named Profile and
    // make Open's Default wrapper point at that Profile after relaunch.
    // Open's global context is always Default; named Profiles load lazily.
    command_line->AppendSwitchWithValue("profile-directory", "Default");
    // Chromium features Open turns on, added to any --enable-features list:
    // ExtensionsPinnedByDefault pins a new install's action (extensions UI
    // plan Q4; the profile pref extensions.pinned_by_default defaults on).
    // WebContentsDiscard: tab sleeping discards pages in place
    // (docs/plans/memory-fork.md §10; off on desktop by default, and
    // WebContents::Discard is NOTREACHED() without it).
    // ImprovedStartupBestEffortDelay: Chrome holds BEST_EFFORT tasks until
    // startup is complete. Without this feature only a visible page that
    // reaches loaded-idle completes startup, so a launch that shows no web
    // page (empty Space, Welcome, chrome:// page) waited for the 3-minute
    // failsafe. With it, startup also completes 5 s after launch when no
    // visible tab appears, and (with the param) when the visible tab's load
    // times out (docs/engine-fork.md "Startup complete").
    std::string features = command_line->GetSwitchValue("enable-features");
    for (const char* feature :
         {"ExtensionsPinnedByDefault", "WebContentsDiscard",
          "ImprovedStartupBestEffortDelay:"
          "StartupDelayStopOnLoadingTimedOut/true"}) {
      features += features.empty() ? feature : std::string(",") + feature;
    }
    command_line->AppendSwitchWithValue("enable-features", features);
    // Chromium services Open does not use (memory-fork §10; each string was
    // read from its BASE_FEATURE in this Chromium tree): optimization guide
    // hints, models and page-content extraction, the segmentation platform,
    // Cast discovery (MediaRouter: Cast is out of v1, page-platform §4.12, EP-12),
    // and the translate ranker (manual translate stays).
    std::string disabled = command_line->GetSwitchValue("disable-features");
    for (const char* feature :
         {"OptimizationHints", "OptimizationTargetPrediction",
          "OptimizationGuidePageContentExtraction",
          "OptimizationGuideModelExecution", "SegmentationPlatform",
          "SegmentationPlatformUkmEngine", "MediaRouter",
          "TranslateRankerQuery", "TranslateRankerEnforcement"}) {
      disabled += disabled.empty() ? feature : std::string(",") + feature;
    }
    command_line->AppendSwitchWithValue("disable-features", disabled);
    // Open has no on-device AI. Without this, Chrome launches the on-device
    // model service about 3 minutes after every launch whose stored
    // performance class is missing or from another version, only to measure
    // the GPU (PerformanceClassifier::ScheduleEvaluation; no feature gates
    // it). A fixed class skips the measurement: 2 is kVeryLow, which makes
    // no on-device model eligible.
    if (!command_line->HasSwitch("optimization-guide-performance-class")) {
      command_line->AppendSwitchWithValue(
          "optimization-guide-performance-class", "2");
    }
    // Chromium's RAM-scaled renderer limit governs, except on small Macs.
    const unsigned long long kSmallMac = 8ull * 1024 * 1024 * 1024;
    if (NSProcessInfo.processInfo.physicalMemory <= kSmallMac &&
        !command_line->HasSwitch("renderer-process-limit")) {
      command_line->AppendSwitchWithValue("renderer-process-limit", "32");
    }
  }

  // CefBrowserProcessHandler
  void OnContextInitialized() override {
    [[OEEngine shared] oe_contextInitialized];
  }
  CefRefPtr<CefClient> GetDefaultClient() override {
    return [[OEEngine shared] oe_defaultClient];
  }

  // CefRenderProcessHandler
  void OnBrowserCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefDictionaryValue> extra_info) override {
    if (extra_info && extra_info->HasKey(kOEExtraScripts)) {
      SetScripts(browser->GetIdentifier(),
                 extra_info->GetList(kOEExtraScripts));
    }
    // User style sheets for every main-frame document of this browser in this
    // process (fork API cef_open_page.h, CEF patch 0601).
    CefRefPtr<CefDictionaryValue> styles =
        extra_info ? extra_info->GetDictionary(kOEExtraUserStyles) : nullptr;
    CefDictionaryValue::KeyList keys;
    if (styles && styles->GetKeys(keys)) {
      for (const CefString& key : keys) {
        CefSetOpenUserStyleSheet(browser, key, styles->GetString(key));
      }
    }
  }

  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    std::lock_guard<std::mutex> lock(mutex_);
    scripts_.erase(browser->GetIdentifier());
    OEOpenWorldBrowserDestroyed(browser->GetIdentifier());
    CefForgetOpenUserStyleSheets(browser);
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    if (!CefIsPageScriptContext(context)) return;
    std::string url = frame->GetURL().ToString();
    CefRefPtr<CefV8Value> retval;
    CefRefPtr<CefV8Exception> exception;
    std::vector<RendererScript> scripts;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = scripts_.find(browser->GetIdentifier());
      if (it != scripts_.end()) {
        scripts = it->second;
      }
    }
    for (const RendererScript& s : scripts) {
      if ((s.main_frame_only || s.open_world) && !frame->IsMain()) {
        continue;
      }
      bool match = false;
      for (const std::string& p : s.patterns) {
        if (OEMatchesPattern(p, url)) {
          match = true;
          break;
        }
      }
      if (!match) {
        continue;
      }
      std::string code = s.css ? CssWrapper(s.source) : s.source;
      if (s.document_end && !s.open_world) {
        code =
            "document.addEventListener('DOMContentLoaded',()=>{" + code +
            "\n},{once:true});";
      }
      auto target = s.open_world ? OEOpenWorldContext(browser, frame) : context;
      if (target) target->Eval(code, "openengine://userscript", 1, retval, exception);
    }
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    if (source_process != PID_BROWSER) return false;
    if (OEOpenWorldRendererMessage(browser, frame, message)) return true;
    if (message->GetName() == kOEMsgUserStyleSheet) {
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      CefSetOpenUserStyleSheet(browser, args->GetString(0), args->GetString(1));
      return true;
    }
    if (message->GetName() == kOEMsgScriptsPatch) {
      auto args = message->GetArgumentList();
      PatchScripts(browser->GetIdentifier(), args->GetList(0), args->GetList(1));
      return true;
    }
    if (message->GetName() == kOEMsgScriptsUpdate) {
      SetScripts(browser->GetIdentifier(),
                 message->GetArgumentList()->GetList(0));
      return true;
    }
    return false;
  }

 private:
  static std::string JsonString(const std::string& s) {
    CefRefPtr<CefValue> v = CefValue::Create();
    v->SetString(s);
    return CefWriteJSON(v, JSON_WRITER_DEFAULT).ToString();
  }

  static std::string CssWrapper(const std::string& css) {
    return "(function(css){const add=()=>{const s=document.createElement("
           "'style');s.dataset.openengine='';s.textContent=css;(document.head||"
           "document.documentElement).appendChild(s)};if(document."
           "documentElement){add()}else{new MutationObserver((m,o)=>{if("
           "document.documentElement){o.disconnect();add()}}).observe("
           "document,{childList:true})}})(" +
           JsonString(css) + ");";
  }

  static std::vector<RendererScript> ReadScripts(CefRefPtr<CefListValue> list) {
    std::vector<RendererScript> out;
    for (size_t i = 0; list && i < list->GetSize(); ++i) {
      CefRefPtr<CefDictionaryValue> d = list->GetDictionary(i);
      RendererScript s;
      s.identifier = d->GetString("identifier");
      s.source = d->GetString("source");
      s.css = d->GetBool("css");
      s.open_world = d->GetBool("openWorld");
      s.document_end = d->GetBool("end");
      s.main_frame_only = d->GetBool("mainFrameOnly");
      CefRefPtr<CefListValue> pats = d->GetList("matches");
      for (size_t j = 0; pats && j < pats->GetSize(); ++j) {
        s.patterns.push_back(pats->GetString(j));
      }
      out.push_back(std::move(s));
    }
    return out;
  }

  void SetScripts(int browser_id, CefRefPtr<CefListValue> list) {
    auto out = ReadScripts(list);
    std::lock_guard<std::mutex> lock(mutex_);
    scripts_[browser_id] = std::move(out);
  }

  void PatchScripts(int browser_id, CefRefPtr<CefListValue> removed,
                    CefRefPtr<CefListValue> added) {
    std::set<std::string> ids;
    for (size_t i = 0; removed && i < removed->GetSize(); ++i) {
      ids.insert(removed->GetString(i));
    }
    auto additions = ReadScripts(added);
    for (const auto& script : additions) ids.insert(script.identifier);
    std::lock_guard<std::mutex> lock(mutex_);
    auto& current = scripts_[browser_id];
    current.erase(std::remove_if(current.begin(), current.end(),
        [&](const RendererScript& script) { return ids.count(script.identifier) != 0; }), current.end());
    for (auto& script : additions) {
      // Duplicate added IDs follow the same last-addition-wins order as native.
      current.erase(std::remove_if(current.begin(), current.end(),
          [&](const RendererScript& old) { return old.identifier == script.identifier; }), current.end());
      current.push_back(std::move(script));
    }
  }

  std::vector<std::string> switches_;
  std::mutex mutex_;
  std::map<int, std::vector<RendererScript>> scripts_;

  IMPLEMENT_REFCOUNTING(OEApp);
};

}  // namespace

CefRefPtr<CefApp> OECreateApp(NSArray<NSString*>* extraSwitches) {
  std::vector<std::string> switches;
  for (NSString* s in extraSwitches) {
    if (const char* utf8 = s.UTF8String) switches.push_back(utf8);
  }
  return new OEApp(std::move(switches));
}

int OEHelperMain(int argc, char* argv[]) {
#if defined(CEF_USE_SANDBOX)
  CefScopedSandboxContext sandbox_context;
  if (!sandbox_context.Initialize(argc, argv)) {
    return 1;
  }
#endif
  CefScopedLibraryLoader library_loader;
  if (!library_loader.LoadInHelper()) {
    return 1;
  }
  CefMainArgs main_args(argc, argv);
  return CefExecuteProcess(main_args, OECreateApp(nil), nullptr);
}
