#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEProfile;
@class OEWebView;
@class OEOpenRequest;
@class OEJavaScriptDialog;
@class OEPermissionRequest;
@class OEContextMenu;
@class OEFindResult;

/// Creation options for an OEWebView.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(WebViewConfiguration)
OE_EXPORT @interface OEWebViewConfiguration : NSObject <NSCopying>
- (instancetype)initWithProfile:(OEProfile*)profile NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, strong) OEProfile* profile;
/// Default: the engine's defaultRuntimeStyle.
@property(nonatomic) OERuntimeStyle runtimeStyle;
/// Painted before the first frame. nil: white.
@property(nonatomic, copy, nullable) NSColor* backgroundColor;
/// Chrome style only: show Chrome's own toolbar (for experiments).
@property(nonatomic) BOOL showsChromeToolbar;
@end

/// Bit set passed to -webView:didChange:. One callback can carry several bits.
typedef NS_OPTIONS(NSUInteger, OEWebViewChange) {
  OEWebViewChangeURL = 1u << 0,
  OEWebViewChangeTitle = 1u << 1,
  OEWebViewChangeFavicon = 1u << 2,
  OEWebViewChangeLoading = 1u << 3,
  OEWebViewChangeProgress = 1u << 4,
  OEWebViewChangeNavigationHistory = 1u << 5,
  OEWebViewChangeAudio = 1u << 6,
  OEWebViewChangeFullscreen = 1u << 7,
  OEWebViewChangeCrash = 1u << 8,
  OEWebViewChangeZoom = 1u << 9,
  OEWebViewChangeMediaCapture = 1u << 10,
  OEWebViewChangeStatusText = 1u << 11,
} NS_SWIFT_NAME(WebViewChange);

typedef NS_ENUM(NSInteger, OEWebViewCrashState) {
  OEWebViewCrashStateNone = 0,
  OEWebViewCrashStateCrashed,
  OEWebViewCrashStateKilled,
  OEWebViewCrashStateOutOfMemory,
  OEWebViewCrashStateUnresponsive,
} NS_SWIFT_NAME(WebViewCrashState);

NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(WebViewDelegate)
@protocol OEWebViewDelegate <NSObject>
@optional
/// State changed. Read the new values from the web view's properties.
- (void)webView:(OEWebView*)webView
      didChange:(OEWebViewChange)changes
    NS_SWIFT_NAME(webView(_:didChange:));

/// The page wants new content: target=_blank, window.open, middle click,
/// Cmd-click, or a link a popup blocker allowed. Return a new OEWebView
/// (created with any configuration) to host it, or nil to block. For
/// window.open the returned view keeps the opener relationship.
- (nullable OEWebView*)webView:(OEWebView*)webView
     createWebViewForOpenRequest:(OEOpenRequest*)request
    NS_SWIFT_NAME(webView(_:createWebViewFor:));

/// window.close() was called, or the renderer asked to close.
- (void)webViewDidRequestClose:(OEWebView*)webView
    NS_SWIFT_NAME(webViewDidRequestClose(_:));

/// A key event before the page sees it. Return YES if the shell handled it
/// (an app shortcut), so the page never gets it. Called for every keyDown.
- (BOOL)webView:(OEWebView*)webView
    handleKeyEventBeforePage:(NSEvent*)event
    NS_SWIFT_NAME(webView(_:handleKeyEventBeforePage:));
/// A key event the page did not consume. Return YES if handled.
- (BOOL)webView:(OEWebView*)webView
    handleUnconsumedKeyEvent:(NSEvent*)event
    NS_SWIFT_NAME(webView(_:handleUnconsumedKeyEvent:));

/// alert/confirm/prompt/beforeunload. Return YES and complete the dialog later
/// to show our own UI; return NO for the engine's default sheet.
- (BOOL)webView:(OEWebView*)webView
    runJavaScriptDialog:(OEJavaScriptDialog*)dialog
    NS_SWIFT_NAME(webView(_:runJavaScriptDialog:));

/// A permission prompt. Return YES and answer the request later to show our
/// own UI; return NO to use the stored site setting or deny.
- (BOOL)webView:(OEWebView*)webView
    decidePermissionRequest:(OEPermissionRequest*)request
    NS_SWIFT_NAME(webView(_:decidePermissionRequest:));

/// Right click. Return YES and complete `menu` later to show our own NSMenu.
/// Return NO to show the engine's default menu.
- (BOOL)webView:(OEWebView*)webView
    showContextMenu:(OEContextMenu*)menu
    NS_SWIFT_NAME(webView(_:showContextMenu:));

- (void)webView:(OEWebView*)webView
    didUpdateFindResult:(OEFindResult*)result
    NS_SWIFT_NAME(webView(_:didUpdateFindResult:));

/// The page entered or left HTML fullscreen (video, requestFullscreen). The
/// shell should make the web view fill the screen (Arc hides the sidebar).
- (void)webView:(OEWebView*)webView
    didRequestFullscreen:(BOOL)fullscreen
    NS_SWIFT_NAME(webView(_:didRequestFullscreen:));

/// The page asked for a content size (extension popups, auto-resize).
- (void)webView:(OEWebView*)webView
    didRequestContentSize:(NSSize)size
    NS_SWIFT_NAME(webView(_:didRequestContentSize:));

/// Main-frame navigation finished or failed.
- (void)webView:(OEWebView*)webView
    didFinishLoadWithStatus:(NSInteger)status
    NS_SWIFT_NAME(webView(_:didFinishLoadWithStatus:));
- (void)webView:(OEWebView*)webView
    didFailLoadWithError:(NSError*)error
    NS_SWIFT_NAME(webView(_:didFailLoadWithError:));

/// A DevTools protocol event for this page (after the matching domain was
/// enabled with -sendDevToolsMethod:, e.g. "Runtime.enable").
- (void)webView:(OEWebView*)webView
    didReceiveDevToolsEvent:(NSString*)method
                 parameters:(NSDictionary<NSString*, id>*)parameters
    NS_SWIFT_NAME(webView(_:didReceiveDevToolsEvent:parameters:));

/// Console output, for the shell's logs and the automation harness.
- (void)webView:(OEWebView*)webView
    didLogConsoleMessage:(NSString*)message
                   level:(NSInteger)level
                  source:(NSString*)source
                    line:(NSInteger)line
    NS_SWIFT_NAME(webView(_:didLogConsoleMessage:level:source:line:));
@end

/// A web page in an NSView. Place it anywhere: several per window (Split
/// View), or in a floating panel (Peek, Little Arc, extension popups).
///
/// The browser is created when the view first moves into a window and is
/// destroyed by -close. Hiding the view (isHidden or removing it from its
/// window) marks the page hidden, which throttles timers and painting.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(WebView)
OE_EXPORT @interface OEWebView : NSView

- (instancetype)initWithConfiguration:(OEWebViewConfiguration*)configuration
                                  URL:(nullable NSURL*)URL
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (nullable instancetype)initWithCoder:(NSCoder*)coder NS_UNAVAILABLE;

@property(nonatomic, weak, nullable) id<OEWebViewDelegate> delegate;
@property(nonatomic, readonly, copy) OEWebViewConfiguration* configuration;
@property(nonatomic, readonly) OEProfile* profile;
@property(nonatomic, readonly) OERuntimeStyle runtimeStyle;

/// CEF browser id. 0 until the browser exists. For Chrome-style views this is
/// also the chrome.tabs tab id.
@property(nonatomic, readonly) NSInteger identifier;
/// The browser exists and has not been closed.
@property(nonatomic, readonly, getter=isLive) BOOL live;
/// Opened by window.open/target=_blank from another web view.
@property(nonatomic, readonly, getter=isPopup) BOOL popup;

#pragma mark Observable state (see OEWebViewChange)
@property(nonatomic, readonly, copy, nullable) NSURL* URL;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, copy, nullable) NSURL* faviconURL;
/// Downloaded lazily after faviconURL changes.
@property(nonatomic, readonly, nullable) NSImage* favicon;
@property(nonatomic, readonly, getter=isLoading) BOOL loading;
/// 0...1
@property(nonatomic, readonly) double estimatedProgress;
@property(nonatomic, readonly) BOOL canGoBack;
@property(nonatomic, readonly) BOOL canGoForward;
/// The page is playing sound. Spike: derived from media element events in
/// the page (gap G7: no engine signal for Web Audio).
@property(nonatomic, readonly, getter=isAudible) BOOL audible;
@property(nonatomic, getter=isMuted) BOOL muted;
@property(nonatomic, readonly, getter=isFullscreen) BOOL fullscreen;
@property(nonatomic, readonly) OEWebViewCrashState crashState;
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
/// Starts or continues a search. Results arrive in -webView:didUpdateFindResult:.
- (void)findString:(NSString*)string
         forward:(BOOL)forward
    caseSensitive:(BOOL)caseSensitive
    NS_SWIFT_NAME(find(_:forward:caseSensitive:));
- (void)stopFindingAndClearSelection:(BOOL)clearSelection
    NS_SWIFT_NAME(stopFinding(clearSelection:));

#pragma mark Zoom
/// Chromium zoom level: 0 = 100%, each step is 20% (1.2^level).
@property(nonatomic) double zoomLevel;
- (void)zoomIn;
- (void)zoomOut;
- (void)resetZoom;

#pragma mark Tools
- (void)showDevTools;
- (void)closeDevTools;
@property(nonatomic, readonly) BOOL hasDevTools;
/// Shows the system print panel for the page.
- (void)print;
- (void)printToPDFAtURL:(NSURL*)fileURL
             completion:(void (^NS_SWIFT_UI_ACTOR _Nullable)(BOOL ok))completion
    NS_SWIFT_NAME(printToPDF(at:completion:));
/// PNG of the visible page (DevTools Page.captureScreenshot), at device
/// scale. Works for hidden and occluded views.
- (void)takeSnapshotWithCompletion:
    (void (^NS_SWIFT_UI_ACTOR)(NSData* _Nullable png,
                               NSError* _Nullable error))completion;
/// Executes a Chrome command id (IDC_*). Chrome style only. Returns NO when
/// the command is unavailable.
- (BOOL)executeChromeCommand:(NSInteger)commandIdentifier;

/// Reports the page's preferred size through -webView:didRequestContentSize:
/// (extension popups, Peek). Alloy style only.
- (void)enableAutoResizeWithMinimumSize:(NSSize)minimumSize
                            maximumSize:(NSSize)maximumSize
    NS_SWIFT_NAME(enableAutoResize(minimumSize:maximumSize:));

#pragma mark Lifecycle
/// Gives keyboard focus to the page.
- (void)focusPage;
/// Exits HTML fullscreen.
- (void)exitFullscreen;
/// Destroys the browser. The view stays and paints its background.
- (void)close;
@end

#pragma mark - Requests

typedef NS_ENUM(NSInteger, OEOpenDisposition) {
  OEOpenDispositionCurrentTab = 0,
  OEOpenDispositionNewForegroundTab,
  OEOpenDispositionNewBackgroundTab,
  /// window.open with features (width/height), Arc opens these in Little Arc.
  OEOpenDispositionNewPopup,
  OEOpenDispositionNewWindow,
  OEOpenDispositionOffTheRecord,
  OEOpenDispositionSaveToDisk,
} NS_SWIFT_NAME(OpenDisposition);

/// A request for new browsing content (see -webView:createWebViewForOpenRequest:).
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(OpenRequest)
OE_EXPORT @interface OEOpenRequest : NSObject
@property(nonatomic, readonly, copy, nullable) NSURL* URL;
@property(nonatomic, readonly) OEOpenDisposition disposition;
@property(nonatomic, readonly) BOOL userGesture;
/// window.open features; NSZeroRect when not given.
@property(nonatomic, readonly) NSRect requestedFrame;
@property(nonatomic, readonly, copy) NSString* targetFrameName;
/// The opener, nil for unowned requests.
@property(nonatomic, readonly, weak, nullable) OEWebView* sourceWebView;
/// Profile the new web view must use (the opener's).
@property(nonatomic, readonly) OEProfile* profile;
@end

typedef NS_ENUM(NSInteger, OEJavaScriptDialogKind) {
  OEJavaScriptDialogKindAlert = 0,
  OEJavaScriptDialogKindConfirm,
  OEJavaScriptDialogKindPrompt,
  OEJavaScriptDialogKindBeforeUnload,
} NS_SWIFT_NAME(JavaScriptDialogKind);

NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(JavaScriptDialog)
OE_EXPORT @interface OEJavaScriptDialog : NSObject
@property(nonatomic, readonly) OEJavaScriptDialogKind kind;
@property(nonatomic, readonly, copy) NSString* message;
@property(nonatomic, readonly, copy) NSString* defaultPromptText;
@property(nonatomic, readonly, copy, nullable) NSURL* originURL;
@property(nonatomic, readonly) BOOL isReload;
/// Call exactly once. `text` is used for prompt().
- (void)completeWithAccepted:(BOOL)accepted
                        text:(nullable NSString*)text
    NS_SWIFT_NAME(complete(accepted:text:));
@end

NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(PermissionRequest)
OE_EXPORT @interface OEPermissionRequest : NSObject
@property(nonatomic, readonly, copy) NSURL* origin;
@property(nonatomic, readonly) OEPermissionKind kinds;
/// Call exactly once.
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
} NS_SWIFT_NAME(ContextMenuTarget);

typedef NS_ENUM(NSInteger, OEContextMenuMediaType) {
  OEContextMenuMediaTypeNone = 0,
  OEContextMenuMediaTypeImage,
  OEContextMenuMediaTypeVideo,
  OEContextMenuMediaTypeAudio,
  OEContextMenuMediaTypeCanvas,
  OEContextMenuMediaTypeFile,
  OEContextMenuMediaTypePlugin,
} NS_SWIFT_NAME(ContextMenuMediaType);

/// One engine-provided menu item (Back, Copy, Inspect, extension items...).
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(ContextMenuItem)
OE_EXPORT @interface OEContextMenuItem : NSObject
@property(nonatomic, readonly) NSInteger commandIdentifier;
@property(nonatomic, readonly, copy) NSString* title;
@property(nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property(nonatomic, readonly, getter=isSeparator) BOOL separator;
@property(nonatomic, readonly, getter=isChecked) BOOL checked;
@property(nonatomic, readonly, copy) NSArray<OEContextMenuItem*>* submenu;
@end

NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(ContextMenu)
OE_EXPORT @interface OEContextMenu : NSObject
@property(nonatomic, readonly) OEContextMenuTarget targets;
@property(nonatomic, readonly) OEContextMenuMediaType mediaType;
/// In web view coordinates (flipped: origin top-left).
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
NS_SWIFT_NAME(FindResult)
OE_EXPORT @interface OEFindResult : NSObject
@property(nonatomic, readonly) NSInteger matchCount;
/// 1-based; 0 when there is no active match.
@property(nonatomic, readonly) NSInteger activeMatchIndex;
@property(nonatomic, readonly) BOOL isFinal;
@end

NS_HEADER_AUDIT_END(nullability, sendability)
