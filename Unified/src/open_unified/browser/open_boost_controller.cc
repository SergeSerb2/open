// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_boost_controller.h"

#include <algorithm>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/json/string_escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/stringprintf.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/core/boosts/boost_store.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

// Hook 0004 defines this world on every platform (6; ad-block cosmetics use
// 7, extensions start at 8). Track 3's BoostStore uses the same number.
constexpr int32_t kOpenWorldId = ISOLATED_WORLD_ID_OPEN;
static_assert(kOpenWorldId == kIsolatedWorldIdOpen,
              "Open's Boost world must match BoostStore");

constexpr size_t kMaxSelectorBytes = kZapMaxSelectorBytes;
constexpr size_t kMaxLabelBytes = kZapMaxLabelBytes;
constexpr base::TimeDelta kZapPollInterval = base::Milliseconds(250);

// The managed applier, run in world 6 with the generated payload. Keeps one
// <style> element and re-inserts it when a SPA replaces <head>; runs user JS
// once per document in the main world through a script element.
constexpr char kApplierTemplate[] = R"JS(
(function(payload) {
  const KEY = '__openBoostApplier';
  let state = window[KEY];
  if (!state) {
    state = { style: null, observer: null, scriptsRun: new Set() };
    window[KEY] = state;
  }
  function ensureStyle() {
    const root = document.head || document.documentElement;
    if (!root) return;
    if (!state.style) {
      state.style = document.createElement('style');
      state.style.setAttribute('data-open-boost', '');
    }
    if (state.style.textContent !== payload.css) {
      state.style.textContent = payload.css;
    }
    if (state.style.parentNode !== root) root.appendChild(state.style);
  }
  ensureStyle();
  if (!state.observer) {
    state.observer = new MutationObserver(() => {
      if (!state.style || !state.style.isConnected) ensureStyle();
    });
    state.observer.observe(document.documentElement,
                           { childList: true, subtree: false });
  }
  for (const item of payload.scripts) {
    if (state.scriptsRun.has(item.id)) continue;
    state.scriptsRun.add(item.id);
    const s = document.createElement('script');
    s.textContent = item.source;
    (document.head || document.documentElement).appendChild(s);
    s.remove();
  }
  return payload.css.length;
})($1)
)JS";

// The Zap picker, armed in world 6. `take()` hands the browser at most one
// pick per session; only the browser knows the nonce it compares.
constexpr char kZapPickerTemplate[] = R"JS(
(function(session) {
  if (window.__openZap) window.__openZap.exit();
  const overlay = document.createElement('div');
  overlay.style.cssText =
      'position:fixed;pointer-events:none;z-index:2147483647;' +
      'background:rgba(255,64,64,0.25);outline:2px solid #ff4040;' +
      'display:none;';
  document.documentElement.appendChild(overlay);
  let pick = null;
  let target = null;
  function cssPath(el) {
    if (el.id &&
        document.querySelectorAll('#' + CSS.escape(el.id)).length === 1) {
      return '#' + CSS.escape(el.id);
    }
    const parts = [];
    while (el && el.nodeType === 1 && el !== document.documentElement) {
      let part = el.localName;
      const parent = el.parentElement;
      if (parent) {
        const same = Array.from(parent.children)
            .filter(c => c.localName === el.localName);
        if (same.length > 1) {
          part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
        }
      }
      parts.unshift(part);
      if (el.id) { parts[0] = '#' + CSS.escape(el.id); break; }
      el = parent;
    }
    return parts.join(' > ');
  }
  function onMove(e) {
    target = e.target;
    const r = target.getBoundingClientRect();
    Object.assign(overlay.style, { display: 'block', left: r.left + 'px',
        top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
  }
  function onClick(e) {
    e.preventDefault(); e.stopPropagation();
    if (!target) return;
    const label = (target.getAttribute('aria-label') || target.innerText ||
                   target.localName).trim().slice(0, 120);
    pick = { boostId: session.boostId, nonce: session.nonce,
             selector: cssPath(target), label };
    exit();
  }
  function onKey(e) { if (e.key === 'Escape') { pick = { cancelled: true,
      boostId: session.boostId, nonce: session.nonce }; exit(); } }
  function exit() {
    document.removeEventListener('mousemove', onMove, true);
    document.removeEventListener('click', onClick, true);
    document.removeEventListener('keydown', onKey, true);
    overlay.remove();
  }
  document.addEventListener('mousemove', onMove, true);
  document.addEventListener('click', onClick, true);
  document.addEventListener('keydown', onKey, true);
  window.__openZap = {
    exit,
    take() { const p = pick; pick = null; return p; },
  };
  return true;
})($1)
)JS";

std::string QuoteCssString(const std::string& value) {
  std::string out = "\"";
  for (char c : value) {
    if (c == '"' || c == '\\') {
      out += '\\';
      out += c;
    } else if (c == '\n' || c == '\r' || c == '<') {
      out += ' ';
    } else {
      out += c;
    }
  }
  out += '"';
  return out;
}

std::string FormatNumber(double value) {
  return base::NumberToString(value);
}

std::u16string FillTemplate(const char* source, const base::Value& payload) {
  std::string json;
  base::JSONWriter::Write(payload, &json);
  std::string script(source);
  const size_t pos = script.find("$1");
  script.replace(pos, 2, json);
  return base::UTF8ToUTF16(script);
}

}  // namespace

OpenBoostController::OpenBoostController(OpenBrowserService* service)
    : service_(service) {
  service_->tab_bridge()->AddObserver(this);
  for (const Profile& profile : service_->model().profiles()) {
    ReloadBoosts(profile.id);
  }
}

OpenBoostController::~OpenBoostController() {
  if (OpenTabBridge* bridge = service_->tab_bridge()) {
    bridge->RemoveObserver(this);
  }
}

// static
bool OpenBoostController::HostMatches(const std::string& host,
                                      const std::string& pattern) {
  if (host.empty() || pattern.empty()) {
    return false;
  }
  // Domain suffix, or an exact IP (docs/boosts.md SiteMatch).
  return SiteMatch::Normalized(pattern).Matches(host, "/");
}

void OpenBoostController::ReloadBoosts(const ProfileID& profile_id) {
  ProfileServices* ps = service_->ProfileServicesFor(profile_id);
  if (!ps) {
    return;
  }
  RunOnStore(ps->boosts,
             base::BindOnce([](BoostStore* store) { return store->List(); }),
             base::BindOnce(&OpenBoostController::OnBoostsLoaded,
                            weak_factory_.GetWeakPtr(), profile_id));
}

void OpenBoostController::OnBoostsLoaded(const ProfileID& profile_id,
                                         std::vector<Boost> boosts) {
  boosts_[profile_id] = std::move(boosts);
  OpenTabBridge* bridge = service_->tab_bridge();
  if (!bridge) {
    return;
  }
  for (const auto& [tab_id, contents] : bridge->LoadedTabs()) {
    if (model_util::ProfileOfNode(service_->model(), tab_id) == profile_id) {
      ApplyToContents(tab_id, contents, /*refresh=*/true);
    }
  }
}

const std::vector<Boost>& OpenBoostController::BoostsFor(
    const ProfileID& profile_id) {
  return boosts_[profile_id];
}

std::vector<Boost> OpenBoostController::MatchingBoosts(
    const ProfileID& profile_id,
    const GURL& url) {
  std::vector<Boost> result;
  if (!url.SchemeIsHTTPOrHTTPS()) {
    return result;
  }
  const std::string host(url.host());
  for (const Boost& boost : boosts_[profile_id]) {
    if (boost.enabled && HostMatches(host, boost.host_pattern)) {
      result.push_back(boost);
    }
  }
  return result;
}

// static
std::string OpenBoostController::BuildStylesheet(
    const std::vector<Boost>& boosts) {
  // Track 3 owns the Boost CSS format (color filter, font, zoom, transform,
  // Zaps, custom CSS; docs/boosts.md). The local builder below is the
  // fallback for an empty generator result only.
  std::string generated = BoostStore::GenerateCssForBoosts(boosts);
  if (!generated.empty() || boosts.empty()) {
    return generated;
  }
  std::string css;
  for (const Boost& boost : boosts) {
    css += "/* boost " + boost.id + " */\n";
    if (boost.color.enabled) {
      std::string filter = "hue-rotate(" +
                           FormatNumber(boost.color.hue_degrees) +
                           "deg) saturate(" +
                           FormatNumber(boost.color.saturation) +
                           ") brightness(" +
                           FormatNumber(1.0 + boost.color.lightness) +
                           ") contrast(" + FormatNumber(boost.color.contrast) +
                           ")";
      if (boost.color.invert) {
        filter += " invert(1) hue-rotate(180deg)";
      }
      css += "html { filter: " + filter + " !important; }\n";
      if (boost.color.invert) {
        // Keep media natural under an inverted page.
        css += "img, video, picture, canvas, svg image "
               "{ filter: invert(1) hue-rotate(180deg) !important; }\n";
      }
    }
    if (boost.font_family && !boost.font_family->empty()) {
      css += "body, body *:not(code):not(pre):not(kbd):not(samp) "
             "{ font-family: " +
             QuoteCssString(*boost.font_family) + " !important; }\n";
    }
    if (boost.text_zoom != 1.0) {
      css += "html { zoom: " + FormatNumber(boost.text_zoom) +
             " !important; }\n";
    }
    if (!boost.text_transform.empty()) {
      css += "body * { text-transform: " + boost.text_transform +
             " !important; }\n";
    }
    for (const ZappedElement& zap : boost.zapped_elements) {
      if (!zap.selector.empty() && zap.selector.size() <= kMaxSelectorBytes &&
          zap.selector.find('{') == std::string::npos &&
          zap.selector.find('}') == std::string::npos) {
        css += zap.selector + " { display: none !important; }\n";
      }
    }
    if (!boost.custom_css.empty()) {
      css += boost.custom_css + "\n";
    }
  }
  return css;
}

void OpenBoostController::ApplyToContents(const ItemID& tab_id,
                                          content::WebContents* contents,
                                          bool refresh) {
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) {
    return;
  }
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), tab_id);
  if (!profile) {
    return;
  }
  const GURL url = contents->GetLastCommittedURL();
  std::vector<Boost> boosts = MatchingBoosts(*profile, url);
  // An empty payload also removes a previously applied Boost (disabled or
  // deleted while the page is open).
  base::ListValue scripts;
  for (const Boost& boost : boosts) {
    if (!boost.custom_js.empty()) {
      scripts.Append(base::DictValue()
                         .Set("id", boost.id + ":" +
                                        base::NumberToString(boost.modified_at))
                         .Set("source", boost.custom_js));
    }
  }
  // Pages without a Boost never get world 6 (no isolated-world cost on
  // ordinary navigations); a page that had one gets an empty payload once.
  const bool had_boost = boosted_tabs_.contains(tab_id);
  if (boosts.empty()) {
    boosted_tabs_.erase(tab_id);
    if (!had_boost || !refresh) {
      return;
    }
  } else {
    boosted_tabs_.insert(tab_id);
  }
  if (!contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
    return;
  }
  base::Value payload(base::DictValue()
                          .Set("css", BuildStylesheet(boosts))
                          .Set("scripts", std::move(scripts)));
  contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      FillTemplate(kApplierTemplate, payload), base::NullCallback(),
      kOpenWorldId);
  if (!boosts.empty()) {
    ++applied_count_;
  }
}

void OpenBoostController::OnTabDocumentAvailable(
    const ItemID& tab_id,
    content::WebContents* contents) {
  ApplyToContents(tab_id, contents, /*refresh=*/false);
}

void OpenBoostController::OnTabPrimaryPageCommitted(
    const ItemID& tab_id,
    content::WebContents* contents) {
  // A new document invalidates an armed Zap session on that tab.
  if (zap_ && zap_->tab_id == tab_id) {
    CancelZap();
  }
}

// --- Zap ---------------------------------------------------------------------

bool OpenBoostController::StartZap(const std::string& boost_id,
                                   std::string* message) {
  OpenTabBridge* bridge = service_->tab_bridge();
  std::optional<ItemID> tab_id =
      bridge ? bridge->ActiveTabId() : std::nullopt;
  content::WebContents* contents =
      tab_id ? bridge->WebContentsForTab(*tab_id) : nullptr;
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord()) {
    *message = "Open a page to zap elements on it.";
    return false;
  }
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), *tab_id);
  const std::vector<Boost>& boosts = BoostsFor(profile.value_or(ProfileID()));
  auto boost = std::find_if(boosts.begin(), boosts.end(),
                            [&](const Boost& b) { return b.id == boost_id; });
  const GURL url = contents->GetLastCommittedURL();
  if (boost == boosts.end() || !url.SchemeIsHTTPOrHTTPS() ||
      !HostMatches(std::string(url.host()), boost->host_pattern)) {
    *message = "The active tab is not a page of this Boost's site.";
    return false;
  }
  CancelZap();
  zap_ = ZapSession{boost_id, *profile, *tab_id,
                    base::UnguessableToken::Create()};
  base::Value session(base::DictValue()
                          .Set("boostId", boost_id)
                          .Set("nonce", zap_->nonce.ToString()));
  contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      FillTemplate(kZapPickerTemplate, session), base::NullCallback(),
      kOpenWorldId);
  zap_poll_.Start(FROM_HERE, kZapPollInterval,
                  base::BindRepeating(&OpenBoostController::PollZap,
                                      weak_factory_.GetWeakPtr()));
  *message = "Click an element to hide it. Press Esc to stop.";
  return true;
}

void OpenBoostController::CancelZap() {
  zap_poll_.Stop();
  if (zap_) {
    if (content::WebContents* contents =
            service_->tab_bridge()->WebContentsForTab(zap_->tab_id)) {
      contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
          u"window.__openZap && window.__openZap.exit(); "
          u"delete window.__openZap;",
          base::NullCallback(), kOpenWorldId);
    }
  }
  zap_.reset();
}

void OpenBoostController::PollZap() {
  if (!zap_) {
    zap_poll_.Stop();
    return;
  }
  content::WebContents* contents =
      service_->tab_bridge()->WebContentsForTab(zap_->tab_id);
  if (!contents) {
    CancelZap();
    return;
  }
  contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      u"(window.__openZap && window.__openZap.take()) || null",
      base::BindOnce(&OpenBoostController::OnZapResult,
                     weak_factory_.GetWeakPtr()),
      kOpenWorldId);
}

void OpenBoostController::OnZapResult(base::Value result) {
  if (!zap_ || !result.is_dict()) {
    return;
  }
  const base::DictValue& pick = result.GetDict();
  const std::string* boost_id = pick.FindString("boostId");
  const std::string* nonce = pick.FindString("nonce");
  // A reply that does not carry this session's pair is ignored: a page
  // script cannot see world 6 state, and old sessions' nonces expire.
  if (!boost_id || !nonce || *boost_id != zap_->boost_id ||
      *nonce != zap_->nonce.ToString()) {
    return;
  }
  if (pick.FindBool("cancelled").value_or(false)) {
    CancelZap();
    return;
  }
  const std::string* selector = pick.FindString("selector");
  const std::string* label = pick.FindString("label");
  if (!selector || selector->empty() || selector->size() > kMaxSelectorBytes ||
      selector->find('{') != std::string::npos ||
      selector->find('}') != std::string::npos ||
      !base::IsStringUTF8(*selector)) {
    return;
  }
  std::string safe_label = label ? label->substr(0, kMaxLabelBytes) : "";
  content::WebContents* contents =
      service_->tab_bridge()->WebContentsForTab(zap_->tab_id);
  if (!contents) {
    CancelZap();
    return;
  }
  // The selector must parse and match in the page before it is saved.
  std::string quoted;
  base::EscapeJSONString(*selector, /*put_in_quotes=*/true, &quoted);
  contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      base::UTF8ToUTF16("(() => { try { return document.querySelectorAll(" +
                        quoted + ").length; } catch (e) { return -1; } })()"),
      base::BindOnce(&OpenBoostController::OnZapSelectorChecked,
                     weak_factory_.GetWeakPtr(), *selector,
                     std::move(safe_label)),
      kOpenWorldId);
  zap_poll_.Stop();
}

void OpenBoostController::OnZapSelectorChecked(std::string selector,
                                               std::string label,
                                               base::Value count) {
  if (!zap_) {
    return;
  }
  const ZapSession session = *zap_;
  zap_.reset();
  if (!count.is_int() || count.GetInt() < 1) {
    return;
  }
  ProfileServices* ps = service_->ProfileServicesFor(session.profile_id);
  if (!ps) {
    return;
  }
  const std::vector<Boost>& boosts = BoostsFor(session.profile_id);
  auto it = std::find_if(boosts.begin(), boosts.end(), [&](const Boost& b) {
    return b.id == session.boost_id;
  });
  if (it == boosts.end()) {
    return;
  }
  Boost updated = *it;
  updated.zapped_elements.push_back(ZappedElement{
      base::UnguessableToken::Create().ToString(), selector, label});
  RunOnStore(ps->boosts,
             base::BindOnce(
                 [](Boost boost, BoostStore* store) {
                   return store->Save(std::move(boost));
                 },
                 std::move(updated)),
             base::BindOnce(
                 [](base::WeakPtr<OpenBoostController> self,
                    ProfileID profile_id, Boost saved) {
                   if (self) {
                     self->ReloadBoosts(profile_id);
                   }
                 },
                 weak_factory_.GetWeakPtr(), session.profile_id));
}

base::DictValue OpenBoostController::StateForAutomation() const {
  base::DictValue state;
  state.Set("zapArmed", zap_.has_value());
  state.Set("applied", applied_count_);
  base::DictValue counts;
  for (const auto& [profile_id, boosts] : boosts_) {
    counts.Set(profile_id, static_cast<int>(boosts.size()));
  }
  state.Set("boostsByProfile", std::move(counts));
  return state;
}

}  // namespace open_unified
