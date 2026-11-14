#import "OEInternal.h"

#include <mutex>

#include "include/cef_open_browser_info.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/wrapper/cef_helpers.h"

#pragma mark - OEUserScript

@implementation OEUserScript

- (instancetype)initWithIdentifier:(NSString*)identifier
                            source:(NSString*)source
                              kind:(OEUserScriptKind)kind
                     injectionTime:(OEUserScriptInjectionTime)injectionTime
                     matchPatterns:(NSArray<NSString*>*)matchPatterns
                     mainFrameOnly:(BOOL)mainFrameOnly {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _source = [source copy];
    _kind = kind;
    _injectionTime = injectionTime;
    _matchPatterns = [matchPatterns copy];
    _mainFrameOnly = mainFrameOnly;
  }
  return self;
}

- (id)copyWithZone:(NSZone*)zone {
  OEUserScript* copy = [[OEUserScript alloc] initWithIdentifier:_identifier
      source:_source kind:_kind injectionTime:_injectionTime
      matchPatterns:_matchPatterns mainFrameOnly:_mainFrameOnly];
  copy.world = _world;
  return copy;
}

@end

#pragma mark - OEResourceRequest

@interface OEResourceRequest ()
- (instancetype)initOEWithRequest:(CefRefPtr<CefRequest>)request
                         initiator:(NSString*)initiator
                        navigation:(BOOL)navigation
                         browserId:(NSInteger)browserId;
@end

@implementation OEResourceRequest

static OEResourceType OEMapResourceType(cef_resource_type_t t) {
  switch (t) {
    case RT_MAIN_FRAME:
    case RT_NAVIGATION_PRELOAD_MAIN_FRAME:
      return OEResourceTypeMainFrame;
    case RT_SUB_FRAME:
    case RT_NAVIGATION_PRELOAD_SUB_FRAME:
      return OEResourceTypeSubFrame;
    case RT_STYLESHEET:
      return OEResourceTypeStylesheet;
    case RT_SCRIPT:
      return OEResourceTypeScript;
    case RT_IMAGE:
      return OEResourceTypeImage;
    case RT_FONT_RESOURCE:
      return OEResourceTypeFont;
    case RT_MEDIA:
      return OEResourceTypeMedia;
    case RT_XHR:
      return OEResourceTypeXHR;
    case RT_PING:
    case RT_CSP_REPORT:
      return OEResourceTypePing;
    case RT_WORKER:
    case RT_SHARED_WORKER:
      return OEResourceTypeWorker;
    case RT_SERVICE_WORKER:
      return OEResourceTypeServiceWorker;
    case RT_FAVICON:
      return OEResourceTypeFavicon;
    default:
      return OEResourceTypeOther;
  }
}

- (instancetype)initOEWithRequest:(CefRefPtr<CefRequest>)request
                         initiator:(NSString*)initiator
                        navigation:(BOOL)navigation
                         browserId:(NSInteger)browserId {
  if ((self = [super init])) {
    _URLString = OEString(request->GetURL());
    _method = OEString(request->GetMethod());
    _firstPartyURLString = OEString(request->GetFirstPartyForCookies());
    _initiator = [initiator copy];
    _resourceType = OEMapResourceType(request->GetResourceType());
    _isNavigation = navigation;
    _webContentIdentifier = browserId;
  }
  return self;
}

@end

#pragma mark - Request context handler (network filter)

namespace {

class BlockingResourceHandler : public CefResourceRequestHandler {
 public:
  ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                   CefRefPtr<CefFrame> frame,
                                   CefRefPtr<CefRequest> request,
                                   CefRefPtr<CefCallback> callback) override {
    return RV_CANCEL;
  }
  IMPLEMENT_REFCOUNTING(BlockingResourceHandler);
};

// The filter decides in GetResourceRequestHandler (IO thread), so allowed
// requests get no per-request handler and no interception overhead.
class OERequestContextHandler : public CefRequestContextHandler {
 public:
  explicit OERequestContextHandler(OEBrowserContext* context)
      : context_(context), block_(new BlockingResourceHandler()) {}

  void OnRequestContextInitialized(
      CefRefPtr<CefRequestContext> request_context) override {
    __weak OEBrowserContext* context = context_;
    dispatch_async(dispatch_get_main_queue(), ^{
      [context oe_contextInitialized];
    });
  }

  void SetFilter(OERequestFilter filter) {
    std::lock_guard<std::mutex> lock(mutex_);
    filter_ = [filter copy];
  }

  CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(
      CefRefPtr<CefBrowser> browser,
      CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request,
      bool is_navigation,
      bool is_download,
      const CefString& request_initiator,
      bool& disable_default_handling) override {
    OERequestFilter filter;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      filter = filter_;
    }
    if (!filter) {
      return nullptr;
    }
    @autoreleasepool {
      OEResourceRequest* info = [[OEResourceRequest alloc]
          initOEWithRequest:request
                   initiator:OEString(request_initiator)
                  navigation:is_navigation
                   browserId:browser ? browser->GetIdentifier() : 0];
      if (filter(info) == OERequestDecisionBlock) {
        return block_;
      }
    }
    return nullptr;
  }

 private:
  __weak OEBrowserContext* context_;
  std::mutex mutex_;
  OERequestFilter filter_;
  CefRefPtr<CefResourceRequestHandler> block_;
  IMPLEMENT_REFCOUNTING(OERequestContextHandler);
};

class DeleteCookiesCallback : public CefDeleteCookiesCallback {
 public:
  explicit DeleteCookiesCallback(void (^done)(void)) : done_([done copy]) {}
  ~DeleteCookiesCallback() override {
    // Released unrun (the cookie store went away): still answer once.
    if (void (^done)(void) = done_) {
      dispatch_async(dispatch_get_main_queue(), done);
    }
  }
  void OnComplete(int num_deleted) override {
    void (^done)(void) = done_;
    done_ = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
      if (done) {
        done();
      }
    });
  }

 private:
  void (^done_)(void);
  IMPLEMENT_REFCOUNTING(DeleteCookiesCallback);
};

cef_content_setting_types_t OEContentSettingType(OEPermissionKind kind) {
  switch (kind) {
    case OEPermissionKindCamera:
      return CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA;
    case OEPermissionKindMicrophone:
      return CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC;
    case OEPermissionKindGeolocation:
      return CEF_CONTENT_SETTING_TYPE_GEOLOCATION;
    case OEPermissionKindNotifications:
      return CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS;
    case OEPermissionKindClipboard:
      return CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE;
    case OEPermissionKindMIDI:
      return CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX;
    case OEPermissionKindScreenCapture:
      return CEF_CONTENT_SETTING_TYPE_DISPLAY_CAPTURE;
    case OEPermissionKindMultipleDownloads:
      return CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS;
    case OEPermissionKindStorageAccess:
      return CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS;
    case OEPermissionKindWindowManagement:
      return CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT;
    case OEPermissionKindLocalFonts:
      return CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS;
    case OEPermissionKindIdleDetection:
      return CEF_CONTENT_SETTING_TYPE_IDLE_DETECTION;
    default:
      return CEF_CONTENT_SETTING_TYPE_NUM_VALUES;
  }
}

}  // namespace

OEPermissionKind OEPermissionKindsFromPrompt(uint32_t p) {
  OEPermissionKind k = 0;
  if (p & CEF_PERMISSION_TYPE_CAMERA_STREAM) k |= OEPermissionKindCamera;
  if (p & CEF_PERMISSION_TYPE_MIC_STREAM) k |= OEPermissionKindMicrophone;
  if (p & CEF_PERMISSION_TYPE_GEOLOCATION) k |= OEPermissionKindGeolocation;
  if (p & CEF_PERMISSION_TYPE_NOTIFICATIONS) k |= OEPermissionKindNotifications;
  if (p & CEF_PERMISSION_TYPE_CLIPBOARD) k |= OEPermissionKindClipboard;
  if (p & CEF_PERMISSION_TYPE_MIDI_SYSEX) k |= OEPermissionKindMIDI;
  if (p & CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS)
    k |= OEPermissionKindMultipleDownloads;
  if (p & (CEF_PERMISSION_TYPE_STORAGE_ACCESS |
           CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS))
    k |= OEPermissionKindStorageAccess;
  if (p & CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT)
    k |= OEPermissionKindWindowManagement;
  if (p & CEF_PERMISSION_TYPE_LOCAL_FONTS) k |= OEPermissionKindLocalFonts;
  if (p & CEF_PERMISSION_TYPE_IDLE_DETECTION)
    k |= OEPermissionKindIdleDetection;
  if (p & CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER)
    k |= OEPermissionKindProtocolHandler;
  if (k == 0 && p != 0) k = OEPermissionKindOther;
  return k;
}

OEPermissionKind OEPermissionKindsFromMedia(uint32_t m) {
  OEPermissionKind k = 0;
  if (m & CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE) k |= OEPermissionKindCamera;
  if (m & CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE)
    k |= OEPermissionKindMicrophone;
  if (m & (CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE |
           CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE))
    k |= OEPermissionKindScreenCapture;
  return k;
}

#pragma mark - OEDownload

@interface OEDownload ()
- (instancetype)initOEWithItem:(CefRefPtr<CefDownloadItem>)item
                     webContent:(nullable OEWebContent*)webContent;
- (void)oe_updateWithItem:(CefRefPtr<CefDownloadItem>)item
                 callback:(CefRefPtr<CefDownloadItemCallback>)callback;
- (void)oe_setDestinationCallback:(CefRefPtr<CefBeforeDownloadCallback>)callback;
- (void)oe_decideDestination:(nullable NSURL*)destination;
- (void)oe_invalidate;
@end

@implementation OEDownload {
  CefRefPtr<CefDownloadItemCallback> _callback;
  CefRefPtr<CefBeforeDownloadCallback> _destinationCallback;
}

- (instancetype)initOEWithItem:(CefRefPtr<CefDownloadItem>)item
                     webContent:(OEWebContent*)webContent {
  if ((self = [super init])) {
    _identifier = item->GetId();
    _sourceURL = OEURL(item->GetURL()) ?: [NSURL URLWithString:@"about:blank"];
    _suggestedFilename = OEString(item->GetSuggestedFileName());
    _MIMEType = OEString(item->GetMimeType());
    _webContent = webContent;
    _totalBytes = -1;
    _state = OEDownloadStatePending;
  }
  return self;
}

- (void)oe_updateWithItem:(CefRefPtr<CefDownloadItem>)item
                 callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  if (callback) {
    _callback = callback;
  }
  NSString* path = OEString(item->GetFullPath());
  if (path.length) {
    _destinationURL = [NSURL fileURLWithPath:path];
  }
  _receivedBytes = item->GetReceivedBytes();
  _totalBytes = item->GetTotalBytes() > 0 ? item->GetTotalBytes() : -1;
  _bytesPerSecond = item->GetCurrentSpeed();
  if (item->IsComplete()) {
    _state = OEDownloadStateComplete;
  } else if (item->IsCanceled()) {
    _state = OEDownloadStateCancelled;
  } else if (item->IsInterrupted()) {
    _state = OEDownloadStateInterrupted;
  } else if (item->IsInProgress()) {
    _state = OEDownloadStateInProgress;
  }
}

- (void)cancel {
  _destinationCallback = nullptr;
  if (_callback) _callback->Cancel();
}
- (void)pause {
  if (_callback) _callback->Pause();
}
- (void)resume {
  if (_callback) _callback->Resume();
}

- (void)oe_invalidate {
  _destinationCallback = nullptr;
  _callback = nullptr;
}

- (void)oe_setDestinationCallback:(CefRefPtr<CefBeforeDownloadCallback>)callback {
  _destinationCallback = callback;
}

- (void)oe_decideDestination:(nullable NSURL*)destination {
  // The shell may retain its completion after context teardown. Keep the CEF
  // handle here so invalidation also makes that retained completion inert.
  auto callback = _destinationCallback;
  _destinationCallback = nullptr;
  if (callback && destination) callback->Continue(OECef(destination.path), false);
}

@end

#pragma mark - Notifications (cef_open_page.h)

@interface OEBrowserContext (OENotificationEvents)
- (void)oe_notificationClicked:(NSString*)identifier
                        origin:(NSString*)origin
                    persistent:(BOOL)persistent;
@end

class OENotificationHandler : public CefOpenNotificationHandler {
 public:
  explicit OENotificationHandler(OEBrowserContext* context)
      : context_(context) {}
  void OnNotificationClick(const CefString& id,
                           const CefString& origin,
                           CefRefPtr<CefBrowser> browser,
                           bool persistent) override {
    [context_ oe_notificationClicked:OEString(id)
                              origin:OEString(origin)
                          persistent:persistent];
  }

 private:
  OEBrowserContext* __weak context_;
  IMPLEMENT_REFCOUNTING(OENotificationHandler);
};

class OENotificationListCallback : public CefNotificationListCallback {
 public:
  explicit OENotificationListCallback(
      void (^done)(NSArray<NSDictionary<NSString*, NSString*>*>*))
      : done_([done copy]) {}
  ~OENotificationListCallback() override {
    if (auto done = done_) {
      dispatch_async(dispatch_get_main_queue(), ^{
        done(@[]);
      });
    }
  }
  void OnNotifications(CefRefPtr<CefListValue> items) override {
    auto done = done_;
    done_ = nil;
    if (!done) {
      return;
    }
    NSMutableArray* out = [NSMutableArray array];
    for (size_t i = 0; items && i < items->GetSize(); ++i) {
      CefRefPtr<CefDictionaryValue> item = items->GetDictionary(i);
      if (!item) {
        continue;
      }
      [out addObject:@{
        @"id" : OEString(item->GetString("id")) ?: @"",
        @"origin" : OEString(item->GetString("origin")) ?: @"",
        @"title" : OEString(item->GetString("title")) ?: @"",
        @"body" : OEString(item->GetString("body")) ?: @"",
      }];
    }
    done(out);
  }

 private:
  void (^done_)(NSArray<NSDictionary<NSString*, NSString*>*>*);
  IMPLEMENT_REFCOUNTING(OENotificationListCallback);
};

#pragma mark - OEBrowserContext

class OEProfileLifetimeHandler : public CefOpenProfileHandler {
 public:
  explicit OEProfileLifetimeHandler(OEBrowserContext* context) : context_(context) {}
  void OnContextClosed() override { [context_ oe_nativeContextClosed]; }
 private:
  __weak OEBrowserContext* context_;
  IMPLEMENT_REFCOUNTING(OEProfileLifetimeHandler);
};

class OEBrowsingDataCallback : public CefOpenProfileCallback {
 public:
  explicit OEBrowsingDataCallback(void (^done)(NSError*)) : done_([done copy]) {}
  ~OEBrowsingDataCallback() override {
    if (auto done = done_) {
      dispatch_async(dispatch_get_main_queue(), ^{
        done([NSError errorWithDomain:OEErrorDomain code:OEErrorContextClosed
                             userInfo:@{NSLocalizedDescriptionKey: @"The profile closed before data removal completed."}]);
      });
    }
  }
  void OnComplete(const CefString& error) override {
    auto done = done_; done_ = nil;
    if (done) done(error.empty() ? nil : [NSError errorWithDomain:OEErrorDomain
        code:OEErrorUnsupported userInfo:@{NSLocalizedDescriptionKey: OEString(error)}]);
  }
 private:
  void (^done_)(NSError*);
  IMPLEMENT_REFCOUNTING(OEBrowsingDataCallback);
};

@implementation OEBrowserContext {
  CefRefPtr<CefRequestContext> _context;
  CefRefPtr<OERequestContextHandler> _handler;
  NSMutableArray<OEUserScript*>* _scripts;
  NSMutableDictionary<NSNumber*, OEDownload*>* _downloads;
  OERequestFilter _requestFilter;
  BOOL _ready;
  NSMutableArray<dispatch_block_t>* _whenReady;
  BOOL _colorSchemeApplied;
}

- (instancetype)initOEWithIdentifier:(NSString*)identifier
                            directory:(nullable NSURL*)directory
                               global:(BOOL)global {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _directory = [directory copy];
    _ephemeral = directory == nil;
    _scripts = [NSMutableArray array];
    _downloads = [NSMutableDictionary dictionary];
    _whenReady = [NSMutableArray array];
    _handler = new OERequestContextHandler(self);
    if (global) {
      // Same storage as the global context, plus our handler.
      _context = CefRequestContext::CreateContext(
          CefRequestContext::GetGlobalContext(), _handler.get());
    } else {
      CefRequestContextSettings settings;
      if (directory) {
        // Private, as Chromium makes its profile folders.
        NSDictionary* privateFolder = @{NSFilePosixPermissions : @0700};
        [NSFileManager.defaultManager createDirectoryAtURL:directory
                               withIntermediateDirectories:YES
                                                attributes:privateFolder
                                                     error:nil];
        [NSFileManager.defaultManager setAttributes:privateFolder
                                       ofItemAtPath:directory.path
                                              error:nil];
        CefString(&settings.cache_path) = directory.path.UTF8String;
        settings.persist_session_cookies = true;
      }
      // An empty cache_path gives an in-memory (incognito) Chrome profile.
      _context = CefRequestContext::CreateContext(settings, _handler.get());
    }
    _extensions = [[OEExtensionManager alloc] initOEWithContext:self];
    [OEEngine.shared oe_registerContext:self];
  }
  return self;
}

- (instancetype)initOEIncognitoWithIdentifier:(NSString*)identifier
                                      original:(OEBrowserContext*)original {
  if ((self = [super init])) {
    _identifier = [identifier copy];
    _originalContext = original;
    _ephemeral = YES;
    _scripts = [NSMutableArray array];
    _downloads = [NSMutableDictionary dictionary];
    _whenReady = [NSMutableArray array];
    _handler = new OERequestContextHandler(self);
    _context = CefCreateIncognitoContext(original.oe_requestContext, _handler);
    if (!_context) return nil;
    _extensions = [[OEExtensionManager alloc] initOEWithContext:self];
    [OEEngine.shared oe_registerContext:self];
  }
  return self;
}

- (void)dealloc {
  // A presenter may retain the manager after this context goes away. Its
  // CEF profile/observers must still close with the owning context.
  [self oe_closeAutofill];
  [_extensions oe_contextClosed];
  if (_context) CefSetOpenProfileHandler(_context, nullptr);
}

- (CefRefPtr<CefRequestContext>)oe_requestContext {
  return _state == OEBrowserContextStateClosed ? nullptr : _context;
}

- (BOOL)oe_isReady {
  return _ready && _state == OEBrowserContextStateLive && !_oe_closing;
}

- (void)oe_whenReady:(dispatch_block_t)block {
  if (_ready || _state == OEBrowserContextStateClosed || _oe_closing) {
    block();
  } else {
    [_whenReady addObject:[block copy]];
  }
}

- (void)oe_contextInitialized {
  if (_state == OEBrowserContextStateClosed) return;
  if (!_context || !CefIsOpenProfileContextLive(_context)) {
    [self oe_invalidate];
    return;
  }
  _ready = YES;
  CefSetOpenProfileHandler(_context, new OEProfileLifetimeHandler(self));
  // Notification clicks reach the delegate (page-platform EP-6).
  // Read the App-supplied configuration, not raw process arguments. Normal
  // Release Open never installs these switches in its configuration.
  NSArray<NSString*>* switches = OEEngine.shared.configuration.additionalSwitches;
  const BOOL automation = [switches containsObject:@"--open-automation"];
  if (automation && [switches containsObject:@"--open-automation-skip-macos-notifications"]) {
    // The notification observer constructs Chromium's display service, whose
    // macOS dispatcher force-starts the Alerts helper even without delivery.
    fprintf(stderr, "OpenEngine: automation macOS notification setup skipped\n");
  } else {
    if (automation) fprintf(stderr, "OpenEngine: automation macOS notification setup reached\n");
    CefSetOpenNotificationHandler(_context, new OENotificationHandler(self));
  }
  NSArray<dispatch_block_t>* blocks = [_whenReady copy];
  [_whenReady removeAllObjects];
  for (dispatch_block_t b in blocks) {
    b();
  }
}

- (void)oe_invalidate {
  if (_state == OEBrowserContextStateClosed && !_context) return;
  // Close profile-store observers before invalidating the native context.
  [self oe_closeAutofill];
  _state = OEBrowserContextStateClosed;
  _ready = NO;
  _oe_closing = YES;
  if (_context) CefSetOpenProfileHandler(_context, nullptr);
  [_extensions oe_contextClosed];
  for (OEDownload* download in _downloads.allValues) [download oe_invalidate];
  [_downloads removeAllObjects];
  if (_handler) _handler->SetFilter(nil);
  _requestFilter = nil;
  _context = nullptr;
  _handler = nullptr;
  NSArray<dispatch_block_t>* waiting = [_whenReady copy];
  [_whenReady removeAllObjects];
  for (dispatch_block_t block in waiting) block();
  [OEEngine.shared oe_contextClosed:self];
}

- (void)oe_nativeContextClosed {
  // Mark inert inside native observation, but release CEF only after the
  // observer stack unwinds. Shutdown also calls oe_invalidate synchronously,
  // so a queued block can retain only an inert ObjC wrapper after unload.
  _state = OEBrowserContextStateClosed;
  _ready = NO;
  _oe_closing = YES;
  if (_handler) _handler->SetFilter(nil);
  dispatch_async(dispatch_get_main_queue(), ^{ [self oe_invalidate]; });
  [OEEngine.shared oe_contextClosed:self];
}

#pragma mark Notifications

- (void)oe_notificationClicked:(NSString*)identifier
                        origin:(NSString*)origin
                    persistent:(BOOL)persistent {
  id<OEBrowserContextDelegate> delegate = self.delegate;
  NSURL* url = [NSURL URLWithString:origin];
  if (url && [delegate respondsToSelector:@selector
                       (browserContext:didClickNotificationWithIdentifier:
                                origin:persistent:)]) {
    [delegate browserContext:self
        didClickNotificationWithIdentifier:identifier
                                    origin:url
                                persistent:persistent];
  }
}

- (void)displayedNotificationsWithCompletion:
    (void (^)(NSArray<NSDictionary<NSString*, NSString*>*>*))completion {
  void (^done)(NSArray<NSDictionary<NSString*, NSString*>*>*) = [completion copy];
  [self oe_whenReady:^{
    if (!self.oe_isReady) { done(@[]); return; }
    CefGetDisplayedNotifications(self->_context,
                                 new OENotificationListCallback(done));
  }];
}

- (BOOL)simulateClickOnNotificationWithIdentifier:(NSString*)identifier {
  return _ready && CefSimulateNotificationClick(_context, OECef(identifier));
}

#pragma mark User scripts

static CefRefPtr<CefListValue> OEUserScriptsValue(NSArray<OEUserScript*>* scripts) {
  CefRefPtr<CefListValue> list = CefListValue::Create();
  size_t i = 0;
  for (OEUserScript* s in scripts) {
    CefRefPtr<CefDictionaryValue> d = CefDictionaryValue::Create();
    d->SetString("identifier", OECef(s.identifier));
    d->SetString("source", OECef(s.source));
    d->SetBool("openWorld", s.world == OEScriptWorldOpen);
    d->SetBool("css", s.kind == OEUserScriptKindStyleSheet);
    d->SetBool("end", s.injectionTime == OEUserScriptInjectionTimeDocumentEnd);
    d->SetBool("mainFrameOnly", s.mainFrameOnly);
    CefRefPtr<CefListValue> pats = CefListValue::Create();
    size_t j = 0;
    for (NSString* p in s.matchPatterns) {
      pats->SetString(j++, OECef(p));
    }
    d->SetList("matches", pats);
    list->SetDictionary(i++, d);
  }
  return list;
}



- (NSArray<OEUserScript*>*)userScripts {
  return [[NSArray alloc] initWithArray:_scripts copyItems:YES];
}

- (void)addUserScript:(OEUserScript*)script {
  if (_state == OEBrowserContextStateClosed || _oe_closing) return;
  [self replaceUserScriptsWithIdentifiers:@[script.identifier] scripts:@[script]];
}

- (void)replaceUserScriptsWithIdentifiers:(NSArray<NSString*>*)identifiers
                                 scripts:(NSArray<OEUserScript*>*)scripts {
  if (_state == OEBrowserContextStateClosed || _oe_closing) return;
  NSMutableSet<NSString*>* replaced = [NSMutableSet setWithArray:identifiers];
  for (OEUserScript* script in scripts) [replaced addObject:script.identifier];
  NSIndexSet* old = [_scripts indexesOfObjectsPassingTest:
      ^BOOL(OEUserScript* script, NSUInteger index, BOOL* stop) {
        return [replaced containsObject:script.identifier];
      }];
  [_scripts removeObjectsAtIndexes:old];
  for (OEUserScript* script in scripts) {
    // Match repeated addUserScript calls when a batch contains duplicate IDs.
    [self removeUserScriptWithIdentifier:script.identifier broadcast:NO];
    [_scripts addObject:[script copy]];
  }
  [self oe_broadcastScriptsRemoving:replaced.allObjects adding:scripts];
}

- (void)removeUserScriptWithIdentifier:(NSString*)identifier {
  [self replaceUserScriptsWithIdentifiers:@[identifier] scripts:@[]];
}

- (void)removeUserScriptWithIdentifier:(NSString*)identifier
                             broadcast:(BOOL)broadcast {
  NSIndexSet* idx = [_scripts
      indexesOfObjectsPassingTest:^BOOL(OEUserScript* s, NSUInteger i,
                                        BOOL* stop) {
        return [s.identifier isEqualToString:identifier];
      }];
  [_scripts removeObjectsAtIndexes:idx];
  if (broadcast) {
    [self oe_broadcastScripts];
  }
}

- (void)removeAllUserScripts {
  [_scripts removeAllObjects];
  [self oe_broadcastScripts];
}

- (CefRefPtr<CefListValue>)oe_scriptsValue {
  return OEUserScriptsValue(_scripts);
}

// Update the stored snapshot before notifying current renderers. Replacement
// renderers receive it before document start; OnRenderViewReady also resends it.
- (void)oe_broadcastScripts {
  [self oe_broadcastScriptsRemoving:nil adding:nil];
}

- (void)oe_broadcastScriptsRemoving:(NSArray<NSString*>*)removed
                            adding:(NSArray<OEUserScript*>*)added {
  if (_state == OEBrowserContextStateClosed || _oe_closing) return;
  // Serialize the Profile snapshot once. Each browser still gets its own
  // stored extra-info copy (including its per-page styles) and renderer message.
  // Rebuilding the full list twice per browser made ten-page Boost edits slow.
  // Stay lazy while preparing a context before its first browser exists.
  CefRefPtr<CefListValue> scripts;
  CefRefPtr<CefListValue> removals;
  CefRefPtr<CefListValue> additions;
  // OTR web contents have their own context. Match that exact owner, so updates
  // cover its browsers without installing a parent profile's scripts there.
  for (OEWebContent* webContent in OEEngine.shared.allWebContents) {
    if (webContent.context != self || !webContent.oe_browser) {
      continue;
    }
    if (!scripts) {
      scripts = [self oe_scriptsValue];
      if (removed) {
        removals = CefListValue::Create();
        size_t index = 0;
        for (NSString* identifier in removed) removals->SetString(index++, OECef(identifier));
        additions = OEUserScriptsValue(added);
      }
    }
    CefSetBrowserExtraInfo(webContent.oe_browser,
                           [webContent oe_extraInfoWithScripts:scripts]);
    // Current renderers retain unrelated scripts. Sending the entire ad-block
    // list for a one-Boost edit made renderer parsing dominate live refresh.
    CefRefPtr<CefProcessMessage> msg =
        CefProcessMessage::Create(removed ? kOEMsgScriptsPatch : kOEMsgScriptsUpdate);
    if (removed) {
      msg->GetArgumentList()->SetList(0, removals->Copy());
      msg->GetArgumentList()->SetList(1, additions->Copy());
    } else {
      msg->GetArgumentList()->SetList(0, scripts->Copy());
    }
    webContent.oe_browser->GetMainFrame()->SendProcessMessage(PID_RENDERER,
                                                              msg);
  }
}

#pragma mark Network filter

- (OERequestFilter)requestFilter {
  @synchronized(self) {
    return _requestFilter;
  }
}

- (void)setRequestFilter:(OERequestFilter)requestFilter {
  if (_state == OEBrowserContextStateClosed || _oe_closing) return;
  @synchronized(self) {
    _requestFilter = [requestFilter copy];
  }
  _handler->SetFilter(requestFilter);
}

#pragma mark Permissions

- (OEPermissionState)permissionStateForKind:(OEPermissionKind)kind
                                     origin:(NSURL*)origin {
  cef_content_setting_types_t type = OEContentSettingType(kind);
  if (!_context || _oe_closing || type == CEF_CONTENT_SETTING_TYPE_NUM_VALUES) {
    return OEPermissionStateAsk;
  }
  CefString url = OECef(origin.absoluteString);
  switch (_context->GetContentSetting(url, url, type)) {
    case CEF_CONTENT_SETTING_VALUE_ALLOW:
      return OEPermissionStateAllow;
    case CEF_CONTENT_SETTING_VALUE_BLOCK:
      return OEPermissionStateBlock;
    default:
      return OEPermissionStateAsk;
  }
}

- (void)setPermissionState:(OEPermissionState)state
                   forKind:(OEPermissionKind)kind
                    origin:(NSURL*)origin {
  cef_content_setting_types_t type = OEContentSettingType(kind);
  if (!_context || _oe_closing || type == CEF_CONTENT_SETTING_TYPE_NUM_VALUES) {
    return;
  }
  cef_content_setting_values_t value =
      state == OEPermissionStateAllow   ? CEF_CONTENT_SETTING_VALUE_ALLOW
      : state == OEPermissionStateBlock ? CEF_CONTENT_SETTING_VALUE_BLOCK
                                        : CEF_CONTENT_SETTING_VALUE_DEFAULT;
  CefString url = OECef(origin.absoluteString);
  _context->SetContentSetting(url, url, type, value);
}

#pragma mark Protocol handlers (fork API cef_open_page.h)

- (NSArray<OEProtocolHandler*>*)protocolHandlers {
  if (!_context || _oe_closing) return @[];
  CefRefPtr<CefListValue> items = CefGetProtocolHandlers(_context);
  NSMutableArray<OEProtocolHandler*>* handlers = [NSMutableArray array];
  for (size_t i = 0; items && i < items->GetSize(); ++i) {
    CefRefPtr<CefDictionaryValue> item = items->GetDictionary(i);
    if (!item) continue;
    [handlers addObject:[[OEProtocolHandler alloc]
                            initOEWithScheme:OEString(item->GetString("scheme"))
                                 urlTemplate:OEString(item->GetString("url"))
                                   isDefault:item->GetBool("default")]];
  }
  return handlers;
}

- (NSURL*)protocolHandlerURLForURL:(NSURL*)url {
  if (!_context || _oe_closing || !url) return nil;
  CefString translated =
      CefTranslateProtocolHandlerURL(_context, OECef(url.absoluteString));
  return translated.empty() ? nil : OEURL(translated);
}

- (BOOL)removeProtocolHandler:(OEProtocolHandler*)handler {
  if (!_context || _oe_closing || !handler) return NO;
  return CefRemoveProtocolHandler(_context, OECef(handler.scheme),
                                  OECef(handler.urlTemplate));
}

#pragma mark Appearance

- (void)setWebsiteColorScheme:(OEColorSchemePreference)scheme {
  if (!_context || _oe_closing) return;
  // Chrome keeps the last value in the profile's prefs, so the first set
  // always reaches Chromium, even when it equals the initial Automatic.
  if (_colorSchemeApplied && scheme == _websiteColorScheme) {
    return;
  }
  _colorSchemeApplied = YES;
  _websiteColorScheme = scheme;
  cef_color_variant_t variant = CEF_COLOR_VARIANT_SYSTEM;
  switch (scheme) {
    case OEColorSchemePreferenceLight:
      variant = CEF_COLOR_VARIANT_LIGHT;
      break;
    case OEColorSchemePreferenceDark:
      variant = CEF_COLOR_VARIANT_DARK;
      break;
    case OEColorSchemePreferenceAutomatic:
      break;
  }
  // Waits for the profile inside CEF (GetBrowserContext), so this is safe
  // before the context is initialized. A transparent user color keeps
  // Chrome's default palette (the browser's own UI and WebUI).
  _context->SetChromeColorScheme(variant, 0);
  // EP-9b (fork patch 0505): web pages of this context see the scheme in
  // prefers-color-scheme and their root scrollbar, also after navigation;
  // hosted tabs do not follow SetChromeColorScheme (check A1). Automatic
  // removes the override. Applies when the context finishes initializing.
  CefSetWebsiteColorScheme(_context, variant);
}

- (void)clearBrowsingDataForOrigin:(NSURL*)origin
                        completion:(void (^)(void))completion {
  if (!_context || _oe_closing) { if (completion) completion(); return; }
  CefRefPtr<CefCookieManager> cookies = _context->GetCookieManager(nullptr);
  CefString url = origin ? OECef(origin.absoluteString) : CefString();
  void (^done)(void) = [completion copy];
  if (!cookies ||
      !cookies->DeleteCookies(url, CefString(),
                              new DeleteCookiesCallback(^{
                                if (!origin && self->_context && !self->_oe_closing) {
                                  self->_context->ClearHttpCache(nullptr);
                                }
                                if (done) {
                                  done();
                                }
                              }))) {
    if (done) {
      done();
    }
  }
}

- (void)clearBrowsingData:(OEBrowsingDataKinds)kinds
                     from:(NSDate*)begin
                       to:(NSDate*)end
               completion:(void (^)(NSError*))completion {
  [self oe_whenReady:^{
    CefRefPtr<OEBrowsingDataCallback> callback = new OEBrowsingDataCallback(completion);
    if (!self.oe_isReady ||
        !CefClearOpenProfileBrowsingData(self->_context, static_cast<int>(kinds),
             begin.timeIntervalSince1970, end.timeIntervalSince1970,
             callback))
      callback->OnComplete("profile-unavailable-or-invalid-data-range");
  }];
}

#pragma mark Downloads

- (NSArray<OEDownload*>*)downloads {
  return _downloads.allValues;
}

- (void)oe_handleBeforeDownload:(CefRefPtr<CefDownloadItem>)item
                  suggestedName:(NSString*)name
                     webContent:(OEWebContent*)webContent
                       callback:(CefRefPtr<CefBeforeDownloadCallback>)callback {
  if (_state == OEBrowserContextStateClosed || _oe_closing) return;
  // Updated callbacks can arrive before the destination request. Reuse the
  // tracked wrapper so a shell-retained earlier object cannot keep CEF alive.
  OEDownload* download = _downloads[@(item->GetId())];
  if (!download) {
    download = [[OEDownload alloc] initOEWithItem:item webContent:webContent];
    _downloads[@(download.identifier)] = download;
  }
  [download oe_setDestinationCallback:callback];
  void (^decide)(NSURL*) = ^(NSURL* destination) {
    [download oe_decideDestination:
        self.state == OEBrowserContextStateLive && !self.oe_closing ? destination : nil];
    // Not calling Continue cancels the download.
  };
  id<OEBrowserContextDelegate> delegate = _delegate;
  if ([delegate respondsToSelector:@selector
                (browserContext:decideDestinationForDownload:suggestedFilename:completion:)]) {
    [delegate browserContext:self
        decideDestinationForDownload:download
                   suggestedFilename:name
                          completion:decide];
  } else {
    NSURL* dir = [NSFileManager.defaultManager
        URLsForDirectory:NSDownloadsDirectory
               inDomains:NSUserDomainMask]
                     .firstObject;
    decide([dir URLByAppendingPathComponent:name.length ? name : @"download"]);
  }
}

- (void)oe_handleDownloadUpdated:(CefRefPtr<CefDownloadItem>)item
                      webContent:(OEWebContent*)webContent
                        callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  if (_state == OEBrowserContextStateClosed || _oe_closing) {
    if (callback && item->IsInProgress()) callback->Cancel();
    return;
  }
  OEDownload* download = _downloads[@(item->GetId())];
  if (!download) {
    // Progress can precede OnBeforeDownload. Preserve this callback's source
    // before the destination request reuses the same download wrapper.
    download = [[OEDownload alloc] initOEWithItem:item webContent:webContent];
    _downloads[@(download.identifier)] = download;
  }
  [download oe_updateWithItem:item callback:callback];
  if ([_delegate respondsToSelector:@selector(browserContext:downloadDidUpdate:)]) {
    [_delegate browserContext:self downloadDidUpdate:download];
  }
}

@end

@implementation OEProtocolHandler

- (instancetype)initOEWithScheme:(NSString*)scheme
                      urlTemplate:(NSString*)urlTemplate
                        isDefault:(BOOL)isDefault {
  if ((self = [super init])) {
    _scheme = [scheme copy];
    _urlTemplate = [urlTemplate copy];
    _defaultHandler = isDefault;
  }
  return self;
}

@end
