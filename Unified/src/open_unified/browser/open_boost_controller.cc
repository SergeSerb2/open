// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_boost_controller.h"

#include <algorithm>
#include <cmath>
#include <functional>
#include <set>
#include <utility>

#include "base/functional/bind.h"
#include "base/json/json_writer.h"
#include "base/json/string_escape.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "chrome/common/chrome_isolated_world_ids.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/render_frame_host.h"
#include "content/public/browser/web_contents.h"
#include "open_unified/browser/open_browser_service.h"
#include "open_unified/browser/open_model_util.h"
#include "open_unified/core/boosts/boost_store.h"
#include "open_unified/ui/webui/open_settings_ui.h"
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
constexpr size_t kMaxZaps = kZapMaxEntriesPerBoost;
// The browser collects queued picks this often while Zap is armed. The page
// hides a picked element at once, so this only bounds the store latency.
constexpr base::TimeDelta kZapPollInterval = base::Milliseconds(200);
// At most this many picks per collection (a page cannot flood the store).
constexpr size_t kMaxPicksPerPoll = 64;

constexpr char kEnableBoostsPref[] = "advanced.enableBoosts";

// Color ranges of the macOS editor (BoostColorWheel.clamped(),
// Packages/OpenKit/Sources/OpenBoosts/Boost.swift): brightness and contrast
// stay within 0.5...1.5, so no Boost can collapse a page to one color
// (brightness 0 or contrast 0 drew black-on-black / grey-on-grey pages).
constexpr double kMinBrightness = 0.5;
constexpr double kMaxBrightness = 1.5;
constexpr double kMinContrast = 0.5;
constexpr double kMaxContrast = 1.5;
constexpr double kMaxSaturation = 3.0;

// The managed applier, run in world 6 with the generated payload. Keeps one
// <style> element and re-inserts it when a SPA replaces <head>; runs user JS
// once per document in the main world through a script element.
//
// Inverted Boosts: `html { filter: ... invert(1) }` inverts what the root
// element paints. A root with no background of its own leaves the viewport
// canvas (the UA white, or a <body> color propagated to it) outside that
// painting on some pages, so text inverted to white sat on an uninverted
// white canvas, and dark sites got dark-on-dark text. The applier gives
// <html> an explicit opaque background equal to the page's own canvas color
// (html, else body, else white; read with the Boost sheet disabled), so the
// whole page inverts as one surface and text keeps its contrast.
constexpr char kApplierTemplate[] = R"JS(
(function(payload) {
  const KEY = '__openBoostApplier';
  let state = window[KEY];
  if (!state) {
    state = { style: null, observer: null, scriptsRun: new Set(),
              payload: null, canvas: null, canvasHadBody: false };
    window[KEY] = state;
  }
  state.payload = payload;
  function opaque(el) {
    if (!el) return null;
    const c = getComputedStyle(el).backgroundColor;
    if (!c || c === 'transparent' || /,\s*0(\.0+)?\)$/.test(c)) return null;
    return c;
  }
  function canvasColor() {
    if (state.canvas && (state.canvasHadBody || !document.body)) {
      return state.canvas;
    }
    const sheet = state.style && state.style.sheet;
    if (sheet) sheet.disabled = true;
    let color = 'rgb(255, 255, 255)';
    try {
      color = opaque(document.documentElement) || opaque(document.body) ||
              color;
    } catch (e) {
    } finally {
      if (sheet) sheet.disabled = false;
    }
    state.canvas = color;
    state.canvasHadBody = !!document.body;
    return color;
  }
  function render() {
    const root = document.head || document.documentElement;
    if (!root) return;
    const p = state.payload;
    let css = p.css;
    if (p.invert && css) {
      css += '\nhtml { background-color: ' + canvasColor() +
             ' !important; }\n';
    }
    if (!state.style) {
      state.style = document.createElement('style');
      state.style.setAttribute('data-open-boost', '');
    }
    if (state.style.textContent !== css) state.style.textContent = css;
    if (state.style.parentNode !== root) root.appendChild(state.style);
  }
  render();
  if (!state.observer) {
    state.observer = new MutationObserver(() => {
      const p = state.payload;
      if (!state.style || !state.style.isConnected ||
          (p && p.invert && !state.canvasHadBody && document.body)) {
        render();
      }
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

// The multi-shot Zap picker (macOS ZapPicker), armed in world 6.
//
// - pointerdown / mousedown / mouseup / pointerup / click / dblclick /
//   auxclick are swallowed in the capture phase on window
//   (preventDefault + stopImmediatePropagation), so links, buttons and page
//   handlers never see a zapping click.
// - A pick hides the element at once through a live world-6 <style>
//   (window.__openZapLive, which outlives the session so Undo can forget a
//   selector), and queues {boostId, nonce, selector, label} for the
//   browser. The picker stays armed until Escape or the browser ends it.
// - Hover draws an outline box and a tag/selector pill in a closed shadow
//   root (page CSS cannot restyle it; it never takes pointer events).
// Built with createElement/textContent only (Trusted Types safe).
constexpr char kZapPickerTemplate[] = R"JS(
(function(session) {
  if (window.__openZap) { try { window.__openZap.exit(); } catch (e) {} }
  const doc = document;
  if (!window.__openZapLive) {
    const live = { el: null, selectors: [] };
    live.render = function() {
      if (!live.el) {
        live.el = doc.createElement('style');
        live.el.setAttribute('data-open-zap-live', '');
      }
      live.el.textContent = live.selectors
          .map(s => s + ' { display: none !important; }').join('\n');
      const root = doc.head || doc.documentElement;
      if (root && live.el.parentNode !== root) root.appendChild(live.el);
    };
    live.add = function(s) {
      if (!live.selectors.includes(s)) { live.selectors.push(s); }
      live.render();
    };
    live.forget = function(s) {
      live.selectors = live.selectors.filter(x => x !== s);
      live.render();
    };
    live.forgetAll = function() { live.selectors = []; live.render(); };
    window.__openZapLive = live;
  }
  const live = window.__openZapLive;

  const host = doc.createElement('open-zap-overlay');
  host.setAttribute('data-open-zap-ignore', '');
  host.style.cssText = 'all: initial !important; position: fixed !important;' +
      'inset: 0 !important; pointer-events: none !important;' +
      'z-index: 2147483647 !important; display: block !important;';
  const shadow = host.attachShadow({ mode: 'closed' });
  const sheet = doc.createElement('style');
  sheet.textContent =
      '.box { position: fixed; display: none; box-sizing: border-box;' +
      '  border: 2px solid #3139FF; border-radius: 4px;' +
      '  background: rgba(49, 57, 255, 0.10);' +
      '  box-shadow: 0 0 0 1px rgba(255, 255, 255, 0.85); }' +
      '.pill { position: fixed; display: none; max-width: 320px;' +
      '  padding: 3px 7px; border-radius: 6px; background: #3139FF;' +
      '  color: #fff; font: 600 11px/14px -apple-system, system-ui,' +
      '  "Segoe UI", sans-serif; white-space: nowrap; overflow: hidden;' +
      '  text-overflow: ellipsis;' +
      '  box-shadow: 0 2px 8px rgba(0, 0, 0, 0.25); }' +
      '.pill b { font-weight: 700; } .pill span { opacity: 0.8; }';
  const box = doc.createElement('div');
  box.className = 'box';
  const pill = doc.createElement('div');
  pill.className = 'pill';
  const pillTag = doc.createElement('b');
  const pillRest = doc.createElement('span');
  pill.appendChild(pillTag);
  pill.appendChild(pillRest);
  shadow.appendChild(sheet);
  shadow.appendChild(box);
  shadow.appendChild(pill);
  doc.documentElement.appendChild(host);

  let pending = [];
  let target = null;
  let active = true;

  function zappable(el) {
    return el && el.nodeType === 1 && el !== host &&
           el !== doc.documentElement && el !== doc.body &&
           el.localName !== 'head' &&
           !(el.closest && el.closest('[data-open-zap-ignore]'));
  }
  function cssPath(el) {
    if (el.id && doc.querySelectorAll('#' + CSS.escape(el.id)).length === 1) {
      return '#' + CSS.escape(el.id);
    }
    const parts = [];
    while (el && el.nodeType === 1 && el !== doc.documentElement) {
      if (el === doc.body) { parts.unshift('body'); break; }
      let part = el.localName;
      if (el.id &&
          doc.querySelectorAll('#' + CSS.escape(el.id)).length === 1) {
        parts.unshift('#' + CSS.escape(el.id));
        break;
      }
      const parent = el.parentElement;
      if (parent) {
        const same = Array.from(parent.children)
            .filter(c => c.localName === el.localName);
        if (same.length > 1) {
          part += ':nth-of-type(' + (same.indexOf(el) + 1) + ')';
        }
      }
      parts.unshift(part);
      el = parent;
    }
    return parts.join(' > ');
  }
  function describe(el) {
    const text = (el.getAttribute('aria-label') || el.getAttribute('alt') ||
                  el.getAttribute('title') || el.innerText || '')
        .replace(/\s+/g, ' ').trim();
    return (text || el.localName).slice(0, 120);
  }
  function hint(el) {
    let rest = '';
    if (el.id) rest = '#' + el.id;
    else if (el.classList && el.classList.length) {
      rest = '.' + Array.from(el.classList).slice(0, 2).join('.');
    }
    return rest;
  }
  function place() {
    if (!active || !target || !target.isConnected) {
      box.style.display = 'none';
      pill.style.display = 'none';
      return;
    }
    const r = target.getBoundingClientRect();
    if (r.width < 1 && r.height < 1) {
      box.style.display = 'none';
      pill.style.display = 'none';
      return;
    }
    Object.assign(box.style, { display: 'block', left: r.left + 'px',
        top: r.top + 'px', width: r.width + 'px', height: r.height + 'px' });
    pillTag.textContent = target.localName;
    pillRest.textContent = hint(target) ?
        ' ' + hint(target) : '';
    pill.style.display = 'block';
    const top = r.top >= 24 ? r.top - 22 : Math.min(r.bottom + 4,
        window.innerHeight - 22);
    pill.style.left = Math.max(4, Math.min(r.left,
        window.innerWidth - 324)) + 'px';
    pill.style.top = Math.max(4, top) + 'px';
  }
  function hover(e) {
    if (!e.isTrusted) return;
    const el = e.target;
    target = zappable(el) ? el : null;
    place();
  }
  function swallow(e) {
    if (!e.isTrusted) return;
    if (e.button !== undefined && e.button !== 0) return;
    e.preventDefault();
    e.stopImmediatePropagation();
  }
  function commit(e) {
    if (!e.isTrusted) return;
    if (e.button !== 0 || e.isPrimary === false) return;
    e.preventDefault();
    e.stopImmediatePropagation();
    const el = zappable(e.target) ? e.target : null;
    if (!el) return;
    const selector = cssPath(el);
    if (!selector || selector.length > 4096) return;
    try { if (doc.querySelectorAll(selector).length < 1) return; }
    catch (err) { return; }
    live.add(selector);
    if (pending.length < 256) {
      pending.push({ boostId: session.boostId, nonce: session.nonce,
                     selector, label: describe(el) });
    }
    target = null;
    place();
  }
  function onKey(e) {
    if (!e.isTrusted) return;
    if (e.key !== 'Escape') return;
    e.preventDefault();
    e.stopImmediatePropagation();
    pending.push({ cancelled: true, boostId: session.boostId,
                   nonce: session.nonce });
    exit();
  }
  const listeners = [
    ['pointermove', hover], ['mouseover', hover],
    ['pointerdown', commit],
    ['mousedown', swallow], ['pointerup', swallow], ['mouseup', swallow],
    ['click', swallow], ['dblclick', swallow], ['auxclick', swallow],
    ['keydown', onKey],
  ];
  const opts = { capture: true, passive: false };
  for (const [type, fn] of listeners) window.addEventListener(type, fn, opts);
  window.addEventListener('scroll', place, { capture: true, passive: true });
  window.addEventListener('resize', place, { passive: true });
  function exit() {
    if (!active) return;
    active = false;
    for (const [type, fn] of listeners) {
      window.removeEventListener(type, fn, opts);
    }
    window.removeEventListener('scroll', place, { capture: true });
    window.removeEventListener('resize', place);
    host.remove();
  }
  window.__openZap = {
    exit,
    take() { const p = pending; pending = []; return p; },
  };
  return true;
})($1)
)JS";

// Collects queued picks with each selector's live match count (one round
// trip). Runs in world 6, where only browser-authored code can reach
// window.__openZap.
constexpr char16_t kZapTakeScript[] =
    u"(() => { const z = window.__openZap; if (!z) return null;"
    u" return z.take().map(p => { let c = -1;"
    u" if (p.selector) { try { c = document.querySelectorAll(p.selector)"
    u".length; } catch (e) {} } p.count = c; return p; }); })()";

// Final collection plus teardown (Done, editor closed, navigation).
constexpr char16_t kZapDrainScript[] =
    u"(() => { const z = window.__openZap; if (!z) return null;"
    u" const picks = z.take(); try { z.exit(); } catch (e) {}"
    u" delete window.__openZap;"
    u" return picks.map(p => { let c = -1;"
    u" if (p.selector) { try { c = document.querySelectorAll(p.selector)"
    u".length; } catch (e) {} } p.count = c; return p; }); })()";

std::string FormatNumber(double value) {
  // Fixed 4 decimals without trailing zeros (BoostStore's FormatCssNumber).
  std::string s = base::NumberToString(std::round(value * 10000.0) / 10000.0);
  return s == "-0" ? "0" : s;
}

std::u16string FillTemplate(const char* source, const base::Value& payload) {
  std::string json;
  base::JSONWriter::Write(payload, &json);
  std::string script(source);
  const size_t pos = script.find("$1");
  script.replace(pos, 2, json);
  return base::UTF8ToUTF16(script);
}

bool IsSafeSelector(const std::string& selector) {
  return !selector.empty() && selector.size() <= kMaxSelectorBytes &&
         selector.find_first_of("{}<") == std::string::npos &&
         base::IsStringUTF8(selector);
}

bool IsSafeFontFamily(const std::string& font) {
  const std::string_view trimmed =
      base::TrimWhitespaceASCII(font, base::TRIM_ALL);
  return !trimmed.empty() &&
         trimmed.find_first_of(";{}\"\r\n<") == std::string_view::npos;
}

bool IsAllowedTransform(const std::string& t) {
  return t == "none" || t == "uppercase" || t == "lowercase" ||
         t == "capitalize";
}

double Finite(double value, double fallback) {
  return std::isfinite(value) ? value : fallback;
}

// Hue normalized to [0, 360).
double NormalizedHue(double degrees) {
  double h = std::fmod(Finite(degrees, 0.0), 360.0);
  if (h < 0.0) {
    h += 360.0;
  }
  return h;
}

bool IsColorIdentity(const BoostColorAdjustment& c) {
  if (!c.enabled) {
    return true;
  }
  const double h = NormalizedHue(c.hue_degrees);
  const double s = std::clamp(Finite(c.saturation, 1.0), 0.0, kMaxSaturation);
  const double b = std::clamp(1.0 + Finite(c.lightness, 0.0), kMinBrightness,
                              kMaxBrightness);
  const double ct =
      std::clamp(Finite(c.contrast, 1.0), kMinContrast, kMaxContrast);
  return (h < 1e-9 || h > 360.0 - 1e-9) && std::fabs(s - 1.0) < 1e-9 &&
         std::fabs(b - 1.0) < 1e-9 && std::fabs(ct - 1.0) < 1e-9 &&
         !c.invert;
}

// The color adjustment that wins for |boosts| (the last non-identity one,
// BoostStore/InjectionPlan order).
const BoostColorAdjustment* EffectiveColor(const std::vector<Boost>& boosts) {
  const BoostColorAdjustment* color = nullptr;
  for (const Boost& boost : boosts) {
    if (!IsColorIdentity(boost.color)) {
      color = &boost.color;
    }
  }
  return color;
}

}  // namespace

OpenBoostController::OpenBoostController(OpenBrowserService* service)
    : service_(service), global_enabled_(BoostsGloballyEnabled()) {
  service_->tab_bridge()->AddObserver(this);
  for (const Profile& profile : service_->model().profiles()) {
    ReloadBoosts(profile.id);
  }
}

OpenBoostController::~OpenBoostController() {
  zap_poll_.Stop();
  if (OpenTabBridge* bridge = service_->tab_bridge()) {
    bridge->RemoveObserver(this);
  }
}

void OpenBoostController::AddObserver(Observer* observer) {
  observers_.AddObserver(observer);
}

void OpenBoostController::RemoveObserver(Observer* observer) {
  observers_.RemoveObserver(observer);
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

// static
bool OpenBoostController::BoostsGloballyEnabled() {
  webui::OpenPreferences* prefs = webui::OpenPreferences::Get();
  if (!prefs) {
    return true;
  }
  const base::Value value = prefs->GetValue(kEnableBoostsPref);
  return value.is_bool() ? value.GetBool() : true;
}

void OpenBoostController::OnBoostsPreferenceChanged() {
  const bool enabled = BoostsGloballyEnabled();
  if (enabled == global_enabled_) {
    return;
  }
  global_enabled_ = enabled;
  if (!enabled) {
    CancelZap();
  }
  RefreshTabs(std::nullopt);
  for (const auto& [profile_id, boosts] : boosts_) {
    NotifyBoostsChanged(profile_id);
  }
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
  global_enabled_ = BoostsGloballyEnabled();
  // A deleted Boost cannot stay armed.
  if (zap_ && zap_->profile_id == profile_id &&
      !FindBoost(profile_id, zap_->boost_id)) {
    CancelZap();
  }
  RefreshTabs(profile_id);
  NotifyBoostsChanged(profile_id);
}

const std::vector<Boost>& OpenBoostController::BoostsFor(
    const ProfileID& profile_id) {
  return boosts_[profile_id];
}

std::optional<Boost> OpenBoostController::FindBoost(
    const ProfileID& profile_id,
    const std::string& boost_id) const {
  auto it = boosts_.find(profile_id);
  if (it == boosts_.end()) {
    return std::nullopt;
  }
  for (const Boost& boost : it->second) {
    if (boost.id == boost_id) {
      return boost;
    }
  }
  return std::nullopt;
}

std::optional<ProfileID> OpenBoostController::ProfileOfBoost(
    const std::string& boost_id) const {
  for (const auto& [profile_id, boosts] : boosts_) {
    for (const Boost& boost : boosts) {
      if (boost.id == boost_id) {
        return profile_id;
      }
    }
  }
  return std::nullopt;
}

Boost* OpenBoostController::MutableBoost(const ProfileID& profile_id,
                                         const std::string& boost_id) {
  auto it = boosts_.find(profile_id);
  if (it == boosts_.end()) {
    return nullptr;
  }
  for (Boost& boost : it->second) {
    if (boost.id == boost_id) {
      return &boost;
    }
  }
  return nullptr;
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

std::vector<Boost> OpenBoostController::EffectiveBoosts(
    const ItemID& tab_id,
    const ProfileID& profile_id,
    const GURL& url) {
  std::vector<Boost> boosts = MatchingBoosts(profile_id, url);
  auto preview = previews_.find(tab_id);
  if (preview == previews_.end()) {
    return boosts;
  }
  Boost draft = preview->second;
  // Zaps are edited only through the Zap API; the stored list wins.
  if (std::optional<Boost> stored = FindBoost(profile_id, draft.id)) {
    draft.zapped_elements = stored->zapped_elements;
  }
  const bool draft_applies =
      draft.enabled && url.SchemeIsHTTPOrHTTPS() &&
      HostMatches(std::string(url.host()), draft.host_pattern);
  auto it = std::find_if(boosts.begin(), boosts.end(),
                         [&](const Boost& b) { return b.id == draft.id; });
  if (it != boosts.end()) {
    if (draft_applies) {
      *it = std::move(draft);
    } else {
      boosts.erase(it);
    }
  } else if (draft_applies) {
    boosts.push_back(std::move(draft));
  }
  return boosts;
}

// static
std::string OpenBoostController::BuildStylesheet(
    const std::vector<Boost>& boosts) {
  // Same merge rules as BoostStore::GenerateCssForBoosts and the macOS
  // InjectionPlan (the last non-identity color, font, zoom and transform
  // win; custom CSS and Zaps accumulate in order), with the macOS editor's
  // color ranges and a correct counter-inversion for media.
  if (boosts.empty()) {
    return std::string();
  }
  std::optional<std::string> font;
  std::optional<double> zoom;
  std::optional<std::string> transform;
  for (const Boost& boost : boosts) {
    if (boost.font_family && IsSafeFontFamily(*boost.font_family)) {
      font = std::string(
          base::TrimWhitespaceASCII(*boost.font_family, base::TRIM_ALL));
    }
    const double z = Finite(boost.text_zoom, 1.0);
    if (std::fabs(z - 1.0) > 1e-6) {
      zoom = std::clamp(z, 0.5, 2.0);
    }
    if (IsAllowedTransform(boost.text_transform)) {
      transform = boost.text_transform;
    }
  }

  std::string css;
  if (const BoostColorAdjustment* color = EffectiveColor(boosts)) {
    const double h = NormalizedHue(color->hue_degrees);
    const double s =
        std::clamp(Finite(color->saturation, 1.0), 0.0, kMaxSaturation);
    const double b = std::clamp(1.0 + Finite(color->lightness, 0.0),
                                kMinBrightness, kMaxBrightness);
    const double ct =
        std::clamp(Finite(color->contrast, 1.0), kMinContrast, kMaxContrast);
    std::string filter = "hue-rotate(" + FormatNumber(h) + "deg) saturate(" +
                         FormatNumber(s) + ") brightness(" + FormatNumber(b) +
                         ") contrast(" + FormatNumber(ct) + ")";
    if (color->invert) {
      filter += " invert(1)";
    }
    css += "html { filter: " + filter + " !important; }\n";
    if (color->invert) {
      // Counter-invert media so photos and video keep their real colors.
      // A child's filter runs before the root's: invert(1), hue-rotate(k),
      // then the root's hue-rotate(h) ... invert(1). Because
      // invert . hue-rotate(t) . invert == hue-rotate(t), the hues cancel
      // when k = 360 - h (the macOS applier's (h + 180) left a hue shift
      // of 2h + 180). Nested media are excluded so <picture><img> is not
      // counter-inverted twice. The root's brightness/contrast still reach
      // media, as on macOS.
      const double k = NormalizedHue(360.0 - h);
      css +=
          "img:not(picture img):not(svg img), picture, "
          "video, canvas:not(picture canvas), svg[role=\"img\"], "
          "embed, object { filter: invert(1) hue-rotate(" +
          FormatNumber(k) + "deg) !important; }\n";
    }
  }
  if (font) {
    css +=
        "body, body *:not(script):not(style):not(code):not(pre):not(kbd):not("
        "samp):not(code *):not(pre *) { font-family: " +
        *font + " !important; }\n";
  }
  if (zoom) {
    css += "html { zoom: " + FormatNumber(*zoom) + " !important; }\n";
  }
  if (transform) {
    css +=
        "body, body *:not(input):not(textarea):not([contenteditable]):not(["
        "contenteditable] *) { text-transform: " +
        *transform + " !important; }\n";
    css +=
        "input, textarea, [contenteditable], [contenteditable] * { "
        "text-transform: none !important; }\n";
  }
  for (const Boost& boost : boosts) {
    if (!boost.custom_css.empty()) {
      css += boost.custom_css;
      css += "\n";
    }
  }
  std::set<std::string> seen;
  for (const Boost& boost : boosts) {
    for (const ZappedElement& zap : boost.zapped_elements) {
      const std::string selector(
          base::TrimWhitespaceASCII(zap.selector, base::TRIM_ALL));
      if (IsSafeSelector(selector) && seen.insert(selector).second) {
        css += selector + " { display: none !important; }\n";
      }
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
  // advanced.enableBoosts off: nothing applies (an empty payload removes
  // what a page already has).
  std::vector<Boost> boosts;
  if (global_enabled_) {
    boosts = EffectiveBoosts(tab_id, *profile, url);
  }
  // User JavaScript comes from stored Boosts only (a draft never runs JS).
  // The run-once key is the Boost id plus a hash of its source, so a color,
  // CSS or Zap save does not run the page's Boost JavaScript again; only a
  // changed script runs (once per document).
  base::ListValue scripts;
  for (const Boost& boost : boosts) {
    std::optional<Boost> stored = FindBoost(*profile, boost.id);
    if (stored && stored->enabled && !stored->custom_js.empty()) {
      scripts.Append(
          base::DictValue()
              .Set("id", stored->id + ":" +
                             base::NumberToString(static_cast<uint64_t>(
                                 std::hash<std::string>()(stored->custom_js))))
              .Set("source", stored->custom_js));
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
  const BoostColorAdjustment* color = EffectiveColor(boosts);
  base::Value payload(base::DictValue()
                          .Set("css", BuildStylesheet(boosts))
                          .Set("invert", color && color->invert)
                          .Set("scripts", std::move(scripts)));
  contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      FillTemplate(kApplierTemplate, payload), base::NullCallback(),
      kOpenWorldId);
  if (!boosts.empty()) {
    ++applied_count_;
  }
}

void OpenBoostController::RefreshTabs(
    const std::optional<ProfileID>& profile_id) {
  OpenTabBridge* bridge = service_->tab_bridge();
  if (!bridge) {
    return;
  }
  for (const auto& [tab_id, contents] : bridge->LoadedTabs()) {
    if (!profile_id ||
        model_util::ProfileOfNode(service_->model(), tab_id) == *profile_id) {
      ApplyToContents(tab_id, contents, /*refresh=*/true);
    }
  }
}

void OpenBoostController::NotifyBoostsChanged(const ProfileID& profile_id) {
  for (Observer& observer : observers_) {
    observer.OnBoostsChanged(profile_id);
  }
}

void OpenBoostController::NotifyZapState(const std::string& boost_id) {
  const bool armed = zap_ && zap_->boost_id == boost_id;
  const int count = ZapCount(boost_id);
  for (Observer& observer : observers_) {
    observer.OnZapStateChanged(armed, boost_id, count);
  }
}

void OpenBoostController::OnTabDocumentAvailable(
    const ItemID& tab_id,
    content::WebContents* contents) {
  // Settings may have flipped advanced.enableBoosts since the last page.
  if (BoostsGloballyEnabled() != global_enabled_) {
    OnBoostsPreferenceChanged();
    return;
  }
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

void OpenBoostController::OnTabContentsDetaching(
    const ItemID& tab_id,
    content::WebContents* contents) {
  if (zap_ && zap_->tab_id == tab_id) {
    CancelZap();
  }
  previews_.erase(tab_id);
  boosted_tabs_.erase(tab_id);
}

// --- Editing -----------------------------------------------------------------

void OpenBoostController::PreviewBoost(const ItemID& tab_id,
                                       const Boost& draft) {
  OpenTabBridge* bridge = service_->tab_bridge();
  content::WebContents* contents =
      bridge ? bridge->WebContentsForTab(tab_id) : nullptr;
  if (!contents) {
    return;
  }
  previews_[tab_id] = draft;
  ApplyToContents(tab_id, contents, /*refresh=*/true);
}

void OpenBoostController::EndPreview(const ItemID& tab_id) {
  if (!previews_.erase(tab_id)) {
    return;
  }
  OpenTabBridge* bridge = service_->tab_bridge();
  if (content::WebContents* contents =
          bridge ? bridge->WebContentsForTab(tab_id) : nullptr) {
    ApplyToContents(tab_id, contents, /*refresh=*/true);
  }
}

void OpenBoostController::SaveBoost(const ProfileID& profile_id,
                                    const Boost& boost,
                                    SaveCallback done) {
  ProfileServices* ps = service_->ProfileServicesFor(profile_id);
  if (!ps) {
    if (done) {
      std::move(done).Run(std::nullopt);
    }
    return;
  }
  Boost pending = boost;
  if (pending.id.empty()) {
    pending.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  }
  pending.profile_id = profile_id;
  // Optimistic cache update: pages and observers follow at once, with no
  // flash back to the old Boost while the store writes.
  std::vector<Boost>& cached = boosts_[profile_id];
  auto it = std::find_if(cached.begin(), cached.end(),
                         [&](const Boost& b) { return b.id == pending.id; });
  if (it != cached.end()) {
    pending.zapped_elements = it->zapped_elements;
    *it = pending;
  } else {
    cached.push_back(pending);
  }
  std::erase_if(previews_, [&](const auto& entry) {
    return entry.second.id == pending.id;
  });
  ++pending_saves_[pending.id];
  RefreshTabs(profile_id);
  NotifyBoostsChanged(profile_id);

  // Zaps change only through AppendZap/RemoveZap: the store keeps the Zaps
  // it holds, so an editor draft never drops a Zap saved meanwhile.
  RunOnStore(
      ps->boosts,
      base::BindOnce(
          [](Boost boost, BoostStore* store) {
            if (std::optional<Boost> current = store->GetBoost(boost.id)) {
              boost.zapped_elements = current->zapped_elements;
            }
            return store->Upsert(std::move(boost));
          },
          std::move(pending)),
      base::BindOnce(
          [](base::WeakPtr<OpenBoostController> self, ProfileID profile_id,
             SaveCallback done, Boost saved) {
            if (self) {
              // Only the newest save's reply replaces the cache (an older
              // reply would flash the page back to an earlier edit). Zaps
              // stay as cached: every Zap edit updates the cache first.
              auto pending = self->pending_saves_.find(saved.id);
              const bool newest = pending == self->pending_saves_.end() ||
                                  --pending->second <= 0;
              if (pending != self->pending_saves_.end() && newest) {
                self->pending_saves_.erase(pending);
              }
              Boost* cached = self->MutableBoost(profile_id, saved.id);
              if (newest && cached) {
                saved.zapped_elements = cached->zapped_elements;
                *cached = saved;
                self->RefreshTabs(profile_id);
                self->NotifyBoostsChanged(profile_id);
              }
            }
            if (done) {
              std::move(done).Run(std::move(saved));
            }
          },
          weak_factory_.GetWeakPtr(), profile_id, std::move(done)));
}

void OpenBoostController::DeleteBoost(const ProfileID& profile_id,
                                      const std::string& boost_id) {
  if (zap_ && zap_->boost_id == boost_id) {
    CancelZap();
  }
  std::erase_if(boosts_[profile_id],
                [&](const Boost& b) { return b.id == boost_id; });
  std::erase_if(previews_, [&](const auto& entry) {
    return entry.second.id == boost_id;
  });
  RefreshTabs(profile_id);
  NotifyBoostsChanged(profile_id);
  ProfileServices* ps = service_->ProfileServicesFor(profile_id);
  if (!ps) {
    return;
  }
  RunOnStore(ps->boosts,
             base::BindOnce(
                 [](std::string id, BoostStore* store) {
                   return store->Delete(id);
                 },
                 boost_id),
             base::BindOnce(
                 [](base::WeakPtr<OpenBoostController> self,
                    ProfileID profile_id, bool deleted) {
                   if (self && !deleted) {
                     self->ReloadBoosts(profile_id);
                   }
                 },
                 weak_factory_.GetWeakPtr(), profile_id));
}

// --- Zap ---------------------------------------------------------------------

bool OpenBoostController::StartZap(const std::string& boost_id,
                                   std::string* message) {
  OpenTabBridge* bridge = service_->tab_bridge();
  std::optional<ItemID> tab_id =
      bridge ? bridge->ActiveTabId() : std::nullopt;
  if (!tab_id) {
    if (message) {
      *message = "Open a page to zap elements on it.";
    }
    return false;
  }
  return StartZapForTab(*tab_id, boost_id, message);
}

bool OpenBoostController::StartZapForTab(const ItemID& tab_id,
                                         const std::string& boost_id,
                                         std::string* message) {
  std::string ignored;
  if (!message) {
    message = &ignored;
  }
  global_enabled_ = BoostsGloballyEnabled();
  if (!global_enabled_) {
    *message = "Boosts are turned off in Settings.";
    return false;
  }
  OpenTabBridge* bridge = service_->tab_bridge();
  content::WebContents* contents =
      bridge ? bridge->WebContentsForTab(tab_id) : nullptr;
  if (!contents || contents->GetBrowserContext()->IsOffTheRecord() ||
      !contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
    *message = "Open a page to zap elements on it.";
    return false;
  }
  std::optional<ProfileID> profile =
      model_util::ProfileOfNode(service_->model(), tab_id);
  std::optional<Boost> boost =
      profile ? FindBoost(*profile, boost_id) : std::nullopt;
  const GURL url = contents->GetLastCommittedURL();
  if (!boost || !url.SchemeIsHTTPOrHTTPS() ||
      !HostMatches(std::string(url.host()), boost->host_pattern)) {
    *message = "This tab is not a page of this Boost's site.";
    return false;
  }
  if (boost->zapped_elements.size() >= kMaxZaps) {
    *message = "This Boost has the most Zaps it can hold.";
    return false;
  }
  if (zap_ && zap_->boost_id == boost_id && zap_->tab_id == tab_id) {
    *message = "Click an element to hide it. Press Esc to stop.";
    return true;
  }
  CancelZap();
  zap_ = ZapSession{boost_id, *profile, tab_id,
                    base::UnguessableToken::Create(), {}};
  base::Value session(base::DictValue()
                          .Set("boostId", boost_id)
                          .Set("nonce", zap_->nonce.ToString()));
  contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      FillTemplate(kZapPickerTemplate, session), base::NullCallback(),
      kOpenWorldId);
  poll_in_flight_ = false;
  zap_poll_.Start(FROM_HERE, kZapPollInterval,
                  base::BindRepeating(&OpenBoostController::PollZap,
                                      weak_factory_.GetWeakPtr()));
  NotifyZapState(boost_id);
  *message = "Click an element to hide it. Press Esc to stop.";
  return true;
}

std::optional<std::string> OpenBoostController::zap_boost_id() const {
  if (!zap_) {
    return std::nullopt;
  }
  return zap_->boost_id;
}

void OpenBoostController::CancelZap() {
  zap_poll_.Stop();
  poll_in_flight_ = false;
  if (!zap_) {
    return;
  }
  const ZapSession session = *zap_;
  zap_.reset();
  if (OpenTabBridge* bridge = service_->tab_bridge()) {
    if (content::WebContents* contents =
            bridge->WebContentsForTab(session.tab_id);
        contents && contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
      // Collect the picks made since the last poll, then tear down.
      contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
          kZapDrainScript,
          base::BindOnce(&OpenBoostController::OnZapPicks,
                         weak_factory_.GetWeakPtr(), session),
          kOpenWorldId);
    }
  }
  NotifyZapState(session.boost_id);
}

void OpenBoostController::PollZap() {
  if (!zap_) {
    zap_poll_.Stop();
    return;
  }
  if (poll_in_flight_) {
    return;
  }
  OpenTabBridge* bridge = service_->tab_bridge();
  content::WebContents* contents =
      bridge ? bridge->WebContentsForTab(zap_->tab_id) : nullptr;
  if (!contents || !contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
    CancelZap();
    return;
  }
  poll_in_flight_ = true;
  contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
      kZapTakeScript,
      base::BindOnce(&OpenBoostController::OnZapPicks,
                     weak_factory_.GetWeakPtr(), *zap_),
      kOpenWorldId);
}

void OpenBoostController::OnZapPicks(ZapSession session, base::Value result) {
  // |session| is the browser's own copy, bound when the script was sent: the
  // armed session, or one that just ended (CancelZap drains its last
  // picks). Each pick must carry that session's Boost id and nonce.
  const bool live_session = zap_ && zap_->nonce == session.nonce;
  if (live_session) {
    poll_in_flight_ = false;
  }
  if (!result.is_list()) {
    return;
  }
  const std::string nonce_text = session.nonce.ToString();
  const std::string& boost_id = session.boost_id;
  const ProfileID& profile_id = session.profile_id;
  Boost* boost = MutableBoost(profile_id, boost_id);
  if (!boost) {
    return;
  }
  ProfileServices* ps = service_->ProfileServicesFor(profile_id);
  bool cancelled = false;
  bool changed = false;
  size_t handled = 0;
  for (const base::Value& item : result.GetList()) {
    if (++handled > kMaxPicksPerPoll || !item.is_dict()) {
      break;
    }
    const base::DictValue& pick = item.GetDict();
    const std::string* pick_boost = pick.FindString("boostId");
    const std::string* pick_nonce = pick.FindString("nonce");
    // A reply that does not carry this session's pair is ignored: a page
    // script cannot see world 6 state, and old sessions' nonces expire.
    if (!pick_boost || !pick_nonce || *pick_boost != boost_id ||
        *pick_nonce != nonce_text) {
      continue;
    }
    if (pick.FindBool("cancelled").value_or(false)) {
      cancelled = true;
      continue;
    }
    const std::string* raw_selector = pick.FindString("selector");
    const std::string* label = pick.FindString("label");
    const std::optional<double> count = pick.FindDouble("count");
    if (!raw_selector || !count || *count < 1) {
      continue;
    }
    const std::string selector(
        base::TrimWhitespaceASCII(*raw_selector, base::TRIM_ALL));
    if (!IsSafeSelector(selector) ||
        boost->zapped_elements.size() >= kMaxZaps ||
        std::any_of(boost->zapped_elements.begin(),
                    boost->zapped_elements.end(),
                    [&](const ZappedElement& z) {
                      return z.selector == selector;
                    })) {
      continue;
    }
    std::string safe_label = label ? label->substr(0, kMaxLabelBytes) : "";
    if (!base::IsStringUTF8(safe_label)) {
      safe_label.clear();
    }
    ZappedElement zap(base::Uuid::GenerateRandomV4().AsLowercaseString(),
                      selector, std::move(safe_label));
    boost->zapped_elements.push_back(zap);
    if (live_session) {
      zap_->picked.push_back(selector);
    }
    changed = true;
    if (ps) {
      RunOnStore(ps->boosts,
                 base::BindOnce(
                     [](std::string id, ZappedElement zap, BoostStore* store) {
                       return store->AppendZap(id, std::move(zap));
                     },
                     boost_id, std::move(zap)),
                 base::BindOnce(&OpenBoostController::OnZapAppended,
                                weak_factory_.GetWeakPtr(), profile_id,
                                boost_id));
    }
  }
  if (changed) {
    // Every page of the site gets the new Zaps (the picked page already
    // hid them live).
    RefreshTabs(profile_id);
    NotifyBoostsChanged(profile_id);
    NotifyZapState(boost_id);
  }
  if (cancelled && live_session) {
    CancelZap();
  }
}

void OpenBoostController::OnZapAppended(ProfileID profile_id,
                                        std::string boost_id,
                                        bool ok) {
  // A refused append (duplicate, cap, Boost deleted meanwhile): resync the
  // cache with the store.
  if (!ok) {
    ReloadBoosts(profile_id);
  }
}

void OpenBoostController::RunInZapPage(const std::u16string& script) {
  OpenTabBridge* bridge = service_->tab_bridge();
  if (!bridge) {
    return;
  }
  // Only documents that already run world 6 (Boosted pages, the Zap page):
  // other pages never get an isolated world.
  for (const auto& [tab_id, contents] : bridge->LoadedTabs()) {
    const bool zap_page = zap_ && zap_->tab_id == tab_id;
    if ((zap_page || boosted_tabs_.contains(tab_id)) && contents &&
        contents->GetPrimaryMainFrame()->IsRenderFrameLive()) {
      contents->GetPrimaryMainFrame()->ExecuteJavaScriptInIsolatedWorld(
          script, base::NullCallback(), kOpenWorldId);
    }
  }
}

bool OpenBoostController::UndoLastZap(const std::string& boost_id) {
  std::optional<ProfileID> profile_id = ProfileOfBoost(boost_id);
  Boost* boost = profile_id ? MutableBoost(*profile_id, boost_id) : nullptr;
  if (!boost || boost->zapped_elements.empty()) {
    return false;
  }
  const std::string selector = boost->zapped_elements.back().selector;
  boost->zapped_elements.pop_back();
  if (zap_ && zap_->boost_id == boost_id && !zap_->picked.empty() &&
      zap_->picked.back() == selector) {
    zap_->picked.pop_back();
  }
  // Forget the live in-page hide first, then re-apply without the Zap.
  std::string quoted;
  base::EscapeJSONString(selector, /*put_in_quotes=*/true, &quoted);
  RunInZapPage(base::UTF8ToUTF16(
      "window.__openZapLive && window.__openZapLive.forget(" + quoted + ");"));
  RefreshTabs(*profile_id);
  NotifyBoostsChanged(*profile_id);
  NotifyZapState(boost_id);
  if (ProfileServices* ps = service_->ProfileServicesFor(*profile_id)) {
    RunOnStore(ps->boosts,
               base::BindOnce(
                   [](std::string id, std::string selector,
                      BoostStore* store) {
                     return store->RemoveZap(id, selector);
                   },
                   boost_id, selector),
               base::BindOnce(&OpenBoostController::OnZapAppended,
                              weak_factory_.GetWeakPtr(), *profile_id,
                              boost_id));
  }
  return true;
}

bool OpenBoostController::ClearAllZaps(const std::string& boost_id) {
  std::optional<ProfileID> profile_id = ProfileOfBoost(boost_id);
  Boost* boost = profile_id ? MutableBoost(*profile_id, boost_id) : nullptr;
  if (!boost || boost->zapped_elements.empty()) {
    return false;
  }
  boost->zapped_elements.clear();
  if (zap_ && zap_->boost_id == boost_id) {
    zap_->picked.clear();
  }
  RunInZapPage(u"window.__openZapLive && window.__openZapLive.forgetAll();");
  RefreshTabs(*profile_id);
  NotifyBoostsChanged(*profile_id);
  NotifyZapState(boost_id);
  if (ProfileServices* ps = service_->ProfileServicesFor(*profile_id)) {
    RunOnStore(ps->boosts,
               base::BindOnce(
                   [](std::string id, BoostStore* store) {
                     std::optional<Boost> current = store->GetBoost(id);
                     if (!current) {
                       return false;
                     }
                     current->zapped_elements.clear();
                     store->Upsert(std::move(*current));
                     return true;
                   },
                   boost_id),
               base::BindOnce(&OpenBoostController::OnZapAppended,
                              weak_factory_.GetWeakPtr(), *profile_id,
                              boost_id));
  }
  return true;
}

int OpenBoostController::ZapCount(const std::string& boost_id) const {
  for (const auto& [profile_id, boosts] : boosts_) {
    for (const Boost& boost : boosts) {
      if (boost.id == boost_id) {
        return static_cast<int>(boost.zapped_elements.size());
      }
    }
  }
  return 0;
}

base::DictValue OpenBoostController::StateForAutomation() const {
  base::DictValue state;
  state.Set("zapArmed", zap_.has_value());
  state.Set("zapBoostId", zap_ ? zap_->boost_id : std::string());
  state.Set("zapPicked",
            zap_ ? static_cast<int>(zap_->picked.size()) : 0);
  state.Set("globalEnabled", global_enabled_);
  state.Set("previews", static_cast<int>(previews_.size()));
  state.Set("applied", applied_count_);
  base::DictValue counts;
  for (const auto& [profile_id, boosts] : boosts_) {
    counts.Set(profile_id, static_cast<int>(boosts.size()));
  }
  state.Set("boostsByProfile", std::move(counts));
  return state;
}

}  // namespace open_unified
