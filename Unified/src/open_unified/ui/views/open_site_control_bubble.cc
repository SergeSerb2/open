// Copyright 2026 The Open Authors. All rights reserved.

#include "open_unified/ui/views/open_site_control_bubble.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <string_view>
#include <utility>

#include "base/callback_list.h"
#include "base/check.h"
#include "base/functional/bind.h"
#include "base/location.h"
#include "base/memory/scoped_refptr.h"
#include "base/scoped_observation.h"
#include "base/strings/strcat.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_split.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/task/sequenced_task_runner.h"
#include "build/build_config.h"
#include "cc/paint/paint_flags.h"
#include "chrome/browser/certificate_viewer.h"
#include "chrome/browser/content_settings/host_content_settings_map_factory.h"
#include "chrome/browser/media/webrtc/media_capture_devices_dispatcher.h"
#include "chrome/browser/media/webrtc/media_stream_capture_indicator.h"
#include "chrome/browser/profiles/profile.h"
#include "components/content_settings/core/browser/content_settings_info.h"
#include "components/content_settings/core/browser/content_settings_registry.h"
#include "components/content_settings/core/browser/host_content_settings_map.h"
#include "components/content_settings/core/common/content_settings.h"
#include "components/content_settings/core/common/content_settings_pattern.h"
#include "components/content_settings/core/common/content_settings_types.h"
#include "content/public/browser/browser_context.h"
#include "content/public/browser/browsing_data_filter_builder.h"
#include "content/public/browser/browsing_data_remover.h"
#include "content/public/browser/host_zoom_map.h"
#include "content/public/browser/navigation_controller.h"
#include "content/public/browser/navigation_entry.h"
#include "content/public/browser/page.h"
#include "content/public/browser/reload_type.h"
#include "content/public/browser/ssl_status.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_contents_capability_type.h"
#include "content/public/browser/web_contents_observer.h"
#include "net/base/hash_value.h"
#include "net/base/registry_controlled_domains/registry_controlled_domain.h"
#include "net/cert/cert_status_flags.h"
#include "net/cert/x509_cert_types.h"
#include "net/cert/x509_certificate.h"
#include "open_unified/core/adblock/open_adblock_profile_service.h"
#include "open_unified/core/model/open_types.h"
#include "open_unified/ui/design/open_glyphs.h"
#include "third_party/blink/public/common/page/page_zoom.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "ui/accessibility/ax_enums.mojom.h"
#include "ui/base/clipboard/scoped_clipboard_writer.h"
#include "ui/base/metadata/metadata_impl_macros.h"
#include "ui/base/mojom/dialog_button.mojom.h"
#include "ui/base/mojom/menu_source_type.mojom.h"
#include "ui/events/event.h"
#include "ui/gfx/canvas.h"
#include "ui/gfx/geometry/insets.h"
#include "ui/gfx/geometry/rect_f.h"
#include "ui/views/accessibility/view_accessibility.h"
#include "ui/views/bubble/bubble_border.h"
#include "ui/views/bubble/bubble_dialog_delegate_view.h"
#include "ui/views/controls/menu/menu_runner.h"
#include "ui/views/controls/menu/menu_types.h"
#include "ui/views/controls/scroll_view.h"
#include "ui/views/controls/scrollbar/overlay_scroll_bar.h"
#include "url/gurl.h"
#include "url/origin.h"
#include "url/url_constants.h"

namespace open_unified {

namespace {

using secondary::Glyph;
using secondary::PaintedButton;
namespace m = site_control_metrics;

// SiteControlColors (Light D3 / Dark Arc 1.170 measured).
constexpr SkColor kActionFillTopLight = SkColorSetRGB(0xFA, 0xFA, 0xFA);
constexpr SkColor kActionFillTopDark = SkColorSetRGB(0x27, 0x27, 0x27);
constexpr SkColor kActionFillBottomLight = SkColorSetRGB(0xFA, 0xFA, 0xFA);
constexpr SkColor kActionFillBottomDark = SkColorSetRGB(0x16, 0x16, 0x16);
constexpr SkColor kActionHighlightDark = SkColorSetRGB(0x57, 0x57, 0x57);
constexpr SkColor kActionHighlightHoverDark = SkColorSetRGB(0x48, 0x48, 0x48);
constexpr SkColor kGlyphLight = SkColorSetRGB(0x3A, 0x38, 0x2F);
constexpr SkColor kLabelLight = SkColorSetRGB(0x26, 0x24, 0x1C);
constexpr SkColor kLabelDark = SkColorSetRGB(0xDB, 0xDB, 0xDF);
constexpr SkColor kRowTitleLight = SkColorSetRGB(0x26, 0x24, 0x1C);
constexpr SkColor kRowTitleDark = SkColorSetRGB(0xDF, 0xDF, 0xE2);
constexpr SkColor kRowSubtitleDark = SkColorSetRGB(0x9F, 0x9E, 0xA9);
constexpr SkColor kCircleOnDark = SkColorSetRGB(0xEC, 0xED, 0xFF);
constexpr SkColor kSeparatorDark = SkColorSetRGB(0x23, 0x23, 0x23);
constexpr SkColor kInsecureTextLight = SkColorSetRGB(0xD8, 0x43, 0x2C);
constexpr SkColor kInsecureTextDark = SkColorSetRGB(0xF2, 0x5E, 0x6B);
// Core.brandBlue #3139FB: the in-use dot after the row title
// (SiteControlRow.updateLayer).
constexpr SkColor kInUseDot = SkColorSetRGB(0x31, 0x39, 0xFB);
// Solid panel body (Open choice, see header).
constexpr SkColor kPanelLight = SkColorSetRGB(0xF4, 0xF3, 0xEC);
constexpr SkColor kPanelDark = SkColorSetRGB(0x2C, 0x2C, 0x33);

constexpr int kTitleFontSize = 14;     // siteControlRowTitle 14 semibold
constexpr int kSubtitleFontSize = 13;  // siteControlRowSubtitle 13 regular
constexpr int kLabelFontSize = 14;     // siteControlLabel 14 semibold
constexpr int kPillFontSize = 14;      // siteControlPill 14 medium

// The fixed chrome around the scrolling body: padding, tiles, separator,
// gap, footer, padding.
constexpr int kFixedHeight = m::kPadding + m::kActionHeight + 1 +
                             m::kGapAfterSeparator + m::kFooterHeight +
                             m::kPadding;

// Menu commands.
enum : int {
  // Settings tile menu.
  kCmdAllow = 100,
  kCmdBlock,
  kCmdReset,
  // "..." menu (SiteControlController.showMore order).
  kCmdClearCache = 200,
  kCmdClearCookies,
  kCmdCopyCleanUrl,
  kCmdManageBoosts,
  kCmdNewBoost,
  kCmdManageExtensions,
  kCmdAddExtension,
  kCmdSiteSettings,
  // Extension tile fallback menu.
  kCmdExtRun = 300,
  kCmdExtPin,
  kCmdExtManage,
};
constexpr int kTileMenuGroup = 1;

// --- Symbols -----------------------------------------------------------------
// macOS draws the SF Symbol AppSiteControlSource names; Windows and Linux
// draw Open's own vector glyph (or a local path below).

enum class Sym : int {
  kShare,
  kBoost,
  kBoostFill,
  kCapture,
  kCaptureFull,
  kLock,
  kLockOpen,
  kMore,
  kPlus,
  kChevronRight,
  kChevronLeft,
  kAdBlock,
  kCamera,
  kMicrophone,
  kLocation,
  kNotifications,
  kClipboard,
  kMidi,
  kScreenCapture,
  kDownloads,
  kStorage,
  kWindows,
  kFonts,
  kIdle,
  kSensors,
  kJavaScript,
  kImages,
  kPopups,
  kAds,
  kSync,
  kSound,
  kUsb,
  kHid,
  kSerial,
  kBluetooth,
  kHand,
  kKeyboardLock,
  kPointer,
  kNetwork,
  kSoundMuted,
  kMinus,
  kCount,
};

struct SymSpec {
  const char* sf;
  Glyph fallback;
};

constexpr std::array<SymSpec, static_cast<size_t>(Sym::kCount)> kSyms = {{
    {"square.and.arrow.up", Glyph::kNone},           // kShare (path)
    {"paintbrush.pointed", Glyph::kBoost},           // kBoost
    {"paintbrush.pointed.fill", Glyph::kBoost},      // kBoostFill
    {"camera", Glyph::kCapture},                     // kCapture
    {"text.viewfinder", Glyph::kNone},               // kCaptureFull (path)
    {"lock.fill", Glyph::kLock},                     // kLock
    {"lock.open.fill", Glyph::kLockOpen},            // kLockOpen
    {"ellipsis", Glyph::kNone},                      // kMore (open_glyphs)
    {"plus", Glyph::kPlus},                          // kPlus
    {"chevron.right", Glyph::kChevronRight},         // kChevronRight
    {"chevron.left", Glyph::kBack},                  // kChevronLeft
    {"hand.raised.fill", Glyph::kShield},            // kAdBlock
    {"video.fill", Glyph::kCamera},                  // kCamera
    {"mic.fill", Glyph::kMicrophone},                // kMicrophone
    {"location.fill", Glyph::kLocation},             // kLocation
    {"bell.fill", Glyph::kBell},                     // kNotifications
    {"doc.on.clipboard.fill", Glyph::kCopy},         // kClipboard
    {"pianokeys", Glyph::kMidi},                     // kMidi
    {"rectangle.on.rectangle", Glyph::kSplit},       // kScreenCapture
    {"arrow.down.circle.fill", Glyph::kDownload},    // kDownloads
    {"externaldrive.fill", Glyph::kStack},           // kStorage
    {"macwindow.on.rectangle", Glyph::kPopup},       // kWindows
    {"textformat", Glyph::kFonts},                   // kFonts
    {"moon.zzz.fill", Glyph::kIdle},                 // kIdle
    {"gyroscope", Glyph::kSensors},                  // kSensors
    {"curlybraces", Glyph::kJavaScript},             // kJavaScript
    {"photo.fill", Glyph::kCapture},                 // kImages
    {"macwindow.badge.plus", Glyph::kPopup},         // kPopups
    {"rectangle.slash.fill", Glyph::kShield},        // kAds
    {"arrow.triangle.2.circlepath", Glyph::kReload}, // kSync
    {"speaker.wave.2.fill", Glyph::kSound},          // kSound
    {"cable.connector", Glyph::kBolt},               // kUsb
    {"keyboard.fill", Glyph::kHid},                  // kHid
    {"cable.connector.horizontal", Glyph::kBolt},    // kSerial
    {"antenna.radiowaves.left.and.right", Glyph::kBluetooth},  // kBluetooth
    {"hand.raised.fill", Glyph::kHandTracking},      // kHand
    {"lock.fill", Glyph::kLock},                     // kKeyboardLock
    {"cursorarrow", Glyph::kPointerLock},            // kPointer
    {"network", Glyph::kGlobe},                      // kNetwork
    {"speaker.slash.fill", Glyph::kNone},            // kSoundMuted (open_glyphs)
    {"minus", Glyph::kMinus},                        // kMinus
}};

cc::PaintFlags StrokeFlags(SkColor color, float width) {
  cc::PaintFlags flags;
  flags.setAntiAlias(true);
  flags.setColor(color);
  flags.setStyle(cc::PaintFlags::kStroke_Style);
  flags.setStrokeWidth(width);
  flags.setStrokeCap(cc::PaintFlags::kRound_Cap);
  flags.setStrokeJoin(cc::PaintFlags::kRound_Join);
  return flags;
}

// Open's share mark: an open-top box with an arrow rising out of it.
void PaintShareGlyph(gfx::Canvas* canvas, const gfx::RectF& box, SkColor c) {
  const float s = box.width();
  const float x = box.x();
  const float y = box.y();
  const float w = std::max(1.2f, s / 11.f);
  SkPathBuilder b;
  b.moveTo(x + s * 0.32f, y + s * 0.40f);
  b.lineTo(x + s * 0.18f, y + s * 0.40f);
  b.lineTo(x + s * 0.18f, y + s * 0.95f);
  b.lineTo(x + s * 0.82f, y + s * 0.95f);
  b.lineTo(x + s * 0.82f, y + s * 0.40f);
  b.lineTo(x + s * 0.68f, y + s * 0.40f);
  b.moveTo(x + s * 0.5f, y + s * 0.62f);
  b.lineTo(x + s * 0.5f, y + s * 0.05f);
  b.moveTo(x + s * 0.32f, y + s * 0.22f);
  b.lineTo(x + s * 0.5f, y + s * 0.05f);
  b.lineTo(x + s * 0.68f, y + s * 0.22f);
  canvas->DrawPath(b.detach(), StrokeFlags(c, w));
}

// Open's full-page capture mark: viewfinder corners around text lines.
void PaintViewfinderGlyph(gfx::Canvas* canvas,
                          const gfx::RectF& box,
                          SkColor c) {
  const float s = box.width();
  const float x = box.x();
  const float y = box.y();
  const float k = s * 0.28f;
  const float w = std::max(1.2f, s / 11.f);
  SkPathBuilder b;
  b.moveTo(x, y + k);
  b.lineTo(x, y);
  b.lineTo(x + k, y);
  b.moveTo(x + s - k, y);
  b.lineTo(x + s, y);
  b.lineTo(x + s, y + k);
  b.moveTo(x + s, y + s - k);
  b.lineTo(x + s, y + s);
  b.lineTo(x + s - k, y + s);
  b.moveTo(x + k, y + s);
  b.lineTo(x, y + s);
  b.lineTo(x, y + s - k);
  for (float f : {0.36f, 0.52f, 0.68f}) {
    b.moveTo(x + s * 0.27f, y + s * f);
    b.lineTo(x + s * (f == 0.68f ? 0.55f : 0.73f), y + s * f);
  }
  canvas->DrawPath(b.detach(), StrokeFlags(c, w));
}

void PaintSym(gfx::Canvas* canvas,
              Sym sym,
              const gfx::RectF& box,
              SkColor color,
              float point_size,
              glyphs::SymbolWeight weight = glyphs::SymbolWeight::kRegular) {
  const SymSpec& spec = kSyms[static_cast<size_t>(sym)];
  if (glyphs::DrawSystemSymbol(canvas, spec.sf, point_size, weight, box,
                               color)) {
    return;
  }
  const float g = std::min(box.width(), box.height());
  const gfx::RectF square(box.CenterPoint().x() - g / 2.f,
                          box.CenterPoint().y() - g / 2.f, g, g);
  switch (sym) {
    case Sym::kShare:
      PaintShareGlyph(canvas, square, color);
      return;
    case Sym::kCaptureFull:
      PaintViewfinderGlyph(canvas, square, color);
      return;
    case Sym::kMore:
      glyphs::Draw(canvas, glyphs::Glyph::kMore, box, color);
      return;
    case Sym::kSoundMuted:
      glyphs::Draw(canvas, glyphs::Glyph::kSpeakerMuted, box, color);
      return;
    default:
      secondary::PaintGlyph(canvas, spec.fallback, square, color);
      return;
  }
}

// --- Setting types -----------------------------------------------------------

struct TypeSpec {
  SiteSettingType type;
  ContentSettingsType content_type;
  const char* id;
  const char16_t* title;
  Sym sym;
  bool permission;
};

// AppSiteControlSource permissionRows, then contentRows.
constexpr std::array<TypeSpec, kSiteSettingTypeCount> kTypes = {{
    {SiteSettingType::kCamera, ContentSettingsType::MEDIASTREAM_CAMERA,
     "permission.camera", u"Camera", Sym::kCamera, true},
    {SiteSettingType::kMicrophone, ContentSettingsType::MEDIASTREAM_MIC,
     "permission.microphone", u"Microphone", Sym::kMicrophone, true},
    {SiteSettingType::kLocation, ContentSettingsType::GEOLOCATION,
     "permission.geolocation", u"Location", Sym::kLocation, true},
    {SiteSettingType::kNotifications, ContentSettingsType::NOTIFICATIONS,
     "permission.notifications", u"Notifications", Sym::kNotifications, true},
    {SiteSettingType::kClipboard, ContentSettingsType::CLIPBOARD_READ_WRITE,
     "permission.clipboard", u"Clipboard", Sym::kClipboard, true},
    {SiteSettingType::kMidi, ContentSettingsType::MIDI_SYSEX,
     "permission.midi", u"MIDI Devices", Sym::kMidi, true},
    {SiteSettingType::kScreenCapture, ContentSettingsType::DISPLAY_CAPTURE,
     "permission.screenCapture", u"Screen Sharing", Sym::kScreenCapture, true},
    {SiteSettingType::kAutomaticDownloads,
     ContentSettingsType::AUTOMATIC_DOWNLOADS, "permission.automaticDownloads",
     u"Automatic Downloads", Sym::kDownloads, true},
    {SiteSettingType::kStorageAccess, ContentSettingsType::STORAGE_ACCESS,
     "permission.storageAccess", u"Storage Access", Sym::kStorage, true},
    {SiteSettingType::kWindowManagement,
     ContentSettingsType::WINDOW_MANAGEMENT, "permission.windowManagement",
     u"Window Management", Sym::kWindows, true},
    {SiteSettingType::kLocalFonts, ContentSettingsType::LOCAL_FONTS,
     "permission.localFonts", u"Fonts", Sym::kFonts, true},
    {SiteSettingType::kIdleDetection, ContentSettingsType::IDLE_DETECTION,
     "permission.idleDetection", u"Idle Detection", Sym::kIdle, true},
    {SiteSettingType::kSensors, ContentSettingsType::SENSORS,
     "content.sensors", u"Motion Sensors", Sym::kSensors, false},
    {SiteSettingType::kJavaScript, ContentSettingsType::JAVASCRIPT,
     "content.javascript", u"JavaScript", Sym::kJavaScript, false},
    {SiteSettingType::kImages, ContentSettingsType::IMAGES, "content.images",
     u"Images", Sym::kImages, false},
    {SiteSettingType::kPopups, ContentSettingsType::POPUPS, "content.popups",
     u"Pop-ups", Sym::kPopups, false},
    {SiteSettingType::kIntrusiveAds, ContentSettingsType::ADS,
     "content.subresource-filter", u"Intrusive Ads", Sym::kAds, false},
    {SiteSettingType::kBackgroundSync, ContentSettingsType::BACKGROUND_SYNC,
     "content.background-sync", u"Background Sync", Sym::kSync, false},
    {SiteSettingType::kSound, ContentSettingsType::SOUND, "content.sound",
     u"Sound", Sym::kSound, false},
    {SiteSettingType::kUsbDevices, ContentSettingsType::USB_GUARD,
     "content.usb-guard", u"USB Devices", Sym::kUsb, false},
    {SiteSettingType::kHidDevices, ContentSettingsType::HID_GUARD,
     "content.hid-guard", u"HID Devices", Sym::kHid, false},
    {SiteSettingType::kSerialPorts, ContentSettingsType::SERIAL_GUARD,
     "content.serial-guard", u"Serial Ports", Sym::kSerial, false},
    {SiteSettingType::kBluetoothDevices, ContentSettingsType::BLUETOOTH_GUARD,
     "content.bluetooth-guard", u"Bluetooth Devices", Sym::kBluetooth, false},
    {SiteSettingType::kHandTracking, ContentSettingsType::HAND_TRACKING,
     "content.hand-tracking", u"Hand Tracking", Sym::kHand, false},
    {SiteSettingType::kKeyboardLock, ContentSettingsType::KEYBOARD_LOCK,
     "content.keyboard-lock", u"Keyboard Lock", Sym::kKeyboardLock, false},
    {SiteSettingType::kPointerLock, ContentSettingsType::POINTER_LOCK,
     "content.pointer-lock", u"Pointer Lock", Sym::kPointer, false},
    {SiteSettingType::kLocalNetwork, ContentSettingsType::LOCAL_NETWORK_ACCESS,
     "content.local-network-access", u"Local Network", Sym::kNetwork, false},
}};

const TypeSpec& SpecFor(SiteSettingType type) {
  for (const TypeSpec& spec : kTypes) {
    if (spec.type == type) {
      return spec;
    }
  }
  return kTypes[0];
}

Sym SymForTile(const SiteSettingTile& tile) {
  return tile.kind == SiteSettingTileKind::kContentBlocking
             ? Sym::kAdBlock
             : SpecFor(tile.type).sym;
}

const content_settings::ContentSettingsInfo* InfoFor(ContentSettingsType t) {
  return content_settings::ContentSettingsRegistry::GetInstance()->Get(t);
}

SitePermissionSetting ToSetting(ContentSetting value) {
  switch (value) {
    case CONTENT_SETTING_ALLOW:
    case CONTENT_SETTING_SESSION_ONLY:
      return SitePermissionSetting::kAllow;
    case CONTENT_SETTING_BLOCK:
      return SitePermissionSetting::kBlock;
    default:
      return SitePermissionSetting::kAsk;
  }
}

std::u16string SubtitleFor(SitePermissionSetting setting) {
  switch (setting) {
    case SitePermissionSetting::kAllow:
      return u"Allowed";
    case SitePermissionSetting::kBlock:
      return u"Blocked";
    case SitePermissionSetting::kAsk:
      return u"Ask";
  }
  return std::u16string();
}

HostContentSettingsMap* SettingsMapFor(content::WebContents* tab) {
  if (!tab) {
    return nullptr;
  }
  return HostContentSettingsMapFactory::GetForProfile(
      ::Profile::FromBrowserContext(tab->GetBrowserContext()));
}

bool IsWebsite(const GURL& url) {
  return url.SchemeIsHTTPOrHTTPS() && url.has_host();
}

bool InUse(content::WebContents* tab, SiteSettingType type) {
  if (!tab) {
    return false;
  }
  scoped_refptr<MediaStreamCaptureIndicator> indicator =
      MediaCaptureDevicesDispatcher::GetInstance()
          ->GetMediaStreamCaptureIndicator();
  switch (type) {
    case SiteSettingType::kCamera:
      return indicator && indicator->IsCapturingVideo(tab);
    case SiteSettingType::kMicrophone:
      return indicator && indicator->IsCapturingAudio(tab);
    case SiteSettingType::kScreenCapture:
      return indicator && (indicator->IsCapturingDisplay(tab) ||
                           indicator->IsCapturingWindow(tab) ||
                           indicator->IsCapturingTab(tab));
    case SiteSettingType::kLocation:
      return tab->IsCapabilityActive(
          content::WebContentsCapabilityType::kGeolocation);
    case SiteSettingType::kUsbDevices:
      return tab->IsCapabilityActive(content::WebContentsCapabilityType::kUSB);
    case SiteSettingType::kHidDevices:
      return tab->IsCapabilityActive(content::WebContentsCapabilityType::kHID);
    case SiteSettingType::kSerialPorts:
      return tab->IsCapabilityActive(
          content::WebContentsCapabilityType::kSerial);
    case SiteSettingType::kBluetoothDevices:
      return tab->IsCapabilityActive(
                 content::WebContentsCapabilityType::kBluetoothConnected) ||
             tab->IsCapabilityActive(
                 content::WebContentsCapabilityType::kBluetoothScanning);
    default:
      return false;
  }
}

SiteSettingTile AdBlockTileFromFields(const SiteControlState& state) {
  SiteSettingTile tile;
  tile.id = "contentBlocking";
  tile.kind = SiteSettingTileKind::kContentBlocking;
  tile.title = u"Block Ads & Trackers";
  tile.changed = true;
  tile.enabled = state.ad_block_changeable;
  if (!state.ad_block_available) {
    tile.state = SiteSettingTileState::kUnavailable;
    tile.subtitle = u"Off";
    tile.help = u"The built-in ad blocker is off. You can turn it on in "
                u"Settings.";
    tile.enabled = true;  // Opens Settings.
  } else if (!state.ad_block_enabled || state.ad_block_excluded) {
    tile.state = SiteSettingTileState::kOff;
    tile.subtitle = state.ad_block_excluded ? u"Paused on this site" : u"Off";
    tile.help = u"The built-in ad blocker is off for this site.";
  } else {
    tile.state = SiteSettingTileState::kOn;
    tile.subtitle =
        state.ad_block_blocked_count > 0
            ? base::StrCat({base::NumberToString16(
                                state.ad_block_blocked_count),
                            u" blocked"})
            : std::u16string(u"On");
    tile.help = u"The built-in ad blocker is on for this site.";
  }
  if (!state.ad_block_changeable) {
    tile.help = u"Ad blocking can't be turned off for this site.";
  }
  if (!state.ad_block_filter_status.empty()) {
    tile.help = base::StrCat({tile.help, u" ", state.ad_block_filter_status});
  }
  return tile;
}

std::u16string FormatDate(base::Time time) {
  if (time.is_null()) {
    return u"-";
  }
  static constexpr std::array<const char16_t*, 12> kMonths = {
      u"Jan", u"Feb", u"Mar", u"Apr", u"May", u"Jun",
      u"Jul", u"Aug", u"Sep", u"Oct", u"Nov", u"Dec"};
  base::Time::Exploded e;
  time.LocalExplode(&e);
  if (e.month < 1 || e.month > 12) {
    return u"-";
  }
  return base::StrCat({kMonths[static_cast<size_t>(e.month - 1)], u" ",
                       base::NumberToString16(e.day_of_month), u", ",
                       base::NumberToString16(e.year)});
}

// Self-owned reply observer for one origin-scoped clear.
class SiteDataClearer : public content::BrowsingDataRemover::Observer {
 public:
  SiteDataClearer(content::BrowsingDataRemover* remover,
                  base::WeakPtr<content::WebContents> tab,
                  GURL expected_url,
                  base::OnceCallback<void(bool)> done)
      : remover_(remover),
        tab_(std::move(tab)),
        expected_origin_(url::Origin::Create(expected_url)),
        done_(std::move(done)) {
    remover_->AddObserver(this);
  }

  void Start(uint64_t mask,
             std::unique_ptr<content::BrowsingDataFilterBuilder> filter) {
    remover_->RemoveWithFilterAndReply(
        base::Time(), base::Time::Max(), mask,
        content::BrowsingDataRemover::ORIGIN_TYPE_UNPROTECTED_WEB |
            content::BrowsingDataRemover::ORIGIN_TYPE_PROTECTED_WEB,
        std::move(filter), this);
  }

  // content::BrowsingDataRemover::Observer:
  void OnBrowsingDataRemoverDone(uint64_t failed_data_types) override {
    remover_->RemoveObserver(this);
    // Reload only when the tab still shows the cleared origin.
    if (tab_ && url::Origin::Create(tab_->GetLastCommittedURL())
                    .IsSameOriginWith(expected_origin_)) {
      tab_->GetController().Reload(content::ReloadType::BYPASSING_CACHE,
                                   /*check_for_repost=*/true);
    }
    if (done_) {
      std::move(done_).Run(failed_data_types == 0);
    }
    delete this;
  }

 private:
  ~SiteDataClearer() override = default;

  raw_ptr<content::BrowsingDataRemover> remover_;
  base::WeakPtr<content::WebContents> tab_;
  url::Origin expected_origin_;
  base::OnceCallback<void(bool)> done_;
};

constexpr std::string_view kTrackingParams[] = {
    "fbclid", "gclid",   "dclid",      "gbraid",     "wbraid",
    "msclkid", "mc_cid", "mc_eid",     "igshid",     "yclid",
    "_hsenc", "_hsmi",   "mkt_tok",    "ttclid",     "twclid",
    "li_fat_id", "oly_anon_id", "oly_enc_id", "vero_id", "_ga",
    "_gl",    "ref_src", "spm",        "si_source",
};

bool IsTrackingParam(std::string_view key) {
  const std::string lower = base::ToLowerASCII(key);
  if (lower.starts_with("utm_")) {
    return true;
  }
  return std::find(std::begin(kTrackingParams), std::end(kTrackingParams),
                   lower) != std::end(kTrackingParams);
}

}  // namespace

// --- Structs -----------------------------------------------------------------

SiteSettingTile::SiteSettingTile() = default;
SiteSettingTile::SiteSettingTile(const SiteSettingTile&) = default;
SiteSettingTile& SiteSettingTile::operator=(const SiteSettingTile&) = default;
SiteSettingTile::~SiteSettingTile() = default;

SiteCertificateSummary::SiteCertificateSummary() = default;
SiteCertificateSummary::SiteCertificateSummary(const SiteCertificateSummary&) =
    default;
SiteCertificateSummary& SiteCertificateSummary::operator=(
    const SiteCertificateSummary&) = default;
SiteCertificateSummary::~SiteCertificateSummary() = default;

SiteControlState::SiteControlState() = default;
SiteControlState::SiteControlState(const SiteControlState&) = default;
SiteControlState& SiteControlState::operator=(const SiteControlState&) =
    default;
SiteControlState::~SiteControlState() = default;

SiteControlCallbacks::SiteControlCallbacks() = default;
SiteControlCallbacks::SiteControlCallbacks(const SiteControlCallbacks&) =
    default;
SiteControlCallbacks& SiteControlCallbacks::operator=(
    const SiteControlCallbacks&) = default;
SiteControlCallbacks::~SiteControlCallbacks() = default;

// --- site_control_data -------------------------------------------------------

namespace site_control_data {

std::u16string TitleFor(SiteSettingType type) {
  return SpecFor(type).title;
}

std::optional<SitePermissionKind> LegacyKindFor(SiteSettingType type) {
  switch (type) {
    case SiteSettingType::kCamera:
      return SitePermissionKind::kCamera;
    case SiteSettingType::kMicrophone:
      return SitePermissionKind::kMicrophone;
    case SiteSettingType::kLocation:
      return SitePermissionKind::kLocation;
    case SiteSettingType::kNotifications:
      return SitePermissionKind::kNotifications;
    case SiteSettingType::kPopups:
      return SitePermissionKind::kPopups;
    default:
      return std::nullopt;
  }
}

SiteSettingType TypeForLegacyKind(SitePermissionKind kind) {
  switch (kind) {
    case SitePermissionKind::kCamera:
      return SiteSettingType::kCamera;
    case SitePermissionKind::kMicrophone:
      return SiteSettingType::kMicrophone;
    case SitePermissionKind::kLocation:
      return SiteSettingType::kLocation;
    case SitePermissionKind::kNotifications:
      return SiteSettingType::kNotifications;
    case SitePermissionKind::kPopups:
      return SiteSettingType::kPopups;
  }
  return SiteSettingType::kCamera;
}

SiteSettingTile BuildAdBlockTile(content::WebContents* tab) {
  SiteControlState state;
  if (tab) {
    const GURL url = tab->GetLastCommittedURL();
    const std::string host(url.host());
    OpenAdBlockProfileService* adblock =
        OpenAdBlockProfileService::GetForBrowserContext(
            tab->GetBrowserContext());
    state.ad_block_available = adblock && adblock->service();
    state.ad_block_enabled = state.ad_block_available && adblock->IsEnabled();
    state.ad_block_excluded = adblock && adblock->IsHostExcluded(host);
    // Exclusions are stored per registrable domain: a one-word host or a
    // public suffix cannot be excluded (AppSiteControlSource
    // canExcludeAdBlockSite).
    state.ad_block_changeable =
        OpenAdBlockProfileService::NormalizeExclusionDomain(host).has_value();
    state.ad_block_blocked_count =
        OpenAdBlockProfileService::GetTotalStoppedCount(tab);
    if (adblock) {
      const AdBlockProfileSnapshot snapshot = adblock->GetSnapshot();
      if (snapshot.is_updating) {
        state.ad_block_filter_status = u"Updating filter lists.";
      } else if (!snapshot.last_error.empty()) {
        state.ad_block_filter_status = u"The last filter update failed.";
      } else {
        const size_t lists = snapshot.enabled_list_ids.size();
        state.ad_block_filter_status = base::StrCat(
            {base::NumberToString16(lists),
             lists == 1 ? u" filter list is on." : u" filter lists are on."});
      }
    }
  } else {
    state.ad_block_available = false;
  }
  return AdBlockTileFromFields(state);
}

SitePermissionSetting GetSiteSetting(content::WebContents* tab,
                                     SiteSettingType type) {
  HostContentSettingsMap* map = SettingsMapFor(tab);
  const TypeSpec& spec = SpecFor(type);
  if (!map || !InfoFor(spec.content_type)) {
    return SitePermissionSetting::kAsk;
  }
  const GURL url = tab->GetLastCommittedURL();
  return ToSetting(map->GetContentSetting(url, url, spec.content_type));
}

std::vector<SiteSettingTile> BuildSiteSettingTiles(content::WebContents* tab) {
  std::vector<SiteSettingTile> tiles;
  if (!tab || !IsWebsite(tab->GetLastCommittedURL())) {
    return tiles;
  }
  tiles.push_back(BuildAdBlockTile(tab));
  HostContentSettingsMap* map = SettingsMapFor(tab);
  const GURL url = tab->GetLastCommittedURL();
  for (const TypeSpec& spec : kTypes) {
    SiteSettingTile tile;
    tile.id = spec.id;
    tile.kind = spec.permission ? SiteSettingTileKind::kPermission
                                : SiteSettingTileKind::kContent;
    tile.type = spec.type;
    tile.title = spec.title;
    tile.in_use = InUse(tab, spec.type);
    const content_settings::ContentSettingsInfo* info =
        InfoFor(spec.content_type);
    if (!map || !info) {
      // Not a content setting on this build (for example DISPLAY_CAPTURE):
      // listed only while the tab uses it.
      tile.state = SiteSettingTileState::kUnavailable;
      tile.subtitle = tile.in_use ? u"In use" : u"Ask";
      tile.enabled = false;
      tile.changed = false;
      tiles.push_back(std::move(tile));
      continue;
    }
    content_settings::SettingInfo setting_info;
    const ContentSetting value =
        map->GetContentSetting(url, url, spec.content_type, &setting_info);
    tile.setting = ToSetting(value);
    tile.state = tile.setting == SitePermissionSetting::kAllow
                     ? SiteSettingTileState::kOn
                     : SiteSettingTileState::kOff;
    tile.subtitle = SubtitleFor(tile.setting);
    const bool site_rule =
        setting_info.source == content_settings::SettingSource::kUser &&
        !setting_info.primary_pattern.MatchesAllHosts();
    // Permissions: shown when not Ask; content: when the site has its own
    // rule (AppSiteControlSource changedSiteSettings).
    tile.changed = spec.permission
                       ? (site_rule && tile.setting != SitePermissionSetting::kAsk)
                       : site_rule;
    tile.enabled =
        setting_info.source == content_settings::SettingSource::kUser ||
        setting_info.source == content_settings::SettingSource::kNone;
    if (!tile.enabled) {
      tile.help = u"This setting is managed and can't be changed here.";
    }
    if (tile.in_use) {
      tile.help = base::StrCat({tile.title, u" is in use on this page."});
    }
    tiles.push_back(std::move(tile));
  }
  return tiles;
}

void FillStateFromTab(content::WebContents* tab, SiteControlState* state) {
  if (!tab || !state) {
    return;
  }
  const GURL url = tab->GetLastCommittedURL();
  state->url = url;
  state->host = base::UTF8ToUTF16(url.host());
  state->is_website = IsWebsite(url);
  state->incognito = tab->GetBrowserContext()->IsOffTheRecord();
  state->secure = url.SchemeIsCryptographic();
  if (content::NavigationEntry* entry =
          tab->GetController().GetLastCommittedEntry()) {
    const content::SSLStatus& ssl = entry->GetSSL();
    if (state->secure && net::IsCertStatusError(ssl.cert_status)) {
      state->secure = false;
    }
  }
  state->tiles = BuildSiteSettingTiles(tab);
  const SiteSettingTile ad = BuildAdBlockTile(tab);
  state->ad_block_available = ad.state != SiteSettingTileState::kUnavailable;
  state->ad_block_enabled = ad.state == SiteSettingTileState::kOn;
  state->ad_block_blocked_count =
      OpenAdBlockProfileService::GetTotalStoppedCount(tab);
  state->ad_block_changeable = ad.enabled;
  state->capture_available = state->is_website;
}

bool ApplySiteSetting(content::WebContents* tab,
                      SiteSettingType type,
                      SitePermissionSetting setting) {
  HostContentSettingsMap* map = SettingsMapFor(tab);
  const TypeSpec& spec = SpecFor(type);
  const content_settings::ContentSettingsInfo* info =
      InfoFor(spec.content_type);
  if (!map || !info) {
    return false;
  }
  const GURL url = tab->GetLastCommittedURL();
  if (!IsWebsite(url)) {
    return false;
  }
  ContentSetting value = CONTENT_SETTING_DEFAULT;
  if (setting == SitePermissionSetting::kAllow) {
    value = CONTENT_SETTING_ALLOW;
  } else if (setting == SitePermissionSetting::kBlock) {
    value = CONTENT_SETTING_BLOCK;
  }
  if (value != CONTENT_SETTING_DEFAULT && !info->IsSettingValid(value)) {
    return false;
  }
  map->SetContentSettingDefaultScope(url, url, spec.content_type, value);
  return true;
}

void ClearSiteDataAndReload(content::WebContents* tab,
                            SiteDataKind kind,
                            base::OnceCallback<void(bool)> done) {
  const GURL url = tab ? tab->GetLastCommittedURL() : GURL();
  if (!tab || !IsWebsite(url)) {
    if (done) {
      std::move(done).Run(false);
    }
    return;
  }
  // Cookies are scoped to the registrable domain; the cache filter matches
  // the same domain. A one-word host or an IP is its own domain.
  std::string domain = net::registry_controlled_domains::GetDomainAndRegistry(
      url, net::registry_controlled_domains::INCLUDE_PRIVATE_REGISTRIES);
  if (domain.empty()) {
    domain = std::string(url.host());
  }
  auto filter = content::BrowsingDataFilterBuilder::Create(
      content::BrowsingDataFilterBuilder::Mode::kDelete);
  filter->AddRegisterableDomain(domain);
  const uint64_t mask = kind == SiteDataKind::kCookies
                            ? content::BrowsingDataRemover::DATA_TYPE_COOKIES
                            : content::BrowsingDataRemover::DATA_TYPE_CACHE;
  content::BrowsingDataRemover* remover =
      tab->GetBrowserContext()->GetBrowsingDataRemover();
  // Deletes itself when the remover replies.
  auto* clearer =
      new SiteDataClearer(remover, tab->GetWeakPtr(), url, std::move(done));
  clearer->Start(mask, std::move(filter));
}

std::optional<SiteCertificateSummary> CertificateSummaryForTab(
    content::WebContents* tab) {
  if (!tab) {
    return std::nullopt;
  }
  content::NavigationEntry* entry =
      tab->GetController().GetLastCommittedEntry();
  if (!entry || !entry->GetSSL().certificate) {
    return std::nullopt;
  }
  const content::SSLStatus& ssl = entry->GetSSL();
  const net::X509Certificate& cert = *ssl.certificate;
  SiteCertificateSummary summary;
  const std::string subject = cert.subject().common_name.empty()
                                  ? cert.subject().GetDisplayName()
                                  : cert.subject().common_name;
  summary.subject = base::UTF8ToUTF16(subject);
  if (!cert.subject().organization_names.empty()) {
    summary.organization =
        base::UTF8ToUTF16(cert.subject().organization_names.front());
  }
  summary.issuer = base::UTF8ToUTF16(cert.issuer().GetDisplayName());
  summary.valid_from = cert.valid_start();
  summary.valid_until = cert.valid_expiry();
  std::vector<std::string> dns_names;
  std::vector<std::string> ip_addrs;
  cert.GetSubjectAltName(&dns_names, &ip_addrs);
  for (const std::string& name : dns_names) {
    summary.subject_alt_names.push_back(base::UTF8ToUTF16(name));
  }
  for (const std::string& ip : ip_addrs) {
    // iPAddress SANs are raw bytes; show IPv4 dotted, IPv6 as hex.
    std::string text;
    if (ip.size() == 4) {
      for (size_t i = 0; i < 4; ++i) {
        if (i) {
          text += '.';
        }
        text += base::NumberToString(static_cast<uint8_t>(ip[i]));
      }
    } else {
      text = base::HexEncode(ip);
    }
    summary.subject_alt_names.push_back(base::UTF8ToUTF16(text));
  }
  const net::SHA256HashValue hash =
      net::X509Certificate::CalculateFingerprint256(cert.cert_buffer());
  const std::string hex = base::HexEncode(hash);
  std::string grouped;
  for (size_t i = 0; i < hex.size(); i += 2) {
    if (i) {
      grouped += ':';
    }
    grouped += hex.substr(i, 2);
  }
  summary.sha256 = base::UTF8ToUTF16(grouped);
  summary.has_errors = net::IsCertStatusError(ssl.cert_status);
  summary.expired = cert.HasExpired();
  return summary;
}

bool ShowCertificateViewerForTab(content::WebContents* tab) {
  if (!tab) {
    return false;
  }
  content::NavigationEntry* entry =
      tab->GetController().GetLastCommittedEntry();
  if (!entry || !entry->GetSSL().certificate) {
    return false;
  }
  ShowCertificateViewer(tab, tab->GetTopLevelNativeWindow(),
                        entry->GetSSL().certificate.get());
  return true;
}

GURL CleanUrlForSharing(const GURL& url) {
  if (!url.is_valid()) {
    return url;
  }
  GURL::Replacements replacements;
  std::string query;
  if (url.has_query()) {
    std::vector<std::string_view> kept;
    for (std::string_view part : base::SplitStringPiece(
             url.query(), "&", base::KEEP_WHITESPACE,
             base::SPLIT_WANT_NONEMPTY)) {
      const size_t eq = part.find('=');
      const std::string_view key =
          eq == std::string_view::npos ? part : part.substr(0, eq);
      if (!IsTrackingParam(key)) {
        kept.push_back(part);
      }
    }
    query = base::JoinString(kept, "&");
    if (query.empty()) {
      replacements.ClearQuery();
    } else {
      replacements.SetQueryStr(query);
    }
  }
  // Text fragment directives (#:~:text=) are not part of the page address.
  std::string ref;
  if (url.has_ref()) {
    const std::string_view full = url.ref();
    const size_t directive = full.find(":~:");
    if (directive != std::string_view::npos) {
      ref = std::string(full.substr(0, directive));
      if (ref.empty()) {
        replacements.ClearRef();
      } else {
        replacements.SetRefStr(ref);
      }
    }
  }
  return url.ReplaceComponents(replacements);
}

void CopyCleanUrl(const GURL& url) {
  const GURL clean = CleanUrlForSharing(url);
  if (!clean.is_valid()) {
    return;
  }
  ui::ScopedClipboardWriter(ui::ClipboardBuffer::kCopyPaste)
      .WriteText(base::UTF8ToUTF16(clean.spec()));
}

SiteControlBoostItem BoostItemFor(const Boost& boost) {
  SiteControlBoostItem item;
  item.id = boost.id;
  item.name = base::UTF8ToUTF16(boost.name.empty() ? boost.host_pattern
                                                   : boost.name);
  item.enabled = boost.enabled;
  item.zap_count = static_cast<int>(boost.zapped_elements.size());
  item.has_code = !boost.custom_css.empty() || !boost.custom_js.empty();
  return item;
}

}  // namespace site_control_data

// --- OpenSiteControlView -----------------------------------------------------

namespace {

// A non-interactive painted view (notes, labels, the certificate page).
class PaintedLabel : public views::View {
 public:
  PaintedLabel(PaintedButton::Painter painter, const std::u16string& text)
      : painter_(std::move(painter)) {
    GetViewAccessibility().SetRole(ax::mojom::Role::kStaticText);
    GetViewAccessibility().SetName(text);
    SetCanProcessEventsWithinSubtree(false);
  }
  void OnPaint(gfx::Canvas* canvas) override {
    painter_.Run(canvas, GetLocalBounds(), false);
  }

 private:
  PaintedButton::Painter painter_;
};

void DrawLine(gfx::Canvas* canvas,
              std::u16string_view text,
              const gfx::FontList& font,
              SkColor color,
              int x,
              int baseline,
              int width,
              int align = gfx::Canvas::TEXT_ALIGN_LEFT) {
  if (width <= 0 || text.empty()) {
    return;
  }
  secondary::DrawText(
      canvas, text, font, color,
      gfx::Rect(x, baseline - font.GetBaseline(), width, font.GetHeight()),
      align);
}

}  // namespace

OpenSiteControlView::OpenSiteControlView(
    SiteControlDelegate* delegate,
    const SiteControlState& state,
    const secondary::Appearance& appearance)
    : delegate_(delegate), state_(state), appearance_(appearance) {
  GetViewAccessibility().SetRole(ax::mojom::Role::kGroup);
  GetViewAccessibility().SetName(u"Site Control Center");

  static constexpr std::array<const char16_t*, 4> kActionNames = {
      u"Share", u"New Boost", u"Capture a portion of this page",
      u"Capture the full page"};
  for (int i = 0; i < 4; ++i) {
    auto tile = std::make_unique<PaintedButton>(
        base::BindRepeating(&OpenSiteControlView::OnActionPressed,
                            base::Unretained(this), i),
        base::BindRepeating(&OpenSiteControlView::PaintActionTile,
                            base::Unretained(this), i),
        kActionNames[static_cast<size_t>(i)]);
#if BUILDFLAG(IS_MAC)
    static constexpr char16_t kCaptureKeys[] = u" \u21e7\u23182";
#else
    static constexpr char16_t kCaptureKeys[] = u" (Ctrl+Shift+2)";
#endif
    tile->SetTooltipText(
        i == 2 ? base::StrCat({kActionNames[2], kCaptureKeys})
               : std::u16string(kActionNames[static_cast<size_t>(i)]));
    action_tiles_.push_back(AddChildView(std::move(tile)));
  }

  auto scroll = std::make_unique<views::ScrollView>();
  scroll->SetBackgroundColor(std::nullopt);
  scroll->SetHorizontalScrollBarMode(
      views::ScrollView::ScrollBarMode::kDisabled);
  scroll->SetVerticalScrollBar(std::make_unique<views::OverlayScrollBar>(
      views::ScrollBar::Orientation::kVertical));
  scroll->SetDrawOverflowIndicator(false);
  scroll->GetViewAccessibility().SetName(u"Site settings and Boosts");
  body_ = scroll->SetContents(std::make_unique<views::View>());
  scroll_view_ = AddChildView(std::move(scroll));

  pill_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(&OpenSiteControlView::OnSecurityPressed,
                          base::Unretained(this)),
      base::BindRepeating(&OpenSiteControlView::PaintPill,
                          base::Unretained(this)),
      u"Connection"));
  more_ = AddChildView(std::make_unique<PaintedButton>(
      base::BindRepeating(&OpenSiteControlView::ShowMoreMenu,
                          base::Unretained(this)),
      base::BindRepeating(&OpenSiteControlView::PaintMore,
                          base::Unretained(this)),
      u"More"));
  more_->GetViewAccessibility().SetRole(ax::mojom::Role::kPopUpButton);
  more_->SetTooltipText(u"More");

  NormalizeState();
  Rebuild();
}

OpenSiteControlView::~OpenSiteControlView() = default;

SkColor OpenSiteControlView::panel_color() const {
  return state_.panel_color.value_or(appearance_.dark ? kPanelDark
                                                      : kPanelLight);
}

void OpenSiteControlView::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  RepaintAll();
}

void OpenSiteControlView::OnThemeChanged() {
  views::View::OnThemeChanged();
  RepaintAll();
}

void OpenSiteControlView::RepaintAll() {
  SchedulePaint();
  for (auto& tile : action_tiles_) {
    if (tile) {
      tile->SchedulePaint();
    }
  }
  if (pill_) {
    pill_->SchedulePaint();
  }
  if (more_) {
    more_->SchedulePaint();
  }
  if (scroll_view_) {
    scroll_view_->SchedulePaint();
  }
  if (body_) {
    body_->SchedulePaint();
    for (views::View* child : body_->children()) {
      child->SchedulePaint();
    }
  }
}

content::WebContents* OpenSiteControlView::web_contents() const {
  return tab_.get();
}

void OpenSiteControlView::SetCallbacks(const SiteControlCallbacks& callbacks) {
  callbacks_ = callbacks;
  Rebuild();
}

void OpenSiteControlView::SetWebContents(content::WebContents* tab) {
  content::WebContents* old = tab_.get();
  tab_ = tab ? tab->GetWeakPtr() : base::WeakPtr<content::WebContents>();
  if (old != tab) {
    sticky_tiles_.clear();
    showing_certificate_ = false;
  }
  NormalizeState();
  Rebuild();
}

void OpenSiteControlView::SetState(const SiteControlState& state) {
  // A legacy state has no URL: compare hosts then.
  const bool same_site =
      state.host == state_.host &&
      (state.url.is_empty() || state_.url.is_empty() ||
       url::Origin::Create(state.url).IsSameOriginWith(
           url::Origin::Create(state_.url)));
  const bool banner = state_.show_reload_banner;
  state_ = state;
  if (same_site) {
    state_.show_reload_banner = state.show_reload_banner || banner;
  } else {
    sticky_tiles_.clear();
    showing_certificate_ = false;
  }
  NormalizeState();
  Rebuild();
}

void OpenSiteControlView::NormalizeState() {
  content::WebContents* tab = tab_.get();
  if (tab && state_.url.is_empty()) {
    // The coordinator's legacy state has no URL; read the identity fields.
    SiteControlState from_tab;
    site_control_data::FillStateFromTab(tab, &from_tab);
    state_.url = from_tab.url;
    state_.is_website = from_tab.is_website;
    state_.incognito = from_tab.incognito;
    state_.capture_available = from_tab.capture_available;
    if (state_.host.empty()) {
      state_.host = from_tab.host;
    }
  }
  if (!state_.tiles.empty()) {
    all_tiles_ = state_.tiles;
  } else if (tab) {
    all_tiles_ = site_control_data::BuildSiteSettingTiles(tab);
  } else {
    // Legacy: the ad-block fields and the fixed permission rows.
    all_tiles_.clear();
    if (state_.is_website) {
      all_tiles_.push_back(AdBlockTileFromFields(state_));
    }
    for (const SitePermissionRow& row : state_.permissions) {
      SiteSettingTile tile;
      tile.type = site_control_data::TypeForLegacyKind(row.kind);
      const TypeSpec& spec = SpecFor(tile.type);
      tile.id = spec.id;
      tile.kind = spec.permission ? SiteSettingTileKind::kPermission
                                  : SiteSettingTileKind::kContent;
      tile.title = spec.title;
      tile.setting = row.setting;
      tile.state = row.setting == SitePermissionSetting::kAllow
                       ? SiteSettingTileState::kOn
                       : SiteSettingTileState::kOff;
      tile.subtitle = SubtitleFor(row.setting);
      tile.in_use = row.in_use;
      tile.changed = row.setting != SitePermissionSetting::kAsk;
      all_tiles_.push_back(std::move(tile));
    }
  }
}

std::vector<const SiteSettingTile*> OpenSiteControlView::VisibleTiles() const {
  std::vector<const SiteSettingTile*> visible;
  for (const SiteSettingTile& tile : all_tiles_) {
    const bool shown =
        tile.kind == SiteSettingTileKind::kContentBlocking || tile.changed ||
        tile.in_use || sticky_tiles_.contains(tile.id) ||
        (show_all_settings_ && tile.state != SiteSettingTileState::kUnavailable);
    if (shown) {
      visible.push_back(&tile);
    }
  }
  return visible;
}

void OpenSiteControlView::SetAdBlockState(bool enabled, int blocked_count) {
  if (state_.ad_block_enabled == enabled &&
      state_.ad_block_blocked_count == blocked_count) {
    return;
  }
  state_.ad_block_enabled = enabled;
  state_.ad_block_blocked_count = blocked_count;
  for (size_t i = 0; i < tile_row_indices_.size(); ++i) {
    SiteSettingTile& tile = all_tiles_[tile_row_indices_[i]];
    if (tile.kind != SiteSettingTileKind::kContentBlocking) {
      continue;
    }
    if (tab_) {
      tile = site_control_data::BuildAdBlockTile(tab_.get());
    } else {
      tile = AdBlockTileFromFields(state_);
    }
    tile_rows_[i]->GetViewAccessibility().SetDescription(tile.subtitle);
    tile_rows_[i]->SchedulePaint();
  }
}

void OpenSiteControlView::RefreshInUse() {
  if (!tab_) {
    return;
  }
  bool visibility_changed = false;
  const std::vector<const SiteSettingTile*> before = VisibleTiles();
  for (SiteSettingTile& tile : all_tiles_) {
    if (tile.kind == SiteSettingTileKind::kContentBlocking) {
      continue;
    }
    tile.in_use = InUse(tab_.get(), tile.type);
  }
  visibility_changed = before.size() != VisibleTiles().size() ||
                       showing_audio_row_ != ShouldShowAudioRow();
  if (visibility_changed) {
    Rebuild();
    return;
  }
  for (auto& row : tile_rows_) {
    row->SchedulePaint();
  }
  if (audio_mute_row_) {
    const bool muted = tab_->IsAudioMuted();
    audio_mute_row_->GetViewAccessibility().SetName(
        muted ? u"Unmute Tab" : u"Mute Tab");
    audio_mute_row_->GetViewAccessibility().SetCheckedState(
        muted ? ax::mojom::CheckedState::kFalse
              : ax::mojom::CheckedState::kTrue);
    audio_mute_row_->GetViewAccessibility().SetDescription(
        muted ? u"Muted" : u"Playing");
    audio_mute_row_->SetTooltipText(
        muted ? u"Unmute audio on this tab" : u"Mute audio on this tab");
    audio_mute_row_->SchedulePaint();
  }
  UpdateZoomControls();
}

void OpenSiteControlView::RefreshZoom() {
  UpdateZoomControls();
}

void OpenSiteControlView::RefreshFromTab() {
  if (!tab_) {
    return;
  }
  if (state_.tiles.empty()) {
    all_tiles_ = site_control_data::BuildSiteSettingTiles(tab_.get());
  }
  state_.certificate.reset();
  Rebuild();
}

void OpenSiteControlView::SetReloadBannerVisible(bool visible) {
  if (state_.show_reload_banner == visible) {
    return;
  }
  state_.show_reload_banner = visible;
  Rebuild();
}

views::View* OpenSiteControlView::GetExtensionAnchor(
    const std::string& extension_id) {
  for (size_t i = 0;
       i < state_.extensions.size() && i < extension_tiles_.size(); ++i) {
    if (state_.extensions[i].id == extension_id) {
      return extension_tiles_[i];
    }
  }
  return nullptr;
}

views::View* OpenSiteControlView::AddBodyChild(
    std::unique_ptr<views::View> view) {
  return body_->AddChildView(std::move(view));
}

void OpenSiteControlView::Rebuild() {
  // Quick actions (AppSiteControlSource commandsEnabled).
  const bool website = state_.is_website;
  action_tiles_[0]->SetEnabled(true);
  action_tiles_[1]->SetEnabled(website && !state_.incognito &&
                               state_.can_create_boost &&
                               state_.boosts_globally_enabled);
  action_tiles_[2]->SetEnabled(website && state_.capture_available);
  action_tiles_[3]->SetEnabled(website && state_.capture_available);
  const bool edit_boost = state_.boost_active && !state_.boosts.empty();
  action_tiles_[1]->GetViewAccessibility().SetName(edit_boost ? u"Edit Boost"
                                                              : u"New Boost");
  action_tiles_[1]->SetTooltipText(edit_boost ? u"Edit Boost" : u"New Boost");

  // Footer.
  const bool http = state_.url.SchemeIsHTTPOrHTTPS() || state_.url.is_empty();
  pill_->SetVisible(http);
  const bool secure = state_.secure;
  const bool has_certificate =
      secure && (state_.certificate.has_value() ||
                 (tab_ && state_.url.SchemeIs(url::kHttpsScheme)));
  pill_->SetEnabled(has_certificate);
  pill_->GetViewAccessibility().SetName(
      base::StrCat({u"Connection: ", secure ? u"Secure" : u"Insecure"}));
  pill_->GetViewAccessibility().SetDescription(state_.host);
  pill_->SetTooltipText(has_certificate ? u"Show certificate details"
                                        : std::u16string());

  BuildBody();
  PreferredSizeChanged();
  InvalidateLayout();
  SchedulePaint();
}

void OpenSiteControlView::BuildBody() {
  extension_tiles_.clear();
  boost_rows_.clear();
  boost_circles_.clear();
  tile_rows_.clear();
  tile_row_indices_.clear();
  audio_mute_row_ = nullptr;
  zoom_out_button_ = nullptr;
  zoom_reset_button_ = nullptr;
  zoom_in_button_ = nullptr;
  showing_audio_row_ = false;
  body_->RemoveAllChildViews();
  if (showing_certificate_) {
    BuildCertificatePage();
    return;
  }

  int y = m::kGapAfterActions;
  auto header = [&](Section section, const std::u16string& name) {
    auto button = std::make_unique<PaintedButton>(
        base::BindRepeating(
            [](OpenSiteControlView* self, Section s) {
              // Deferred: pressing "More" rebuilds this header.
              base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
                  FROM_HERE,
                  base::BindOnce(&OpenSiteControlView::OnSectionPressed,
                                 self->weak_factory_.GetWeakPtr(), s));
            },
            base::Unretained(this), section),
        base::BindRepeating(&OpenSiteControlView::PaintSectionHeader,
                            base::Unretained(this), section),
        name);
    button->GetViewAccessibility().SetRole(ax::mojom::Role::kHeading);
    button->SetBoundsRect(gfx::Rect(
        0, y - m::kLabelBaselineAboveContent - m::kLabelBaselineInRow,
        m::kWidth, m::kLabelRowHeight));
    AddBodyChild(std::move(button));
  };

  // Extensions.
  header(Section::kExtensions, u"Extensions, Manage");
  if (!state_.extensions.empty()) {
    for (size_t i = 0; i < state_.extensions.size(); ++i) {
      const SiteControlExtensionItem& item = state_.extensions[i];
      auto tile = std::make_unique<PaintedButton>(
          base::BindRepeating(&OpenSiteControlView::OnExtensionPressed,
                              base::Unretained(this), i),
          base::BindRepeating(&OpenSiteControlView::PaintExtensionTile,
                              base::Unretained(this), i),
          item.name);
      tile->SetTooltipText(item.tooltip.empty() ? item.name : item.tooltip);
      tile->SetEnabled(item.enabled);
      tile->set_context_menu_controller(this);
      const int col = static_cast<int>(i % m::kExtensionColumns);
      const int row = static_cast<int>(i / m::kExtensionColumns);
      tile->SetBoundsRect(gfx::Rect(
          m::kPadding + col * (m::kActionWidth + m::kActionGap),
          y + row * m::kExtensionRowPitch, m::kActionWidth,
          m::kActionHeight));
      extension_tiles_.push_back(
          static_cast<PaintedButton*>(AddBodyChild(std::move(tile))));
    }
    const int rows = static_cast<int>(
        (state_.extensions.size() + m::kExtensionColumns - 1) /
        m::kExtensionColumns);
    y += (rows - 1) * m::kExtensionRowPitch + m::kActionHeight;
  } else if (state_.incognito) {
    static constexpr char16_t kNote[] = u"Extensions are off in Incognito.";
    auto note = std::make_unique<PaintedLabel>(
        base::BindRepeating(&OpenSiteControlView::PaintNote,
                            base::Unretained(this), std::u16string(kNote)),
        kNote);
    note->SetBoundsRect(gfx::Rect(m::kPadding, y, m::kWidth - 2 * m::kPadding,
                                  m::kGlobalOffHeight));
    AddBodyChild(std::move(note));
    y += m::kGlobalOffHeight;
  } else {
    auto add = std::make_unique<PaintedButton>(
        base::BindRepeating(
            [](OpenSiteControlView* self) {
              if (self->callbacks_.on_add_extension) {
                self->callbacks_.on_add_extension.Run();
              }
            },
            base::Unretained(this)),
        base::BindRepeating(&OpenSiteControlView::PaintAddExtensionTile,
                            base::Unretained(this)),
        u"Add Extension");
    add->SetTooltipText(u"Add Extension");
    add->SetEnabled(!callbacks_.on_add_extension.is_null());
    add->SetBoundsRect(
        gfx::Rect(m::kPadding, y, m::kActionWidth, m::kActionHeight));
    AddBodyChild(std::move(add));
    y += m::kActionHeight;
  }

  // Boosts (only for a website with matching Boosts).
  if (state_.is_website && !state_.boosts.empty()) {
    y += m::kSectionGap;
    header(Section::kBoosts, u"Boosts, Manage");
    if (!state_.boosts_globally_enabled) {
      static constexpr char16_t kNote[] =
          u"Boosts are off. Turn them on in Settings.";
      auto note = std::make_unique<PaintedLabel>(
          base::BindRepeating(&OpenSiteControlView::PaintNote,
                              base::Unretained(this), std::u16string(kNote)),
          kNote);
      note->SetBoundsRect(gfx::Rect(m::kPadding, y,
                                    m::kWidth - 2 * m::kPadding,
                                    m::kGlobalOffHeight));
      AddBodyChild(std::move(note));
      y += m::kGlobalOffHeight;
    }
    for (size_t i = 0; i < state_.boosts.size(); ++i) {
      if (i > 0) {
        y += m::kRowPitch - m::kRowIcon;
      }
      const SiteControlBoostItem& boost = state_.boosts[i];
      auto row = std::make_unique<PaintedButton>(
          base::BindRepeating(&OpenSiteControlView::OnBoostPressed,
                              base::Unretained(this), i),
          base::BindRepeating(&OpenSiteControlView::PaintBoostRow,
                              base::Unretained(this), i),
          base::StrCat({u"Edit ", boost.name}));
      row->SetEnabled(!state_.incognito);
      if (state_.incognito) {
        row->SetTooltipText(u"Boosts can't be edited in a private window.");
      }
      row->SetBoundsRect(gfx::Rect(0, y, m::kWidth, m::kRowIcon));
      boost_rows_.push_back(
          static_cast<PaintedButton*>(AddBodyChild(std::move(row))));
      auto circle = std::make_unique<PaintedButton>(
          base::BindRepeating(&OpenSiteControlView::OnBoostToggled,
                              base::Unretained(this), i),
          base::BindRepeating(&OpenSiteControlView::PaintBoostCircle,
                              base::Unretained(this), i),
          base::StrCat({u"Enable ", boost.name}));
      circle->GetViewAccessibility().SetRole(ax::mojom::Role::kCheckBox);
      circle->GetViewAccessibility().SetCheckedState(
          boost.enabled ? ax::mojom::CheckedState::kTrue
                        : ax::mojom::CheckedState::kFalse);
      circle->SetEnabled(state_.boosts_globally_enabled && !state_.incognito);
      circle->SetBoundsRect(
          gfx::Rect(m::kPadding, y, m::kRowIcon, m::kRowIcon));
      boost_circles_.push_back(
          static_cast<PaintedButton*>(AddBodyChild(std::move(circle))));
      y += m::kRowIcon;
    }
  }

  // Settings.
  if (state_.is_website) {
    y += m::kSectionGap;
    header(Section::kSettings,
           show_all_settings_ ? u"Settings, Less" : u"Settings, More");
    const std::vector<const SiteSettingTile*> visible = VisibleTiles();
    for (size_t i = 0; i < visible.size(); ++i) {
      if (i > 0) {
        y += m::kRowPitch - m::kRowIcon;
      }
      const SiteSettingTile& tile = *visible[i];
      size_t index = 0;
      while (index < all_tiles_.size() && &all_tiles_[index] != visible[i]) {
        ++index;
      }
      auto row = std::make_unique<PaintedButton>(
          base::BindRepeating(
              [](OpenSiteControlView* self, size_t tile_index) {
                // Deferred: the change rebuilds this row.
                base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
                    FROM_HERE,
                    base::BindOnce(&OpenSiteControlView::OnTilePressed,
                                   self->weak_factory_.GetWeakPtr(),
                                   tile_index));
              },
              base::Unretained(this), index),
          base::BindRepeating(&OpenSiteControlView::PaintTileRow,
                              base::Unretained(this), tile_rows_.size()),
          tile.title);
      row->GetViewAccessibility().SetRole(
          tile.state == SiteSettingTileState::kUnavailable
              ? ax::mojom::Role::kButton
              : ax::mojom::Role::kCheckBox);
      if (tile.state != SiteSettingTileState::kUnavailable) {
        row->GetViewAccessibility().SetCheckedState(
            tile.state == SiteSettingTileState::kOn
                ? ax::mojom::CheckedState::kTrue
                : ax::mojom::CheckedState::kFalse);
      }
      row->GetViewAccessibility().SetDescription(tile.subtitle);
      if (!tile.help.empty()) {
        row->SetTooltipText(tile.help);
      }
      row->SetEnabled(tile.enabled);
      if (tile.kind != SiteSettingTileKind::kContentBlocking) {
        row->set_context_menu_controller(this);
      }
      row->SetBoundsRect(gfx::Rect(0, y, m::kWidth, m::kRowIcon));
      tile_rows_.push_back(
          static_cast<PaintedButton*>(AddBodyChild(std::move(row))));
      tile_row_indices_.push_back(index);
      y += m::kRowIcon;
    }
    if (ShouldShowAudioRow()) {
      showing_audio_row_ = true;
      if (!visible.empty()) {
        y += m::kRowPitch - m::kRowIcon;
      }
      const bool muted = tab_->IsAudioMuted();
      auto audio_row = std::make_unique<PaintedButton>(
          base::BindRepeating(&OpenSiteControlView::OnAudioMuteToggled,
                              base::Unretained(this)),
          base::BindRepeating(&OpenSiteControlView::PaintAudioMuteRow,
                              base::Unretained(this)),
          muted ? u"Unmute Tab" : u"Mute Tab");
      audio_row->GetViewAccessibility().SetRole(ax::mojom::Role::kCheckBox);
      audio_row->GetViewAccessibility().SetCheckedState(
          muted ? ax::mojom::CheckedState::kFalse
                : ax::mojom::CheckedState::kTrue);
      audio_row->GetViewAccessibility().SetDescription(
          muted ? u"Muted" : u"Playing");
      audio_row->SetTooltipText(
          muted ? u"Unmute audio on this tab" : u"Mute audio on this tab");
      audio_row->SetBoundsRect(gfx::Rect(0, y, m::kWidth, m::kRowIcon));
      audio_mute_row_ =
          static_cast<PaintedButton*>(AddBodyChild(std::move(audio_row)));
      y += m::kRowIcon;
    }
    if (tab_) {
      if (!visible.empty() || showing_audio_row_) {
        y += m::kRowPitch - m::kRowIcon;
      }
      auto zoom_label = std::make_unique<PaintedLabel>(
          base::BindRepeating(&OpenSiteControlView::PaintZoomLabel,
                              base::Unretained(this)),
          u"Zoom");
      zoom_label->SetBoundsRect(gfx::Rect(m::kPadding, y, 86, m::kRowIcon));
      AddBodyChild(std::move(zoom_label));

      constexpr int kZoomStepW = 26;
      constexpr int kZoomResetW = 48;
      constexpr int kZoomBtnH = 26;
      constexpr int kZoomGap = 4;
      const int btn_y = y + (m::kRowIcon - kZoomBtnH) / 2;
      const int in_x = m::kWidth - m::kPadding - kZoomStepW;
      const int reset_x = in_x - kZoomGap - kZoomResetW;
      const int out_x = reset_x - kZoomGap - kZoomStepW;

      auto zoom_out = std::make_unique<PaintedButton>(
          base::BindRepeating(&OpenSiteControlView::OnZoomOut,
                              base::Unretained(this)),
          base::BindRepeating(&OpenSiteControlView::PaintZoomStepButton,
                              base::Unretained(this), /*zoom_in=*/false),
          u"Zoom Out");
      zoom_out->SetTooltipText(u"Zoom Out");
      zoom_out->SetBoundsRect(gfx::Rect(out_x, btn_y, kZoomStepW, kZoomBtnH));
      zoom_out_button_ =
          static_cast<PaintedButton*>(AddBodyChild(std::move(zoom_out)));

      auto zoom_reset = std::make_unique<PaintedButton>(
          base::BindRepeating(&OpenSiteControlView::OnZoomReset,
                              base::Unretained(this)),
          base::BindRepeating(&OpenSiteControlView::PaintZoomResetButton,
                              base::Unretained(this)),
          u"Reset Zoom");
      zoom_reset->SetTooltipText(u"Reset zoom to 100%");
      zoom_reset->SetBoundsRect(
          gfx::Rect(reset_x, btn_y, kZoomResetW, kZoomBtnH));
      zoom_reset_button_ =
          static_cast<PaintedButton*>(AddBodyChild(std::move(zoom_reset)));

      auto zoom_in = std::make_unique<PaintedButton>(
          base::BindRepeating(&OpenSiteControlView::OnZoomIn,
                              base::Unretained(this)),
          base::BindRepeating(&OpenSiteControlView::PaintZoomStepButton,
                              base::Unretained(this), /*zoom_in=*/true),
          u"Zoom In");
      zoom_in->SetTooltipText(u"Zoom In");
      zoom_in->SetBoundsRect(gfx::Rect(in_x, btn_y, kZoomStepW, kZoomBtnH));
      zoom_in_button_ =
          static_cast<PaintedButton*>(AddBodyChild(std::move(zoom_in)));

      UpdateZoomControls();
      y += m::kRowIcon;
    }
    if (state_.show_reload_banner) {
      y += m::kReloadGap;
      auto label = std::make_unique<PaintedLabel>(
          base::BindRepeating(&OpenSiteControlView::PaintReloadLabel,
                              base::Unretained(this)),
          u"Reload to apply changes.");
      label->SetBoundsRect(gfx::Rect(m::kPadding, y, 162, m::kReloadRowHeight));
      AddBodyChild(std::move(label));
      auto reload = std::make_unique<PaintedButton>(
          base::BindRepeating(
              [](OpenSiteControlView* self) {
                base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
                    FROM_HERE,
                    base::BindOnce(&OpenSiteControlView::OnReloadPressed,
                                   self->weak_factory_.GetWeakPtr()));
              },
              base::Unretained(this)),
          base::BindRepeating(&OpenSiteControlView::PaintReloadButton,
                              base::Unretained(this)),
          u"Reload");
      reload->SetBoundsRect(gfx::Rect(
          m::kWidth - m::kPadding - m::kReloadButtonWidth, y,
          m::kReloadButtonWidth, m::kReloadRowHeight));
      AddBodyChild(std::move(reload));
      y += m::kReloadRowHeight;
    }
  }

  body_height_ = y + m::kGapBeforeSeparator;
  body_->SetPreferredSize(gfx::Size(m::kWidth, body_height_));
  body_->SetSize(gfx::Size(m::kWidth, body_height_));
}

void OpenSiteControlView::BuildCertificatePage() {
  if (!state_.certificate && tab_) {
    state_.certificate =
        site_control_data::CertificateSummaryForTab(tab_.get());
  }
  int y = m::kPadding;
  auto back = std::make_unique<PaintedButton>(
      base::BindRepeating(
          [](OpenSiteControlView* self) {
            base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
                FROM_HERE, base::BindOnce(
                               [](base::WeakPtr<OpenSiteControlView> view) {
                                 if (view) {
                                   view->showing_certificate_ = false;
                                   view->Rebuild();
                                 }
                               },
                               self->weak_factory_.GetWeakPtr()));
          },
          base::Unretained(this)),
      base::BindRepeating(&OpenSiteControlView::PaintTextButton,
                          base::Unretained(this), std::u16string(u"‹ Back")),
      u"Back to Site Controls");
  back->SetBoundsRect(
      gfx::Rect(m::kPadding, y, m::kWidth - 2 * m::kPadding, 24));
  AddBodyChild(std::move(back));
  y += 24 + 8;

  // Field rows: label line 16 + value line 18 + gap 8.
  int lines = 0;
  if (state_.certificate) {
    const SiteCertificateSummary& c = *state_.certificate;
    lines = 5 + (c.organization.empty() ? 0 : 1) +
            static_cast<int>(std::min<size_t>(c.subject_alt_names.size(), 6)) +
            (c.subject_alt_names.size() > 6 ? 1 : 0) + 3;
  } else {
    lines = 2;
  }
  const int page_height = 16 + lines * 20 + 8;
  auto page = std::make_unique<PaintedLabel>(
      base::BindRepeating(&OpenSiteControlView::PaintCertificatePage,
                          base::Unretained(this)),
      base::StrCat({u"Certificate for ", state_.host}));
  page->SetBoundsRect(gfx::Rect(m::kPadding, y, m::kWidth - 2 * m::kPadding,
                                page_height));
  AddBodyChild(std::move(page));
  y += page_height;

  if (state_.certificate &&
      (tab_ || !callbacks_.on_show_certificate.is_null())) {
    auto show = std::make_unique<PaintedButton>(
        base::BindRepeating(
            [](OpenSiteControlView* self) {
              if (self->callbacks_.on_show_certificate) {
                self->callbacks_.on_show_certificate.Run();
              } else {
                site_control_data::ShowCertificateViewerForTab(
                    self->tab_.get());
              }
            },
            base::Unretained(this)),
        base::BindRepeating(&OpenSiteControlView::PaintTextButton,
                            base::Unretained(this),
                            std::u16string(u"Show Certificate…")),
        u"Show Certificate");
    show->SetBoundsRect(
        gfx::Rect(m::kPadding, y, m::kWidth - 2 * m::kPadding, 28));
    AddBodyChild(std::move(show));
    y += 28;
  }
  body_height_ = y + m::kGapBeforeSeparator;
  body_->SetPreferredSize(gfx::Size(m::kWidth, body_height_));
  body_->SetSize(gfx::Size(m::kWidth, body_height_));
}

int OpenSiteControlView::FixedHeight() const {
  return kFixedHeight;
}

int OpenSiteControlView::BodyHeight() const {
  return std::min(body_height_, m::kMaxHeight - kFixedHeight);
}

gfx::Size OpenSiteControlView::CalculatePreferredSize(
    const views::SizeBounds& available_size) const {
  // height = min(content, maxHeight); the bubble also clamps to window room.
  return gfx::Size(m::kWidth, FixedHeight() + BodyHeight());
}

void OpenSiteControlView::Layout(PassKey) {
  for (int i = 0; i < 4; ++i) {
    action_tiles_[static_cast<size_t>(i)]->SetBoundsRect(
        gfx::Rect(m::kPadding + i * (m::kActionWidth + m::kActionGap),
                  m::kPadding, m::kActionWidth, m::kActionHeight));
  }
  const int scroll_top = m::kPadding + m::kActionHeight;
  const int scroll_height = std::max(0, height() - kFixedHeight);
  scroll_view_->SetBoundsRect(
      gfx::Rect(0, scroll_top, m::kWidth, scroll_height));
  const int footer_y = height() - m::kPadding - m::kFooterHeight;
  separator_y_ = footer_y - m::kGapAfterSeparator - 1;

  const std::u16string pill_text = state_.secure ? u"Secure" : u"Insecure";
  const int pill_width =
      2 * m::kPillPadding + m::kPillLockGlyph + m::kPillLockGap +
      secondary::TextWidth(pill_text, secondary::FontOfSize(
                                          kPillFontSize,
                                          gfx::Font::Weight::MEDIUM));
  pill_->SetBoundsRect(
      gfx::Rect(m::kPadding, footer_y, pill_width, m::kFooterHeight));
  more_->SetBoundsRect(gfx::Rect(m::kWidth - m::kPadding - m::kMoreButton,
                                 footer_y, m::kMoreButton, m::kMoreButton));
}

void OpenSiteControlView::OnPaint(gfx::Canvas* canvas) {
  canvas->DrawColor(panel_color());
  // A 1 pt line inset by the padding (SiteControlPanelView.layout).
  canvas->FillRect(
      gfx::Rect(m::kPadding, separator_y_, m::kWidth - 2 * m::kPadding, 1),
      Color(secondary::WithAlpha(SK_ColorBLACK, 0.10f), kSeparatorDark));
}

bool OpenSiteControlView::OnMouseWheel(const ui::MouseWheelEvent& event) {
  // The body's ScrollView handles wheel events; the fixed chrome does not
  // scroll.
  return false;
}

// --- Actions -------------------------------------------------------------------

void OpenSiteControlView::OnActionPressed(int index) {
  base::WeakPtr<OpenSiteControlView> self = weak_factory_.GetWeakPtr();
  const gfx::Rect anchor =
      action_tiles_[static_cast<size_t>(index)]->GetBoundsInScreen();
  bool handled = false;
  switch (index) {
    case 0:
      if (callbacks_.on_share) {
        callbacks_.on_share.Run(anchor);
        handled = true;
      } else if (delegate_) {
        delegate_->OnSiteControlAction(SiteControlAction::kCopyUrl);
        return;
      }
      break;
    case 1:
      if (callbacks_.on_open_boost_editor) {
        std::optional<std::string> boost_id;
        if (state_.boost_active) {
          for (const SiteControlBoostItem& boost : state_.boosts) {
            if (boost.enabled) {
              boost_id = boost.id;
              break;
            }
          }
        }
        callbacks_.on_open_boost_editor.Run(boost_id);
        handled = true;
      } else if (delegate_) {
        delegate_->OnSiteControlAction(SiteControlAction::kNewBoost);
        return;
      }
      break;
    case 2:
    case 3: {
      const base::RepeatingClosure& callback =
          index == 2 ? callbacks_.on_capture_region
                     : callbacks_.on_capture_full_page;
      if (callback) {
        callback.Run();
        handled = true;
      } else if (delegate_) {
        delegate_->OnSiteControlAction(SiteControlAction::kCapture);
        return;
      }
      break;
    }
  }
  if (handled && self && self->GetWidget()) {
    self->GetWidget()->Close();  // SiteControlDismissReason.action
  }
}

void OpenSiteControlView::OnSectionPressed(Section section) {
  switch (section) {
    case Section::kExtensions:
      if (callbacks_.on_manage_extensions) {
        callbacks_.on_manage_extensions.Run();
      }
      return;
    case Section::kBoosts:
      if (callbacks_.on_manage_boosts) {
        callbacks_.on_manage_boosts.Run();
      }
      return;
    case Section::kSettings:
      show_all_settings_ = !show_all_settings_;
      Rebuild();
      return;
  }
}

void OpenSiteControlView::OnTilePressed(size_t index) {
  if (index >= all_tiles_.size() || !all_tiles_[index].enabled) {
    return;
  }
  SiteSettingTile& tile = all_tiles_[index];
  if (tile.kind == SiteSettingTileKind::kContentBlocking) {
    if (tile.state == SiteSettingTileState::kUnavailable) {
      if (callbacks_.on_open_ad_block_settings) {
        callbacks_.on_open_ad_block_settings.Run();
      } else if (callbacks_.on_open_site_settings) {
        callbacks_.on_open_site_settings.Run();
      } else if (delegate_) {
        delegate_->OnSiteControlAction(SiteControlAction::kSiteSettings);
      }
      return;
    }
    const bool enabled = tile.state != SiteSettingTileState::kOn;
    state_.ad_block_enabled = enabled;
    state_.ad_block_excluded = !enabled;
    tile = AdBlockTileFromFields(state_);
    base::WeakPtr<OpenSiteControlView> self = weak_factory_.GetWeakPtr();
    if (callbacks_.on_ad_block_toggled) {
      // Swift parity: the change applies on the next load ("Reload").
      state_.show_reload_banner = true;
      callbacks_.on_ad_block_toggled.Run(enabled);
    } else if (delegate_) {
      // The legacy coordinator reloads the page itself.
      delegate_->OnSiteControlAdBlockToggled(enabled);
    }
    if (self) {
      Rebuild();
    }
    return;
  }
  // Swift parity: a click flips Allowed / Blocked. Kinds that refuse
  // "Allow" (the device guards) go back to their default.
  SitePermissionSetting next = tile.setting == SitePermissionSetting::kAllow
                                   ? SitePermissionSetting::kBlock
                                   : SitePermissionSetting::kAllow;
  if (next == SitePermissionSetting::kAllow) {
    const content_settings::ContentSettingsInfo* info =
        InfoFor(SpecFor(tile.type).content_type);
    if (info && !info->IsSettingValid(CONTENT_SETTING_ALLOW)) {
      next = tile.setting == SitePermissionSetting::kBlock
                 ? SitePermissionSetting::kAsk
                 : SitePermissionSetting::kBlock;
    }
  }
  OnTileSettingChosen(index, next);
}

void OpenSiteControlView::OnTileSettingChosen(size_t index,
                                              SitePermissionSetting setting) {
  if (index >= all_tiles_.size()) {
    return;
  }
  const SiteSettingType type = all_tiles_[index].type;
  const std::string id = all_tiles_[index].id;
  sticky_tiles_.insert(id);
  base::WeakPtr<OpenSiteControlView> self = weak_factory_.GetWeakPtr();
  if (callbacks_.on_site_setting_changed) {
    callbacks_.on_site_setting_changed.Run(type, setting);
  } else if (tab_) {
    site_control_data::ApplySiteSetting(tab_.get(), type, setting);
  } else if (std::optional<SitePermissionKind> legacy =
                 site_control_data::LegacyKindFor(type);
             legacy && delegate_) {
    // The legacy coordinator writes the setting and calls UpdateState().
    delegate_->OnSiteControlPermissionChanged(*legacy, setting);
  }
  if (!self) {
    return;
  }
  // Re-read the tile (the write may have been refused or normalized).
  for (SiteSettingTile& tile : all_tiles_) {
    if (tile.id != id) {
      continue;
    }
    if (tab_) {
      tile.setting = site_control_data::GetSiteSetting(tab_.get(), type);
    } else {
      tile.setting = setting;
    }
    tile.state = tile.setting == SitePermissionSetting::kAllow
                     ? SiteSettingTileState::kOn
                     : SiteSettingTileState::kOff;
    tile.subtitle = SubtitleFor(tile.setting);
  }
  state_.show_reload_banner = true;
  Rebuild();
}

void OpenSiteControlView::OnExtensionPressed(size_t index) {
  if (index >= state_.extensions.size() || index >= extension_tiles_.size()) {
    return;
  }
  const std::string id = state_.extensions[index].id;
  views::View* anchor = extension_tiles_[index];
  if (callbacks_.on_run_extension_action) {
    callbacks_.on_run_extension_action.Run(id, anchor);
  } else if (delegate_) {
    delegate_->OnSiteControlExtensionPressed(id, anchor);
  }
}

void OpenSiteControlView::OnBoostToggled(size_t index) {
  if (index >= state_.boosts.size()) {
    return;
  }
  const std::string id = state_.boosts[index].id;
  const bool enabled = !state_.boosts[index].enabled;
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<OpenSiteControlView> view, std::string boost_id,
             bool on) {
            if (!view) {
              return;
            }
            for (SiteControlBoostItem& boost : view->state_.boosts) {
              if (boost.id == boost_id) {
                boost.enabled = on;
              }
            }
            view->state_.boost_active = std::any_of(
                view->state_.boosts.begin(), view->state_.boosts.end(),
                [](const SiteControlBoostItem& b) { return b.enabled; });
            if (view->callbacks_.on_boost_enabled_changed) {
              view->callbacks_.on_boost_enabled_changed.Run(boost_id, on);
            }
            if (view) {
              view->Rebuild();
            }
          },
          weak_factory_.GetWeakPtr(), id, enabled));
}

void OpenSiteControlView::OnBoostPressed(size_t index) {
  if (index >= state_.boosts.size()) {
    return;
  }
  base::WeakPtr<OpenSiteControlView> self = weak_factory_.GetWeakPtr();
  if (callbacks_.on_open_boost_editor) {
    callbacks_.on_open_boost_editor.Run(state_.boosts[index].id);
    if (self && self->GetWidget()) {
      self->GetWidget()->Close();
    }
  } else if (delegate_) {
    delegate_->OnSiteControlAction(SiteControlAction::kNewBoost);
  }
}

void OpenSiteControlView::OnReloadPressed() {
  state_.show_reload_banner = false;
  base::WeakPtr<OpenSiteControlView> self = weak_factory_.GetWeakPtr();
  if (callbacks_.on_reload_page) {
    callbacks_.on_reload_page.Run();
  } else if (tab_) {
    tab_->GetController().Reload(content::ReloadType::NORMAL,
                                 /*check_for_repost=*/true);
  }
  if (self) {
    Rebuild();
  }
}

void OpenSiteControlView::OnSecurityPressed() {
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenSiteControlView> view) {
                       if (!view) {
                         return;
                       }
                       view->showing_certificate_ = !view->showing_certificate_;
                       view->Rebuild();
                     },
                     weak_factory_.GetWeakPtr()));
}

bool OpenSiteControlView::ShouldShowAudioRow() const {
  return tab_ && (tab_->IsCurrentlyAudible() || tab_->IsAudioMuted());
}

void OpenSiteControlView::OnAudioMuteToggled() {
  if (!tab_) {
    return;
  }
  const bool next_muted = !tab_->IsAudioMuted();
  tab_->SetAudioMuted(next_muted);
  if (audio_mute_row_) {
    audio_mute_row_->GetViewAccessibility().SetName(
        next_muted ? u"Unmute Tab" : u"Mute Tab");
    audio_mute_row_->GetViewAccessibility().SetCheckedState(
        next_muted ? ax::mojom::CheckedState::kFalse
                   : ax::mojom::CheckedState::kTrue);
    audio_mute_row_->GetViewAccessibility().SetDescription(
        next_muted ? u"Muted" : u"Playing");
    audio_mute_row_->SetTooltipText(
        next_muted ? u"Unmute audio on this tab" : u"Mute audio on this tab");
    audio_mute_row_->SchedulePaint();
  }
  if (!ShouldShowAudioRow()) {
    base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
        FROM_HERE, base::BindOnce(&OpenSiteControlView::Rebuild,
                                  weak_factory_.GetWeakPtr()));
  }
}

int OpenSiteControlView::CurrentZoomPercent() const {
  if (!tab_ || !tab_->GetPrimaryMainFrame()) {
    return 100;
  }
  const double level = content::HostZoomMap::GetZoomLevel(tab_.get());
  const double factor = blink::ZoomLevelToZoomFactor(level);
  return static_cast<int>(std::lround(factor * 100.0));
}

bool OpenSiteControlView::CanZoomIn() const {
  if (!tab_ || !tab_->GetPrimaryMainFrame()) {
    return false;
  }
  const double factor = blink::ZoomLevelToZoomFactor(
      content::HostZoomMap::GetZoomLevel(tab_.get()));
  const double max_factor = blink::kPresetBrowserZoomFactors.back();
  return factor < max_factor && !blink::ZoomValuesEqual(factor, max_factor);
}

bool OpenSiteControlView::CanZoomOut() const {
  if (!tab_ || !tab_->GetPrimaryMainFrame()) {
    return false;
  }
  const double factor = blink::ZoomLevelToZoomFactor(
      content::HostZoomMap::GetZoomLevel(tab_.get()));
  const double min_factor = blink::kPresetBrowserZoomFactors.front();
  return factor > min_factor && !blink::ZoomValuesEqual(factor, min_factor);
}

void OpenSiteControlView::OnZoomIn() {
  if (!tab_ || !tab_->GetPrimaryMainFrame()) {
    return;
  }
  const double factor = blink::ZoomLevelToZoomFactor(
      content::HostZoomMap::GetZoomLevel(tab_.get()));
  for (double preset : blink::kPresetBrowserZoomFactors) {
    if (preset > factor && !blink::ZoomValuesEqual(preset, factor)) {
      content::HostZoomMap::SetZoomLevel(tab_.get(),
                                         blink::ZoomFactorToZoomLevel(preset));
      UpdateZoomControls();
      return;
    }
  }
}

void OpenSiteControlView::OnZoomOut() {
  if (!tab_ || !tab_->GetPrimaryMainFrame()) {
    return;
  }
  const double factor = blink::ZoomLevelToZoomFactor(
      content::HostZoomMap::GetZoomLevel(tab_.get()));
  for (auto it = blink::kPresetBrowserZoomFactors.rbegin();
       it != blink::kPresetBrowserZoomFactors.rend(); ++it) {
    if (*it < factor && !blink::ZoomValuesEqual(*it, factor)) {
      content::HostZoomMap::SetZoomLevel(tab_.get(),
                                         blink::ZoomFactorToZoomLevel(*it));
      UpdateZoomControls();
      return;
    }
  }
}

void OpenSiteControlView::OnZoomReset() {
  if (!tab_ || !tab_->GetPrimaryMainFrame()) {
    return;
  }
  content::HostZoomMap* map =
      content::HostZoomMap::GetForWebContents(tab_.get());
  const double default_level = map ? map->GetDefaultZoomLevel() : 0.0;
  content::HostZoomMap::SetZoomLevel(tab_.get(), default_level);
  UpdateZoomControls();
}

void OpenSiteControlView::UpdateZoomControls() {
  if (!zoom_out_button_ && !zoom_reset_button_ && !zoom_in_button_) {
    return;
  }
  const int percent = CurrentZoomPercent();
  if (zoom_out_button_) {
    zoom_out_button_->SetEnabled(CanZoomOut());
    zoom_out_button_->SchedulePaint();
  }
  if (zoom_reset_button_) {
    const std::u16string pct =
        base::StrCat({base::NumberToString16(percent), u"%"});
    zoom_reset_button_->GetViewAccessibility().SetName(
        base::StrCat({u"Zoom ", pct, u", click to reset"}));
    zoom_reset_button_->SchedulePaint();
  }
  if (zoom_in_button_) {
    zoom_in_button_->SetEnabled(CanZoomIn());
    zoom_in_button_->SchedulePaint();
  }
}

void OpenSiteControlView::ClearSiteData(SiteDataKind kind) {
  base::WeakPtr<OpenSiteControlView> self = weak_factory_.GetWeakPtr();
  const base::RepeatingClosure& callback =
      kind == SiteDataKind::kCache ? callbacks_.on_clear_cache_and_reload
                                   : callbacks_.on_clear_cookies_and_reload;
  if (callback) {
    callback.Run();
  } else if (tab_) {
    site_control_data::ClearSiteDataAndReload(tab_.get(), kind);
  } else if (delegate_) {
    delegate_->OnSiteControlAction(SiteControlAction::kClearSiteData);
    return;
  }
  if (self && self->GetWidget()) {
    self->GetWidget()->Close();
  }
}

void OpenSiteControlView::NotifyChanged() {
  SchedulePaint();
}

// --- Menus ---------------------------------------------------------------------

void OpenSiteControlView::RunMenu(std::unique_ptr<ui::SimpleMenuModel> model,
                                  const gfx::Rect& anchor_in_screen,
                                  ui::mojom::MenuSourceType source_type) {
  if (menu_runner_ && menu_runner_->IsRunning()) {
    return;
  }
  menu_model_ = std::move(model);
  menu_runner_ = std::make_unique<views::MenuRunner>(
      menu_model_.get(), views::MenuRunner::CONTEXT_MENU);
  menu_runner_->RunMenuAt(GetWidget(), nullptr, anchor_in_screen,
                          views::MenuAnchorPosition::kTopLeft, source_type);
}

void OpenSiteControlView::ShowMoreMenu() {
  auto model = std::make_unique<ui::SimpleMenuModel>(this);
  // SiteControlController.showMore: data, Boosts, Extensions, Site Settings.
  if (state_.is_website) {
    model->AddItem(kCmdClearCache, u"Clear Cache");
    model->AddItem(kCmdClearCookies, u"Clear Cookies");
    model->AddItem(kCmdCopyCleanUrl, u"Copy Clean URL");
    model->AddSeparator(ui::NORMAL_SEPARATOR);
  }
  model->AddItem(kCmdManageBoosts, u"Manage Boosts…");
  model->AddItem(kCmdNewBoost, u"New Boost…");
  model->AddSeparator(ui::NORMAL_SEPARATOR);
  model->AddItem(kCmdManageExtensions, u"Manage Extensions…");
  model->AddItem(kCmdAddExtension, u"Add Extension…");
  if (state_.is_website) {
    model->AddSeparator(ui::NORMAL_SEPARATOR);
    model->AddItem(kCmdSiteSettings, u"All Site Settings…");
  }
  menu_target_ = -1;
  RunMenu(std::move(model), more_->GetBoundsInScreen(),
          ui::mojom::MenuSourceType::kMouse);
}

void OpenSiteControlView::ShowTileMenu(size_t index,
                                       const gfx::Point& point,
                                       ui::mojom::MenuSourceType source_type) {
  if (index >= all_tiles_.size()) {
    return;
  }
  const SiteSettingTile& tile = all_tiles_[index];
  const content_settings::ContentSettingsInfo* info =
      InfoFor(SpecFor(tile.type).content_type);
  auto model = std::make_unique<ui::SimpleMenuModel>(this);
  if (!info || info->IsSettingValid(CONTENT_SETTING_ALLOW)) {
    model->AddRadioItem(kCmdAllow, u"Allow", kTileMenuGroup);
  }
  model->AddRadioItem(kCmdBlock, u"Block", kTileMenuGroup);
  const bool default_is_ask =
      tile.kind == SiteSettingTileKind::kPermission ||
      (info && info->IsSettingValid(CONTENT_SETTING_ASK));
  model->AddRadioItem(kCmdReset, default_is_ask ? u"Ask" : u"Reset to Default",
                      kTileMenuGroup);
  menu_target_ = static_cast<int>(index);
  RunMenu(std::move(model), gfx::Rect(point, gfx::Size()), source_type);
}

void OpenSiteControlView::ShowExtensionMenu(
    size_t index,
    const gfx::Point& point,
    ui::mojom::MenuSourceType source_type) {
  if (index >= state_.extensions.size()) {
    return;
  }
  const SiteControlExtensionItem& item = state_.extensions[index];
  if (callbacks_.on_extension_context_menu) {
    callbacks_.on_extension_context_menu.Run(item.id, extension_tiles_[index],
                                             point, source_type);
    return;
  }
  auto model = std::make_unique<ui::SimpleMenuModel>(this);
  model->AddItem(kCmdExtRun, item.name);
  model->AddSeparator(ui::NORMAL_SEPARATOR);
  if (callbacks_.on_toggle_extension_pin && !item.force_pinned) {
    model->AddItem(kCmdExtPin, item.pinned ? u"Unpin" : u"Pin");
  }
  model->AddItem(kCmdExtManage, u"Manage Extensions…");
  menu_target_ = static_cast<int>(index);
  RunMenu(std::move(model), gfx::Rect(point, gfx::Size()), source_type);
}

void OpenSiteControlView::ShowContextMenuForViewImpl(
    views::View* source,
    const gfx::Point& point,
    ui::mojom::MenuSourceType source_type) {
  for (size_t i = 0; i < extension_tiles_.size(); ++i) {
    if (extension_tiles_[i] == source) {
      ShowExtensionMenu(i, point, source_type);
      return;
    }
  }
  for (size_t i = 0; i < tile_rows_.size(); ++i) {
    if (tile_rows_[i] == source) {
      ShowTileMenu(tile_row_indices_[i], point, source_type);
      return;
    }
  }
}

void OpenSiteControlView::ExecuteCommand(int command_id, int event_flags) {
  // Deferred: menu commands may rebuild or close the panel, and the menu
  // model is still on the stack.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<OpenSiteControlView> view, int command, int target) {
            if (!view) {
              return;
            }
            auto close = [&view] {
              if (view && view->GetWidget()) {
                view->GetWidget()->Close();
              }
            };
            SiteControlCallbacks& cb = view->callbacks_;
            switch (command) {
              case kCmdAllow:
              case kCmdBlock:
              case kCmdReset:
                if (target >= 0) {
                  view->OnTileSettingChosen(
                      static_cast<size_t>(target),
                      command == kCmdAllow   ? SitePermissionSetting::kAllow
                      : command == kCmdBlock ? SitePermissionSetting::kBlock
                                             : SitePermissionSetting::kAsk);
                }
                return;
              case kCmdClearCache:
                view->ClearSiteData(SiteDataKind::kCache);
                return;
              case kCmdClearCookies:
                view->ClearSiteData(SiteDataKind::kCookies);
                return;
              case kCmdCopyCleanUrl:
                if (cb.on_copy_clean_url) {
                  cb.on_copy_clean_url.Run();
                } else {
                  site_control_data::CopyCleanUrl(view->state_.url);
                }
                close();
                return;
              case kCmdManageBoosts:
                if (cb.on_manage_boosts) {
                  cb.on_manage_boosts.Run();
                  close();
                }
                return;
              case kCmdNewBoost:
                if (cb.on_open_boost_editor) {
                  cb.on_open_boost_editor.Run(std::nullopt);
                  close();
                } else if (view->delegate_) {
                  view->delegate_->OnSiteControlAction(
                      SiteControlAction::kNewBoost);
                }
                return;
              case kCmdManageExtensions:
              case kCmdExtManage:
                if (cb.on_manage_extensions) {
                  cb.on_manage_extensions.Run();
                  close();
                }
                return;
              case kCmdAddExtension:
                if (cb.on_add_extension) {
                  cb.on_add_extension.Run();
                  close();
                }
                return;
              case kCmdSiteSettings:
                if (cb.on_open_site_settings) {
                  cb.on_open_site_settings.Run();
                  close();
                } else if (view->delegate_) {
                  view->delegate_->OnSiteControlAction(
                      SiteControlAction::kSiteSettings);
                }
                return;
              case kCmdExtRun:
                if (target >= 0) {
                  view->OnExtensionPressed(static_cast<size_t>(target));
                }
                return;
              case kCmdExtPin:
                if (target >= 0 &&
                    static_cast<size_t>(target) <
                        view->state_.extensions.size() &&
                    cb.on_toggle_extension_pin) {
                  SiteControlExtensionItem& item =
                      view->state_.extensions[static_cast<size_t>(target)];
                  item.pinned = !item.pinned;
                  cb.on_toggle_extension_pin.Run(item.id, item.pinned);
                }
                return;
            }
          },
          weak_factory_.GetWeakPtr(), command_id, menu_target_));
}

bool OpenSiteControlView::IsCommandIdChecked(int command_id) const {
  if (menu_target_ < 0 ||
      static_cast<size_t>(menu_target_) >= all_tiles_.size() ||
      command_id < kCmdAllow || command_id > kCmdReset) {
    return false;
  }
  switch (all_tiles_[static_cast<size_t>(menu_target_)].setting) {
    case SitePermissionSetting::kAllow:
      return command_id == kCmdAllow;
    case SitePermissionSetting::kBlock:
      return command_id == kCmdBlock;
    case SitePermissionSetting::kAsk:
      return command_id == kCmdReset;
  }
  return false;
}

bool OpenSiteControlView::IsCommandIdEnabled(int command_id) const {
  switch (command_id) {
    case kCmdClearCache:
      return state_.is_website &&
             (tab_ || !callbacks_.on_clear_cache_and_reload.is_null() ||
              delegate_);
    case kCmdClearCookies:
      return state_.is_website &&
             (tab_ || !callbacks_.on_clear_cookies_and_reload.is_null() ||
              delegate_);
    case kCmdManageBoosts:
      return !state_.incognito && !callbacks_.on_manage_boosts.is_null();
    case kCmdNewBoost:
      return state_.is_website && !state_.incognito &&
             state_.can_create_boost && state_.boosts_globally_enabled;
    case kCmdManageExtensions:
    case kCmdExtManage:
      return !callbacks_.on_manage_extensions.is_null();
    case kCmdAddExtension:
      return !callbacks_.on_add_extension.is_null();
    default:
      return true;
  }
}

// --- Painting ------------------------------------------------------------------

void OpenSiteControlView::PaintActionTile(int index,
                                          gfx::Canvas* canvas,
                                          const gfx::Rect& bounds,
                                          bool hovered) {
  static constexpr std::array<Sym, 4> kSymsForTiles = {
      Sym::kShare, Sym::kBoost, Sym::kCapture, Sym::kCaptureFull};
  const gfx::RectF tile(bounds);
  // Gradient tile, 1 pt ring, dark 1 pt top highlight (SiteControlColors).
  secondary::FillRoundRectGradient(
      canvas, tile, m::kActionRadius,
      Color(kActionFillTopLight, kActionFillTopDark),
      Color(kActionFillBottomLight, kActionFillBottomDark));
  if (hovered) {
    secondary::FillRoundRect(
        canvas, tile, m::kActionRadius,
        secondary::WithAlpha(appearance_.dark ? SK_ColorWHITE : SK_ColorBLACK,
                             0.05f));
  }
  if (appearance_.dark) {
    canvas->FillRect(gfx::Rect(bounds.x() + m::kActionRadius, bounds.y(),
                               bounds.width() - 2 * m::kActionRadius, 1),
                     hovered ? kActionHighlightHoverDark
                             : kActionHighlightDark);
  }
  secondary::StrokeRoundRect(canvas, tile, m::kActionRadius,
                             Color(secondary::WithAlpha(SK_ColorBLACK, 0.08f),
                                   secondary::WithAlpha(SK_ColorBLACK, 0.30f)),
                             1.f);
  SkColor glyph =
      Color(kGlyphLight, secondary::WithAlpha(SK_ColorWHITE, 0.85f));
  Sym sym = kSymsForTiles[static_cast<size_t>(index)];
  if (index == 1 && state_.boost_active) {
    glyph = appearance_.ActiveAccent();
    sym = Sym::kBoostFill;
  }
  if (!action_tiles_[static_cast<size_t>(index)]->GetEnabled()) {
    glyph = secondary::WithAlpha(glyph, m::kDisabledAlpha);
  }
  const float g = m::kActionGlyph;
  PaintSym(canvas, sym,
           gfx::RectF(tile.CenterPoint().x() - g / 2.f,
                      tile.CenterPoint().y() - g / 2.f, g, g),
           glyph, g);
}

void OpenSiteControlView::PaintSectionHeader(Section section,
                                             gfx::Canvas* canvas,
                                             const gfx::Rect& bounds,
                                             bool hovered) {
  std::u16string caption;
  std::u16string accessory;
  switch (section) {
    case Section::kExtensions:
      caption = u"Extensions";
      accessory = u"Manage";
      break;
    case Section::kBoosts:
      caption = u"Boosts";
      accessory = u"Manage";
      break;
    case Section::kSettings:
      caption = u"Settings";
      accessory = show_all_settings_ ? u"Less" : u"More";
      break;
  }
  const int baseline = bounds.y() + m::kLabelBaselineInRow;
  DrawLine(canvas, caption,
           secondary::FontOfSize(kLabelFontSize, gfx::Font::Weight::SEMIBOLD),
           Color(kLabelLight, kLabelDark), bounds.x() + m::kPadding, baseline,
           bounds.width() - 2 * m::kPadding);
  // The accessory fades in on hover (SiteControlSectionButton).
  if (hovered) {
    DrawLine(canvas, accessory, secondary::FontOfSize(kSubtitleFontSize),
             Color(secondary::WithAlpha(kRowTitleLight, 0.6f),
                   kRowSubtitleDark),
             bounds.x() + m::kPadding, baseline,
             bounds.width() - 2 * m::kPadding,
             gfx::Canvas::TEXT_ALIGN_RIGHT);
  }
}

void OpenSiteControlView::PaintExtensionTile(size_t index,
                                             gfx::Canvas* canvas,
                                             const gfx::Rect& bounds,
                                             bool hovered) {
  if (index >= state_.extensions.size()) {
    return;
  }
  const SiteControlExtensionItem& item = state_.extensions[index];
  const gfx::RectF tile(bounds);
  secondary::FillRoundRect(
      canvas, tile, m::kTileRadius,
      Color(secondary::WithAlpha(SK_ColorBLACK, hovered ? 0.11f : 0.07f),
            secondary::WithAlpha(SK_ColorWHITE, hovered ? 0.12f : 0.08f)));
  const gfx::Rect icon(bounds.CenterPoint().x() - m::kExtensionIcon / 2,
                       bounds.CenterPoint().y() - m::kExtensionIcon / 2,
                       m::kExtensionIcon, m::kExtensionIcon);
  if (item.icon.isNull()) {
    secondary::PaintGlyph(
        canvas, Glyph::kPuzzle, gfx::RectF(icon),
        Color(kGlyphLight, secondary::WithAlpha(SK_ColorWHITE, 0.85f)));
  } else {
    canvas->SaveLayerAlpha(item.enabled ? 255 : 90);
    secondary::DrawImageInRect(canvas, item.icon, icon);
    canvas->Restore();
  }
  if (!item.badge_text.empty()) {
    // Badge overlay at the icon's bottom-right (Chromium toolbar badge
    // convention; size is a guess).
    const gfx::FontList font =
        secondary::FontOfSize(9, gfx::Font::Weight::BOLD);
    const int w = std::max(12, secondary::TextWidth(item.badge_text, font) + 6);
    const gfx::Rect badge(
        std::min(icon.right() + 4 - w / 2, bounds.right() - w - 2),
        icon.bottom() - 6, w, 12);
    secondary::FillRoundRect(canvas, gfx::RectF(badge), 6.f, item.badge_color);
    secondary::DrawText(canvas, item.badge_text, font, item.badge_text_color,
                        badge, gfx::Canvas::TEXT_ALIGN_CENTER);
  }
}

void OpenSiteControlView::PaintAddExtensionTile(gfx::Canvas* canvas,
                                                const gfx::Rect& bounds,
                                                bool hovered) {
  secondary::FillRoundRect(
      canvas, gfx::RectF(bounds), m::kTileRadius,
      Color(secondary::WithAlpha(SK_ColorBLACK, hovered ? 0.11f : 0.07f),
            secondary::WithAlpha(SK_ColorWHITE, hovered ? 0.12f : 0.08f)));
  const float g = 14.f;
  PaintSym(canvas, Sym::kPlus,
           gfx::RectF(bounds.CenterPoint().x() - g / 2.f,
                      bounds.CenterPoint().y() - g / 2.f, g, g),
           Color(kGlyphLight, secondary::WithAlpha(SK_ColorWHITE, 0.85f)), g);
}

void OpenSiteControlView::PaintNote(const std::u16string& text,
                                    gfx::Canvas* canvas,
                                    const gfx::Rect& bounds,
                                    bool hovered) {
  const gfx::FontList font = secondary::FontOfSize(kSubtitleFontSize);
  const SkColor color =
      Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark);
  // The Boosts note breaks after its first sentence (SiteControlBaselineLabel
  // multiline: baselines 11 and 26).
  const size_t split = text.find(u". ");
  if (split != std::u16string::npos && text.starts_with(u"Boosts")) {
    DrawLine(canvas, std::u16string_view(text).substr(0, split + 1), font,
             color, bounds.x(), bounds.y() + 11, bounds.width());
    DrawLine(canvas, std::u16string_view(text).substr(split + 2), font, color,
             bounds.x(), bounds.y() + 26, bounds.width());
    return;
  }
  DrawLine(canvas, text, font, color, bounds.x(), bounds.y() + 20,
           bounds.width());
}

void OpenSiteControlView::PaintRowCircle(gfx::Canvas* canvas,
                                         const gfx::Rect& circle,
                                         bool on,
                                         int symbol,
                                         bool pressed) {
  // Light: an "on" disc in the Space's dark accent (D3 section 2.5); Dark
  // keeps Arc's measured disc.
  SkColor disc = on ? (appearance_.dark ? kCircleOnDark
                                        : appearance_.dark_accent)
                    : Color(secondary::WithAlpha(SK_ColorBLACK, 0.10f),
                            secondary::WithAlpha(SK_ColorWHITE, 0.28f));
  if (pressed) {
    disc = secondary::Mix(disc, SK_ColorBLACK, 0.08f);
  }
  secondary::FillRoundRect(canvas, gfx::RectF(circle), circle.width() / 2.f,
                           disc);
  // The glyph is a knock-out: drawn in the panel color on an "on" disc.
  const SkColor ink = on ? panel_color() : Color(kRowTitleLight, kRowTitleDark);
  const float g = m::kRowGlyph;
  PaintSym(canvas, static_cast<Sym>(symbol),
           gfx::RectF(circle.CenterPoint().x() - g / 2.f,
                      circle.CenterPoint().y() - g / 2.f, g, g),
           ink, g, glyphs::SymbolWeight::kMedium);
}

void OpenSiteControlView::PaintTileRow(size_t row_index,
                                       gfx::Canvas* canvas,
                                       const gfx::Rect& bounds,
                                       bool hovered) {
  if (row_index >= tile_row_indices_.size() ||
      tile_row_indices_[row_index] >= all_tiles_.size()) {
    return;
  }
  const SiteSettingTile& tile = all_tiles_[tile_row_indices_[row_index]];
  const bool dim = !tile.enabled;
  if (dim) {
    canvas->SaveLayerAlpha(static_cast<uint8_t>(255 * m::kDisabledAlpha));
  }
  PaintRowCircle(canvas,
                 gfx::Rect(bounds.x() + m::kPadding, bounds.y(), m::kRowIcon,
                           m::kRowIcon),
                 tile.state == SiteSettingTileState::kOn,
                 static_cast<int>(SymForTile(tile)), false);
  const gfx::FontList title =
      secondary::FontOfSize(kTitleFontSize, gfx::Font::Weight::SEMIBOLD);
  const gfx::FontList subtitle = secondary::FontOfSize(kSubtitleFontSize);
  const int text_x = bounds.x() + m::kRowTextX;
  const int title_width = bounds.width() - m::kRowTextX -
                          m::kRowTitleTrailing -
                          (tile.in_use ? m::kInUseDot + 4 : 0);
  DrawLine(canvas, tile.title, title, Color(kRowTitleLight, kRowTitleDark),
           text_x, bounds.y() + m::kRowTitleBaseline, title_width);
  DrawLine(canvas, tile.subtitle, subtitle,
           Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark),
           text_x, bounds.y() + m::kRowSubtitleBaseline,
           bounds.width() - m::kRowTextX - m::kPadding);
  if (tile.in_use) {
    const int advance =
        std::min(title_width, secondary::TextWidth(tile.title, title));
    secondary::FillRoundRect(
        canvas,
        gfx::RectF(text_x + advance + 4, bounds.y() + 5, m::kInUseDot,
                   m::kInUseDot),
        m::kInUseDot / 2.f, kInUseDot);
  }
  if (dim) {
    canvas->Restore();
  }
}

void OpenSiteControlView::PaintAudioMuteRow(gfx::Canvas* canvas,
                                            const gfx::Rect& bounds,
                                            bool hovered) {
  if (!tab_) {
    return;
  }
  const bool muted = tab_->IsAudioMuted();
  const bool audible = tab_->IsCurrentlyAudible();
  PaintRowCircle(canvas,
                 gfx::Rect(bounds.x() + m::kPadding, bounds.y(), m::kRowIcon,
                           m::kRowIcon),
                 /*on=*/!muted,
                 static_cast<int>(muted ? Sym::kSoundMuted : Sym::kSound),
                 hovered);
  const gfx::FontList title =
      secondary::FontOfSize(kTitleFontSize, gfx::Font::Weight::SEMIBOLD);
  const gfx::FontList subtitle = secondary::FontOfSize(kSubtitleFontSize);
  const int text_x = bounds.x() + m::kRowTextX;
  const std::u16string title_text = u"Tab Audio";
  const bool show_dot = audible && !muted;
  const int title_width = bounds.width() - m::kRowTextX - m::kRowTitleTrailing -
                          (show_dot ? m::kInUseDot + 4 : 0);
  DrawLine(canvas, title_text, title, Color(kRowTitleLight, kRowTitleDark),
           text_x, bounds.y() + m::kRowTitleBaseline, title_width);
  DrawLine(canvas, muted ? u"Muted" : u"Playing", subtitle,
           Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark),
           text_x, bounds.y() + m::kRowSubtitleBaseline,
           bounds.width() - m::kRowTextX - m::kPadding);
  if (show_dot) {
    const int advance =
        std::min(title_width, secondary::TextWidth(title_text, title));
    secondary::FillRoundRect(
        canvas,
        gfx::RectF(text_x + advance + 4, bounds.y() + 5, m::kInUseDot,
                   m::kInUseDot),
        m::kInUseDot / 2.f, kInUseDot);
  }
}

void OpenSiteControlView::PaintZoomLabel(gfx::Canvas* canvas,
                                         const gfx::Rect& bounds,
                                         bool hovered) {
  secondary::DrawText(
      canvas, u"Zoom",
      secondary::FontOfSize(kTitleFontSize, gfx::Font::Weight::SEMIBOLD),
      Color(kRowTitleLight, kRowTitleDark), bounds);
}

void OpenSiteControlView::PaintZoomStepButton(bool zoom_in,
                                              gfx::Canvas* canvas,
                                              const gfx::Rect& bounds,
                                              bool hovered) {
  const bool enabled = zoom_in ? CanZoomIn() : CanZoomOut();
  const gfx::RectF pill(bounds);
  secondary::FillRoundRect(
      canvas, pill, m::kTileRadius,
      Color(secondary::WithAlpha(SK_ColorBLACK,
                                 hovered && enabled ? 0.11f : 0.06f),
            secondary::WithAlpha(SK_ColorWHITE,
                                 hovered && enabled ? 0.14f : 0.08f)));
  SkColor ink = Color(kGlyphLight, secondary::WithAlpha(SK_ColorWHITE, 0.85f));
  if (!enabled) {
    ink = secondary::WithAlpha(ink, m::kDisabledAlpha);
  }
  const float g = 11.f;
  PaintSym(canvas, zoom_in ? Sym::kPlus : Sym::kMinus,
           gfx::RectF(pill.CenterPoint().x() - g / 2.f,
                      pill.CenterPoint().y() - g / 2.f, g, g),
           ink, g, glyphs::SymbolWeight::kSemibold);
}

void OpenSiteControlView::PaintZoomResetButton(gfx::Canvas* canvas,
                                               const gfx::Rect& bounds,
                                               bool hovered) {
  const int percent = CurrentZoomPercent();
  const bool non_default = percent != 100;
  const gfx::RectF pill(bounds);
  secondary::FillRoundRect(
      canvas, pill, m::kTileRadius,
      Color(secondary::WithAlpha(SK_ColorBLACK, hovered ? 0.11f : 0.06f),
            secondary::WithAlpha(SK_ColorWHITE, hovered ? 0.14f : 0.08f)));
  const SkColor ink =
      non_default ? appearance_.ActiveAccent()
                  : Color(kRowTitleLight, kRowTitleDark);
  secondary::DrawText(
      canvas, base::StrCat({base::NumberToString16(percent), u"%"}),
      secondary::FontOfSize(12, non_default ? gfx::Font::Weight::SEMIBOLD
                                            : gfx::Font::Weight::MEDIUM),
      ink, bounds, gfx::Canvas::TEXT_ALIGN_CENTER);
}

void OpenSiteControlView::PaintBoostRow(size_t index,
                                        gfx::Canvas* canvas,
                                        const gfx::Rect& bounds,
                                        bool hovered) {
  if (index >= state_.boosts.size()) {
    return;
  }
  const SiteControlBoostItem& boost = state_.boosts[index];
  const bool dim = !state_.boosts_globally_enabled || state_.incognito;
  if (dim) {
    canvas->SaveLayerAlpha(128);
  }
  const gfx::FontList title =
      secondary::FontOfSize(kTitleFontSize, gfx::Font::Weight::SEMIBOLD);
  const gfx::FontList subtitle = secondary::FontOfSize(kSubtitleFontSize);
  const SkColor sub =
      Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark);
  const int text_x = bounds.x() + m::kRowTextX;
  // The Zap count pill sits at the trailing edge, before the chevron.
  std::u16string zaps;
  int pill_width = 0;
  const gfx::FontList pill_font =
      secondary::FontOfSize(11, gfx::Font::Weight::SEMIBOLD);
  if (boost.zap_count > 0) {
    zaps = base::StrCat({base::NumberToString16(boost.zap_count),
                         boost.zap_count == 1 ? u" Zap" : u" Zaps"});
    pill_width = secondary::TextWidth(zaps, pill_font) + 12;
  }
  const int trailing = m::kRowTitleTrailing + 11 + (pill_width ? pill_width + 6 : 0);
  DrawLine(canvas, boost.name, title, Color(kRowTitleLight, kRowTitleDark),
           text_x, bounds.y() + m::kRowTitleBaseline,
           bounds.width() - m::kRowTextX - trailing);
  DrawLine(canvas, boost.enabled ? u"Enabled" : u"Disabled", subtitle, sub,
           text_x, bounds.y() + m::kRowSubtitleBaseline,
           bounds.width() - m::kRowTextX - trailing);
  if (pill_width) {
    const gfx::Rect pill(bounds.right() - m::kPadding - 11 - 6 - pill_width,
                         bounds.CenterPoint().y() - 9, pill_width, 18);
    secondary::FillRoundRect(
        canvas, gfx::RectF(pill), 9.f,
        Color(secondary::WithAlpha(SK_ColorBLACK, 0.07f),
              secondary::WithAlpha(SK_ColorWHITE, 0.10f)));
    secondary::DrawText(canvas, zaps, pill_font, sub, pill,
                        gfx::Canvas::TEXT_ALIGN_CENTER);
  }
  if (hovered) {
    PaintSym(canvas, Sym::kChevronRight,
             gfx::RectF(bounds.right() - 10 - 11, bounds.CenterPoint().y() - 5.5f,
                        11, 11),
             sub, 11, glyphs::SymbolWeight::kSemibold);
  }
  if (dim) {
    canvas->Restore();
  }
}

void OpenSiteControlView::PaintBoostCircle(size_t index,
                                           gfx::Canvas* canvas,
                                           const gfx::Rect& bounds,
                                           bool hovered) {
  if (index >= state_.boosts.size()) {
    return;
  }
  PaintRowCircle(canvas, bounds, state_.boosts[index].enabled,
                 static_cast<int>(Sym::kBoostFill), false);
}

void OpenSiteControlView::PaintReloadLabel(gfx::Canvas* canvas,
                                           const gfx::Rect& bounds,
                                           bool hovered) {
  DrawLine(canvas, u"Reload to apply changes.",
           secondary::FontOfSize(kSubtitleFontSize),
           Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark),
           bounds.x(), bounds.y() + 20, bounds.width());
}

void OpenSiteControlView::PaintReloadButton(gfx::Canvas* canvas,
                                            const gfx::Rect& bounds,
                                            bool hovered) {
  SkColor ink = Color(kRowTitleLight, kRowTitleDark);
  if (hovered) {
    ink = secondary::WithAlpha(ink, 0.75f);
  }
  DrawLine(canvas, u"Reload",
           secondary::FontOfSize(13, gfx::Font::Weight::SEMIBOLD), ink,
           bounds.x(), bounds.y() + 20, bounds.width(),
           gfx::Canvas::TEXT_ALIGN_RIGHT);
}

void OpenSiteControlView::PaintTextButton(const std::u16string& text,
                                          gfx::Canvas* canvas,
                                          const gfx::Rect& bounds,
                                          bool hovered) {
  if (hovered) {
    secondary::FillRoundRect(
        canvas, gfx::RectF(bounds), 6.f,
        Color(secondary::WithAlpha(SK_ColorBLACK, 0.05f),
              secondary::WithAlpha(SK_ColorWHITE, 0.06f)));
  }
  gfx::Rect text_rect = bounds;
  text_rect.Inset(gfx::Insets::VH(0, 4));
  secondary::DrawText(
      canvas, text, secondary::FontOfSize(13, gfx::Font::Weight::SEMIBOLD),
      Color(kRowTitleLight, kRowTitleDark), text_rect,
      gfx::Canvas::TEXT_ALIGN_LEFT);
}

void OpenSiteControlView::PaintCertificatePage(gfx::Canvas* canvas,
                                               const gfx::Rect& bounds,
                                               bool hovered) {
  const gfx::FontList label = secondary::FontOfSize(12);
  const gfx::FontList value =
      secondary::FontOfSize(13, gfx::Font::Weight::MEDIUM);
  const gfx::FontList heading =
      secondary::FontOfSize(kLabelFontSize, gfx::Font::Weight::SEMIBOLD);
  const SkColor sub =
      Color(secondary::WithAlpha(kRowTitleLight, 0.6f), kRowSubtitleDark);
  const SkColor ink = Color(kRowTitleLight, kRowTitleDark);
  const int x = bounds.x();
  const int w = bounds.width();
  int baseline = bounds.y() + 14;
  DrawLine(canvas, state_.host, heading, Color(kLabelLight, kLabelDark), x,
           baseline, w);
  if (!state_.certificate) {
    baseline += 20;
    DrawLine(canvas, u"No certificate details are available.", label, sub, x,
             baseline, w);
    return;
  }
  const SiteCertificateSummary& c = *state_.certificate;
  auto field = [&](std::u16string_view name, std::u16string_view text) {
    baseline += 20;
    DrawLine(canvas, name, label, sub, x, baseline, w);
    baseline += 20;
    DrawLine(canvas, text, value, ink, x, baseline, w);
  };
  if (c.has_errors || c.expired) {
    baseline += 20;
    DrawLine(canvas,
             c.expired ? u"This certificate has expired."
                       : u"This certificate has errors.",
             value, Color(kInsecureTextLight, kInsecureTextDark), x, baseline,
             w);
  }
  field(u"Issued to", c.subject);
  if (!c.organization.empty()) {
    baseline += 20;
    DrawLine(canvas, c.organization, value, ink, x, baseline, w);
  }
  field(u"Issued by", c.issuer);
  field(u"Valid", base::StrCat({FormatDate(c.valid_from), u" – ",
                                FormatDate(c.valid_until)}));
  if (!c.subject_alt_names.empty()) {
    baseline += 20;
    DrawLine(canvas, u"Also valid for", label, sub, x, baseline, w);
    const size_t shown = std::min<size_t>(c.subject_alt_names.size(), 6);
    for (size_t i = 0; i < shown; ++i) {
      baseline += 20;
      DrawLine(canvas, c.subject_alt_names[i], value, ink, x, baseline, w);
    }
    if (c.subject_alt_names.size() > shown) {
      baseline += 20;
      DrawLine(canvas,
               base::StrCat({u"and ",
                             base::NumberToString16(
                                 c.subject_alt_names.size() - shown),
                             u" more"}),
               label, sub, x, baseline, w);
    }
  }
  field(u"SHA-256", c.sha256);
}

void OpenSiteControlView::PaintPill(gfx::Canvas* canvas,
                                    const gfx::Rect& bounds,
                                    bool hovered) {
  const bool secure = state_.secure;
  const bool clickable = pill_->GetEnabled();
  const gfx::RectF pill(bounds);
  secondary::FillRoundRect(
      canvas, pill, m::kPillRadius,
      Color(secondary::WithAlpha(SK_ColorBLACK,
                                 hovered && clickable ? 0.07f : 0.04f),
            secondary::WithAlpha(SK_ColorWHITE,
                                 hovered && clickable ? 0.08f : 0.05f)));
  const SkColor ink = secure ? Color(kLabelLight, kLabelDark)
                             : Color(kInsecureTextLight, kInsecureTextDark);
  const float g = m::kPillLockGlyph;
  PaintSym(canvas, secure ? Sym::kLock : Sym::kLockOpen,
           gfx::RectF(bounds.x() + m::kPillPadding,
                      bounds.CenterPoint().y() - g / 2.f, g, g),
           ink, g);
  const int text_x =
      bounds.x() + m::kPillPadding + m::kPillLockGlyph + m::kPillLockGap;
  secondary::DrawText(
      canvas, secure ? u"Secure" : u"Insecure",
      secondary::FontOfSize(kPillFontSize, gfx::Font::Weight::MEDIUM), ink,
      gfx::Rect(text_x, bounds.y(),
                std::max(0, bounds.right() - m::kPillPadding - text_x),
                bounds.height()));
}

void OpenSiteControlView::PaintMore(gfx::Canvas* canvas,
                                    const gfx::Rect& bounds,
                                    bool hovered) {
  SkColor fill = Color(secondary::WithAlpha(SkColorSetRGB(128, 128, 128), 0.18f),
                       secondary::WithAlpha(SK_ColorBLACK, 0.28f));
  if (hovered) {
    fill = secondary::Mix(
        fill, appearance_.dark ? SK_ColorWHITE : SK_ColorBLACK, 0.06f);
  }
  secondary::FillRoundRect(canvas, gfx::RectF(bounds), bounds.width() / 2.f,
                           fill);
  const float g = m::kMoreGlyph;
  PaintSym(canvas, Sym::kMore,
           gfx::RectF(bounds.CenterPoint().x() - g / 2.f,
                      bounds.CenterPoint().y() - g / 2.f, g, g),
           Color(kGlyphLight, secondary::WithAlpha(SK_ColorWHITE, 0.85f)), g,
           glyphs::SymbolWeight::kBold);
}

BEGIN_METADATA(OpenSiteControlView)
END_METADATA

// --- OpenSiteControlBubble ---------------------------------------------------

// Keeps an open panel live: the tab's navigation and capability changes,
// the Profile's ad-block service, and the media capture indicator.
class OpenSiteControlBubble::LiveObserver
    : public content::WebContentsObserver,
      public OpenAdBlockProfileService::Observer,
      public MediaStreamCaptureIndicator::Observer {
 public:
  LiveObserver(OpenSiteControlBubble* owner, content::WebContents* tab)
      : content::WebContentsObserver(tab),
        owner_(owner),
        indicator_(MediaCaptureDevicesDispatcher::GetInstance()
                       ->GetMediaStreamCaptureIndicator()) {
    if (OpenAdBlockProfileService* adblock =
            OpenAdBlockProfileService::GetForBrowserContext(
                tab->GetBrowserContext())) {
      adblock_observation_.Observe(adblock);
    }
    if (indicator_) {
      indicator_->AddObserver(this);
    }
    if (content::HostZoomMap* zoom_map =
            content::HostZoomMap::GetForWebContents(tab)) {
      zoom_subscription_ = zoom_map->AddZoomLevelChangedCallback(
          base::BindRepeating(&LiveObserver::OnZoomChanged,
                              base::Unretained(this)));
    }
  }

  ~LiveObserver() override {
    if (indicator_) {
      indicator_->RemoveObserver(this);
    }
  }

  // content::WebContentsObserver:
  void PrimaryPageChanged(content::Page& page) override {
    owner_->OnTabNavigated();
  }
  void DidChangeVisibleSecurityState() override {
    owner_->OnLiveSourceChanged();
  }
  void OnAudioStateChanged(bool audible) override {
    owner_->OnLiveSourceChanged();
  }
  void DidUpdateAudioMutingState(bool muted) override {
    owner_->OnLiveSourceChanged();
  }
  void OnCapabilityTypesChanged(
      content::WebContentsCapabilityType capability_type,
      bool used) override {
    owner_->OnLiveSourceChanged();
  }
  void WebContentsDestroyed() override { owner_->OnTabDestroyed(); }

  // OpenAdBlockProfileService::Observer:
  void OnAdBlockStateChanged(const std::string& profile_id) override {
    owner_->OnLiveSourceChanged();
  }
  void OnAdBlockBlockedCountChanged(content::WebContents* contents,
                                    int count) override {
    if (contents == web_contents()) {
      owner_->OnBlockedCountChanged(count);
    }
  }

  // MediaStreamCaptureIndicator::Observer:
  void OnIsCapturingVideoChanged(content::WebContents* contents,
                                 bool capturing) override {
    MaybeRefresh(contents);
  }
  void OnIsCapturingAudioChanged(content::WebContents* contents,
                                 bool capturing) override {
    MaybeRefresh(contents);
  }
  void OnIsCapturingTabChanged(content::WebContents* contents,
                               bool capturing) override {
    MaybeRefresh(contents);
  }
  void OnIsCapturingWindowChanged(content::WebContents* contents,
                                  bool capturing) override {
    MaybeRefresh(contents);
  }
  void OnIsCapturingDisplayChanged(content::WebContents* contents,
                                   bool capturing) override {
    MaybeRefresh(contents);
  }

 private:
  void MaybeRefresh(content::WebContents* contents) {
    if (contents == web_contents()) {
      owner_->OnLiveSourceChanged();
    }
  }

  void OnZoomChanged(const content::HostZoomMap::ZoomLevelChange&) {
    owner_->OnZoomLevelChanged();
  }

  raw_ptr<OpenSiteControlBubble> owner_;
  scoped_refptr<MediaStreamCaptureIndicator> indicator_;
  base::ScopedObservation<OpenAdBlockProfileService,
                          OpenAdBlockProfileService::Observer>
      adblock_observation_{this};
  base::CallbackListSubscription zoom_subscription_;
};

OpenSiteControlBubble::OpenSiteControlBubble(SiteControlDelegate* delegate)
    : delegate_(delegate) {}

OpenSiteControlBubble::~OpenSiteControlBubble() {
  live_observer_.reset();
  DiscardBubble(/*synchronous=*/true);
}

void OpenSiteControlBubble::DiscardBubble(bool synchronous) {
  weak_factory_.InvalidateWeakPtrs();
  contents_ = nullptr;
  if (synchronous) {
    if (widget_) {
      widget_->CloseNow();
    }
    widget_.reset();
    bubble_delegate_.reset();
    return;
  }
  // Posted in order: the widget is deleted before its delegate.
  if (widget_) {
    widget_->Hide();
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(widget_));
  }
  if (bubble_delegate_) {
    base::SequencedTaskRunner::GetCurrentDefault()->DeleteSoon(
        FROM_HERE, std::move(bubble_delegate_));
  }
}

void OpenSiteControlBubble::Show(views::View* anchor,
                                 const SiteControlState& state,
                                 const secondary::Appearance& appearance) {
  Show(anchor, state, appearance, nullptr, callbacks_);
}

void OpenSiteControlBubble::Show(views::View* anchor,
                                 const SiteControlState& state,
                                 const secondary::Appearance& appearance,
                                 content::WebContents* tab,
                                 const SiteControlCallbacks& callbacks) {
  // Reopening replaces the panel: release the old bubble (and cancel its
  // closed callback) before the members are reassigned.
  DiscardBubble(/*synchronous=*/false);
  live_observer_.reset();
  appearance_ = appearance;
  callbacks_ = callbacks;
  bubble_delegate_ = std::make_unique<views::BubbleDialogDelegate>(
      anchor, views::BubbleBorder::TOP_LEFT, views::BubbleBorder::DIALOG_SHADOW,
      /*autosize=*/true);
  bubble_delegate_->set_margins(gfx::Insets());
  bubble_delegate_->set_fixed_width(site_control_metrics::kWidth);
  bubble_delegate_->set_corner_radius(site_control_metrics::kCornerRadius);
  bubble_delegate_->SetButtons(
      static_cast<int>(ui::mojom::DialogButton::kNone));
  bubble_delegate_->SetShowCloseButton(false);
  bubble_delegate_->SetShowTitle(false);
  bubble_delegate_->set_close_on_deactivate(true);
  auto view =
      std::make_unique<OpenSiteControlView>(delegate_, state, appearance);
  view->SetCallbacks(callbacks_);
  if (tab) {
    view->SetWebContents(tab);
  }
  contents_ = bubble_delegate_->SetContentsView(std::move(view));
  bubble_delegate_->SetBackgroundColor(contents_->panel_color());
  widget_ = views::BubbleDialogDelegate::CreateBubble(
      bubble_delegate_.get(),
      base::BindOnce(&OpenSiteControlBubble::OnWidgetClosed,
                     weak_factory_.GetWeakPtr()));
  if (tab) {
    live_observer_ = std::make_unique<LiveObserver>(this, tab);
  }
  widget_->Show();
}

void OpenSiteControlBubble::Close() {
  if (widget_) {
    widget_->CloseWithReason(views::Widget::ClosedReason::kUnspecified);
  }
}

bool OpenSiteControlBubble::IsShowing() const {
  return widget_ && widget_->IsVisible();
}

void OpenSiteControlBubble::UpdateState(const SiteControlState& state) {
  if (contents_) {
    contents_->SetState(state);
    if (bubble_delegate_) {
      bubble_delegate_->SetBackgroundColor(contents_->panel_color());
    }
  }
}

void OpenSiteControlBubble::SetAppearance(
    const secondary::Appearance& appearance) {
  appearance_ = appearance;
  if (contents_) {
    contents_->SetAppearance(appearance_);
    if (bubble_delegate_) {
      bubble_delegate_->SetBackgroundColor(contents_->panel_color());
    }
  }
  if (widget_) {
    if (views::View* root = widget_->GetRootView()) {
      root->SchedulePaint();
    }
  }
}

void OpenSiteControlBubble::SetAdBlockState(bool enabled, int blocked_count) {
  if (contents_) {
    contents_->SetAdBlockState(enabled, blocked_count);
  }
}

void OpenSiteControlBubble::SetCallbacks(const SiteControlCallbacks& callbacks) {
  callbacks_ = callbacks;
  if (contents_) {
    contents_->SetCallbacks(callbacks_);
  }
}

void OpenSiteControlBubble::SetWebContents(content::WebContents* tab) {
  live_observer_.reset();
  if (contents_) {
    contents_->SetWebContents(tab);
  }
  if (tab && contents_) {
    live_observer_ = std::make_unique<LiveObserver>(this, tab);
  }
}

void OpenSiteControlBubble::SetReloadBannerVisible(bool visible) {
  if (contents_) {
    contents_->SetReloadBannerVisible(visible);
  }
}

void OpenSiteControlBubble::OnTabNavigated() {
  if (!contents_) {
    return;
  }
  // A new page: the banner's change is applied, and the tiles belong to the
  // new origin (SiteControlContext.showsSameSite).
  contents_->SetReloadBannerVisible(false);
  if (callbacks_.refresh_state) {
    if (std::optional<SiteControlState> state = callbacks_.refresh_state.Run();
        state && contents_) {
      state->show_reload_banner = false;
      contents_->SetState(*state);
      return;
    }
  }
  if (!contents_) {
    return;
  }
  SiteControlState state = contents_->state();
  content::WebContents* tab = contents_->web_contents();
  if (tab) {
    const GURL old_url = state.url;
    site_control_data::FillStateFromTab(tab, &state);
    if (!url::Origin::Create(old_url).IsSameOriginWith(
            url::Origin::Create(state.url))) {
      // Boosts and the Boost tile belong to the old host.
      state.boosts.clear();
      state.boost_active = false;
      state.certificate.reset();
    }
  }
  state.tiles.clear();  // Re-derived from the tab.
  state.show_reload_banner = false;
  contents_->SetState(state);
}

void OpenSiteControlBubble::OnTabDestroyed() {
  live_observer_.reset();
  if (contents_) {
    contents_->SetWebContents(nullptr);
  }
  Close();
}

void OpenSiteControlBubble::OnLiveSourceChanged() {
  if (!contents_) {
    return;
  }
  // Coalesced: capture and ad-block changes can arrive in bursts.
  base::SequencedTaskRunner::GetCurrentDefault()->PostTask(
      FROM_HERE, base::BindOnce(
                     [](base::WeakPtr<OpenSiteControlBubble> self) {
                       if (!self || !self->contents_) {
                         return;
                       }
                       if (self->contents_->state().tiles.empty()) {
                         self->contents_->RefreshFromTab();
                       } else {
                         self->contents_->RefreshInUse();
                       }
                     },
                     weak_factory_.GetWeakPtr()));
}

void OpenSiteControlBubble::OnZoomLevelChanged() {
  if (contents_) {
    contents_->RefreshZoom();
  }
}

void OpenSiteControlBubble::OnBlockedCountChanged(int count) {
  if (contents_) {
    contents_->SetAdBlockState(contents_->state().ad_block_enabled, count);
  }
}

void OpenSiteControlBubble::OnWidgetClosed(views::Widget::ClosedReason reason) {
  // The close can start inside the widget's own activation handling, so hide
  // now and delete on the next task (widget first, then its delegate, which
  // must outlive it).
  live_observer_.reset();
  DiscardBubble(/*synchronous=*/false);
  if (delegate_) {
    delegate_->OnSiteControlClosed();
  }
}

}  // namespace open_unified
