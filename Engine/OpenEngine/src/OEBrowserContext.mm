#import "OEInternal.h"

#include <mutex>

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
  return self;
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
  void OnComplete(int num_deleted) override {
    void (^done)(void) = done_;
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
@end

@implementation OEDownload {
  CefRefPtr<CefDownloadItemCallback> _callback;
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
  if (_callback) _callback->Cancel();
}
- (void)pause {
  if (_callback) _callback->Pause();
}
- (void)resume {
  if (_callback) _callback->Resume();
}

@end

#pragma mark - OEBrowserContext

@implementation OEBrowserContext {
  CefRefPtr<CefRequestContext> _context;
  CefRefPtr<OERequestContextHandler> _handler;
  NSMutableArray<OEUserScript*>* _scripts;
  NSMutableDictionary<NSNumber*, OEDownload*>* _downloads;
  OERequestFilter _requestFilter;
  BOOL _ready;
  NSMutableArray<dispatch_block_t>* _whenReady;
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
        [NSFileManager.defaultManager createDirectoryAtURL:directory
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
        CefString(&settings.cache_path) = directory.path.UTF8String;
        settings.persist_session_cookies = true;
      }
      // An empty cache_path gives an in-memory (incognito) Chrome profile.
      _context = CefRequestContext::CreateContext(settings, _handler.get());
    }
    _extensions = [[OEExtensionManager alloc] initOEWithContext:self];
  }
  return self;
}

- (CefRefPtr<CefRequestContext>)oe_requestContext {
  return _context;
}

- (BOOL)oe_isReady {
  return _ready;
}

- (void)oe_whenReady:(dispatch_block_t)block {
  if (_ready) {
    block();
  } else {
    [_whenReady addObject:[block copy]];
  }
}

- (void)oe_contextInitialized {
  _ready = YES;
  NSArray<dispatch_block_t>* blocks = [_whenReady copy];
  [_whenReady removeAllObjects];
  for (dispatch_block_t b in blocks) {
    b();
  }
}

#pragma mark User scripts

- (NSArray<OEUserScript*>*)userScripts {
  return [_scripts copy];
}

- (void)addUserScript:(OEUserScript*)script {
  [self removeUserScriptWithIdentifier:script.identifier broadcast:NO];
  [_scripts addObject:script];
  [self oe_broadcastScripts];
}

- (void)removeUserScriptWithIdentifier:(NSString*)identifier {
  [self removeUserScriptWithIdentifier:identifier broadcast:YES];
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
  CefRefPtr<CefListValue> list = CefListValue::Create();
  size_t i = 0;
  for (OEUserScript* s in _scripts) {
    CefRefPtr<CefDictionaryValue> d = CefDictionaryValue::Create();
    d->SetString("source", OECef(s.source));
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

// Sends the script list to the current renderer of every web content. New
// renderers get it from extra_info (creation) or OnRenderViewReady.
- (void)oe_broadcastScripts {
  for (OEWebContent* webContent in OEEngine.shared.allWebContents) {
    if (webContent.context != self || !webContent.oe_browser) {
      continue;
    }
    CefRefPtr<CefProcessMessage> msg =
        CefProcessMessage::Create(kOEMsgScriptsUpdate);
    msg->GetArgumentList()->SetList(0, [self oe_scriptsValue]);
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
  @synchronized(self) {
    _requestFilter = [requestFilter copy];
  }
  _handler->SetFilter(requestFilter);
}

#pragma mark Permissions

- (OEPermissionState)permissionStateForKind:(OEPermissionKind)kind
                                     origin:(NSURL*)origin {
  cef_content_setting_types_t type = OEContentSettingType(kind);
  if (type == CEF_CONTENT_SETTING_TYPE_NUM_VALUES) {
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
  if (type == CEF_CONTENT_SETTING_TYPE_NUM_VALUES) {
    return;
  }
  cef_content_setting_values_t value =
      state == OEPermissionStateAllow   ? CEF_CONTENT_SETTING_VALUE_ALLOW
      : state == OEPermissionStateBlock ? CEF_CONTENT_SETTING_VALUE_BLOCK
                                        : CEF_CONTENT_SETTING_VALUE_DEFAULT;
  CefString url = OECef(origin.absoluteString);
  _context->SetContentSetting(url, url, type, value);
}

- (void)clearBrowsingDataForOrigin:(NSURL*)origin
                        completion:(void (^)(void))completion {
  CefRefPtr<CefCookieManager> cookies = _context->GetCookieManager(nullptr);
  CefString url = origin ? OECef(origin.absoluteString) : CefString();
  void (^done)(void) = [completion copy];
  if (!cookies ||
      !cookies->DeleteCookies(url, CefString(),
                              new DeleteCookiesCallback(^{
                                if (!origin) {
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

#pragma mark Downloads

- (NSArray<OEDownload*>*)downloads {
  return _downloads.allValues;
}

- (void)oe_handleBeforeDownload:(CefRefPtr<CefDownloadItem>)item
                  suggestedName:(NSString*)name
                     webContent:(OEWebContent*)webContent
                       callback:(CefRefPtr<CefBeforeDownloadCallback>)callback {
  OEDownload* download = [[OEDownload alloc] initOEWithItem:item
                                                 webContent:webContent];
  _downloads[@(download.identifier)] = download;
  CefRefPtr<CefBeforeDownloadCallback> cb = callback;
  void (^decide)(NSURL*) = ^(NSURL* destination) {
    if (destination) {
      cb->Continue(OECef(destination.path), false);
    }
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
                        callback:(CefRefPtr<CefDownloadItemCallback>)callback {
  OEDownload* download = _downloads[@(item->GetId())];
  if (!download) {
    download = [[OEDownload alloc] initOEWithItem:item webContent:nil];
    _downloads[@(download.identifier)] = download;
  }
  [download oe_updateWithItem:item callback:callback];
  if ([_delegate respondsToSelector:@selector(browserContext:downloadDidUpdate:)]) {
    [_delegate browserContext:self downloadDidUpdate:download];
  }
}

@end
