// Copyright 2026 The Open Authors. All rights reserved.
// Canonical cross-platform data model types for Open Unified Browser.
// Schema-compatible with macOS Open's State/browser.json (schemaVersion = 1)
// and Open Sync v1 (docs/sync-protocol.md).

#ifndef OPEN_UNIFIED_CORE_MODEL_OPEN_TYPES_H_
#define OPEN_UNIFIED_CORE_MODEL_OPEN_TYPES_H_

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <variant>
#include <vector>

namespace open_unified {

using ItemID = std::string;     // Canonical lowercase UUID string
using SpaceID = std::string;    // Canonical lowercase UUID string
using ProfileID = std::string;  // Canonical lowercase UUID string
using WindowID = std::string;   // Canonical lowercase UUID string
using RuleID = std::string;     // Canonical lowercase UUID string
using TimestampSec = double;    // Unix epoch seconds (matching Swift TimeInterval)

struct RGBAColor {
  double r = 0.0;  // 0..1
  double g = 0.0;  // 0..1
  double b = 0.0;  // 0..1
  double a = 1.0;  // 0..1

  bool operator==(const RGBAColor&) const = default;
};

struct GradientStop {
  double location = 0.0;  // 0..1
  RGBAColor color;

  bool operator==(const GradientStop&) const = default;
};

enum class ThemeWheel {
  kAnalogous,
  kComplementary,
};

enum class ThemeAppearance {
  kAutomatic,
  kLight,
  kDark,
};

enum class ThemeTexture {
  kGrain,
  kSand,
  kDenim,
  kTweed,
};

struct SpaceStyle {
  int math_version = 1;
  RGBAColor key_color{0.19, 0.22, 1.0, 1.0};
  int color_count = 2;  // 1..3
  ThemeWheel wheel = ThemeWheel::kAnalogous;
  ThemeAppearance appearance = ThemeAppearance::kAutomatic;
  double noise_factor = 0.0;      // 0..1
  ThemeTexture texture = ThemeTexture::kGrain;
  double intensity_factor = 0.6;  // 0..1

  bool operator==(const SpaceStyle&) const = default;
};

struct SpaceTheme {
  std::optional<RGBAColor> light_background;
  std::optional<RGBAColor> dark_background;
  std::optional<RGBAColor> light_foreground;
  std::optional<RGBAColor> dark_foreground;
  std::optional<RGBAColor> accent;
  std::vector<GradientStop> gradient_stops_light;
  std::vector<GradientStop> gradient_stops_dark;
  std::optional<std::string> imported_arc_theme_json;
  std::optional<SpaceStyle> style;

  bool operator==(const SpaceTheme&) const = default;
};

enum class SpaceIconKind {
  kEmoji,
  kSymbol,
  kNamed,
};

struct SpaceIcon {
  SpaceIconKind kind = SpaceIconKind::kEmoji;
  std::string value;

  bool operator==(const SpaceIcon&) const = default;
};

enum class SleepPhase {
  kPlaceholder,
  kLive,
  kFrozen,
  kSleeping,
};

struct LiveItemInfo {
  std::string source_kind;  // e.g. "github_pr"
  std::string subtitle;
  std::string status_badge;
  TimestampSec updated_at = 0.0;

  bool operator==(const LiveItemInfo&) const = default;
};

struct LiveFolderConfig {
  std::string provider;
  std::string query;
  int refresh_interval_sec = 300;
  bool enabled = true;

  bool operator==(const LiveFolderConfig&) const = default;
};

// Runtime-only tab telemetry (never serialized to browser.json).
struct TabLiveState {
  bool has_web_content = false;
  bool has_loaded_in_this_launch = false;
  SleepPhase sleep_phase = SleepPhase::kPlaceholder;
  bool is_capturing_media = false;
  bool devtools_open = false;
  std::optional<TimestampSec> last_form_interaction_at;
  bool notifications_allowed = false;
  bool is_loading = false;
  double progress = 0.0;
  bool is_audible = false;
  bool is_crashed = false;
  bool can_go_back = false;
  bool can_go_forward = false;
  std::vector<uint8_t> favicon_png;
  std::optional<RGBAColor> page_background_color;
};

struct Tab {
  ItemID id;
  std::string url;
  std::string title;
  std::optional<std::string> custom_title;
  std::optional<std::string> pinned_url;
  std::optional<std::string> custom_icon;
  std::optional<SpaceIcon> icon_override;
  TimestampSec created_at = 0.0;
  TimestampSec last_active_at = 0.0;
  bool is_muted = false;
  std::optional<ItemID> opener_id;
  bool is_unread = false;
  std::optional<std::string> live_item_url;
  std::optional<LiveItemInfo> live_item;

  // Non-persisted runtime state.
  TabLiveState live_state;

  const std::string& display_title() const {
    if (custom_title.has_value() && !custom_title->empty()) {
      return *custom_title;
    }
    return title.empty() ? url : title;
  }
};

enum class SplitOrientation {
  kHorizontal,
  kVertical,
};

struct Split {
  ItemID id;
  SplitOrientation orientation = SplitOrientation::kHorizontal;
  std::vector<double> fractions;  // Normalized sum = 1.0; empty = equal
  std::vector<Tab> panes;         // 2..4 panes
  std::optional<ItemID> focused_pane_id;
  std::optional<std::string> custom_title;
  std::optional<SpaceIcon> icon_override;
};

struct SidebarNode;

struct Folder {
  ItemID id;
  std::string title;
  bool is_expanded = false;
  std::optional<ItemID> peeked_child_id;
  std::optional<std::string> custom_icon;
  std::optional<SpaceIcon> icon_override;
  std::vector<SidebarNode> children;
  std::optional<LiveFolderConfig> live;
  // Session-only SSO URL.
  std::optional<std::string> live_sso_url;
};

struct SidebarNode {
  enum class Kind { kTab, kFolder, kSplit };

  std::variant<Tab, Folder, Split> data;

  SidebarNode() : data(Tab{}) {}
  explicit SidebarNode(Tab t) : data(std::move(t)) {}
  explicit SidebarNode(Folder f) : data(std::move(f)) {}
  explicit SidebarNode(Split s) : data(std::move(s)) {}

  Kind kind() const {
    if (std::holds_alternative<Tab>(data)) return Kind::kTab;
    if (std::holds_alternative<Folder>(data)) return Kind::kFolder;
    return Kind::kSplit;
  }

  const ItemID& id() const {
    if (auto* t = std::get_if<Tab>(&data)) return t->id;
    if (auto* f = std::get_if<Folder>(&data)) return f->id;
    return std::get<Split>(data).id;
  }

  Tab* as_tab() { return std::get_if<Tab>(&data); }
  const Tab* as_tab() const { return std::get_if<Tab>(&data); }
  Folder* as_folder() { return std::get_if<Folder>(&data); }
  const Folder* as_folder() const { return std::get_if<Folder>(&data); }
  Split* as_split() { return std::get_if<Split>(&data); }
  const Split* as_split() const { return std::get_if<Split>(&data); }
};

enum class AutoArchiveInterval {
  kNever,
  kOneHour,
  kSixHours,
  kTwelveHours,
  kTwentyFourHours,
  kSevenDays,
  kThirtyDays,
};

enum class SleepMode {
  kOff,
  kConservative,  // 900s discard
  kBalanced,      // 300s discard
  kAggressive,    // 120s discard
};

struct CustomSearchEngine {
  std::string id;
  std::string name;
  std::string keyword;
  std::string url_template;  // Contains "%s"

  bool operator==(const CustomSearchEngine&) const = default;
};

struct ProfileSettings {
  AutoArchiveInterval auto_archive_after = AutoArchiveInterval::kTwelveHours;
  AutoArchiveInterval little_open_auto_archive_after =
      AutoArchiveInterval::kSixHours;
  bool search_suggest_enabled = true;
  std::string download_directory = "~/Downloads";
  bool ask_where_to_save_each_file = false;
  std::vector<CustomSearchEngine> custom_search_engines;
  std::string search_engine_id = "google";
  SleepMode sleep_mode = SleepMode::kBalanced;
  std::vector<std::string> keep_alive_sites;
  std::string default_document_app = "note";
};

struct Profile {
  ProfileID id;
  std::string name;
  std::optional<SpaceIcon> icon;
  std::vector<Tab> favorites;  // Tabs only
  ProfileSettings settings;
  std::string data_directory_name = "Default";
  bool favorites_empty_state_dismissed = false;
};

struct Space {
  SpaceID id;
  std::optional<std::string> title;
  std::optional<SpaceIcon> icon;
  SpaceTheme theme;
  ProfileID profile_id;
  std::vector<SidebarNode> pinned;
  std::vector<SidebarNode> today;
  bool is_pinned_collapsed = false;
};

enum class SidebarMode {
  kAnchored,
  kHidden,
};

enum class WindowStyle {
  kStandard,
  kLittleOpen,
};

struct BrowserWindowState {
  WindowID id;
  SpaceID focused_space_id;
  std::map<SpaceID, ItemID> selected_node_by_space;
  double sidebar_width = 228.0;
  SidebarMode sidebar_mode = SidebarMode::kAnchored;
  double frame_x = 100.0;
  double frame_y = 100.0;
  double frame_width = 1280.0;
  double frame_height = 800.0;
  WindowStyle style = WindowStyle::kStandard;
  bool stay_on_top = false;
  bool shows_toolbar = true;
  std::optional<TimestampSec> last_focused_at;
};

enum class RoutingDestinationKind {
  kSpace,
  kLittleOpen,
  kMostRecentSpace,
};

struct RoutingDestination {
  RoutingDestinationKind kind = RoutingDestinationKind::kMostRecentSpace;
  std::optional<SpaceID> space_id;
  std::optional<ProfileID> profile_id;

  bool operator==(const RoutingDestination&) const = default;
};

struct RoutingRule {
  RuleID id;
  std::string name;
  std::string host_pattern;
  std::optional<std::string> path_prefix;
  std::optional<std::string> source_app_id;
  RoutingDestination destination;
  bool enabled = true;
};

enum class NodeParentKind {
  kSpacePinned,
  kSpaceToday,
  kFolder,
  kFavorites,
  kSplitPane,
};

struct NodeParent {
  NodeParentKind kind = NodeParentKind::kSpaceToday;
  std::string owner_id;  // SpaceID, Folder ItemID, ProfileID, or Split ItemID

  bool operator==(const NodeParent&) const = default;
};

struct TreeChange {
  enum class Kind {
    kInsert,
    kRemove,
    kMove,
    kUpdate,
    kReload,
    kSpaceProfileChanged,
  };

  Kind kind = Kind::kReload;
  NodeParent parent;
  size_t index = 0;
  NodeParent to_parent;
  size_t to_index = 0;
  ItemID node_id;
  SpaceID space_id;
  ProfileID from_profile_id;
  ProfileID to_profile_id;
};

struct ArchivedTabRecord {
  ItemID id;
  std::string url;
  std::string title;
  std::optional<SpaceID> space_id;
  std::optional<ProfileID> profile_id;
  TimestampSec archived_at = 0.0;
  std::string reason;             // "closed", "auto-archive", "clear-today", "space-deleted"
  std::string original_location;  // "today", "pinned", "folder"
  std::string payload_json;
  std::string kind = "tab";       // "tab" | "folder"
};

struct HistoryEntry {
  int64_t id = 0;
  std::string url;
  std::string title;
  int visit_count = 0;
  int typed_count = 0;
  TimestampSec last_visit = 0.0;
};

struct DownloadRecord {
  std::string id;
  std::string url;
  std::string filename;
  std::string target_path;
  std::string mime_type;
  std::string state;  // "in_progress", "completed", "cancelled", "interrupted"
  int64_t received_bytes = 0;
  int64_t total_bytes = -1;
  TimestampSec started_at = 0.0;
  TimestampSec ended_at = 0.0;
};

// Boosts & Zap model (docs/boosts.md).
struct BoostColorAdjustment {
  bool enabled = false;
  double hue_degrees = 0.0;
  double saturation = 1.0;
  double lightness = 0.0;
  double contrast = 1.0;
  bool invert = false;
};

struct ZappedElement {
  std::string id;
  std::string selector;
  std::string label;
};

struct Boost {
  std::string id;
  ProfileID profile_id;
  std::string name;
  std::string host_pattern;  // Domain suffix or exact IP
  bool enabled = true;
  BoostColorAdjustment color;
  std::optional<std::string> font_family;
  double text_zoom = 1.0;  // 0.5..2.0
  std::string text_transform;  // "", "uppercase", "lowercase", "capitalize"
  std::string custom_css;
  std::string custom_js;
  std::vector<ZappedElement> zapped_elements;
  TimestampSec created_at = 0.0;
  TimestampSec modified_at = 0.0;
};

// NoteDocument (Packages/OpenKit/Sources/OpenDocuments/NoteDocument.swift).
struct NoteFormatRange {
  std::string type;  // bold, italic, underline, strikethrough, h1..h3, link, bulletList, numberedList, image
  int location = 0;  // UTF-16 offset
  int length = 0;    // UTF-16 length
  std::optional<std::string> url;
  std::optional<int> level;
};

struct NoteDocument {
  int format_version = 1;
  std::string id;
  std::string title;
  std::string text;
  std::vector<NoteFormatRange> formats;
  TimestampSec created_at = 0.0;
  TimestampSec modified_at = 0.0;
};

// EaselDocument (docs/easels.md).
struct EaselElement {
  std::string id;
  std::string type;  // "text", "image", "rect", "ellipse", "arrow", "freehand", "live_card"
  double x = 0.0;
  double y = 0.0;
  double width = 200.0;
  double height = 100.0;
  std::string content;        // Text, URL, SVG path, or image sha256 ref
  std::string fill_color;
  std::string stroke_color;
  double stroke_width = 2.0;
  double font_size = 16.0;
  int z_index = 0;
};

struct EaselDocument {
  int format_version = 1;
  std::string id;
  std::string title;
  double canvas_width = 1000.0;
  double canvas_height = 1400.0;
  std::string palette = "vibrant";  // "vibrant" | "chill"
  std::vector<EaselElement> elements;
  TimestampSec created_at = 0.0;
  TimestampSec modified_at = 0.0;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_CORE_MODEL_OPEN_TYPES_H_
