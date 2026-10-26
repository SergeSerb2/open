// Installed-extension model for our own toolbar UI.
//
// CEF has no extension API since M128 (CefExtension and
// CefRequestContext::LoadExtension were removed with the Alloy runtime). The
// Chrome extension system still runs inside every context, so until fork
// patch P3 we read its state from the profile on disk: "extensions.settings"
// in Preferences / Secure Preferences, plus each extension's manifest.json
// and _locales. Dynamic action state (badge, setIcon, setTitle) is not on
// disk; patch P2 adds it.

#import "OEInternal.h"

namespace {

// extensions::mojom::ManifestLocation values written to Preferences.
enum Location {
  kInternal = 1,
  kExternalPref = 2,
  kUnpacked = 4,
  kComponent = 5,
  kExternalPrefDownload = 6,
  kExternalPolicyDownload = 7,
  kCommandLine = 8,
  kExternalPolicy = 9,
  kExternalComponent = 10,
};

NSDictionary* ReadJSON(NSURL* url) {
  NSData* data = [NSData dataWithContentsOfURL:url];
  if (!data) {
    return nil;
  }
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [obj isKindOfClass:NSDictionary.class] ? obj : nil;
}

}  // namespace

#pragma mark - OEExtension

@interface OEExtension ()
- (nullable instancetype)initOEWithIdentifier:(NSString*)identifier
                                      settings:(NSDictionary*)settings
                                    profileDir:(NSURL*)profileDir;
@end

@implementation OEExtension {
  NSDictionary* _messages;
}

- (nullable instancetype)initOEWithIdentifier:(NSString*)identifier
                                      settings:(NSDictionary*)settings
                                    profileDir:(NSURL*)profileDir {
  if (!(self = [super init])) {
    return nil;
  }
  NSInteger location = [settings[@"location"] integerValue];
  if (location == kComponent || location == kExternalComponent) {
    return nil;
  }
  NSString* path = settings[@"path"];
  if (![path isKindOfClass:NSString.class] || path.length == 0) {
    return nil;
  }
  _identifier = [identifier copy];
  _unpacked = location == kUnpacked || location == kCommandLine;
  _installDirectory =
      path.isAbsolutePath
          ? [NSURL fileURLWithPath:path isDirectory:YES]
          : [[profileDir URLByAppendingPathComponent:@"Extensions"]
                URLByAppendingPathComponent:path
                                isDirectory:YES];
  NSDictionary* manifest =
      ReadJSON([_installDirectory URLByAppendingPathComponent:@"manifest.json"]);
  if (!manifest) {
    manifest = [settings[@"manifest"] isKindOfClass:NSDictionary.class]
                   ? settings[@"manifest"]
                   : nil;
  }
  if (!manifest) {
    return nil;
  }
  [self oe_loadMessages:manifest[@"default_locale"]];

  _name = [self oe_localize:manifest[@"name"]] ?: identifier;
  _version = manifest[@"version"] ?: @"";
  _summary = [self oe_localize:manifest[@"description"]] ?: @"";
  _manifestVersion = [manifest[@"manifest_version"] integerValue];

  id reasons = settings[@"disable_reasons"];
  BOOL disabled = NO;
  if ([reasons isKindOfClass:NSArray.class]) {
    disabled = [reasons count] > 0;
  } else if ([reasons isKindOfClass:NSNumber.class]) {
    disabled = [reasons integerValue] != 0;
  }
  if (settings[@"state"] && [settings[@"state"] integerValue] == 0) {
    disabled = YES;
  }
  _enabled = !disabled;

  NSDictionary* action = manifest[@"action"] ?: manifest[@"browser_action"]
                                                   ?: manifest[@"page_action"];
  _oe_hasAction = [action isKindOfClass:NSDictionary.class];
  NSString* base =
      [NSString stringWithFormat:@"chrome-extension://%@/", identifier];
  if (_oe_hasAction) {
    _oe_actionTitle = [self oe_localize:action[@"default_title"]];
    NSString* popup = action[@"default_popup"];
    if ([popup isKindOfClass:NSString.class] && popup.length) {
      _oe_actionPopupURL =
          [NSURL URLWithString:[base stringByAppendingString:popup]];
    }
  }
  NSDictionary* optionsUI = manifest[@"options_ui"];
  NSString* options = [optionsUI isKindOfClass:NSDictionary.class]
                          ? optionsUI[@"page"]
                          : manifest[@"options_page"];
  if ([options isKindOfClass:NSString.class] && options.length) {
    _optionsURL = [NSURL URLWithString:[base stringByAppendingString:options]];
  }
  _icon = [self oe_bestIcon:manifest[@"icons"]];
  _oe_actionIcon =
      (_oe_hasAction ? [self oe_bestIcon:action[@"default_icon"]] : nil)
          ?: _icon;

  NSMutableArray* perms = [NSMutableArray array];
  NSMutableArray* hosts = [NSMutableArray array];
  for (id p in manifest[@"permissions"] ?: @[]) {
    if (![p isKindOfClass:NSString.class]) continue;
    if ([p containsString:@"://"] || [p isEqualToString:@"<all_urls>"]) {
      [hosts addObject:p];
    } else {
      [perms addObject:p];
    }
  }
  for (id p in manifest[@"host_permissions"] ?: @[]) {
    if ([p isKindOfClass:NSString.class]) [hosts addObject:p];
  }
  _permissions = perms;
  _hostPermissions = hosts;
  return self;
}

- (void)oe_loadMessages:(NSString*)defaultLocale {
  NSMutableArray* candidates = [NSMutableArray array];
  for (NSString* lang in NSLocale.preferredLanguages) {
    NSString* l = [lang stringByReplacingOccurrencesOfString:@"-"
                                                  withString:@"_"];
    [candidates addObject:l];
    NSArray* parts = [l componentsSeparatedByString:@"_"];
    if (parts.count > 1) [candidates addObject:parts[0]];
  }
  if ([defaultLocale isKindOfClass:NSString.class]) {
    [candidates addObject:defaultLocale];
  }
  for (NSString* locale in candidates) {
    NSURL* url = [[[_installDirectory URLByAppendingPathComponent:@"_locales"]
        URLByAppendingPathComponent:locale]
        URLByAppendingPathComponent:@"messages.json"];
    NSDictionary* messages = ReadJSON(url);
    if (messages) {
      NSMutableDictionary* lower = [NSMutableDictionary dictionary];
      [messages enumerateKeysAndObjectsUsingBlock:^(NSString* k, id v,
                                                    BOOL* stop) {
        lower[k.lowercaseString] = v;
      }];
      _messages = lower;
      return;
    }
  }
}

- (nullable NSString*)oe_localize:(id)value {
  if (![value isKindOfClass:NSString.class]) {
    return nil;
  }
  NSString* s = value;
  if ([s hasPrefix:@"__MSG_"] && [s hasSuffix:@"__"] && s.length > 8) {
    NSString* key = [[s substringWithRange:NSMakeRange(6, s.length - 8)]
        lowercaseString];
    NSString* message = _messages[key][@"message"];
    return message ?: s;
  }
  return s;
}

- (nullable NSImage*)oe_bestIcon:(id)icons {
  NSString* path = nil;
  if ([icons isKindOfClass:NSString.class]) {
    path = icons;
  } else if ([icons isKindOfClass:NSDictionary.class]) {
    NSInteger best = 0;
    for (NSString* size in icons) {
      if (size.integerValue > best && [icons[size] isKindOfClass:NSString.class]) {
        best = size.integerValue;
        path = icons[size];
      }
    }
  }
  if (!path.length) {
    return nil;
  }
  if ([path hasPrefix:@"/"]) {
    path = [path substringFromIndex:1];
  }
  return [[NSImage alloc]
      initWithContentsOfURL:[_installDirectory URLByAppendingPathComponent:path]];
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
  }
  return self;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<OEExtensionAction %@ pinned=%d badge=%@>",
                                    _extensionIdentifier, _pinned, _badgeText];
}

- (void)oe_applyBadgeText:(NSString*)badgeText
               badgeColor:(NSColor*)badgeColor
                    title:(NSString*)title
                  enabled:(BOOL)enabled {
  _badgeText = badgeText.length ? [badgeText copy] : nil;
  _badgeBackgroundColor = badgeColor;
  if (title.length) {
    _title = [title copy];
  }
  _enabled = _enabled && enabled;
}

@end

#pragma mark - OEExtensionManager

@implementation OEExtensionManager {
  NSArray<OEExtension*>* _installed;
  dispatch_source_t _watcher;
  BOOL _reloadScheduled;
}

- (instancetype)initOEWithContext:(OEBrowserContext*)context {
  if ((self = [super init])) {
    _context = context;
    _installed = @[];
    [self reload];
    [self oe_watch];
  }
  return self;
}

- (void)dealloc {
  if (_watcher) {
    dispatch_source_cancel(_watcher);
  }
}

+ (NSURL*)managementPageURL {
  return [NSURL URLWithString:@"chrome://extensions"];
}

+ (NSURL*)webStorePageURLForExtensionIdentifier:(NSString*)identifier {
  return [NSURL
      URLWithString:[@"https://chromewebstore.google.com/detail/"
                        stringByAppendingString:identifier]];
}

- (NSArray<OEExtension*>*)installedExtensions {
  return _installed;
}

- (nullable OEExtension*)extensionWithIdentifier:(NSString*)identifier {
  for (OEExtension* e in _installed) {
    if ([e.identifier isEqualToString:identifier]) {
      return e;
    }
  }
  return nil;
}

- (void)reload {
  NSURL* dir = _context.directory;
  if (!dir) {
    // Ephemeral contexts have no folder (patch P3 reads the live registry).
    return;
  }
  NSMutableDictionary* settings = [NSMutableDictionary dictionary];
  // Secure Preferences holds MAC-protected entries; Preferences holds the
  // rest. Merge both, Secure Preferences winning.
  for (NSString* file in @[ @"Preferences", @"Secure Preferences" ]) {
    NSDictionary* prefs = ReadJSON([dir URLByAppendingPathComponent:file]);
    NSDictionary* s = prefs[@"extensions"][@"settings"];
    if ([s isKindOfClass:NSDictionary.class]) {
      [s enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSDictionary* value,
                                             BOOL* stop) {
        if (![value isKindOfClass:NSDictionary.class]) {
          return;
        }
        NSMutableDictionary* merged =
            [settings[key] mutableCopy] ?: [NSMutableDictionary dictionary];
        [merged addEntriesFromDictionary:value];
        settings[key] = merged;
      }];
    }
  }
  NSMutableArray* out = [NSMutableArray array];
  [settings enumerateKeysAndObjectsUsingBlock:^(NSString* key,
                                                NSDictionary* value,
                                                BOOL* stop) {
    OEExtension* e = [[OEExtension alloc] initOEWithIdentifier:key
                                                       settings:value
                                                     profileDir:dir];
    if (e) {
      [out addObject:e];
    }
  }];
  [out sortUsingComparator:^NSComparisonResult(OEExtension* a, OEExtension* b) {
    return [a.name localizedCaseInsensitiveCompare:b.name];
  }];
  BOOL changed = ![[_installed valueForKey:@"identifier"]
      isEqualToArray:[out valueForKey:@"identifier"]];
  if (!changed) {
    for (NSUInteger i = 0; i < out.count; ++i) {
      if ([out[i] isEnabled] != [_installed[i] isEnabled]) {
        changed = YES;
        break;
      }
    }
  }
  _installed = out;
  if (changed) {
    if ([_delegate respondsToSelector:@selector(extensionManagerDidChange)]) {
      [_delegate extensionManagerDidChange];
    }
    OEBrowserContext* context = _context;
    if (context) {
      [OEEngine.shared oe_extensionsChangedInContext:context];
    }
  }
}

// Chromium rewrites Preferences atomically (write + rename) a few seconds
// after a change, so watch the directory and debounce.
- (void)oe_watch {
  NSURL* dir = _context.directory;
  if (!dir) {
    return;
  }
  int fd = open(dir.fileSystemRepresentation, O_EVTONLY);
  if (fd < 0) {
    [NSFileManager.defaultManager createDirectoryAtURL:dir
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    fd = open(dir.fileSystemRepresentation, O_EVTONLY);
    if (fd < 0) {
      return;
    }
  }
  _watcher = dispatch_source_create(DISPATCH_SOURCE_TYPE_VNODE, fd,
                                    DISPATCH_VNODE_WRITE,
                                    dispatch_get_main_queue());
  __weak OEExtensionManager* weakSelf = self;
  dispatch_source_set_event_handler(_watcher, ^{
    OEExtensionManager* strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_reloadScheduled) {
      return;
    }
    strongSelf->_reloadScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 2),
                   dispatch_get_main_queue(), ^{
                     OEExtensionManager* s = weakSelf;
                     if (s) {
                       s->_reloadScheduled = NO;
                       [s reload];
                     }
                   });
  });
  dispatch_source_set_cancel_handler(_watcher, ^{
    close(fd);
  });
  dispatch_resume(_watcher);
}

@end
