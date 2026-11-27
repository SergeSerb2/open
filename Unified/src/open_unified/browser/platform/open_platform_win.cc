// Copyright 2026 The Open Authors. All rights reserved.
// Windows implementation of OpenPlatform.

#include "open_unified/browser/platform/open_platform.h"

#include <algorithm>
#include <cmath>
#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/utf_string_conversions.h"
#include "base/win/scoped_com_initializer.h"
#include "base/win/windows_version.h"
#include "ui/base/win/shell.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/win/hwnd_util.h"

#include <windows.h>

#include <dwmapi.h>
#include <shlobj.h>
#include <shellapi.h>
#include <wincred.h>
#include <wincrypt.h>

namespace open_unified {

namespace {

#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
constexpr DWORD kDwmwaUseImmersiveDarkMode = 20;
#else
constexpr DWORD kDwmwaUseImmersiveDarkMode = DWMWA_USE_IMMERSIVE_DARK_MODE;
#endif

#ifndef DWMWA_WINDOW_CORNER_PREFERENCE
constexpr DWORD kDwmwaWindowCornerPreference = 33;
constexpr DWORD kDwmwcpDoNotRound = 1;
constexpr DWORD kDwmwcpRound = 2;
#else
constexpr DWORD kDwmwaWindowCornerPreference = DWMWA_WINDOW_CORNER_PREFERENCE;
constexpr DWORD kDwmwcpDoNotRound = DWMWCP_DONOTROUND;
constexpr DWORD kDwmwcpRound = DWMWCP_ROUND;
#endif

#ifndef DWMWA_SYSTEMBACKDROP_TYPE
constexpr DWORD kDwmwaSystemBackdropType = 38;
constexpr DWORD kDwmsbtNone = 1;
#else
constexpr DWORD kDwmwaSystemBackdropType = DWMWA_SYSTEMBACKDROP_TYPE;
constexpr DWORD kDwmsbtNone = DWMSBT_NONE;
#endif

std::wstring MakeCredTargetName(std::string_view service,
                                std::string_view account) {
  std::string combined =
      "OpenBrowser:" + std::string(service) + ":" + std::string(account);
  return base::UTF8ToWide(combined);
}

std::string HashSecretKeyHex(std::string_view service,
                             std::string_view account) {
  std::string key = std::string(service) + '\0' + std::string(account);
  uint64_t h1 = 14695981039346656037ULL;
  uint64_t h2 = 1099511628211ULL;
  for (unsigned char c : key) {
    h1 = (h1 ^ c) * 1099511628211ULL;
    h2 = (h2 * 1099511628211ULL) ^ c;
  }
  uint8_t bytes[16]{};
  for (int i = 0; i < 8; ++i) {
    bytes[i] = static_cast<uint8_t>((h1 >> (8 * i)) & 0xFFu);
    bytes[8 + i] = static_cast<uint8_t>((h2 >> (8 * i)) & 0xFFu);
  }
  return base::HexEncodeLower(bytes);
}

base::FilePath SecretFilePath(const base::FilePath& data_dir,
                              std::string_view service,
                              std::string_view account) {
  return data_dir.AppendASCII("Secrets")
      .AppendASCII(HashSecretKeyHex(service, account) + ".dpapi");
}

// DPAPI file-backed secret store used when force_file_backend is true or as
// fallback if Credential Manager rejects a secret larger than CRED_MAX_CREDENTIAL_BLOB_SIZE.
class WinDpapiSecretStore final : public SecretStore {
 public:
  explicit WinDpapiSecretStore(base::FilePath data_dir)
      : data_dir_(std::move(data_dir)) {}

  bool SaveSecret(std::string_view service,
                  std::string_view account,
                  const std::vector<uint8_t>& secret) override {
    DATA_BLOB in_blob{};
    in_blob.pbData = const_cast<BYTE*>(secret.data());
    in_blob.cbData = static_cast<DWORD>(secret.size());

    DATA_BLOB entropy{};
    std::string tag = "open-dpapi-v1|" + std::string(service) + "|" +
                      std::string(account);
    entropy.pbData = reinterpret_cast<BYTE*>(tag.data());
    entropy.cbData = static_cast<DWORD>(tag.size());

    DATA_BLOB out_blob{};
    if (!CryptProtectData(&in_blob, L"Open Browser Secret", &entropy, nullptr,
                          nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out_blob)) {
      PLOG(ERROR) << "CryptProtectData failed";
      return false;
    }

    base::FilePath path = SecretFilePath(data_dir_, service, account);
    if (!base::CreateDirectory(path.DirName())) {
      LocalFree(out_blob.pbData);
      return false;
    }
    std::string_view bytes(reinterpret_cast<const char*>(out_blob.pbData),
                           out_blob.cbData);
    bool ok = base::ImportantFileWriter::WriteFileAtomically(path, bytes);
    SecureZeroMemory(out_blob.pbData, out_blob.cbData);
    LocalFree(out_blob.pbData);
    return ok;
  }

  std::optional<std::vector<uint8_t>> LoadSecret(
      std::string_view service,
      std::string_view account) override {
    base::FilePath path = SecretFilePath(data_dir_, service, account);
    std::string ciphertext;
    if (!base::ReadFileToStringWithMaxSize(path, &ciphertext, 1024 * 1024)) {
      return std::nullopt;
    }

    DATA_BLOB in_blob{};
    in_blob.pbData = reinterpret_cast<BYTE*>(ciphertext.data());
    in_blob.cbData = static_cast<DWORD>(ciphertext.size());

    DATA_BLOB entropy{};
    std::string tag = "open-dpapi-v1|" + std::string(service) + "|" +
                      std::string(account);
    entropy.pbData = reinterpret_cast<BYTE*>(tag.data());
    entropy.cbData = static_cast<DWORD>(tag.size());

    DATA_BLOB out_blob{};
    if (!CryptUnprotectData(&in_blob, nullptr, &entropy, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &out_blob)) {
      return std::nullopt;
    }

    std::vector<uint8_t> result(out_blob.pbData,
                                out_blob.pbData + out_blob.cbData);
    SecureZeroMemory(out_blob.pbData, out_blob.cbData);
    LocalFree(out_blob.pbData);
    return result;
  }

  bool DeleteSecret(std::string_view service,
                    std::string_view account) override {
    base::FilePath path = SecretFilePath(data_dir_, service, account);
    if (!base::PathExists(path)) {
      return true;
    }
    return base::DeleteFile(path);
  }

  bool UsesFileBackend() const override { return true; }

 private:
  base::FilePath data_dir_;
};

// Primary Windows secret store using Windows Credential Manager (CredWriteW /
// CredReadW / CredDeleteW) with DPAPI fallback for large blobs (> 2560 bytes).
class WinCredentialManagerSecretStore final : public SecretStore {
 public:
  explicit WinCredentialManagerSecretStore(base::FilePath data_dir)
      : dpapi_fallback_(std::move(data_dir)) {}

  bool SaveSecret(std::string_view service,
                  std::string_view account,
                  const std::vector<uint8_t>& secret) override {
    // Windows Credential Manager blobs cap at CRED_MAX_CREDENTIAL_BLOB_SIZE (2560).
    if (secret.size() > CRED_MAX_CREDENTIAL_BLOB_SIZE) {
      CredDeleteW(MakeCredTargetName(service, account).c_str(),
                  CRED_TYPE_GENERIC, 0);
      used_fallback_ = true;
      return dpapi_fallback_.SaveSecret(service, account, secret);
    }

    std::wstring target = MakeCredTargetName(service, account);
    std::wstring user = base::UTF8ToWide(account);

    CREDENTIALW cred{};
    cred.Type = CRED_TYPE_GENERIC;
    cred.TargetName = target.data();
    cred.CredentialBlobSize = static_cast<DWORD>(secret.size());
    cred.CredentialBlob = const_cast<LPBYTE>(secret.data());
    cred.Persist = CRED_PERSIST_LOCAL_MACHINE;
    cred.UserName = user.data();

    if (CredWriteW(&cred, 0)) {
      used_fallback_ = false;
      dpapi_fallback_.DeleteSecret(service, account);
      return true;
    }
    PLOG(WARNING) << "CredWriteW failed; falling back to DPAPI file";
    // Delete any existing Credential Manager entry before writing the DPAPI
    // fallback file so a stale token can never win on the next LoadSecret().
    CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0);
    used_fallback_ = true;
    return dpapi_fallback_.SaveSecret(service, account, secret);
  }

  std::optional<std::vector<uint8_t>> LoadSecret(
      std::string_view service,
      std::string_view account) override {
    std::wstring target = MakeCredTargetName(service, account);
    PCREDENTIALW cred = nullptr;
    if (CredReadW(target.c_str(), CRED_TYPE_GENERIC, 0, &cred) && cred) {
      std::vector<uint8_t> out;
      if (cred->CredentialBlob && cred->CredentialBlobSize > 0) {
        out.assign(cred->CredentialBlob,
                   cred->CredentialBlob + cred->CredentialBlobSize);
      }
      CredFree(cred);
      return out;
    }
    return dpapi_fallback_.LoadSecret(service, account);
  }

  bool DeleteSecret(std::string_view service,
                    std::string_view account) override {
    std::wstring target = MakeCredTargetName(service, account);
    BOOL deleted_cred = CredDeleteW(target.c_str(), CRED_TYPE_GENERIC, 0);
    DWORD err = GetLastError();
    bool cred_ok = deleted_cred || err == ERROR_NOT_FOUND;
    bool file_ok = dpapi_fallback_.DeleteSecret(service, account);
    return cred_ok && file_ok;
  }

  bool UsesFileBackend() const override { return used_fallback_; }

 private:
  WinDpapiSecretStore dpapi_fallback_;
  bool used_fallback_ = false;
};

// Hidden message-only window that receives WM_HOTKEY notifications.
class WinHotkeyDispatcher {
 public:
  WinHotkeyDispatcher() = default;
  ~WinHotkeyDispatcher() { Shutdown(); }

  void Shutdown() {
    std::lock_guard<std::mutex> lock(mu_);
    if (hwnd_) {
      for (const auto& [atom_id, entry] : entries_) {
        UnregisterHotKey(hwnd_, atom_id);
      }
      entries_.clear();
      id_to_atom_.clear();
      DestroyWindow(hwnd_);
      hwnd_ = nullptr;
    }
    if (class_registered_) {
      UnregisterClassW(kClassName, GetModuleHandleW(nullptr));
      class_registered_ = false;
    }
  }

  bool Register(const GlobalHotkeySpec& spec,
                OpenPlatform::HotkeyCallback callback) {
    std::lock_guard<std::mutex> lock(mu_);
    EnsureWindowLocked();
    if (!hwnd_) {
      return false;
    }
    UnregisterLocked(spec.id);

    UINT win_mods = MOD_NOREPEAT;
    if (spec.modifiers & kHotkeyModAlt) win_mods |= MOD_ALT;
    if (spec.modifiers & kHotkeyModControl) win_mods |= MOD_CONTROL;
    if (spec.modifiers & kHotkeyModShift) win_mods |= MOD_SHIFT;
    if (spec.modifiers & kHotkeyModMeta) win_mods |= MOD_WIN;

    int atom_id = next_atom_id_++;
    if (!RegisterHotKey(hwnd_, atom_id, win_mods, spec.key_code)) {
      PLOG(WARNING) << "RegisterHotKey failed for " << spec.id;
      return false;
    }
    entries_[atom_id] = Entry{spec.id, std::move(callback)};
    id_to_atom_[spec.id] = atom_id;
    return true;
  }

  bool Unregister(std::string_view id) {
    std::lock_guard<std::mutex> lock(mu_);
    return UnregisterLocked(id);
  }

 private:
  static constexpr wchar_t kClassName[] = L"OpenUnifiedHotkeyWindow";

  struct Entry {
    std::string id;
    OpenPlatform::HotkeyCallback callback;
  };

  void EnsureWindowLocked() {
    if (hwnd_) {
      return;
    }
    HINSTANCE instance = GetModuleHandleW(nullptr);
    if (!class_registered_) {
      WNDCLASSEXW wc{};
      wc.cbSize = sizeof(wc);
      wc.lpfnWndProc = &WinHotkeyDispatcher::WndProc;
      wc.hInstance = instance;
      wc.lpszClassName = kClassName;
      if (RegisterClassExW(&wc) ||
          GetLastError() == ERROR_CLASS_ALREADY_EXISTS) {
        class_registered_ = true;
      }
    }
    hwnd_ = CreateWindowExW(0, kClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                            nullptr, instance, this);
    if (hwnd_) {
      SetWindowLongPtrW(hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    }
  }

  bool UnregisterLocked(std::string_view id) {
    auto it = id_to_atom_.find(std::string(id));
    if (it == id_to_atom_.end()) {
      return false;
    }
    int atom_id = it->second;
    if (hwnd_) {
      UnregisterHotKey(hwnd_, atom_id);
    }
    entries_.erase(atom_id);
    id_to_atom_.erase(it);
    return true;
  }

  static LRESULT CALLBACK WndProc(HWND hwnd,
                                  UINT msg,
                                  WPARAM wparam,
                                  LPARAM lparam) {
    if (msg == WM_HOTKEY) {
      auto* self = reinterpret_cast<WinHotkeyDispatcher*>(
          GetWindowLongPtrW(hwnd, GWLP_USERDATA));
      if (self) {
        self->OnHotkey(static_cast<int>(wparam));
      }
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  void OnHotkey(int atom_id) {
    std::string id;
    OpenPlatform::HotkeyCallback cb;
    {
      std::lock_guard<std::mutex> lock(mu_);
      auto it = entries_.find(atom_id);
      if (it == entries_.end()) {
        return;
      }
      id = it->second.id;
      cb = it->second.callback;
    }
    if (cb) {
      cb.Run(id);
    }
  }

  std::mutex mu_;
  HWND hwnd_ = nullptr;
  bool class_registered_ = false;
  int next_atom_id_ = 1;
  std::map<int, Entry> entries_;
  std::map<std::string, int> id_to_atom_;
};

class OpenPlatformWin final : public OpenPlatform {
 public:
  OpenPlatformWin() = default;
  ~OpenPlatformWin() override = default;

  void Shutdown() override { hotkeys_.Shutdown(); }

  std::unique_ptr<SecretStore> CreateSecretStore(
      const base::FilePath& data_dir,
      bool force_file_backend) override {
    if (force_file_backend) {
      return std::make_unique<WinDpapiSecretStore>(data_dir);
    }
    return std::make_unique<WinCredentialManagerSecretStore>(data_dir);
  }

  bool SetDefaultBrowser() override {
    // ShellExecuteW for ms-settings: requires COM STA initialization.
    base::win::ScopedCOMInitializer com_initializer;
    // Windows 10/11 requires users to confirm default browser changes in Settings.
    HINSTANCE result = ShellExecuteW(
        nullptr, L"open", L"ms-settings:defaultapps", nullptr, nullptr,
        SW_SHOWNORMAL);
    return reinterpret_cast<INT_PTR>(result) > 32;
  }

  bool IsDefaultBrowser() override {
    HKEY key = nullptr;
    const wchar_t* subkey =
        L"Software\\Microsoft\\Windows\\Shell\\Associations\\UrlAssociations\\"
        L"https\\UserChoice";
    if (RegOpenKeyExW(HKEY_CURRENT_USER, subkey, 0, KEY_READ, &key) !=
        ERROR_SUCCESS) {
      return false;
    }
    wchar_t prog_id[256]{};
    DWORD size = sizeof(prog_id);
    DWORD type = 0;
    LONG status = RegQueryValueExW(key, L"ProgId", nullptr, &type,
                                   reinterpret_cast<LPBYTE>(prog_id), &size);
    RegCloseKey(key);
    if (status != ERROR_SUCCESS || type != REG_SZ) {
      return false;
    }
    std::wstring value(prog_id);
    return value.find(L"OpenHTML") != std::wstring::npos ||
           value.find(L"OpenBrowser") != std::wstring::npos;
  }

  bool RegisterGlobalHotkey(const GlobalHotkeySpec& spec,
                            HotkeyCallback callback) override {
    return hotkeys_.Register(spec, std::move(callback));
  }

  bool UnregisterGlobalHotkey(std::string_view id) override {
    return hotkeys_.Unregister(id);
  }

  void ApplyWindowEffects(views::Widget* widget, bool dark_mode) override {
    if (!widget) {
      return;
    }
    HWND hwnd = views::HWNDForWidget(widget);
    if (!hwnd || !IsWindow(hwnd)) {
      return;
    }

    BOOL dark = dark_mode ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd, kDwmwaUseImmersiveDarkMode, &dark, sizeof(dark));

    DWORD corner = kDwmwcpRound;
    DwmSetWindowAttribute(hwnd, kDwmwaWindowCornerPreference, &corner,
                          sizeof(corner));

    // Stamp the AppUserModelID so taskbar grouping, jump lists, and pinned
    // shortcuts identify Open Unified consistently.
    ui::win::SetAppIdForWindow(L"OpenBrowser.Open.Unified", hwnd);

    // Ensure frameless windows that support minimize/maximize keep the native
    // WS_MINIMIZEBOX / WS_MAXIMIZEBOX styles needed for Win11 Snap Layouts and
    // Aero Snap (remove_standard_frame strips them in widget_hwnd_utils.cc).
    if (views::WidgetDelegate* delegate = widget->widget_delegate()) {
      LONG_PTR style = GetWindowLongPtrW(hwnd, GWL_STYLE);
      LONG_PTR desired = style;
      if (delegate->CanMinimize()) {
        desired |= WS_MINIMIZEBOX;
      }
      if (delegate->CanMaximize()) {
        desired |= WS_MAXIMIZEBOX;
      }
      if (desired != style) {
        SetWindowLongPtrW(hwnd, GWL_STYLE, desired);
        SetWindowPos(hwnd, nullptr, 0, 0, 0, 0,
                     SWP_FRAMECHANGED | SWP_NOMOVE | SWP_NOSIZE |
                         SWP_NOZORDER | SWP_NOACTIVATE);
      }
    }
  }

  bool UpdateWindowEffects(views::Widget* widget,
                           const WindowMaterialSpec& spec) override {
    if (!widget) {
      return false;
    }
    HWND hwnd = views::HWNDForWidget(widget);
    if (!hwnd || !IsWindow(hwnd)) {
      return false;
    }

    BOOL dark = spec.dark_scheme ? TRUE : FALSE;
    DwmSetWindowAttribute(hwnd, kDwmwaUseImmersiveDarkMode, &dark, sizeof(dark));

    // BrowserDesktopWindowTreeHostWin::ShouldWindowContentsBeTransparent() is
    // false on Windows, so returning true here would composite translucent
    // themes over Chromium's solid frame color instead of DWM Mica. Keep the
    // backdrop off and return false so Open paints its crisp opaque OKLab
    // Space gradient cleanly.
    if (base::win::GetVersion() >= base::win::Version::WIN11_22H2) {
      DWORD backdrop = kDwmsbtNone;
      DwmSetWindowAttribute(hwnd, kDwmwaSystemBackdropType, &backdrop,
                            sizeof(backdrop));
    }
    return false;
  }

  void SetFullscreenCornerState(views::Widget* widget,
                                bool fullscreen) override {
    if (!widget) {
      return;
    }
    HWND hwnd = views::HWNDForWidget(widget);
    if (!hwnd || !IsWindow(hwnd)) {
      return;
    }
    DWORD corner = fullscreen ? kDwmwcpDoNotRound : kDwmwcpRound;
    DwmSetWindowAttribute(hwnd, kDwmwaWindowCornerPreference, &corner,
                          sizeof(corner));
  }

  int MaximizedFrameInsetDip(views::Widget* widget) const override {
    if (!widget) {
      return 0;
    }
    HWND hwnd = views::HWNDForWidget(widget);
    if (!hwnd || !IsWindow(hwnd)) {
      return 0;
    }
    const UINT dpi = GetDpiForWindow(hwnd);
    const UINT effective_dpi = dpi > 0 ? dpi : 96;
    const int px = GetSystemMetricsForDpi(SM_CXSIZEFRAME, effective_dpi) +
                   GetSystemMetricsForDpi(SM_CXPADDEDBORDER, effective_dpi);
    const float scale = static_cast<float>(effective_dpi) / 96.0f;
    return static_cast<int>(std::floor(static_cast<float>(px) / scale));
  }

  base::FilePath GetDefaultUserDataDir() override {
    PWSTR local_app_data = nullptr;
    if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr,
                                       &local_app_data)) &&
        local_app_data) {
      base::FilePath dir(local_app_data);
      CoTaskMemFree(local_app_data);
      return dir.AppendASCII("Open");
    }
    wchar_t env_buf[MAX_PATH]{};
    DWORD len = GetEnvironmentVariableW(L"LOCALAPPDATA", env_buf, MAX_PATH);
    if (len > 0 && len < MAX_PATH) {
      return base::FilePath(env_buf).AppendASCII("Open");
    }
    return base::FilePath(FILE_PATH_LITERAL("Open"));
  }

  std::string GetDeviceName() override {
    wchar_t buf[MAX_COMPUTERNAME_LENGTH + 1]{};
    DWORD size = MAX_COMPUTERNAME_LENGTH + 1;
    if (GetComputerNameW(buf, &size) && size > 0) {
      return base::WideToUTF8(std::wstring_view(buf, size));
    }
    return "Windows PC";
  }

  std::string GetSyncPlatformName() override { return "windows"; }

  // Windows' closest match to macOS "Increase contrast": a High Contrast
  // (Contrast themes) scheme is on.
  bool IsIncreaseContrastEnabled() override {
    HIGHCONTRASTW hc{};
    hc.cbSize = sizeof(hc);
    return SystemParametersInfoW(SPI_GETHIGHCONTRAST, sizeof(hc), &hc, 0) &&
           (hc.dwFlags & HCF_HIGHCONTRASTON);
  }

 private:
  WinHotkeyDispatcher hotkeys_;
};

}  // namespace

// --- OpenPlatform base defaults (OpenPlatformWin overrides
// UpdateWindowEffects and IsIncreaseContrastEnabled; Windows has no movable
// traffic lights or per-app URL source). ------------------------------------

bool OpenPlatform::UpdateWindowEffects(views::Widget*,
                                       const WindowMaterialSpec&) {
  return false;
}

void OpenPlatform::PlaceWindowButtons(views::Widget*,
                                      const gfx::Point&,
                                      bool,
                                      bool) {}

void OpenPlatform::SetWindowButtonsTone(views::Widget*, bool, bool) {}

bool OpenPlatform::IsIncreaseContrastEnabled() {
  return false;
}

bool OpenPlatform::SetAppIcon(const std::string&) {
  return false;
}

std::string OpenPlatform::ResolveExternalUrlSourceApp() {
  return std::string();
}

// static
OpenPlatform* OpenPlatform::Get() {
  static base::NoDestructor<OpenPlatformWin> instance;
  return instance.get();
}

}  // namespace open_unified
