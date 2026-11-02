#import "OEClient.h"

#include "include/cef_parser.h"

#pragma mark - OEWebContentConfiguration

@implementation OEWebContentConfiguration

- (instancetype)initWithContext:(OEBrowserContext*)context {
  if ((self = [super init])) {
    _context = context;
    _runtimeStyle = OEEngine.shared.configuration.defaultRuntimeStyle;
  }
  return self;
}

- (id)copyWithZone:(NSZone*)zone {
  OEWebContentConfiguration* c =
      [[OEWebContentConfiguration alloc] initWithContext:_context];
  c.runtimeStyle = _runtimeStyle;
  c.backgroundColor = _backgroundColor;
  c.showsChromeToolbar = _showsChromeToolbar;
  return c;
}

@end

#pragma mark - Helpers

namespace {

class FaviconCallback : public CefDownloadImageCallback {
 public:
  explicit FaviconCallback(void (^done)(NSImage* _Nullable))
      : done_([done copy]) {}
  void OnDownloadImageFinished(const CefString& image_url,
                               int http_status_code,
                               CefRefPtr<CefImage> image) override {
    NSImage* result = nil;
    if (image && !image->IsEmpty()) {
      int w = 0, h = 0;
      CefRefPtr<CefBinaryValue> png = image->GetAsPNG(2.0f, true, w, h);
      if (!png) {
        png = image->GetAsPNG(1.0f, true, w, h);
      }
      if (png) {
        NSMutableData* data = [NSMutableData dataWithLength:png->GetSize()];
        png->GetData(data.mutableBytes, data.length, 0);
        result = [[NSImage alloc] initWithData:data];
      }
    }
    done_(result);
  }

 private:
  void (^done_)(NSImage* _Nullable);
  IMPLEMENT_REFCOUNTING(FaviconCallback);
};

class PdfCallback : public CefPdfPrintCallback {
 public:
  explicit PdfCallback(void (^done)(BOOL)) : done_([done copy]) {}
  void OnPdfPrintFinished(const CefString& path, bool ok) override {
    if (done_) {
      done_(ok);
    }
  }

 private:
  void (^done_)(BOOL);
  IMPLEMENT_REFCOUNTING(PdfCallback);
};

CefRefPtr<CefDictionaryValue> OEDictionary(NSDictionary* _Nullable dict) {
  if (!dict.count) {
    return nullptr;
  }
  NSData* data = [NSJSONSerialization dataWithJSONObject:dict
                                                 options:0
                                                   error:nil];
  if (!data) {
    return nullptr;
  }
  CefRefPtr<CefValue> value =
      CefParseJSON(data.bytes, data.length, JSON_PARSER_RFC);
  return value ? value->GetDictionary() : nullptr;
}

}  // namespace

static NSView* _Nullable OEFindRenderWidgetView(NSView* _Nullable root) {
  if (!root) {
    return nil;
  }
  NSMutableArray<NSView*>* queue = [NSMutableArray arrayWithObject:root];
  while (queue.count) {
    NSView* v = queue.firstObject;
    [queue removeObjectAtIndex:0];
    if ([NSStringFromClass(v.class) hasPrefix:@"RenderWidgetHostView"]) {
      return v;
    }
    [queue addObjectsFromArray:v.subviews];
  }
  return nil;
}

// CEF needs a browser's parent NSView to outlive the browser (until
// OnBeforeClose). A web content that is deallocated without -close parks
// CEF's view here, in a window that is never shown, while Chromium finishes
// closing it.
static NSView* OEParkingView() {
  static NSWindow* window;
  if (!window) {
    window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 16, 16)
                                         styleMask:NSWindowStyleMaskBorderless
                                           backing:NSBackingStoreBuffered
                                             defer:YES];
    window.releasedWhenClosed = NO;
  }
  return window.contentView;
}

#pragma mark - OEWebContentView

@interface OEWebContent (ViewEvents)
- (void)oe_viewWillMoveToWindow:(nullable NSWindow*)window;
- (void)oe_viewDidMoveToWindow;
- (void)oe_viewGeometryChanged;
- (void)oe_showHostedPageIfVisible;
@end

// The page's view. CEF's host NSView becomes its only subview (Alloy), or a
// Views child window is kept glued over it (Chrome). It holds its content
// weakly: the shell owns the OEWebContent.
@interface OEWebContentView : NSView
@property(nonatomic, weak) OEWebContent* content;
@end

@implementation OEWebContentView

- (BOOL)isFlipped {
  return YES;
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow {
  [_content oe_viewWillMoveToWindow:newWindow];
  [super viewWillMoveToWindow:newWindow];
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  [_content oe_viewDidMoveToWindow];
}

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [_content oe_viewGeometryChanged];
}

- (void)setFrameOrigin:(NSPoint)newOrigin {
  [super setFrameOrigin:newOrigin];
  [_content oe_viewGeometryChanged];
}

- (void)viewDidHide {
  [super viewDidHide];
  [_content oe_viewGeometryChanged];
}

- (void)viewDidUnhide {
  [super viewDidUnhide];
  [_content oe_viewGeometryChanged];
  [_content oe_showHostedPageIfVisible];
}

@end

#pragma mark - OEWebContent

typedef void (^OEDevToolsCompletion)(NSDictionary* _Nullable, NSError* _Nullable);

@implementation OEWebContent {
  OEWebContentConfiguration* _configuration;
  OEWebContentView* _view;
  CefRefPtr<OEClient> _client;
  CefRefPtr<CefBrowser> _browser;
  NSURL* _pendingURL;
  BOOL _creating;
  BOOL _awaitingPopup;
  BOOL _closeRequested;
  BOOL _isPopup;
  OEWebContent* __weak _pendingChromePopup;
  // Chrome style hosting.
  CefRefPtr<CefWindowDelegate> _chromeHost;
  CefRefPtr<CefBrowserView> _adoptedBrowserView;
  NSWindow* __weak _chromeWindow;
  NSWindow* __weak _observedWindow;
  // DevTools protocol.
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSMutableDictionary<NSNumber*, OEDevToolsCompletion>* _devToolsCallbacks;
  int _nextDevToolsId;
  NSMutableSet<NSString*>* _audibleFrames;
  NSString* _lastFindString;
  BOOL _autoResize;
  NSSize _autoResizeMin;
  NSSize _autoResizeMax;
  // Keeps this object (and so the parent view) alive from -close until
  // Chromium reports the browser closed.
  OEWebContent* _closingSelf;
  // Keeps this object (and so the parent view) alive from CreateBrowser
  // until OnAfterCreated: CEF creates the browser in a later task and
  // dereferences the parent NSView then (a freed view crashed in
  // CefBrowserPlatformDelegateNativeMac::CreateHostWindow).
  OEWebContent* _creatingSelf;
}

- (instancetype)initWithConfiguration:(OEWebContentConfiguration*)configuration
                                  URL:(NSURL*)URL {
  if ((self = [super init])) {
    _configuration = [configuration copy];
    _pendingURL = URL;
    _title = @"";
    _statusText = @"";
    _devToolsCallbacks = [NSMutableDictionary dictionary];
    _audibleFrames = [NSMutableSet set];
    _client = OECreateClient(self);
    _view = [[OEWebContentView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
    _view.content = self;
    _view.wantsLayer = YES;
    NSColor* bg = _configuration.backgroundColor ?: NSColor.whiteColor;
    _view.layer.backgroundColor = bg.CGColor;
    [[OEEngine shared] oe_registerWebContent:self];
  }
  return self;
}

- (void)oe_setHostBrowser:(nullable OEBrowser*)browser {
  _oe_hostBrowser = browser;
  _oe_hostBrowserIdentifier = browser ? browser.identifier : 0;
}

- (instancetype)initOEForExtensionPopupInBrowser:(OEBrowser*)browser
                                       extension:(NSString*)extensionIdentifier {
  if ((self = [self initOEForChromiumTabInBrowser:browser])) {
    // Not a tab: it never joins the strip; resize and close go to `browser`.
    self.oe_popupOwner = browser;
    self.oe_popupExtension = extensionIdentifier;
  }
  return self;
}

- (instancetype)initOEForChromiumTabInBrowser:(OEBrowser*)browser {
  OEWebContentConfiguration* config =
      [[OEWebContentConfiguration alloc] initWithContext:browser.context];
  config.runtimeStyle = OERuntimeStyleChrome;
  if ((self = [self initWithConfiguration:config URL:nil])) {
    // Chromium creates the page (OnAfterCreated arrives on our client).
    _awaitingPopup = YES;
    [self oe_setHostBrowser:browser];
  }
  return self;
}

- (void)dealloc {
  _client->Detach();
  if (_browser) {
    _client->SetClosing();
    if (_configuration.runtimeStyle == OERuntimeStyleAlloy ||
        _oe_hostBrowser) {
      NSView* host = (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
      [OEParkingView() addSubview:host];
    }
    _browser->GetHost()->CloseBrowser(true);
  }
  if (_chromeHost) {
    OEChromeHostClose(_chromeHost);
  }
  if (_observedWindow) {
    [NSNotificationCenter.defaultCenter removeObserver:self];
  }
}

- (NSView*)view {
  return _view;
}

- (OEWebContentConfiguration*)configuration {
  return [_configuration copy];
}

- (OEBrowserContext*)context {
  return _configuration.context;
}

- (OERuntimeStyle)runtimeStyle {
  return _configuration.runtimeStyle;
}

- (nullable OEBrowser*)browser {
  return _oe_tabStrip;
}

- (nullable NSString*)extensionPopupIdentifier {
  return _oe_popupExtension;
}

- (BOOL)isLive {
  return _browser != nullptr;
}

- (BOOL)isPopup {
  return _isPopup;
}

- (NSInteger)identifier {
  return _browser ? _browser->GetIdentifier() : 0;
}

- (NSInteger)chromeTabIdentifier {
  CefRefPtr<CefTabStrip> strip =
      [_oe_hostBrowser oe_tabStripCreatingIfNeeded:NO];
  return _browser && strip ? strip->GetTabId(_browser) : -1;
}

- (CefRefPtr<CefBrowser>)oe_browser {
  return _browser;
}

- (CefRefPtr<OEClient>)oe_client {
  return _client;
}

- (NSString*)description {
  return [NSString stringWithFormat:@"<OEWebContent %p id=%ld %@>", self,
                                    (long)self.identifier,
                                    _URL ?: _pendingURL];
}

#pragma mark Creation

- (CefRefPtr<CefDictionaryValue>)oe_extraInfo {
  CefRefPtr<CefDictionaryValue> extra = CefDictionaryValue::Create();
  extra->SetList(kOEExtraScripts, [self.context oe_scriptsValue]);
  return extra;
}

- (CefBrowserSettings)oe_browserSettings {
  CefBrowserSettings settings;
  NSColor* bg = [(_configuration.backgroundColor ?: NSColor.whiteColor)
      colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  settings.background_color =
      CefColorSetARGB(255, (int)(bg.redComponent * 255),
                      (int)(bg.greenComponent * 255),
                      (int)(bg.blueComponent * 255));
  return settings;
}

- (void)oe_viewDidMoveToWindow {
  // Wait one run-loop turn: a content returned from
  // -webContent:createWebContentForOpenRequest: is usually put in a window
  // before OnBeforePopup hands it the popup browser (-oe_adoptPopup...).
  __weak OEWebContent* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    OEWebContent* content = weakSelf;
    if (content && content->_view.window && !content->_browser &&
        !content->_creating && !content->_awaitingPopup &&
        !content->_closeRequested) {
      [content oe_createBrowser];
    }
  });
  [self oe_syncChromeWindow];
  [self oe_showHostedPageIfVisible];
}

- (void)oe_createBrowser {
  _creating = YES;
  __weak OEWebContent* weakSelf = self;
  [self.context oe_whenReady:^{
    [weakSelf oe_createBrowserNow];
  }];
}

- (void)oe_createBrowserNow {
  if (_closeRequested || _browser) {
    _creating = NO;
    return;
  }
  CefString url = OECef(_pendingURL.absoluteString ?: @"about:blank");
  CefRefPtr<CefRequestContext> context = self.context.oe_requestContext;
  if (_configuration.runtimeStyle == OERuntimeStyleChrome &&
      [self oe_createHostedTab:url]) {
    return;
  }
  if (_configuration.runtimeStyle == OERuntimeStyleChrome && _oe_tabStrip &&
      _oe_tabStrip.context == self.context && !_oe_tabStrip.oe_canHostTabs) {
    // A tab whose context gets no hidden Chrome window (CefTabStrip::Create
    // refused it) stays Alloy rather than opening its own Chrome window.
    _configuration.runtimeStyle = OERuntimeStyleAlloy;
  }
  if (_configuration.runtimeStyle == OERuntimeStyleChrome) {
    _chromeHost = OECreateChromeHostWindow(
        self, _client.get(), url, [self oe_browserSettings],
        [self oe_extraInfo], context, _configuration.showsChromeToolbar,
        nullptr);
    return;
  }
  NSRect b = _view.bounds;
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)_view,
                  CefRect(0, 0, (int)b.size.width, (int)b.size.height));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  _creatingSelf = self;
  CefBrowserHost::CreateBrowser(info, _client.get(), url,
                                [self oe_browserSettings],
                                [self oe_extraInfo], context);
}

// Fork patch P1: a Chrome style page that is in an OEBrowser becomes a tab of
// that window's hidden Chrome window, hosted in our view.
- (BOOL)oe_createHostedTab:(const CefString&)url {
  OEBrowser* owner = _oe_tabStrip;
  if (!owner || owner.context != self.context) {
    return NO;
  }
  CefRefPtr<CefTabStrip> strip = [owner oe_tabStripCreatingIfNeeded:YES];
  if (!strip) {
    return NO;
  }
  [self oe_setHostBrowser:owner];
  // Synchronous: OnAfterCreated (-oe_browserCreated:) runs inside.
  CefRefPtr<CefBrowser> browser =
      strip->CreateTab(_client.get(), url, [self oe_browserSettings],
                       [self oe_extraInfo], -1,
                       [owner isPinnedWebContent:self]);
  if (!browser) {
    [self oe_setHostBrowser:nil];
    return NO;
  }
  [owner oe_setNeedsTabStripSync];
  return YES;
}

- (BOOL)oe_adoptPopupWithWindowInfo:(CefWindowInfo&)windowInfo
                             client:(CefRefPtr<CefClient>&)client
                           settings:(CefBrowserSettings&)settings
                          extraInfo:(CefRefPtr<CefDictionaryValue>&)extraInfo
                             opener:(OEWebContent*)opener {
  if (_browser || _creating) {
    return NO;
  }
  _awaitingPopup = YES;
  _isPopup = YES;
  client = _client.get();
  extraInfo = [self oe_extraInfo];
  settings.background_color = [self oe_browserSettings].background_color;
  if (opener.oe_hostBrowser) {
    // Hosted opener (P1): keep CEF's Chrome style window info; the engine
    // makes the popup a tab of the opener's hidden Chrome window.
    [self oe_setHostBrowser:opener.oe_hostBrowser];
    _configuration.runtimeStyle = OERuntimeStyleChrome;
    return YES;
  }
  if (opener.runtimeStyle == OERuntimeStyleChrome) {
    // Views-hosted opener: CEF ignores windowInfo and hands us a
    // CefBrowserView in OnPopupBrowserViewCreated instead.
    opener->_pendingChromePopup = self;
    _configuration.runtimeStyle = OERuntimeStyleChrome;
    return YES;
  }
  NSRect b = _view.bounds;
  windowInfo.SetAsChild((__bridge CefWindowHandle)_view,
                        CefRect(0, 0, (int)b.size.width, (int)b.size.height));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  _configuration.runtimeStyle = OERuntimeStyleAlloy;
  _creatingSelf = self;
  return YES;
}

- (nullable OEWebContent*)oe_takePendingChromePopup {
  OEWebContent* popup = _pendingChromePopup;
  _pendingChromePopup = nil;
  return popup;
}

- (void)oe_adoptPopupBrowserView:(CefRefPtr<CefBrowserView>)browserView {
  _adoptedBrowserView = browserView;
  _chromeHost = OECreateChromeHostWindow(self, _client.get(), CefString(),
                                         [self oe_browserSettings], nullptr,
                                         nullptr, false, browserView);
}

- (void)oe_browserCreated:(CefRefPtr<CefBrowser>)browser {
  _browser = browser;
  _creating = NO;
  _awaitingPopup = NO;
  // Released at the end of this method; -close or the parking path in
  // -dealloc take over from here.
  OEWebContent* keepAlive = _creatingSelf;
  _creatingSelf = nil;
  (void)keepAlive;
  if (_closeRequested) {
    // Closed while Chromium was still creating the browser.
    _closingSelf = self;
    _client->SetClosing();
    browser->GetHost()->CloseBrowser(true);
    return;
  }
  if (_muted) {
    browser->GetHost()->SetAudioMuted(true);
  }
  if (_autoResize) {
    [self enableAutoResizeWithMinimumSize:_autoResizeMin
                              maximumSize:_autoResizeMax];
  }
  if (_configuration.runtimeStyle == OERuntimeStyleAlloy ||
      _oe_hostBrowser) {
    NSView* host = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (_oe_hostBrowser && host && host.superview != _view) {
      // A hosted tab's window handle is its WebContents view (P1). Chromium
      // hides that view itself when the tab starts in the background, and
      // only Views unhides it (ViewsHostableSetVisible); here our view's
      // hidden state and the window's occlusion decide, as for Alloy.
      [_view addSubview:host];
      host.hidden = NO;
    }
    host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self oe_layoutBrowserView];
  }
  [_oe_hostBrowser oe_setNeedsTabStripSync];
  [self oe_showHostedPageIfVisible];
  [self oe_notify:OEWebContentChangeLive | OEWebContentChangeURL |
                  OEWebContentChangeLoading];
}

- (void)oe_browserClosed {
  _browser = nullptr;
  _devToolsRegistration = nullptr;
  for (OEDevToolsCompletion done in _devToolsCallbacks.allValues) {
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorWebContentClosed
                              userInfo:nil]);
  }
  [_devToolsCallbacks removeAllObjects];
  _chromeHost = nullptr;
  _adoptedBrowserView = nullptr;
  _closeRequested = YES;
  [[OEEngine shared] oe_unregisterWebContent:self];
  [self oe_notify:OEWebContentChangeLive];
  _closingSelf = nil;
}

- (void)oe_chromeWindowReady:(NSWindow*)window {
  _chromeWindow = window;
  [self oe_syncChromeWindow];
  // Views applies its own initial bounds (clamped to the primary display)
  // after Show(); place the window again once that has happened.
  __weak OEWebContent* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
                 dispatch_get_main_queue(), ^{
                   [weakSelf oe_syncChromeWindow];
                 });
}

#pragma mark View geometry

- (void)oe_viewGeometryChanged {
  [self oe_layoutBrowserView];
  [self oe_syncChromeWindow];
}

// Hosted tabs (P1) that Chromium created in the background start hidden; a
// view that becomes visible in a window shows its page, as a Chrome
// BrowserView does for the active tab. Hiding (and window occlusion) is
// Chromium's own WebContents view logic.
- (void)oe_showHostedPageIfVisible {
  if (_browser && _oe_hostBrowser && _view.window &&
      !_view.isHiddenOrHasHiddenAncestor) {
    _browser->GetHost()->WasHidden(false);
  }
}

// Alloy: CEF's host NSView is our view's only subview; keep it filling it.
// Hosted tabs (P1): the same for the WebContents view.
- (void)oe_layoutBrowserView {
  if (!_browser || (_configuration.runtimeStyle != OERuntimeStyleAlloy &&
                    !_oe_hostBrowser)) {
    return;
  }
  NSView* host = (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
  if (host && !NSEqualRects(host.frame, _view.bounds)) {
    host.frame = _view.bounds;
  }
}

- (void)oe_viewWillMoveToWindow:(NSWindow*)newWindow {
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  if (_observedWindow) {
    [nc removeObserver:self name:nil object:_observedWindow];
    _observedWindow = nil;
  }
  if (newWindow && _configuration.runtimeStyle == OERuntimeStyleChrome) {
    for (NSNotificationName name in @[
           NSWindowDidMoveNotification, NSWindowDidResizeNotification,
           NSWindowDidEndLiveResizeNotification
         ]) {
      [nc addObserver:self
             selector:@selector(oe_hostWindowChanged:)
                 name:name
               object:newWindow];
    }
    _observedWindow = newWindow;
  }
}

- (void)oe_hostWindowChanged:(NSNotification*)note {
  [self oe_syncChromeWindow];
}

// Chrome style: keep the Views window over our view, as a child window.
- (void)oe_syncChromeWindow {
  NSWindow* child = _chromeWindow;
  if (!child) {
    return;
  }
  NSWindow* host = _view.window;
  if (!host || _view.isHiddenOrHasHiddenAncestor) {
    if (child.parentWindow) {
      [child.parentWindow removeChildWindow:child];
    }
    [child orderOut:nil];
    return;
  }
  NSRect inWindow = [_view convertRect:_view.bounds toView:nil];
  NSRect onScreen = [host convertRectToScreen:inWindow];
  if (child.parentWindow != host) {
    [child.parentWindow removeChildWindow:child];
    [host addChildWindow:child ordered:NSWindowAbove];
  }
  if (!NSEqualRects(child.frame, onScreen)) {
    [child setFrame:onScreen display:YES];
  }
  if (!child.isVisible) {
    [child orderWindow:NSWindowAbove relativeTo:host.windowNumber];
  }
}

#pragma mark State updates (from OEClient)

- (void)oe_notify:(OEWebContentChange)changes {
  if ([_delegate respondsToSelector:@selector(webContent:didChange:)]) {
    [_delegate webContent:self didChange:changes];
  }
}

- (void)oe_setURL:(NSURL*)url {
  if ([_URL isEqual:url]) {
    return;
  }
  _URL = [url copy];
  [_audibleFrames removeAllObjects];
  [self oe_notify:OEWebContentChangeURL];
}

- (void)oe_setTitle:(NSString*)title {
  _title = [title copy];
  [self oe_notify:OEWebContentChangeTitle];
}

- (void)oe_setFaviconURL:(NSURL*)url {
  if ([_faviconURL isEqual:url]) {
    return;
  }
  _faviconURL = [url copy];
  _favicon = nil;
  [self oe_notify:OEWebContentChangeFavicon];
  if (!url || !_browser) {
    return;
  }
  __weak OEWebContent* weakSelf = self;
  NSURL* requested = url;
  _browser->GetHost()->DownloadImage(
      OECef(url.absoluteString), true, 64, false,
      new FaviconCallback(^(NSImage* image) {
        OEWebContent* strongSelf = weakSelf;
        if (strongSelf && [strongSelf->_faviconURL isEqual:requested]) {
          strongSelf->_favicon = image;
          [strongSelf oe_notify:OEWebContentChangeFavicon];
        }
      }));
}

- (void)oe_setLoading:(BOOL)loading
            canGoBack:(BOOL)back
         canGoForward:(BOOL)forward {
  OEWebContentChange changes = 0;
  if (_loading != loading) {
    _loading = loading;
    changes |= OEWebContentChangeLoading;
  }
  if (_canGoBack != back || _canGoForward != forward) {
    _canGoBack = back;
    _canGoForward = forward;
    changes |= OEWebContentChangeNavigationHistory;
  }
  if (changes) {
    [self oe_notify:changes];
  }
}

- (void)oe_setProgress:(double)progress {
  _estimatedProgress = progress;
  [self oe_notify:OEWebContentChangeProgress];
}

- (void)oe_setFullscreen:(BOOL)fullscreen {
  _fullscreen = fullscreen;
  if ([_delegate respondsToSelector:@selector(webContent:
                                        didRequestFullscreen:)]) {
    [_delegate webContent:self didRequestFullscreen:fullscreen];
  }
  [self oe_notify:OEWebContentChangeFullscreen];
}

- (void)oe_setAudible:(BOOL)audible frame:(NSString*)frameId {
  if (audible) {
    [_audibleFrames addObject:frameId];
  } else {
    [_audibleFrames removeObject:frameId];
  }
  BOOL now = _audibleFrames.count > 0;
  if (now != _audible) {
    _audible = now;
    [self oe_notify:OEWebContentChangeAudio];
  }
}

- (void)oe_setCrashState:(OEWebContentCrashState)state {
  if (_crashState == state) {
    return;
  }
  _crashState = state;
  [self oe_notify:OEWebContentChangeCrash];
}

- (void)oe_setMediaCaptureCamera:(BOOL)camera microphone:(BOOL)microphone {
  _capturingCamera = camera;
  _capturingMicrophone = microphone;
  [self oe_notify:OEWebContentChangeMediaCapture];
}

- (void)oe_setStatusText:(NSString*)text {
  _statusText = [text copy];
  [self oe_notify:OEWebContentChangeStatusText];
}

- (void)oe_notifyZoomChanged {
  [self oe_notify:OEWebContentChangeZoom];
}

- (void)oe_requestContentSize:(NSSize)size {
  OEBrowser* owner = _oe_popupOwner;
  if (owner) {
    [owner oe_popupDidResize:self size:size];
    return;
  }
  if ([_delegate respondsToSelector:@selector(webContent:
                                        didRequestContentSize:)]) {
    [_delegate webContent:self didRequestContentSize:size];
  }
}

- (void)oe_requestClose {
  OEBrowser* owner = _oe_popupOwner;
  if (owner) {
    [owner oe_popupRequestedClose:self];
    return;
  }
  if ([_delegate respondsToSelector:@selector(webContentDidRequestClose:)]) {
    [_delegate webContentDidRequestClose:self];
  }
}

#pragma mark Navigation

- (void)loadURL:(NSURL*)URL {
  // An action popup shows only its own extension's pages (Chrome blocks the
  // page's own cross-site navigations; this blocks ours).
  NSString* extension = _oe_popupOwner ? _oe_popupExtension : nil;
  if (extension &&
      !([URL.scheme isEqualToString:@"chrome-extension"] &&
        [URL.host isEqualToString:extension])) {
    NSLog(@"OEWebContent: refused to load %@ in the popup of %@",
          URL.absoluteString, extension);
    return;
  }
  if (!_browser) {
    _pendingURL = URL;
    return;
  }
  _browser->GetMainFrame()->LoadURL(OECef(URL.absoluteString));
}

- (void)goBack {
  if (_browser) _browser->GoBack();
}
- (void)goForward {
  if (_browser) _browser->GoForward();
}
- (void)reload {
  if (_browser) _browser->Reload();
}
- (void)reloadIgnoringCache {
  if (_browser) _browser->ReloadIgnoreCache();
}
- (void)stopLoading {
  if (_browser) _browser->StopLoad();
}

#pragma mark DevTools protocol / JavaScript

- (void)sendDevToolsMethod:(NSString*)method
                parameters:(NSDictionary<NSString*, id>*)parameters
                completion:(void (^NS_SWIFT_UI_ACTOR)(
                               NSDictionary<NSString*, id>* _Nullable,
                               NSError* _Nullable))completion {
  OEDevToolsCompletion done = [completion copy];
  if (!done) {
    done = ^(NSDictionary* r, NSError* e) {
    };
  }
  if (!_browser) {
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorWebContentClosed
                              userInfo:nil]);
    return;
  }
  CefRefPtr<CefBrowserHost> host = _browser->GetHost();
  if (!_devToolsRegistration) {
    _devToolsRegistration = host->AddDevToolsMessageObserver(_client.get());
  }
  int messageId = ++_nextDevToolsId;
  _devToolsCallbacks[@(messageId)] = done;
  if (host->ExecuteDevToolsMethod(messageId, OECef(method),
                                  OEDictionary(parameters)) == 0) {
    [_devToolsCallbacks removeObjectForKey:@(messageId)];
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorDevToolsFailure
                              userInfo:@{
                                NSLocalizedDescriptionKey :
                                    @"ExecuteDevToolsMethod failed"
                              }]);
  }
}

- (void)oe_devToolsResult:(int)messageId
                  success:(BOOL)success
                     json:(NSData*)json {
  OEDevToolsCompletion done = _devToolsCallbacks[@(messageId)];
  if (!done) {
    return;
  }
  [_devToolsCallbacks removeObjectForKey:@(messageId)];
  id object = json.length ? [NSJSONSerialization JSONObjectWithData:json
                                                            options:0
                                                              error:nil]
                          : nil;
  NSDictionary* dict = [object isKindOfClass:NSDictionary.class] ? object : @{};
  if (!success) {
    NSString* message = dict[@"message"] ?: @"DevTools method failed";
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorDevToolsFailure
                              userInfo:@{NSLocalizedDescriptionKey : message}]);
    return;
  }
  done(dict, nil);
}

- (void)evaluateJavaScript:(NSString*)script
                completion:(void (^)(id _Nullable, NSError* _Nullable))completion {
  void (^done)(id, NSError*) = [completion copy];
  [self sendDevToolsMethod:@"Runtime.evaluate"
                parameters:@{
                  @"expression" : script,
                  @"awaitPromise" : @YES,
                  @"returnByValue" : @YES,
                  @"userGesture" : @YES,
                }
                completion:^(NSDictionary* result, NSError* error) {
                  if (!done) {
                    return;
                  }
                  if (error) {
                    done(nil, error);
                    return;
                  }
                  NSDictionary* exception = result[@"exceptionDetails"];
                  if (exception) {
                    NSString* text =
                        exception[@"exception"][@"description"]
                            ?: exception[@"text"] ?: @"JavaScript exception";
                    done(nil, [NSError
                                  errorWithDomain:OEErrorDomain
                                             code:OEErrorJavaScriptException
                                         userInfo:@{
                                           NSLocalizedDescriptionKey : text
                                         }]);
                    return;
                  }
                  id value = result[@"result"][@"value"];
                  done(value ?: NSNull.null, nil);
                }];
}

- (void)takeSnapshotWithCompletion:(void (^)(NSData* _Nullable,
                                             NSError* _Nullable))completion {
  void (^done)(NSData*, NSError*) = [completion copy];
  [self sendDevToolsMethod:@"Page.captureScreenshot"
                parameters:@{@"format" : @"png"}
                completion:^(NSDictionary* result, NSError* error) {
                  NSString* b64 = result[@"data"];
                  NSData* png =
                      b64 ? [[NSData alloc] initWithBase64EncodedString:b64
                                                                options:0]
                          : nil;
                  done(png, png ? nil : error);
                }];
}

#pragma mark Find

- (void)findString:(NSString*)string
          forward:(BOOL)forward
    caseSensitive:(BOOL)caseSensitive {
  if (!_browser || string.length == 0) {
    return;
  }
  BOOL next = [_lastFindString isEqualToString:string];
  _lastFindString = [string copy];
  _browser->GetHost()->Find(OECef(string), forward, caseSensitive, next);
}

- (void)stopFindingAndClearSelection:(BOOL)clearSelection {
  _lastFindString = nil;
  if (_browser) {
    _browser->GetHost()->StopFinding(clearSelection);
  }
}

#pragma mark Zoom

- (double)zoomLevel {
  return _browser ? _browser->GetHost()->GetZoomLevel() : 0;
}

- (void)setZoomLevel:(double)zoomLevel {
  if (_browser) {
    _browser->GetHost()->SetZoomLevel(zoomLevel);
    [self oe_notifyZoomChanged];
  }
}

- (void)zoomIn {
  if (_browser) {
    _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_IN);
    [self oe_notifyZoomChanged];
  }
}

- (void)zoomOut {
  if (_browser) {
    _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_OUT);
    [self oe_notifyZoomChanged];
  }
}

- (void)resetZoom {
  if (_browser) {
    // Also resets the pinch scale (page-platform EP-5, Arc's resetZoomAndScaleFactors,
    // PG-3.2): CEF runs zoom::PageZoom::Zoom (cef/libcef/browser/browser_host_base.cc:397),
    // whose PAGE_ZOOM_RESET calls WebContents::SetPageScale(1) (components/zoom/page_zoom.cc:81-83).
    _browser->GetHost()->Zoom(CEF_ZOOM_COMMAND_RESET);
    [self oe_notifyZoomChanged];
  }
}

#pragma mark Tools

- (void)showDevTools {
  if (!_browser) {
    return;
  }
  CefWindowInfo info;
  info.runtime_style = _browser->GetHost()->GetRuntimeStyle();
  CefBrowserSettings settings;
  _browser->GetHost()->ShowDevTools(info, nullptr, settings, CefPoint());
}

- (void)closeDevTools {
  if (_browser) _browser->GetHost()->CloseDevTools();
}

- (BOOL)hasDevTools {
  return _browser && _browser->GetHost()->HasDevTools();
}

- (void)print {
  if (_browser) _browser->GetHost()->Print();
}

- (void)printToPDFAtURL:(NSURL*)fileURL completion:(void (^)(BOOL))completion {
  if (!_browser) {
    if (completion) completion(NO);
    return;
  }
  CefPdfPrintSettings settings;
  settings.print_background = true;
  _browser->GetHost()->PrintToPDF(OECef(fileURL.path), settings,
                                  new PdfCallback(completion));
}

- (void)setMuted:(BOOL)muted {
  _muted = muted;
  if (_browser) {
    _browser->GetHost()->SetAudioMuted(muted);
  }
  [self oe_notify:OEWebContentChangeAudio];
}

- (void)enableAutoResizeWithMinimumSize:(NSSize)minimumSize
                            maximumSize:(NSSize)maximumSize {
  _autoResizeMin = minimumSize;
  _autoResizeMax = maximumSize;
  _autoResize = YES;
  if (_browser) {
    _browser->GetHost()->SetAutoResizeEnabled(
        true, CefSize((int)minimumSize.width, (int)minimumSize.height),
        CefSize((int)maximumSize.width, (int)maximumSize.height));
  }
}

#pragma mark Lifecycle

- (void)focusPage {
  if (!_browser) {
    return;
  }
  _browser->GetHost()->SetFocus(true);
  if (_configuration.runtimeStyle == OERuntimeStyleAlloy || _oe_hostBrowser) {
    // The page's key view is Chromium's RenderWidgetHostViewCocoa inside
    // CEF's host view (Alloy) or the WebContents view (hosted tab); the
    // container itself does not handle key events.
    NSView* content = (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
    NSView* target = OEFindRenderWidgetView(content) ?: content;
    if (target.window && target.window.firstResponder != target) {
      [target.window makeFirstResponder:target];
    }
  } else {
    [_chromeWindow makeKeyWindow];
  }
}

- (void)exitFullscreen {
  if (_browser) {
    _browser->GetHost()->ExitFullscreen(true);
  }
}

- (void)close {
  // An action popup: the engine owns its page (CloseBrowser does nothing for
  // it), so close it as the popup.
  OEBrowser* owner = _oe_popupOwner;
  if (owner && owner.extensionPopup == self) {
    [owner closeExtensionPopup];
    return;
  }
  if (_closeRequested && !_browser) {
    return;
  }
  _closeRequested = YES;
  _client->SetClosing();
  [_oe_tabStrip oe_webContentClosed:self];
  if (_browser) {
    _closingSelf = self;
    _browser->GetHost()->CloseBrowser(true);
  }
  if (_chromeHost) {
    OEChromeHostClose(_chromeHost);
  }
  if (!_browser) {
    [[OEEngine shared] oe_unregisterWebContent:self];
  }
}

@end
