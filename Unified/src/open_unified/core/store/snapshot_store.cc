// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/core/store/snapshot_store.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <functional>
#include <map>
#include <memory>
#include <set>
#include <unordered_map>
#include <utility>

#include "base/base64.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/functional/bind.h"
#include "base/json/json_reader.h"
#include "base/json/json_writer.h"
#include "base/location.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/synchronization/lock.h"
#include "base/task/thread_pool.h"
#include "base/task/thread_pool/thread_pool_instance.h"
#include "content/public/browser/browser_thread.h"
#include "open_unified/core/model/uuid_util.h"

namespace open_unified {

namespace {

double ClampUnit(double v) {
  return std::isfinite(v) ? std::clamp(v, 0.0, 1.0) : 0.0;
}

double FiniteOr(std::optional<double> v, double fallback) {
  return (v.has_value() && std::isfinite(*v)) ? *v : fallback;
}

std::string SafeUuid(const std::string* raw) {
  if (raw) {
    if (auto norm = NormalizeUuid(*raw)) {
      return *norm;
    }
  }
  return GenerateUuidV4();
}

std::optional<std::string> OptionalUuid(const std::string* raw) {
  if (!raw || raw->empty()) {
    return std::nullopt;
  }
  if (auto norm = NormalizeUuid(*raw)) {
    return *norm;
  }
  return std::nullopt;
}

// --- Enum codecs (exact Swift SnapshotDTOs rawValues) ---

const char* AutoArchiveToString(AutoArchiveInterval v) {
  switch (v) {
    case AutoArchiveInterval::kNever:
      return "never";
    case AutoArchiveInterval::kOneHour:
      return "oneHour";
    case AutoArchiveInterval::kSixHours:
      return "sixHours";
    case AutoArchiveInterval::kTwelveHours:
      return "twelveHours";
    case AutoArchiveInterval::kTwentyFourHours:
      return "twentyFourHours";
    case AutoArchiveInterval::kSevenDays:
      return "sevenDays";
    case AutoArchiveInterval::kThirtyDays:
      return "thirtyDays";
  }
  return "twelveHours";
}

AutoArchiveInterval AutoArchiveFromString(const std::string* s,
                                          AutoArchiveInterval fallback) {
  if (!s) return fallback;
  if (*s == "never") return AutoArchiveInterval::kNever;
  if (*s == "oneHour") return AutoArchiveInterval::kOneHour;
  if (*s == "sixHours") return AutoArchiveInterval::kSixHours;
  if (*s == "twelveHours") return AutoArchiveInterval::kTwelveHours;
  if (*s == "twentyFourHours") return AutoArchiveInterval::kTwentyFourHours;
  if (*s == "sevenDays") return AutoArchiveInterval::kSevenDays;
  if (*s == "thirtyDays") return AutoArchiveInterval::kThirtyDays;
  return fallback;
}

const char* SleepModeToString(SleepMode v) {
  switch (v) {
    case SleepMode::kOff:
      return "off";
    case SleepMode::kConservative:
      return "conservative";
    case SleepMode::kBalanced:
      return "balanced";
    case SleepMode::kAggressive:
      return "aggressive";
  }
  return "balanced";
}

SleepMode SleepModeFromString(const std::string* s) {
  if (!s) return SleepMode::kBalanced;
  if (*s == "off") return SleepMode::kOff;
  if (*s == "conservative") return SleepMode::kConservative;
  if (*s == "balanced") return SleepMode::kBalanced;
  if (*s == "aggressive") return SleepMode::kAggressive;
  return SleepMode::kBalanced;
}

const char* WheelToString(ThemeWheel w) {
  return w == ThemeWheel::kComplementary ? "complementary" : "analogous";
}

ThemeWheel WheelFromString(const std::string* s) {
  return (s && *s == "complementary") ? ThemeWheel::kComplementary
                                      : ThemeWheel::kAnalogous;
}

const char* AppearanceToString(ThemeAppearance a) {
  switch (a) {
    case ThemeAppearance::kAutomatic:
      return "automatic";
    case ThemeAppearance::kLight:
      return "light";
    case ThemeAppearance::kDark:
      return "dark";
  }
  return "automatic";
}

ThemeAppearance AppearanceFromString(const std::string* s) {
  if (!s) return ThemeAppearance::kAutomatic;
  if (*s == "light") return ThemeAppearance::kLight;
  if (*s == "dark") return ThemeAppearance::kDark;
  return ThemeAppearance::kAutomatic;
}

const char* TextureToString(ThemeTexture t) {
  switch (t) {
    case ThemeTexture::kGrain:
      return "grain";
    case ThemeTexture::kSand:
      return "sand";
    case ThemeTexture::kDenim:
      return "denim";
    case ThemeTexture::kTweed:
      return "tweed";
  }
  return "grain";
}

ThemeTexture TextureFromString(const std::string* s) {
  if (!s) return ThemeTexture::kGrain;
  if (*s == "sand") return ThemeTexture::kSand;
  if (*s == "denim") return ThemeTexture::kDenim;
  if (*s == "tweed") return ThemeTexture::kTweed;
  return ThemeTexture::kGrain;
}

// --- Value object codecs ---

base::DictValue SerializeColor(const RGBAColor& c) {
  base::DictValue d;
  d.Set("red", c.r);
  d.Set("green", c.g);
  d.Set("blue", c.b);
  d.Set("alpha", c.a);
  return d;
}

std::optional<RGBAColor> DeserializeColor(const base::DictValue* d) {
  if (!d) return std::nullopt;
  auto r = d->FindDouble("red");
  auto g = d->FindDouble("green");
  auto b = d->FindDouble("blue");
  if (!r.has_value() || !g.has_value() || !b.has_value()) {
    return std::nullopt;
  }
  RGBAColor c;
  c.r = FiniteOr(r, 0.0);
  c.g = FiniteOr(g, 0.0);
  c.b = FiniteOr(b, 0.0);
  c.a = FiniteOr(d->FindDouble("alpha"), 1.0);
  return c;
}

base::DictValue SerializeIcon(const SpaceIcon& icon) {
  base::DictValue inner;
  inner.Set("_0", icon.value);
  base::DictValue outer;
  switch (icon.kind) {
    case SpaceIconKind::kEmoji:
      outer.Set("emoji", std::move(inner));
      break;
    case SpaceIconKind::kSymbol:
      outer.Set("symbol", std::move(inner));
      break;
    case SpaceIconKind::kNamed:
      outer.Set("named", std::move(inner));
      break;
  }
  return outer;
}

std::optional<SpaceIcon> DeserializeIcon(const base::DictValue* d) {
  if (!d) return std::nullopt;
  if (const base::DictValue* inner = d->FindDict("emoji")) {
    if (const std::string* v = inner->FindString("_0")) {
      return SpaceIcon{SpaceIconKind::kEmoji, *v};
    }
  }
  if (const base::DictValue* inner = d->FindDict("symbol")) {
    if (const std::string* v = inner->FindString("_0")) {
      return SpaceIcon{SpaceIconKind::kSymbol, *v};
    }
  }
  if (const base::DictValue* inner = d->FindDict("named")) {
    if (const std::string* v = inner->FindString("_0")) {
      return SpaceIcon{SpaceIconKind::kNamed, *v};
    }
  }
  return std::nullopt;
}

base::DictValue SerializeSpaceStyle(const SpaceStyle& style) {
  base::DictValue d;
  d.Set("mathVersion", style.math_version);
  d.Set("keyColor", SerializeColor(style.key_color));
  d.Set("colorCount", std::clamp(style.color_count, 1, 3));
  d.Set("wheel", WheelToString(style.wheel));
  d.Set("appearance", AppearanceToString(style.appearance));
  d.Set("noiseFactor", ClampUnit(style.noise_factor));
  d.Set("texture", TextureToString(style.texture));
  d.Set("intensityFactor", ClampUnit(style.intensity_factor));
  return d;
}

std::optional<SpaceStyle> DeserializeSpaceStyle(const base::DictValue* d) {
  if (!d) return std::nullopt;
  auto key = DeserializeColor(d->FindDict("keyColor"));
  if (!key.has_value()) {
    return std::nullopt;
  }
  SpaceStyle s;
  s.math_version = d->FindInt("mathVersion").value_or(1);
  s.key_color = *key;
  s.color_count = std::clamp(d->FindInt("colorCount").value_or(1), 1, 3);
  s.wheel = WheelFromString(d->FindString("wheel"));
  s.appearance = AppearanceFromString(d->FindString("appearance"));
  s.noise_factor = ClampUnit(d->FindDouble("noiseFactor").value_or(0.0));
  s.texture = TextureFromString(d->FindString("texture"));
  s.intensity_factor =
      ClampUnit(d->FindDouble("intensityFactor").value_or(0.8));
  return s;
}

base::DictValue SerializeTheme(const SpaceTheme& theme) {
  base::DictValue d;
  if (theme.light_background.has_value()) {
    d.Set("lightBackground", SerializeColor(*theme.light_background));
  }
  if (theme.dark_background.has_value()) {
    d.Set("darkBackground", SerializeColor(*theme.dark_background));
  }
  if (theme.light_foreground.has_value()) {
    d.Set("lightForeground", SerializeColor(*theme.light_foreground));
  }
  if (theme.dark_foreground.has_value()) {
    d.Set("darkForeground", SerializeColor(*theme.dark_foreground));
  }
  if (theme.accent.has_value()) {
    d.Set("accent", SerializeColor(*theme.accent));
  }
  base::ListValue light_stops;
  for (const GradientStop& stop : theme.gradient_stops_light) {
    base::DictValue sd;
    sd.Set("location", stop.location);
    sd.Set("color", SerializeColor(stop.color));
    light_stops.Append(std::move(sd));
  }
  d.Set("gradientStopsLight", std::move(light_stops));
  base::ListValue dark_stops;
  for (const GradientStop& stop : theme.gradient_stops_dark) {
    base::DictValue sd;
    sd.Set("location", stop.location);
    sd.Set("color", SerializeColor(stop.color));
    dark_stops.Append(std::move(sd));
  }
  d.Set("gradientStopsDark", std::move(dark_stops));
  if (theme.imported_arc_theme_json.has_value()) {
    d.Set("importedArcThemeJSON",
          base::Base64Encode(*theme.imported_arc_theme_json));
  }
  if (theme.style.has_value()) {
    d.Set("style", SerializeSpaceStyle(*theme.style));
  }
  return d;
}

SpaceTheme DeserializeTheme(const base::DictValue* d) {
  SpaceTheme theme;
  if (!d) return theme;
  theme.light_background = DeserializeColor(d->FindDict("lightBackground"));
  theme.dark_background = DeserializeColor(d->FindDict("darkBackground"));
  theme.light_foreground = DeserializeColor(d->FindDict("lightForeground"));
  theme.dark_foreground = DeserializeColor(d->FindDict("darkForeground"));
  theme.accent = DeserializeColor(d->FindDict("accent"));
  auto parse_stops = [](const base::ListValue* list) {
    std::vector<GradientStop> out;
    if (!list) return out;
    for (const base::Value& v : *list) {
      const base::DictValue* sd = v.GetIfDict();
      if (!sd) continue;
      auto col = DeserializeColor(sd->FindDict("color"));
      if (!col.has_value()) continue;
      GradientStop stop;
      stop.location = FiniteOr(sd->FindDouble("location"), 0.0);
      stop.color = *col;
      out.push_back(stop);
    }
    return out;
  };
  theme.gradient_stops_light = parse_stops(d->FindList("gradientStopsLight"));
  theme.gradient_stops_dark = parse_stops(d->FindList("gradientStopsDark"));
  if (const std::string* raw_arc = d->FindString("importedArcThemeJSON")) {
    std::string decoded;
    if (base::Base64Decode(*raw_arc, &decoded)) {
      theme.imported_arc_theme_json = std::move(decoded);
    } else {
      theme.imported_arc_theme_json = *raw_arc;
    }
  }
  theme.style = DeserializeSpaceStyle(d->FindDict("style"));
  return theme;
}

base::DictValue SerializeDestination(const RoutingDestination& dest) {
  base::DictValue outer;
  base::DictValue inner;
  switch (dest.kind) {
    case RoutingDestinationKind::kSpace:
      inner.Set("_0", dest.space_id.value_or(""));
      outer.Set("space", std::move(inner));
      break;
    case RoutingDestinationKind::kLittleOpen:
      if (dest.profile_id.has_value()) {
        inner.Set("profile", *dest.profile_id);
      }
      outer.Set("littleOpen", std::move(inner));
      break;
    case RoutingDestinationKind::kMostRecentSpace:
      if (dest.profile_id.has_value()) {
        inner.Set("profile", *dest.profile_id);
      }
      outer.Set("mostRecentSpace", std::move(inner));
      break;
  }
  return outer;
}

RoutingDestination DeserializeDestination(const base::DictValue* d) {
  RoutingDestination dest;
  if (!d) {
    dest.kind = RoutingDestinationKind::kLittleOpen;
    return dest;
  }
  if (const base::DictValue* inner = d->FindDict("space")) {
    dest.kind = RoutingDestinationKind::kSpace;
    dest.space_id = OptionalUuid(inner->FindString("_0"));
    return dest;
  }
  // Support legacy "littleArc" spelling alongside canonical "littleOpen".
  const base::DictValue* little = d->FindDict("littleOpen");
  if (!little) {
    little = d->FindDict("littleArc");
  }
  if (little) {
    dest.kind = RoutingDestinationKind::kLittleOpen;
    dest.profile_id = OptionalUuid(little->FindString("profile"));
    return dest;
  }
  if (const base::DictValue* recent = d->FindDict("mostRecentSpace")) {
    dest.kind = RoutingDestinationKind::kMostRecentSpace;
    dest.profile_id = OptionalUuid(recent->FindString("profile"));
    return dest;
  }
  dest.kind = RoutingDestinationKind::kLittleOpen;
  return dest;
}

base::DictValue SerializeProfileSettings(const ProfileSettings& s) {
  base::DictValue d;
  d.Set("autoArchiveAfter", AutoArchiveToString(s.auto_archive_after));
  d.Set("littleOpenAutoArchiveAfter",
        AutoArchiveToString(s.little_open_auto_archive_after));
  d.Set("searchSuggestEnabled", s.search_suggest_enabled);
  d.Set("downloadDirectory", s.download_directory);
  d.Set("askWhereToSaveEachFile", s.ask_where_to_save_each_file);
  base::ListValue engines;
  for (const CustomSearchEngine& e : s.custom_search_engines) {
    base::DictValue ed;
    ed.Set("id", e.id);
    ed.Set("name", e.name);
    base::ListValue kws;
    if (!e.keyword.empty()) {
      kws.Append(e.keyword);
    }
    ed.Set("keywords", std::move(kws));
    ed.Set("keyword", e.keyword);
    ed.Set("searchURLTemplate", e.url_template);
    ed.Set("suggestFormat", "openSearch");
    engines.Append(std::move(ed));
  }
  d.Set("customSearchEngines", std::move(engines));
  d.Set("searchEngineID", s.search_engine_id);
  d.Set("sleepMode", SleepModeToString(s.sleep_mode));
  base::ListValue keep_alive;
  for (const std::string& site : s.keep_alive_sites) {
    keep_alive.Append(site);
  }
  d.Set("keepAliveSites", std::move(keep_alive));
  d.Set("defaultDocumentApp", s.default_document_app);
  return d;
}

ProfileSettings DeserializeProfileSettings(const base::DictValue* d) {
  ProfileSettings s;
  if (!d) return s;
  s.auto_archive_after = AutoArchiveFromString(
      d->FindString("autoArchiveAfter"), AutoArchiveInterval::kTwelveHours);
  const std::string* lo_archive = d->FindString("littleOpenAutoArchiveAfter");
  if (!lo_archive) {
    // Legacy macOS Open snapshot key.
    lo_archive = d->FindString("littleArcAutoArchiveAfter");
  }
  s.little_open_auto_archive_after =
      AutoArchiveFromString(lo_archive, AutoArchiveInterval::kSixHours);
  s.search_suggest_enabled = d->FindBool("searchSuggestEnabled").value_or(true);
  if (const std::string* dir = d->FindString("downloadDirectory")) {
    s.download_directory = *dir;
  }
  s.ask_where_to_save_each_file =
      d->FindBool("askWhereToSaveEachFile").value_or(false);
  if (const base::ListValue* engines = d->FindList("customSearchEngines")) {
    for (const base::Value& v : *engines) {
      const base::DictValue* ed = v.GetIfDict();
      if (!ed) continue;
      CustomSearchEngine e;
      if (const std::string* id = ed->FindString("id")) e.id = *id;
      if (const std::string* name = ed->FindString("name")) e.name = *name;
      if (const std::string* kw = ed->FindString("keyword")) {
        e.keyword = *kw;
      } else if (const base::ListValue* kws = ed->FindList("keywords")) {
        if (!kws->empty() && (*kws)[0].is_string()) {
          e.keyword = (*kws)[0].GetString();
        }
      }
      if (const std::string* tpl = ed->FindString("searchURLTemplate")) {
        e.url_template = *tpl;
      } else if (const std::string* tpl2 = ed->FindString("urlTemplate")) {
        e.url_template = *tpl2;
      }
      if (!e.id.empty() && !e.url_template.empty()) {
        s.custom_search_engines.push_back(std::move(e));
      }
    }
  }
  if (const std::string* se = d->FindString("searchEngineID")) {
    s.search_engine_id = *se;
  }
  s.sleep_mode = SleepModeFromString(d->FindString("sleepMode"));
  if (const base::ListValue* sites = d->FindList("keepAliveSites")) {
    for (const base::Value& v : *sites) {
      if (v.is_string()) {
        s.keep_alive_sites.push_back(v.GetString());
      }
    }
  }
  if (const std::string* doc_app = d->FindString("defaultDocumentApp")) {
    s.default_document_app = *doc_app;
  }
  return s;
}

base::DictValue SerializeRoutingRule(const RoutingRule& r) {
  base::DictValue d;
  d.Set("id", r.id);
  d.Set("name", r.name);
  d.Set("hostPattern", r.host_pattern);
  if (r.path_prefix.has_value()) {
    d.Set("pathPrefix", *r.path_prefix);
  }
  if (r.source_app_id.has_value()) {
    std::string norm;
    base::TrimWhitespaceASCII(*r.source_app_id, base::TRIM_ALL, &norm);
    norm = base::ToLowerASCII(norm);
    if (!norm.empty()) {
      d.Set("sourceBundleID", norm);
      d.Set("sourceAppID", norm);
    }
  }
  d.Set("enabled", r.enabled);
  d.Set("destination", SerializeDestination(r.destination));

  // Emit Swift SnapshotDTOs-compatible `match` field as well.
  base::DictValue match_dict;
  base::DictValue match_inner;
  if (r.path_prefix.has_value() && !r.path_prefix->empty()) {
    std::string prefix = r.host_pattern;
    if (r.path_prefix->front() != '/') {
      prefix += "/";
    }
    prefix += *r.path_prefix;
    match_inner.Set("_0", prefix);
    match_dict.Set("urlPrefix", std::move(match_inner));
  } else {
    match_inner.Set("_0", r.host_pattern);
    match_dict.Set("hostEquals", std::move(match_inner));
  }
  d.Set("match", std::move(match_dict));
  return d;
}

RoutingRule DeserializeRoutingRule(const base::DictValue& d) {
  RoutingRule r;
  r.id = SafeUuid(d.FindString("id"));
  if (const std::string* name = d.FindString("name")) {
    r.name = *name;
  }
  r.enabled = d.FindBool("enabled").value_or(true);
  r.destination = DeserializeDestination(d.FindDict("destination"));

  const std::string* src = d.FindString("sourceAppID");
  if (!src) src = d.FindString("sourceBundleID");
  if (src) {
    std::string trimmed;
    base::TrimWhitespaceASCII(*src, base::TRIM_ALL, &trimmed);
    trimmed = base::ToLowerASCII(trimmed);
    if (!trimmed.empty()) {
      r.source_app_id = std::move(trimmed);
    }
  }

  if (const std::string* hp = d.FindString("hostPattern")) {
    r.host_pattern = *hp;
    if (const std::string* pp = d.FindString("pathPrefix")) {
      if (!pp->empty()) {
        r.path_prefix = *pp;
      }
    }
  } else if (const base::DictValue* match = d.FindDict("match")) {
    // Decode Swift RoutingMatchDTO shapes.
    if (const base::DictValue* he = match->FindDict("hostEquals")) {
      if (const std::string* v = he->FindString("_0")) {
        r.host_pattern = *v;
      }
    } else if (const base::DictValue* hc = match->FindDict("hostContains")) {
      if (const std::string* v = hc->FindString("_0")) {
        r.host_pattern = "*" + *v + "*";
      }
    } else if (const base::DictValue* up = match->FindDict("urlPrefix")) {
      if (const std::string* v = up->FindString("_0")) {
        std::string_view sv(*v);
        size_t scheme_pos = sv.find("://");
        if (scheme_pos != std::string_view::npos) {
          sv = sv.substr(scheme_pos + 3);
        }
        size_t slash = sv.find('/');
        if (slash != std::string_view::npos) {
          r.host_pattern = std::string(sv.substr(0, slash));
          r.path_prefix = std::string(sv.substr(slash));
        } else {
          r.host_pattern = std::string(sv);
        }
      }
    }
  }
  return r;
}

// Repairs duplicate IDs across profiles, spaces, and nodes (matching Swift
// SnapshotMapper.removingDuplicateIDs).
void RepairDuplicateIds(std::vector<Profile>* profiles,
                        std::vector<Space>* spaces,
                        std::vector<std::string>* repairs) {
  auto record = [&](std::string msg) {
    if (repairs) {
      repairs->push_back(std::move(msg));
    }
  };

  std::set<std::string> profile_ids;
  profiles->erase(
      std::remove_if(profiles->begin(), profiles->end(),
                     [&](const Profile& p) {
                       if (!profile_ids.insert(p.id).second) {
                         record("dropped duplicate Profile " + p.id);
                         return true;
                       }
                       return false;
                     }),
      profiles->end());

  std::set<std::string> space_ids;
  for (Space& s : *spaces) {
    if (!space_ids.insert(s.id).second) {
      std::string old_id = s.id;
      s.id = GenerateUuidV4();
      space_ids.insert(s.id);
      record("gave Space " + old_id + " a new ID " + s.id);
    }
  }

  std::set<std::string> node_ids;
  auto claim_tab = [&](Tab& tab) {
    if (!node_ids.insert(tab.id).second) {
      std::string old_id = tab.id;
      tab.id = GenerateUuidV4();
      node_ids.insert(tab.id);
      record("gave tab " + old_id + " a new ID " + tab.id);
    }
  };
  std::function<void(std::vector<SidebarNode>&)> claim_nodes =
      [&](std::vector<SidebarNode>& list) {
        for (SidebarNode& node : list) {
          if (Tab* t = node.as_tab()) {
            claim_tab(*t);
          } else if (Folder* f = node.as_folder()) {
            if (!node_ids.insert(f->id).second) {
              std::string old_id = f->id;
              f->id = GenerateUuidV4();
              node_ids.insert(f->id);
              record("gave folder " + old_id + " a new ID " + f->id);
            }
            claim_nodes(f->children);
          } else if (Split* sp = node.as_split()) {
            if (!node_ids.insert(sp->id).second) {
              std::string old_id = sp->id;
              sp->id = GenerateUuidV4();
              node_ids.insert(sp->id);
              record("gave split " + old_id + " a new ID " + sp->id);
            }
            for (Tab& pane : sp->panes) {
              claim_tab(pane);
            }
          }
        }
      };

  for (Profile& p : *profiles) {
    for (Tab& fav : p.favorites) {
      claim_tab(fav);
    }
  }
  for (Space& s : *spaces) {
    claim_nodes(s.pinned);
    claim_nodes(s.today);
  }
}

struct PathWriteState {
  std::atomic<uint64_t> latest_generation{0};
  base::Lock io_lock;
};

PathWriteState& GetPathWriteState(const base::FilePath& file_path) {
  static base::NoDestructor<base::Lock> map_lock;
  static base::NoDestructor<
      std::map<base::FilePath, std::unique_ptr<PathWriteState>>>
      states;
  base::AutoLock lock(*map_lock);
  auto& slot = (*states)[file_path];
  if (!slot) {
    slot = std::make_unique<PathWriteState>();
  }
  return *slot;
}

uint64_t NextWriteGeneration(const base::FilePath& file_path) {
  return GetPathWriteState(file_path)
             .latest_generation.fetch_add(1, std::memory_order_acq_rel) +
         1;
}

base::Lock& InlineIoStoresLock() {
  static base::NoDestructor<base::Lock> lock;
  return *lock;
}

std::set<const SnapshotStore*>& InlineIoStores() {
  static base::NoDestructor<std::set<const SnapshotStore*>> stores;
  return *stores;
}

std::string WriteSnapshotOnIoSequence(base::FilePath file_path,
                                      std::string encoded,
                                      uint64_t generation) {
  PathWriteState& state = GetPathWriteState(file_path);
  if (generation < state.latest_generation.load(std::memory_order_acquire)) {
    return {};  // Superseded by a newer snapshot (e.g., shutdown flush).
  }
  base::AutoLock lock(state.io_lock);
  if (generation < state.latest_generation.load(std::memory_order_acquire)) {
    return {};
  }
  if (!base::CreateDirectory(file_path.DirName())) {
    return "SnapshotStore: failed to create State directory";
  }
  if (!base::ImportantFileWriter::WriteFileAtomically(file_path, encoded)) {
    return "SnapshotStore: atomic write to browser.json failed";
  }
  return {};
}

void MoveCorruptSnapshotAside(const base::FilePath& file_path) {
  const int64_t epoch_ms = base::Time::Now().InMillisecondsSinceUnixEpoch();
  const int64_t epoch_sec = epoch_ms / 1000;
  base::FilePath dest = file_path.DirName().AppendASCII(
      "browser.corrupt-" + base::NumberToString(epoch_sec) + ".json");
  if (base::PathExists(dest)) {
    dest = file_path.DirName().AppendASCII(
        "browser.corrupt-" + base::NumberToString(epoch_ms) + ".json");
  }
  base::Move(file_path, dest);
}

// Detects corrupted moved-from empty-shell tab entries (id == "", url == "",
// title == "") left behind by the old SweepExpiredList bug.
bool IsCorruptedEmptyShellTab(const base::DictValue& d) {
  const std::string* id = d.FindString("id");
  if (!id || !id->empty()) {
    return false;
  }
  const std::string* url = d.FindString("url");
  const std::string* title = d.FindString("title");
  return (!url || url->empty()) && (!title || title->empty());
}

std::optional<SidebarNode> DeserializeNodeImpl(
    const base::DictValue& d,
    std::vector<std::string>* repairs_out) {
  if (const base::DictValue* wrap = d.FindDict("tab")) {
    const base::DictValue* inner = wrap->FindDict("_0");
    if (!inner) return std::nullopt;
    if (IsCorruptedEmptyShellTab(*inner)) {
      if (repairs_out) {
        repairs_out->push_back("dropped corrupted empty-shell tab");
      }
      return std::nullopt;
    }
    return SidebarNode(SnapshotStore::DeserializeTab(*inner));
  }
  if (const base::DictValue* wrap = d.FindDict("folder")) {
    const base::DictValue* inner = wrap->FindDict("_0");
    if (!inner) return std::nullopt;
    Folder f;
    f.id = SafeUuid(inner->FindString("id"));
    if (const std::string* title = inner->FindString("title")) {
      f.title = *title;
    }
    f.is_expanded = inner->FindBool("isExpanded").value_or(false);
    f.peeked_child_id = OptionalUuid(inner->FindString("peekedChildID"));
    if (const std::string* ci = inner->FindString("customIcon")) {
      f.custom_icon = *ci;
    }
    f.icon_override = DeserializeIcon(inner->FindDict("iconOverride"));
    if (const base::ListValue* children = inner->FindList("children")) {
      for (const base::Value& v : *children) {
        if (const base::DictValue* cd = v.GetIfDict()) {
          if (auto child = DeserializeNodeImpl(*cd, repairs_out)) {
            f.children.push_back(std::move(*child));
          }
        }
      }
    }
    if (const base::DictValue* ld = inner->FindDict("live")) {
      LiveFolderConfig cfg;
      if (const std::string* prov = ld->FindString("provider")) {
        cfg.provider = *prov;
      } else if (const std::string* src = ld->FindString("source")) {
        cfg.provider = *src;
      }
      if (const std::string* q = ld->FindString("query")) {
        cfg.query = *q;
      }
      cfg.refresh_interval_sec = ld->FindInt("refreshIntervalSec").value_or(300);
      cfg.enabled = ld->FindBool("enabled").value_or(true);
      f.live = std::move(cfg);
    }
    return SidebarNode(std::move(f));
  }
  if (const base::DictValue* wrap = d.FindDict("split")) {
    const base::DictValue* inner = wrap->FindDict("_0");
    if (!inner) return std::nullopt;
    Split s;
    s.id = SafeUuid(inner->FindString("id"));
    const std::string* orient = inner->FindString("orientation");
    s.orientation = (orient && *orient == "vertical")
                        ? SplitOrientation::kVertical
                        : SplitOrientation::kHorizontal;
    if (const base::ListValue* fracs = inner->FindList("fractions")) {
      for (const base::Value& v : *fracs) {
        if (v.is_double() || v.is_int()) {
          s.fractions.push_back(v.GetDouble());
        }
      }
    }
    if (const base::ListValue* panes = inner->FindList("panes")) {
      for (const base::Value& v : *panes) {
        if (const base::DictValue* pd = v.GetIfDict()) {
          if (IsCorruptedEmptyShellTab(*pd)) {
            if (repairs_out) {
              repairs_out->push_back("dropped corrupted empty-shell tab");
            }
            continue;
          }
          s.panes.push_back(SnapshotStore::DeserializeTab(*pd));
        }
      }
    }
    if (s.panes.empty()) {
      return std::nullopt;
    }
    if (s.panes.size() == 1) {
      return SidebarNode(std::move(s.panes.front()));
    }
    s.focused_pane_id = OptionalUuid(inner->FindString("focusedPaneID"));
    if (const std::string* ct = inner->FindString("customTitle")) {
      s.custom_title = *ct;
    }
    s.icon_override = DeserializeIcon(inner->FindDict("iconOverride"));
    return SidebarNode(std::move(s));
  }
  return std::nullopt;
}

}  // namespace

SnapshotStore::SnapshotStore(base::FilePath data_root)
    : data_root_(std::move(data_root)),
      file_path_(data_root_.AppendASCII("State").AppendASCII("browser.json")) {}

SnapshotStore::~SnapshotStore() {
  save_timer_.Stop();
  weak_factory_.InvalidateWeakPtrs();
  base::AutoLock lock(InlineIoStoresLock());
  InlineIoStores().erase(this);
}

void SnapshotStore::SetSaveFailureCallback(
    base::RepeatingCallback<void(const std::string&)> callback) {
  on_save_failure_ = std::move(callback);
}

void SnapshotStore::SetIoTaskRunner(
    scoped_refptr<base::SequencedTaskRunner> runner) {
  {
    base::AutoLock lock(InlineIoStoresLock());
    if (runner) {
      InlineIoStores().erase(this);
    } else {
      // Explicit nullptr switches this store to synchronous inline writes
      // (used during shutdown flush so browser.json lands on disk before exit).
      InlineIoStores().insert(this);
    }
  }
  io_runner_ = std::move(runner);
}

scoped_refptr<base::SequencedTaskRunner>
SnapshotStore::GetOrCreateIoTaskRunner() {
  {
    base::AutoLock lock(InlineIoStoresLock());
    if (InlineIoStores().contains(this)) {
      return nullptr;
    }
  }
  if (!io_runner_ && base::ThreadPoolInstance::Get()) {
    io_runner_ = base::ThreadPool::CreateSequencedTaskRunner(
        {base::MayBlock(), base::TaskPriority::USER_VISIBLE,
         base::TaskShutdownBehavior::BLOCK_SHUTDOWN});
  }
  return io_runner_;
}

void SnapshotStore::ScheduleSave(const BrowserModel* model) {
  if (!model) {
    return;
  }
  const base::TimeTicks now = base::TimeTicks::Now();
  // Respect 10s max wait: once elapsed, keep the active timer rather than
  // pushing it out again.
  if (dirty_since_.has_value() && (now - *dirty_since_) >= kMaxSaveWait &&
      save_timer_.IsRunning()) {
    dirty_model_ = model;
    return;
  }
  if (!dirty_model_ || !dirty_since_.has_value()) {
    dirty_since_ = now;
  }
  dirty_model_ = model;
  save_timer_.Start(FROM_HERE, kDebounceDelay,
                    base::BindOnce(&SnapshotStore::OnTimerFired,
                                   base::Unretained(this)));
}

void SnapshotStore::ScheduleMetadataSave(const BrowserModel* model) {
  if (!model) {
    return;
  }
  dirty_model_ = model;
  if (save_timer_.IsRunning()) {
    return;
  }
  if (!dirty_since_.has_value()) {
    dirty_since_ = base::TimeTicks::Now();
  }
  save_timer_.Start(FROM_HERE, kMetadataSaveDelay,
                    base::BindOnce(&SnapshotStore::OnTimerFired,
                                   base::Unretained(this)));
}

void SnapshotStore::OnTimerFired() {
  FlushAsync();
}

void SnapshotStore::OnAsyncWriteComplete(
    base::OnceCallback<void(bool ok, std::string error)> done,
    std::string error) {
  const bool ok = error.empty();
  if (!ok && on_save_failure_) {
    on_save_failure_.Run(error);
  }
  if (done) {
    std::move(done).Run(ok, std::move(error));
  }
}

void SnapshotStore::FlushAsync(
    base::OnceCallback<void(bool ok, std::string error)> done) {
  save_timer_.Stop();
  if (!dirty_model_) {
    if (done) {
      std::move(done).Run(true, {});
    }
    return;
  }
  const BrowserModel* model = dirty_model_;
  dirty_model_ = nullptr;
  dirty_since_.reset();

  base::DictValue root = SerializeModel(*model);
  std::string encoded;
  if (!base::JSONWriter::Write(root, &encoded)) {
    std::string err = "SnapshotStore: failed to serialize browser model to JSON";
    if (on_save_failure_) {
      on_save_failure_.Run(err);
    }
    if (done) {
      std::move(done).Run(false, std::move(err));
    }
    return;
  }

  const uint64_t generation = NextWriteGeneration(file_path_);
  if (auto runner = GetOrCreateIoTaskRunner()) {
    runner->PostTaskAndReplyWithResult(
        FROM_HERE,
        base::BindOnce(&WriteSnapshotOnIoSequence, file_path_,
                       std::move(encoded), generation),
        base::BindOnce(&SnapshotStore::OnAsyncWriteComplete,
                       weak_factory_.GetWeakPtr(), std::move(done)));
    return;
  }

  std::string err =
      WriteSnapshotOnIoSequence(file_path_, std::move(encoded), generation);
  OnAsyncWriteComplete(std::move(done), std::move(err));
}

bool SnapshotStore::SaveNow(const BrowserModel& model, std::string* error_out) {
  save_timer_.Stop();
  dirty_model_ = nullptr;
  dirty_since_.reset();

  base::DictValue root = SerializeModel(model);
  std::string encoded;
  if (!base::JSONWriter::Write(root, &encoded)) {
    if (error_out) {
      *error_out = "SnapshotStore: failed to serialize browser model to JSON";
    }
    return false;
  }

  const uint64_t generation = NextWriteGeneration(file_path_);
  const bool on_ui_thread =
      content::BrowserThread::IsThreadInitialized(content::BrowserThread::UI) &&
      content::BrowserThread::CurrentlyOn(content::BrowserThread::UI);
  if (on_ui_thread) {
    if (auto runner = GetOrCreateIoTaskRunner()) {
      // Never perform blocking disk I/O on BrowserThread::UI during normal
      // operation; the runner uses BLOCK_SHUTDOWN so writes finish cleanly.
      runner->PostTaskAndReplyWithResult(
          FROM_HERE,
          base::BindOnce(&WriteSnapshotOnIoSequence, file_path_,
                         std::move(encoded), generation),
          base::BindOnce(&SnapshotStore::OnAsyncWriteComplete,
                         weak_factory_.GetWeakPtr(),
                         base::OnceCallback<void(bool, std::string)>()));
      return true;
    }
  }

  std::string err =
      WriteSnapshotOnIoSequence(file_path_, std::move(encoded), generation);
  if (!err.empty()) {
    if (error_out) {
      *error_out = std::move(err);
    }
    return false;
  }
  return true;
}

bool SnapshotStore::Flush(std::string* error_out) {
  if (!dirty_model_) {
    return true;
  }
  const BrowserModel* model = dirty_model_;
  return SaveNow(*model, error_out);
}

std::unique_ptr<BrowserModel> SnapshotStore::Load(
    std::vector<std::string>* repairs_out,
    std::string* error_out) const {
  if (!base::PathExists(file_path_)) {
    return nullptr;
  }
  std::string raw;
  if (!base::ReadFileToString(file_path_, &raw)) {
    if (error_out) {
      *error_out = "SnapshotStore: failed to read browser.json";
    }
    MoveCorruptSnapshotAside(file_path_);
    return nullptr;
  }
  auto parsed = base::JSONReader::ReadDict(raw, base::JSON_PARSE_RFC);
  if (!parsed.has_value()) {
    if (error_out) {
      *error_out = "SnapshotStore: invalid JSON in browser.json";
    }
    MoveCorruptSnapshotAside(file_path_);
    return nullptr;
  }
  auto model = DeserializeModel(*parsed, repairs_out, error_out);
  if (!model) {
    MoveCorruptSnapshotAside(file_path_);
    return nullptr;
  }
  return model;
}

// --- Static Serialization / Deserialization ---

base::DictValue SnapshotStore::SerializeTab(const Tab& t) {
  base::DictValue d;
  d.Set("id", t.id);
  d.Set("url", t.url);
  d.Set("title", t.title);
  if (t.custom_title.has_value()) {
    d.Set("customTitle", *t.custom_title);
  }
  if (t.pinned_url.has_value()) {
    d.Set("pinnedURL", *t.pinned_url);
  }
  if (t.custom_icon.has_value()) {
    d.Set("customIcon", *t.custom_icon);
  }
  if (t.icon_override.has_value()) {
    d.Set("iconOverride", SerializeIcon(*t.icon_override));
  }
  d.Set("createdAt", t.created_at);
  d.Set("lastActiveAt", t.last_active_at);
  d.Set("isMuted", t.is_muted);
  if (t.opener_id.has_value()) {
    d.Set("openerID", *t.opener_id);
  }
  d.Set("isUnread", t.is_unread);
  if (t.live_item_url.has_value()) {
    d.Set("liveItemURL", *t.live_item_url);
  }
  if (t.live_item.has_value()) {
    base::DictValue li;
    li.Set("sourceKind", t.live_item->source_kind);
    li.Set("subtitle", t.live_item->subtitle);
    li.Set("statusBadge", t.live_item->status_badge);
    li.Set("updatedAt", t.live_item->updated_at);
    d.Set("liveItem", std::move(li));
  }
  return d;
}

Tab SnapshotStore::DeserializeTab(const base::DictValue& d) {
  Tab t;
  t.id = SafeUuid(d.FindString("id"));
  if (const std::string* url = d.FindString("url")) {
    t.url = *url;
  } else {
    t.url = "about:blank";
  }
  if (const std::string* title = d.FindString("title")) {
    t.title = *title;
  }
  if (const std::string* ct = d.FindString("customTitle")) {
    t.custom_title = *ct;
  }
  if (const std::string* pu = d.FindString("pinnedURL")) {
    t.pinned_url = *pu;
  }
  if (const std::string* ci = d.FindString("customIcon")) {
    t.custom_icon = *ci;
  }
  t.icon_override = DeserializeIcon(d.FindDict("iconOverride"));
  t.created_at = FiniteOr(d.FindDouble("createdAt"), 0.0);
  t.last_active_at = FiniteOr(d.FindDouble("lastActiveAt"), t.created_at);
  t.is_muted = d.FindBool("isMuted").value_or(false);
  t.opener_id = OptionalUuid(d.FindString("openerID"));
  t.is_unread = d.FindBool("isUnread").value_or(false);
  if (const std::string* lu = d.FindString("liveItemURL")) {
    t.live_item_url = *lu;
  }
  if (t.live_item_url.has_value()) {
    if (const base::DictValue* li = d.FindDict("liveItem")) {
      LiveItemInfo info;
      if (const std::string* sk = li->FindString("sourceKind")) {
        info.source_kind = *sk;
      }
      if (const std::string* sub = li->FindString("subtitle")) {
        info.subtitle = *sub;
      }
      if (const std::string* sb = li->FindString("statusBadge")) {
        info.status_badge = *sb;
      }
      info.updated_at = FiniteOr(li->FindDouble("updatedAt"), 0.0);
      t.live_item = std::move(info);
    }
  }
  return t;
}

base::DictValue SnapshotStore::SerializeNode(const SidebarNode& node) {
  base::DictValue outer;
  base::DictValue wrapper;
  if (const Tab* tab = node.as_tab()) {
    wrapper.Set("_0", SerializeTab(*tab));
    outer.Set("tab", std::move(wrapper));
  } else if (const Folder* folder = node.as_folder()) {
    base::DictValue fd;
    fd.Set("id", folder->id);
    fd.Set("title", folder->title);
    fd.Set("isExpanded", folder->is_expanded);
    if (folder->peeked_child_id.has_value()) {
      fd.Set("peekedChildID", *folder->peeked_child_id);
    }
    if (folder->custom_icon.has_value()) {
      fd.Set("customIcon", *folder->custom_icon);
    }
    if (folder->icon_override.has_value()) {
      fd.Set("iconOverride", SerializeIcon(*folder->icon_override));
    }
    base::ListValue children;
    for (const SidebarNode& child : folder->children) {
      children.Append(SerializeNode(child));
    }
    fd.Set("children", std::move(children));
    if (folder->live.has_value()) {
      base::DictValue ld;
      ld.Set("provider", folder->live->provider);
      ld.Set("query", folder->live->query);
      ld.Set("refreshIntervalSec", folder->live->refresh_interval_sec);
      ld.Set("enabled", folder->live->enabled);
      fd.Set("live", std::move(ld));
    }
    wrapper.Set("_0", std::move(fd));
    outer.Set("folder", std::move(wrapper));
  } else if (const Split* split = node.as_split()) {
    base::DictValue sd;
    sd.Set("id", split->id);
    sd.Set("orientation", split->orientation == SplitOrientation::kVertical
                              ? "vertical"
                              : "horizontal");
    base::ListValue fracs;
    for (double f : split->fractions) {
      fracs.Append(f);
    }
    sd.Set("fractions", std::move(fracs));
    base::ListValue panes;
    for (const Tab& pane : split->panes) {
      panes.Append(SerializeTab(pane));
    }
    sd.Set("panes", std::move(panes));
    if (split->focused_pane_id.has_value()) {
      sd.Set("focusedPaneID", *split->focused_pane_id);
    }
    if (split->custom_title.has_value()) {
      sd.Set("customTitle", *split->custom_title);
    }
    if (split->icon_override.has_value()) {
      sd.Set("iconOverride", SerializeIcon(*split->icon_override));
    }
    wrapper.Set("_0", std::move(sd));
    outer.Set("split", std::move(wrapper));
  }
  return outer;
}

std::optional<SidebarNode> SnapshotStore::DeserializeNode(
    const base::DictValue& d) {
  return DeserializeNodeImpl(d, nullptr);
}

base::DictValue SnapshotStore::SerializeModel(const BrowserModel& model) {
  base::DictValue root;
  root.Set("schemaVersion", kSchemaVersion);

  base::ListValue profiles;
  for (const Profile& p : model.profiles()) {
    base::DictValue pd;
    pd.Set("id", p.id);
    pd.Set("name", p.name);
    if (p.icon.has_value()) {
      pd.Set("icon", SerializeIcon(*p.icon));
    }
    base::ListValue favs;
    for (const Tab& fav : p.favorites) {
      favs.Append(SerializeNode(SidebarNode(fav)));
    }
    pd.Set("favorites", std::move(favs));
    pd.Set("settings", SerializeProfileSettings(p.settings));
    pd.Set("dataDirectoryName", p.data_directory_name);
    if (p.favorites_empty_state_dismissed) {
      pd.Set("favoritesEmptyStateDismissed", true);
    }
    profiles.Append(std::move(pd));
  }
  root.Set("profiles", std::move(profiles));

  base::ListValue spaces;
  for (const Space& s : model.spaces()) {
    base::DictValue sd;
    sd.Set("id", s.id);
    if (s.title.has_value()) {
      sd.Set("title", *s.title);
    }
    if (s.icon.has_value()) {
      sd.Set("icon", SerializeIcon(*s.icon));
    }
    sd.Set("theme", SerializeTheme(s.theme));
    sd.Set("profileID", s.profile_id);
    base::ListValue pinned;
    for (const SidebarNode& n : s.pinned) {
      pinned.Append(SerializeNode(n));
    }
    sd.Set("pinned", std::move(pinned));
    base::ListValue today;
    for (const SidebarNode& n : s.today) {
      today.Append(SerializeNode(n));
    }
    sd.Set("today", std::move(today));
    sd.Set("isPinnedCollapsed", s.is_pinned_collapsed);
    spaces.Append(std::move(sd));
  }
  root.Set("spaces", std::move(spaces));

  base::ListValue windows;
  for (const BrowserWindowState& w : model.windows()) {
    base::DictValue wd;
    wd.Set("id", w.id);
    wd.Set("focusedSpaceID", w.focused_space_id);
    base::DictValue sel;
    for (const auto& [space_id, node_id] : w.selected_node_by_space) {
      sel.Set(space_id, node_id);
    }
    wd.Set("selectedNodeBySpace", std::move(sel));
    wd.Set("sidebarWidth", w.sidebar_width);
    wd.Set("sidebarMode",
           w.sidebar_mode == SidebarMode::kHidden ? "hidden" : "anchored");
    wd.Set("frameX", w.frame_x);
    wd.Set("frameY", w.frame_y);
    wd.Set("frameWidth", w.frame_width);
    wd.Set("frameHeight", w.frame_height);
    wd.Set("style",
           w.style == WindowStyle::kLittleOpen ? "littleOpen" : "standard");
    wd.Set("stayOnTop", w.stay_on_top);
    if (w.shows_toolbar) {
      wd.Set("showsToolbar", true);
    }
    if (w.last_focused_at.has_value()) {
      wd.Set("lastFocusedAt", *w.last_focused_at);
    }
    windows.Append(std::move(wd));
  }
  root.Set("windows", std::move(windows));

  base::ListValue rules;
  for (const RoutingRule& r : model.routing_rules()) {
    rules.Append(SerializeRoutingRule(r));
  }
  root.Set("routingRules", std::move(rules));
  root.Set("defaultDestination",
           SerializeDestination(model.default_destination()));
  return root;
}

std::unique_ptr<BrowserModel> SnapshotStore::DeserializeModel(
    const base::DictValue& root,
    std::vector<std::string>* repairs_out,
    std::string* error_out) {
  auto schema = root.FindInt("schemaVersion");
  if (!schema.has_value() || *schema != kSchemaVersion) {
    if (error_out) {
      *error_out = "SnapshotStore: unsupported or missing schemaVersion";
    }
    return nullptr;
  }

  std::vector<Profile> profiles;
  if (const base::ListValue* plist = root.FindList("profiles")) {
    for (const base::Value& v : *plist) {
      const base::DictValue* pd = v.GetIfDict();
      if (!pd) continue;
      Profile p;
      p.id = SafeUuid(pd->FindString("id"));
      if (const std::string* name = pd->FindString("name")) {
        p.name = *name;
      } else {
        p.name = "Default";
      }
      p.icon = DeserializeIcon(pd->FindDict("icon"));
      if (const base::ListValue* favs = pd->FindList("favorites")) {
        for (const base::Value& fv : *favs) {
          if (const base::DictValue* fd = fv.GetIfDict()) {
            if (auto node = DeserializeNodeImpl(*fd, repairs_out);
                node && node->as_tab()) {
              p.favorites.push_back(std::move(*node->as_tab()));
            }
          }
        }
      }
      p.settings = DeserializeProfileSettings(pd->FindDict("settings"));
      if (const std::string* dir = pd->FindString("dataDirectoryName")) {
        p.data_directory_name = *dir;
      }
      p.favorites_empty_state_dismissed =
          pd->FindBool("favoritesEmptyStateDismissed").value_or(false);
      profiles.push_back(std::move(p));
    }
  }

  std::vector<Space> spaces;
  if (const base::ListValue* slist = root.FindList("spaces")) {
    for (const base::Value& v : *slist) {
      const base::DictValue* sd = v.GetIfDict();
      if (!sd) continue;
      Space s;
      s.id = SafeUuid(sd->FindString("id"));
      if (const std::string* title = sd->FindString("title")) {
        s.title = *title;
      }
      s.icon = DeserializeIcon(sd->FindDict("icon"));
      s.theme = DeserializeTheme(sd->FindDict("theme"));
      s.profile_id = SafeUuid(sd->FindString("profileID"));
      if (const base::ListValue* pinned = sd->FindList("pinned")) {
        for (const base::Value& nv : *pinned) {
          if (const base::DictValue* nd = nv.GetIfDict()) {
            if (auto node = DeserializeNodeImpl(*nd, repairs_out)) {
              s.pinned.push_back(std::move(*node));
            }
          }
        }
      }
      if (const base::ListValue* today = sd->FindList("today")) {
        for (const base::Value& nv : *today) {
          if (const base::DictValue* nd = nv.GetIfDict()) {
            if (auto node = DeserializeNodeImpl(*nd, repairs_out)) {
              s.today.push_back(std::move(*node));
            }
          }
        }
      }
      s.is_pinned_collapsed = sd->FindBool("isPinnedCollapsed").value_or(false);
      spaces.push_back(std::move(s));
    }
  }

  RepairDuplicateIds(&profiles, &spaces, repairs_out);

  std::vector<BrowserWindowState> windows;
  if (const base::ListValue* wlist = root.FindList("windows")) {
    for (const base::Value& v : *wlist) {
      const base::DictValue* wd = v.GetIfDict();
      if (!wd) continue;
      BrowserWindowState w;
      w.id = SafeUuid(wd->FindString("id"));
      w.focused_space_id = SafeUuid(wd->FindString("focusedSpaceID"));
      if (const base::DictValue* sel = wd->FindDict("selectedNodeBySpace")) {
        for (const auto [k, val] : *sel) {
          if (!val.is_string()) continue;
          auto sid = NormalizeUuid(k);
          auto nid = NormalizeUuid(val.GetString());
          if (sid.has_value() && nid.has_value()) {
            w.selected_node_by_space[*sid] = *nid;
          }
        }
      }
      w.sidebar_width = FiniteOr(wd->FindDouble("sidebarWidth"), 228.0);
      const std::string* mode = wd->FindString("sidebarMode");
      w.sidebar_mode = (mode && *mode == "hidden") ? SidebarMode::kHidden
                                                   : SidebarMode::kAnchored;
      w.frame_x = FiniteOr(wd->FindDouble("frameX"), 100.0);
      w.frame_y = FiniteOr(wd->FindDouble("frameY"), 100.0);
      w.frame_width = FiniteOr(wd->FindDouble("frameWidth"), 1280.0);
      w.frame_height = FiniteOr(wd->FindDouble("frameHeight"), 800.0);
      const std::string* style = wd->FindString("style");
      if (style && (*style == "littleOpen" || *style == "littleArc")) {
        w.style = WindowStyle::kLittleOpen;
      } else {
        w.style = WindowStyle::kStandard;
      }
      w.stay_on_top = wd->FindBool("stayOnTop").value_or(false);
      w.shows_toolbar = wd->FindBool("showsToolbar").value_or(false);
      if (auto lfa = wd->FindDouble("lastFocusedAt");
          lfa.has_value() && std::isfinite(*lfa)) {
        w.last_focused_at = *lfa;
      }
      windows.push_back(std::move(w));
    }
  }

  std::vector<RoutingRule> rules;
  if (const base::ListValue* rlist = root.FindList("routingRules")) {
    for (const base::Value& v : *rlist) {
      if (const base::DictValue* rd = v.GetIfDict()) {
        rules.push_back(DeserializeRoutingRule(*rd));
      }
    }
  }

  RoutingDestination default_dest =
      DeserializeDestination(root.FindDict("defaultDestination"));

  return std::make_unique<BrowserModel>(
      std::move(profiles), std::move(spaces), std::move(windows),
      std::move(rules), std::move(default_dest));
}

}  // namespace open_unified
