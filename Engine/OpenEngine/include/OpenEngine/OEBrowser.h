#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEBrowser;
@class OEBrowserContext;
@class OEExtensionAction;
@class OEWebContent;

NS_SWIFT_UI_ACTOR
@protocol OEBrowserDelegate <NSObject>
@optional
/// The toolbar actions changed (install, uninstall, enable, or, with patch
/// P2, a dynamic icon/title/badge change). Redraw from -extensionActions.
- (void)browserDidUpdateExtensionActions:(OEBrowser*)browser
    NS_SWIFT_NAME(browserDidUpdateExtensionActions(_:));

/// An action popup opened. Host `popup.view` in a panel anchored to the
/// action's button. The engine created the web content and owns its
/// lifetime: it reports size changes and the close below.
- (void)browser:(OEBrowser*)browser
    didOpenExtensionPopup:(OEWebContent*)popup
                forAction:(OEExtensionAction*)action
    NS_SWIFT_NAME(browser(_:didOpenExtensionPopup:for:));
/// The popup page asked for a new size (Chrome limits: 25x25 to 800x600).
- (void)browser:(OEBrowser*)browser
    didResizeExtensionPopup:(OEWebContent*)popup
                     toSize:(NSSize)size
    NS_SWIFT_NAME(browser(_:didResizeExtensionPopup:to:));
/// The popup closed (window.close(), -closeExtensionPopup, or a new popup
/// replaced it). Remove its view.
- (void)browser:(OEBrowser*)browser
    didCloseExtensionPopup:(OEWebContent*)popup
    NS_SWIFT_NAME(browser(_:didCloseExtensionPopup:));
@end

/// One shell window's tab strip (ADK "Browser"): the ordered web contents of
/// a window, which one is active, and the window's extension actions.
///
/// This is the object Chromium's extension system will see as a window:
/// with fork patch P1 (docs/engine-patches.md) every OEBrowser is mirrored
/// into a hidden Chrome Browser + TabStripModel, so chrome.tabs and
/// chrome.windows see Open's tabs. In stock CEF it is bookkeeping only, but
/// the shell already keeps it exact (insert, remove, move, activate, pin)
/// so the patch needs no shell change.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEBrowser : NSObject

- (instancetype)initWithContext:(OEBrowserContext*)context
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Unique per process (chrome.windows window id with patch P1).
@property(nonatomic, readonly) NSInteger identifier;
@property(nonatomic, readonly) OEBrowserContext* context;
@property(nonatomic, weak, nullable) id<OEBrowserDelegate> delegate;
/// The shell window, for focus and bounds (chrome.windows.get/update).
@property(nonatomic, weak, nullable) NSWindow* window;

#pragma mark Tab strip
/// Tabs in sidebar order: favorites, pinned, then today (Arc's visual order).
@property(nonatomic, readonly, copy) NSArray<OEWebContent*>* webContents;
- (void)insertWebContent:(OEWebContent*)webContent
                 atIndex:(NSUInteger)index
    NS_SWIFT_NAME(insert(_:at:));
/// Also happens automatically when the content closes.
- (void)removeWebContent:(OEWebContent*)webContent NS_SWIFT_NAME(remove(_:));
- (void)moveWebContent:(OEWebContent*)webContent
               toIndex:(NSUInteger)index NS_SWIFT_NAME(move(_:to:));
/// Pinned tabs (Arc favorites and pinned section) map to chrome.tabs pinned.
- (void)setPinned:(BOOL)pinned
    forWebContent:(OEWebContent*)webContent NS_SWIFT_NAME(setPinned(_:for:));
- (BOOL)isPinnedWebContent:(OEWebContent*)webContent
    NS_SWIFT_NAME(isPinned(_:));
/// The selected tab. In Split View, the focused pane.
@property(nonatomic, weak, nullable) OEWebContent* activeWebContent;

#pragma mark Extension actions
/// Toolbar actions of enabled extensions, in pin order.
@property(nonatomic, readonly, copy) NSArray<OEExtensionAction*>* extensionActions;
/// Runs an action for the active tab, like a click on its toolbar button.
/// A popup action opens its popup (see the delegate); returns NO when the
/// action cannot run (unknown id, disabled, or a popup-less action, which
/// needs patch P2).
- (BOOL)executeExtensionAction:(NSString*)extensionIdentifier
    NS_SWIFT_NAME(executeExtensionAction(_:));
/// The open popup, if any. One per browser, like Chrome.
@property(nonatomic, readonly, nullable) OEWebContent* extensionPopup;
- (void)closeExtensionPopup;

/// Closes the popup and detaches every web content. Call when the window
/// closes.
- (void)close;
@end

NS_HEADER_AUDIT_END(nullability, sendability)
