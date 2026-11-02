// CefApp for every process. The browser half forwards to OEEngine; the
// renderer half injects profile user scripts at V8 context creation and
// reports media playback for the "audible" tab indicator.

#import "OEInternal.h"

#include <map>
#include <mutex>

#include "include/cef_parser.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

const char kOEMsgScriptsUpdate[] = "oe.scripts.update";
const char kOEMsgAudibleChanged[] = "oe.audible";
const char kOEMsgMediaReport[] = "oe.media";
const char kOEMsgMediaCommand[] = "oe.media.cmd";
const char kOEExtraScripts[] = "oe.scripts";

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

// Runs at document start in every frame. Tracks unmuted, playing media
// elements and reports changes through the native callback, which is removed
// from the global object before any page script runs.
const char kAudibleProbe[] = R"JS((function(report){
  let audible = false;
  const media = new Set();
  const update = () => {
    let now = false;
    for (const m of media) {
      if (!m.paused && !m.muted && m.volume > 0) { now = true; break; }
    }
    if (now !== audible) { audible = now; report(now); }
  };
  const track = (e) => {
    const t = e.target;
    if (t instanceof HTMLMediaElement) { media.add(t); update(); }
  };
  const types = ['play','playing','pause','ended','volumechange','emptied'];
  for (const type of types) window.addEventListener(type, track, true);
  // Detached elements (new Audio()) never reach window listeners.
  const play = HTMLMediaElement.prototype.play;
  HTMLMediaElement.prototype.play = function() {
    if (!media.has(this)) {
      media.add(this);
      for (const type of types) this.addEventListener(type, update);
    }
    const p = play.apply(this, arguments);
    Promise.resolve(p).then(update, update);
    return p;
  };
})(globalThis.__oeAudible); delete globalThis.__oeAudible;)JS";

// Media session probe (media-pip EM-1a). Runs at document start in every
// frame, like the audible probe. It reports the frame's media state as JSON
// on media events only (no timer, no timeupdate), records the page's
// navigator.mediaSession action handlers so the shell can call them, and
// returns the command function the browser reaches through kOEMsgMediaCommand.
// The native report function is removed before any page script runs.
const char kMediaProbe[] = R"JS((() => {
const report = globalThis.__oeMedia; delete globalThis.__oeMedia;
const media = new Set();
const handlers = new Map();
let lastPlayed = null, lastPlayedAt = 0, last = '', pending = false;
let micActive = null, cameraActive = null;
const hasAudio = (m) => {
  const s = m.srcObject;
  if (s && typeof s.getAudioTracks === 'function') return s.getAudioTracks().length > 0;
  return !!(m.currentSrc || m.src || s);
};
const area = (v) => {
  if (!v.isConnected || !v.videoWidth) return [0, 0];
  const r = v.getBoundingClientRect();
  return [Math.max(0, r.width), Math.max(0, r.height)];
};
const largestPlaying = () => {
  let best = null, bestArea = -1;
  for (const m of media) {
    if (!(m instanceof HTMLVideoElement) || m.paused || m.ended || !m.videoWidth) continue;
    const [w, h] = area(m);
    if (w * h > bestArea) { best = m; bestArea = w * h; }
  }
  return best;
};
const state = () => {
  let playing = false, paused = false, video = false, audio = false, controllable = false;
  for (const m of Array.from(media)) {
    if (!m.isConnected && m.paused) { media.delete(m); if (lastPlayed === m) lastPlayed = null; continue; }
    const active = !m.paused && !m.ended;
    if (!active && (m.ended || m.currentTime <= 0)) continue;
    if (active) playing = true; else paused = true;
    const a = hasAudio(m);
    if (a) audio = true;
    const d = m.duration;
    if (a && !(isFinite(d) && d < 5)) controllable = true;
    if (m instanceof HTMLVideoElement && m.videoWidth > 0) video = true;
  }
  if (!playing && !paused) return {};
  const big = largestPlaying();
  const [vw, vh] = big ? area(big) : [0, 0];
  const actions = ['play', 'pause', 'seekto'];
  for (const [k, v] of handlers) if (v) actions.push(k);
  if (big && !big.disablePictureInPicture && document.pictureInPictureEnabled) actions.push('pip');
  const md = navigator.mediaSession && navigator.mediaSession.metadata;
  const t = lastPlayed && media.has(lastPlayed) ? lastPlayed : null;
  const d = t ? t.duration : NaN;
  return {
    playback: playing ? 'playing' : 'paused', controllable, video, audio,
    vw, vh, pipDisabled: !!(big && big.disablePictureInPicture),
    pip: !!document.pictureInPictureElement, actions,
    title: md ? String(md.title || '') : null, artist: md ? String(md.artist || '') : null,
    album: md ? String(md.album || '') : null,
    duration: t ? (isFinite(d) ? d : (d > 0 ? -1 : 0)) : null,
    position: t ? t.currentTime : null, rate: t ? t.playbackRate : null, ended: t ? t.ended : false,
    micMuted: micActive === null ? null : !micActive, cameraOn: cameraActive,
    lastPlayedAt, frameArea: vw * vh,
  };
};
const flush = () => {
  pending = false;
  const s = JSON.stringify(state());
  if (s !== last) { last = s; report('state', s); }
};
const schedule = () => { if (!pending) { pending = true; queueMicrotask(flush); } };
const track = (e) => {
  hook();
  const t = e.target;
  if (t instanceof HTMLMediaElement) {
    media.add(t);
    if (e.type === 'play' || e.type === 'playing') { lastPlayed = t; lastPlayedAt = Date.now(); }
    schedule();
  }
};
const types = ['play', 'playing', 'pause', 'ended', 'emptied', 'loadedmetadata', 'durationchange',
  'ratechange', 'seeked', 'resize', 'volumechange', 'enterpictureinpicture', 'leavepictureinpicture'];
for (const type of types) window.addEventListener(type, track, true);
const play = HTMLMediaElement.prototype.play;
HTMLMediaElement.prototype.play = function() {
  if (!media.has(this) && !this.isConnected) {
    media.add(this);
    for (const type of types) this.addEventListener(type, track);
  }
  return play.apply(this, arguments);
};
// Blink installs secure-context interfaces (MediaSession) after this probe runs, so the
// hooks go in at the first point where the interface exists: a microtask, the first DOM
// mutation (its microtask runs before the first parser-inserted script), DOMContentLoaded
// and every media event.
let hooked = false;
const hook = () => {
  const MS = !hooked && globalThis.MediaSession && MediaSession.prototype;
  if (!MS) return;
  hooked = true;
  const setHandler = MS.setActionHandler;
  MS.setActionHandler = function(action, handler) {
    const r = setHandler.apply(this, arguments);
    handlers.set(String(action), typeof handler === 'function' ? handler : null);
    schedule();
    return r;
  };
  const meta = Object.getOwnPropertyDescriptor(MS, 'metadata');
  if (meta && meta.set) Object.defineProperty(MS, 'metadata', { ...meta,
    set(v) { meta.set.call(this, v); schedule(); } });
  for (const [name, setter] of [['setMicrophoneActive', (v) => { micActive = !!v; }],
                                ['setCameraActive', (v) => { cameraActive = !!v; }]]) {
    const f = MS[name];
    if (typeof f === 'function') MS[name] = function(v) { setter(v); schedule(); return f.apply(this, arguments); };
  }
};
hook();
queueMicrotask(hook);
const observer = new MutationObserver(() => { hook(); if (hooked) observer.disconnect(); });
observer.observe(document, { childList: true, subtree: true });
document.addEventListener('DOMContentLoaded', () => { hook(); observer.disconnect(); }, { once: true, capture: true });
window.addEventListener('pagehide', () => { last = ''; report('state', '{}'); }, true);
window.addEventListener('pageshow', (e) => { if (e.persisted) { last = ''; schedule(); } }, true);
const call = (action, details) => {
  const h = handlers.get(action);
  if (!h) return false;
  try { h(Object.assign({ action }, details || {})); } catch (e) {}
  return true;
};
const target = () => {
  if (lastPlayed && media.has(lastPlayed)) return lastPlayed;
  for (const m of media) if (!m.paused) return m;
  for (const m of media) return m;
  return null;
};
return (cmd, value) => {
  const t = target();
  switch (cmd) {
    case 'play': if (!call('play') && t) Promise.resolve(t.play()).catch(() => {}); break;
    case 'pause': if (!call('pause')) for (const m of media) if (!m.paused) m.pause(); break;
    case 'stop': if (!call('stop')) for (const m of media) if (!m.paused) m.pause(); break;
    case 'seekby':
      if (!call(value < 0 ? 'seekbackward' : 'seekforward', { seekOffset: Math.abs(value) }) && t)
        t.currentTime = Math.max(0, t.currentTime + value);
      break;
    case 'seekto': if (!call('seekto', { seekTime: value }) && t) t.currentTime = value; break;
    case 'scrubto':
      if (!call('seekto', { seekTime: value, fastSeek: true }) && t) t.currentTime = value;
      break;
    case 'pip': {
      const v = largestPlaying();
      const done = (ok) => report('pip', JSON.stringify({ id: value, ok }));
      if (!v || v.disablePictureInPicture) { done(false); break; }
      v.requestPictureInPicture().then(() => done(true), () => done(false));
      break;
    }
    case 'exitpip':
      if (document.pictureInPictureElement) document.exitPictureInPicture().catch(() => {});
      break;
    default: call(cmd); break;
  }
};
})())JS";

class MediaReportHandler : public CefV8Handler {
 public:
  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    if (arguments.size() < 2) {
      return false;
    }
    CefRefPtr<CefV8Context> ctx = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = ctx ? ctx->GetFrame() : nullptr;
    if (!frame) {
      return false;
    }
    CefRefPtr<CefProcessMessage> msg =
        CefProcessMessage::Create(kOEMsgMediaReport);
    msg->GetArgumentList()->SetString(0, arguments[0]->GetStringValue());
    msg->GetArgumentList()->SetString(1, arguments[1]->GetStringValue());
    msg->GetArgumentList()->SetString(2, frame->GetIdentifier());
    frame->SendProcessMessage(PID_BROWSER, msg);
    return true;
  }
  IMPLEMENT_REFCOUNTING(MediaReportHandler);
};

struct RendererScript {
  std::string source;
  bool css = false;
  bool document_end = false;
  bool main_frame_only = true;
  std::vector<std::string> patterns;
};

class AudibleHandler : public CefV8Handler {
 public:
  bool Execute(const CefString& name,
               CefRefPtr<CefV8Value> object,
               const CefV8ValueList& arguments,
               CefRefPtr<CefV8Value>& retval,
               CefString& exception) override {
    if (arguments.empty()) {
      return false;
    }
    CefRefPtr<CefV8Context> ctx = CefV8Context::GetCurrentContext();
    CefRefPtr<CefFrame> frame = ctx ? ctx->GetFrame() : nullptr;
    if (!frame) {
      return false;
    }
    CefRefPtr<CefProcessMessage> msg =
        CefProcessMessage::Create(kOEMsgAudibleChanged);
    msg->GetArgumentList()->SetBool(0, arguments[0]->GetBoolValue());
    msg->GetArgumentList()->SetString(1, frame->GetIdentifier());
    frame->SendProcessMessage(PID_BROWSER, msg);
    return true;
  }
  IMPLEMENT_REFCOUNTING(AudibleHandler);
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
    // Chromium features Open turns on, added to any --enable-features list:
    // ExtensionsPinnedByDefault pins a new install's action (extensions UI
    // plan Q4; the profile pref extensions.pinned_by_default defaults on).
    std::string features = command_line->GetSwitchValue("enable-features");
    for (const char* feature : {"ExtensionsPinnedByDefault"}) {
      features += features.empty() ? feature : std::string(",") + feature;
    }
    command_line->AppendSwitchWithValue("enable-features", features);
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
  }

  void OnBrowserDestroyed(CefRefPtr<CefBrowser> browser) override {
    std::lock_guard<std::mutex> lock(mutex_);
    scripts_.erase(browser->GetIdentifier());
  }

  void OnContextCreated(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefV8Context> context) override {
    std::string url = frame->GetURL().ToString();
    bool web = url.rfind("http", 0) == 0 || url.rfind("file:", 0) == 0;

    CefRefPtr<CefV8Value> global = context->GetGlobal();
    CefRefPtr<CefV8Value> retval;
    CefRefPtr<CefV8Exception> exception;
    if (web) {
      global->SetValue("__oeAudible",
                       CefV8Value::CreateFunction("__oeAudible",
                                                  new AudibleHandler()),
                       V8_PROPERTY_ATTRIBUTE_DONTENUM);
      context->Eval(kAudibleProbe, "openengine://audible", 1, retval,
                    exception);
      global->SetValue("__oeMedia",
                       CefV8Value::CreateFunction("__oeMedia",
                                                  new MediaReportHandler()),
                       V8_PROPERTY_ATTRIBUTE_DONTENUM);
      CefRefPtr<CefV8Value> command;
      if (context->Eval(kMediaProbe, "openengine://media", 1, command,
                        exception) &&
          command && command->IsFunction()) {
        media_commands_[frame->GetIdentifier().ToString()] = {context,
                                                               command};
      }
    }

    std::vector<RendererScript> scripts;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto it = scripts_.find(browser->GetIdentifier());
      if (it != scripts_.end()) {
        scripts = it->second;
      }
    }
    for (const RendererScript& s : scripts) {
      if (s.main_frame_only && !frame->IsMain()) {
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
      if (s.document_end) {
        code =
            "document.addEventListener('DOMContentLoaded',()=>{" + code +
            "\n},{once:true});";
      }
      context->Eval(code, "openengine://userscript", 1, retval, exception);
    }
  }

  void OnContextReleased(CefRefPtr<CefBrowser> browser,
                         CefRefPtr<CefFrame> frame,
                         CefRefPtr<CefV8Context> context) override {
    auto it = media_commands_.find(frame->GetIdentifier().ToString());
    if (it != media_commands_.end() && it->second.context->IsSame(context)) {
      media_commands_.erase(it);
    }
  }

  bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                CefRefPtr<CefFrame> frame,
                                CefProcessId source_process,
                                CefRefPtr<CefProcessMessage> message) override {
    if (message->GetName() == kOEMsgMediaCommand) {
      auto it = media_commands_.find(frame->GetIdentifier().ToString());
      if (it == media_commands_.end() || !it->second.context->IsValid()) {
        return true;
      }
      CefRefPtr<CefListValue> args = message->GetArgumentList();
      CefRefPtr<CefV8Context> context = it->second.context;
      CefRefPtr<CefV8Value> command = it->second.command;
      if (context->Enter()) {
        CefV8ValueList call_args = {
            CefV8Value::CreateString(args->GetString(0)),
            CefV8Value::CreateDouble(args->GetDouble(1))};
        command->ExecuteFunction(nullptr, call_args);
        context->Exit();
      }
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

  void SetScripts(int browser_id, CefRefPtr<CefListValue> list) {
    std::vector<RendererScript> out;
    for (size_t i = 0; list && i < list->GetSize(); ++i) {
      CefRefPtr<CefDictionaryValue> d = list->GetDictionary(i);
      RendererScript s;
      s.source = d->GetString("source");
      s.css = d->GetBool("css");
      s.document_end = d->GetBool("end");
      s.main_frame_only = d->GetBool("mainFrameOnly");
      CefRefPtr<CefListValue> pats = d->GetList("matches");
      for (size_t j = 0; pats && j < pats->GetSize(); ++j) {
        s.patterns.push_back(pats->GetString(j));
      }
      out.push_back(std::move(s));
    }
    std::lock_guard<std::mutex> lock(mutex_);
    scripts_[browser_id] = std::move(out);
  }

  struct MediaCommand {
    CefRefPtr<CefV8Context> context;
    CefRefPtr<CefV8Value> command;
  };

  std::vector<std::string> switches_;
  // Render thread only: the media probe's command function per frame.
  std::map<std::string, MediaCommand> media_commands_;
  std::mutex mutex_;
  std::map<int, std::vector<RendererScript>> scripts_;

  IMPLEMENT_REFCOUNTING(OEApp);
};

}  // namespace

CefRefPtr<CefApp> OECreateApp(NSArray<NSString*>* extraSwitches) {
  std::vector<std::string> switches;
  for (NSString* s in extraSwitches) {
    switches.push_back(s.UTF8String);
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
