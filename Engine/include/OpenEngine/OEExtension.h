#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEProfile;
@class OEWebView;
@class OEExtension;

/// One installed Chrome extension, as our own toolbar/sidebar UI needs it.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(Extension)
OE_EXPORT @interface OEExtension : NSObject
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* name;
@property(nonatomic, readonly, copy) NSString* version;
@property(nonatomic, readonly, copy) NSString* summary;
@property(nonatomic, readonly) NSInteger manifestVersion;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
/// Unpacked (developer) install rather than a Web Store / CRX install.
@property(nonatomic, readonly, getter=isUnpacked) BOOL unpacked;
@property(nonatomic, readonly, copy) NSURL* installDirectory;
/// Best manifest icon (largest), loaded from disk.
@property(nonatomic, readonly, nullable) NSImage* icon;
/// chrome-extension://<id>/<options_page or options_ui.page>.
@property(nonatomic, readonly, copy, nullable) NSURL* optionsURL;

/// The toolbar action (MV3 "action", MV2 "browser_action"/"page_action").
@property(nonatomic, readonly) BOOL hasAction;
/// Manifest default title. Dynamic chrome.action.setTitle() is not visible
/// yet (see engine-spike.md gap G3).
@property(nonatomic, readonly, copy, nullable) NSString* actionTitle;
/// Manifest default popup. nil if the action has no popup (it fires
/// chrome.action.onClicked instead).
@property(nonatomic, readonly, copy, nullable) NSURL* actionPopupURL;
/// Dynamic badge text. Always nil until gap G3 is fixed.
@property(nonatomic, readonly, copy, nullable) NSString* badgeText;

@property(nonatomic, readonly, copy) NSArray<NSString*>* permissions;
@property(nonatomic, readonly, copy) NSArray<NSString*>* hostPermissions;
@end

NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(ExtensionManagerDelegate)
@protocol OEExtensionManagerDelegate <NSObject>
@optional
/// The installed set or an extension's enabled state changed.
- (void)extensionManagerDidChange;
@end

/// Chrome extensions of one profile.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(ExtensionManager)
OE_EXPORT @interface OEExtensionManager : NSObject
@property(nonatomic, readonly, weak) OEProfile* profile;
@property(nonatomic, weak, nullable) id<OEExtensionManagerDelegate> delegate;

/// Installed extensions, sorted by name. Excludes Chromium component
/// extensions (PDF viewer, Web Store helper, etc.).
@property(nonatomic, readonly, copy) NSArray<OEExtension*>* installedExtensions;
- (nullable OEExtension*)extensionWithIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(extension(identifier:));

/// Re-reads the installed set from the profile now (it also refreshes when
/// Chromium writes its preferences).
- (void)reload;

/// chrome://extensions
@property(class, nonatomic, readonly) NSURL* managementPageURL;
/// https://chromewebstore.google.com/detail/<id>
+ (NSURL*)webStorePageURLForExtensionIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(webStorePageURL(extensionIdentifier:));

/// Creates a web view that shows the extension's action popup. The shell
/// places it (a floating panel anchored to its own toolbar button) and sizes
/// it from `-webView:didRequestContentSize:`. `activeWebView` is the tab the
/// popup acts on. Returns nil if the extension has no popup.
///
/// Spike status: the popup page renders and runs, but Chromium treats it as
/// a tab, not as an extension popup (gap G4 in engine-spike.md).
- (nullable OEWebView*)makeActionPopupWebViewForExtension:
                           (OEExtension*)extension
                                           activeWebView:
                                               (nullable OEWebView*)
                                                   activeWebView
    NS_SWIFT_NAME(makeActionPopupWebView(for:activeWebView:));
@end

NS_HEADER_AUDIT_END(nullability, sendability)
