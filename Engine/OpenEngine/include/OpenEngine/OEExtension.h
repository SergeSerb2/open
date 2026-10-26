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

/// Site access of an action for the active tab (Chrome's
/// PermissionsManager): what the extension may do on this site.
typedef NS_ENUM(NSInteger, OEExtensionSiteAccess) {
  /// No host permission for this site.
  OEExtensionSiteAccessNone = 0,
  /// Runs when the user clicks (UserSiteAccess::kOnClick).
  OEExtensionSiteAccessOnClick = 1,
  /// On this site (kOnSite).
  OEExtensionSiteAccessOnSite = 2,
  /// On all sites (kOnAllSites).
  OEExtensionSiteAccessOnAllSites = 3,
  /// The user blocked all extensions on this site.
  OEExtensionSiteAccessBlocked = 4,
} NS_SWIFT_NAME(OEExtensionAction.SiteAccess);

/// Immutable snapshot of one toolbar action (ADK ExtensionToolbarAction),
/// for drawing our own button, for the window's active tab. Rebuilt whenever
/// it changes; see -[OEBrowserDelegate browser:didUpdateExtensionAction:].
///
/// With fork patch P2 (Chrome style windows) the values come from Chrome's
/// toolbar action model, including chrome.action.setIcon/setTitle/
/// setBadgeText/setPopup and per-tab state. Without it (Alloy style, or
/// before the window has a tab) the snapshot comes from the manifest: title,
/// icon, and popup are the manifest defaults, and badgeText is nil.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionAction : NSObject
@property(nonatomic, readonly, copy) NSString* extensionIdentifier;
/// The action title (chrome.action.setTitle, else the manifest's
/// default_title, else the extension name).
@property(nonatomic, readonly, copy) NSString* title;
/// The extension's name.
@property(nonatomic, readonly, copy) NSString* extensionName;
/// Title plus badge, for accessibility (ExtensionActionViewModel).
@property(nonatomic, readonly, copy) NSString* accessibleName;
@property(nonatomic, readonly, copy) NSString* tooltip;
/// The 16x16 pt plain action icon (no badge), for menus.
@property(nonatomic, readonly, nullable) NSImage* icon;
/// The 28x28 pt image Chrome's toolbar draws: icon, badge, disabled
/// grayscale, and the wants-to-run decoration (P2; nil without it).
@property(nonatomic, readonly, nullable) NSImage* toolbarImage;
@property(nonatomic, readonly, copy, nullable) NSString* badgeText;
@property(nonatomic, readonly, copy, nullable) NSColor* badgeBackgroundColor;
/// nil means automatic contrast.
@property(nonatomic, readonly, copy, nullable) NSColor* badgeTextColor;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// The action opens a popup page. NO means a click fires
/// chrome.action.onClicked.
@property(nonatomic, readonly) BOOL hasPopup;
/// The manifest popup (without P2 only; nil with it).
@property(nonatomic, readonly, copy, nullable) NSURL* popupURL;
/// Pinned to the toolbar (the profile's extensions.pinned_extensions).
@property(nonatomic, readonly, getter=isPinned) BOOL pinned;
/// -1 when unpinned.
@property(nonatomic, readonly) NSInteger pinnedIndex;
/// The extension has blocked scripts on this page that a click runs.
@property(nonatomic, readonly) BOOL wantsToRun;
@property(nonatomic, readonly) OEExtensionSiteAccess siteAccess;
@property(nonatomic, readonly, getter=isShowingPopup) BOOL showingPopup;
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
