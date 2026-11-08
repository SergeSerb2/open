#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEBrowserContext;
@class OEExtension;
@class OEWebContent;
@class OEBrowser;
@class OEExtensionManager;
@class OEExtensionPrompt;

/// Parsed Chromium omnibox suggestion. Ranges use UTF-16 offsets.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEOmniboxSuggestion : NSObject
@property(nonatomic, readonly, copy) NSString* content;
@property(nonatomic, readonly, copy) NSString* descriptionText;
@property(nonatomic, readonly, copy) NSArray<NSValue*>* matchRanges;
@property(nonatomic, readonly, copy) NSArray<NSValue*>* dimRanges;
@property(nonatomic, readonly, copy) NSArray<NSValue*>* urlRanges;
@property(nonatomic, readonly, getter=isDeletable) BOOL deletable;
@end

typedef NS_ENUM(NSInteger, OEOmniboxDisposition) {
  OEOmniboxDispositionCurrentTab,
  OEOmniboxDispositionNewForegroundTab,
  OEOmniboxDispositionNewBackgroundTab,
};

/// One installed Chrome extension (ADK ExtensionInfo).
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtension : NSObject
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* version;
@property(nonatomic, readonly, copy) NSString* summary;
@property(nonatomic, readonly) NSInteger manifestVersion;
@property(nonatomic, readonly) BOOL hasAction;
@property(nonatomic, readonly) BOOL fromWebStore;
@property(nonatomic, readonly, copy, nullable) NSURL* homepageURL;
@property(nonatomic, readonly) NSUInteger disableReasons;
@property(nonatomic, readonly, copy, nullable) NSString* omniboxKeyword;
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
  /// Granted for this tab only, until it navigates away (activeTab after a
  /// click).
  OEExtensionSiteAccessThisTab = 5,
} NS_SWIFT_NAME(OEExtensionAction.SiteAccess);

/// Immutable snapshot of one toolbar action (ADK ExtensionToolbarAction),
/// for drawing our own button, for the window's active tab. Rebuilt whenever
/// it changes; see -[OEBrowserDelegate browser:didUpdateExtensionAction:].
///
/// With fork patch P2 the values come from Chrome's toolbar action model,
/// including chrome.action.setIcon/setTitle/setBadgeText/setPopup and
/// per-tab state (`live`). While the window has no live Chrome tab they come
/// from the profile's action list: pins and the tab-independent defaults,
/// and the action cannot run (`live` NO).
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
/// The manifest popup, for display only (a window whose profile the engine
/// refused, OEBrowser.extensionActions); nil from Chrome's model.
@property(nonatomic, readonly, copy, nullable) NSURL* popupURL;
/// Pinned to the toolbar (the profile's extensions.pinned_extensions).
@property(nonatomic, readonly, getter=isPinned) BOOL pinned;
/// -1 when unpinned.
@property(nonatomic, readonly) NSInteger pinnedIndex;
/// The extension has blocked scripts on this page that a click runs.
@property(nonatomic, readonly) BOOL wantsToRun;
@property(nonatomic, readonly) OEExtensionSiteAccess siteAccess;
@property(nonatomic, readonly, getter=isShowingPopup) BOOL showingPopup;
/// From the window's live toolbar model: per-tab state, and the action can
/// run. NO for the profile's list (no live Chrome tab in the window).
@property(nonatomic, readonly, getter=isLive) BOOL live;
@property(nonatomic, readonly, copy, nullable) NSString* shortcutKeyEquivalent;
@property(nonatomic, readonly) NSEventModifierFlags shortcutModifierFlags;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionCommand : NSObject
@property(nonatomic, readonly, copy) NSString* extensionIdentifier;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* summary;
/// Chromium's Cocoa form: uppercase letters encode Shift; the modifier mask
/// omits an implied Shift (e.g. "Y" + Command means Command-Shift-Y).
@property(nonatomic, readonly, copy) NSString* keyEquivalent;
@property(nonatomic, readonly) NSEventModifierFlags modifierFlags;
@property(nonatomic, readonly, getter=isGlobal) BOOL global;
@property(nonatomic, readonly, getter=isActionCommand) BOOL actionCommand;
@end

typedef NS_ENUM(NSInteger, OEExtensionPromptType) {
  OEExtensionPromptTypeInstall,
  OEExtensionPromptTypeReEnable,
  OEExtensionPromptTypePermissions,
  OEExtensionPromptTypeExternalInstall,
  OEExtensionPromptTypeRemoteInstall,
  OEExtensionPromptTypeRepair,
  OEExtensionPromptTypeUninstall,
};
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionPermissionMessage : NSObject
@property(nonatomic, readonly, copy) NSString* message;
@property(nonatomic, readonly, copy) NSArray<NSString*>* details;
@end

/// Main-thread object. Retain until answered. Release without answering cancels.
/// Answering twice is harmless. Continuations run on a later main-loop turn.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionPrompt : NSObject
@property(nonatomic, readonly) OEExtensionPromptType type;
@property(nonatomic, readonly, copy) NSString* extensionIdentifier;
@property(nonatomic, readonly, copy) NSString* extensionName;
@property(nonatomic, readonly, nullable) NSImage* icon;
@property(nonatomic, readonly, copy) NSString* chromiumTitle;
@property(nonatomic, readonly, copy) NSString* chromiumAcceptLabel;
@property(nonatomic, readonly, copy) NSString* chromiumCancelLabel;
@property(nonatomic, readonly, copy) NSArray<OEExtensionPermissionMessage*>* permissions;
@property(nonatomic, readonly, copy) NSArray<NSString*>* retainedFiles;
@property(nonatomic, readonly, copy) NSArray<NSString*>* retainedDevices;
@property(nonatomic, readonly, copy, nullable) NSString* triggeringExtensionName;
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;
@property(nonatomic, readonly, weak, nullable) OEBrowser* browser;
- (void)accept;
- (void)cancel;
@end

NS_SWIFT_UI_ACTOR
@protocol OEExtensionManagerDelegate <NSObject>
@optional
/// All events arrive outside Chromium model notifications. Callbacks may
/// close or replace a context or window. Release managers on the main thread.
- (void)extensionManagerDidChange:(OEExtensionManager*)manager;
- (void)extensionManager:(OEExtensionManager*)manager
    didInstallExtension:(OEExtension*)extension byUser:(BOOL)byUser
    NS_SWIFT_NAME(extensionManager(_:didInstall:byUser:));
- (void)extensionManager:(OEExtensionManager*)manager
    didFailToLoadExtensionAt:(NSURL*)path error:(NSString*)message
    NS_SWIFT_NAME(extensionManager(_:didFailToLoadExtensionAt:error:));
- (void)extensionManagerDidBecomeReady:(OEExtensionManager*)manager;
- (void)extensionManagerDidChangeCommands:(OEExtensionManager*)manager;
/// Without this optional method Chromium keeps its existing native dialogs.
- (void)extensionManager:(OEExtensionManager*)manager showPrompt:(OEExtensionPrompt*)prompt
    NS_SWIFT_NAME(extensionManager(_:show:));
@end

typedef NS_ENUM(NSInteger, OEExtensionInstallResult) {
  OEExtensionInstallResultInstalled = 0,
  OEExtensionInstallResultCancelled = 1,
  OEExtensionInstallResultFailed = 2,
};

/// Live Chromium extensions of this context, including non-default profiles.
/// No Preferences reader, filesystem watcher, timer, or second state store.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionManager : NSObject
@property(nonatomic, readonly, weak) OEBrowserContext* context;
@property(nonatomic, weak, nullable) id<OEExtensionManagerDelegate> delegate;
@property(nonatomic, readonly, getter=isReady) BOOL ready;
/// Installed non-component extensions, sorted by name, including disabled ones.
@property(nonatomic, readonly, copy) NSArray<OEExtension*>* installedExtensions;
@property(nonatomic, readonly, copy) NSArray<OEExtensionCommand*>* commands;
- (nullable OEExtension*)extensionWithIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(extension(identifier:));
/// Refreshes the live snapshot and notifies observers. No disk reads.
- (void)reload;
- (void)setEnabled:(BOOL)enabled forExtension:(NSString*)identifier;
/// Always asks for removal consent first.
- (void)uninstallExtension:(NSString*)identifier window:(nullable NSWindow*)window;
- (void)reloadExtension:(NSString*)identifier;
- (void)installFromWebStore:(NSString*)identifier window:(nullable NSWindow*)window
    completion:(void (^)(BOOL installed, NSString* _Nullable error))completion;
/// Real local CRX install, only with --open-automation. Uses Chromium consent.
- (BOOL)installLocalCRX:(NSURL*)file webContent:(OEWebContent*)webContent;
/// Automation only. Completes exactly once on a later main-queue turn, including
/// rejection and context closure. Installed returns an ID; failed returns the
/// Chromium error text. Cancelled has neither. No delegate error event is sent.
/// The completion may close or replace the manager/context.
- (void)installLocalCRX:(NSURL*)file
    completion:(void (^)(OEExtensionInstallResult result,
                         NSString* _Nullable extensionID,
                         NSString* _Nullable error))completion;
@property(class, nonatomic, readonly) NSURL* managementPageURL;
+ (NSURL*)webStorePageURLForExtensionIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(webStorePageURL(extensionIdentifier:));
@end

NS_HEADER_AUDIT_END(nullability, sendability)
