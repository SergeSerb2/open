// Copyright 2026 The Open Authors. All rights reserved.
// Linux implementation of OpenPlatform.

#include "open_unified/browser/platform/open_platform.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <array>
#include <cerrno>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <string>
#include <string_view>
#include <utility>
#include <vector>

#include "base/base64.h"
#include "base/base_paths.h"
#include "base/environment.h"
#include "base/files/file_util.h"
#include "base/files/important_file_writer.h"
#include "base/logging.h"
#include "base/memory/raw_ptr.h"
#include "base/memory/raw_ptr_exclusion.h"
#include "base/no_destructor.h"
#include "base/path_service.h"
#include "base/process/launch.h"
#include "base/scoped_multi_source_observation.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/string_util.h"
#include "third_party/skia/include/core/SkBitmap.h"
#include "third_party/skia/include/core/SkCanvas.h"
#include "third_party/skia/include/core/SkColor.h"
#include "third_party/skia/include/core/SkPaint.h"
#include "third_party/skia/include/core/SkPath.h"
#include "third_party/skia/include/core/SkPathBuilder.h"
#include "third_party/skia/include/core/SkRRect.h"
#include "third_party/skia/include/core/SkRect.h"
#include "third_party/skia/include/effects/SkGradient.h"
#include "ui/base/models/image_model.h"
#include "ui/gfx/image/image_skia.h"
#include "ui/gfx/image/image_skia_rep.h"
#include "ui/linux/linux_ui.h"
#include "ui/views/widget/native_widget_private.h"
#include "ui/views/widget/widget.h"
#include "ui/views/widget/widget_delegate.h"
#include "ui/views/widget/widget_observer.h"
#include "ui/views/window/frame_buttons.h"
#include "ui/views/window/window_button_order_provider.h"

namespace open_unified {

namespace {

constexpr char kLibSecretPrefix[] = "b64:";
constexpr char kSecretCollectionDefault[] = "default";

// Exact C ABI mirror of libsecret's SecretSchemaAttribute / SecretSchema
// (see third_party/libsecret/libsecret/secret-schema.h) and GLib's GError.
struct LibSecretSchemaAttribute {
  RAW_PTR_EXCLUSION const char* name;
  int type;  // SecretSchemaAttributeType: 0 = STRING
};

struct LibSecretSchema {
  RAW_PTR_EXCLUSION const char* name;
  int flags;  // SecretSchemaFlags: 0 = SECRET_SCHEMA_NONE
  LibSecretSchemaAttribute attributes[32];

  // <private>
  int reserved;
  RAW_PTR_EXCLUSION void* reserved1;
  RAW_PTR_EXCLUSION void* reserved2;
  RAW_PTR_EXCLUSION void* reserved3;
  RAW_PTR_EXCLUSION void* reserved4;
  RAW_PTR_EXCLUSION void* reserved5;
  RAW_PTR_EXCLUSION void* reserved6;
  RAW_PTR_EXCLUSION void* reserved7;
};

struct LibGError {
  uint32_t domain;
  int code;
  RAW_PTR_EXCLUSION char* message;
};

constexpr LibSecretSchema kOpenSecretSchema = {
    "org.openbrowser.open.secret",
    /*SECRET_SCHEMA_NONE=*/0,
    {
        {"service", /*SECRET_SCHEMA_ATTRIBUTE_STRING=*/0},
        {"account", /*SECRET_SCHEMA_ATTRIBUTE_STRING=*/0},
        {nullptr, 0},
    },
    0,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
    nullptr,
};

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

gfx::ImageSkia BuildAppIconImageSkia(const AppIconPalette& palette,
                                     int dip_size) {
  gfx::ImageSkia image;
  SkBitmap bmp_1x = RenderAppIconBitmap(palette, dip_size);
  if (!bmp_1x.isNull()) {
    image.AddRepresentation(gfx::ImageSkiaRep(bmp_1x, 1.0f));
  }
  SkBitmap bmp_2x = RenderAppIconBitmap(palette, dip_size * 2);
  if (!bmp_2x.isNull()) {
    image.AddRepresentation(gfx::ImageSkiaRep(bmp_2x, 2.0f));
  }
  return image;
}

std::string EscapeDesktopExecArg(std::string_view arg) {
  bool needs_quoting = arg.empty();
  for (char c : arg) {
    if (c == ' ' || c == '\t' || c == '\n' || c == '"' || c == '\'' ||
        c == '\\' || c == '>' || c == '<' || c == '~' || c == '|' ||
        c == '&' || c == ';' || c == '$' || c == '*' || c == '?' ||
        c == '#' || c == '(' || c == ')' || c == '`') {
      needs_quoting = true;
      break;
    }
  }
  if (!needs_quoting) {
    return std::string(arg);
  }
  std::string quoted;
  quoted.reserve(arg.size() + 4);
  quoted.push_back('"');
  for (char c : arg) {
    if (c == '"' || c == '`' || c == '$' || c == '\\') {
      quoted.push_back('\\');
    }
    quoted.push_back(c);
  }
  quoted.push_back('"');
  return quoted;
}

base::FilePath GetXdgDataHome() {
  auto env = base::Environment::Create();
  if (auto xdg_data = env->GetVar("XDG_DATA_HOME");
      xdg_data && !xdg_data->empty()) {
    return base::FilePath(*xdg_data);
  }
  if (auto home = env->GetVar("HOME"); home && !home->empty()) {
    return base::FilePath(*home).AppendASCII(".local").AppendASCII("share");
  }
  return base::FilePath();
}

void EnsureDesktopIntegrationFiles() {
  const base::FilePath data_home = GetXdgDataHome();
  if (data_home.empty()) {
    return;
  }
  const base::FilePath exe_path = base::PathService::CheckedGet(base::FILE_EXE);
  if (exe_path.empty()) {
    return;
  }

  const base::FilePath apps_dir = data_home.AppendASCII("applications");
  if (base::CreateDirectory(apps_dir)) {
    const base::FilePath desktop_file =
        apps_dir.AppendASCII("open-browser.desktop");
    const std::string desktop_contents =
        "[Desktop Entry]\n"
        "Version=1.0\n"
        "Name=Open\n"
        "GenericName=Web Browser\n"
        "Comment=Browse the Web with Open\n"
        "Exec=" +
        EscapeDesktopExecArg(exe_path.value()) +
        " %U\n"
        "Terminal=false\n"
        "Type=Application\n"
        "Icon=open-browser\n"
        "Categories=Network;WebBrowser;\n"
        "MimeType=text/html;text/xml;application/xhtml+xml;"
        "x-scheme-handler/http;x-scheme-handler/https;\n"
        "StartupNotify=true\n"
        "StartupWMClass=open-browser\n";
    if (!base::ImportantFileWriter::WriteFileAtomically(desktop_file,
                                                        desktop_contents)) {
      LOG(WARNING) << "Failed to write " << desktop_file;
    }
  }

  const base::FilePath src_icon = exe_path.DirName()
                                      .AppendASCII("icons")
                                      .AppendASCII("product_logo_256.png");
  if (base::PathExists(src_icon)) {
    const base::FilePath icon_dir = data_home.AppendASCII("icons")
                                        .AppendASCII("hicolor")
                                        .AppendASCII("256x256")
                                        .AppendASCII("apps");
    if (base::CreateDirectory(icon_dir)) {
      const base::FilePath dst_icon = icon_dir.AppendASCII("open-browser.png");
      if (!base::CopyFile(src_icon, dst_icon)) {
        LOG(WARNING) << "Failed to copy " << src_icon << " to " << dst_icon;
      }
    }
  }
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

// Runtime libsecret/D-Bus loader: attempts dlopen("libsecret-1.so.0") for
// Secret Service integration when a desktop keyring is active.
class LinuxSecretServiceHook {
 public:
  using StoreSyncFn = int (*)(const LibSecretSchema* schema,
                              const char* collection,
                              const char* label,
                              const char* password,
                              void* cancellable,
                              LibGError** error,
                              ...);
  using LookupSyncFn = char* (*)(const LibSecretSchema* schema,
                                 void* cancellable,
                                 LibGError** error,
                                 ...);
  using ClearSyncFn = int (*)(const LibSecretSchema* schema,
                              void* cancellable,
                              LibGError** error,
                              ...);
  using PasswordFreeFn = void (*)(char* password);
  using ErrorFreeFn = void (*)(LibGError* error);

  LinuxSecretServiceHook() {
    handle_ = dlopen("libsecret-1.so.0", RTLD_LAZY | RTLD_LOCAL);
    if (!handle_) {
      return;
    }
    store_sync_ = reinterpret_cast<StoreSyncFn>(
        dlsym(handle_, "secret_password_store_sync"));
    lookup_sync_ = reinterpret_cast<LookupSyncFn>(
        dlsym(handle_, "secret_password_lookup_sync"));
    clear_sync_ = reinterpret_cast<ClearSyncFn>(
        dlsym(handle_, "secret_password_clear_sync"));
    password_free_ = reinterpret_cast<PasswordFreeFn>(
        dlsym(handle_, "secret_password_free"));
    error_free_ =
        reinterpret_cast<ErrorFreeFn>(dlsym(handle_, "g_error_free"));
    if (!error_free_) {
      error_free_ =
          reinterpret_cast<ErrorFreeFn>(dlsym(RTLD_DEFAULT, "g_error_free"));
    }
    available_ = (store_sync_ != nullptr && lookup_sync_ != nullptr &&
                  clear_sync_ != nullptr && password_free_ != nullptr &&
                  error_free_ != nullptr);
  }

  ~LinuxSecretServiceHook() {
    if (handle_) {
      dlclose(handle_);
      handle_ = nullptr;
    }
  }

  bool available() const { return available_; }
  StoreSyncFn store_sync() const { return store_sync_; }
  LookupSyncFn lookup_sync() const { return lookup_sync_; }
  ClearSyncFn clear_sync() const { return clear_sync_; }
  PasswordFreeFn password_free() const { return password_free_; }
  ErrorFreeFn error_free() const { return error_free_; }

 private:
  raw_ptr<void> handle_ = nullptr;
  StoreSyncFn store_sync_ = nullptr;
  LookupSyncFn lookup_sync_ = nullptr;
  ClearSyncFn clear_sync_ = nullptr;
  PasswordFreeFn password_free_ = nullptr;
  ErrorFreeFn error_free_ = nullptr;
  bool available_ = false;
};

// Primary Linux secret store backed by org.freedesktop.secrets via libsecret,
// falling back transparently to the 0600 file store if D-Bus / gnome-keyring is
// unavailable at runtime (headless, minimal Wayland, or WSL sessions).
class LinuxLibSecretStore final : public SecretStore {
 public:
  LinuxLibSecretStore(const LinuxSecretServiceHook* hook,
                      base::FilePath data_dir)
      : hook_(hook), file_fallback_(std::move(data_dir)) {}

  bool SaveSecret(std::string_view service,
                  std::string_view account,
                  const std::vector<uint8_t>& secret) override {
    if (!hook_ || !hook_->available()) {
      used_fallback_ = true;
      return file_fallback_.SaveSecret(service, account, secret);
    }

    const std::string service_str(service);
    const std::string account_str(account);
    const std::string label = "Open Browser (" + service_str + ")";
    const std::string encoded =
        std::string(kLibSecretPrefix) + base::Base64Encode(secret);

    LibGError* err = nullptr;
    const int ok = hook_->store_sync()(
        &kOpenSecretSchema, kSecretCollectionDefault, label.c_str(),
        encoded.c_str(), /*cancellable=*/nullptr, &err, "service",
        service_str.c_str(), "account", account_str.c_str(),
        static_cast<const char*>(nullptr));
    if (ok && err == nullptr) {
      used_fallback_ = false;
      file_fallback_.DeleteSecret(service, account);
      return true;
    }

    if (err) {
      LOG(WARNING) << "libsecret store failed ("
                   << (err->message ? err->message : "unknown error")
                   << "); falling back to 0600 file store";
      hook_->error_free()(err);
    } else {
      LOG(WARNING) << "libsecret store returned false; falling back to 0600 "
                      "file store";
    }
    used_fallback_ = true;
    return file_fallback_.SaveSecret(service, account, secret);
  }

  std::optional<std::vector<uint8_t>> LoadSecret(
      std::string_view service,
      std::string_view account) override {
    if (hook_ && hook_->available()) {
      const std::string service_str(service);
      const std::string account_str(account);
      LibGError* err = nullptr;
      char* raw = hook_->lookup_sync()(
          &kOpenSecretSchema, /*cancellable=*/nullptr, &err, "service",
          service_str.c_str(), "account", account_str.c_str(),
          static_cast<const char*>(nullptr));
      if (err) {
        LOG(WARNING) << "libsecret lookup failed ("
                     << (err->message ? err->message : "unknown error")
                     << "); trying 0600 file fallback";
        hook_->error_free()(err);
        if (raw) {
          hook_->password_free()(raw);
        }
        used_fallback_ = true;
      } else if (raw) {
        std::string value(raw);
        hook_->password_free()(raw);
        used_fallback_ = false;
        if (base::StartsWith(value, kLibSecretPrefix)) {
          auto decoded = base::Base64Decode(
              std::string_view(value).substr(sizeof(kLibSecretPrefix) - 1));
          if (decoded.has_value()) {
            return decoded;
          }
          LOG(WARNING) << "libsecret entry had malformed base64 payload";
        } else {
          return std::vector<uint8_t>(value.begin(), value.end());
        }
      }
    }
    return file_fallback_.LoadSecret(service, account);
  }

  bool DeleteSecret(std::string_view service,
                    std::string_view account) override {
    bool libsecret_ok = true;
    if (hook_ && hook_->available()) {
      const std::string service_str(service);
      const std::string account_str(account);
      LibGError* err = nullptr;
      hook_->clear_sync()(&kOpenSecretSchema, /*cancellable=*/nullptr, &err,
                          "service", service_str.c_str(), "account",
                          account_str.c_str(),
                          static_cast<const char*>(nullptr));
      if (err) {
        LOG(WARNING) << "libsecret clear failed ("
                     << (err->message ? err->message : "unknown error") << ")";
        hook_->error_free()(err);
        // If D-Bus is unavailable and we are operating on the file fallback,
        // deleting the fallback file is sufficient.
        libsecret_ok = used_fallback_;
      }
    }
    const bool file_ok = file_fallback_.DeleteSecret(service, account);
    return libsecret_ok && file_ok;
  }

  bool UsesFileBackend() const override { return used_fallback_; }

 private:
  raw_ptr<const LinuxSecretServiceHook> hook_;
  LinuxFileSecretStore file_fallback_;
  bool used_fallback_ = false;
};

class OpenPlatformLinux final : public OpenPlatform,
                                public views::WidgetObserver {
 public:
  OpenPlatformLinux() = default;
  ~OpenPlatformLinux() override { Shutdown(); }

  void Shutdown() override { widget_observations_.RemoveAllObservations(); }

  std::unique_ptr<SecretStore> CreateSecretStore(
      const base::FilePath& data_dir,
      bool force_file_backend) override {
    if (force_file_backend || !secret_service_hook_.available()) {
      return std::make_unique<LinuxFileSecretStore>(data_dir);
    }
    return std::make_unique<LinuxLibSecretStore>(&secret_service_hook_,
                                                 data_dir);
  }

  bool SetDefaultBrowser() override {
    EnsureDesktopIntegrationFiles();
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
                            HotkeyCallback /*callback*/) override {
    // Global shortcuts on Linux require an X11 grab or xdg-desktop-portal
    // GlobalShortcuts session binding, which is not yet wired. Report false so
    // Settings accurately reflects that the shortcut is not globally bound.
    VLOG(1) << "Global hotkey '" << spec.id
            << "' not bound: Linux global shortcuts backend not implemented";
    return false;
  }

  bool UnregisterGlobalHotkey(std::string_view /*id*/) override {
    return false;
  }

  void ApplyWindowEffects(views::Widget* widget, bool dark_mode) override {
    if (!widget) {
      return;
    }
    if (!widget_observations_.IsObservingSource(widget)) {
      widget_observations_.AddObservation(widget);
    }
    // On Linux (X11/Wayland/Ozone), compositor translucency and rounded CSD
    // framing are controlled through the Views non-client frame and widget
    // opacity; mark the widget color-mode override when supported.
    widget->SetColorModeOverride(
        dark_mode ? ui::ColorProviderKey::ColorMode::kDark
                  : ui::ColorProviderKey::ColorMode::kLight);
    if (has_custom_icon_) {
      ApplyIconsToWidget(widget, current_small_icon_, current_large_icon_);
    }
  }

  bool SetAppIcon(const std::string& icon_id) override {
    const AppIconPalette* palette = FindAppIconPalette(icon_id);
    if (!palette) {
      return false;
    }
    gfx::ImageSkia small_icon = BuildAppIconImageSkia(*palette, 32);
    gfx::ImageSkia large_icon = BuildAppIconImageSkia(*palette, 128);
    if (small_icon.isNull() || large_icon.isNull()) {
      return false;
    }
    current_small_icon_ = std::move(small_icon);
    current_large_icon_ = std::move(large_icon);
    has_custom_icon_ = true;

    std::vector<views::Widget*> widgets;
    widgets.reserve(widget_observations_.GetSourcesCount());
    for (const auto& observed : widget_observations_.sources()) {
      widgets.push_back(observed.get());
    }
    for (views::Widget* widget : widgets) {
      ApplyIconsToWidget(widget, current_small_icon_, current_large_icon_);
    }
    return true;
  }

  LinuxWindowButtons GetLinuxWindowButtons() const override {
    LinuxWindowButtons result;
    if (!ui::LinuxUi::instance()) {
      result.trailing = {WindowControlButton::kMinimize,
                         WindowControlButton::kMaximize,
                         WindowControlButton::kClose};
      result.has_csd_preference = false;
      return result;
    }
    // Chromium's LinuxUi toolkit (GTK/Qt) populates WindowButtonOrderProvider
    // with the desktop environment's client-side window button ordering.
    const auto* provider = views::WindowButtonOrderProvider::GetInstance();
    auto map_button = [](views::FrameButton button) -> WindowControlButton {
      switch (button) {
        case views::FrameButton::kMinimize:
          return WindowControlButton::kMinimize;
        case views::FrameButton::kMaximize:
          return WindowControlButton::kMaximize;
        case views::FrameButton::kClose:
          return WindowControlButton::kClose;
      }
      return WindowControlButton::kClose;
    };
    for (views::FrameButton button : provider->leading_buttons()) {
      result.leading.push_back(map_button(button));
    }
    for (views::FrameButton button : provider->trailing_buttons()) {
      result.trailing.push_back(map_button(button));
    }
    if (result.leading.empty() && result.trailing.empty()) {
      result.trailing = {WindowControlButton::kMinimize,
                         WindowControlButton::kMaximize,
                         WindowControlButton::kClose};
      result.has_csd_preference = false;
      return result;
    }
    result.has_csd_preference = true;
    return result;
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
  // views::WidgetObserver:
  void OnWidgetDestroyed(views::Widget* widget) override {
    if (widget_observations_.IsObservingSource(widget)) {
      widget_observations_.RemoveObservation(widget);
    }
  }

  static void ApplyIconsToWidget(views::Widget* widget,
                                 const gfx::ImageSkia& small_icon,
                                 const gfx::ImageSkia& large_icon) {
    if (!widget || widget->IsClosed()) {
      return;
    }
    if (views::WidgetDelegate* delegate = widget->widget_delegate()) {
      delegate->SetIcon(ui::ImageModel::FromImageSkia(small_icon));
      delegate->SetAppIcon(ui::ImageModel::FromImageSkia(large_icon));
    }
    // BrowserView overrides WidgetDelegate::GetWindowIcon/GetWindowAppIcon, so
    // push directly to NativeWidgetPrivate to update the Aura/Ozone window icon
    // (_NET_WM_ICON on X11 / platform icon on Wayland).
    if (auto* native_widget = widget->native_widget_private()) {
      native_widget->SetWindowIcons(small_icon, large_icon);
    }
  }

  LinuxSecretServiceHook secret_service_hook_;
  base::ScopedMultiSourceObservation<views::Widget, views::WidgetObserver>
      widget_observations_{this};
  gfx::ImageSkia current_small_icon_;
  gfx::ImageSkia current_large_icon_;
  bool has_custom_icon_ = false;
};

}  // namespace

// --- OpenPlatform defaults (Linux overrides SetAppIcon; Linux has no native
// window material, no movable window buttons, and no per-app URL source). ---

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
