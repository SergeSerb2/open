#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEBrowser;
@class OEBrowserContext;
@class OEContextMenuItem;
@class OEExtensionAction;
@class OEExtensionActionMenu;
@class OEWebContent;

/// How an action is run (Chrome's ToolbarActionViewModel::InvocationSource).
typedef NS_ENUM(NSInteger, OEExtensionActionSource) {
  OEExtensionActionSourceToolbarButton = 0,
  OEExtensionActionSourceMenuEntry = 1,
  OEExtensionActionSourceCommand = 2,
} NS_SWIFT_NAME(OEBrowser.ExtensionActionSource);

/// What opened the action popup.
typedef NS_ENUM(NSInteger, OEExtensionPopupSource) {
  /// A click, a menu entry, or the shell's run call.
  OEExtensionPopupSourceUser = 0,
  /// The extension's _execute_action keyboard command.
  OEExtensionPopupSourceCommand = 1,
  /// chrome.action.openPopup().
  OEExtensionPopupSourceAPI = 2,
} NS_SWIFT_NAME(OEBrowser.ExtensionPopupSource);

/// Where an action's context menu opens
/// (ExtensionContextMenuModel::ContextMenuSource).
typedef NS_ENUM(NSInteger, OEExtensionMenuSource) {
  OEExtensionMenuSourceToolbarAction = 0,
  OEExtensionMenuSourceMenuItem = 1,
} NS_SWIFT_NAME(OEBrowser.ExtensionMenuSource);

NS_SWIFT_UI_ACTOR
@protocol OEBrowserDelegate <NSObject>
@optional
/// The list or the order of the toolbar actions changed (install,
/// uninstall, enable, disable, pin, unpin, move), or the window's live
/// model came or went (extensionActionsReady changed). Redraw from
/// -extensionActions. Also sent for a single action's change when the
/// delegate does not implement browser:didUpdateExtensionAction:.
- (void)browserDidUpdateExtensionActions:(OEBrowser*)browser
    NS_SWIFT_NAME(browserDidUpdateExtensionActions(_:));
/// One action's state changed (icon, badge, title, enabled, wants-to-run,
/// site access, popup shown, or the active tab changed). Coalesced: at most
/// one call per action per run loop turn. -extensionActions already has the
/// new snapshot.
- (void)browser:(OEBrowser*)browser
    didUpdateExtensionAction:(OEExtensionAction*)action
    NS_SWIFT_NAME(browser(_:didUpdate:));

/// An action popup opened. Host `popup.view` in a panel anchored to the
/// action's button. The engine created the web content and owns its
/// lifetime: it reports size changes and the close below.
/// During didOpenExtensionPopup, didResizeExtensionPopup and
/// extensionPopupIsReady, -closeExtensionPopup, -close and action execution
/// are safe to request: OpenEngine defers them to the next main-queue turn,
/// after Chromium's popup/ExtensionViewHost callback returns. A deferred
/// popup close applies only to that popup, never to its replacement.
- (void)browser:(OEBrowser*)browser
    didOpenExtensionPopup:(OEWebContent*)popup
                forAction:(OEExtensionAction*)action
    NS_SWIFT_NAME(browser(_:didOpenExtensionPopup:for:));
/// The popup page asked for a new size (Chrome limits: 25x25 to 800x600).
- (void)browser:(OEBrowser*)browser
    didResizeExtensionPopup:(OEWebContent*)popup
                     toSize:(NSSize)size
    NS_SWIFT_NAME(browser(_:didResizeExtensionPopup:to:));
/// The popup closed: window.close(), Escape, -closeExtensionPopup, the
/// active tab changed (as in Chrome), the extension unloaded, reloaded or
/// crashed, or the window closed. Remove its view. Calls from
/// -closeExtensionPopup and -executeExtensionAction: arrive inside them.
- (void)browser:(OEBrowser*)browser
    didCloseExtensionPopup:(OEWebContent*)popup
    NS_SWIFT_NAME(browser(_:didCloseExtensionPopup:));
/// The popup's first load stopped: show it now (Chrome shows its bubble at
/// this point). Arrives after didOpenExtensionPopup (P2).
- (void)browser:(OEBrowser*)browser
    extensionPopupIsReady:(OEWebContent*)popup
    NS_SWIFT_NAME(browser(_:extensionPopupIsReady:));
/// The user ran an action that is disabled for the active tab. Chrome shows
/// the action's context menu instead: show
/// contextMenu(forExtensionAction:source:) at the action's button.
- (void)browser:(OEBrowser*)browser
    requestsContextMenuForExtensionAction:(NSString*)extensionIdentifier
    NS_SWIFT_NAME(browser(_:requestsContextMenuForExtensionAction:));

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
/// chrome.tabs.discard: return YES if the shell will unload `webContent`
/// with its own tab sleep. Do not close it inside this call. Chromium
/// never discards these tabs itself (memory pressure, Memory Saver). Without
/// this method the request is refused.
- (BOOL)browser:(OEBrowser*)browser
    requestsDiscardOfWebContent:(OEWebContent*)webContent
    NS_SWIFT_NAME(browser(_:requestsDiscardOf:));
/// chrome.windows.remove on this window while it has tabs. The window stays
/// open; the shell decides. Without this method the request is refused.
- (void)browserRequestsClose:(OEBrowser*)browser
    NS_SWIFT_NAME(browserRequestsClose(_:));
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
/// Pending strip changes are flushed before executing an action or building
/// its context menu, including a focus change in the same event.
@property(nonatomic, weak, nullable) OEWebContent* activeWebContent;

#pragma mark Extension actions
/// Every toolbar action of the enabled extensions of this window's profile:
/// pinned actions in pinned order first, then the rest. With a live model
/// (extensionActionsReady) the snapshots are for the active tab. Without
/// one they come from the profile's list (`live` NO): pins and defaults,
/// and pin changes made in other windows show at the next update. Empty
/// until the profile's context is ready; browserDidUpdateExtensionActions
/// follows.
@property(nonatomic, readonly, copy) NSArray<OEExtensionAction*>* extensionActions;
/// YES while Chrome's toolbar action model for this window is live (P2). It
/// needs the window's hidden Chrome window, which exists only while the
/// window has a live Chrome style tab: a new window, or one whose tabs all
/// sleep, has no live actions.
@property(nonatomic, readonly) BOOL extensionActionsReady;
/// Pins or unpins an action (the profile's extensions.pinned_extensions;
/// every window of the profile gets browserDidUpdateExtensionActions).
- (void)setExtensionAction:(NSString*)extensionIdentifier
                    pinned:(BOOL)pinned
    NS_SWIFT_NAME(setExtensionAction(_:pinned:));
/// Moves a pinned action.
- (void)moveExtensionAction:(NSString*)extensionIdentifier
              toPinnedIndex:(NSUInteger)index
    NS_SWIFT_NAME(moveExtensionAction(_:toPinnedIndex:));
/// Runs an action for the active tab as the user would: opens its popup
/// (see the delegate) or fires chrome.action.onClicked, and runs blocked
/// scripts when the extension wants to run. Running the action whose popup
/// is open closes it. A disabled action asks for its context menu instead
/// (browser:requestsContextMenuForExtensionAction:). Returns NO for an
/// unknown id and without a live model (extensionActionsReady NO).
- (BOOL)executeExtensionAction:(NSString*)extensionIdentifier
                        source:(OEExtensionActionSource)source
    NS_SWIFT_NAME(executeExtensionAction(_:source:));
/// executeExtensionAction(_:source: .toolbarButton).
- (BOOL)executeExtensionAction:(NSString*)extensionIdentifier
    NS_SWIFT_NAME(executeExtensionAction(_:));
/// The open popup, if any. One per browser, like Chrome.
@property(nonatomic, readonly, nullable) OEWebContent* extensionPopup;
/// Valid from didOpenExtensionPopup until didCloseExtensionPopup.
@property(nonatomic, readonly) OEExtensionPopupSource extensionPopupSource;
@property(nonatomic, readonly, copy, nullable) NSString* extensionPopupExtensionIdentifier;
- (void)closeExtensionPopup;
/// YES while the open popup must stay open when it loses focus, as in
/// Chrome: an app-modal JavaScript dialog is showing, a web-modal dialog of
/// the popup is showing (a WebAuthn or passkey request), or DevTools
/// inspects the popup. Read it when the popup's panel resigns key, and keep
/// the panel open while it is YES. The shell's own JavaScript dialogs for
/// tabs are not included. NO without a popup.
@property(nonatomic, readonly) BOOL extensionPopupStaysOpenOnBlur;
/// The action's context menu (Chrome's ExtensionContextMenuModel: name,
/// pin, options, site access, remove, manage), or nil for an unknown action
/// or without a live model. Show the items, then call -selectCommand: or
/// -cancel.
- (nullable OEExtensionActionMenu*)contextMenuForExtensionAction:(NSString*)extensionIdentifier
                                                         source:(OEExtensionMenuSource)source
    NS_SWIFT_NAME(contextMenu(forExtensionAction:source:));

/// Closes the popup and detaches every web content. Call when the window
/// closes.
- (void)close;
@end

/// One toolbar action's context menu (fork patch P2). Each menu has its own
/// Chrome menu model, kept until -selectCommand:, -cancel, or the object goes
/// away, so several menus can be open at once. The model also goes away
/// with the action or with the window's live model.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEExtensionActionMenu : NSObject
@property(nonatomic, readonly, copy) NSString* extensionIdentifier;
/// Radio items come as checked items.
@property(nonatomic, readonly, copy) NSArray<OEContextMenuItem*>* items;
/// Runs an enabled item of this menu. NO if the menu was used, cancelled or
/// is gone, or `commandIdentifier` is not an enabled item.
- (BOOL)selectCommand:(NSInteger)commandIdentifier
    NS_SWIFT_NAME(select(command:));
- (void)cancel;
@end

NS_HEADER_AUDIT_END(nullability, sendability)
