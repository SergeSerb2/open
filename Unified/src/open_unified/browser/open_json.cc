// Copyright 2026 The Open Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "open_unified/browser/open_json.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <utility>

#include "base/strings/string_util.h"

namespace open_unified::json {

namespace {

// Upper bounds for renderer-supplied documents (WebUI payloads).
constexpr size_t kMaxStringBytes = 4 * 1024 * 1024;
constexpr size_t kMaxListItems = 10000;

template <typename Enum, size_t N>
std::optional<Enum> ParseFromTable(
    const std::array<std::pair<Enum, std::string_view>, N>& table,
    std::string_view value) {
  for (const auto& [e, name] : table) {
    if (name == value) {
      return e;
    }
  }
  return std::nullopt;
}

template <typename Enum, size_t N>
std::string_view NameFromTable(
    const std::array<std::pair<Enum, std::string_view>, N>& table,
    Enum value) {
  for (const auto& [e, name] : table) {
    if (e == value) {
      return name;
    }
  }
  return table[0].second;
}

constexpr std::array<std::pair<ThemeWheel, std::string_view>, 2> kWheels = {{
    {ThemeWheel::kAnalogous, "analogous"},
    {ThemeWheel::kComplementary, "complementary"},
}};
constexpr std::array<std::pair<ThemeAppearance, std::string_view>, 3>
    kAppearances = {{
        {ThemeAppearance::kAutomatic, "automatic"},
        {ThemeAppearance::kLight, "light"},
        {ThemeAppearance::kDark, "dark"},
    }};
constexpr std::array<std::pair<ThemeTexture, std::string_view>, 4> kTextures =
    {{
        {ThemeTexture::kGrain, "grain"},
        {ThemeTexture::kSand, "sand"},
        {ThemeTexture::kDenim, "denim"},
        {ThemeTexture::kTweed, "tweed"},
    }};
constexpr std::array<std::pair<SpaceIconKind, std::string_view>, 3>
    kIconKinds = {{
        {SpaceIconKind::kEmoji, "emoji"},
        {SpaceIconKind::kSymbol, "symbol"},
        {SpaceIconKind::kNamed, "named"},
    }};
constexpr std::array<std::pair<AutoArchiveInterval, std::string_view>, 7>
    kArchiveIntervals = {{
        {AutoArchiveInterval::kNever, "never"},
        {AutoArchiveInterval::kOneHour, "1h"},
        {AutoArchiveInterval::kSixHours, "6h"},
        {AutoArchiveInterval::kTwelveHours, "12h"},
        {AutoArchiveInterval::kTwentyFourHours, "24h"},
        {AutoArchiveInterval::kSevenDays, "7d"},
        {AutoArchiveInterval::kThirtyDays, "30d"},
    }};
constexpr std::array<std::pair<SleepMode, std::string_view>, 4> kSleepModes = {
    {
        {SleepMode::kOff, "off"},
        {SleepMode::kConservative, "conservative"},
        {SleepMode::kBalanced, "balanced"},
        {SleepMode::kAggressive, "aggressive"},
    }};
constexpr std::array<std::pair<RoutingDestinationKind, std::string_view>, 3>
    kRoutingKinds = {{
        {RoutingDestinationKind::kSpace, "space"},
        {RoutingDestinationKind::kLittleOpen, "little_open"},
        {RoutingDestinationKind::kMostRecentSpace, "most_recent_space"},
    }};
constexpr std::array<std::pair<SleepPhase, std::string_view>, 4> kSleepPhases =
    {{
        {SleepPhase::kPlaceholder, "placeholder"},
        {SleepPhase::kLive, "live"},
        {SleepPhase::kFrozen, "frozen"},
        {SleepPhase::kSleeping, "sleeping"},
    }};
constexpr std::array<std::pair<NodeParentKind, std::string_view>, 5>
    kParentKinds = {{
        {NodeParentKind::kSpacePinned, "pinned"},
        {NodeParentKind::kSpaceToday, "today"},
        {NodeParentKind::kFolder, "folder"},
        {NodeParentKind::kFavorites, "favorites"},
        {NodeParentKind::kSplitPane, "split"},
    }};

double Clamp01(double v) {
  return std::isfinite(v) ? std::clamp(v, 0.0, 1.0) : 0.0;
}

bool IsSane(const std::string& s) {
  return s.size() <= kMaxStringBytes &&
         base::IsStringUTF8AllowingNoncharacters(s);
}

void SetOptionalString(base::DictValue& dict,
                       std::string_view key,
                       const std::optional<std::string>& value) {
  if (value.has_value()) {
    dict.Set(key, *value);
  }
}

}  // namespace

std::string_view ThemeWheelName(ThemeWheel v) {
  return NameFromTable(kWheels, v);
}
std::string_view ThemeAppearanceName(ThemeAppearance v) {
  return NameFromTable(kAppearances, v);
}
std::string_view ThemeTextureName(ThemeTexture v) {
  return NameFromTable(kTextures, v);
}
std::string_view SpaceIconKindName(SpaceIconKind v) {
  return NameFromTable(kIconKinds, v);
}
std::string_view AutoArchiveIntervalName(AutoArchiveInterval v) {
  return NameFromTable(kArchiveIntervals, v);
}
std::string_view SleepModeName(SleepMode v) {
  return NameFromTable(kSleepModes, v);
}
std::string_view RoutingDestinationKindName(RoutingDestinationKind v) {
  return NameFromTable(kRoutingKinds, v);
}
std::string_view SleepPhaseName(SleepPhase v) {
  return NameFromTable(kSleepPhases, v);
}
std::string_view NodeParentKindName(NodeParentKind v) {
  return NameFromTable(kParentKinds, v);
}

std::optional<ThemeWheel> ParseThemeWheel(std::string_view v) {
  return ParseFromTable(kWheels, v);
}
std::optional<ThemeAppearance> ParseThemeAppearance(std::string_view v) {
  return ParseFromTable(kAppearances, v);
}
std::optional<ThemeTexture> ParseThemeTexture(std::string_view v) {
  return ParseFromTable(kTextures, v);
}
std::optional<SpaceIconKind> ParseSpaceIconKind(std::string_view v) {
  return ParseFromTable(kIconKinds, v);
}
std::optional<AutoArchiveInterval> ParseAutoArchiveInterval(
    std::string_view v) {
  return ParseFromTable(kArchiveIntervals, v);
}
std::optional<SleepMode> ParseSleepMode(std::string_view v) {
  return ParseFromTable(kSleepModes, v);
}
std::optional<RoutingDestinationKind> ParseRoutingDestinationKind(
    std::string_view v) {
  return ParseFromTable(kRoutingKinds, v);
}

// --- Leaf types -----------------------------------------------------------

base::DictValue ColorToValue(const RGBAColor& c) {
  return base::DictValue()
      .Set("r", c.r)
      .Set("g", c.g)
      .Set("b", c.b)
      .Set("a", c.a);
}

std::optional<RGBAColor> ColorFromValue(const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const base::DictValue& d = value->GetDict();
  RGBAColor c;
  c.r = Clamp01(GetDouble(d, "r", 0.0));
  c.g = Clamp01(GetDouble(d, "g", 0.0));
  c.b = Clamp01(GetDouble(d, "b", 0.0));
  c.a = Clamp01(GetDouble(d, "a", 1.0));
  return c;
}

base::DictValue SpaceIconToValue(const SpaceIcon& icon) {
  return base::DictValue()
      .Set("kind", SpaceIconKindName(icon.kind))
      .Set("value", icon.value);
}

std::optional<SpaceIcon> SpaceIconFromValue(const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const base::DictValue& d = value->GetDict();
  auto kind = ParseSpaceIconKind(GetString(d, "kind"));
  std::string icon_value = GetString(d, "value");
  if (!kind || icon_value.empty() || icon_value.size() > 256 ||
      !IsSane(icon_value)) {
    return std::nullopt;
  }
  return SpaceIcon{*kind, std::move(icon_value)};
}

base::DictValue SpaceStyleToValue(const SpaceStyle& s) {
  return base::DictValue()
      .Set("math_version", s.math_version)
      .Set("key_color", ColorToValue(s.key_color))
      .Set("color_count", s.color_count)
      .Set("wheel", ThemeWheelName(s.wheel))
      .Set("appearance", ThemeAppearanceName(s.appearance))
      .Set("noise_factor", s.noise_factor)
      .Set("texture", ThemeTextureName(s.texture))
      .Set("intensity_factor", s.intensity_factor);
}

std::optional<SpaceStyle> SpaceStyleFromValue(const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const base::DictValue& d = value->GetDict();
  SpaceStyle s;
  s.math_version = std::clamp(GetInt(d, "math_version", 1), 1, 16);
  auto key = ColorFromValue(d.Find("key_color"));
  if (!key) {
    return std::nullopt;
  }
  s.key_color = *key;
  s.color_count = std::clamp(GetInt(d, "color_count", 2), 1, 3);
  auto wheel = ParseThemeWheel(GetString(d, "wheel", "analogous"));
  auto appearance =
      ParseThemeAppearance(GetString(d, "appearance", "automatic"));
  auto texture = ParseThemeTexture(GetString(d, "texture", "grain"));
  if (!wheel || !appearance || !texture) {
    return std::nullopt;
  }
  s.wheel = *wheel;
  s.appearance = *appearance;
  s.texture = *texture;
  s.noise_factor = Clamp01(GetDouble(d, "noise_factor", 0.0));
  s.intensity_factor = Clamp01(GetDouble(d, "intensity_factor", 0.6));
  return s;
}

base::DictValue SpaceThemeToValue(const SpaceTheme& theme) {
  base::DictValue d;
  auto set_color = [&](std::string_view key,
                       const std::optional<RGBAColor>& color) {
    if (color) {
      d.Set(key, ColorToValue(*color));
    }
  };
  set_color("light_background", theme.light_background);
  set_color("dark_background", theme.dark_background);
  set_color("light_foreground", theme.light_foreground);
  set_color("dark_foreground", theme.dark_foreground);
  set_color("accent", theme.accent);
  auto stops = [](const std::vector<GradientStop>& in) {
    base::ListValue list;
    for (const auto& stop : in) {
      list.Append(base::DictValue()
                      .Set("location", stop.location)
                      .Set("color", ColorToValue(stop.color)));
    }
    return list;
  };
  d.Set("gradient_stops_light", stops(theme.gradient_stops_light));
  d.Set("gradient_stops_dark", stops(theme.gradient_stops_dark));
  if (theme.style) {
    d.Set("style", SpaceStyleToValue(*theme.style));
  }
  return d;
}

// --- Model types ------------------------------------------------------------

base::DictValue TabLiveStateToValue(const TabLiveState& live) {
  base::DictValue d;
  d.Set("has_web_content", live.has_web_content);
  d.Set("has_loaded_in_this_launch", live.has_loaded_in_this_launch);
  d.Set("sleep_phase", SleepPhaseName(live.sleep_phase));
  d.Set("is_capturing_media", live.is_capturing_media);
  d.Set("devtools_open", live.devtools_open);
  d.Set("is_loading", live.is_loading);
  d.Set("progress", live.progress);
  d.Set("is_audible", live.is_audible);
  d.Set("is_crashed", live.is_crashed);
  d.Set("can_go_back", live.can_go_back);
  d.Set("can_go_forward", live.can_go_forward);
  d.Set("has_favicon", !live.favicon_png.empty());
  if (live.page_background_color) {
    d.Set("page_background_color", ColorToValue(*live.page_background_color));
  }
  return d;
}

base::DictValue TabToValue(const Tab& tab) {
  base::DictValue d;
  d.Set("id", tab.id);
  d.Set("kind", "tab");
  d.Set("url", tab.url);
  d.Set("title", tab.display_title());
  SetOptionalString(d, "custom_title", tab.custom_title);
  SetOptionalString(d, "pinned_url", tab.pinned_url);
  d.Set("created_at", tab.created_at);
  d.Set("last_active_at", tab.last_active_at);
  d.Set("is_muted", tab.is_muted);
  d.Set("is_unread", tab.is_unread);
  SetOptionalString(d, "opener_id", tab.opener_id);
  if (tab.icon_override) {
    d.Set("icon_override", SpaceIconToValue(*tab.icon_override));
  }
  d.Set("live", TabLiveStateToValue(tab.live_state));
  return d;
}

base::DictValue SidebarNodeToValue(const SidebarNode& node) {
  if (const Tab* tab = node.as_tab()) {
    return TabToValue(*tab);
  }
  if (const Folder* folder = node.as_folder()) {
    base::ListValue children;
    for (const auto& child : folder->children) {
      children.Append(SidebarNodeToValue(child));
    }
    base::DictValue d;
    d.Set("id", folder->id);
    d.Set("kind", "folder");
    d.Set("title", folder->title);
    d.Set("expanded", folder->is_expanded);
    SetOptionalString(d, "peeked_child_id", folder->peeked_child_id);
    d.Set("live", folder->live.has_value());
    d.Set("children", std::move(children));
    return d;
  }
  const Split& split = *node.as_split();
  base::ListValue panes;
  for (const auto& pane : split.panes) {
    panes.Append(TabToValue(pane));
  }
  base::ListValue fractions;
  for (double f : split.fractions) {
    fractions.Append(f);
  }
  base::DictValue d;
  d.Set("id", split.id);
  d.Set("kind", "split");
  d.Set("orientation", split.orientation == SplitOrientation::kHorizontal
                           ? "horizontal"
                           : "vertical");
  d.Set("fractions", std::move(fractions));
  d.Set("panes", std::move(panes));
  SetOptionalString(d, "focused_pane_id", split.focused_pane_id);
  return d;
}

base::DictValue ProfileSettingsToValue(const ProfileSettings& s) {
  base::ListValue engines;
  for (const auto& engine : s.custom_search_engines) {
    engines.Append(base::DictValue()
                       .Set("id", engine.id)
                       .Set("name", engine.name)
                       .Set("keyword", engine.keyword)
                       .Set("url_template", engine.url_template));
  }
  base::ListValue keep_alive;
  for (const auto& site : s.keep_alive_sites) {
    keep_alive.Append(site);
  }
  return base::DictValue()
      .Set("auto_archive_after", AutoArchiveIntervalName(s.auto_archive_after))
      .Set("little_open_auto_archive_after",
           AutoArchiveIntervalName(s.little_open_auto_archive_after))
      .Set("search_suggest_enabled", s.search_suggest_enabled)
      .Set("download_directory", s.download_directory)
      .Set("ask_where_to_save_each_file", s.ask_where_to_save_each_file)
      .Set("search_engine_id", s.search_engine_id)
      .Set("custom_search_engines", std::move(engines))
      .Set("sleep_mode", SleepModeName(s.sleep_mode))
      .Set("keep_alive_sites", std::move(keep_alive))
      .Set("default_document_app", s.default_document_app);
}

bool ApplyProfileSettings(const base::DictValue& d, ProfileSettings* out) {
  ProfileSettings s = *out;
  if (const std::string* v = d.FindString("auto_archive_after")) {
    auto parsed = ParseAutoArchiveInterval(*v);
    if (!parsed) return false;
    s.auto_archive_after = *parsed;
  }
  if (const std::string* v = d.FindString("little_open_auto_archive_after")) {
    auto parsed = ParseAutoArchiveInterval(*v);
    if (!parsed) return false;
    s.little_open_auto_archive_after = *parsed;
  }
  if (auto v = d.FindBool("search_suggest_enabled")) {
    s.search_suggest_enabled = *v;
  }
  if (const std::string* v = d.FindString("download_directory")) {
    if (v->empty() || !IsSane(*v)) return false;
    s.download_directory = *v;
  }
  if (auto v = d.FindBool("ask_where_to_save_each_file")) {
    s.ask_where_to_save_each_file = *v;
  }
  if (const std::string* v = d.FindString("search_engine_id")) {
    if (v->empty() || v->size() > 128) return false;
    s.search_engine_id = *v;
  }
  if (const std::string* v = d.FindString("sleep_mode")) {
    auto parsed = ParseSleepMode(*v);
    if (!parsed) return false;
    s.sleep_mode = *parsed;
  }
  if (const base::ListValue* list = d.FindList("keep_alive_sites")) {
    if (list->size() > kMaxListItems) return false;
    s.keep_alive_sites.clear();
    for (const auto& item : *list) {
      if (!item.is_string() || !IsSane(item.GetString())) return false;
      s.keep_alive_sites.push_back(base::ToLowerASCII(item.GetString()));
    }
  }
  if (const base::ListValue* list = d.FindList("custom_search_engines")) {
    if (list->size() > 256) return false;
    s.custom_search_engines.clear();
    for (const auto& item : *list) {
      if (!item.is_dict()) return false;
      const auto& e = item.GetDict();
      CustomSearchEngine engine;
      engine.id = GetString(e, "id");
      engine.name = GetString(e, "name");
      engine.keyword = GetString(e, "keyword");
      engine.url_template = GetString(e, "url_template");
      if (engine.id.empty() ||
          engine.url_template.find("%s") == std::string::npos) {
        return false;
      }
      s.custom_search_engines.push_back(std::move(engine));
    }
  }
  if (const std::string* v = d.FindString("default_document_app")) {
    if (*v != "note" && *v != "easel") return false;
    s.default_document_app = *v;
  }
  *out = std::move(s);
  return true;
}

base::DictValue RoutingDestinationToValue(const RoutingDestination& dest) {
  base::DictValue d;
  d.Set("kind", RoutingDestinationKindName(dest.kind));
  SetOptionalString(d, "space_id", dest.space_id);
  SetOptionalString(d, "profile_id", dest.profile_id);
  return d;
}

std::optional<RoutingDestination> RoutingDestinationFromValue(
    const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const auto& d = value->GetDict();
  auto kind = ParseRoutingDestinationKind(GetString(d, "kind"));
  if (!kind) {
    return std::nullopt;
  }
  RoutingDestination dest;
  dest.kind = *kind;
  dest.space_id = FindString(d, "space_id");
  dest.profile_id = FindString(d, "profile_id");
  if (dest.kind == RoutingDestinationKind::kSpace && !dest.space_id) {
    return std::nullopt;
  }
  return dest;
}

base::DictValue RoutingRuleToValue(const RoutingRule& rule) {
  base::DictValue d;
  d.Set("id", rule.id);
  d.Set("name", rule.name);
  d.Set("host_pattern", rule.host_pattern);
  SetOptionalString(d, "path_prefix", rule.path_prefix);
  SetOptionalString(d, "source_app_id", rule.source_app_id);
  d.Set("destination", RoutingDestinationToValue(rule.destination));
  d.Set("enabled", rule.enabled);
  return d;
}

std::optional<RoutingRule> RoutingRuleFromValue(const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const auto& d = value->GetDict();
  RoutingRule rule;
  rule.id = GetString(d, "id");
  rule.name = GetString(d, "name");
  rule.host_pattern = base::ToLowerASCII(GetString(d, "host_pattern"));
  rule.path_prefix = FindString(d, "path_prefix");
  rule.source_app_id = FindString(d, "source_app_id");
  rule.enabled = GetBool(d, "enabled", true);
  auto dest = RoutingDestinationFromValue(d.Find("destination"));
  if (!dest || rule.host_pattern.empty() || rule.host_pattern.size() > 253 ||
      !IsSane(rule.name)) {
    return std::nullopt;
  }
  rule.destination = *dest;
  return rule;
}

// --- Library records --------------------------------------------------------

base::DictValue HistoryEntryToValue(const HistoryEntry& e,
                                      const ProfileID& profile_id) {
  return base::DictValue()
      .Set("id", static_cast<double>(e.id))
      .Set("url", e.url)
      .Set("title", e.title)
      .Set("visit_count", e.visit_count)
      .Set("typed_count", e.typed_count)
      .Set("last_visit", e.last_visit)
      .Set("profile_id", profile_id);
}

base::DictValue ArchivedTabToValue(const ArchivedTabRecord& r,
                                     const std::string& space_title) {
  base::DictValue d;
  d.Set("id", r.id);
  d.Set("url", r.url);
  d.Set("title", r.title);
  SetOptionalString(d, "space_id", r.space_id);
  if (!space_title.empty()) {
    d.Set("space_title", space_title);
  }
  d.Set("profile_id", r.profile_id.value_or(std::string()));
  d.Set("archived_at", r.archived_at);
  d.Set("reason", r.reason);
  d.Set("original_location", r.original_location);
  d.Set("kind", r.kind);
  return d;
}

base::DictValue DownloadToValue(const DownloadRecord& r,
                                  const ProfileID& profile_id) {
  return base::DictValue()
      .Set("id", r.id)
      .Set("url", r.url)
      .Set("filename", r.filename)
      .Set("target_path", r.target_path)
      .Set("mime_type", r.mime_type)
      .Set("state", r.state)
      .Set("received_bytes", static_cast<double>(r.received_bytes))
      .Set("total_bytes", static_cast<double>(r.total_bytes))
      .Set("started_at", r.started_at)
      .Set("ended_at", r.ended_at)
      .Set("profile_id", profile_id);
}

// --- Boosts ------------------------------------------------------------------

base::DictValue BoostToValue(const Boost& b) {
  base::ListValue zaps;
  for (const auto& z : b.zapped_elements) {
    zaps.Append(base::DictValue()
                    .Set("id", z.id)
                    .Set("selector", z.selector)
                    .Set("label", z.label));
  }
  base::DictValue d;
  d.Set("id", b.id);
  d.Set("profile_id", b.profile_id);
  d.Set("name", b.name);
  d.Set("host_pattern", b.host_pattern);
  d.Set("enabled", b.enabled);
  d.Set("color", base::DictValue()
                     .Set("enabled", b.color.enabled)
                     .Set("hue_degrees", b.color.hue_degrees)
                     .Set("saturation", b.color.saturation)
                     .Set("lightness", b.color.lightness)
                     .Set("contrast", b.color.contrast)
                     .Set("invert", b.color.invert));
  SetOptionalString(d, "font_family", b.font_family);
  d.Set("text_zoom", b.text_zoom);
  d.Set("text_transform", b.text_transform);
  d.Set("custom_css", b.custom_css);
  d.Set("custom_js", b.custom_js);
  d.Set("zapped_elements", std::move(zaps));
  d.Set("created_at", b.created_at);
  d.Set("modified_at", b.modified_at);
  return d;
}

std::optional<Boost> BoostFromValue(const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const auto& d = value->GetDict();
  Boost b;
  b.id = GetString(d, "id");
  b.profile_id = GetString(d, "profile_id");
  b.name = GetString(d, "name");
  b.host_pattern = base::ToLowerASCII(GetString(d, "host_pattern"));
  b.enabled = GetBool(d, "enabled", true);
  if (const base::DictValue* c = d.FindDict("color")) {
    b.color.enabled = GetBool(*c, "enabled", false);
    b.color.hue_degrees =
        std::clamp(GetDouble(*c, "hue_degrees", 0.0), -180.0, 180.0);
    b.color.saturation = std::clamp(GetDouble(*c, "saturation", 1.0), 0.0, 2.0);
    b.color.lightness = std::clamp(GetDouble(*c, "lightness", 0.0), -0.5, 0.5);
    b.color.contrast = std::clamp(GetDouble(*c, "contrast", 1.0), 0.5, 2.0);
    b.color.invert = GetBool(*c, "invert", false);
  }
  b.font_family = FindString(d, "font_family");
  b.text_zoom = std::clamp(GetDouble(d, "text_zoom", 1.0), 0.5, 2.0);
  b.text_transform = GetString(d, "text_transform");
  if (!b.text_transform.empty() && b.text_transform != "uppercase" &&
      b.text_transform != "lowercase" && b.text_transform != "capitalize") {
    return std::nullopt;
  }
  b.custom_css = GetString(d, "custom_css");
  b.custom_js = GetString(d, "custom_js");
  if (const base::ListValue* zaps = d.FindList("zapped_elements")) {
    if (zaps->size() > kMaxListItems) return std::nullopt;
    for (const auto& item : *zaps) {
      if (!item.is_dict()) return std::nullopt;
      ZappedElement z;
      z.id = GetString(item.GetDict(), "id");
      z.selector = GetString(item.GetDict(), "selector");
      z.label = GetString(item.GetDict(), "label");
      if (z.selector.empty() || z.selector.size() > 4096) return std::nullopt;
      b.zapped_elements.push_back(std::move(z));
    }
  }
  b.created_at = GetDouble(d, "created_at", 0.0);
  b.modified_at = GetDouble(d, "modified_at", 0.0);
  if (b.host_pattern.empty() || b.host_pattern.size() > 253 ||
      !IsSane(b.custom_css) || !IsSane(b.custom_js) || !IsSane(b.name)) {
    return std::nullopt;
  }
  return b;
}

// --- Documents ---------------------------------------------------------------

base::DictValue NoteToValue(const NoteDocument& n) {
  base::ListValue formats;
  for (const auto& f : n.formats) {
    base::DictValue fd;
    fd.Set("type", f.type);
    fd.Set("location", f.location);
    fd.Set("length", f.length);
    SetOptionalString(fd, "url", f.url);
    if (f.level) {
      fd.Set("level", *f.level);
    }
    formats.Append(std::move(fd));
  }
  return base::DictValue()
      .Set("format_version", n.format_version)
      .Set("id", n.id)
      .Set("title", n.title)
      .Set("text", n.text)
      .Set("formats", std::move(formats))
      .Set("created_at", n.created_at)
      .Set("modified_at", n.modified_at);
}

std::optional<NoteDocument> NoteFromValue(const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const auto& d = value->GetDict();
  NoteDocument n;
  n.format_version = GetInt(d, "format_version", 1);
  n.id = GetString(d, "id");
  n.title = GetString(d, "title");
  n.text = GetString(d, "text");
  n.created_at = GetDouble(d, "created_at", 0.0);
  n.modified_at = GetDouble(d, "modified_at", 0.0);
  if (n.format_version != 1 || !IsSane(n.text) || !IsSane(n.title)) {
    return std::nullopt;
  }
  if (const base::ListValue* formats = d.FindList("formats")) {
    if (formats->size() > kMaxListItems) return std::nullopt;
    for (const auto& item : *formats) {
      if (!item.is_dict()) return std::nullopt;
      const auto& fd = item.GetDict();
      NoteFormatRange f;
      f.type = GetString(fd, "type");
      f.location = GetInt(fd, "location", -1);
      f.length = GetInt(fd, "length", -1);
      f.url = FindString(fd, "url");
      if (auto level = fd.FindInt("level")) {
        f.level = *level;
      }
      if (f.type.empty() || f.location < 0 || f.length < 0) {
        return std::nullopt;
      }
      n.formats.push_back(std::move(f));
    }
  }
  return n;
}

base::DictValue EaselToValue(const EaselDocument& e) {
  base::ListValue elements;
  for (const auto& el : e.elements) {
    elements.Append(base::DictValue()
                        .Set("id", el.id)
                        .Set("type", el.type)
                        .Set("x", el.x)
                        .Set("y", el.y)
                        .Set("width", el.width)
                        .Set("height", el.height)
                        .Set("content", el.content)
                        .Set("fill_color", el.fill_color)
                        .Set("stroke_color", el.stroke_color)
                        .Set("stroke_width", el.stroke_width)
                        .Set("font_size", el.font_size)
                        .Set("z_index", el.z_index));
  }
  return base::DictValue()
      .Set("format_version", e.format_version)
      .Set("id", e.id)
      .Set("title", e.title)
      .Set("canvas_width", e.canvas_width)
      .Set("canvas_height", e.canvas_height)
      .Set("palette", e.palette)
      .Set("elements", std::move(elements))
      .Set("created_at", e.created_at)
      .Set("modified_at", e.modified_at);
}

std::optional<EaselDocument> EaselFromValue(const base::Value* value) {
  if (!value || !value->is_dict()) {
    return std::nullopt;
  }
  const auto& d = value->GetDict();
  EaselDocument e;
  e.format_version = GetInt(d, "format_version", 1);
  e.id = GetString(d, "id");
  e.title = GetString(d, "title");
  e.canvas_width =
      std::clamp(GetDouble(d, "canvas_width", 1000.0), 1.0, 20000.0);
  e.canvas_height =
      std::clamp(GetDouble(d, "canvas_height", 1400.0), 1.0, 20000.0);
  e.palette = GetString(d, "palette", "vibrant");
  e.created_at = GetDouble(d, "created_at", 0.0);
  e.modified_at = GetDouble(d, "modified_at", 0.0);
  if (e.format_version != 1 ||
      (e.palette != "vibrant" && e.palette != "chill")) {
    return std::nullopt;
  }
  static constexpr std::array<std::string_view, 7> kTypes = {
      "text", "image", "rect", "ellipse", "arrow", "freehand", "live_card"};
  if (const base::ListValue* elements = d.FindList("elements")) {
    if (elements->size() > kMaxListItems) return std::nullopt;
    for (const auto& item : *elements) {
      if (!item.is_dict()) return std::nullopt;
      const auto& ed = item.GetDict();
      EaselElement el;
      el.id = GetString(ed, "id");
      el.type = GetString(ed, "type");
      if (std::find(kTypes.begin(), kTypes.end(), el.type) == kTypes.end()) {
        return std::nullopt;
      }
      el.x = GetDouble(ed, "x", 0.0);
      el.y = GetDouble(ed, "y", 0.0);
      el.width = GetDouble(ed, "width", 200.0);
      el.height = GetDouble(ed, "height", 100.0);
      el.content = GetString(ed, "content");
      el.fill_color = GetString(ed, "fill_color");
      el.stroke_color = GetString(ed, "stroke_color");
      el.stroke_width = GetDouble(ed, "stroke_width", 2.0);
      el.font_size = GetDouble(ed, "font_size", 16.0);
      el.z_index = GetInt(ed, "z_index", 0);
      if (!IsSane(el.content)) return std::nullopt;
      e.elements.push_back(std::move(el));
    }
  }
  return e;
}

// --- Readers -----------------------------------------------------------------

std::string GetString(const base::DictValue& dict,
                      std::string_view key,
                      std::string_view fallback) {
  const std::string* v = dict.FindString(key);
  return v ? *v : std::string(fallback);
}

std::optional<std::string> FindString(const base::DictValue& dict,
                                      std::string_view key) {
  const std::string* v = dict.FindString(key);
  if (!v) {
    return std::nullopt;
  }
  return *v;
}

bool GetBool(const base::DictValue& dict, std::string_view key,
             bool fallback) {
  return dict.FindBool(key).value_or(fallback);
}

double GetDouble(const base::DictValue& dict, std::string_view key,
                 double fallback) {
  std::optional<double> v = dict.FindDouble(key);
  return v && std::isfinite(*v) ? *v : fallback;
}

int GetInt(const base::DictValue& dict, std::string_view key, int fallback) {
  if (std::optional<int> v = dict.FindInt(key)) {
    return *v;
  }
  if (std::optional<double> d = dict.FindDouble(key);
      d && std::isfinite(*d) && *d >= -2147483648.0 && *d <= 2147483647.0) {
    return static_cast<int>(*d);
  }
  return fallback;
}

}  // namespace open_unified::json
