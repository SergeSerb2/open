// Copyright 2026 The Open Authors. All rights reserved.
// Windows implementation of OpenPlatform.

#include "open_unified/browser/platform/open_platform.h"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstring>
#include <cwchar>
#include <iterator>
#include <map>
#include <mutex>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "base/strings/utf_string_conversions.h"
#include "base/win/scoped_com_initializer.h"
#include "base/win/scoped_gdi_object.h"
#include "base/win/windows_version.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkCanvas.h"
#include "third_party/skia/include/core/SkColor.h"
#include "third_party/skia/include/core/SkPaint.h"
#include "third_party/skia/include/core/SkPath.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "third_party/skia/include/core/SkRect.h"
#include "third_party/skia/include/effects/SkGradient.h"
#include "ui/base/win/shell.h"
#include "ui/gfx/win/icon_util.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/win/hwnd_util.h"

#include <windows.h>

#include <dwmapi.h>
#include <shellapi.h>
#include <shlobj.h>
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

constexpr wchar_t kHotkeyWindowClassName[] = L"OpenUnifiedHotkeyWindow";

std::wstring GetCurrentExecutablePath() {
  std::wstring buf(MAX_PATH, L'\0');
  for (;;) {
    DWORD len =
        GetModuleFileNameW(nullptr, buf.data(), static_cast<DWORD>(buf.size()));
    if (len == 0) {
      return {};
    }
    if (len < buf.size()) {
      buf.resize(len);
      return buf;
    }
    if (buf.size() >= 32768) {
      return {};
    }
    buf.resize(buf.size() * 2, L'\0');
  }
}

bool WriteRegistrySz(HKEY root,
                     const wchar_t* subkey,
                     const wchar_t* value_name,
                     const std::wstring& value) {
  HKEY key = nullptr;
  LONG create_status = RegCreateKeyExW(
      root, subkey, 0, nullptr, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr,
      &key, nullptr);
  if (create_status != ERROR_SUCCESS || !key) {
    LOG(WARNING) << "RegCreateKeyExW failed (" << create_status << ")";
    return false;
  }
  const DWORD byte_len =
      static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t));
  LONG set_status = RegSetValueExW(
      key, value_name, 0, REG_SZ,
      reinterpret_cast<const BYTE*>(value.c_str()), byte_len);
  RegCloseKey(key);
  if (set_status != ERROR_SUCCESS) {
    LOG(WARNING) << "RegSetValueExW failed (" << set_status << ")";
    return false;
  }
  return true;
}

bool EnsureUrlProtocolRegistration() {
  const std::wstring exe_path = GetCurrentExecutablePath();
  if (exe_path.empty()) {
    PLOG(WARNING) << "GetModuleFileNameW failed during default browser "
                     "registration";
    return false;
  }

  const std::wstring icon_ref = exe_path + L",0";
  const std::wstring open_cmd = L"\"" + exe_path + L"\" -- \"%1\"";
  const std::wstring launch_cmd = L"\"" + exe_path + L"\"";

  bool ok = true;
  ok &= WriteRegistrySz(HKEY_CURRENT_USER, L"Software\\Classes\\OpenHTML",
                        nullptr, L"Open HTML Document");
  ok &= WriteRegistrySz(HKEY_CURRENT_USER, L"Software\\Classes\\OpenHTML",
                        L"FriendlyTypeName", L"Open HTML Document");
  ok &= WriteRegistrySz(HKEY_CURRENT_USER,
                        L"Software\\Classes\\OpenHTML\\DefaultIcon", nullptr,
                        icon_ref);
  ok &= WriteRegistrySz(HKEY_CURRENT_USER,
                        L"Software\\Classes\\OpenHTML\\shell\\open\\command",
                        nullptr, open_cmd);

  ok &= WriteRegistrySz(HKEY_CURRENT_USER,
                        L"Software\\Clients\\StartMenuInternet\\Open", nullptr,
                        L"Open");
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\DefaultIcon", nullptr,
      icon_ref);
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\shell\\open\\command",
      nullptr, launch_cmd);
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\Capabilities",
      L"ApplicationName", L"Open");
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\Capabilities",
      L"ApplicationDescription", L"Open Web Browser");
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\Capabilities",
      L"ApplicationIcon", icon_ref);
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\Capabilities\\"
      L"URLAssociations",
      L"http", L"OpenHTML");
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\Capabilities\\"
      L"URLAssociations",
      L"https", L"OpenHTML");
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\Capabilities\\"
      L"FileAssociations",
      L".htm", L"OpenHTML");
  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER,
      L"Software\\Clients\\StartMenuInternet\\Open\\Capabilities\\"
      L"FileAssociations",
      L".html", L"OpenHTML");

  ok &= WriteRegistrySz(
      HKEY_CURRENT_USER, L"Software\\RegisteredApplications", L"Open",
      L"Software\\Clients\\StartMenuInternet\\Open\\Capabilities");

  if (ok) {
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
  }
  return ok;
}

struct AppIconPalette {
  std::string_view id;
  SkColor stops[3];
  float positions[3];
  size_t count;
};

constexpr std::array<AppIconPalette, 6> kAppIconPalettes = {{
    {"open-indigo",
     {SkColorSetRGB(0x3B, 0x3F, 0xD8), SkColorSetRGB(0x64, 0x57, 0xF0),
      SkColorSetRGB(0xF2, 0xA3, 0x5E)},
     {0.0f, 0.55f, 1.0f},
     3},
    {"open-obsidian",
     {SkColorSetRGB(0x17, 0x17, 0x1F), SkColorSetRGB(0x34, 0x36, 0x4A), 0},
     {0.0f, 1.0f, 1.0f},
     2},
    {"open-sunburst",
     {SkColorSetRGB(0xF7, 0xB4, 0x55), SkColorSetRGB(0xEF, 0x5D, 0x3B), 0},
     {0.0f, 1.0f, 1.0f},
     2},
    {"open-sage",
     {SkColorSetRGB(0x3F, 0xB6, 0x8B), SkColorSetRGB(0x14, 0x6B, 0x52), 0},
     {0.0f, 1.0f, 1.0f},
     2},
    {"open-slate",
     {SkColorSetRGB(0x83, 0x90, 0xA6), SkColorSetRGB(0x3A, 0x44, 0x56), 0},
     {0.0f, 1.0f, 1.0f},
     2},
    {"open-dawn",
     {SkColorSetRGB(0xF0, 0x8D, 0xB4), SkColorSetRGB(0x8C, 0x63, 0xE6), 0},
     {0.0f, 1.0f, 1.0f},
     2},
}};

const AppIconPalette* FindAppIconPalette(std::string_view icon_id) {
  std::string_view target = icon_id.empty() ? "open-indigo" : icon_id;
  for (const AppIconPalette& palette : kAppIconPalettes) {
    if (palette.id == target) {
      return &palette;
    }
  }
  return nullptr;
}

SkBitmap RenderAppIconBitmap(const AppIconPalette& palette, int size) {
  SkBitmap bitmap;
  if (size <= 0 || !bitmap.tryAllocN32Pixels(size, size)) {
    return bitmap;
  }
  bitmap.eraseColor(SK_ColorTRANSPARENT);

  SkCanvas canvas(bitmap);
  const float s = static_cast<float>(size);
  const float radius = s * 0.22f;

  // 140deg CSS linear gradient direction: (sin(140deg), -cos(140deg)).
  constexpr float kDx = 0.6427876f;
  constexpr float kDy = 0.7660444f;
  const float half_len = s * 0.5f * (kDx + kDy);
  const SkPoint pts[2] = {
      SkPoint::Make(s * 0.5f - kDx * half_len, s * 0.5f - kDy * half_len),
      SkPoint::Make(s * 0.5f + kDx * half_len, s * 0.5f + kDy * half_len),
  };

  std::vector<SkColor4f> colors;
  std::vector<float> pos;
  colors.reserve(palette.count);
  pos.reserve(palette.count);
  for (size_t i = 0; i < palette.count; ++i) {
    colors.push_back(SkColor4f::FromColor(palette.stops[i]));
    pos.push_back(palette.positions[i]);
  }

  SkPaint bg_paint;
  bg_paint.setAntiAlias(true);
  SkGradient grad(SkGradient::Colors(colors, pos, SkTileMode::kClamp),
                  SkGradient::Interpolation{});
  bg_paint.setShader(SkShaders::LinearGradient(pts, grad));
  canvas.drawRRect(SkRRect::MakeRectXY(SkRect::MakeIWH(size, size), radius,
                                       radius),
                   bg_paint);

  // Open doorway-and-sun mark scaled from the 40x40 Settings artwork.
  const float scale = s / 40.0f;
  SkPathBuilder doorway;
  doorway.moveTo(12.0f * scale, 33.0f * scale);
  doorway.lineTo(12.0f * scale, 18.5f * scale);
  doorway.cubicTo(12.0f * scale, 13.8f * scale, 15.6f * scale, 10.0f * scale,
                  20.0f * scale, 10.0f * scale);
  doorway.cubicTo(24.4f * scale, 10.0f * scale, 28.0f * scale, 13.8f * scale,
                  28.0f * scale, 18.5f * scale);
  doorway.lineTo(28.0f * scale, 33.0f * scale);
  doorway.close();
  const SkPath doorway_path = doorway.detach();

  SkPaint doorway_fill;
  doorway_fill.setAntiAlias(true);
  doorway_fill.setStyle(SkPaint::kFill_Style);
  doorway_fill.setColor(SkColorSetARGB(46, 255, 255, 255));
  canvas.drawPath(doorway_path, doorway_fill);

  SkPaint doorway_stroke;
  doorway_stroke.setAntiAlias(true);
  doorway_stroke.setStyle(SkPaint::kStroke_Style);
  doorway_stroke.setStrokeWidth(std::max(1.25f, 2.0f * scale));
  doorway_stroke.setStrokeJoin(SkPaint::kRound_Join);
  doorway_stroke.setStrokeCap(SkPaint::kRound_Cap);
  doorway_stroke.setColor(SK_ColorWHITE);
  canvas.drawPath(doorway_path, doorway_stroke);

  SkPaint sun_paint;
  sun_paint.setAntiAlias(true);
  sun_paint.setStyle(SkPaint::kFill_Style);
  sun_paint.setColor(SkColorSetRGB(0xFF, 0xE9, 0xB8));
  canvas.drawCircle(20.0f * scale, 23.0f * scale, 3.6f * scale, sun_paint);

  bitmap.setImmutable();
  return bitmap;
}

struct ApplyIconEnumContext {
  DWORD process_id = 0;
  HICON big_icon = nullptr;
  HICON small_icon = nullptr;
};

BOOL CALLBACK ApplyIconToProcessWindowProc(HWND hwnd, LPARAM lparam) {
  auto* ctx = reinterpret_cast<ApplyIconEnumContext*>(lparam);
  if (!ctx || !IsWindow(hwnd)) {
    return TRUE;
  }
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid != ctx->process_id) {
    return TRUE;
  }
  // Skip tool windows and our hidden hotkey dispatcher class.
  const LONG_PTR ex_style = GetWindowLongPtrW(hwnd, GWL_EXSTYLE);
  if (ex_style & WS_EX_TOOLWINDOW) {
    return TRUE;
  }
  wchar_t class_name[64]{};
  if (GetClassNameW(hwnd, class_name,
                    static_cast<int>(std::size(class_name))) > 0 &&
      wcscmp(class_name, kHotkeyWindowClassName) == 0) {
    return TRUE;
  }
  SendMessageW(hwnd, WM_SETICON, ICON_BIG,
               reinterpret_cast<LPARAM>(ctx->big_icon));
  SendMessageW(hwnd, WM_SETICON, ICON_SMALL,
               reinterpret_cast<LPARAM>(ctx->small_icon));
  return TRUE;
}

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
      UnregisterClassW(kHotkeyWindowClassName, GetModuleHandleW(nullptr));
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
      wc.lpszClassName = kHotkeyWindowClassName;
      if (RegisterClassExW(&wc) ||
          GetLastError() == ERROR_CLASS_ALREADY_EXISTS) {
        class_registered_ = true;
      }
    }
    hwnd_ = CreateWindowExW(0, kHotkeyWindowClassName, L"", 0, 0, 0, 0, 0,
                            HWND_MESSAGE, nullptr, instance, this);
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
  ~OpenPlatformWin() override { Shutdown(); }

  void Shutdown() override {
    hotkeys_.Shutdown();
    base::win::ScopedGDIObject<HICON> old_big;
    base::win::ScopedGDIObject<HICON> old_small;
    {
      std::lock_guard<std::mutex> lock(icon_mu_);
      old_big = std::move(current_big_icon_);
      old_small = std::move(current_small_icon_);
    }
    if (old_big.is_valid() || old_small.is_valid()) {
      ApplyIconEnumContext ctx{GetCurrentProcessId(), nullptr, nullptr};
      EnumWindows(&ApplyIconToProcessWindowProc,
                  reinterpret_cast<LPARAM>(&ctx));
    }
  }

  std::unique_ptr<SecretStore> CreateSecretStore(
      const base::FilePath& data_dir,
      bool force_file_backend) override {
    if (force_file_backend) {
      return std::make_unique<WinDpapiSecretStore>(data_dir);
    }
    return std::make_unique<WinCredentialManagerSecretStore>(data_dir);
  }

  bool SetDefaultBrowser() override {
    // Register Open's ProgID, StartMenuInternet entry, and Capabilities in
    // HKCU before launching Default Apps so Windows lists Open as a selectable
    // HTTP/HTTPS handler.
    EnsureUrlProtocolRegistration();

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

    // Apply the active custom app icon to newly created top-level windows.
    HICON big_icon = nullptr;
    HICON small_icon = nullptr;
    {
      std::lock_guard<std::mutex> lock(icon_mu_);
      big_icon = current_big_icon_.get();
      small_icon = current_small_icon_.get();
    }
    if (big_icon) {
      SendMessageW(hwnd, WM_SETICON, ICON_BIG,
                   reinterpret_cast<LPARAM>(big_icon));
    }
    if (small_icon) {
      SendMessageW(hwnd, WM_SETICON, ICON_SMALL,
                   reinterpret_cast<LPARAM>(small_icon));
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

  bool SetAppIcon(const std::string& icon_id) override {
    const AppIconPalette* palette = FindAppIconPalette(icon_id);
    if (!palette) {
      return false;
    }

    const int big_size = std::max(32, GetSystemMetrics(SM_CXICON));
    const int small_size = std::max(16, GetSystemMetrics(SM_CXSMICON));
    base::win::ScopedGDIObject<HICON> new_big;
    base::win::ScopedGDIObject<HICON> new_small;

    if (icon_id.empty() || icon_id == "open-indigo") {
      // Prefer the executable's embedded icon resource for the default icon.
      HMODULE module = GetModuleHandleW(nullptr);
      new_big.reset(static_cast<HICON>(LoadImageW(
          module, MAKEINTRESOURCEW(101), IMAGE_ICON, big_size, big_size,
          LR_DEFAULTCOLOR)));
      new_small.reset(static_cast<HICON>(LoadImageW(
          module, MAKEINTRESOURCEW(101), IMAGE_ICON, small_size, small_size,
          LR_DEFAULTCOLOR)));
      if (!new_big.is_valid() || !new_small.is_valid()) {
        const std::wstring exe_path = GetCurrentExecutablePath();
        if (!exe_path.empty()) {
          HICON extracted_big = nullptr;
          HICON extracted_small = nullptr;
          if (ExtractIconExW(exe_path.c_str(), 0, &extracted_big,
                             &extracted_small, 1) > 0) {
            if (!new_big.is_valid() && extracted_big) {
              new_big.reset(extracted_big);
            } else if (extracted_big) {
              DestroyIcon(extracted_big);
            }
            if (!new_small.is_valid() && extracted_small) {
              new_small.reset(extracted_small);
            } else if (extracted_small) {
              DestroyIcon(extracted_small);
            }
          }
        }
      }
    }

    if (!new_big.is_valid()) {
      SkBitmap big_bmp = RenderAppIconBitmap(*palette, big_size);
      if (!big_bmp.isNull()) {
        new_big = IconUtil::CreateHICONFromSkBitmap(big_bmp);
      }
    }
    if (!new_small.is_valid()) {
      SkBitmap small_bmp = RenderAppIconBitmap(*palette, small_size);
      if (!small_bmp.isNull()) {
        new_small = IconUtil::CreateHICONFromSkBitmap(small_bmp);
      }
    }
    if (!new_big.is_valid() && !new_small.is_valid()) {
      return false;
    }

    HICON big_raw = new_big.get();
    HICON small_raw = new_small.get();
    // Retain old handles until every top-level window has switched to the new
    // icons so no window ever holds a destroyed HICON.
    base::win::ScopedGDIObject<HICON> old_big;
    base::win::ScopedGDIObject<HICON> old_small;
    {
      std::lock_guard<std::mutex> lock(icon_mu_);
      old_big = std::move(current_big_icon_);
      old_small = std::move(current_small_icon_);
      current_big_icon_ = std::move(new_big);
      current_small_icon_ = std::move(new_small);
    }

    ApplyIconEnumContext ctx{GetCurrentProcessId(), big_raw, small_raw};
    EnumWindows(&ApplyIconToProcessWindowProc, reinterpret_cast<LPARAM>(&ctx));
    return true;
  }

  std::string ResolveExternalUrlSourceApp() override {
    HWND fg = GetForegroundWindow();
    if (!fg) {
      return {};
    }
    DWORD pid = 0;
    GetWindowThreadProcessId(fg, &pid);
    if (pid == 0 || pid == GetCurrentProcessId()) {
      return {};
    }
    HANDLE process =
        OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) {
      return {};
    }
    std::wstring image_path(1024, L'\0');
    DWORD length = static_cast<DWORD>(image_path.size());
    BOOL ok =
        QueryFullProcessImageNameW(process, 0, image_path.data(), &length);
    CloseHandle(process);
    if (!ok || length == 0) {
      return {};
    }
    image_path.resize(length);
    base::FilePath exe_path(image_path);
    std::string basename = base::WideToUTF8(exe_path.BaseName().value());
    return base::ToLowerASCII(basename);
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
  std::mutex icon_mu_;
  base::win::ScopedGDIObject<HICON> current_big_icon_;
  base::win::ScopedGDIObject<HICON> current_small_icon_;
};

}  // namespace

// --- OpenPlatform base defaults (OpenPlatformWin overrides
// UpdateWindowEffects, IsIncreaseContrastEnabled, SetAppIcon, and
// ResolveExternalUrlSourceApp; Windows has no movable traffic lights). ------

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
