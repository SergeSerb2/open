// Copyright 2026 The Open Authors. All rights reserved.
//
// OpenSiteControlBubble: the Site Control Center panel.
//
// Sources: Packages/OpenKit/Sources/OpenSiteControl/{SiteControlView,
// SiteControlRows,SiteControlTypes,SiteControlController}.swift,
// App/SiteControl/AppSiteControlSource.swift, and SiteControlMetrics /
// SiteControlColors in Packages/OpenKit/Sources/OpenDesign/
// SiteControlTokens.swift (Arc 1.172 session 2 14c).
//
// Layout (236 wide, padding 10, radius 16, at most 640 tall), top to bottom:
//   quick actions (48 x 32 tiles, radius 6, gap 8): Share, New Boost (Edit
//     Boost while a Boost matches), Capture a portion, Capture the full page;
//   a scrolling body that starts 37 pt below the tiles:
//     Extensions (header accessory "Manage"): a 4-column grid of the
//       window's extension actions (real icons, badge overlay, right-click
//       menu with Pin/Unpin), an "Add Extension" tile when none, or the
//       private-window note;
//     Boosts (only when a Boost matches; accessory "Manage"): one row per
//       Boost with an enable circle, the Zap count and Edit on click;
//     Settings (accessory "More" / "Less"): "Block Ads & Trackers" with the
//       live blocked count, then the permissions and content settings that
//       differ from their defaults (all 27 kinds after "More"). A click
//       toggles Allowed / Blocked (Swift parity); a right-click offers
//       Allow / Block / Ask / Reset;
//     "Reload to apply changes." with a Reload button after a change;
//   a 1 pt separator, then the footer (32 pt): the security pill (lock +
//     "Secure" / "Insecure"; a click opens the certificate details page) and
//     the round "..." button (Clear Cache, Clear Cookies, Copy Clean URL,
//     Manage Boosts, New Boost, Manage Extensions, Add Extension, All Site
//     Settings).
//
// Data: the coordinator passes a SiteControlState. When the bubble also gets
// the tab (Show(..., tab, callbacks)) it reads the live tiles, ad-block
// state, in-use indicators and certificate from Chromium itself (helpers in
// site_control_data below) and keeps them live (OpenAdBlockProfileService,
// MediaStreamCaptureIndicator and WebContents capability observers).
//
// Construction note: Chromium 156 makes BubbleDialogDelegateView's
// constructors private (friend list), so this uses the public
// views::BubbleDialogDelegate with a contents view, the same pattern as
// Chromium's ExtensionsMenuCoordinator.
//
// Material: Arc's panel is a backdrop blur with a Space tint. Views has no
// cheap backdrop blur, so the panel uses a solid body (Open choice; Track 4
// can pass a themed color through `SiteControlState::panel_color`).

#ifndef OPEN_UNIFIED_UI_VIEWS_OPEN_SITE_CONTROL_BUBBLE_H_
#define OPEN_UNIFIED_UI_VIEWS_OPEN_SITE_CONTROL_BUBBLE_H_

#include <cstddef>
#include <memory>
#include <optional>
#include <set>
#include <string>
#include <vector>

#include "base/functional/callback.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/weak_ptr.h"
#include "base/time/time.h"
#include "open_unified/ui/views/open_split_container_view.h"
#include "third_party/skia/include/core/SkColor.h"
#include "ui/base/metadata/metadata_header_macros.h"
#include "ui/base/mojom/menu_source_type.mojom-forward.h"
#include "ui/gfx/geometry/point.h"
#include "ui/gfx/geometry/rect.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/menus/simple_menu_model.h"
#include "ui/views/context_menu_controller.h"
#include "ui/views/view.h"
#include "ui/views/widget/widget.h"
#include "url/gurl.h"

namespace content {
class WebContents;
}  // namespace content

namespace views {
class BubbleDialogDelegate;
class MenuRunner;
class ScrollView;
}  // namespace views

namespace open_unified {

struct Boost;

namespace site_control_metrics {
inline constexpr int kWidth = 236;
inline constexpr int kPadding = 10;
inline constexpr int kCornerRadius = 16;
inline constexpr int kMaxHeight = 640;
inline constexpr int kActionWidth = 48;
inline constexpr int kActionHeight = 32;
inline constexpr int kActionGap = 8;
inline constexpr int kActionRadius = 6;
inline constexpr int kActionGlyph = 17;
inline constexpr int kGapAfterActions = 37;
inline constexpr int kSectionGap = 43;
inline constexpr int kLabelBaselineAboveContent = 14;
inline constexpr int kLabelRowHeight = 24;
inline constexpr int kLabelBaselineInRow = 21;
inline constexpr int kExtensionColumns = 4;
inline constexpr int kExtensionRowPitch = 40;
inline constexpr int kExtensionIcon = 16;
inline constexpr int kTileRadius = 6;
inline constexpr int kRowIcon = 32;
inline constexpr int kRowPitch = 43;
inline constexpr int kRowTextX = 50;
inline constexpr int kRowTitleBaseline = 13;
inline constexpr int kRowSubtitleBaseline = 29;
inline constexpr int kRowTitleTrailing = 16;
inline constexpr int kRowGlyph = 15;
inline constexpr int kGapBeforeSeparator = 15;
inline constexpr int kGapAfterSeparator = 10;
inline constexpr int kFooterHeight = 32;
inline constexpr int kPillRadius = 8;
inline constexpr int kPillPadding = 10;
inline constexpr int kPillLockGlyph = 13;
inline constexpr int kPillLockGap = 6;
inline constexpr int kMoreButton = 32;
inline constexpr int kMoreGlyph = 13;
inline constexpr int kInUseDot = 6;
inline constexpr int kReloadRowHeight = 32;
inline constexpr int kReloadGap = 11;
inline constexpr int kReloadButtonWidth = 44;
inline constexpr int kGlobalOffHeight = 28;
inline constexpr float kDisabledAlpha = 0.3f;
}  // namespace site_control_metrics

// --- Legacy model (kept for open_window_controller) -------------------------

enum class SiteControlAction {
  kCopyUrl,
  kNewBoost,
  kSplit,
  kCapture,
  kSiteSettings,
  kClearSiteData,
};

enum class SitePermissionKind {
  kCamera,
  kMicrophone,
  kLocation,
  kNotifications,
  kPopups,
};

enum class SitePermissionSetting {
  kAsk,
  kAllow,
  kBlock,
};

struct SitePermissionRow {
  SitePermissionKind kind = SitePermissionKind::kCamera;
  SitePermissionSetting setting = SitePermissionSetting::kAsk;
  bool in_use = false;  // Draws the 6 pt in-use dot.
};

// --- Parity model -------------------------------------------------------------

// Every permission and content setting the Settings section can show, in
// AppSiteControlSource's order (permissionRows, then contentRows).
enum class SiteSettingType {
  // Permissions: shown when not "Ask".
  kCamera,
  kMicrophone,
  kLocation,
  kNotifications,
  kClipboard,
  kMidi,
  kScreenCapture,
  kAutomaticDownloads,
  kStorageAccess,
  kWindowManagement,
  kLocalFonts,
  kIdleDetection,
  // Content settings: shown when they differ from the Profile default.
  kSensors,
  kJavaScript,
  kImages,
  kPopups,
  kIntrusiveAds,
  kBackgroundSync,
  kSound,
  kUsbDevices,
  kHidDevices,
  kSerialPorts,
  kBluetoothDevices,
  kHandTracking,
  kKeyboardLock,
  kPointerLock,
  kLocalNetwork,
};
inline constexpr size_t kSiteSettingTypeCount = 27;

enum class SiteSettingTileKind {
  kContentBlocking,  // "Block Ads & Trackers"
  kPermission,
  kContent,
};

enum class SiteSettingTileState {
  kOn,
  kOff,
  kUnavailable,
};

// One Settings row (Swift SiteSettingTile).
struct SiteSettingTile {
  SiteSettingTile();
  SiteSettingTile(const SiteSettingTile&);
  SiteSettingTile& operator=(const SiteSettingTile&);
  ~SiteSettingTile();

  // "contentBlocking", "permission.camera", "content.javascript", ...
  std::string id;
  SiteSettingTileKind kind = SiteSettingTileKind::kPermission;
  SiteSettingType type = SiteSettingType::kCamera;  // Unused for ad blocking.
  std::u16string title;
  std::u16string subtitle;  // "Allowed", "Blocked", "Ask", "12 blocked", ...
  std::u16string help;      // Tooltip / accessible description.
  SiteSettingTileState state = SiteSettingTileState::kOff;
  SitePermissionSetting setting = SitePermissionSetting::kAsk;
  bool in_use = false;   // The tab uses the capability now (blue dot).
  bool enabled = true;   // False: the site cannot change it (drawn at 0.3).
  bool changed = true;   // Differs from the default: shown without "More".
};

struct SiteControlExtensionItem {
  std::string id;
  std::u16string name;
  gfx::ImageSkia icon;  // The action's real icon (null draws the puzzle).
  std::u16string badge_text;
  SkColor badge_color = SkColorSetRGB(0xD9, 0x30, 0x25);
  SkColor badge_text_color = SK_ColorWHITE;
  std::u16string tooltip;  // Empty uses `name`.
  bool enabled = true;
  bool pinned = false;
  bool force_pinned = false;
  bool has_popup = false;
};

struct SiteControlBoostItem {
  std::string id;
  std::u16string name;  // Boost name, or the site when unnamed.
  bool enabled = true;
  int zap_count = 0;
  bool has_code = false;  // Custom CSS or JS.
};

// The page's certificate, read from NavigationEntry::GetSSL().
struct SiteCertificateSummary {
  SiteCertificateSummary();
  SiteCertificateSummary(const SiteCertificateSummary&);
  SiteCertificateSummary& operator=(const SiteCertificateSummary&);
  ~SiteCertificateSummary();

  std::u16string subject;       // Common name (or display name).
  std::u16string organization;  // Subject organization, may be empty.
  std::u16string issuer;
  base::Time valid_from;
  base::Time valid_until;
  std::vector<std::u16string> subject_alt_names;  // DNS names, then IPs.
  std::u16string sha256;  // Hex fingerprint of the leaf, colon separated.
  bool has_errors = false;
  bool expired = false;
};

enum class SiteDataKind {
  kCache,
  kCookies,
};

struct SiteControlState {
  SiteControlState();
  SiteControlState(const SiteControlState&);
  SiteControlState& operator=(const SiteControlState&);
  ~SiteControlState();

  std::u16string host;
  bool secure = true;
  bool boost_active = false;
  bool split_available = true;  // Legacy; the Split tile is now Capture.
  // Pinned and active extension actions for this tab, in toolbar order.
  std::vector<SiteControlExtensionItem> extensions;
  // Legacy rows (used only when `tiles` is empty and no tab is attached).
  std::vector<SitePermissionRow> permissions;
  bool ad_block_available = true;
  bool ad_block_enabled = true;
  int ad_block_blocked_count = 0;
  // Solid panel body; empty uses Open's light/dark default.
  std::optional<SkColor> panel_color;

  // --- Parity fields ---
  GURL url;  // Last committed URL (Share, Copy Clean URL, origin checks).
  bool is_website = true;  // http(s) with a host.
  bool incognito = false;
  bool can_create_boost = true;
  bool capture_available = true;
  // Settings rows. Empty: derived from the attached tab (or the legacy rows).
  std::vector<SiteSettingTile> tiles;
  // Boosts matching the host (Boosts section shown when non-empty).
  std::vector<SiteControlBoostItem> boosts;
  bool boosts_globally_enabled = true;
  // Ad blocking detail for the tile.
  bool ad_block_changeable = true;   // False for one-word hosts and suffixes.
  bool ad_block_excluded = false;    // Paused on this site.
  std::u16string ad_block_filter_status;  // "2 filter lists, updated ..."
  // Empty: read from the attached tab when the pill is clicked.
  std::optional<SiteCertificateSummary> certificate;
  bool show_reload_banner = false;
};

// Callbacks for the parity actions. Every one is optional: a null callback
// falls back to the legacy SiteControlDelegate method (where one exists) or
// to the bubble's own Chromium implementation on the attached tab.
struct SiteControlCallbacks {
  SiteControlCallbacks();
  SiteControlCallbacks(const SiteControlCallbacks&);
  SiteControlCallbacks& operator=(const SiteControlCallbacks&);
  ~SiteControlCallbacks();

  // Quick actions. `anchor_in_screen` is the tile (native share sheet).
  base::RepeatingCallback<void(const gfx::Rect& anchor_in_screen)> on_share;
  // nullopt: New Boost; else edit that Boost (floating Boost Editor).
  base::RepeatingCallback<void(const std::optional<std::string>& boost_id)>
      on_open_boost_editor;
  base::RepeatingClosure on_capture_region;
  base::RepeatingClosure on_capture_full_page;
  // "..." menu. Null clear callbacks run ClearSiteDataAndReload on the tab.
  base::RepeatingClosure on_clear_cache_and_reload;
  base::RepeatingClosure on_clear_cookies_and_reload;
  base::RepeatingClosure on_copy_clean_url;
  base::RepeatingClosure on_open_site_settings;
  base::RepeatingClosure on_manage_boosts;
  base::RepeatingClosure on_manage_extensions;
  base::RepeatingClosure on_add_extension;
  // Extensions section.
  base::RepeatingCallback<void(const std::string& extension_id, bool pinned)>
      on_toggle_extension_pin;
  base::RepeatingCallback<void(const std::string& extension_id,
                               views::View* anchor)>
      on_run_extension_action;
  // The real ExtensionContextMenuModel (OpenExtensionBridge::
  // ShowContextMenu). Null shows the bubble's own Pin / Manage menu.
  base::RepeatingCallback<void(const std::string& extension_id,
                               views::View* anchor,
                               const gfx::Point& point_in_screen,
                               ui::mojom::MenuSourceType source_type)>
      on_extension_context_menu;
  // Boosts section.
  base::RepeatingCallback<void(const std::string& boost_id, bool enabled)>
      on_boost_enabled_changed;
  // Settings section. Null applies the setting on the tab
  // (site_control_data::ApplySiteSetting) or, for the five legacy kinds,
  // calls SiteControlDelegate::OnSiteControlPermissionChanged.
  base::RepeatingCallback<void(SiteSettingType type,
                               SitePermissionSetting setting)>
      on_site_setting_changed;
  // Null calls SiteControlDelegate::OnSiteControlAdBlockToggled.
  base::RepeatingCallback<void(bool enabled)> on_ad_block_toggled;
  // The ad-block tile while blocking is off for the Profile (Settings, Ad
  // Blocking). Null falls back to on_open_site_settings.
  base::RepeatingClosure on_open_ad_block_settings;
  // The banner's Reload. Null reloads the attached tab.
  base::RepeatingClosure on_reload_page;
  // Null opens Chromium's certificate viewer for the attached tab.
  base::RepeatingClosure on_show_certificate;
  // Asked for a fresh state after the tab navigates or a live source
  // changes. Null keeps the current coordinator fields and refreshes only
  // what the bubble reads from the tab.
  base::RepeatingCallback<std::optional<SiteControlState>()> refresh_state;
};

class SiteControlDelegate {
 public:
  virtual ~SiteControlDelegate() = default;

  virtual void OnSiteControlAction(SiteControlAction action) = 0;
  // Run the extension's action (ExtensionActionViewModel::ExecuteUserAction)
  // and anchor any popup to `anchor`.
  virtual void OnSiteControlExtensionPressed(const std::string& extension_id,
                                             views::View* anchor) = 0;
  virtual void OnSiteControlPermissionChanged(
      SitePermissionKind kind,
      SitePermissionSetting setting) = 0;
  virtual void OnSiteControlAdBlockToggled(bool enabled) = 0;
  // The bubble closed (deactivation, Esc, or Close()).
  virtual void OnSiteControlClosed() {}
};

// Chromium-backed data and actions for the Site Control Center. UI thread.
namespace site_control_data {

// Tiles for `tab`'s last committed origin, in panel order: the ad-block tile,
// then all 27 permission and content kinds. `changed` marks the ones that
// differ from their default; the panel shows only those until "More".
std::vector<SiteSettingTile> BuildSiteSettingTiles(content::WebContents* tab);
// The "Block Ads & Trackers" tile alone (live count, pause state, help).
SiteSettingTile BuildAdBlockTile(content::WebContents* tab);
// Fills url, host, secure, is_website, incognito, tiles and the ad-block
// fields of `state` from `tab`. Leaves Boosts, extensions and panel color.
void FillStateFromTab(content::WebContents* tab, SiteControlState* state);
// Writes `setting` for `type` on the tab's origin (kAsk resets to default).
// Returns false when the kind refuses that value.
bool ApplySiteSetting(content::WebContents* tab,
                      SiteSettingType type,
                      SitePermissionSetting setting);
// The site's current value of `type`.
SitePermissionSetting GetSiteSetting(content::WebContents* tab,
                                     SiteSettingType type);
// The legacy kind for `type`, when there is one.
std::optional<SitePermissionKind> LegacyKindFor(SiteSettingType type);
SiteSettingType TypeForLegacyKind(SitePermissionKind kind);
// Origin-scoped clear: content::BrowsingDataRemover::RemoveWithFilter with a
// registrable-domain filter (never the whole Profile), then a reload that
// bypasses the cache. `done` gets false when nothing could be cleared.
void ClearSiteDataAndReload(content::WebContents* tab,
                            SiteDataKind kind,
                            base::OnceCallback<void(bool)> done = {});
std::optional<SiteCertificateSummary> CertificateSummaryForTab(
    content::WebContents* tab);
// Chromium's certificate viewer for the tab's leaf certificate.
bool ShowCertificateViewerForTab(content::WebContents* tab);
// `url` without tracking parameters (utm_*, fbclid, gclid, ...) and fragment
// text directives.
GURL CleanUrlForSharing(const GURL& url);
void CopyCleanUrl(const GURL& url);
SiteControlBoostItem BoostItemFor(const Boost& boost);
// "Camera", "Pop-ups", ... (user-visible title of `type`).
std::u16string TitleFor(SiteSettingType type);

}  // namespace site_control_data

// The panel contents. Usable on its own (e.g. inside an automation snapshot)
// but normally created by OpenSiteControlBubble.
class OpenSiteControlView : public views::View,
                            public ui::SimpleMenuModel::Delegate,
                            public views::ContextMenuController {
  METADATA_HEADER(OpenSiteControlView, views::View)

 public:
  OpenSiteControlView(SiteControlDelegate* delegate,
                      const SiteControlState& state,
                      const secondary::Appearance& appearance);
  OpenSiteControlView(const OpenSiteControlView&) = delete;
  OpenSiteControlView& operator=(const OpenSiteControlView&) = delete;
  ~OpenSiteControlView() override;

  void SetState(const SiteControlState& state);
  const SiteControlState& state() const { return state_; }
  void SetAppearance(const secondary::Appearance& appearance);
  void SetCallbacks(const SiteControlCallbacks& callbacks);
  // The tab the panel reads from and acts on (may be null).
  void SetWebContents(content::WebContents* tab);
  content::WebContents* web_contents() const;
  // Live counter: repaints the ad-block tile only.
  void SetAdBlockState(bool enabled, int blocked_count);
  // Re-reads the in-use indicators from the tab.
  void RefreshInUse();
  // Re-reads the live page zoom level and updates the Zoom row.
  void RefreshZoom();
  // Re-reads every tab-derived field (tiles, ad blocking, certificate).
  void RefreshFromTab();
  void SetReloadBannerVisible(bool visible);
  SkColor panel_color() const;

  // Extension tile for `extension_id` (popup anchor), or null.
  views::View* GetExtensionAnchor(const std::string& extension_id);
  // The tiles the Settings section shows now (changed-only or all).
  std::vector<const SiteSettingTile*> VisibleTiles() const;
  bool showing_all_settings() const { return show_all_settings_; }
  bool showing_certificate() const { return showing_certificate_; }

  // views::View:
  gfx::Size CalculatePreferredSize(
      const views::SizeBounds& available_size) const override;
  void Layout(PassKey) override;
  void OnPaint(gfx::Canvas* canvas) override;
  void OnThemeChanged() override;
  bool OnMouseWheel(const ui::MouseWheelEvent& event) override;

  // ui::SimpleMenuModel::Delegate:
  void ExecuteCommand(int command_id, int event_flags) override;
  bool IsCommandIdChecked(int command_id) const override;
  bool IsCommandIdEnabled(int command_id) const override;

  // views::ContextMenuController:
  void ShowContextMenuForViewImpl(
      views::View* source,
      const gfx::Point& point,
      ui::mojom::MenuSourceType source_type) override;

 private:
  enum class Section {
    kExtensions,
    kBoosts,
    kSettings,
  };

  void Rebuild();
  void RepaintAll();
  void BuildBody();
  void BuildCertificatePage();
  void NormalizeState();
  int BodyHeight() const;
  int FixedHeight() const;
  views::View* AddBodyChild(std::unique_ptr<views::View> view);

  void OnActionPressed(int index);
  void OnSectionPressed(Section section);
  void OnTilePressed(size_t index);
  void OnTileSettingChosen(size_t index, SitePermissionSetting setting);
  void OnExtensionPressed(size_t index);
  void OnBoostToggled(size_t index);
  void OnBoostPressed(size_t index);
  void OnReloadPressed();
  void OnSecurityPressed();
  void OnAudioMuteToggled();
  void OnZoomIn();
  void OnZoomOut();
  void OnZoomReset();
  void UpdateZoomControls();
  int CurrentZoomPercent() const;
  bool CanZoomIn() const;
  bool CanZoomOut() const;
  bool ShouldShowAudioRow() const;
  void ShowMoreMenu();
  void ShowTileMenu(size_t index, const gfx::Point& point,
                    ui::mojom::MenuSourceType source_type);
  void ShowExtensionMenu(size_t index, const gfx::Point& point,
                         ui::mojom::MenuSourceType source_type);
  void RunMenu(std::unique_ptr<ui::SimpleMenuModel> model,
               const gfx::Rect& anchor_in_screen,
               ui::mojom::MenuSourceType source_type);
  void ClearSiteData(SiteDataKind kind);
  void NotifyChanged();

  void PaintActionTile(int index,
                       gfx::Canvas* canvas,
                       const gfx::Rect& bounds,
                       bool hovered);
  void PaintSectionHeader(Section section,
                          gfx::Canvas* canvas,
                          const gfx::Rect& bounds,
                          bool hovered);
  void PaintExtensionTile(size_t index,
                          gfx::Canvas* canvas,
                          const gfx::Rect& bounds,
                          bool hovered);
  void PaintAddExtensionTile(gfx::Canvas* canvas,
                             const gfx::Rect& bounds,
                             bool hovered);
  void PaintNote(const std::u16string& text,
                 gfx::Canvas* canvas,
                 const gfx::Rect& bounds,
                 bool hovered);
  void PaintBoostRow(size_t index,
                     gfx::Canvas* canvas,
                     const gfx::Rect& bounds,
                     bool hovered);
  void PaintBoostCircle(size_t index,
                        gfx::Canvas* canvas,
                        const gfx::Rect& bounds,
                        bool hovered);
  void PaintTileRow(size_t index,
                    gfx::Canvas* canvas,
                    const gfx::Rect& bounds,
                    bool hovered);
  void PaintAudioMuteRow(gfx::Canvas* canvas,
                         const gfx::Rect& bounds,
                         bool hovered);
  void PaintZoomLabel(gfx::Canvas* canvas,
                      const gfx::Rect& bounds,
                      bool hovered);
  void PaintZoomStepButton(bool zoom_in,
                           gfx::Canvas* canvas,
                           const gfx::Rect& bounds,
                           bool hovered);
  void PaintZoomResetButton(gfx::Canvas* canvas,
                            const gfx::Rect& bounds,
                            bool hovered);
  void PaintReloadLabel(gfx::Canvas* canvas,
                        const gfx::Rect& bounds,
                        bool hovered);
  void PaintReloadButton(gfx::Canvas* canvas,
                         const gfx::Rect& bounds,
                         bool hovered);
  void PaintCertificatePage(gfx::Canvas* canvas,
                            const gfx::Rect& bounds,
                            bool hovered);
  void PaintTextButton(const std::u16string& text,
                       gfx::Canvas* canvas,
                       const gfx::Rect& bounds,
                       bool hovered);
  void PaintPill(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered);
  void PaintMore(gfx::Canvas* canvas, const gfx::Rect& bounds, bool hovered);
  void PaintRowCircle(gfx::Canvas* canvas,
                      const gfx::Rect& circle,
                      bool on,
                      int symbol,
                      bool pressed);

  SkColor Color(SkColor light, SkColor dark) const {
    return appearance_.dark ? dark : light;
  }

  raw_ptr<SiteControlDelegate> delegate_;
  SiteControlState state_;
  SiteControlCallbacks callbacks_;
  secondary::Appearance appearance_;
  base::WeakPtr<content::WebContents> tab_;
  // Every tile (ad blocking first, then all kinds); VisibleTiles() filters.
  std::vector<SiteSettingTile> all_tiles_;
  // Tiles the user changed while the panel is open stay listed even when
  // the change returned them to the default (AppSiteControlSource
  // toggledContent).
  std::set<std::string> sticky_tiles_;
  bool show_all_settings_ = false;
  bool showing_certificate_ = false;

  // Fixed chrome.
  std::vector<raw_ptr<secondary::PaintedButton>> action_tiles_;
  raw_ptr<views::ScrollView> scroll_view_ = nullptr;
  raw_ptr<views::View> body_ = nullptr;
  raw_ptr<secondary::PaintedButton> pill_ = nullptr;
  raw_ptr<secondary::PaintedButton> more_ = nullptr;

  // Body children (rebuilt by BuildBody()).
  std::vector<raw_ptr<secondary::PaintedButton>> extension_tiles_;
  std::vector<raw_ptr<secondary::PaintedButton>> boost_rows_;
  std::vector<raw_ptr<secondary::PaintedButton>> boost_circles_;
  std::vector<raw_ptr<secondary::PaintedButton>> tile_rows_;
  std::vector<size_t> tile_row_indices_;  // Into all_tiles_.
  raw_ptr<secondary::PaintedButton> audio_mute_row_ = nullptr;
  raw_ptr<secondary::PaintedButton> zoom_out_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> zoom_reset_button_ = nullptr;
  raw_ptr<secondary::PaintedButton> zoom_in_button_ = nullptr;
  bool showing_audio_row_ = false;
  int body_height_ = 0;
  int separator_y_ = 0;

  // Menus.
  int menu_target_ = -1;  // Tile or extension index of the open menu.
  std::unique_ptr<ui::SimpleMenuModel> menu_model_;
  std::unique_ptr<views::MenuRunner> menu_runner_;

  base::WeakPtrFactory<OpenSiteControlView> weak_factory_{this};
};

// Owns the bubble widget for one browser window.
class OpenSiteControlBubble {
 public:
  explicit OpenSiteControlBubble(SiteControlDelegate* delegate);
  OpenSiteControlBubble(const OpenSiteControlBubble&) = delete;
  OpenSiteControlBubble& operator=(const OpenSiteControlBubble&) = delete;
  ~OpenSiteControlBubble();

  // Opens anchored to `anchor` (the sidebar URL field's Site Controls button
  // or a pane bar's Site Control button). Reopening replaces the panel.
  void Show(views::View* anchor,
            const SiteControlState& state,
            const secondary::Appearance& appearance);
  // Parity entry point: also reads and observes `tab` (live ad-block count,
  // in-use dots, navigation) and routes the parity actions to `callbacks`.
  void Show(views::View* anchor,
            const SiteControlState& state,
            const secondary::Appearance& appearance,
            content::WebContents* tab,
            const SiteControlCallbacks& callbacks);
  void Close();
  bool IsShowing() const;

  void UpdateState(const SiteControlState& state);
  void SetAppearance(const secondary::Appearance& appearance);
  void SetAdBlockState(bool enabled, int blocked_count);
  void SetCallbacks(const SiteControlCallbacks& callbacks);
  // Switches the observed tab (a tab switch while the panel is open).
  void SetWebContents(content::WebContents* tab);
  void SetReloadBannerVisible(bool visible);

  OpenSiteControlView* contents() { return contents_; }
  views::Widget* widget() { return widget_.get(); }

 private:
  class LiveObserver;

  void OnWidgetClosed(views::Widget::ClosedReason reason);
  // Cancels the current bubble's pending close callback and releases its
  // widget, then its delegate (the delegate must outlive the widget).
  // `synchronous`: delete now (destructor); else delete on the next task, as
  // the call can come from inside the old bubble's own event handling.
  void DiscardBubble(bool synchronous);
  // Live sources.
  void OnTabNavigated();
  void OnTabDestroyed();
  void OnLiveSourceChanged();
  void OnZoomLevelChanged();
  void OnBlockedCountChanged(int count);

  raw_ptr<SiteControlDelegate> delegate_;
  secondary::Appearance appearance_;
  SiteControlCallbacks callbacks_;
  std::unique_ptr<LiveObserver> live_observer_;
  std::unique_ptr<views::BubbleDialogDelegate> bubble_delegate_;
  std::unique_ptr<views::Widget> widget_;
  raw_ptr<OpenSiteControlView> contents_ = nullptr;
  // Bound into each bubble's closed callback; invalidated when the bubble is
  // replaced or this object dies, so a stale callback never runs.
  base::WeakPtrFactory<OpenSiteControlBubble> weak_factory_{this};
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_UI_VIEWS_OPEN_SITE_CONTROL_BUBBLE_H_
