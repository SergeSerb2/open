#import "OEClient.h"

#include "include/cef_parser.h"

#pragma mark - OEWebViewConfiguration

@implementation OEWebViewConfiguration

- (instancetype)initWithProfile:(OEProfile*)profile {
  if ((self = [super init])) {
    _profile = profile;
    _runtimeStyle = OEEngine.shared.configuration.defaultRuntimeStyle;
  }
  return self;
}

- (id)copyWithZone:(NSZone*)zone {
  OEWebViewConfiguration* c =
      [[OEWebViewConfiguration alloc] initWithProfile:_profile];
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

#pragma mark - OEWebView

typedef void (^OEDevToolsCompletion)(NSDictionary* _Nullable, NSError* _Nullable);

@implementation OEWebView {
  OEWebViewConfiguration* _configuration;
  CefRefPtr<OEClient> _client;
  CefRefPtr<CefBrowser> _browser;
  NSURL* _pendingURL;
  BOOL _creating;
  BOOL _awaitingPopup;
  BOOL _closeRequested;
  BOOL _isPopup;
  OEWebView* __weak _pendingChromePopup;
  // Chrome style hosting.
  CefRefPtr<CefWindowDelegate> _chromeHost;
  CefRefPtr<CefBrowserView> _adoptedBrowserView;
  NSWindow* __weak _chromeWindow;
  // DevTools protocol.
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSMutableDictionary<NSNumber*, OEDevToolsCompletion>* _devToolsCallbacks;
  int _nextDevToolsId;
  NSMutableSet<NSString*>* _audibleFrames;
  NSString* _lastFindString;
  BOOL _autoResize;
  NSSize _autoResizeMin;
  NSSize _autoResizeMax;
}

- (instancetype)initWithConfiguration:(OEWebViewConfiguration*)configuration
                                  URL:(NSURL*)URL {
  if ((self = [super initWithFrame:NSMakeRect(0, 0, 800, 600)])) {
    _configuration = [configuration copy];
    _pendingURL = URL;
    _title = @"";
    _statusText = @"";
    _devToolsCallbacks = [NSMutableDictionary dictionary];
    _audibleFrames = [NSMutableSet set];
    _client = OECreateClient(self);
    self.wantsLayer = YES;
    NSColor* bg = _configuration.backgroundColor ?: NSColor.whiteColor;
    self.layer.backgroundColor = bg.CGColor;
    [[OEEngine shared] oe_registerWebView:self];
  }
  return self;
}

- (void)dealloc {
  _client->Detach();
  if (_browser) {
    _client->SetClosing();
    _browser->GetHost()->CloseBrowser(true);
  }
  if (_chromeHost) {
    OEChromeHostClose(_chromeHost);
  }
}

- (OEWebViewConfiguration*)configuration {
  return [_configuration copy];
}

- (OEProfile*)profile {
  return _configuration.profile;
}

- (OERuntimeStyle)runtimeStyle {
  return _configuration.runtimeStyle;
}

- (BOOL)isFlipped {
  return YES;
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

- (CefRefPtr<CefBrowser>)oe_browser {
  return _browser;
}

- (CefRefPtr<OEClient>)oe_client {
  return _client;
}

#pragma mark Creation

- (CefRefPtr<CefDictionaryValue>)oe_extraInfo {
  CefRefPtr<CefDictionaryValue> extra = CefDictionaryValue::Create();
  extra->SetList(kOEExtraScripts, [self.profile oe_scriptsValue]);
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

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  // Wait one run-loop turn: a view returned from
  // -webView:createWebViewForOpenRequest: is usually added to a window before
  // OnBeforePopup hands it the popup browser (-oe_adoptPopup...).
  __weak OEWebView* weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    OEWebView* view = weakSelf;
    if (view && view.window && !view->_browser && !view->_creating &&
        !view->_awaitingPopup && !view->_closeRequested) {
      [view oe_createBrowser];
    }
  });
  [self oe_syncChromeWindow];
}

- (void)oe_createBrowser {
  _creating = YES;
  __weak OEWebView* weakSelf = self;
  [self.profile oe_whenReady:^{
    [weakSelf oe_createBrowserNow];
  }];
}

- (void)oe_createBrowserNow {
  if (_closeRequested || _browser) {
    _creating = NO;
    return;
  }
  CefString url = OECef(_pendingURL.absoluteString ?: @"about:blank");
  NSLog(@"[OpenEngine] create browser url=%@ style=%ld", _pendingURL, (long)_configuration.runtimeStyle);
  CefRefPtr<CefRequestContext> context = self.profile.oe_requestContext;
  if (_configuration.runtimeStyle == OERuntimeStyleChrome) {
    _chromeHost = OECreateChromeHostWindow(
        self, _client.get(), url, [self oe_browserSettings],
        [self oe_extraInfo], context, _configuration.showsChromeToolbar,
        nullptr);
    return;
  }
  NSRect b = self.bounds;
  CefWindowInfo info;
  info.SetAsChild((__bridge CefWindowHandle)self,
                  CefRect(0, 0, (int)b.size.width, (int)b.size.height));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserHost::CreateBrowser(info, _client.get(), url,
                                [self oe_browserSettings],
                                [self oe_extraInfo], context);
}

- (BOOL)oe_adoptPopupWithWindowInfo:(CefWindowInfo&)windowInfo
                             client:(CefRefPtr<CefClient>&)client
                           settings:(CefBrowserSettings&)settings
                          extraInfo:(CefRefPtr<CefDictionaryValue>&)extraInfo
                             opener:(OEWebView*)opener {
  if (_browser || _creating) {
    return NO;
  }
  _awaitingPopup = YES;
  _isPopup = YES;
  client = _client.get();
  extraInfo = [self oe_extraInfo];
  settings.background_color = [self oe_browserSettings].background_color;
  if (opener.runtimeStyle == OERuntimeStyleChrome) {
    // Views-hosted opener: CEF ignores windowInfo and hands us a
    // CefBrowserView in OnPopupBrowserViewCreated instead.
    opener->_pendingChromePopup = self;
    _configuration.runtimeStyle = OERuntimeStyleChrome;
    return YES;
  }
  NSRect b = self.bounds;
  windowInfo.SetAsChild((__bridge CefWindowHandle)self,
                        CefRect(0, 0, (int)b.size.width, (int)b.size.height));
  windowInfo.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  _configuration.runtimeStyle = OERuntimeStyleAlloy;
  return YES;
}

- (nullable OEWebView*)oe_takePendingChromePopup {
  OEWebView* popup = _pendingChromePopup;
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
  NSLog(@"[OpenEngine] browser %d created, main frame url=%@", browser->GetIdentifier(), OEString(browser->GetMainFrame()->GetURL()));
  _browser = browser;
  _creating = NO;
  _awaitingPopup = NO;
  if (_muted) {
    browser->GetHost()->SetAudioMuted(true);
  }
  if (_autoResize) {
    [self enableAutoResizeWithMinimumSize:_autoResizeMin
                              maximumSize:_autoResizeMax];
  }
  if (_configuration.runtimeStyle == OERuntimeStyleAlloy) {
    NSView* host = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    host.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self oe_layoutBrowserView];
  }
  [self oe_notify:OEWebViewChangeURL | OEWebViewChangeLoading];
}

- (void)oe_browserClosed {
  _browser = nullptr;
  _devToolsRegistration = nullptr;
  for (OEDevToolsCompletion done in _devToolsCallbacks.allValues) {
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorWebViewClosed
                              userInfo:nil]);
  }
  [_devToolsCallbacks removeAllObjects];
  _chromeHost = nullptr;
  _adoptedBrowserView = nullptr;
  _closeRequested = YES;
  [[OEEngine shared] oe_unregisterWebView:self];
}

- (void)oe_chromeWindowReady:(NSWindow*)window {
  _chromeWindow = window;
  [self oe_syncChromeWindow];
  // Views applies its own initial bounds (clamped to the primary display)
  // after Show(); place the window again once that has happened.
  __weak OEWebView* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC / 10),
                 dispatch_get_main_queue(), ^{
                   [weakSelf oe_syncChromeWindow];
                 });
}

#pragma mark Chrome-style child window placement

- (void)setFrameSize:(NSSize)newSize {
  [super setFrameSize:newSize];
  [self oe_layoutBrowserView];
  [self oe_syncChromeWindow];
}

// Alloy: CEF's host NSView is our only subview; keep it filling our bounds.
- (void)oe_layoutBrowserView {
  if (!_browser || _configuration.runtimeStyle != OERuntimeStyleAlloy) {
    return;
  }
  NSView* host = (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
  if (host && !NSEqualRects(host.frame, self.bounds)) {
    host.frame = self.bounds;
  }
}

- (void)setFrameOrigin:(NSPoint)newOrigin {
  [super setFrameOrigin:newOrigin];
  [self oe_syncChromeWindow];
}

- (void)viewDidHide {
  [super viewDidHide];
  [self oe_syncChromeWindow];
}

- (void)viewDidUnhide {
  [super viewDidUnhide];
  [self oe_syncChromeWindow];
}

- (void)viewWillMoveToWindow:(NSWindow*)newWindow {
  NSNotificationCenter* nc = NSNotificationCenter.defaultCenter;
  if (self.window) {
    [nc removeObserver:self name:nil object:self.window];
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
  }
  [super viewWillMoveToWindow:newWindow];
}

- (void)oe_hostWindowChanged:(NSNotification*)note {
  [self oe_syncChromeWindow];
}

- (void)oe_syncChromeWindow {
  NSWindow* child = _chromeWindow;
  if (!child) {
    return;
  }
  NSWindow* host = self.window;
  if (!host || self.isHiddenOrHasHiddenAncestor) {
    if (child.parentWindow) {
      [child.parentWindow removeChildWindow:child];
    }
    [child orderOut:nil];
    return;
  }
  NSRect inWindow = [self convertRect:self.bounds toView:nil];
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

- (void)oe_notify:(OEWebViewChange)changes {
  if ([_delegate respondsToSelector:@selector(webView:didChange:)]) {
    [_delegate webView:self didChange:changes];
  }
}

- (void)oe_setURL:(NSURL*)url {
  if ([_URL isEqual:url]) {
    return;
  }
  _URL = [url copy];
  [_audibleFrames removeAllObjects];
  [self oe_notify:OEWebViewChangeURL];
}

- (void)oe_setTitle:(NSString*)title {
  _title = [title copy];
  [self oe_notify:OEWebViewChangeTitle];
}

- (void)oe_setFaviconURL:(NSURL*)url {
  if ([_faviconURL isEqual:url]) {
    return;
  }
  _faviconURL = [url copy];
  _favicon = nil;
  [self oe_notify:OEWebViewChangeFavicon];
  if (!url || !_browser) {
    return;
  }
  __weak OEWebView* weakSelf = self;
  NSURL* requested = url;
  _browser->GetHost()->DownloadImage(
      OECef(url.absoluteString), true, 64, false,
      new FaviconCallback(^(NSImage* image) {
        OEWebView* strongSelf = weakSelf;
        if (strongSelf && [strongSelf->_faviconURL isEqual:requested]) {
          strongSelf->_favicon = image;
          [strongSelf oe_notify:OEWebViewChangeFavicon];
        }
      }));
}

- (void)oe_setLoading:(BOOL)loading
            canGoBack:(BOOL)back
         canGoForward:(BOOL)forward {
  OEWebViewChange changes = 0;
  if (_loading != loading) {
    _loading = loading;
    changes |= OEWebViewChangeLoading;
  }
  if (_canGoBack != back || _canGoForward != forward) {
    _canGoBack = back;
    _canGoForward = forward;
    changes |= OEWebViewChangeNavigationHistory;
  }
  if (changes) {
    [self oe_notify:changes];
  }
}

- (void)oe_setProgress:(double)progress {
  _estimatedProgress = progress;
  [self oe_notify:OEWebViewChangeProgress];
}

- (void)oe_setFullscreen:(BOOL)fullscreen {
  _fullscreen = fullscreen;
  if ([_delegate respondsToSelector:@selector(webView:didRequestFullscreen:)]) {
    [_delegate webView:self didRequestFullscreen:fullscreen];
  }
  [self oe_notify:OEWebViewChangeFullscreen];
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
    [self oe_notify:OEWebViewChangeAudio];
  }
}

- (void)oe_setCrashState:(OEWebViewCrashState)state {
  if (_crashState == state) {
    return;
  }
  _crashState = state;
  [self oe_notify:OEWebViewChangeCrash];
}

- (void)oe_setMediaCaptureCamera:(BOOL)camera microphone:(BOOL)microphone {
  _capturingCamera = camera;
  _capturingMicrophone = microphone;
  [self oe_notify:OEWebViewChangeMediaCapture];
}

- (void)oe_setStatusText:(NSString*)text {
  _statusText = [text copy];
  [self oe_notify:OEWebViewChangeStatusText];
}

- (void)oe_notifyZoomChanged {
  [self oe_notify:OEWebViewChangeZoom];
}

#pragma mark Navigation

- (void)loadURL:(NSURL*)URL {
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
                completion:(void (^)(NSDictionary* _Nullable,
                                     NSError* _Nullable))completion {
  OEDevToolsCompletion done = [completion copy];
  if (!done) {
    done = ^(NSDictionary* r, NSError* e) {
    };
  }
  if (!_browser) {
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorWebViewClosed
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

- (BOOL)executeChromeCommand:(NSInteger)commandIdentifier {
  if (!_browser ||
      !_browser->GetHost()->CanExecuteChromeCommand((int)commandIdentifier)) {
    return NO;
  }
  _browser->GetHost()->ExecuteChromeCommand((int)commandIdentifier,
                                            CEF_WOD_CURRENT_TAB);
  return YES;
}

- (void)setMuted:(BOOL)muted {
  _muted = muted;
  if (_browser) {
    _browser->GetHost()->SetAudioMuted(muted);
  }
  [self oe_notify:OEWebViewChangeAudio];
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
  if (_configuration.runtimeStyle == OERuntimeStyleAlloy) {
    // The page's key view is Chromium's RenderWidgetHostViewCocoa inside
    // CEF's host view; the host view itself does not handle key events.
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
  _closeRequested = YES;
  _client->SetClosing();
  if (_browser) {
    _browser->GetHost()->CloseBrowser(true);
  }
  if (_chromeHost) {
    OEChromeHostClose(_chromeHost);
  }
  if (!_browser) {
    [[OEEngine shared] oe_unregisterWebView:self];
  }
}

@end
