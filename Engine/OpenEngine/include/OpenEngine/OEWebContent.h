#import <AppKit/AppKit.h>
#import <OpenEngine/OEBrowserContext.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEBrowser;
@class OEBrowserContext;
@class OEWebContent;
@class OEOpenRequest;
@class OEJavaScriptDialog;
@class OEPermissionRequest;
@class OEContextMenu;
@class OEFindResult;

/// Creation options for an OEWebContent.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEWebContentConfiguration : NSObject <NSCopying>
- (instancetype)initWithContext:(OEBrowserContext*)context
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, strong) OEBrowserContext* context;
/// Default: the engine's defaultRuntimeStyle.
@property(nonatomic) OERuntimeStyle runtimeStyle;
/// Painted before the first frame. nil: white.
@property(nonatomic, copy, nullable) NSColor* backgroundColor;
/// Chrome style only: show Chrome's own toolbar (for experiments).
@property(nonatomic) BOOL showsChromeToolbar;
@end

/// Bit set passed to -webContent:didChange:. One callback can carry several.
typedef NS_OPTIONS(NSUInteger, OEWebContentChange) {
  OEWebContentChangeURL = 1u << 0,
  OEWebContentChangeTitle = 1u << 1,
  OEWebContentChangeFavicon = 1u << 2,
  OEWebContentChangeLoading = 1u << 3,
  OEWebContentChangeProgress = 1u << 4,
  OEWebContentChangeNavigationHistory = 1u << 5,
  OEWebContentChangeAudio = 1u << 6,
  OEWebContentChangeFullscreen = 1u << 7,
  OEWebContentChangeCrash = 1u << 8,
  OEWebContentChangeZoom = 1u << 9,
  OEWebContentChangeMediaCapture = 1u << 10,
  OEWebContentChangeStatusText = 1u << 11,
  OEWebContentChangeLive = 1u << 12,
  /// mediaSession changed (state, actions, metadata, position on seek or
  /// rate change; never on a playback timer).
  OEWebContentChangeMedia = 1u << 13,
  /// A video of the page entered or left Picture in Picture.
  OEWebContentChangePictureInPicture = 1u << 14,
};

typedef NS_ENUM(NSInteger, OEWebContentCrashState) {
  OEWebContentCrashStateNone = 0,
  OEWebContentCrashStateCrashed,
  OEWebContentCrashStateKilled,
  OEWebContentCrashStateOutOfMemory,
  OEWebContentCrashStateUnresponsive,
};

NS_SWIFT_UI_ACTOR
@protocol OEWebContentDelegate <NSObject>
@optional
/// State changed. Read the new values from the web content's properties.
- (void)webContent:(OEWebContent*)webContent
         didChange:(OEWebContentChange)changes
    NS_SWIFT_NAME(webContent(_:didChange:));

/// The page wants new content: target=_blank, window.open, middle click,
/// Cmd-click. Return a new OEWebContent (any configuration with the same
/// context) and put its view somewhere, or return nil to block. For
/// window.open the returned content keeps the opener relationship.
- (nullable OEWebContent*)webContent:(OEWebContent*)webContent
    createWebContentForOpenRequest:(OEOpenRequest*)request
    NS_SWIFT_NAME(webContent(_:createWebContentFor:));

/// window.close() was called, or the renderer asked to close.
- (void)webContentDidRequestClose:(OEWebContent*)webContent
    NS_SWIFT_NAME(webContentDidRequestClose(_:));

/// A key-down before the page sees it. Return YES if the shell handled it.
/// OEApplication.keyEquivalentHandler runs earlier for real key presses;
/// this hook also covers events that reach the page view directly.
- (BOOL)webContent:(OEWebContent*)webContent
    handleKeyEventBeforePage:(NSEvent*)event
    NS_SWIFT_NAME(webContent(_:handleKeyEventBeforePage:));
/// A key-down the page did not consume. Return YES if handled. If not
/// implemented (or NO), the engine offers it to the main menu.
- (BOOL)webContent:(OEWebContent*)webContent
    handleUnconsumedKeyEvent:(NSEvent*)event
    NS_SWIFT_NAME(webContent(_:handleUnconsumedKeyEvent:));

/// alert/confirm/prompt/beforeunload. Return YES and complete the dialog
/// later to show our own UI; return NO for the engine's default sheet.
- (BOOL)webContent:(OEWebContent*)webContent
    runJavaScriptDialog:(OEJavaScriptDialog*)dialog
    NS_SWIFT_NAME(webContent(_:runJavaScriptDialog:));

/// A permission prompt. Return YES and answer the request later to show our
/// own UI; return NO to use the stored site setting or deny.
- (BOOL)webContent:(OEWebContent*)webContent
    decidePermissionRequest:(OEPermissionRequest*)request
    NS_SWIFT_NAME(webContent(_:decidePermissionRequest:));

/// Right click. Return YES and complete `menu` later to show our own NSMenu.
/// Return NO to show the engine's default menu.
- (BOOL)webContent:(OEWebContent*)webContent
    showContextMenu:(OEContextMenu*)menu
    NS_SWIFT_NAME(webContent(_:showContextMenu:));

- (void)webContent:(OEWebContent*)webContent
    didUpdateFindResult:(OEFindResult*)result
    NS_SWIFT_NAME(webContent(_:didUpdateFindResult:));

/// The page entered or left HTML fullscreen. The shell should make the view
/// fill the screen (Arc hides the sidebar).
- (void)webContent:(OEWebContent*)webContent
    didRequestFullscreen:(BOOL)fullscreen
    NS_SWIFT_NAME(webContent(_:didRequestFullscreen:));

/// The page asked for a content size (auto-resize, see
/// -enableAutoResizeWithMinimumSize:maximumSize:).
- (void)webContent:(OEWebContent*)webContent
    didRequestContentSize:(NSSize)size
    NS_SWIFT_NAME(webContent(_:didRequestContentSize:));

/// Main-frame navigation finished or failed.
- (void)webContent:(OEWebContent*)webContent
    didFinishLoadWithStatus:(NSInteger)status
    NS_SWIFT_NAME(webContent(_:didFinishLoadWithStatus:));
- (void)webContent:(OEWebContent*)webContent
    didFailLoadWithError:(NSError*)error
    NS_SWIFT_NAME(webContent(_:didFailLoadWithError:));

/// A DevTools protocol event for this page (after the matching domain was
/// enabled with -sendDevToolsMethod:, e.g. "Runtime.enable").
- (void)webContent:(OEWebContent*)webContent
    didReceiveDevToolsEvent:(NSString*)method
                 parameters:(NSDictionary<NSString*, id>*)parameters
    NS_SWIFT_NAME(webContent(_:didReceiveDevToolsEvent:parameters:));

/// Console output, for logs and the automation harness.
- (void)webContent:(OEWebContent*)webContent
    didLogConsoleMessage:(NSString*)message
                   level:(NSInteger)level
                  source:(NSString*)source
                    line:(NSInteger)line
    NS_SWIFT_NAME(webContent(_:didLogConsoleMessage:level:source:line:));
@end

/// The DevTools panel -showDevToolsPanel: opens.
typedef NS_ENUM(NSInteger, OEDevToolsPanel) {
  OEDevToolsPanelDefault = 0,
  OEDevToolsPanelElements,
  OEDevToolsPanelConsole,
  OEDevToolsPanelNetwork,
  OEDevToolsPanelInspectMode,
};

/// One page (ADK "WebContent"). Its `view` can go anywhere: several per
/// window (Split View), or a floating panel (Peek, Little Open, extension
/// popups). The view can move between windows.
///
/// The Chromium browser is created when `view` first moves into a window,
/// so a web content that is never shown costs nothing. It is destroyed by
/// -close or when the last strong reference to the OEWebContent goes away
/// (the view does not keep its content alive). A hidden view (isHidden, or
/// a hidden ancestor) tells Chromium the page is hidden, which throttles
/// timers and painting.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEWebContent : NSObject

- (instancetype)initWithConfiguration:(OEWebContentConfiguration*)configuration
                                  URL:(nullable NSURL*)URL
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// The page's view. Flipped. Size it like any NSView.
@property(nonatomic, readonly) NSView* view;

@property(nonatomic, weak, nullable) id<OEWebContentDelegate> delegate;
@property(nonatomic, readonly, copy) OEWebContentConfiguration* configuration;
@property(nonatomic, readonly) OEBrowserContext* context;
@property(nonatomic, readonly) OERuntimeStyle runtimeStyle;
/// The browser (tab strip) this content belongs to, if any.
@property(nonatomic, readonly, weak, nullable) OEBrowser* browser;

/// Engine identifier: stable for the content's life, unique per process.
/// 0 until the Chromium browser exists.
@property(nonatomic, readonly) NSInteger identifier;
/// The chrome.tabs id, or -1 when Chromium's tab APIs cannot see this page
/// (not live, or not a tab of an OEBrowser's tab strip).
@property(nonatomic, readonly) NSInteger chromeTabIdentifier;
/// The Chromium browser exists and has not been closed.
@property(nonatomic, readonly, getter=isLive) BOOL live;
/// Opened by window.open/target=_blank from another web content.
@property(nonatomic, readonly, getter=isPopup) BOOL popup;
/// The extension whose action popup this content shows, if any.
@property(nonatomic, readonly, copy, nullable) NSString* extensionPopupIdentifier;

#pragma mark Observable state (see OEWebContentChange)
@property(nonatomic, readonly, copy, nullable) NSURL* URL;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy, nullable) NSURL* faviconURL;
/// Downloaded after faviconURL changes.
@property(nonatomic, readonly, nullable) NSImage* favicon;
@property(nonatomic, readonly, getter=isLoading) BOOL loading;
/// 0...1
@property(nonatomic, readonly) double estimatedProgress;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
/// The page is playing sound. Stock CEF has no audible signal, so this is
/// derived from media element events in the page (Web Audio is missed);
/// patch P6 in docs/engine-patches.md replaces it.
@property(nonatomic, readonly, getter=isAudible) BOOL audible;
@property(nonatomic, getter=isMuted) BOOL muted;
@property(nonatomic, readonly, getter=isFullscreen) BOOL fullscreen;
@property(nonatomic, readonly) OEWebContentCrashState crashState;
@property(nonatomic, readonly, getter=isCapturingCamera) BOOL capturingCamera;
@property(nonatomic, readonly, getter=isCapturingMicrophone)
    BOOL capturingMicrophone;
/// Link-hover URL (Arc shows it bottom-left).
@property(nonatomic, readonly, copy) NSString* statusText;

#pragma mark Navigation
- (void)loadURL:(NSURL*)URL NS_SWIFT_NAME(load(_:));
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;

#pragma mark JavaScript
/// Evaluates `script` in the main frame's main world (DevTools protocol
/// Runtime.evaluate with awaitPromise and a user gesture). The result is a
/// JSON-compatible Foundation object, or NSNull.
- (void)evaluateJavaScript:(NSString*)script
                completion:(void (^NS_SWIFT_UI_ACTOR _Nullable)(
                               id _Nullable result,
                               NSError* _Nullable error))completion;
/// Sends a raw DevTools protocol command; the result is the decoded JSON.
- (void)sendDevToolsMethod:(NSString*)method
                parameters:(nullable NSDictionary<NSString*, id>*)parameters
                completion:(void (^NS_SWIFT_UI_ACTOR _Nullable)(
                               NSDictionary<NSString*, id>* _Nullable result,
                               NSError* _Nullable error))completion;

#pragma mark Find in page
/// Starts or continues a search. Results arrive in
/// -webContent:didUpdateFindResult:.
- (void)findString:(NSString*)string
          forward:(BOOL)forward
    caseSensitive:(BOOL)caseSensitive
    NS_SWIFT_NAME(find(_:forward:caseSensitive:));
- (void)stopFindingAndClearSelection:(BOOL)clearSelection
    NS_SWIFT_NAME(stopFinding(clearSelection:));

#pragma mark Zoom
/// Chromium zoom level: 0 = 100%, each step is 20% (1.2^level). Chromium
/// remembers zoom per host within a context.
@property(nonatomic) double zoomLevel;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;

#pragma mark Tools
/// Opens DevTools in a separate window.
- (void)showDevTools;
/// Opens DevTools on one panel (plans/page-platform.md EP-4a). Chrome style
/// pages run Chrome's own command: Console is IDC_DEV_TOOLS_CONSOLE (shows
/// the Console panel, opening DevTools if needed) and InspectMode is
/// IDC_DEV_TOOLS_INSPECT (opens DevTools with the element picker on; a second
/// call turns the picker off, as in Chrome). Elements and Network (EP-4b),
/// and Console where Chrome's command cannot run (Alloy pages, and a hosted
/// tab that is not Chromium's active tab in its window's hidden strip), open
/// DevTools and select the panel through the front end's
/// DevToolsAPI.showPanel, the call Chrome makes for its own Console command;
/// it retries until the panel is selected (at most 15 s). Default opens
/// DevTools as -showDevTools does; so does InspectMode where Chrome's command
/// cannot run. Returns NO only for that plain fallback.
- (BOOL)showDevToolsPanel:(OEDevToolsPanel)panel
    NS_SWIFT_NAME(showDevTools(panel:));
- (void)closeDevTools;
@property(nonatomic, readonly) BOOL hasDevTools;
/// Diagnostics (automation checks): evaluates `script` in the page of this
/// page's open DevTools window (the DevTools front end, not the inspected
/// page), awaiting promises; the result is the JSON value. Fails when no
/// DevTools window of this page is open.
- (void)evaluateJavaScriptInDevToolsFrontend:(NSString*)script
                                  completion:
                                      (void (^NS_SWIFT_UI_ACTOR)(
                                          id _Nullable result,
                                          NSError* _Nullable error))completion
    NS_SWIFT_NAME(evaluateInDevToolsFrontend(_:completion:));
/// Shows the system print panel for the page.
- (void)print NS_SWIFT_NAME(showPrintPanel());
- (void)printToPDFAtURL:(NSURL*)fileURL
             completion:(void (^NS_SWIFT_UI_ACTOR _Nullable)(BOOL ok))completion
    NS_SWIFT_NAME(printToPDF(at:completion:));
/// PNG of the visible page (DevTools Page.captureScreenshot) at device
/// scale. Works for hidden and occluded views.
- (void)takeSnapshotWithCompletion:
    (void (^NS_SWIFT_UI_ACTOR)(NSData* _Nullable png,
                               NSError* _Nullable error))completion;
/// Reports the page's preferred size through
/// -webContent:didRequestContentSize: (extension popups, Peek).
- (void)enableAutoResizeWithMinimumSize:(NSSize)minimumSize
                            maximumSize:(NSSize)maximumSize
    NS_SWIFT_NAME(enableAutoResize(minimumSize:maximumSize:));

#pragma mark Lifecycle
/// Gives keyboard focus to the page.
- (void)focusPage;
/// Exits HTML fullscreen.
- (void)exitFullscreen;
/// Destroys the Chromium browser. The view stays and paints its background.
- (void)close;
@end

#pragma mark - Requests

typedef NS_ENUM(NSInteger, OEOpenDisposition) {
  OEOpenDispositionCurrentTab = 0,
  OEOpenDispositionNewForegroundTab,
  OEOpenDispositionNewBackgroundTab,
  /// window.open with features (width/height). Arc opens these in a small
  /// window (Little Open style).
  OEOpenDispositionNewPopup,
  OEOpenDispositionNewWindow,
  OEOpenDispositionOffTheRecord,
  OEOpenDispositionSaveToDisk,
};

/// A request for new browsing content.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEOpenRequest : NSObject
@property(nonatomic, readonly, copy, nullable) NSURL* URL;
@property(nonatomic, readonly) OEOpenDisposition disposition;
@property(nonatomic, readonly) BOOL userGesture;
/// window.open features; NSZeroRect when not given.
@property(nonatomic, readonly) NSRect requestedFrame;
@property(nonatomic, readonly, copy) NSString* targetFrameName;
/// The opener; nil for unowned requests.
@property(nonatomic, readonly, weak, nullable) OEWebContent* sourceWebContent;
/// The context the new web content must use (the opener's).
@property(nonatomic, readonly) OEBrowserContext* context;
@end

typedef NS_ENUM(NSInteger, OEJavaScriptDialogKind) {
  OEJavaScriptDialogKindAlert = 0,
  OEJavaScriptDialogKindConfirm,
  OEJavaScriptDialogKindPrompt,
  OEJavaScriptDialogKindBeforeUnload,
};

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEJavaScriptDialog : NSObject
@property(nonatomic, readonly) OEJavaScriptDialogKind kind;
@property(nonatomic, readonly, copy) NSString* message;
@property(nonatomic, readonly, copy) NSString* defaultPromptText;
@property(nonatomic, readonly, copy, nullable) NSURL* originURL;
@property(nonatomic, readonly) BOOL isReload;
/// Call exactly once. `text` is used for prompt(). A dialog that is never
/// completed is cancelled when it is deallocated.
- (void)completeWithAccepted:(BOOL)accepted
                        text:(nullable NSString*)text
    NS_SWIFT_NAME(complete(accepted:text:));
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEPermissionRequest : NSObject
@property(nonatomic, readonly, copy) NSURL* origin;
@property(nonatomic, readonly) OEPermissionKind kinds;
/// Call exactly one of these. An unanswered request is dismissed when it is
/// deallocated.
- (void)grant;
- (void)deny;
- (void)dismiss;
@end

typedef NS_OPTIONS(NSUInteger, OEContextMenuTarget) {
  OEContextMenuTargetPage = 1u << 0,
  OEContextMenuTargetFrame = 1u << 1,
  OEContextMenuTargetLink = 1u << 2,
  OEContextMenuTargetMedia = 1u << 3,
  OEContextMenuTargetSelection = 1u << 4,
  OEContextMenuTargetEditable = 1u << 5,
};

typedef NS_ENUM(NSInteger, OEContextMenuMediaType) {
  OEContextMenuMediaTypeNone = 0,
  OEContextMenuMediaTypeImage,
  OEContextMenuMediaTypeVideo,
  OEContextMenuMediaTypeAudio,
  OEContextMenuMediaTypeCanvas,
  OEContextMenuMediaTypeFile,
  OEContextMenuMediaTypePlugin,
};

/// One engine-provided menu item (Back, Copy, Inspect, extension items...).
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEContextMenuItem : NSObject
@property(nonatomic, readonly) NSInteger commandIdentifier;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly, getter=isSeparator) BOOL separator;
@property(nonatomic, readonly, getter=isChecked) BOOL checked;
@property(nonatomic, readonly, copy) NSArray<OEContextMenuItem*>* submenu;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEContextMenu : NSObject
@property(nonatomic, readonly) OEContextMenuTarget targets;
@property(nonatomic, readonly) OEContextMenuMediaType mediaType;
/// In view coordinates (flipped: origin top-left).
@property(nonatomic, readonly) NSPoint location;
@property(nonatomic, readonly, copy, nullable) NSURL* linkURL;
@property(nonatomic, readonly, copy) NSString* linkText;
@property(nonatomic, readonly, copy, nullable) NSURL* sourceURL;
@property(nonatomic, readonly, copy, nullable) NSURL* pageURL;
@property(nonatomic, readonly, copy, nullable) NSURL* frameURL;
@property(nonatomic, readonly, copy) NSString* selectionText;
@property(nonatomic, readonly, copy) NSString* misspelledWord;
@property(nonatomic, readonly, copy) NSArray<NSString*>* spellingSuggestions;
/// The menu Chromium would show (includes extension context-menu items).
@property(nonatomic, readonly, copy) NSArray<OEContextMenuItem*>* items;
/// Runs an engine command (an item's commandIdentifier). Call this or
/// -cancel exactly once.
- (void)selectCommand:(NSInteger)commandIdentifier
    NS_SWIFT_NAME(select(command:));
- (void)cancel;
@end

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEFindResult : NSObject
@property(nonatomic, readonly) NSInteger matchCount;
/// 1-based; 0 when there is no active match.
@property(nonatomic, readonly) NSInteger activeMatchIndex;
@property(nonatomic, readonly) BOOL isFinal;
@end

NS_HEADER_AUDIT_END(nullability, sendability)
