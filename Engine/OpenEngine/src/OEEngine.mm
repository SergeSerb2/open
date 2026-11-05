#import "OEInternal.h"

#include <crt_externs.h>
#include <time.h>

#include <set>

#include "include/cef_application_mac.h"
#include "include/cef_task_manager.h"
#include "include/cef_version.h"
#include "include/wrapper/cef_library_loader.h"

NSErrorDomain const OEErrorDomain = @"app.open.engine";

#pragma mark - OEEngineConfiguration

@implementation OEEngineConfiguration

- (instancetype)init {
  if ((self = [super init])) {
    NSURL* support = [NSFileManager.defaultManager
        URLsForDirectory:NSApplicationSupportDirectory
               inDomains:NSUserDomainMask]
                         .firstObject;
    _userDataDirectory = [support URLByAppendingPathComponent:@"Open"
                                                  isDirectory:YES];
    _additionalSwitches = @[];
    _defaultRuntimeStyle = OERuntimeStyleAlloy;
    _keychainServiceName = @"Open Safe Storage";
    _keychainAccountName = @"Open";
  }
  return self;
}

- (id)copyWithZone:(NSZone*)zone {
  OEEngineConfiguration* c = [[OEEngineConfiguration alloc] init];
  c.userDataDirectory = _userDataDirectory;
  c.userAgentProduct = _userAgentProduct;
  c.locale = _locale;
  c.defaultRuntimeStyle = _defaultRuntimeStyle;
  c.remoteDebuggingPort = _remoteDebuggingPort;
  c.additionalSwitches = _additionalSwitches;
  c.logFile = _logFile;
  c.verboseLogging = _verboseLogging;
  c.keychainServiceName = _keychainServiceName;
  c.keychainAccountName = _keychainAccountName;
  c.useMockKeychain = _useMockKeychain;
  return c;
}

@end

#pragma mark - OEApplication

@interface OEApplication () <CefAppProtocol>
@end

@implementation OEApplication {
  BOOL _handlingSendEvent;
}

@synthesize keyEquivalentHandler = _keyEquivalentHandler;

- (BOOL)isHandlingSendEvent {
  return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
  _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent sendingEventScoper;
  // App shortcuts that must beat the page. AppKit would otherwise send the
  // key-down to Chromium's RenderWidgetHostViewCocoa first, and the page can
  // swallow it.
  if (event.type == NSEventTypeKeyDown && _keyEquivalentHandler &&
      (event.modifierFlags &
       (NSEventModifierFlagCommand | NSEventModifierFlagControl)) &&
      _keyEquivalentHandler(event)) {
    return;
  }
  [super sendEvent:event];
}

// Chromium must close its browsers before the process exits, so -terminate:
// never exits directly: it starts the engine's close sequence, and main()
// returns after the message loop quits.
- (void)terminate:(id)sender {
  id<NSApplicationDelegate> delegate = self.delegate;
  if ([delegate respondsToSelector:@selector(applicationShouldTerminate:)] &&
      [delegate applicationShouldTerminate:self] == NSTerminateCancel) {
    return;
  }
  [[OEEngine shared] terminate];
}

@end

#pragma mark - OEProcessMetrics

@interface OEProcessMetrics ()
- (instancetype)initOEWithInfo:(const CefTaskInfo&)info;
@end

@implementation OEProcessMetrics
- (instancetype)initOEWithInfo:(const CefTaskInfo&)info {
  if ((self = [super init])) {
    _taskIdentifier = info.id;
    _title = OEString(CefString(&info.title));
    _memoryFootprint = info.memory;
    _gpuMemory = info.gpu_memory;
    _cpuUsage = info.cpu_usage;
    switch (info.type) {
      case CEF_TASK_TYPE_BROWSER:
        _kind = OEProcessKindBrowser;
        break;
      case CEF_TASK_TYPE_GPU:
        _kind = OEProcessKindGPU;
        break;
      case CEF_TASK_TYPE_RENDERER:
        _kind = OEProcessKindRenderer;
        break;
      case CEF_TASK_TYPE_EXTENSION:
        _kind = OEProcessKindExtension;
        break;
      case CEF_TASK_TYPE_UTILITY:
        _kind = OEProcessKindUtility;
        break;
      case CEF_TASK_TYPE_SERVICE_WORKER:
        _kind = OEProcessKindServiceWorker;
        break;
      case CEF_TASK_TYPE_UNKNOWN:
        _kind = OEProcessKindUnknown;
        break;
      default:
        _kind = OEProcessKindOther;
        break;
    }
  }
  return self;
}
@end

#pragma mark - Default client (browsers Chromium creates on its own)

namespace {

// Chromium can create browsers that no OEWebContent asked for:
// chrome.tabs.create() from an extension service worker, an extension's
// welcome page after install, chrome.runtime.openOptionsPage(). Stock CEF
// shows them in its own Chrome window. This client catches the first
// navigation, asks the shell for a web content (an Open tab) to load the URL
// instead, and closes the Chrome window. Fork patch P1 replaces this with a
// real tab-strip insertion (the new tab keeps its chrome.tabs identity).
class OEDefaultClient : public CefClient,
                        public CefLifeSpanHandler,
                        public CefRequestHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    browsers_.push_back(browser);
  }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                      CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request,
                      bool user_gesture,
                      bool is_redirect) override {
    if (!frame->IsMain() || redirected_.count(browser->GetIdentifier())) {
      return false;
    }
    NSURL* url = OEURL(request->GetURL());
    if (!url || [url.absoluteString isEqualToString:@"chrome://ignore/"]) {
      return false;
    }
    OEEngine* engine = OEEngine.shared;
    id<OEEngineDelegate> delegate = engine.delegate;
    if (![delegate respondsToSelector:@selector
                   (engineWebContentForUnownedOpenRequest:)]) {
      return false;
    }
    OEBrowserContext* context =
        [engine oe_contextForRequestContext:browser->GetHost()
                                                ->GetRequestContext()];
    OEOpenRequest* open = [[OEOpenRequest alloc]
        initOEWithURL:url
          disposition:OEOpenDispositionNewForegroundTab
          userGesture:user_gesture
       requestedFrame:NSZeroRect
      targetFrameName:@""
               source:nil
              context:context];
    OEWebContent* content =
        [delegate engineWebContentForUnownedOpenRequest:open];
    if (!content) {
      return false;
    }
    redirected_.insert(browser->GetIdentifier());
    [content loadURL:url];
    CefRefPtr<CefBrowser> doomed = browser;
    dispatch_async(dispatch_get_main_queue(), ^{
      doomed->GetHost()->CloseBrowser(true);
    });
    return true;  // Cancel the navigation in Chromium's own window.
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    redirected_.erase(browser->GetIdentifier());
    for (auto it = browsers_.begin(); it != browsers_.end(); ++it) {
      if ((*it)->IsSame(browser)) {
        browsers_.erase(it);
        break;
      }
    }
    [[OEEngine shared] oe_browserDidClose];
  }

  void CloseAll() {
    auto copy = browsers_;
    for (auto& b : copy) {
      b->GetHost()->CloseBrowser(true);
    }
  }

  size_t Count() const { return browsers_.size(); }
  const std::vector<CefRefPtr<CefBrowser>>& Browsers() const {
    return browsers_;
  }

 private:
  std::vector<CefRefPtr<CefBrowser>> browsers_;
  std::set<int> redirected_;
  IMPLEMENT_REFCOUNTING(OEDefaultClient);
};

}  // namespace

#pragma mark - OEEngine

@implementation OEEngine {
  CefScopedLibraryLoader* _loader;
  NSDictionary<NSString*, NSNumber*>* _startupDurations;
  OEEngineConfiguration* _configuration;
  NSPointerArray* _webContents;  // weak, creation order
  NSPointerArray* _browsers;     // weak, creation order
  NSMutableDictionary<NSString*, OEBrowserContext*>* _contexts;
  OEBrowserContext* _defaultContext;
  CefRefPtr<OEDefaultClient> _defaultClient;
  BOOL _terminating;
  NSUInteger _ephemeralCount;
  NSURL* _defaultContextDirectory;  // resolved
  NSMutableArray<dispatch_block_t>* _pendingReleases;
}

+ (OEEngine*)shared {
  static OEEngine* engine;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    engine = [[OEEngine alloc] init];
  });
  return engine;
}

- (instancetype)init {
  if ((self = [super init])) {
    _webContents = [NSPointerArray weakObjectsPointerArray];
    _browsers = [NSPointerArray weakObjectsPointerArray];
    _contexts = [NSMutableDictionary dictionary];
    _startupDurations = @{};
  }
  return self;
}

- (OEEngineConfiguration*)configuration {
  return [_configuration copy];
}

- (NSDictionary<NSString*, NSNumber*>*)startupDurations {
  return _startupDurations;
}

- (NSString*)chromiumVersion {
  return [NSString stringWithFormat:@"%d.%d.%d.%d", CHROME_VERSION_MAJOR,
                                    CHROME_VERSION_MINOR, CHROME_VERSION_BUILD,
                                    CHROME_VERSION_PATCH];
}

- (NSString*)cefVersion {
  return @CEF_VERSION;
}

- (BOOL)startWithConfiguration:(OEEngineConfiguration*)configuration
                         error:(NSError**)error {
  if (_running) {
    if (error) {
      *error = [NSError errorWithDomain:OEErrorDomain
                                   code:OEErrorAlreadyStarted
                               userInfo:nil];
    }
    return NO;
  }
  NSAssert([NSApp isKindOfClass:[OEApplication class]],
           @"NSApp must be an OEApplication (CefAppProtocol)");
  _configuration = [configuration copy];

  const uint64_t loadStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  _loader = new CefScopedLibraryLoader();
  if (!_loader->LoadInMain()) {
    if (error) {
      *error = [NSError
          errorWithDomain:OEErrorDomain
                     code:OEErrorInitializationFailed
                 userInfo:@{
                   NSLocalizedDescriptionKey :
                       @"Could not load Chromium Embedded Framework"
                 }];
    }
    return NO;
  }

  const uint64_t loadEnd = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  [NSFileManager.defaultManager
            createDirectoryAtURL:_configuration.userDataDirectory
      withIntermediateDirectories:YES
                       attributes:nil
                            error:nil];
  // CEF compares cache paths as strings: every profile's cache_path must be
  // inside root_cache_path, so resolve symlinks (/tmp -> /private/tmp) once.
  char resolved[PATH_MAX];
  if (realpath(_configuration.userDataDirectory.fileSystemRepresentation,
               resolved)) {
    _configuration.userDataDirectory =
        [NSURL fileURLWithFileSystemRepresentation:resolved
                                       isDirectory:YES
                                     relativeToURL:nil];
  }
  NSString* root = _configuration.userDataDirectory.path;
  // The global context is the default profile. CEF uses
  // <root_cache_path>/Default for it whatever child path is passed, so say
  // so explicitly.
  NSURL* defaultDir = [_configuration.userDataDirectory
      URLByAppendingPathComponent:@"Default"
                      isDirectory:YES];
  _defaultContextDirectory = defaultDir;

  CefMainArgs args(*_NSGetArgc(), *_NSGetArgv());
  CefSettings settings;
  settings.no_sandbox = false;
  settings.persist_session_cookies = true;
  settings.remote_debugging_port = (int)_configuration.remoteDebuggingPort;
  settings.background_color = CefColorSetARGB(255, 255, 255, 255);
  settings.log_severity =
      _configuration.verboseLogging ? LOGSEVERITY_VERBOSE : LOGSEVERITY_INFO;
  CefString(&settings.root_cache_path) = root.UTF8String;
  CefString(&settings.cache_path) = defaultDir.path.UTF8String;
  NSString* logFile = _configuration.logFile.path
                          ?: [root stringByAppendingPathComponent:@"engine.log"];
  CefString(&settings.log_file) = logFile.UTF8String;
  if (_configuration.locale) {
    CefString(&settings.locale) = _configuration.locale.UTF8String;
  }
  if (_configuration.userAgentProduct) {
    CefString(&settings.user_agent_product) =
        _configuration.userAgentProduct.UTF8String;
  }
  CefString(&settings.keychain_service_name) =
      _configuration.keychainServiceName.UTF8String;
  CefString(&settings.keychain_account_name) =
      _configuration.keychainAccountName.UTF8String;
  // Enables Chrome policy lookup under our bundle id (managed preferences).
  CefString(&settings.chrome_policy_id) =
      NSBundle.mainBundle.bundleIdentifier.UTF8String ?: "io.github.sergeserb2.open";

  NSArray<NSString*>* switches = _configuration.additionalSwitches;
  if (_configuration.useMockKeychain &&
      ![switches containsObject:@"--use-mock-keychain"]) {
    switches = [switches arrayByAddingObject:@"--use-mock-keychain"];
  }
  CefRefPtr<CefApp> app = OECreateApp(switches);
  const uint64_t initializeStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  const bool initialized = CefInitialize(args, settings, app, nullptr);
  const uint64_t initializeEnd = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW);
  _startupDurations = @{
    @"frameworkLoadMs" : @((loadEnd - loadStart) / 1e6),
    @"configurationMs" : @((initializeStart - loadEnd) / 1e6),
    @"cefInitializeMs" : @((initializeEnd - initializeStart) / 1e6),
  };
  if (!initialized) {
    if (error) {
      *error = [NSError
          errorWithDomain:OEErrorDomain
                     code:OEErrorInitializationFailed
                 userInfo:@{
                   NSLocalizedDescriptionKey : [NSString
                       stringWithFormat:@"CefInitialize failed (exit code %d)",
                                        CefGetExitCode()]
                 }];
    }
    return NO;
  }
  _defaultClient = new OEDefaultClient();
  _running = YES;
  return YES;
}

- (void)oe_contextInitialized {
  // With the Chrome bootstrap this runs nested inside CefInitialize(). A
  // browser created there gets an empty first navigation entry, so tell the
  // shell once the message loop is running.
  dispatch_async(dispatch_get_main_queue(), ^{
    self->_initialized = YES;
    if ([self->_delegate respondsToSelector:@selector(engineDidInitialize)]) {
      [self->_delegate engineDidInitialize];
    }
  });
}

- (void)runMessageLoop {
  CefRunMessageLoop();
}

- (void)terminate {
  if (_terminating) {
    return;
  }
  _terminating = YES;
  for (OEBrowser* browser in self.browsers) {
    [browser closeExtensionPopup];
  }
  for (OEWebContent* webContent in self.allWebContents) {
    [webContent close];
  }
  if (_defaultClient) {
    _defaultClient->CloseAll();
  }
  [self oe_quitIfDone];
  // Do not hang the user's quit if a renderer never answers.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC),
                 dispatch_get_main_queue(), ^{
                   [self oe_quit];
                 });
}

- (BOOL)oe_isTerminating {
  return _terminating;
}

- (void)oe_quitIfDone {
  if (!_running || !_defaultClient) {
    return;  // Already shut down (browsers can close during CefShutdown).
  }
  NSUInteger live = 0;
  for (OEWebContent* webContent in self.allWebContents) {
    if (webContent.live) {
      live++;
    }
  }
  if (live == 0 && _defaultClient->Count() == 0) {
    [self oe_quit];
  }
}

- (void)oe_quit {
  static BOOL quit = NO;
  if (quit) {
    return;
  }
  quit = YES;
  if ([_delegate respondsToSelector:@selector(engineWillShutDown)]) {
    [_delegate engineWillShutDown];
  }
  CefQuitMessageLoop();
}

- (void)oe_browserDidClose {
  if (_pendingReleases.count) {
    NSArray<dispatch_block_t>* checks = [_pendingReleases copy];
    dispatch_async(dispatch_get_main_queue(), ^{
      for (dispatch_block_t check in checks) {
        check();
      }
    });
  }
  if (_terminating && _running) {
    dispatch_async(dispatch_get_main_queue(), ^{
      [self oe_quitIfDone];
    });
  }
}

- (void)shutdown {
  if (!_running) {
    return;
  }
  [_contexts removeAllObjects];
  _defaultContext = nil;
  _defaultClient = nullptr;
  CefShutdown();
  _running = NO;
  delete _loader;
  _loader = nullptr;
}

- (CefRefPtr<CefClient>)oe_defaultClient {
  return _defaultClient.get();
}

#pragma mark Browser contexts

- (OEBrowserContext*)defaultContext {
  if (!_defaultContext) {
    _defaultContext =
        [[OEBrowserContext alloc] initOEWithIdentifier:@"Default"
                                              directory:_defaultContextDirectory
                                                 global:YES];
    _contexts[@"Default"] = _defaultContext;
  }
  return _defaultContext;
}

- (OEBrowserContext*)contextWithIdentifier:(NSString*)identifier {
  return [self contextWithIdentifier:identifier
                           directory:[_configuration.userDataDirectory
                                         URLByAppendingPathComponent:identifier
                                                         isDirectory:YES]];
}

- (OEBrowserContext*)contextWithIdentifier:(NSString*)identifier
                                 directory:(NSURL*)directory {
  // CEF loads a disk profile only when cache_path's parent is
  // root_cache_path, compared as strings (ChromeBrowserContext::
  // InitializeAsync); anything else silently becomes an off-the-record
  // profile of the default profile, whose extensions (if allowed in
  // incognito) could see its tabs. Such a folder is refused here.
  // userDataDirectory is already resolved (/tmp -> /private/tmp), so name the
  // child through it.
  char resolved[PATH_MAX];
  if (!realpath(directory.URLByDeletingLastPathComponent.fileSystemRepresentation,
                resolved) ||
      ![@(resolved) isEqualToString:_configuration.userDataDirectory.path]) {
    NSLog(@"OEEngine: refused context %@: %@ is not a direct child of %@",
          identifier, directory.path, _configuration.userDataDirectory.path);
    NSAssert(NO, @"context directory must be a direct child of "
                 @"userDataDirectory");
    return nil;
  }
  directory = [_configuration.userDataDirectory
      URLByAppendingPathComponent:directory.lastPathComponent
                      isDirectory:YES];
  // Already resolved: no URLByStandardizingPath, which drops /private and
  // would no longer match userDataDirectory.
  NSString* path = directory.path;
  if ([identifier isEqualToString:@"Default"] ||
      [path isEqualToString:_defaultContextDirectory.path]) {
    return self.defaultContext;
  }
  OEBrowserContext* context = _contexts[identifier];
  if (!context) {
    context = [[OEBrowserContext alloc] initOEWithIdentifier:identifier
                                                    directory:directory
                                                       global:NO];
    _contexts[identifier] = context;
  }
  return context;
}

- (void)releaseContext:(OEBrowserContext*)context
            completion:(void (^)(void))completion {
  if (context == _defaultContext) {
    if (completion) completion();
    return;
  }
  [_contexts removeObjectForKey:context.identifier];
  for (OEBrowser* browser in self.browsers) {
    if (browser.context == context) {
      [browser close];
    }
  }
  for (OEWebContent* webContent in self.allWebContents) {
    if (webContent.context == context) {
      [webContent close];
    }
  }
  if (!completion) {
    return;
  }
  // Done when no live web content uses the context any more; re-checked
  // after every browser close (-oe_browserDidClose).
  __weak OEBrowserContext* weakContext = context;
  void (^done)(void) = [completion copy];
  __block BOOL finished = NO;
  dispatch_block_t check = ^{
    if (finished) {
      return;
    }
    for (OEWebContent* w in OEEngine.shared.allWebContents) {
      if (w.context == weakContext && w.live) {
        return;
      }
    }
    finished = YES;
    done();
  };
  if (!_pendingReleases) {
    _pendingReleases = [NSMutableArray array];
  }
  [_pendingReleases addObject:[check copy]];
  check();
}

- (OEBrowserContext*)makeEphemeralContext {
  NSString* identifier =
      [NSString stringWithFormat:@"Ephemeral-%lu", (unsigned long)++_ephemeralCount];
  // Not stored in _contexts: it lives as long as the shell keeps it.
  return [[OEBrowserContext alloc] initOEWithIdentifier:identifier
                                              directory:nil
                                                 global:NO];
}

- (NSArray<OEBrowserContext*>*)contexts {
  return [_contexts.allValues
      sortedArrayUsingComparator:^NSComparisonResult(OEBrowserContext* a,
                                                     OEBrowserContext* b) {
        return [a.identifier compare:b.identifier];
      }];
}

- (OEBrowserContext*)oe_contextForRequestContext:
    (CefRefPtr<CefRequestContext>)requestContext {
  if (requestContext) {
    for (OEBrowserContext* context in _contexts.allValues) {
      if (context.oe_requestContext->IsSharingWith(requestContext)) {
        return context;
      }
    }
  }
  return self.defaultContext;
}

- (void)oe_extensionsChangedInContext:(OEBrowserContext*)context {
  for (OEBrowser* browser in self.browsers) {
    if (browser.context == context) {
      [browser oe_extensionsChanged];
    }
  }
}

#pragma mark Live objects

static NSArray* OELiveObjects(NSPointerArray* array) {
  [array compact];
  NSMutableArray* out = [NSMutableArray array];
  for (id object in array) {
    if (object) {
      [out addObject:object];
    }
  }
  return out;
}

- (void)oe_registerBrowser:(OEBrowser*)browser {
  [_browsers addPointer:(__bridge void*)browser];
}

- (NSArray<OEBrowser*>*)browsers {
  return OELiveObjects(_browsers);
}

- (void)oe_registerWebContent:(OEWebContent*)webContent {
  [_webContents addPointer:(__bridge void*)webContent];
}

- (void)oe_unregisterWebContent:(OEWebContent*)webContent {
  for (NSUInteger i = 0; i < _webContents.count; ++i) {
    if ([_webContents pointerAtIndex:i] == (__bridge void*)webContent) {
      [_webContents removePointerAtIndex:i];
      break;
    }
  }
}

- (NSArray<OEWebContent*>*)allWebContents {
  return OELiveObjects(_webContents);
}

- (nullable OEWebContent*)webContentWithIdentifier:(NSInteger)identifier {
  for (OEWebContent* w in self.allWebContents) {
    if (w.identifier == identifier) {
      return w;
    }
  }
  return nil;
}

#pragma mark Metrics

- (void)sampleProcessMetricsAfter:(NSTimeInterval)interval
                       completion:(void (^)(NSArray<OEProcessMetrics*>*))
                                      completion {
  CefRefPtr<CefTaskManager> manager = CefTaskManager::GetTaskManager();
  if (!manager) {
    completion(@[]);
    return;
  }
  // The first call starts sampling; read after the interval for CPU numbers.
  CefTaskManager::TaskIdList warmup;
  manager->GetTaskIdsList(warmup);
  void (^done)(NSArray<OEProcessMetrics*>*) = [completion copy];
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        CefTaskManager::TaskIdList ids;
        NSMutableArray* out = [NSMutableArray array];
        if (manager->GetTaskIdsList(ids)) {
          for (int64_t taskId : ids) {
            CefTaskInfo info;
            if (manager->GetTaskInfo(taskId, info)) {
              [out addObject:[[OEProcessMetrics alloc] initOEWithInfo:info]];
            }
          }
        }
        done(out);
      });
}

@end
