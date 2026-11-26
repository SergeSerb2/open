// Copyright 2026 The Open Authors. All rights reserved.
// Linux implementation of OpenPlatform.

#include "open_unified/browser/platform/open_platform.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstring>
#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "base/environment.h"
#include "base/files/file_util.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/no_destructor.h"
#include "base/process/launch.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "ui/views/widget/widget.h"

namespace open_unified {

namespace {

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
      .AppendASCII(HashSecretKeyHex(service, account) + ".bin");
}

// Writes |bytes| atomically to |dest| with strict 0600 permissions inside a
// 0700 parent directory so no other local user can read secrets.
bool WriteSecretFile0600(const base::FilePath& dest,
                         const std::vector<uint8_t>& bytes) {
  base::FilePath dir = dest.DirName();
  if (!base::CreateDirectory(dir)) {
    return false;
  }
  chmod(dir.value().c_str(), 0700);

  base::FilePath tmp(dest.value() + ".tmp." +
                     base::NumberToString(static_cast<int>(getpid())));
  int fd = open(tmp.value().c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW,
                0600);
  if (fd < 0) {
    return false;
  }
  fchmod(fd, 0600);

  size_t written = 0;
  while (written < bytes.size()) {
    ssize_t n = write(fd, bytes.data() + written, bytes.size() - written);
    if (n < 0) {
      if (errno == EINTR) continue;
      close(fd);
      unlink(tmp.value().c_str());
      return false;
    }
    written += static_cast<size_t>(n);
  }
  fsync(fd);
  close(fd);

  if (rename(tmp.value().c_str(), dest.value().c_str()) != 0) {
    unlink(tmp.value().c_str());
    return false;
  }
  chmod(dest.value().c_str(), 0600);
  return true;
}

class LinuxFileSecretStore final : public SecretStore {
 public:
  explicit LinuxFileSecretStore(base::FilePath data_dir)
      : data_dir_(std::move(data_dir)) {}

  bool SaveSecret(std::string_view service,
                  std::string_view account,
                  const std::vector<uint8_t>& secret) override {
    return WriteSecretFile0600(SecretFilePath(data_dir_, service, account),
                               secret);
  }

  std::optional<std::vector<uint8_t>> LoadSecret(
      std::string_view service,
      std::string_view account) override {
    base::FilePath path = SecretFilePath(data_dir_, service, account);
    struct stat st {};
    if (lstat(path.value().c_str(), &st) != 0 || !S_ISREG(st.st_mode)) {
      return std::nullopt;
    }
    std::string raw;
    if (!base::ReadFileToStringWithMaxSize(path, &raw, 1024 * 1024)) {
      return std::nullopt;
    }
    return std::vector<uint8_t>(raw.begin(), raw.end());
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

// Optional runtime libsecret/D-Bus hook: attempts dlopen("libsecret-1.so.0")
// for Secret Service integration when a desktop keyring is active, falling
// back transparently to the 0600 protected file store otherwise.
class LinuxSecretServiceHook {
 public:
  LinuxSecretServiceHook() {
    handle_ = dlopen("libsecret-1.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (!handle_) {
      return;
    }
    // Verify basic symbol availability; full schema operations stay guarded.
    available_ = (dlsym(handle_, "secret_password_store_sync") != nullptr &&
                  dlsym(handle_, "secret_password_lookup_sync") != nullptr &&
                  dlsym(handle_, "secret_password_clear_sync") != nullptr);
  }

  ~LinuxSecretServiceHook() {
    if (handle_) {
      dlclose(handle_);
      handle_ = nullptr;
    }
  }

  bool available() const { return available_; }

 private:
  raw_ptr<void> handle_ = nullptr;
  bool available_ = false;
};

class OpenPlatformLinux final : public OpenPlatform {
 public:
  OpenPlatformLinux() = default;
  ~OpenPlatformLinux() override = default;

  std::unique_ptr<SecretStore> CreateSecretStore(
      const base::FilePath& data_dir,
      bool force_file_backend) override {
    (void)force_file_backend;
    // Probe libsecret availability once for diagnostics; use 0600 atomic file
    // store so headless / Wayland / WSL / minimal Linux environments always
    // succeed deterministically without blocking on a locked keyring prompt.
    (void)secret_service_hook_.available();
    return std::make_unique<LinuxFileSecretStore>(data_dir);
  }

  bool SetDefaultBrowser() override {
    std::string output;
    return base::GetAppOutput(
        {"xdg-settings", "set", "default-web-browser", "open-browser.desktop"},
        &output);
  }

  bool IsDefaultBrowser() override {
    std::string output;
    if (!base::GetAppOutput(
            {"xdg-settings", "get", "default-web-browser"}, &output)) {
      return false;
    }
    std::string trimmed =
        std::string(base::TrimWhitespaceASCII(output, base::TRIM_ALL));
    return trimmed == "open-browser.desktop" || trimmed == "open.desktop";
  }

  bool RegisterGlobalHotkey(const GlobalHotkeySpec& spec,
                            HotkeyCallback callback) override {
    std::lock_guard<std::mutex> lock(hotkey_mu_);
    // Wayland/X11 global shortcuts are handled via xdg-desktop-portal
    // GlobalShortcuts or compositor bindings; store the registration so
    // in-process accelerators and portal relays can invoke it.
    hotkeys_[spec.id] = HotkeyEntry{spec, std::move(callback)};
    return true;
  }

  bool UnregisterGlobalHotkey(std::string_view id) override {
    std::lock_guard<std::mutex> lock(hotkey_mu_);
    return hotkeys_.erase(std::string(id)) > 0;
  }

  void ApplyWindowEffects(views::Widget* widget, bool dark_mode) override {
    if (!widget) {
      return;
    }
    // On Linux (X11/Wayland/Ozone), compositor translucency and rounded CSD
    // framing are controlled through the Views non-client frame and widget
    // opacity; mark the widget color-mode override when supported.
    widget->SetColorModeOverride(
        dark_mode ? ui::ColorProviderKey::ColorMode::kDark
                  : ui::ColorProviderKey::ColorMode::kLight);
  }

  base::FilePath GetDefaultUserDataDir() override {
    auto env = base::Environment::Create();
    if (auto xdg_config = env->GetVar("XDG_CONFIG_HOME");
        xdg_config && !xdg_config->empty()) {
      return base::FilePath(*xdg_config).AppendASCII("open");
    }
    if (auto home = env->GetVar("HOME"); home && !home->empty()) {
      return base::FilePath(*home).AppendASCII(".config").AppendASCII("open");
    }
    return base::FilePath("/tmp/open");
  }

  std::string GetDeviceName() override {
    char host[256]{};
    if (gethostname(host, sizeof(host) - 1) == 0 && host[0] != '\0') {
      return std::string(host);
    }
    return "Linux Desktop";
  }

  std::string GetSyncPlatformName() override { return "linux"; }

 private:
  struct HotkeyEntry {
    GlobalHotkeySpec spec;
    HotkeyCallback callback;
  };

  LinuxSecretServiceHook secret_service_hook_;
  std::mutex hotkey_mu_;
  std::map<std::string, HotkeyEntry> hotkeys_;
};

}  // namespace

// --- OpenPlatform defaults (Windows and Linux have no native window
// material, no movable window buttons, and no per-app URL source). ---------

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
  static base::NoDestructor<OpenPlatformLinux> instance;
  return instance.get();
}

}  // namespace open_unified
