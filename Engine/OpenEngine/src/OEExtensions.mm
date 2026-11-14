// Live per-profile extension registry and consent. Swift sees only OpenEngine.
#import "OEInternal.h"
#import <ImageIO/ImageIO.h>

namespace {
NSArray<NSString*>* OEStrings(CefRefPtr<CefListValue> list) {
  NSMutableArray* result = [NSMutableArray array];
  if (list) for (size_t i = 0; i < list->GetSize(); ++i) [result addObject:OEString(list->GetString(i))];
  return result;
}
NSImage* OEManifestIcon(NSURL* url) {
  NSFileHandle* file = [NSFileHandle fileHandleForReadingFromURL:url error:nil];
  NSData* data = [file readDataUpToLength:4 * 1024 * 1024 + 1 error:nil];
  [file closeFile];
  if (!data.length || data.length > 4 * 1024 * 1024) return nil;
  CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
  if (!source) return nil;
  NSDictionary* properties = CFBridgingRelease(CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
  const long long width = [properties[(__bridge NSString*)kCGImagePropertyPixelWidth] longLongValue];
  const long long height = [properties[(__bridge NSString*)kCGImagePropertyPixelHeight] longLongValue];
  const long long depth = [properties[(__bridge NSString*)kCGImagePropertyDepth] longLongValue];
  NSString* model = properties[(__bridge NSString*)kCGImagePropertyColorModel];
  const BOOL knownModel = [@[ @"RGB", @"Gray", @"CMYK", @"Lab", @"Indexed" ] containsObject:model ?: @""];
  // guess (child): safety caps for manifest metadata icons. At most four
  // 8-bit components: 2048 * 2048 * 4 = 16 MiB. Reject before decode.
  CGImageRef image = width > 0 && height > 0 && width <= 2048 && height <= 2048
      && depth > 0 && depth <= 8 && knownModel
      ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
  CFRelease(source);
  if (!image) { NSLog(@"OpenEngine: extension icon refused (2048 px/8-bit limit or invalid image)"); return nil; }
  NSImage* result = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(width, height)];
  CGImageRelease(image);
  return result;
}

NSImage* OEPromptImage(CefRefPtr<CefImage> image) {
  if (!image) return nil;
  int width, height;
  auto bytes = image->GetAsPNG(1, true, width, height);
  if (!bytes || bytes->GetSize() > 4 * 1024 * 1024) return nil;
  NSMutableData* data = [NSMutableData dataWithLength:bytes->GetSize()];
  bytes->GetData(data.mutableBytes, data.length, 0);
  return [[NSImage alloc] initWithData:data];
}
}

@interface OEExtension ()
- (instancetype)initOEWithState:(CefRefPtr<CefDictionaryValue>)d;
@end
@implementation OEExtension
- (instancetype)initOEWithState:(CefRefPtr<CefDictionaryValue>)d {
  if ((self = [super init])) {
    _identifier = OEString(d->GetString("id"));
    _name = OEString(d->GetString("name"));
    _version = OEString(d->GetString("version"));
    _summary = OEString(d->GetString("summary"));
    _manifestVersion = d->GetInt("manifestVersion");
    _enabled = d->GetBool("enabled"); _unpacked = d->GetBool("unpacked");
    _hasAction = _oe_hasAction = d->GetBool("hasAction");
    _fromWebStore = d->GetBool("fromWebStore");
    _disableReasons = static_cast<uint32_t>(d->GetInt("disableReasons"));
    _homepageURL = OEURL(d->GetString("homepage"));
    NSString* keyword = OEString(d->GetString("omniboxKeyword"));
    _omniboxKeyword = keyword.length ? keyword : nil;
    _installDirectory = [NSURL fileURLWithPath:OEString(d->GetString("path")) isDirectory:YES];
    _optionsURL = OEURL(d->GetString("options"));
    _permissions = OEStrings(d->GetList("permissions"));
    _hostPermissions = OEStrings(d->GetList("hostPermissions"));
    _oe_actionTitle = OEString(d->GetString("actionTitle"));
    _oe_actionPopupURL = OEURL(d->GetString("actionPopup"));
    // Chromium resolved and validated the manifest path. Bound encoded bytes
    // before AppKit decodes the image. Toolbar images come from Chromium.
    NSURL* iconURL = [NSURL fileURLWithPath:OEString(d->GetString("iconPath"))];
    _icon = OEManifestIcon(iconURL);
    _oe_actionIcon = _icon;
  }
  return self;
}
@end

#pragma mark - OEExtensionAction

@implementation OEExtensionAction

- (instancetype)initOEWithExtension:(OEExtension*)extension {
  if ((self = [super init])) {
    _extensionIdentifier = [extension.identifier copy];
    _title = [extension.oe_actionTitle ?: extension.name copy];
    _extensionName = [extension.name copy];
    _accessibleName = _title;
    _tooltip = _title;
    _icon = extension.oe_actionIcon;
    _enabled = extension.enabled;
    _popupURL = [extension.oe_actionPopupURL copy];
    _hasPopup = _popupURL != nil;
    _pinnedIndex = -1;
  }
  return self;
}

static NSColor* OEColorFromARGB(int argb) {
  const uint32_t c = static_cast<uint32_t>(argb);
  return [NSColor colorWithSRGBRed:((c >> 16) & 0xff) / 255.0
                             green:((c >> 8) & 0xff) / 255.0
                              blue:(c & 0xff) / 255.0
                             alpha:((c >> 24) & 0xff) / 255.0];
}

- (instancetype)initOEWithIdentifier:(NSString*)identifier
                               state:(CefRefPtr<CefDictionaryValue>)state
                        toolbarImage:(nullable NSImage*)toolbarImage
                                icon:(nullable NSImage*)icon {
  if ((self = [super init])) {
    _extensionIdentifier = [identifier copy];
    _extensionName = OEString(state->GetString("name"));
    NSString* title = OEString(state->GetString("title"));
    _title = title.length ? title : _extensionName;
    _accessibleName = OEString(state->GetString("accessibleName"));
    _tooltip = OEString(state->GetString("tooltip"));
    _icon = icon;
    _toolbarImage = toolbarImage;
    NSString* badge = OEString(state->GetString("badgeText"));
    _badgeText = badge.length ? badge : nil;
    const int background = state->GetInt("badgeBackgroundColor");
    _badgeBackgroundColor = (static_cast<uint32_t>(background) >> 24)
                                ? OEColorFromARGB(background)
                                : nil;
    _badgeTextColor = state->HasKey("badgeTextColor")
                          ? OEColorFromARGB(state->GetInt("badgeTextColor"))
                          : nil;
    _enabled = state->GetBool("enabled");
    _hasPopup = state->GetBool("hasPopup");
    _pinned = state->GetBool("pinned");
    _pinnedIndex = state->GetInt("pinnedIndex");
    _wantsToRun = state->GetBool("wantsToRun");
    _siteAccess = static_cast<OEExtensionSiteAccess>(state->GetInt("siteAccess"));
    _showingPopup = state->GetBool("showingPopup");
    _live = state->GetBool("live");
    NSString* key = OEString(state->GetString("shortcutKeyEquivalent"));
    _shortcutKeyEquivalent = key.length ? key : nil;
    _shortcutModifierFlags = state->GetInt("shortcutModifierFlags");

  }
  return self;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<OEExtensionAction %@ pinned=%d badge=%@>",
                                    _extensionIdentifier, _pinned, _badgeText];
}

@end


@interface OEExtensionCommand ()
- (instancetype)initOEWithState:(CefRefPtr<CefDictionaryValue>)d;
@end
@implementation OEExtensionCommand
- (instancetype)initOEWithState:(CefRefPtr<CefDictionaryValue>)d {
  if ((self = [super init])) {
    _extensionIdentifier = OEString(d->GetString("id"));
    _name = OEString(d->GetString("name")); _summary = OEString(d->GetString("summary"));
    _keyEquivalent = OEString(d->GetString("keyEquivalent"));
    _modifierFlags = d->GetInt("modifierFlags");
    _global = d->GetBool("global"); _actionCommand = d->GetBool("actionCommand");
  }
  return self;
}
@end

@interface OEExtensionPermissionMessage ()
- (instancetype)initOEWithState:(CefRefPtr<CefDictionaryValue>)d;
@end
@implementation OEExtensionPermissionMessage
- (instancetype)initOEWithState:(CefRefPtr<CefDictionaryValue>)d {
  if ((self = [super init])) { _message = OEString(d->GetString("message")); _details = OEStrings(d->GetList("details")); }
  return self;
}
@end

@interface OEExtensionPrompt ()
- (instancetype)initOEWithPrompt:(CefRefPtr<CefExtensionPrompt>)prompt;
@end
@implementation OEExtensionPrompt {
  CefRefPtr<CefExtensionPrompt> _prompt;
}
- (instancetype)initOEWithPrompt:(CefRefPtr<CefExtensionPrompt>)prompt {
  if ((self = [super init])) {
    _prompt = prompt;
    auto d = prompt->GetData();
    switch (d->GetInt("type")) {
      case 3: _type = OEExtensionPromptTypeReEnable; break;
      case 4: _type = OEExtensionPromptTypePermissions; break;
      case 5: _type = OEExtensionPromptTypeExternalInstall; break;
      case 8: _type = OEExtensionPromptTypeRemoteInstall; break;
      case 9: _type = OEExtensionPromptTypeRepair; break;
      case 100: _type = OEExtensionPromptTypeUninstall; break;
      default: _type = OEExtensionPromptTypeInstall; break;
    }
    _extensionIdentifier = OEString(d->GetString("id"));
    _extensionName = OEString(d->GetString("name"));
    _chromiumTitle = OEString(d->GetString("title"));
    _chromiumAcceptLabel = OEString(d->GetString("acceptLabel"));
    _chromiumCancelLabel = OEString(d->GetString("cancelLabel"));
    NSString* triggering = OEString(d->GetString("triggeringExtensionName"));
    _triggeringExtensionName = triggering.length ? triggering : nil;
    _icon = OEPromptImage(prompt->GetIcon());
    NSMutableArray* permissions = [NSMutableArray array];
    auto list = d->GetList("permissions");
    if (list) for (size_t i = 0; i < list->GetSize(); ++i)
      [permissions addObject:[[OEExtensionPermissionMessage alloc] initOEWithState:list->GetDictionary(i)]];
    _permissions = permissions;
    _retainedFiles = OEStrings(d->GetList("retainedFiles"));
    _retainedDevices = OEStrings(d->GetList("retainedDevices"));
    auto source = prompt->GetBrowser();
    if (source) for (OEWebContent* content in OEEngine.shared.allWebContents) {
      if (content.oe_browser && content.oe_browser->IsSame(source)) {
        // permissions.request and uninstall supply a native window only.
        // Its CEF lookup identifies the owning browser, not a requesting page.
        if (d->GetBool("hasRequestingPage")) _webContent = content;
        _browser = content.oe_hostBrowser; break;
      }
    }
  }
  return self;
}
- (void)accept {
  auto prompt = _prompt; _prompt = nullptr;
  if (prompt) prompt->Answer(true);
}
- (void)cancel {
  auto prompt = _prompt; _prompt = nullptr;
  if (prompt) prompt->Answer(false);
}
@end

@interface OEExtensionManager ()
- (void)oe_changed:(BOOL)commands;
- (void)oe_ready;
- (void)oe_installed:(CefRefPtr<CefDictionaryValue>)state byUser:(BOOL)user;
- (void)oe_failed:(NSString*)path error:(NSString*)error;
- (void)oe_showPrompt:(OEExtensionPrompt*)prompt;
@end
namespace {
class OEExtensionsHandler : public CefExtensionManagerHandler {
 public:
  explicit OEExtensionsHandler(OEExtensionManager* manager) : manager_(manager) {}
  void OnChanged(bool commands) override { [manager_ oe_changed:commands]; }
  void OnReady() override { [manager_ oe_ready]; }
  void OnInstalled(CefRefPtr<CefDictionaryValue> e, bool user) override { [manager_ oe_installed:e byUser:user]; }
  void OnLoadFailed(const CefString& path, const CefString& error) override { [manager_ oe_failed:OEString(path) error:OEString(error)]; }
  bool CanShowPrompt() override { return [manager_.delegate respondsToSelector:@selector(extensionManager:showPrompt:)]; }
  void OnPrompt(CefRefPtr<CefExtensionPrompt> prompt) override {
    [manager_ oe_showPrompt:[[OEExtensionPrompt alloc] initOEWithPrompt:prompt]];
  }
 private:
  __weak OEExtensionManager* manager_;
  IMPLEMENT_REFCOUNTING(OEExtensionsHandler);
};
class OEInstallCompletion : public CefExtensionInstallCallback {
 public:
  explicit OEInstallCompletion(void (^completion)(BOOL, NSString*)) : completion_([completion copy]) {}
  ~OEInstallCompletion() override {
    // Released unrun (the profile's extension system closed mid-install).
    if (auto completion = completion_) dispatch_async(dispatch_get_main_queue(), ^{
      completion(NO, @"The extension install did not complete");
    });
  }
  void OnComplete(bool installed, const CefString& error) override {
    auto completion = completion_; completion_ = nil;
    if (completion) completion(installed, error.empty() ? nil : OEString(error));
  }
 private:
  void (^completion_)(BOOL, NSString*);
  IMPLEMENT_REFCOUNTING(OEInstallCompletion);
};
class OELocalInstallCompletion : public CefExtensionLocalInstallCallback {
 public:
  explicit OELocalInstallCompletion(void (^completion)(OEExtensionInstallResult, NSString*, NSString*))
      : completion_([completion copy]) {}
  ~OELocalInstallCompletion() override {
    // Released unrun (the profile's extension system closed mid-install).
    if (auto completion = completion_) dispatch_async(dispatch_get_main_queue(), ^{
      completion(OEExtensionInstallResultFailed, nil, @"The extension install did not complete");
    });
  }
  void OnComplete(int result, const CefString& identifier, const CefString& error) override {
    auto completion = completion_; completion_ = nil;
    NSString* extensionID = identifier.empty() ? nil : OEString(identifier);
    NSString* message = error.empty() ? nil : OEString(error);
    // Always leave the CEF stack before caller code can tear down its context.
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{
      completion(static_cast<OEExtensionInstallResult>(result), extensionID, message);
    });
  }
 private:
  void (^completion_)(OEExtensionInstallResult, NSString*, NSString*);
  IMPLEMENT_REFCOUNTING(OELocalInstallCompletion);
};
}
@implementation OEExtensionManager {
  CefRefPtr<CefExtensionManager> _manager;
  NSArray<OEExtension*>* _installed;
  NSArray<OEExtensionCommand*>* _commands;
  NSHashTable<OEExtensionPrompt*>* _prompts;
}
- (instancetype)initOEWithContext:(OEBrowserContext*)context {
  if ((self = [super init])) {
    _context = context;
    _prompts = [NSHashTable weakObjectsHashTable];
    __weak OEExtensionManager* weakSelf = self;
    [context oe_whenReady:^{
      OEExtensionManager* s = weakSelf;
      if (s && context.oe_isReady && context.oe_requestContext)
        s->_manager = CefExtensionManager::Create(context.oe_requestContext, new OEExtensionsHandler(s));
    }];
  }
  return self;
}
- (void)dealloc { [self oe_contextClosed]; }
- (void)oe_contextClosed {
  if (_manager) { _manager->Close(); _manager = nullptr; }
  // A presenter can retain a prompt beyond its context's lifetime. Drop each
  // prompt's CEF handle while the framework is still loaded.
  for (OEExtensionPrompt* prompt in _prompts.allObjects) [prompt cancel];
  [_prompts removeAllObjects];
  _installed = nil; _commands = nil;
}
- (void)oe_showPrompt:(OEExtensionPrompt*)prompt {
  if (!_manager || _context.state == OEBrowserContextStateClosed || _context.oe_closing) {
    [prompt cancel];
    return;
  }
  [_prompts addObject:prompt];
  id<OEExtensionManagerDelegate> delegate = _delegate;
  if ([delegate respondsToSelector:@selector(extensionManager:showPrompt:)])
    [delegate extensionManager:self showPrompt:prompt];
  else
    [prompt cancel];
}
- (CefRefPtr<CefExtensionManager>)oe_manager { return _manager; }
- (BOOL)isReady { return _manager && _manager->IsReady(); }
- (NSArray<OEExtension*>*)installedExtensions {
  if (_installed) return _installed;
  NSMutableArray* out = [NSMutableArray array];
  auto list = _manager ? _manager->GetInstalled() : nullptr;
  if (list) for (size_t i = 0; i < list->GetSize(); ++i)
    [out addObject:[[OEExtension alloc] initOEWithState:list->GetDictionary(i)]];
  [out sortUsingComparator:^NSComparisonResult(OEExtension* a, OEExtension* b) { return [a.name localizedCaseInsensitiveCompare:b.name]; }];
  _installed = out;
  return out;
}
- (NSArray<OEExtensionCommand*>*)commands {
  if (_commands) return _commands;
  NSMutableArray* out = [NSMutableArray array];
  auto list = _manager ? _manager->GetCommands() : nullptr;
  if (list) for (size_t i = 0; i < list->GetSize(); ++i)
    [out addObject:[[OEExtensionCommand alloc] initOEWithState:list->GetDictionary(i)]];
  _commands = out;
  return out;
}
- (OEExtension*)extensionWithIdentifier:(NSString*)identifier {
  for (OEExtension* e in self.installedExtensions) if ([e.identifier isEqualToString:identifier]) return e;
  return nil;
}
- (void)setEnabled:(BOOL)enabled forExtension:(NSString*)identifier { if (_manager) _manager->SetEnabled(OECef(identifier), enabled); }
- (void)uninstallExtension:(NSString*)identifier window:(NSWindow*)window { if (_manager) _manager->Uninstall(OECef(identifier), (__bridge void*)window); }
- (void)reloadExtension:(NSString*)identifier { if (_manager) _manager->Reload(OECef(identifier)); }
- (void)installFromWebStore:(NSString*)identifier window:(NSWindow*)window completion:(void (^)(BOOL, NSString*))completion {
  if (_manager) _manager->InstallFromWebStore(OECef(identifier), (__bridge void*)window, new OEInstallCompletion(completion));
  else completion(NO, @"Extension system is not ready");
}
- (BOOL)installLocalCRX:(NSURL*)file webContent:(OEWebContent*)content {
  return _manager && _manager->InstallLocalCrx(OECef(file.path), content.oe_browser);
}
- (void)installLocalCRX:(NSURL*)file
    completion:(void (^)(OEExtensionInstallResult, NSString*, NSString*))completion {
  CefRefPtr<OELocalInstallCompletion> callback = new OELocalInstallCompletion(completion);
  if (!file.isFileURL || !_manager) {
    callback->OnComplete(2, "", !file.isFileURL ? "Local CRX requires a file URL" : "Extension system is not ready");
    return;
  }
  CefInstallLocalCrx(_manager, OECef(file.path), nullptr, callback);
}
- (void)reload { [self oe_changed:NO]; }
- (void)oe_changed:(BOOL)commands {
  _commands = nil;
  if (!commands) _installed = nil;
  [OEEngine.shared oe_extensionsChangedInContext:_context];
  if (commands) {
    if ([_delegate respondsToSelector:@selector(extensionManagerDidChangeCommands:)]) [_delegate extensionManagerDidChangeCommands:self];
  } else {
    if ([_delegate respondsToSelector:@selector(extensionManagerDidChange:)]) [_delegate extensionManagerDidChange:self];
  }
}
- (void)oe_ready {
  [self oe_changed:NO]; [self oe_changed:YES];
  if ([_delegate respondsToSelector:@selector(extensionManagerDidBecomeReady:)]) [_delegate extensionManagerDidBecomeReady:self];
}
- (void)oe_installed:(CefRefPtr<CefDictionaryValue>)state byUser:(BOOL)user {
  if ([_delegate respondsToSelector:@selector(extensionManager:didInstallExtension:byUser:)])
    [_delegate extensionManager:self didInstallExtension:[[OEExtension alloc] initOEWithState:state] byUser:user];
}
- (void)oe_failed:(NSString*)path error:(NSString*)error {
  if ([_delegate respondsToSelector:@selector(extensionManager:didFailToLoadExtensionAt:error:)])
    [_delegate extensionManager:self didFailToLoadExtensionAt:[NSURL fileURLWithPath:path] error:error];
}
+ (NSURL*)managementPageURL { return [NSURL URLWithString:@"chrome://extensions"]; }
+ (NSURL*)webStorePageURLForExtensionIdentifier:(NSString*)identifier {
  return [NSURL URLWithString:[@"https://chromewebstore.google.com/detail/" stringByAppendingString:identifier]];
}
@end
