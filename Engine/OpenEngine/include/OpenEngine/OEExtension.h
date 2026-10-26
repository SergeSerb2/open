#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEBrowserContext;
@class OEExtension;

/// One installed Chrome extension (ADK ExtensionInfo).
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtension : NSObject
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* version;
@property(nonatomic, readonly, copy) NSString* summary;
@property(nonatomic, readonly) NSInteger manifestVersion;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// Unpacked (developer or --load-extension) install, not a Web Store CRX.
@property(nonatomic, readonly, getter=isUnpacked) BOOL unpacked;
@property(nonatomic, readonly, copy) NSURL* installDirectory;
/// Best manifest icon (largest), loaded from disk.
@property(nonatomic, readonly, nullable) NSImage* icon;
/// chrome-extension://<id>/<options_ui.page or options_page>.
@property(nonatomic, readonly, copy, nullable) NSURL* optionsURL;
@property(nonatomic, readonly, copy) NSArray<NSString*>* permissions;
@property(nonatomic, readonly, copy) NSArray<NSString*>* hostPermissions;
@end

/// Immutable snapshot of one toolbar action (ADK ExtensionToolbarAction),
/// for drawing our own button. Rebuilt whenever it changes; see
/// -[OEBrowserDelegate browserDidUpdateExtensionActions:].
///
/// Stock CEF has no action model, so the snapshot comes from the manifest:
/// title, icon, and popup are the manifest defaults, and badgeText is nil.
/// Dynamic chrome.action.setIcon/setTitle/setBadgeText/setPopup need fork
/// patch P2 (docs/engine-patches.md).
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionAction : NSObject
@property(nonatomic, readonly, copy) NSString* extensionIdentifier;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, nullable) NSImage* icon;
@property(nonatomic, readonly, copy, nullable) NSString* badgeText;
@property(nonatomic, readonly, copy, nullable) NSColor* badgeBackgroundColor;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// The action opens a popup page. NO means a click fires
/// chrome.action.onClicked (needs patch P2).
@property(nonatomic, readonly) BOOL hasPopup;
@property(nonatomic, readonly, copy, nullable) NSURL* popupURL;
@end

NS_SWIFT_UI_ACTOR
@protocol OEExtensionManagerDelegate <NSObject>
@optional
/// The installed set or an extension's enabled state changed.
- (void)extensionManagerDidChange;
@end

/// Chrome extensions of one browser context (ADK
/// BrowserContextExtensions).
///
/// Stock CEF removed its extension API in M128 (CefExtension and
/// CefRequestContext::LoadExtension went away with the Alloy runtime), but
/// the Chrome extension system still runs in every context. Until fork patch
/// P3, this class reads the installed set from the profile's Preferences and
/// each manifest, and watches the folder for changes. Install from the Web
/// Store works through a Chrome-style web content; --load-extension works for
/// the default context.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionManager : NSObject
@property(nonatomic, readonly, weak) OEBrowserContext* context;
@property(nonatomic, weak, nullable) id<OEExtensionManagerDelegate> delegate;

/// Installed extensions, sorted by name. Excludes Chromium component
/// extensions (PDF viewer, Web Store helper, and so on).
@property(nonatomic, readonly, copy) NSArray<OEExtension*>* installedExtensions;
- (nullable OEExtension*)extensionWithIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(extension(identifier:));

/// Re-reads the installed set now (it also refreshes on its own when
/// Chromium writes its preferences).
- (void)reload;

/// chrome://extensions (needs a Chrome-style web content in stock CEF).
@property(class, nonatomic, readonly) NSURL* managementPageURL;
/// https://chromewebstore.google.com/detail/<id>
+ (NSURL*)webStorePageURLForExtensionIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(webStorePageURL(extensionIdentifier:));
@end

NS_HEADER_AUDIT_END(nullability, sendability)
