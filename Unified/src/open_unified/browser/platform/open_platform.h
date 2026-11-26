// Copyright 2026 The Open Authors. All rights reserved.
// Cross-platform OS adapter interface for Open Unified Browser.

#ifndef OPEN_UNIFIED_BROWSER_PLATFORM_OPEN_PLATFORM_H_
#define OPEN_UNIFIED_BROWSER_PLATFORM_OPEN_PLATFORM_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "base/files/file_path.h"
#include "base/functional/callback.h"
#include "ui/gfx/geometry/point.h"

namespace views {
class Widget;
}  // namespace views

namespace open_unified {

// Modifier bitmask for RegisterGlobalHotkey.
enum HotkeyModifier : uint32_t {
  kHotkeyModNone = 0,
  kHotkeyModAlt = 1u << 0,
  kHotkeyModControl = 1u << 1,
  kHotkeyModShift = 1u << 2,
  kHotkeyModMeta = 1u << 3,  // Command on macOS, Win on Windows, Super on Linux
};

struct GlobalHotkeySpec {
  // Stable identifier for unregistering / routing callbacks.
  std::string id;
  // Bitmask of HotkeyModifier values.
  uint32_t modifiers = kHotkeyModNone;
  // Virtual key code (VKEY / ASCII uppercase letter or platform keycode).
  uint32_t key_code = 0;
};

// Cross-platform secret storage interface used by Open Sync v1 and credentials.
// Implementations:
// - Windows: Windows Credential Manager (CredWriteW/CredReadW) or DPAPI
//            (CryptProtectData/CryptUnprotectData) + private 0600 file.
// - Linux:   0600 protected file under user data dir with optional libsecret /
//            D-Bus Secret Service hook.
// - macOS:   Keychain Services (SecItemAdd/SecItemCopyMatching/SecItemDelete)
//            with automatic 0600 file fallback when Keychain is unavailable.
class SecretStore {
 public:
  virtual ~SecretStore() = default;

  // Stores raw secret bytes under |service| and |account|.
  // Overwrites any existing entry.
  virtual bool SaveSecret(std::string_view service,
                          std::string_view account,
                          const std::vector<uint8_t>& secret) = 0;

  // Loads raw secret bytes for |service| and |account|.
  // Returns std::nullopt if absent or unreadable.
  virtual std::optional<std::vector<uint8_t>> LoadSecret(
      std::string_view service,
      std::string_view account) = 0;

  // Removes the secret for |service| and |account|.
  // Returns true if deleted or already absent.
  virtual bool DeleteSecret(std::string_view service,
                            std::string_view account) = 0;

  // True when secrets are stored in a protected file rather than an OS vault.
  virtual bool UsesFileBackend() const = 0;
};

// The live window material under a translucent browser window (macOS:
// NSVisualEffectView behind-window blur plus a fitted gray wash, the port of
// ThemeBackgroundView.updateWindowMaterial()). Every field is a theme or
// window input; the adapter maps them to the measured C14-T fit.
struct WindowMaterialSpec {
  // The theme asks for the system material (ThemeStyle::is_vibrant). Off for
  // Incognito and fully opaque themes: the theme field covers the window.
  bool vibrant = true;
  // Stored translucency selects the material (dark: legacy raw value 2,
  // light: raw value 1).
  bool dark_translucency = false;
  // Window color scheme selects the wash and the material's appearance.
  bool dark_scheme = false;
  // The default (corner) theme has its own wash fit.
  bool default_theme = true;
  // The window paints as active (Widget::ShouldPaintAsActive(), so a Command
  // Bar or Find bar child window does not turn the material inactive).
  bool active = true;
  bool operator==(const WindowMaterialSpec&) const = default;
};

// Arc's traffic-light centers (AX frames [12/35/58, 16, 16, 16]): x 20 / 43 /
// 66, y 24, relative to the window's top-left corner, in points.
inline constexpr int kWindowButtonCenterX[3] = {20, 43, 66};
inline constexpr int kWindowButtonCenterY = 24;

// Platform-specific OS integration facade.
class OpenPlatform {
 public:
  using HotkeyCallback = base::RepeatingCallback<void(const std::string& id)>;

  OpenPlatform() = default;
  virtual ~OpenPlatform() = default;

  OpenPlatform(const OpenPlatform&) = delete;
  OpenPlatform& operator=(const OpenPlatform&) = delete;

  // Returns the process-wide singleton for the host operating system.
  static OpenPlatform* Get();

  // Creates a SecretStore rooted at |data_dir| (used for file-backed storage
  // or DPAPI blob storage). Pass |force_file_backend = true| for isolated test
  // data roots or ad-hoc builds without OS keychain access.
  virtual std::unique_ptr<SecretStore> CreateSecretStore(
      const base::FilePath& data_dir,
      bool force_file_backend = false) = 0;

  // Attempts to set Open as the OS default HTTP/HTTPS browser.
  // Returns true if the request succeeded or opened the OS default-apps prompt.
  virtual bool SetDefaultBrowser() = 0;

  // Returns true if Open is currently registered as the default web browser.
  virtual bool IsDefaultBrowser() = 0;

  // Registers a system-wide global hotkey (e.g., Option+Cmd+N / Alt+Ctrl+N
  // for Little Open). Invokes |callback| when pressed.
  virtual bool RegisterGlobalHotkey(const GlobalHotkeySpec& spec,
                                    HotkeyCallback callback) = 0;

  // Unregisters a previously registered global hotkey by |id|.
  virtual bool UnregisterGlobalHotkey(std::string_view id) = 0;

  // Applies native translucent / rounded / mica / vibrancy effects to a
  // top-level browser widget.
  virtual void ApplyWindowEffects(views::Widget* widget, bool dark_mode) = 0;

  // Updates the live window material for a theme or activation change.
  // Returns true when the native material now draws behind the window's
  // content, so the views paint the translucent window tint
  // (theme::ThemePainter::SetTranslucentWindow(true)) instead of the opaque
  // field. Default: no native material (returns false).
  virtual bool UpdateWindowEffects(views::Widget* widget,
                                   const WindowMaterialSpec& spec);

  // Places the native window buttons (macOS traffic lights). `origin` is the
  // group's offset from Arc's resting place (kWindowButtonCenterX/Y): (0, 0)
  // anchored, (5, 5) plus the card motion on the hover-reveal card, the live
  // sidebar offset during the Cmd/Ctrl+S slide. `visible` false hides the
  // buttons (sidebar hidden, no card). `dimmed` shows Arc's
  // DimmedWindowControls look at rest (grey circles; the system buttons
  // light up under the pointer). Native full screen is left to AppKit.
  // No-op on Windows and Linux.
  virtual void PlaceWindowButtons(views::Widget* widget,
                                  const gfx::Point& origin,
                                  bool visible,
                                  bool dimmed);
  // The tone of the dimmed circles: the Space's content appearance, and the
  // window's paint-as-active state (the colored rings show only while
  // active). No-op on Windows and Linux.
  virtual void SetWindowButtonsTone(views::Widget* widget,
                                    bool dark_content,
                                    bool active);

  // System "Increase contrast" (macOS
  // NSWorkspace.accessibilityDisplayShouldIncreaseContrast). Default false.
  virtual bool IsIncreaseContrastEnabled();

  // Sets the running app's icon (macOS
  // NSApplication.applicationIconImage) to the bundled alternate icon
  // `icon_id` ("" restores the default). Default: no-op, returns false.
  virtual bool SetAppIcon(const std::string& icon_id);

  // For Air Traffic Control: the bundle id (macOS) of the app that asked the
  // OS to open the URL being handled now, read from the current Apple Event's
  // sender PID. Empty when unknown or on other platforms. Call it while the
  // open-URL event is being handled.
  virtual std::string ResolveExternalUrlSourceApp();

  // Returns the platform-standard default user data directory:
  // - Windows: %LOCALAPPDATA%\Open
  // - Linux:   ~/.config/open (or $XDG_CONFIG_HOME/open)
  // - macOS:   ~/Library/Application Support/Open Unified (hook 0008; the
  //            AppKit Open keeps .../Open)
  virtual base::FilePath GetDefaultUserDataDir() = 0;

  // Returns a human-readable device name suitable for Sync device registration.
  virtual std::string GetDeviceName() = 0;

  // Returns the Open Sync v1 platform string ("windows", "linux", "macos").
  virtual std::string GetSyncPlatformName() = 0;
};

}  // namespace open_unified

#endif  // OPEN_UNIFIED_BROWSER_PLATFORM_OPEN_PLATFORM_H_
