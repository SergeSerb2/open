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

#pragma mark Tab requests from Chromium (fork patch P1)
// Chromium changes a window's tabs on its own for chrome.tabs and similar
// APIs. The shell owns the tabs: each change arrives here as a request, the
// shell applies it to its model, and the engine then puts Chromium's tab
// strip back in the shell's order (insert/move/setPinned/activeWebContent).
// Closes arrive as -[OEWebContentDelegate webContentDidRequestClose:].

/// Chromium opened a page in this window (chrome.tabs.create, an extension's
/// welcome or options page). The page is live but not shown: adopt it as a
/// tab (set its delegate, show its view, insert it), or close it. `active`:
/// Chromium asked for it to become the selected tab. Without this method
/// the engine closes the page.
- (void)browser:(OEBrowser*)browser
    didOpenWebContent:(OEWebContent*)webContent
               active:(BOOL)active
    NS_SWIFT_NAME(browser(_:didOpen:active:));
/// chrome.tabs.update({active: true}) and similar: select `webContent`.
- (void)browser:(OEBrowser*)browser
    requestsActivationOfWebContent:(OEWebContent*)webContent
    NS_SWIFT_NAME(browser(_:requestsActivationOf:));
/// chrome.tabs.move: move `webContent` to `index` in -webContents order.
- (void)browser:(OEBrowser*)browser
    requestsMoveOfWebContent:(OEWebContent*)webContent
                     toIndex:(NSUInteger)index
    NS_SWIFT_NAME(browser(_:requestsMoveOf:to:));
/// chrome.tabs.update({pinned}): pin or unpin `webContent`.
- (void)browser:(OEBrowser*)browser
    requestsPinned:(BOOL)pinned
     forWebContent:(OEWebContent*)webContent
    NS_SWIFT_NAME(browser(_:requestsPinned:for:));
@end

/// One shell window's tab strip (ADK "Browser") for one profile: the ordered
/// web contents of a window, which one is active, and the window's
/// extension actions.
///
/// This is the object Chromium's extension system sees as a window: with
/// fork patch P1 (docs/engine-patches.md) each OEBrowser owns a hidden
/// Chrome Browser + TabStripModel (CefTabStrip), and Chrome style web
/// contents inserted here are its tabs, hosted in our views. chrome.tabs and
/// chrome.windows see them in -webContents order (pinned first), with
/// activeWebContent as the active tab. Contents of other styles, and pages
/// that are not live, are bookkeeping only.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEBrowser : NSObject

- (instancetype)initWithContext:(OEBrowserContext*)context
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Unique per process.
@property(nonatomic, readonly) NSInteger identifier;
/// The chrome.windows id of this window's hidden Chrome window, or -1 while
/// it has no live Chrome style tab (Chrome closes a window without tabs; the
/// next tab gets a new window and id).
@property(nonatomic, readonly) NSInteger chromeWindowIdentifier;
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
