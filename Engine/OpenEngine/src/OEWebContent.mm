#import "OEClient.h"

#include "include/cef_id_mappers.h"
#import <ImageIO/ImageIO.h>

#include <algorithm>

#include "include/cef_open_browser_info.h"
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

// Runs `done` once, on the main thread (the CEF UI thread).
class OECompletionCallback : public CefCompletionCallback {
 public:
  explicit OECompletionCallback(void (^done)(void)) : done_([done copy]) {}
  ~OECompletionCallback() override {
    // Released unrun (the engine went away): still answer once.
    if (void (^done)(void) = done_) {
      dispatch_async(dispatch_get_main_queue(), done);
    }
  }
  void OnComplete() override {
    void (^done)(void) = done_;
    done_ = nil;
    if (done) {
      done();
    }
  }

 private:
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(OECompletionCallback);
};

class PdfCallback : public CefPdfPrintCallback {
 public:
  explicit PdfCallback(void (^done)(BOOL)) : done_([done copy]) {}
  ~PdfCallback() override {
    // Released unrun (the page closed mid-print): still answer once.
    if (void (^done)(BOOL) = done_) {
      dispatch_async(dispatch_get_main_queue(), ^{
        done(NO);
      });
    }
  }
  void OnPdfPrintFinished(const CefString& path, bool ok) override {
    void (^done)(BOOL) = done_;
    done_ = nil;
    if (done) {
      done(ok);
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
- (void)oe_showPageIfVisible;
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
  [_content oe_showPageIfVisible];
}

@end

#pragma mark - Page handler (cef_open_page.h)

@interface OEWebContent (OEPageEvents)
- (void)oe_selectionChanged:(BOOL)hasSelection;
- (void)oe_historySwipe:(int)phase direction:(int)direction progress:(double)progress;
@end

// Selection changes and history swipes of one page (page-platform EP-1, EP-3).
class OEPageHandler : public CefOpenPageHandler {
 public:
  explicit OEPageHandler(OEWebContent* content) : content_(content) {}
  void OnSelectionChanged(CefRefPtr<CefBrowser> browser,
                          bool has_selection) override {
    [content_ oe_selectionChanged:has_selection];
  }
  void OnSecurityStateChanged(CefRefPtr<CefBrowser> browser) override {
    // Defer delegate work; it may close the WebContents observing this event.
    OEWebContent* content = content_;
    dispatch_async(dispatch_get_main_queue(), ^{ [content oe_notify:OEWebContentChangeSecurity]; });
  }
  void OnHistorySwipe(CefRefPtr<CefBrowser> browser,
                      int phase,
                      int direction,
                      double progress) override {
    [content_ oe_historySwipe:phase direction:direction progress:progress];
  }

 private:
  OEWebContent* __weak content_;
  IMPLEMENT_REFCOUNTING(OEPageHandler);
};

// Runs a selection request's completion exactly once (also when the engine
// drops the callback unrun).
class OESelectionCallback : public CefSelectionCallback {
 public:
  explicit OESelectionCallback(void (^done)(NSString*, NSURL*))
      : done_([done copy]) {}
  ~OESelectionCallback() override {
    if (void (^done)(NSString*, NSURL*) = done_) {
      dispatch_async(dispatch_get_main_queue(), ^{
        done(@"", nil);
      });
    }
  }
  void OnSelection(const CefString& text, const CefString& link) override {
    void (^done)(NSString*, NSURL*) = done_;
    done_ = nil;
    if (!done) {
      return;
    }
    done(OEString(text) ?: @"", link.empty() ? nil : OEURL(link));
  }

 private:
  void (^done_)(NSString*, NSURL*);
  IMPLEMENT_REFCOUNTING(OESelectionCallback);
};

#pragma mark - OEWebContent

typedef void (^OEDevToolsCompletion)(NSDictionary* _Nullable, NSError* _Nullable);
typedef void (^OEOpenWorldCompletion)(id _Nullable, NSError* _Nullable);

@implementation OEWebContent {
  OEWebContentConfiguration* _configuration;
  OEWebContentView* _view;
  CefRefPtr<OEClient> _client;
  CefRefPtr<CefBrowser> _browser;
  NSURL* _pendingURL;
  NSString* _browserCreationURL;
  BOOL _hasNavigationAfterCreationSnapshot;
  BOOL _creating;
  BOOL _awaitingPopup;
  BOOL _closeRequested;
  BOOL _isPopup;
  OEWebContent* __weak _pendingChromePopup;
  // Chrome style hosting.
  CefRefPtr<CefWindowDelegate> _chromeHost;
  OEDevToolsDock* _devToolsDock;
  NSMutableDictionary<NSString*, NSString*>* _userStyleSheets;
  NSNumber* _devToolsDockPendingPanel;
  CefRefPtr<CefBrowserView> _adoptedBrowserView;
  NSWindow* __weak _chromeWindow;
  NSWindow* __weak _observedWindow;
  // DevTools protocol.
  CefRefPtr<CefRegistration> _devToolsRegistration;
  NSMutableDictionary<NSNumber*, OEDevToolsCompletion>* _devToolsCallbacks;
  int _nextDevToolsId;
  NSMutableDictionary<NSNumber*, OEOpenWorldCompletion>* _openWorldCallbacks;
  int _nextOpenWorldID;
  // The DevTools window's own browser (front end), while it is open.
  CefRefPtr<OEDevToolsClient> _devToolsFrontend;
  // The latest panel request through the front end (EP-4b).
  NSInteger _devToolsPanelRequest;
  NSString* _lastFindString;
  BOOL _autoResize;
  // Page API (cef_open_page.h): selection flag and swipe options.
  BOOL _hasSelection;
  BOOL _historySwipeEnabled;
  BOOL _drawsEngineHistorySwipeOverlay;
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
  // Tab sleeping: the history to install when the page is created, and the
  // URL to load if that fails.
  OENavigationHistory* _restoreHistory;
  NSURL* _restoreFallbackURL;
  OENavigationHistoryRestore _navigationHistoryRestore;
}

- (instancetype)initWithConfiguration:(OEWebContentConfiguration*)configuration
                                  URL:(NSURL*)URL {
  if ((self = [super init])) {
    _configuration = [configuration copy];
    _pendingURL = URL;
    _title = @"";
    _statusText = @"";
    _devToolsCallbacks = [NSMutableDictionary dictionary];
    _historySwipeEnabled = YES;
    _drawsEngineHistorySwipeOverlay = YES;
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
  return [self oe_extraInfoWithScripts:[self.context oe_scriptsValue]];
}

- (CefRefPtr<CefDictionaryValue>)oe_extraInfoWithScripts:(CefRefPtr<CefListValue>)scripts {
  CefRefPtr<CefDictionaryValue> extra = CefDictionaryValue::Create();
  // Keep a broadcast's shared serialization unowned by this per-page snapshot.
  extra->SetList(kOEExtraScripts, scripts->Copy());
  if (_userStyleSheets.count) {
    CefRefPtr<CefDictionaryValue> styles = CefDictionaryValue::Create();
    for (NSString* key in _userStyleSheets) {
      styles->SetString(OECef(key), OECef(_userStyleSheets[key]));
    }
    extra->SetDictionary(kOEExtraUserStyles, styles);
  }
  return extra;
}

- (void)setUserStyleSheet:(NSString*)css forKey:(NSString*)key {
  if (key.length == 0 || key.length > 256 || css.length > 1024 * 1024) {
    return;
  }
  if (!_userStyleSheets) _userStyleSheets = [NSMutableDictionary dictionary];
  if ((css.length ? [_userStyleSheets[key] isEqualToString:css]
                  : _userStyleSheets[key] == nil)) {
    return;
  }
  if (css.length) {
    _userStyleSheets[key] = [css copy];
  } else {
    [_userStyleSheets removeObjectForKey:key];
  }
  if (!_browser) {
    return;  // Delivered with the extra info when the browser is created.
  }
  // A later renderer process (cross-site navigation) gets it from the extra
  // info; the current one from the message.
  CefSetBrowserExtraInfo(_browser, [self oe_extraInfo]);
  CefRefPtr<CefProcessMessage> msg =
      CefProcessMessage::Create(kOEMsgUserStyleSheet);
  msg->GetArgumentList()->SetString(0, OECef(key));
  msg->GetArgumentList()->SetString(1, OECef(css ?: @""));
  _browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, msg);
}

- (CefBrowserSettings)oe_browserSettings {
  CefBrowserSettings settings;
  NSColor* bg = [(_configuration.backgroundColor ?: NSColor.whiteColor)
      colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
  settings.background_color =
      CefColorSetARGB(255, (int)(bg.redComponent * 255),
                      (int)(bg.greenComponent * 255),
                      (int)(bg.blueComponent * 255));
  // Tab sleeping: no renderer until the restored page is shown (fork patch
  // 0105; hosted tabs and Alloy pages).
  settings.no_renderer = _restoreHistory ? 1 : 0;
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
  [self oe_showPageIfVisible];
}

- (void)oe_createBrowser {
  _creating = YES;
  __weak OEWebContent* weakSelf = self;
  [self.context oe_whenReady:^{
    [weakSelf oe_createBrowserNow];
  }];
}

- (void)prepareForDisplay {
  if (_view.window && !_browser && !_creating && !_awaitingPopup &&
      !_closeRequested) {
    [self oe_createBrowser];
  }
}

- (void)oe_createBrowserNow {
  if (_closeRequested || _browser || !self.context.oe_isReady ||
      !self.context.oe_requestContext) {
    _creating = NO;
    return;
  }
  // A restored page starts with no URL: the history comes first.
  CefString url = _restoreHistory
                      ? CefString()
                      : OECef(_pendingURL.absoluteString ?: @"about:blank");
  _browserCreationURL = OEString(url);
  _hasNavigationAfterCreationSnapshot = NO;
#if DEBUG
  // As with the App's OPEN_AUTOMATION slow-start fixture, keep this hook
  // out of Release. Yield after the snapshot so a real loadURL: can arrive.
  if ([OEEngine.shared.configuration.additionalSwitches
          containsObject:@"--open-automation"]) {
    NSInteger delay = [NSProcessInfo.processInfo.environment[
        @"OPEN_AUTOMATION_BROWSER_CREATION_DELAY_MS"] integerValue];
    if (delay >= 1 && delay <= 5000) {
      fprintf(stderr, "OpenEngine: browser-creation-delay page=%ld ms=%ld\n",
              (long)self.identifier, (long)delay);
      __weak OEWebContent* weakSelf = self;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delay * NSEC_PER_MSEC),
                     dispatch_get_main_queue(), ^{
        [weakSelf oe_createBrowserWithURL:url];
      });
      return;
    }
  }
#endif
  [self oe_createBrowserWithURL:url];
}

- (void)oe_createBrowserWithURL:(const CefString&)initialURL {
  // The automation delay may outlive the host or its Profile.
  if (_closeRequested || _browser || !self.context.oe_isReady ||
      !self.context.oe_requestContext) {
    _creating = NO;
    return;
  }
  CefString url = initialURL;
  if (OEIsChromeNewTabURL(OEURL(url))) url = OECef(@"about:blank");
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
  if (_configuration.runtimeStyle == OERuntimeStyleChrome && _restoreHistory) {
    // A Views-window Chrome page navigates at creation: no restore there.
    [self oe_restoreFailed];
    url = OECef(_pendingURL.absoluteString ?: @"about:blank");
    if (OEIsChromeNewTabURL(OEURL(url))) url = OECef(@"about:blank");
    // The fallback URL is consumed by this creation call itself.
    _browserCreationURL = OEString(url);
    _hasNavigationAfterCreationSnapshot = NO;
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
  // Popups/adopted views have no creation snapshot. An ordinary initial
  // URL also needs no second load unless loadURL: changed it after that snapshot.
  NSURL* pendingNavigation =
      _hasNavigationAfterCreationSnapshot && _browserCreationURL &&
              ![_pendingURL.absoluteString isEqualToString:_browserCreationURL]
          ? _pendingURL : nil;
  BOOL restoreLoadedURL = NO;
  if (_restoreHistory) {
    // Before the page can be shown (hosted tabs: still inside CreateTab).
    [self oe_restoreHistoryIntoBrowser:browser];
    restoreLoadedURL =
        _navigationHistoryRestore == OENavigationHistoryRestoreFailed;
  }
  _browserCreationURL = nil;
  _hasNavigationAfterCreationSnapshot = NO;
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
  if (pendingNavigation && !restoreLoadedURL) {
    browser->GetMainFrame()->LoadURL(OECef(pendingNavigation.absoluteString));
  }
  if (_muted) {
    browser->GetHost()->SetAudioMuted(true);
  }
  [self oe_attachMedia:browser];
  // Selection changes and history swipe events (page-platform EP-1, EP-3).
  CefSetOpenPageHandler(browser, new OEPageHandler(self));
  if (!_historySwipeEnabled || !_drawsEngineHistorySwipeOverlay) {
    CefSetHistorySwipeOptions(browser, _historySwipeEnabled,
                              _drawsEngineHistorySwipeOverlay);
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
  [self oe_showPageIfVisible];
  [self oe_notify:OEWebContentChangeLive | OEWebContentChangeURL |
                  OEWebContentChangeLoading | OEWebContentChangeSecurity];
}

- (void)oe_browserClosed {
  [_devToolsDock unregisterForBrowser:_browser];
  _devToolsDockPendingPanel = nil;
  [_devToolsDock close];
  _browser = nullptr;
  _hasSelection = NO;
  _devToolsRegistration = nullptr;
  for (OEDevToolsCompletion done in _devToolsCallbacks.allValues) {
    done(nil, [NSError errorWithDomain:OEErrorDomain
                                  code:OEErrorWebContentClosed
                              userInfo:nil]);
  }
  [_devToolsCallbacks removeAllObjects];
  NSArray* pending = _openWorldCallbacks.allValues;
  [_openWorldCallbacks removeAllObjects];
  for (OEOpenWorldCompletion done in pending) {
    done(nil, [NSError errorWithDomain:OEErrorDomain code:OEErrorWebContentClosed userInfo:nil]);
  }
  if (_chromeHost) {
    // A Views-window Chrome page whose browser closed on its own
    // (window.close()): its frameless window would otherwise stay up, empty,
    // because a later -close finds no host left to close.
    OEChromeHostClose(_chromeHost);
  }
  _chromeHost = nullptr;
  _adoptedBrowserView = nullptr;
  _closeRequested = YES;
  [self oe_resetMediaDetaching:YES];
  [[OEEngine shared] oe_unregisterWebContent:self];
  [self oe_notify:OEWebContentChangeLive | OEWebContentChangeSecurity];
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

// Hosted tabs (P1) and Alloy pages restored with no_renderer start hidden.
// The view may already be visible when the browser is created, so replay its
// show after history restore as well as on later window/unhide events. Hiding
// and window occlusion still follow Chromium's WebContents view logic.
- (void)oe_showPageIfVisible {
  if (_browser &&
      (_oe_hostBrowser || _configuration.runtimeStyle == OERuntimeStyleAlloy) &&
      _view.window && !_view.isHiddenOrHasHiddenAncestor) {
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

- (void)oe_setAudible:(BOOL)audible {
  if (audible != _audible) {
    _audible = audible;
    [self oe_notify:OEWebContentChangeAudio];
  }
}

- (void)oe_setCrashState:(OEWebContentCrashState)state {
  if (_crashState == state) {
    return;
  }
  _crashState = state;
  if (state != OEWebContentCrashStateNone) {
    [self oe_resetMediaDetaching:NO];
  }
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
  if (OEIsChromeNewTabURL(URL)) {
    URL = [NSURL URLWithString:@"about:blank"];
  }
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
    if (_browserCreationURL) _hasNavigationAfterCreationSnapshot = YES;
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
  _client->CancelAuthenticationRequests();
  if (_browser) _browser->StopLoad();
}

#pragma mark Selection and history swipe (fork API cef_open_page.h)

- (BOOL)hasSelection {
  return _hasSelection;
}

- (void)oe_selectionChanged:(BOOL)hasSelection {
  if (_hasSelection == hasSelection) {
    return;
  }
  _hasSelection = hasSelection;
  [self oe_notify:OEWebContentChangeSelection];
}

- (void)requestSelectionWithCompletion:(void (^)(NSString*, NSURL*))completion {
  void (^done)(NSString*, NSURL*) = [completion copy];
  if (!_browser) {
    dispatch_async(dispatch_get_main_queue(), ^{
      done(@"", nil);
    });
    return;
  }
  if (!CefRequestSelection(_browser, new OESelectionCallback(done))) {
    // Refused without running the callback: the wrapper's destructor
    // answers once.
  }
}

- (BOOL)historySwipeEnabled {
  return _historySwipeEnabled;
}

- (void)setHistorySwipeEnabled:(BOOL)enabled {
  _historySwipeEnabled = enabled;
  if (_browser) {
    CefSetHistorySwipeOptions(_browser, _historySwipeEnabled,
                              _drawsEngineHistorySwipeOverlay);
  }
}

- (BOOL)drawsEngineHistorySwipeOverlay {
  return _drawsEngineHistorySwipeOverlay;
}

- (void)setDrawsEngineHistorySwipeOverlay:(BOOL)draws {
  _drawsEngineHistorySwipeOverlay = draws;
  if (_browser) {
    CefSetHistorySwipeOptions(_browser, _historySwipeEnabled,
                              _drawsEngineHistorySwipeOverlay);
  }
}

- (BOOL)simulateHistorySwipeInDirection:(OEHistorySwipeDirection)direction
                               progress:(double)progress {
  return _browser &&
         CefSimulateHistorySwipe(
             _browser, direction == OEHistorySwipeDirectionForward ? 1 : 0,
             progress);
}

- (void)oe_historySwipe:(int)phase
              direction:(int)direction
               progress:(double)progress {
  if ([_delegate respondsToSelector:@selector
                 (webContent:historySwipe:direction:progress:)]) {
    [_delegate webContent:self
             historySwipe:(OEHistorySwipePhase)std::clamp(phase, 0, 3)
                direction:direction == 1 ? OEHistorySwipeDirectionForward
                                         : OEHistorySwipeDirectionBack
                 progress:progress];
  }
}

#pragma mark Sleep (memory-fork; fork API cef_page_lifecycle.h)

- (instancetype)initWithConfiguration:(OEWebContentConfiguration*)configuration
                    navigationHistory:(OENavigationHistory*)history
                          fallbackURL:(nullable NSURL*)fallbackURL {
  if ((self = [self initWithConfiguration:configuration URL:nil])) {
    _restoreHistory = history;
    _restoreFallbackURL = [fallbackURL copy] ?: history.currentURL;
    _navigationHistoryRestore = OENavigationHistoryRestorePending;
  }
  return self;
}

- (OENavigationHistoryRestore)navigationHistoryRestore {
  return _navigationHistoryRestore;
}

// The page could not take the history: it loads the fallback URL instead.
- (void)oe_restoreFailed {
  NSLog(@"OEWebContent: navigation history restore failed; loading the "
        @"fallback URL");
  _restoreHistory = nil;
  // A navigation submitted after the creation snapshot wins over the saved
  // fallback. The failed-restore path below loads that URL exactly once.
  if (!_hasNavigationAfterCreationSnapshot) _pendingURL = _restoreFallbackURL;
  _restoreFallbackURL = nil;
  _navigationHistoryRestore = OENavigationHistoryRestoreFailed;
}

- (void)oe_restoreHistoryIntoBrowser:(CefRefPtr<CefBrowser>)browser {
  CefRefPtr<CefNavigationHistory> history = [_restoreHistory oe_cefHistory];
  if (history && CefRestoreNavigationHistory(browser, history)) {
    _restoreHistory = nil;
    _restoreFallbackURL = nil;
    _navigationHistoryRestore = OENavigationHistoryRestoreRestored;
    return;
  }
  [self oe_restoreFailed];
  if (_pendingURL) {
    browser->GetMainFrame()->LoadURL(OECef(_pendingURL.absoluteString));
  }
}

- (nullable OENavigationHistory*)captureNavigationHistory {
  if (!_browser) {
    return nil;
  }
  return [[OENavigationHistory alloc]
      initOEWithCefHistory:CefGetNavigationHistory(_browser)];
}

- (void)setPageHidden:(BOOL)hidden {
  if (_browser) {
    _browser->GetHost()->WasHidden(hidden);
  }
}

- (BOOL)setPageFrozen:(BOOL)frozen {
  return _browser && CefSetPageFrozen(_browser, frozen);
}

- (BOOL)isPageFrozen {
  return _browser && CefIsPageFrozen(_browser);
}

- (BOOL)isDiscarded {
  return _browser && CefWasDiscarded(_browser);
}

- (BOOL)hasUnloadHandlers {
  return _browser && CefHasUnloadHandlers(_browser);
}

- (void)discardWithCompletion:(void (^)(BOOL))completion {
  void (^done)(BOOL) = [completion copy];
  if (!_browser) {
    dispatch_async(dispatch_get_main_queue(), ^{
      done(NO);
    });
    return;
  }
  // The engine settles exactly once (also when it refuses or gives up); the
  // answer is the re-check, never the callback alone (memory-fork D-5).
  __weak OEWebContent* weakSelf = self;
  CefDiscardBrowser(_browser, new OECompletionCallback(^{
                      done(weakSelf.isDiscarded);
                    }));
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
  // DevTools input is real renderer input too. CEF's later navigation policy
  // callback omits its flags, just as it omits flags for native AppKit input.
  if ([method isEqualToString:@"Input.dispatchMouseEvent"] &&
      ([parameters[@"type"] isEqual:@"mousePressed"] ||
       [parameters[@"type"] isEqual:@"mouseReleased"])) {
    NSUInteger flags = [parameters[@"modifiers"] unsignedIntegerValue];
    NSEventModifierFlags modifiers = 0;
    if (flags & 1) modifiers |= NSEventModifierFlagOption;
    if (flags & 2) modifiers |= NSEventModifierFlagControl;
    if (flags & 4) modifiers |= NSEventModifierFlagCommand;
    if (flags & 8) modifiers |= NSEventModifierFlagShift;
    OENoteNavigationInput(self.view.window, modifiers);
  } else if ([method isEqualToString:@"Input.dispatchKeyEvent"]) {
    OENoteNavigationInput(nil, 0);
  }
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

- (void)oe_openWorldMessage:(CefRefPtr<CefProcessMessage>)message {
  auto args = message->GetArgumentList();
  if (message->GetName() == "oe.open.message") {
    NSString* type = OEString(args->GetString(0));
    NSString* payload = OEString(args->GetString(1));
    NSString* document = OEString(args->GetString(2));
    // Re-check at the browser boundary. Renderer limits run before IPC.
    if ([type lengthOfBytesUsingEncoding:NSUTF8StringEncoding] +
        [payload lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 65536 ||
        document.length > 128) return;
    auto callback = self.onOpenWorldMessage;
    id<OEWebContentDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(webContent:didReceiveOpenWorldMessage:payloadJSON:documentID:)]) {
      [delegate webContent:self didReceiveOpenWorldMessage:type
               payloadJSON:payload documentID:document];
    }
    if (callback) callback(type, payload, document);
    return;
  }
  NSNumber* request = @(args->GetInt(0));
  OEOpenWorldCompletion done = _openWorldCallbacks[request];
  if (!done) return;
  [_openWorldCallbacks removeObjectForKey:request];
  NSString* error = OEString(args->GetString(2));
  if (error.length) {
    done(nil, [NSError errorWithDomain:OEErrorDomain code:OEErrorJavaScriptException
        userInfo:@{NSLocalizedDescriptionKey:error}]);
  } else {
    NSData* data = [OEString(args->GetString(1)) dataUsingEncoding:NSUTF8StringEncoding];
    NSError* parseError = nil;
    id value = [NSJSONSerialization JSONObjectWithData:data
        options:NSJSONReadingFragmentsAllowed error:&parseError];
    done(value, parseError);
  }
}

- (void)oe_sendOpenWorldRequest:(const char*)name source:(NSString*)source
                   completion:(OEOpenWorldCompletion)completion {
  if (!_browser || _closeRequested || source.length > 1024 * 1024 ||
      _openWorldCallbacks.count >= 64) {
    completion(nil, [NSError errorWithDomain:OEErrorDomain code:OEErrorWebContentClosed
        userInfo:@{NSLocalizedDescriptionKey:@"Open-world request unavailable or over limit"}]);
    return;
  }
  // OECef uses a C string. Refuse text that would truncate or fail conversion
  // before it can become a different valid JavaScript program.
  if (![source canBeConvertedToEncoding:NSUTF8StringEncoding] ||
      [source rangeOfCharacterFromSet:[NSCharacterSet characterSetWithRange:NSMakeRange(0, 1)]].location != NSNotFound) {
    completion(nil, [NSError errorWithDomain:OEErrorDomain code:OEErrorJavaScriptException
        userInfo:@{NSLocalizedDescriptionKey:@"Open-world source contains invalid Unicode or NUL"}]);
    return;
  }
  if (!_openWorldCallbacks) _openWorldCallbacks = [NSMutableDictionary dictionary];
  // Never reuse request IDs; refuse exhaustion instead of accepting stale replies.
  if (_nextOpenWorldID == INT_MAX) {
    completion(nil, [NSError errorWithDomain:OEErrorDomain code:OEErrorWebContentClosed userInfo:nil]);
    return;
  }
  NSNumber* request = @(++_nextOpenWorldID);
  _openWorldCallbacks[request] = [completion copy];
  auto msg = CefProcessMessage::Create(name);
  msg->GetArgumentList()->SetInt(0, request.intValue);
  msg->GetArgumentList()->SetString(1, OECef(source));
  _browser->GetMainFrame()->SendProcessMessage(PID_RENDERER, msg);
  __weak OEWebContent* weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    OEWebContent* page = weakSelf;
    if (!page) return;
    OEOpenWorldCompletion done = page->_openWorldCallbacks[request];
    [page->_openWorldCallbacks removeObjectForKey:request];
    if (done) done(nil, [NSError errorWithDomain:OEErrorDomain code:OEErrorJavaScriptException
        userInfo:@{NSLocalizedDescriptionKey:@"Open-world request timed out (document may have changed)"}]);
  });
}

- (void)evaluateJavaScript:(NSString*)script inWorld:(OEScriptWorld)world
               completion:(void (^)(id, NSError*))completion {
  if (world == OEScriptWorldPage) {
    [self evaluateJavaScript:script completion:completion];
  } else {
    [self oe_sendOpenWorldRequest:"oe.open.eval" source:script completion:completion];
  }
}

- (void)openWorldMessageStatisticsWithCompletion:(void (^)(NSDictionary*, NSError*))completion {
  [self oe_sendOpenWorldRequest:"oe.open.stats" source:@"" completion:completion];
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

#pragma mark Full-page capture (EP-8)

/// Largest tile edge and output width in device pixels. Tiles stay under the
/// GPU texture size every Mac supports; the stitched bitmap is at most
/// 4,096 × maxDevicePixels × 4 bytes (512 MiB at the 32,768 px cap).
static const NSInteger kOECaptureTilePixels = 4096;

static NSError* OECaptureError(NSString* message) {
  return [NSError errorWithDomain:OEErrorDomain
                             code:OEErrorDevToolsFailure
                         userInfo:@{NSLocalizedDescriptionKey : message}];
}

/// Decodes the tiles, draws them top to bottom, and encodes one PNG. Runs on
/// a utility queue: only NSData crosses threads.
static NSData* OEStitchTiles(NSArray<NSData*>* tiles, NSError** error) {
  NSMutableArray* images = [NSMutableArray array];
  size_t width = 0, height = 0;
  for (NSData* tile in tiles) {
    CGImageSourceRef source =
        CGImageSourceCreateWithData((__bridge CFDataRef)tile, nullptr);
    CGImageRef image =
        source ? CGImageSourceCreateImageAtIndex(source, 0, nullptr) : nullptr;
    if (source) {
      CFRelease(source);
    }
    if (!image) {
      *error = OECaptureError(@"Unable to read a full page tile.");
      return nil;
    }
    width = MAX(width, CGImageGetWidth(image));
    height += CGImageGetHeight(image);
    [images addObject:(__bridge_transfer id)image];
  }
  if (width == 0 || height == 0 || width > (size_t)kOECaptureTilePixels * 2) {
    *error = OECaptureError(@"The full page capture is empty or too wide.");
    return nil;
  }
  CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CGContextRef context = CGBitmapContextCreate(
      nullptr, width, height, 8, 0, space,
      (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
  CGColorSpaceRelease(space);
  if (!context) {
    *error = OECaptureError(@"Unable to allocate the full page image.");
    return nil;
  }
  CGContextSetRGBFillColor(context, 1, 1, 1, 1);
  CGContextFillRect(context, CGRectMake(0, 0, width, height));
  // Core Graphics is bottom-up: the first tile goes at the top.
  CGFloat top = height;
  for (id object in images) {
    CGImageRef image = (__bridge CGImageRef)object;
    CGFloat h = CGImageGetHeight(image);
    top -= h;
    CGContextDrawImage(context,
                       CGRectMake(0, top, CGImageGetWidth(image), h), image);
  }
  CGImageRef stitched = CGBitmapContextCreateImage(context);
  CGContextRelease(context);
  [images removeAllObjects];
  if (!stitched) {
    *error = OECaptureError(@"Unable to draw the full page image.");
    return nil;
  }
  NSMutableData* png = [NSMutableData data];
  CGImageDestinationRef destination = CGImageDestinationCreateWithData(
      (__bridge CFMutableDataRef)png,
      CFSTR("public.png"), 1, nullptr);
  BOOL ok = NO;
  if (destination) {
    CGImageDestinationAddImage(destination, stitched, nullptr);
    ok = CGImageDestinationFinalize(destination);
    CFRelease(destination);
  }
  CGImageRelease(stitched);
  if (!ok) {
    *error = OECaptureError(@"Unable to encode the full page image.");
    return nil;
  }
  return png;
}

/// Pixel width from a PNG's header (0 when it is not one).
static double OEPNGPixelWidth(NSData* png) {
  if (!png.length) {
    return 0;
  }
  CGImageSourceRef source =
      CGImageSourceCreateWithData((__bridge CFDataRef)png, nullptr);
  if (!source) {
    return 0;
  }
  NSDictionary* properties = CFBridgingRelease(
      CGImageSourceCopyPropertiesAtIndex(source, 0, nullptr));
  CFRelease(source);
  return [properties[(__bridge NSString*)kCGImagePropertyPixelWidth]
      doubleValue];
}

- (void)captureFullPageWithMaxDevicePixels:(NSInteger)maxDevicePixels
                                completion:(void (^)(NSData* _Nullable, BOOL,
                                                     NSError* _Nullable))
                                               completion {
  void (^done)(NSData*, BOOL, NSError*) = [completion copy];
  if (!_browser) {
    done(nil, NO,
         [NSError errorWithDomain:OEErrorDomain
                             code:OEErrorWebContentClosed
                         userInfo:nil]);
    return;
  }
  // The device scale the screenshots come out at: one visible-page shot's
  // pixel width over the view's width in points. It follows the window's
  // backing scale and DevTools device emulation alike; the layout metrics
  // do not (`contentSize` stays in CSS pixels on the Mac, even under
  // emulation). Fallback: the window's, else the main screen's, backing scale.
  CGFloat fallbackScale = self.view.window.backingScaleFactor
                              ?: NSScreen.mainScreen.backingScaleFactor ?: 2;
  CGFloat viewWidth = self.view.bounds.size.width;
  __weak OEWebContent* weakSelf = self;
  [self takeSnapshotWithCompletion:^(NSData* shot, NSError* shotError) {
    OEWebContent* strongSelf = weakSelf;
    if (!strongSelf) {
      done(nil, NO, shotError ?: OECaptureError(@"The page closed."));
      return;
    }
    double measured = viewWidth > 0 ? OEPNGPixelWidth(shot) / viewWidth : 0;
    double scale = isfinite(measured) && measured >= 0.5 && measured <= 8
                       ? round(measured * 100) / 100
                       : fallbackScale;
    [strongSelf oe_captureFullPageAtScale:scale
                         maxDevicePixels:maxDevicePixels
                              completion:done];
  }];
}

- (void)oe_captureFullPageAtScale:(double)scale
                  maxDevicePixels:(NSInteger)maxDevicePixels
                       completion:(void (^)(NSData*, BOOL, NSError*))done {
  __weak OEWebContent* weakSelf = self;
  [self sendDevToolsMethod:@"Page.getLayoutMetrics"
                parameters:nil
                completion:^(NSDictionary* metrics, NSError* error) {
                  OEWebContent* strongSelf = weakSelf;
                  NSDictionary* size = metrics[@"cssContentSize"];
                  double contentWidth = [size[@"width"] doubleValue];
                  double contentHeight = [size[@"height"] doubleValue];
                  if (!strongSelf || error || contentWidth < 1 ||
                      contentHeight < 1) {
                    done(nil, NO,
                         error ?: OECaptureError(
                                      @"The page has no size to capture."));
                    return;
                  }
                  double tile = floor(kOECaptureTilePixels / scale);
                  double width = MIN(ceil(contentWidth), tile);
                  double cap = floor(MAX(maxDevicePixels, 1) / scale);
                  double height = MIN(ceil(contentHeight), cap);
                  [strongSelf oe_captureTilesFrom:0
                                            width:width
                                           height:height
                                             tile:tile
                                            tiles:[NSMutableArray array]
                                        truncated:ceil(contentHeight) > cap
                                       completion:done];
                }];
}

/// One tile at a time (each capture resizes the widget temporarily), CSS
/// pixels in document coordinates.
- (void)oe_captureTilesFrom:(double)y
                      width:(double)width
                     height:(double)height
                       tile:(double)tile
                      tiles:(NSMutableArray<NSData*>*)tiles
                  truncated:(BOOL)truncated
                 completion:(void (^)(NSData*, BOOL, NSError*))done {
  if (y >= height) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
      NSError* error = nil;
      NSData* png = OEStitchTiles(tiles, &error);
      dispatch_async(dispatch_get_main_queue(), ^{
        done(png, truncated, png ? nil : error);
      });
    });
    return;
  }
  double h = MIN(tile, height - y);
  __weak OEWebContent* weakSelf = self;
  [self sendDevToolsMethod:@"Page.captureScreenshot"
                parameters:@{
                  @"format" : @"png",
                  @"fromSurface" : @YES,
                  @"captureBeyondViewport" : @YES,
                  @"clip" : @{
                    @"x" : @0,
                    @"y" : @(y),
                    @"width" : @(width),
                    @"height" : @(h),
                    @"scale" : @1
                  },
                }
                completion:^(NSDictionary* result, NSError* error) {
                  OEWebContent* strongSelf = weakSelf;
                  NSString* b64 = result[@"data"];
                  NSData* png = b64 ? [[NSData alloc]
                                          initWithBase64EncodedString:b64
                                                              options:0]
                                    : nil;
                  if (!strongSelf || !png) {
                    done(nil, NO,
                         error ?: OECaptureError(
                                     @"A full page tile could not be captured."));
                    return;
                  }
                  [tiles addObject:png];
                  [strongSelf oe_captureTilesFrom:y + h
                                            width:width
                                           height:height
                                             tile:tile
                                            tiles:tiles
                                        truncated:truncated
                                       completion:done];
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

- (BOOL)showDevToolsPanel:(OEDevToolsPanel)panel {
  if (!_browser) {
    return NO;
  }
  // Version-safe IDC ids (cef_id_mappers.h); -1 if this build lacks one.
  const char* name = nullptr;
  // The front end's own panel id, for the path through DevToolsAPI.
  NSString* frontendPanel = nil;
  switch (panel) {
    case OEDevToolsPanelConsole:
      name = "IDC_DEV_TOOLS_CONSOLE";
      frontendPanel = @"console";
      break;
    case OEDevToolsPanelInspectMode:
      name = "IDC_DEV_TOOLS_INSPECT";
      break;
    case OEDevToolsPanelElements:
      frontendPanel = @"elements";
      break;
    case OEDevToolsPanelNetwork:
      frontendPanel = @"network";
      break;
    case OEDevToolsPanelDefault:
      break;
  }
  int command = name ? cef_id_for_command_id_name(name) : -1;
  CefRefPtr<CefBrowserHost> host = _browser->GetHost();
  // A hosted tab's Chrome browser is the window's hidden strip, whose
  // commands act on Chromium's active tab, not necessarily this page.
  OEBrowser* strip = _oe_hostBrowser;
  BOOL targetsThisPage = !strip || [strip oe_isChromiumActiveTab:self];
  // Every request ends an older panel retry (a Network request still retrying
  // must not switch back after a later Console request).
  _devToolsPanelRequest += 1;
  // DevTools already open (for example from Network Inspector): Chrome's
  // Console command does not switch that window's panel, so use the front end.
  BOOL useFrontend = frontendPanel && [self hasDevTools];
  if (command >= 0 && targetsThisPage && !useFrontend &&
      host->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME &&
      host->CanExecuteChromeCommand(command)) {
    host->ExecuteChromeCommand(command, CEF_WOD_CURRENT_TAB);
    return YES;
  }
  [self showDevTools];
  if (frontendPanel) {
    // EP-4b without a fork patch: the front end selects the panel through
    // DevToolsAPI.showPanel, the call Chrome itself makes for its Console
    // command (DevToolsWindow::DoAction). The front end exists and loads a
    // moment after showDevTools; retry until the panel's tab is selected.
    [self oe_selectFrontendPanel:frontendPanel
                         request:_devToolsPanelRequest
                         attempt:0];
    return YES;
  }
  return NO;
}

// One try every 250 ms for at most 15 s; a newer request ends older ones.
- (void)oe_selectFrontendPanel:(NSString*)panel
                       request:(NSInteger)request
                       attempt:(int)attempt {
  if (request != _devToolsPanelRequest || attempt >= 60 || !_browser) {
    return;
  }
  NSString* script = [NSString
      stringWithFormat:
          @"(() => { const name = '%@'; if (!globalThis.DevToolsAPI || "
          @"!globalThis.InspectorFrontendAPI) return false; const selected = []; "
          @"const walk = (root) => { for (const el of root.querySelectorAll("
          @"'[role=tab][aria-selected=true]')) selected.push(el.id); for (const "
          @"el of root.querySelectorAll('*')) if (el.shadowRoot) "
          @"walk(el.shadowRoot); }; walk(document); if (selected.includes('tab-' "
          @"+ name)) return true; DevToolsAPI.showPanel(name); return false; })()",
          panel];
  __weak OEWebContent* weakSelf = self;
  void (^retry)(void) = ^{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     [weakSelf oe_selectFrontendPanel:panel
                                              request:request
                                              attempt:attempt + 1];
                   });
  };
  [self evaluateJavaScriptInDevToolsFrontend:script
                                  completion:^(id result, NSError* error) {
                                    if (![result isEqual:@YES]) {
                                      retry();
                                    }
                                  }];
}

- (void)oe_setDevToolsFrontend:(OEDevToolsClient*)frontend {
  _devToolsFrontend = frontend;
}

- (void)oe_devToolsFrontendClosed:(OEDevToolsClient*)frontend {
  if (_devToolsFrontend.get() == frontend) {
    _devToolsFrontend = nullptr;
  }
  [_devToolsDock close];
  NSNumber* pending = _devToolsDockPendingPanel;
  _devToolsDockPendingPanel = nil;
  if (pending && _browser) {
    // -devToolsViewForPanel: closed the window-mode DevTools; open it docked.
    __weak OEWebContent* weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      OEWebContent* strongSelf = weakSelf;
      if (strongSelf && !strongSelf.hasDevTools) {
        [strongSelf showDevToolsPanel:(OEDevToolsPanel)pending.integerValue];
      }
    });
  }
}

- (void)evaluateJavaScriptInDevToolsFrontend:(NSString*)script
                                  completion:(void (^)(id _Nullable,
                                                       NSError* _Nullable))
                                                 completion {
  CefRefPtr<OEDevToolsClient> frontend = _devToolsFrontend;
  if (!frontend || !frontend->IsOpen()) {
    completion(nil, [NSError errorWithDomain:OEErrorDomain
                                        code:OEErrorWebContentClosed
                                    userInfo:@{
                                      NSLocalizedDescriptionKey :
                                          @"No DevTools window is open"
                                    }]);
    return;
  }
  frontend->Evaluate(script, completion);
}

- (NSView*)devToolsViewForPanel:(OEDevToolsPanel)panel {
  if (!_browser || _configuration.runtimeStyle != OERuntimeStyleChrome) {
    return nil;
  }
  if (!_devToolsDock) {
    _devToolsDock = [[OEDevToolsDock alloc] init];
  }
  if (!_devToolsDock.isHostingFrontend) {
    if (self.hasDevTools) {
      // Open in its own window: CEF has one DevTools per page. Reopen docked
      // once that window has closed (OEDevToolsClient::OnBeforeClose).
      _devToolsDockPendingPanel = @(panel);
      [_devToolsDock registerForBrowser:_browser];
      _browser->GetHost()->CloseDevTools();
      return _devToolsDock.view;
    }
    [_devToolsDock registerForBrowser:_browser];
  }
  [self showDevToolsPanel:panel];
  return _devToolsDock.view;
}

- (void)closeDevTools {
  _devToolsDockPendingPanel = nil;
  [_devToolsDock unregisterForBrowser:_browser];
  [_devToolsDock close];
  if (_browser) _browser->GetHost()->CloseDevTools();
}

- (BOOL)hasDevTools {
  return _browser && _browser->GetHost()->HasDevTools();
}

- (void)print {
  if (_browser) _browser->GetHost()->Print();
}

- (void)printToPDFAtURL:(NSURL*)fileURL completion:(void (^)(BOOL))completion {
  if (!_browser || !fileURL.isFileURL || !fileURL.path.length) {
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
