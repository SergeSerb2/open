// Copyright 2026 The Open Authors. All rights reserved.
// BoostStore, SiteMatch, CSS generator, and Zap coordinator implementation.

#include "open_unified/core/boosts/boost_store.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <set>
#include <sstream>
#include <tuple>
#include <utility>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/logging.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/time/time.h"
#include "base/uuid.h"
#include "url/gurl.h"

namespace open_unified {

namespace {

constexpr char kBoostsDirName[] = "Boosts";
constexpr char kBoostsFileName[] = "boosts.json";
constexpr size_t kMaxBoostsFileBytes = 32 * 1024 * 1024;

double NowEpochSec() {
  return base::Time::Now().InSecondsFSinceUnixEpoch();
}

std::string FormatCssNumber(double value) {
  char buf[64]{};
  std::snprintf(buf, sizeof(buf), "%.4f", value);
  std::string s(buf);
  if (s.find('.') != std::string::npos) {
    while (!s.empty() && s.back() == '0') s.pop_back();
    if (!s.empty() && s.back() == '.') s.pop_back();
  }
  return s == "-0" ? "0" : s;
}

bool IsSafeFontFamily(std::string_view font) {
  std::string_view trimmed = base::TrimWhitespaceASCII(font, base::TRIM_ALL);
  if (trimmed.empty()) return false;
  return trimmed.find_first_of(";{}\"\r\n") == std::string_view::npos;
}

bool IsAllowedTransform(std::string_view t) {
  return t == "none" || t == "uppercase" || t == "lowercase" ||
         t == "capitalize";
}

uint64_t Fnv1a64(std::string_view data) {
  uint64_t hash = 14695981039346656037ULL;
  for (unsigned char b : data) {
    hash ^= static_cast<uint64_t>(b);
    hash *= 1099511628211ULL;
  }
  return hash;
}

std::string Hex64(uint64_t v) {
  char buf[17]{};
  std::snprintf(buf, sizeof(buf), "%016llx",
                static_cast<unsigned long long>(v));
  return std::string(buf);
}

bool IsColorIdentity(const BoostColorAdjustment& c) {
  if (!c.enabled) return true;
  double h = std::isfinite(c.hue_degrees) ? std::fmod(c.hue_degrees, 360.0) : 0.0;
  if (h < 0.0) h += 360.0;
  double s = std::isnan(c.saturation) ? 1.0 : std::clamp(c.saturation, 0.0, 3.0);
  double b = std::isnan(c.lightness) ? 1.0
                                     : std::clamp(1.0 + c.lightness, 0.0, 3.0);
  double ct = std::isnan(c.contrast) ? 1.0 : std::clamp(c.contrast, 0.0, 3.0);
  double inv = c.invert ? 1.0 : 0.0;
  return std::fabs(h) < 1e-9 && std::fabs(s - 1.0) < 1e-9 &&
         std::fabs(b - 1.0) < 1e-9 && std::fabs(ct - 1.0) < 1e-9 &&
         std::fabs(inv) < 1e-9;
}

std::string EncodeJsonString(const base::DictValue& dict) {
  std::string out;
  base::JSONWriter::Write(dict, &out);
  return out;
}

bool HasOnlyAllowedKeys(const base::DictValue& dict,
                        const std::set<std::string_view>& allowed) {
  for (const auto [k, _] : dict) {
    if (!allowed.contains(k)) return false;
  }
  return true;
}

// Built-in isolated-world v1 Boost applier runtime (fallback when external
// boost-applier.js file is not provided on disk).
constexpr char kBuiltinBoostApplierJs[] = R"JS(
(function() {
  "use strict";
  if (window.__openBoosts && window.__openBoosts.version === 1) return;
  const bridge = window.__open || (window.__open = { postMessage() {} });
  if (!bridge._handlers) {
    bridge._handlers = [];
    const prior = bridge.receive;
    bridge.receive = function(msg) {
      if (prior) prior.call(bridge, msg);
      for (const h of bridge._handlers) { try { h(msg); } catch (_) {} }
    };
  }
  const STYLE_ID = "open-boosts-style";
  let current = null, styleEl = null, sheet = null, cssText = "", observer = null;
  function clear() {
    current = null; cssText = "";
    if (observer) { observer.disconnect(); observer = null; }
    if (styleEl) { styleEl.remove(); styleEl = null; }
    if (sheet) {
      document.adoptedStyleSheets = document.adoptedStyleSheets.filter(s => s !== sheet);
      sheet = null;
    }
  }
  function apply(plan) {
    if (!plan || !Array.isArray(plan.boosts) || !plan.boosts.length) { clear(); return; }
    if (current && current.planID === plan.planID) return;
    clear();
    cssText = plan.generatedCSS || "";
    if (!cssText.trim()) return;
    current = { planID: plan.planID, boostIDs: plan.boosts.map(b => b.boostID) };
    styleEl = document.createElement("style");
    styleEl.id = STYLE_ID;
    styleEl.textContent = cssText;
    (document.documentElement || document.head).appendChild(styleEl);
    if (!styleEl.sheet) {
      try {
        sheet = new CSSStyleSheet();
        sheet.replaceSync(cssText);
        document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
      } catch (_) { sheet = null; }
    }
    observer = new MutationObserver(() => {
      if (current && styleEl && !document.getElementById(STYLE_ID) && document.documentElement) {
        document.documentElement.appendChild(styleEl);
      }
    });
    if (document.documentElement) {
      observer.observe(document.documentElement, { childList: true, subtree: true });
    }
    try { window.__open.postMessage("boost:applied", { planID: plan.planID }); } catch (_) {}
  }
  window.__openBoosts = { version: 1, apply, clear, state: () => current };
  bridge._handlers.push(msg => {
    if (!msg || msg.v !== 1) return;
    if (msg.type === "boost:apply") apply(msg.payload);
    else if (msg.type === "boost:clear") clear();
  });
})();
)JS";

// Built-in isolated-world v1 Zap picker runtime fallback.
constexpr char kBuiltinZapPickerJs[] = R"JS(
(function() {
  "use strict";
  if (window.__openZap && window.__openZap.version === 1) return;
  const bridge = window.__open || (window.__open = { postMessage() {} });
  if (!bridge._handlers) {
    bridge._handlers = [];
    const prior = bridge.receive;
    bridge.receive = function(msg) {
      if (prior) prior.call(bridge, msg);
      for (const h of bridge._handlers) { try { h(msg); } catch (_) {} }
    };
  }
  let active = false, boostID = null, sessionNonce = null, mode = "zap", host = null;
  function post(type, payload) {
    try { window.__open.postMessage(type, Object.assign({}, payload, { boostID, sessionNonce })); } catch (_) {}
  }
  function selectorFor(el) {
    if (el.id) return "#" + CSS.escape(el.id);
    const parts = [];
    let cur = el;
    while (cur && cur.nodeType === 1 && parts.length < 4) {
      let s = cur.tagName.toLowerCase();
      if (cur.classList && cur.classList.length) s += "." + CSS.escape(cur.classList[0]);
      parts.unshift(s);
      cur = cur.parentElement;
    }
    return parts.join(" > ");
  }
  function onClick(e) {
    if (!active) return;
    e.preventDefault(); e.stopPropagation();
    const sel = selectorFor(e.target);
    const matches = document.querySelectorAll(sel).length;
    if (mode === "select") {
      post("picker:selected", { selector: sel, matches });
      exit("selected");
    } else {
      post("zap:committed", { selector: sel, label: e.target.tagName.toLowerCase(), matches, inShadowRoot: false });
    }
  }
  function onKey(e) { if (active && e.key === "Escape") exit("esc"); }
  function enter(p) {
    if (!p || !p.boostID || !p.sessionNonce) return;
    active = true; boostID = p.boostID; sessionNonce = p.sessionNonce; mode = p.mode || "zap";
    document.addEventListener("click", onClick, true);
    document.addEventListener("keydown", onKey, true);
    post("picker:ready", {});
  }
  function exit(reason) {
    if (!active) return;
    active = false;
    document.removeEventListener("click", onClick, true);
    document.removeEventListener("keydown", onKey, true);
    if (host) { host.remove(); host = null; }
    post("picker:exited", { reason: reason || "native" });
  }
  window.__openZap = { version: 1, isActive: () => active, isObserving: () => active };
  bridge._handlers.push(msg => {
    if (!msg || msg.v !== 1) return;
    if (msg.type === "zap:enter") enter(msg.payload);
    else if (msg.type === "zap:exit") exit("native");
  });
})();
)JS";

}  // namespace

// --- SiteMatch ---

// static
bool SiteMatch::IsIpAddress(std::string_view host) {
  if (host.find(':') != std::string_view::npos ||
      (!host.empty() && host.front() == '[')) {
    return true;
  }
  int dots = 0;
  size_t start = 0;
  for (size_t i = 0; i <= host.size(); ++i) {
    if (i == host.size() || host[i] == '.') {
      if (i == start) return false;
      for (size_t j = start; j < i; ++j) {
        if (host[j] < '0' || host[j] > '9') return false;
      }
      if (i < host.size()) ++dots;
      start = i + 1;
    }
  }
  return dots == 3;
}

// static
SiteMatch SiteMatch::Normalized(std::string_view raw_domain,
                                std::optional<std::string_view> path_prefix) {
  std::string host =
      base::ToLowerASCII(base::TrimWhitespaceASCII(raw_domain, base::TRIM_ALL));
  if (base::StartsWith(host, "*.")) {
    host.erase(0, 2);
  }
  if (size_t scheme = host.find("://"); scheme != std::string::npos) {
    host.erase(0, scheme + 3);
  }
  if (size_t sep = host.find_first_of("/?#"); sep != std::string::npos) {
    host.erase(sep);
  }
  if (!host.empty() && host.front() == '[') {
    size_t close = host.find(']');
    if (close != std::string::npos) {
      host = host.substr(1, close - 1);
    }
  } else if (std::count(host.begin(), host.end(), ':') < 2) {
    if (size_t colon = host.find(':'); colon != std::string::npos) {
      host.erase(colon);
    }
  }
  while (!host.empty() && host.back() == '.') {
    host.pop_back();
  }

  SiteMatch match;
  match.domain = std::move(host);
  if (!match.domain.empty() && path_prefix && !path_prefix->empty()) {
    std::string cleaned;
    size_t pos = 0;
    while (pos < path_prefix->size()) {
      while (pos < path_prefix->size() && (*path_prefix)[pos] == '/') ++pos;
      size_t end = path_prefix->find('/', pos);
      if (end == std::string_view::npos) end = path_prefix->size();
      if (end > pos) {
        cleaned.push_back('/');
        cleaned.append(path_prefix->substr(pos, end - pos));
      }
      pos = end;
    }
    if (!cleaned.empty()) {
      match.path_prefix = std::move(cleaned);
    }
  }
  return match;
}

bool SiteMatch::Matches(std::string_view host,
                        std::string_view encoded_path) const {
  if (domain.empty()) return false;
  std::string norm_host = base::ToLowerASCII(host);
  if (!norm_host.empty() && norm_host.back() == '.') norm_host.pop_back();
  if (norm_host.size() >= 2 && norm_host.front() == '[' &&
      norm_host.back() == ']') {
    norm_host = norm_host.substr(1, norm_host.size() - 2);
  }

  bool host_match = (norm_host == domain);
  if (!host_match && !IsIpAddress(norm_host) &&
      norm_host.size() > domain.size() + 1) {
    host_match =
        base::EndsWith(norm_host, "." + domain, base::CompareCase::SENSITIVE);
  }
  if (!host_match) return false;
  if (!path_prefix) return true;
  return encoded_path == *path_prefix ||
         base::StartsWith(encoded_path, *path_prefix + "/");
}

bool SiteMatch::MatchesUrl(std::string_view url) const {
  GURL gurl(url);
  if (!gurl.is_valid() || !gurl.SchemeIsHTTPOrHTTPS() || gurl.host().empty()) {
    return false;
  }
  std::string path = gurl.path().empty() ? "/" : std::string(gurl.path());
  return Matches(gurl.host(), path);
}

// --- BoostInjectionPlan ---

std::string BoostInjectionPlan::ToWirePayloadJson() const {
  base::DictValue root;
  root.Set("planID", plan_id);
  root.Set("generatedCSS", generated_css);
  root.Set("js", combined_js);

  base::ListValue wire_boosts;
  const BoostColorAdjustment* active_color = nullptr;
  std::optional<std::string> active_font;
  std::optional<double> active_zoom;
  std::optional<std::string> active_transform;

  for (const auto& b : matched_boosts) {
    base::DictValue bd;
    bd.Set("boostID", b.id);
    bd.Set("css", b.custom_css);
    base::ListValue zaps;
    for (const auto& z : b.zapped_elements) {
      zaps.Append(z.selector);
    }
    bd.Set("zaps", std::move(zaps));
    wire_boosts.Append(std::move(bd));

    if (!IsColorIdentity(b.color)) active_color = &b.color;
    if (b.font_family && IsSafeFontFamily(*b.font_family)) {
      active_font = *b.font_family;
    }
    if (std::fabs(b.text_zoom - 1.0) > 1e-6) {
      active_zoom = std::clamp(b.text_zoom, 0.5, 2.0);
    }
    if (IsAllowedTransform(b.text_transform)) {
      active_transform = b.text_transform;
    }
  }
  root.Set("boosts", std::move(wire_boosts));
  if (active_color) {
    base::DictValue c;
    double h = std::fmod(active_color->hue_degrees, 360.0);
    if (h < 0.0) h += 360.0;
    c.Set("hueRotateDegrees", h);
    c.Set("saturation", std::clamp(active_color->saturation, 0.0, 3.0));
    c.Set("brightness", std::clamp(1.0 + active_color->lightness, 0.0, 3.0));
    c.Set("contrast", std::clamp(active_color->contrast, 0.0, 3.0));
    c.Set("invert", active_color->invert ? 1.0 : 0.0);
    root.Set("colorAdjustment", std::move(c));
  } else {
    root.Set("colorAdjustment", base::Value());
  }
  if (active_font) root.Set("fontFamily", *active_font);
  else root.Set("fontFamily", base::Value());
  if (active_zoom) root.Set("textZoom", *active_zoom);
  else root.Set("textZoom", base::Value());
  if (active_transform) root.Set("textTransform", *active_transform);
  else root.Set("textTransform", base::Value());
  return EncodeJsonString(root);
}

// --- BoostStore ---

BoostStore::BoostStore(ProfileID profile_id, base::FilePath profile_dir)
    : profile_id_(std::move(profile_id)),
      file_path_(profile_dir.AppendASCII(kBoostsDirName)
                     .AppendASCII(kBoostsFileName)) {}

BoostStore::BoostStore(std::filesystem::path json_path)
    : profile_id_("default"),
      file_path_(base::FilePath::FromUTF8Unsafe(json_path.u8string().empty()
                                                    ? json_path.string()
                                                    : json_path.string())) {
  Load();
}

BoostStore::~BoostStore() = default;

// static
Boost BoostStore::NormalizeBoost(Boost b, const ProfileID& profile_id) {
  if (b.id.empty()) {
    b.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  }
  b.profile_id = profile_id;
  b.host_pattern = SiteMatch::Normalized(b.host_pattern).domain;
  b.text_zoom = std::isnan(b.text_zoom) ? 1.0 : std::clamp(b.text_zoom, 0.5, 2.0);
  if (!b.text_transform.empty() && !IsAllowedTransform(b.text_transform)) {
    b.text_transform.clear();
  }
  if (b.font_family &&
      base::TrimWhitespaceASCII(*b.font_family, base::TRIM_ALL).empty()) {
    b.font_family.reset();
  }
  std::vector<ZappedElement> deduped;
  std::set<std::string> seen;
  for (auto& z : b.zapped_elements) {
    std::string sel(base::TrimWhitespaceASCII(z.selector, base::TRIM_ALL));
    if (sel.empty() || !seen.insert(sel).second) continue;
    z.selector = std::move(sel);
    if (z.id.empty()) {
      z.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
    }
    deduped.push_back(std::move(z));
  }
  b.zapped_elements = std::move(deduped);
  return b;
}

std::vector<Boost> BoostStore::Load() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (retired_) return {};
  if (!base::PathExists(file_path_)) {
    boosts_.clear();
    loaded_schema_version_ = 1;
    return {};
  }

  std::string raw;
  bool ok = base::ReadFileToStringWithMaxSize(file_path_, &raw,
                                              kMaxBoostsFileBytes);
  auto dict = ok ? base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC)
                 : std::nullopt;
  const base::ListValue* list = dict ? dict->FindList("boosts") : nullptr;
  if (!dict || !list) {
    // Move corrupt file aside without losing user data.
    base::FilePath aside = file_path_.AddExtensionASCII(
        "corrupt-" +
        base::NumberToString(static_cast<int64_t>(NowEpochSec())));
    base::Move(file_path_, aside);
    boosts_.clear();
    loaded_schema_version_ = 1;
    return {};
  }

  loaded_schema_version_ = std::max(1, dict->FindInt("schemaVersion").value_or(1));
  boosts_.clear();
  for (const auto& item : *list) {
    const auto* bd = item.GetIfDict();
    if (!bd) continue;
    Boost b;
    if (const auto* s = bd->FindString("id")) b.id = *s;
    if (const auto* s = bd->FindString("name")) b.name = *s;
    if (const auto* s = bd->FindString("hostPattern")) {
      b.host_pattern = *s;
    } else if (const auto* sm = bd->FindDict("siteMatch")) {
      if (const auto* d = sm->FindString("domain")) b.host_pattern = *d;
    }
    b.enabled = bd->FindBool("isEnabled")
                    .value_or(bd->FindBool("enabled").value_or(true));
    if (const auto* s = bd->FindString("css")) b.custom_css = *s;
    if (const auto* s = bd->FindString("js")) b.custom_js = *s;
    if (const auto* c = bd->FindDict("colorAdjustment")) {
      b.color.enabled = c->FindBool("enabled").value_or(true);
      b.color.hue_degrees = c->FindDouble("hueRotateDegrees").value_or(0.0);
      b.color.saturation = c->FindDouble("saturation").value_or(1.0);
      b.color.lightness = c->FindDouble("brightness").value_or(1.0) - 1.0;
      b.color.contrast = c->FindDouble("contrast").value_or(1.0);
      b.color.invert = c->FindDouble("invert").value_or(0.0) >= 0.5;
    }
    if (const auto* s = bd->FindString("fontFamily")) b.font_family = *s;
    b.text_zoom = bd->FindDouble("textZoom").value_or(1.0);
    if (const auto* s = bd->FindString("textTransform")) b.text_transform = *s;
    if (const auto* zaps = bd->FindList("zaps")) {
      for (const auto& zv : *zaps) {
        const auto* zd = zv.GetIfDict();
        if (!zd) continue;
        ZappedElement z;
        if (const auto* s = zd->FindString("id")) z.id = *s;
        if (const auto* s = zd->FindString("selector")) z.selector = *s;
        if (const auto* s = zd->FindString("label")) z.label = *s;
        if (!z.selector.empty()) b.zapped_elements.push_back(std::move(z));
      }
    }
    b.created_at = bd->FindDouble("createdAt").value_or(0.0);
    b.modified_at = bd->FindDouble("updatedAt").value_or(b.created_at);
    b = NormalizeBoost(std::move(b), profile_id_);
    boosts_[b.id] = std::move(b);
  }

  std::vector<Boost> result;
  result.reserve(boosts_.size());
  for (const auto& [_, b] : boosts_) result.push_back(b);
  std::sort(result.begin(), result.end(), [](const Boost& a, const Boost& b) {
    return std::tie(a.name, a.id) < std::tie(b.name, b.id);
  });
  return result;
}

std::vector<Boost> BoostStore::AllBoosts() const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (retired_) return {};
  std::vector<Boost> result;
  result.reserve(boosts_.size());
  for (const auto& [_, b] : boosts_) result.push_back(b);
  std::sort(result.begin(), result.end(), [](const Boost& a, const Boost& b) {
    return std::tie(a.name, a.id) < std::tie(b.name, b.id);
  });
  return result;
}

std::optional<Boost> BoostStore::GetBoost(const std::string& boost_id) const {
  std::lock_guard<std::mutex> lock(mutex_);
  if (retired_) return std::nullopt;
  auto it = boosts_.find(boost_id);
  return it == boosts_.end() ? std::nullopt : std::make_optional(it->second);
}

Boost BoostStore::Upsert(Boost boost) {
  std::lock_guard<std::mutex> lock(mutex_);
  double now = NowEpochSec();
  if (boost.created_at == 0.0) boost.created_at = now;
  boost.modified_at = now;
  boost = NormalizeBoost(std::move(boost), profile_id_);
  if (!retired_) {
    boosts_[boost.id] = boost;
    WriteLocked();
  }
  return boost;
}

bool BoostStore::Delete(const std::string& boost_id) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (retired_) return false;
  if (boosts_.erase(boost_id) == 0) return false;
  WriteLocked();
  return true;
}

bool BoostStore::SetEnabled(const std::string& boost_id, bool enabled) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (retired_) return false;
  auto it = boosts_.find(boost_id);
  if (it == boosts_.end() || it->second.enabled == enabled) return false;
  it->second.enabled = enabled;
  it->second.modified_at = NowEpochSec();
  WriteLocked();
  return true;
}

bool BoostStore::AppendZap(const std::string& boost_id, ZappedElement zap) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (retired_) return false;
  auto it = boosts_.find(boost_id);
  if (it == boosts_.end()) return false;
  std::string sel(base::TrimWhitespaceASCII(zap.selector, base::TRIM_ALL));
  if (sel.empty() || sel.size() > kZapMaxSelectorBytes ||
      zap.label.size() > kZapMaxLabelBytes ||
      it->second.zapped_elements.size() >= kZapMaxEntriesPerBoost) {
    return false;
  }
  for (const auto& existing : it->second.zapped_elements) {
    if (existing.selector == sel) return false;
  }
  zap.selector = std::move(sel);
  if (zap.id.empty()) {
    zap.id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  }
  it->second.zapped_elements.push_back(std::move(zap));
  it->second.modified_at = NowEpochSec();
  WriteLocked();
  return true;
}

bool BoostStore::RemoveZap(const std::string& boost_id,
                           std::string_view selector) {
  std::lock_guard<std::mutex> lock(mutex_);
  if (retired_) return false;
  auto it = boosts_.find(boost_id);
  if (it == boosts_.end()) return false;
  std::string sel(base::TrimWhitespaceASCII(selector, base::TRIM_ALL));
  size_t before = it->second.zapped_elements.size();
  std::erase_if(it->second.zapped_elements,
                [&](const ZappedElement& z) { return z.selector == sel; });
  if (it->second.zapped_elements.size() == before) return false;
  it->second.modified_at = NowEpochSec();
  WriteLocked();
  return true;
}

bool BoostStore::SaveNow() {
  std::lock_guard<std::mutex> lock(mutex_);
  if (retired_) return false;
  return WriteLocked();
}

void BoostStore::Retire() {
  std::lock_guard<std::mutex> lock(mutex_);
  retired_ = true;
  boosts_.clear();
}

bool BoostStore::WriteLocked() const {
  if (retired_) return false;
  if (!base::CreateDirectory(file_path_.DirName())) return false;

  base::ListValue list;
  for (const auto& [_, b] : boosts_) {
    base::DictValue bd;
    bd.Set("id", b.id);
    bd.Set("name", b.name);
    base::DictValue sm;
    sm.Set("domain", b.host_pattern);
    bd.Set("siteMatch", std::move(sm));
    bd.Set("isEnabled", b.enabled);
    bd.Set("css", b.custom_css);
    bd.Set("js", b.custom_js);
    if (b.color.enabled) {
      base::DictValue c;
      c.Set("enabled", true);
      c.Set("hueRotateDegrees", b.color.hue_degrees);
      c.Set("saturation", b.color.saturation);
      c.Set("brightness", 1.0 + b.color.lightness);
      c.Set("contrast", b.color.contrast);
      c.Set("invert", b.color.invert ? 1.0 : 0.0);
      bd.Set("colorAdjustment", std::move(c));
    }
    if (b.font_family) bd.Set("fontFamily", *b.font_family);
    bd.Set("textZoom", b.text_zoom);
    if (!b.text_transform.empty()) bd.Set("textTransform", b.text_transform);
    base::ListValue zaps;
    for (const auto& z : b.zapped_elements) {
      base::DictValue zd;
      zd.Set("id", z.id);
      zd.Set("selector", z.selector);
      zd.Set("label", z.label);
      zaps.Append(std::move(zd));
    }
    bd.Set("zaps", std::move(zaps));
    bd.Set("createdAt", b.created_at);
    bd.Set("updatedAt", b.modified_at);
    list.Append(std::move(bd));
  }

  base::DictValue root;
  root.Set("schemaVersion", loaded_schema_version_);
  root.Set("profileID", profile_id_);
  root.Set("boosts", std::move(list));
  std::string json;
  if (!base::JSONWriter::WriteWithOptions(
          root, base::JSONWriter::OPTIONS_PRETTY_PRINT, &json)) {
    return false;
  }
  return base::ImportantFileWriter::WriteFileAtomically(file_path_, json);
}

std::vector<Boost> BoostStore::MatchUrl(std::string_view url,
                                        bool include_disabled) const {
  GURL gurl(url);
  if (!gurl.is_valid() || !gurl.SchemeIsHTTPOrHTTPS() || gurl.host().empty()) {
    return {};
  }
  std::string host(gurl.host());
  std::string path = gurl.path().empty() ? "/" : std::string(gurl.path());

  std::vector<Boost> matched;
  {
    std::lock_guard<std::mutex> lock(mutex_);
    if (retired_) return {};
    for (const auto& [_, b] : boosts_) {
      if (!include_disabled && !b.enabled) continue;
      SiteMatch sm = SiteMatch::Normalized(b.host_pattern);
      if (sm.Matches(host, path)) {
        matched.push_back(b);
      }
    }
  }
  // General to specific (shorter domain first), then created_at, then id.
  std::sort(matched.begin(), matched.end(), [](const Boost& a, const Boost& b) {
    if (a.host_pattern.size() != b.host_pattern.size()) {
      return a.host_pattern.size() < b.host_pattern.size();
    }
    if (a.host_pattern != b.host_pattern) {
      return a.host_pattern < b.host_pattern;
    }
    if (a.created_at != b.created_at) return a.created_at < b.created_at;
    return a.id < b.id;
  });
  return matched;
}

// static
std::string BoostStore::GenerateCssForBoost(const Boost& boost) {
  return GenerateCssForBoosts({boost});
}

// static
std::string BoostStore::GenerateCssForBoosts(const std::vector<Boost>& boosts) {
  if (boosts.empty()) return {};

  const BoostColorAdjustment* color = nullptr;
  std::optional<std::string> font;
  std::optional<double> zoom;
  std::optional<std::string> transform;
  for (const auto& b : boosts) {
    if (!IsColorIdentity(b.color)) color = &b.color;
    if (b.font_family && IsSafeFontFamily(*b.font_family)) {
      font = *b.font_family;
    }
    if (std::fabs(b.text_zoom - 1.0) > 1e-6) {
      zoom = std::clamp(b.text_zoom, 0.5, 2.0);
    }
    if (IsAllowedTransform(b.text_transform)) {
      transform = b.text_transform;
    }
  }

  std::string css;
  if (color) {
    double h = std::isfinite(color->hue_degrees)
                   ? std::fmod(color->hue_degrees, 360.0)
                   : 0.0;
    if (h < 0.0) h += 360.0;
    double s = std::clamp(color->saturation, 0.0, 3.0);
    double b = std::clamp(1.0 + color->lightness, 0.0, 3.0);
    double ct = std::clamp(color->contrast, 0.0, 3.0);
    double inv = color->invert ? 1.0 : 0.0;
    css += "html { filter: hue-rotate(" + FormatCssNumber(h) + "deg) saturate(" +
           FormatCssNumber(s) + ") brightness(" + FormatCssNumber(b) +
           ") contrast(" + FormatCssNumber(ct) + ") invert(" +
           FormatCssNumber(inv) + "); }\n";
    if (inv >= 0.999) {
      double counter_h = std::fmod(h + 180.0, 360.0);
      css += "img, video, canvas { filter: invert(" + FormatCssNumber(inv) +
             ") hue-rotate(" + FormatCssNumber(counter_h) + "deg); }\n";
    }
  }
  if (font) {
    css +=
        "body, body *:not(script):not(style):not(code):not(pre):not(kbd):not("
        "samp) { font-family: " +
        *font + " !important; }\n";
  }
  if (zoom) {
    css += "html { zoom: " + FormatCssNumber(*zoom) + "; }\n";
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

  for (const auto& b : boosts) {
    if (!b.custom_css.empty()) {
      css += b.custom_css;
      css += "\n";
    }
  }

  std::set<std::string> seen_zaps;
  for (const auto& b : boosts) {
    for (const auto& z : b.zapped_elements) {
      if (!z.selector.empty() && seen_zaps.insert(z.selector).second) {
        css += z.selector + " { display: none !important; }\n";
      }
    }
  }
  return css;
}

BoostInjectionPlan BoostStore::BuildInjectionPlan(
    std::string_view url,
    bool boosts_globally_enabled) const {
  BoostInjectionPlan plan;
  plan.url = std::string(url);
  plan.profile_id = profile_id_;
  if (!boosts_globally_enabled) {
    plan.plan_id = "empty";
    return plan;
  }
  plan.matched_boosts = MatchUrl(url, /*include_disabled=*/false);
  if (plan.matched_boosts.empty()) {
    plan.plan_id = "empty";
    return plan;
  }

  plan.generated_css = GenerateCssForBoosts(plan.matched_boosts);
  std::string js;
  for (const auto& b : plan.matched_boosts) {
    if (!base::TrimWhitespaceASCII(b.custom_js, base::TRIM_ALL).empty()) {
      if (!js.empty()) js += "\n;\n";
      js += b.custom_js;
    }
  }
  plan.combined_js = std::move(js);
  plan.contains_js = !plan.combined_js.empty();

  std::string hash_input = plan.generated_css;
  hash_input.push_back('\0');
  hash_input += plan.combined_js;
  for (const auto& b : plan.matched_boosts) {
    hash_input.push_back('\0');
    hash_input += b.id;
  }
  plan.plan_id = base::NumberToString(plan.matched_boosts.size()) + "-" +
                 Hex64(Fnv1a64(hash_input));
  return plan;
}

// static
std::string BoostStore::LoadBoostApplierJs(const base::FilePath& resource_dir) {
  if (!resource_dir.empty()) {
    std::string file_text;
    if (base::ReadFileToStringWithMaxSize(
            resource_dir.AppendASCII("boost-applier.js"), &file_text,
            1024 * 1024) &&
        !file_text.empty()) {
      return file_text;
    }
  }
  return kBuiltinBoostApplierJs;
}

// static
std::string BoostStore::LoadZapPickerJs(const base::FilePath& resource_dir) {
  if (!resource_dir.empty()) {
    std::string file_text;
    if (base::ReadFileToStringWithMaxSize(
            resource_dir.AppendASCII("zap-picker.js"), &file_text,
            1024 * 1024) &&
        !file_text.empty()) {
      return file_text;
    }
  }
  return kBuiltinZapPickerJs;
}

// static
std::string BoostStore::BuildReceiveScript(std::string_view type,
                                           std::string_view payload_json) {
  base::DictValue envelope;
  envelope.Set("v", 1);
  envelope.Set("type", type);
  if (auto parsed = base::JSONReader::Read(payload_json, base::JSON_PARSE_RFC)) {
    envelope.Set("payload", std::move(*parsed));
  } else {
    envelope.Set("payload", base::DictValue());
  }
  std::string serialized = EncodeJsonString(envelope);
  return "window.__open && window.__open.receive(" + serialized + ");";
}

// --- BoostPickerCoordinator ---

BoostPickerCoordinator::BoostPickerCoordinator(BoostStore* store)
    : store_(store) {}

BoostPickerCoordinator::~BoostPickerCoordinator() = default;

bool BoostPickerCoordinator::CanEnterZap(const std::string& boost_id) const {
  if (!store_) return false;
  auto boost = store_->GetBoost(boost_id);
  if (!boost) return false;
  if (boost->zapped_elements.size() > kZapMaxEntriesPerBoost) return false;
  for (const auto& z : boost->zapped_elements) {
    if (z.selector.size() > kZapMaxSelectorBytes ||
        z.label.size() > kZapMaxLabelBytes) {
      return false;
    }
  }
  return true;
}

std::optional<std::pair<std::string, std::string>>
BoostPickerCoordinator::EnterZap(const std::string& boost_id,
                                 const std::string& page_id,
                                 ZapPickerMode mode) {
  if (!store_ || page_id.empty() || !CanEnterZap(boost_id)) {
    return std::nullopt;
  }
  auto it = sessions_.find(page_id);
  if (it != sessions_.end()) {
    if (it->second.boost_id != boost_id || it->second.mode != mode) {
      return std::nullopt;
    }
  } else {
    ZapPickerSession s;
    s.page_id = page_id;
    s.boost_id = boost_id;
    s.session_nonce = base::Uuid::GenerateRandomV4().AsLowercaseString();
    s.mode = mode;
    it = sessions_.emplace(page_id, std::move(s)).first;
  }

  base::DictValue payload;
  payload.Set("boostID", it->second.boost_id);
  payload.Set("sessionNonce", it->second.session_nonce);
  payload.Set("mode", it->second.mode == ZapPickerMode::kSelect ? "select"
                                                                : "zap");
  return std::make_pair(std::string("zap:enter"), EncodeJsonString(payload));
}

std::vector<std::pair<std::string, std::string>>
BoostPickerCoordinator::BuildListZapMessages(const std::string& page_id) const {
  std::vector<std::pair<std::string, std::string>> out;
  auto it = sessions_.find(page_id);
  if (it == sessions_.end() || !store_) return out;
  auto boost = store_->GetBoost(it->second.boost_id);
  if (!boost) return out;

  std::string list_id = base::Uuid::GenerateRandomV4().AsLowercaseString();
  base::ListValue chunk_selectors;
  base::DictValue chunk_labels;
  size_t approx_bytes = 256;
  bool first = true;

  auto flush_chunk = [&](bool complete) {
    base::DictValue p;
    p.Set("boostID", it->second.boost_id);
    p.Set("sessionNonce", it->second.session_nonce);
    p.Set("listID", list_id);
    if (first) p.Set("reset", true);
    if (complete) p.Set("complete", true);
    p.Set("selectors", std::move(chunk_selectors));
    p.Set("labels", std::move(chunk_labels));
    out.emplace_back("zap:list", EncodeJsonString(p));
    chunk_selectors = base::ListValue();
    chunk_labels = base::DictValue();
    approx_bytes = 256;
    first = false;
  };

  for (const auto& z : boost->zapped_elements) {
    size_t entry_bytes = z.selector.size() * 2 + z.label.size() + 32;
    if (!chunk_selectors.empty() &&
        approx_bytes + entry_bytes > kZapMaxMessageBytes - 1024) {
      flush_chunk(false);
    }
    chunk_selectors.Append(z.selector);
    chunk_labels.Set(z.selector, z.label);
    approx_bytes += entry_bytes;
  }
  flush_chunk(true);
  return out;
}

std::optional<std::pair<std::string, std::string>>
BoostPickerCoordinator::BuildUndoMessage(const std::string& page_id) const {
  auto it = sessions_.find(page_id);
  if (it == sessions_.end()) return std::nullopt;
  base::DictValue p;
  p.Set("boostID", it->second.boost_id);
  p.Set("sessionNonce", it->second.session_nonce);
  return std::make_pair(std::string("zap:undo"), EncodeJsonString(p));
}

std::optional<std::pair<std::string, std::string>>
BoostPickerCoordinator::BuildRemoveZapMessage(const std::string& page_id,
                                              std::string_view selector) const {
  auto it = sessions_.find(page_id);
  if (it == sessions_.end()) return std::nullopt;
  base::DictValue p;
  p.Set("boostID", it->second.boost_id);
  p.Set("sessionNonce", it->second.session_nonce);
  p.Set("selector", selector);
  return std::make_pair(std::string("zap:remove"), EncodeJsonString(p));
}

std::optional<std::pair<std::string, std::string>>
BoostPickerCoordinator::BuildOcclusionMessage(const std::string& page_id,
                                              double right_fraction,
                                              double top_fraction,
                                              double bottom_fraction) const {
  auto it = sessions_.find(page_id);
  if (it == sessions_.end()) return std::nullopt;
  base::DictValue p;
  p.Set("boostID", it->second.boost_id);
  p.Set("sessionNonce", it->second.session_nonce);
  p.Set("right", std::clamp(right_fraction, 0.0, 1.0));
  p.Set("top", std::clamp(top_fraction, 0.0, 1.0));
  p.Set("bottom", std::clamp(bottom_fraction, 0.0, 1.0));
  return std::make_pair(std::string("zap:occlusion"), EncodeJsonString(p));
}

std::optional<std::pair<std::string, std::string>>
BoostPickerCoordinator::ExitZap(const std::string& page_id) {
  auto it = sessions_.find(page_id);
  if (it == sessions_.end()) return std::nullopt;
  ZapPickerSession expired = std::move(it->second);
  sessions_.erase(it);
  base::DictValue p;
  p.Set("boostID", expired.boost_id);
  p.Set("sessionNonce", expired.session_nonce);
  return std::make_pair(std::string("zap:exit"), EncodeJsonString(p));
}

void BoostPickerCoordinator::InvalidatePage(const std::string& page_id) {
  sessions_.erase(page_id);
}

bool BoostPickerCoordinator::HasActiveSession(
    const std::string& page_id) const {
  return sessions_.contains(page_id);
}

ZapMessageValidationResult BoostPickerCoordinator::HandleRawMessage(
    const std::string& page_id,
    std::string_view raw_json) {
  ZapMessageValidationResult res;
  if (raw_json.size() > kZapMaxMessageBytes) {
    res.reject_reason = "Message exceeds 64 KiB cap";
    return res;
  }
  auto env = base::JSONReader::ReadDict(raw_json, base::JSON_PARSE_RFC);
  if (!env) {
    res.reject_reason = "Invalid JSON";
    return res;
  }
  if (env->FindInt("v").value_or(0) != 1) {
    res.reject_reason = "Unsupported envelope version";
    return res;
  }
  const auto* type = env->FindString("type");
  const auto* payload = env->FindDict("payload");
  if (!type || !payload) {
    res.reject_reason = "Missing type or payload";
    return res;
  }

  if (*type == "boost:applied" || *type == "boost:error") {
    res.accepted = true;
    res.event_type = *type;
    return res;
  }

  // Every zap:* / picker:* message requires an armed native session matching
  // page_id + boostID + sessionNonce.
  auto sit = sessions_.find(page_id);
  if (sit == sessions_.end()) {
    res.reject_reason = "No armed session for page";
    return res;
  }
  const auto* bid = payload->FindString("boostID");
  const auto* nonce = payload->FindString("sessionNonce");
  if (!bid || !nonce || *bid != sit->second.boost_id ||
      *nonce != sit->second.session_nonce) {
    res.reject_reason = "Invalid boostID or sessionNonce";
    return res;
  }

  const ZapPickerSession& session = sit->second;
  if (session.mode == ZapPickerMode::kSelect) {
    if (*type == "picker:selected") {
      static const std::set<std::string_view> kAllowed = {
          "boostID", "sessionNonce", "selector", "matches"};
      if (!HasOnlyAllowedKeys(*payload, kAllowed)) {
        res.reject_reason = "Unknown fields in picker:selected";
        return res;
      }
      const auto* sel = payload->FindString("selector");
      auto matches = payload->FindInt("matches");
      if (!sel || sel->empty() || sel->size() > kZapMaxSelectorBytes ||
          !matches || *matches <= 0) {
        res.reject_reason = "Invalid selector or match count";
        return res;
      }
      res.accepted = true;
      res.event_type = "selected";
      res.selected_selector = *sel;
      res.selected_matches = *matches;
      return res;
    }
    if (*type != "picker:ready" && *type != "picker:exited" &&
        *type != "picker:error") {
      res.reject_reason = "Disallowed message in select mode";
      return res;
    }
  } else if (*type == "picker:selected") {
    res.reject_reason = "picker:selected disallowed in zap mode";
    return res;
  }

  if (*type == "zap:committed") {
    static const std::set<std::string_view> kAllowed = {
        "boostID", "sessionNonce", "selector",
        "label",   "matches",      "inShadowRoot"};
    if (!HasOnlyAllowedKeys(*payload, kAllowed)) {
      res.reject_reason = "Unknown fields in zap:committed";
      return res;
    }
    const auto* sel = payload->FindString("selector");
    const auto* label = payload->FindString("label");
    auto matches = payload->FindInt("matches");
    if (!sel || sel->empty() || sel->size() > kZapMaxSelectorBytes ||
        !matches || *matches < 0 ||
        (label && label->size() > kZapMaxLabelBytes)) {
      res.reject_reason = "Invalid zap:committed fields";
      return res;
    }
    ZappedElement z;
    z.selector = *sel;
    z.label = label ? *label : "";
    res.store_mutated = store_ && store_->AppendZap(session.boost_id, z);
    res.accepted = true;
    res.event_type = "committed";
    return res;
  }

  if (*type == "zap:replaced") {
    static const std::set<std::string_view> kAllowed = {
        "boostID",     "sessionNonce", "oldSelector",
        "newSelector", "label",        "matches"};
    if (!HasOnlyAllowedKeys(*payload, kAllowed)) {
      res.reject_reason = "Unknown fields in zap:replaced";
      return res;
    }
    const auto* old_sel = payload->FindString("oldSelector");
    const auto* new_sel = payload->FindString("newSelector");
    const auto* label = payload->FindString("label");
    auto matches = payload->FindInt("matches");
    if (!old_sel || !new_sel || new_sel->empty() || *old_sel == *new_sel ||
        old_sel->size() > kZapMaxSelectorBytes ||
        new_sel->size() > kZapMaxSelectorBytes || !matches || *matches < 0 ||
        (label && label->size() > kZapMaxLabelBytes)) {
      res.reject_reason = "Invalid zap:replaced fields";
      return res;
    }
    bool removed = store_ && store_->RemoveZap(session.boost_id, *old_sel);
    ZappedElement z;
    z.selector = *new_sel;
    z.label = label ? *label : "";
    bool added = store_ && store_->AppendZap(session.boost_id, z);
    res.store_mutated = removed || added;
    res.accepted = true;
    res.event_type = "committed";
    return res;
  }

  if (*type == "zap:removed") {
    static const std::set<std::string_view> kAllowed = {
        "boostID", "sessionNonce", "selector", "via"};
    if (!HasOnlyAllowedKeys(*payload, kAllowed)) {
      res.reject_reason = "Unknown fields in zap:removed";
      return res;
    }
    const auto* sel = payload->FindString("selector");
    const auto* via = payload->FindString("via");
    if (!sel || !via || sel->size() > kZapMaxSelectorBytes) {
      res.reject_reason = "Invalid zap:removed fields";
      return res;
    }
    // Verify selector exists in store before accepting removal.
    auto boost = store_ ? store_->GetBoost(session.boost_id) : std::nullopt;
    bool in_store =
        boost && std::any_of(boost->zapped_elements.begin(),
                             boost->zapped_elements.end(),
                             [&](const ZappedElement& z) {
                               return z.selector == *sel;
                             });
    if (!in_store) {
      res.reject_reason = "Selector not found in store";
      return res;
    }
    res.store_mutated =
        (*via == "undo") && store_ && store_->RemoveZap(session.boost_id, *sel);
    res.accepted = true;
    res.event_type = "removed";
    return res;
  }

  if (*type == "zap:revealRequested") {
    static const std::set<std::string_view> kAllowed = {
        "boostID", "sessionNonce", "selector"};
    if (!HasOnlyAllowedKeys(*payload, kAllowed)) {
      res.reject_reason = "Unknown fields in zap:revealRequested";
      return res;
    }
    const auto* sel = payload->FindString("selector");
    if (!sel || sel->empty() || sel->size() > kZapMaxSelectorBytes) {
      res.reject_reason = "Invalid selector";
      return res;
    }
    res.store_mutated = store_ && store_->RemoveZap(session.boost_id, *sel);
    res.accepted = res.store_mutated;
    res.event_type = "removed";
    return res;
  }

  if (*type == "zap:list-result") {
    const auto* entries = payload->FindList("entries");
    if (!entries) {
      res.reject_reason = "Missing entries";
      return res;
    }
    std::set<std::string> seen;
    for (const auto& ev : *entries) {
      const auto* ed = ev.GetIfDict();
      if (!ed) return res;
      const auto* sel = ed->FindString("selector");
      auto cnt = ed->FindInt("matchCount");
      if (!sel || !cnt || *cnt < 0 || sel->size() > kZapMaxSelectorBytes ||
          !seen.insert(*sel).second) {
        res.reject_reason = "Invalid or duplicate list entry";
        return res;
      }
      ZapListEntry e;
      e.selector = *sel;
      if (const auto* l = ed->FindString("label")) e.label = *l;
      e.match_count = *cnt;
      e.truncated = ed->FindBool("truncated").value_or(false);
      res.list_entries.push_back(std::move(e));
    }
    res.accepted = true;
    res.event_type = "listResult";
    return res;
  }

  if (*type == "picker:exited") {
    sessions_.erase(sit);
    res.accepted = true;
    res.event_type = "exited";
    return res;
  }

  if (*type == "picker:ready" || *type == "picker:error") {
    res.accepted = true;
    res.event_type = *type;
    return res;
  }

  res.reject_reason = "Unknown message type";
  return res;
}

}  // namespace open_unified
