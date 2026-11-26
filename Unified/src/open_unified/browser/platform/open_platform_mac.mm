// Copyright 2026 The Open Authors. All rights reserved.
// macOS implementation of OpenPlatform.

#include "open_unified/browser/platform/open_platform.h"

#import <Carbon/Carbon.h>
#import <Cocoa/Cocoa.h>
#import <CoreServices/CoreServices.h>
#import <Security/Security.h>

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <map>
#include <mutex>
#include <string>
#include <utility>
#include <vector>

#include "base/apple/foundation_util.h"
#include "base/files/file_util.h"
#include "base/logging.h"
#include "base/no_destructor.h"
#include "base/strings/string_number_conversions.h"
#include "base/strings/sys_string_conversions.h"
#include "ui/gfx/native_ui_types.h"
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

class MacFileSecretStore final : public SecretStore {
 public:
  explicit MacFileSecretStore(base::FilePath data_dir)
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

class MacKeychainSecretStore final : public SecretStore {
 public:
  explicit MacKeychainSecretStore(base::FilePath data_dir)
      : file_fallback_(std::move(data_dir)) {}

  bool SaveSecret(std::string_view service,
                  std::string_view account,
                  const std::vector<uint8_t>& secret) override {
    @autoreleasepool {
      NSString* ns_service = base::SysUTF8ToNSString(service);
      NSString* ns_account = base::SysUTF8ToNSString(account);
      NSData* ns_data =
          [NSData dataWithBytes:secret.data() length:secret.size()];

      NSDictionary* query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : ns_service,
        (__bridge id)kSecAttrAccount : ns_account,
      };
      NSDictionary* update = @{
        (__bridge id)kSecValueData : ns_data,
        (__bridge id)kSecAttrAccessible :
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
      };

      OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                      (__bridge CFDictionaryRef)update);
      if (status == errSecItemNotFound) {
        NSMutableDictionary* add_query = [query mutableCopy];
        add_query[(__bridge id)kSecValueData] = ns_data;
        add_query[(__bridge id)kSecAttrAccessible] =
            (__bridge id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
        status = SecItemAdd((__bridge CFDictionaryRef)add_query, nullptr);
      }
      if (status == errSecSuccess) {
        used_fallback_ = false;
        file_fallback_.DeleteSecret(service, account);
        return true;
      }
      LOG(WARNING) << "SecItem save failed (" << status
                   << "); using 0600 file fallback";
      // Remove any existing Keychain entry before writing the fallback file so
      // a stale Keychain token can never win on the next LoadSecret().
      SecItemDelete((__bridge CFDictionaryRef)query);
      used_fallback_ = true;
      return file_fallback_.SaveSecret(service, account, secret);
    }
  }

  std::optional<std::vector<uint8_t>> LoadSecret(
      std::string_view service,
      std::string_view account) override {
    @autoreleasepool {
      NSString* ns_service = base::SysUTF8ToNSString(service);
      NSString* ns_account = base::SysUTF8ToNSString(account);
      NSDictionary* query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : ns_service,
        (__bridge id)kSecAttrAccount : ns_account,
        (__bridge id)kSecReturnData : @YES,
        (__bridge id)kSecMatchLimit : (__bridge id)kSecMatchLimitOne,
      };
      CFTypeRef result = nullptr;
      OSStatus status =
          SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
      if (status == errSecSuccess && result != nullptr) {
        NSData* data = (__bridge_transfer NSData*)result;
        const auto* ptr = static_cast<const uint8_t*>(data.bytes);
        return std::vector<uint8_t>(ptr, ptr + data.length);
      }
      return file_fallback_.LoadSecret(service, account);
    }
  }

  bool DeleteSecret(std::string_view service,
                    std::string_view account) override {
    @autoreleasepool {
      NSString* ns_service = base::SysUTF8ToNSString(service);
      NSString* ns_account = base::SysUTF8ToNSString(account);
      NSDictionary* query = @{
        (__bridge id)kSecClass : (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService : ns_service,
        (__bridge id)kSecAttrAccount : ns_account,
      };
      OSStatus status = SecItemDelete((__bridge CFDictionaryRef)query);
      bool kc_ok = (status == errSecSuccess || status == errSecItemNotFound);
      bool file_ok = file_fallback_.DeleteSecret(service, account);
      return kc_ok && file_ok;
    }
  }

  bool UsesFileBackend() const override { return used_fallback_; }

 private:
  MacFileSecretStore file_fallback_;
  bool used_fallback_ = false;
};

class MacCarbonHotkeyDispatcher {
 public:
  MacCarbonHotkeyDispatcher() = default;
  ~MacCarbonHotkeyDispatcher() {
    std::lock_guard<std::mutex> lock(mu_);
    for (auto& [key_id, entry] : entries_) {
      if (entry.ref) {
        UnregisterEventHotKey(entry.ref);
      }
    }
    if (handler_ref_) {
      RemoveEventHandler(handler_ref_);
      handler_ref_ = nullptr;
    }
  }

  bool Register(const GlobalHotkeySpec& spec,
                OpenPlatform::HotkeyCallback callback) {
    std::lock_guard<std::mutex> lock(mu_);
    EnsureHandlerLocked();
    UnregisterLocked(spec.id);

    UInt32 carbon_mods = 0;
    if (spec.modifiers & kHotkeyModMeta) carbon_mods |= cmdKey;
    if (spec.modifiers & kHotkeyModAlt) carbon_mods |= optionKey;
    if (spec.modifiers & kHotkeyModControl) carbon_mods |= controlKey;
    if (spec.modifiers & kHotkeyModShift) carbon_mods |= shiftKey;

    UInt32 numeric_id = next_id_++;
    EventHotKeyID hotkey_id{'OPEN', numeric_id};
    EventHotKeyRef ref = nullptr;
    OSStatus status =
        RegisterEventHotKey(spec.key_code, carbon_mods, hotkey_id,
                            GetApplicationEventTarget(), 0, &ref);
    if (status != noErr || !ref) {
      LOG(WARNING) << "RegisterEventHotKey failed (" << status << ")";
      return false;
    }
    entries_[numeric_id] = Entry{spec.id, ref, std::move(callback)};
    id_to_num_[spec.id] = numeric_id;
    return true;
  }

  bool Unregister(std::string_view id) {
    std::lock_guard<std::mutex> lock(mu_);
    return UnregisterLocked(id);
  }

 private:
  struct Entry {
    std::string id;
    EventHotKeyRef ref = nullptr;
    OpenPlatform::HotkeyCallback callback;
  };

  void EnsureHandlerLocked() {
    if (handler_ref_) {
      return;
    }
    EventTypeSpec event_spec{};
    event_spec.eventClass = kEventClassKeyboard;
    event_spec.eventKind = kEventHotKeyPressed;
    InstallApplicationEventHandler(&MacCarbonHotkeyDispatcher::OnEvent, 1,
                                   &event_spec, this, &handler_ref_);
  }

  bool UnregisterLocked(std::string_view id) {
    auto it = id_to_num_.find(std::string(id));
    if (it == id_to_num_.end()) {
      return false;
    }
    auto entry_it = entries_.find(it->second);
    if (entry_it != entries_.end()) {
      if (entry_it->second.ref) {
        UnregisterEventHotKey(entry_it->second.ref);
      }
      entries_.erase(entry_it);
    }
    id_to_num_.erase(it);
    return true;
  }

  static OSStatus OnEvent(EventHandlerCallRef /*next*/,
                          EventRef event,
                          void* user_data) {
    EventHotKeyID hotkey_id{};
    if (GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID,
                          nullptr, sizeof(hotkey_id), nullptr,
                          &hotkey_id) != noErr) {
      return eventNotHandledErr;
    }
    auto* self = static_cast<MacCarbonHotkeyDispatcher*>(user_data);
    self->Dispatch(hotkey_id.id);
    return noErr;
  }

  void Dispatch(UInt32 numeric_id) {
    std::string id;
    OpenPlatform::HotkeyCallback cb;
    {
      std::lock_guard<std::mutex> lock(mu_);
      auto it = entries_.find(numeric_id);
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
  EventHandlerRef handler_ref_ = nullptr;
  UInt32 next_id_ = 1;
  std::map<UInt32, Entry> entries_;
  std::map<std::string, UInt32> id_to_num_;
};

class OpenPlatformMac final : public OpenPlatform {
 public:
  OpenPlatformMac() = default;
  ~OpenPlatformMac() override = default;

  std::unique_ptr<SecretStore> CreateSecretStore(
      const base::FilePath& data_dir,
      bool force_file_backend) override {
    if (force_file_backend) {
      return std::make_unique<MacFileSecretStore>(data_dir);
    }
    return std::make_unique<MacKeychainSecretStore>(data_dir);
  }

  bool SetDefaultBrowser() override {
    @autoreleasepool {
      NSString* bundle_id = [[NSBundle mainBundle] bundleIdentifier];
      if (!bundle_id.length) {
        return false;
      }
      NSURL* app_url = [[NSBundle mainBundle] bundleURL];
      if (!app_url) {
        return false;
      }
      if (@available(macOS 12.0, *)) {
        [[NSWorkspace sharedWorkspace]
            setDefaultApplicationAtURL:app_url
                     toOpenURLsWithScheme:@"http"
                        completionHandler:^(NSError*) {}];
        [[NSWorkspace sharedWorkspace]
            setDefaultApplicationAtURL:app_url
                     toOpenURLsWithScheme:@"https"
                        completionHandler:^(NSError*) {}];
        return true;
      }
      return false;
    }
  }

  bool IsDefaultBrowser() override {
    @autoreleasepool {
      NSString* self_id = [[NSBundle mainBundle] bundleIdentifier];
      if (!self_id.length) {
        return false;
      }
      NSURL* probe = [NSURL URLWithString:@"https://example.com"];
      NSURL* handler = [[NSWorkspace sharedWorkspace] URLForApplicationToOpenURL:probe];
      if (!handler) {
        return false;
      }
      NSBundle* handler_bundle = [NSBundle bundleWithURL:handler];
      return [handler_bundle.bundleIdentifier isEqualToString:self_id];
    }
  }

  bool RegisterGlobalHotkey(const GlobalHotkeySpec& spec,
                            HotkeyCallback callback) override {
    return hotkeys_.Register(spec, std::move(callback));
  }

  bool UnregisterGlobalHotkey(std::string_view id) override {
    return hotkeys_.Unregister(id);
  }

  void ApplyWindowEffects(views::Widget* widget, bool dark_mode) override {
    @autoreleasepool {
      if (!widget) {
        return;
      }
      NSWindow* window = widget->GetNativeWindow().GetNativeNSWindow();
      if (!window) {
        return;
      }
      window.appearance = [NSAppearance
          appearanceNamed:(dark_mode ? NSAppearanceNameDarkAqua
                                     : NSAppearanceNameAqua)];
      window.titlebarAppearsTransparent = YES;
      window.movableByWindowBackground = NO;

      NSView* content_view = window.contentView;
      if (!content_view) {
        return;
      }
      static constexpr NSInteger kOpenVibrancyTag = 0x4F50454E;
      NSVisualEffectView* vfx = [content_view viewWithTag:kOpenVibrancyTag];
      if (!vfx) {
        vfx = [[NSVisualEffectView alloc] initWithFrame:content_view.bounds];
        vfx.tag = kOpenVibrancyTag;
        vfx.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        vfx.blendingMode = NSVisualEffectBlendingModeBehindWindow;
        vfx.state = NSVisualEffectStateFollowsWindowActiveState;
        [content_view addSubview:vfx
                      positioned:NSWindowBelow
                      relativeTo:nil];
      }
      vfx.material = dark_mode ? NSVisualEffectMaterialUnderWindowBackground
                               : NSVisualEffectMaterialSidebar;
    }
  }

  base::FilePath GetDefaultUserDataDir() override {
    @autoreleasepool {
      NSArray<NSURL*>* urls = [[NSFileManager defaultManager]
          URLsForDirectory:NSApplicationSupportDirectory
                 inDomains:NSUserDomainMask];
      if (urls.count > 0) {
        NSURL* open_dir =
            [urls.firstObject URLByAppendingPathComponent:@"Open"
                                              isDirectory:YES];
        return base::apple::NSStringToFilePath(open_dir.path);
      }
      return base::FilePath("/tmp/Open");
    }
  }

  std::string GetDeviceName() override {
    @autoreleasepool {
      NSString* name = [[NSHost currentHost] localizedName];
      if (name.length > 0) {
        return base::SysNSStringToUTF8(name);
      }
      return "Mac";
    }
  }

  std::string GetSyncPlatformName() override { return "macos"; }

 private:
  MacCarbonHotkeyDispatcher hotkeys_;
};

}  // namespace

// static
OpenPlatform* OpenPlatform::Get() {
  static base::NoDestructor<OpenPlatformMac> instance;
  return instance.get();
}

}  // namespace open_unified
