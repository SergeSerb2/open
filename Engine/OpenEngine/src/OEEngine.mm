#import "OEInternal.h"

#include <crt_externs.h>

#include <set>
#include <mach/mach_time.h>
#include <os/signpost.h>

// Opt-in startup boundaries only; no work is scheduled and no idle logs exist.
static void OESpeedPhase(const char* phase) {
  static const bool enabled = [] { const char* value = getenv("OPEN_SPEED_TRACE"); return value && !strcmp(value, "1"); }();
  if (!enabled) return;
  static os_log_t log = os_log_create("io.github.sergeserb2.open", "SpeedTrace");
  uint64_t ticks = mach_continuous_time();
  os_signpost_event_emit(log, OS_SIGNPOST_ID_EXCLUSIVE, "EnginePhase", "%{public}s", phase);
  fprintf(stderr, "OpenSpeed engine %s %llu\n", phase, (unsigned long long)ticks);
}

#include "include/cef_application_mac.h"
#include "include/cef_id_mappers.h"
#include "include/cef_task_manager.h"
#include "include/cef_trace.h"
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
  c.handlesHTTPAuthentication = _handlesHTTPAuthentication;
  c.keychainServiceName = _keychainServiceName;
  c.keychainAccountName = _keychainAccountName;
  c.useMockKeychain = _useMockKeychain;
  return c;
}

@end

#pragma mark - OEApplication

static __weak NSWindow* navigationMouseWindow;
static NSEventModifierFlags navigationMouseModifiers;
void OENoteNavigationInput(NSWindow* window, NSEventModifierFlags modifiers) {
  navigationMouseWindow = window;
  navigationMouseModifiers = modifiers;
}
NSEventModifierFlags OENavigationModifiersForWindow(NSWindow* window) {
  return window && window == navigationMouseWindow ? navigationMouseModifiers : 0;
}

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
  if (event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp) {
    OENoteNavigationInput(event.window, event.modifierFlags);
  } else if (event.type == NSEventTypeKeyDown) {
    OENoteNavigationInput(nil, 0);
  }
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
    if (!context) {
      CefRefPtr<CefBrowser> doomed = browser;
      dispatch_async(dispatch_get_main_queue(), ^{ doomed->GetHost()->CloseBrowser(true); });
      return true;
    }
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

  void CloseForContext(CefRefPtr<CefRequestContext> context) {
    if (!context) return;
    auto copy = browsers_;
    for (auto& browser : copy) {
      if (browser->GetHost()->GetRequestContext()->IsSharingWith(context))
        browser->GetHost()->CloseBrowser(true);
    }
  }

  bool HasBrowsersForContext(CefRefPtr<CefRequestContext> context) const {
    if (!context) return false;
    for (const auto& browser : browsers_) {
      if (browser->GetHost()->GetRequestContext()->IsSharingWith(context)) {
        return true;
      }
    }
    return false;
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

// Calls `done` with the path CEF wrote (main thread).
class OEEndTracingCallback : public CefEndTracingCallback {
 public:
  explicit OEEndTracingCallback(void (^done)(NSString*)) : done_([done copy]) {}
  ~OEEndTracingCallback() override {
    // Released unrun (tracing stopped at shutdown): answer once with no file,
    // so the completion runs and isTracing does not stay YES.
    if (void (^done)(NSString*) = done_) {
      dispatch_async(dispatch_get_main_queue(), ^{
        done(@"");
      });
    }
  }
  void OnEndTracingComplete(const CefString& tracing_file) override {
    void (^done)(NSString*) = done_;
    done_ = nil;
    if (done) {
      done(OEString(tracing_file));
    }
  }

 private:
  void (^done_)(NSString*);
  IMPLEMENT_REFCOUNTING(OEEndTracingCallback);
};

}  // namespace

class OEProfileDeletionHandler : public CefOpenProfileDeletionHandler {
 public:
  OEProfileDeletionHandler(dispatch_block_t ready, void (^done)(NSError*))
      : ready_([ready copy]), done_([done copy]) {}
  ~OEProfileDeletionHandler() override {
    if (auto done = done_) {
      dispatch_async(dispatch_get_main_queue(), ^{
        done([NSError errorWithDomain:OEErrorDomain code:OEErrorProfileDeletionFailed
            userInfo:@{NSLocalizedDescriptionKey: @"profile-deletion-interrupted"}]);
      });
    }
  }
  void OnReadyToRelease() override { auto ready = ready_; ready_ = nil; if (ready) ready(); }
  void OnComplete(const CefString& error) override {
    auto done = done_; done_ = nil; ready_ = nil;
    if (done) done(error.empty() ? nil : [NSError errorWithDomain:OEErrorDomain
        code:OEErrorProfileDeletionFailed userInfo:@{NSLocalizedDescriptionKey: OEString(error)}]);
  }
 private:
  dispatch_block_t ready_;
  void (^done_)(NSError*);
  IMPLEMENT_REFCOUNTING(OEProfileDeletionHandler);
};

#pragma mark - OEEngine

@implementation OEEngine {
  CefScopedLibraryLoader* _loader;
  OEEngineConfiguration* _configuration;
  NSPointerArray* _webContents;  // weak, creation order
  NSPointerArray* _browsers;     // weak, creation order
  NSMutableDictionary<NSString*, OEBrowserContext*>* _contexts;
  NSPointerArray* _allContexts;  // weak, includes retired and private wrappers
  NSMutableDictionary<NSString*, OEBrowserContext*>* _privateContexts;
  NSMutableSet<NSString*>* _closingDirectories;
  NSMutableDictionary<NSString*, NSMutableArray*>* _deletionCompletions;
  OEBrowserContext* _defaultContext;
  CefRefPtr<OEDefaultClient> _defaultClient;
  BOOL _terminating;
  BOOL _quitAtDeadline;
  BOOL _quitDeadlineFired;
  NSUInteger _ephemeralCount;
  NSURL* _defaultContextDirectory;  // resolved
  NSMutableDictionary<NSUUID*, dispatch_block_t>* _pendingReleases;
  BOOL _tracing;        // CefBeginTracing succeeded; no end requested yet
  BOOL _tracingEnding;  // CefEndTracing runs; its callback is pending
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
    _allContexts = [NSPointerArray weakObjectsPointerArray];
    _privateContexts = [NSMutableDictionary dictionary];
    _closingDirectories = [NSMutableSet set];
    _deletionCompletions = [NSMutableDictionary dictionary];
  }
  return self;
}

- (OEEngineConfiguration*)configuration {
  return [_configuration copy];
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
  // Validate before loading CEF or allowing os_crypt to access any item.
  if (!configuration.keychainServiceName.length ||
      [configuration.keychainServiceName isEqualToString:@"Chromium Safe Storage"]) {
    if (error) *error = [NSError errorWithDomain:OEErrorDomain
        code:OEErrorInitializationFailed userInfo:@{
          NSLocalizedDescriptionKey: @"Open requires its own Keychain service name"
        }];
    return NO;
  }
  _configuration = [configuration copy];

  _loader = new CefScopedLibraryLoader();
  OESpeedPhase("frameworkLoadBegin");
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

  OESpeedPhase("frameworkLoaded");
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
  if (_configuration.handlesHTTPAuthentication) {
    switches = [switches arrayByAddingObject:@"--disable-chrome-login-prompt"];
  }
  if (_configuration.useMockKeychain &&
      ![switches containsObject:@"--use-mock-keychain"]) {
    switches = [switches arrayByAddingObject:@"--use-mock-keychain"];
  }
  CefRefPtr<CefApp> app = OECreateApp(switches);
  OESpeedPhase("cefInitializeBegin");
  if (!CefInitialize(args, settings, app, nullptr)) {
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
  OESpeedPhase("cefInitializeEnd");
  _running = YES;
  OEInstallAutofillHandler();
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
  // Automation can exercise the existing deadline with cooperative renderers,
  // without hanging or crashing a helper process.
  NSArray<NSString*>* switches = _configuration.additionalSwitches;
  _quitAtDeadline = [switches containsObject:@"--open-automation"] &&
      [NSProcessInfo.processInfo.environment[@"OPEN_AUTOMATION_QUIT_AT_DEADLINE"] isEqualToString:@"1"];
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
                   self->_quitDeadlineFired = YES;
                   [self oe_quit];
                 });
}

- (BOOL)oe_isTerminating {
  return _terminating;
}

- (void)oe_quitIfDone {
  if (_quitAtDeadline) return;
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
    NSArray<dispatch_block_t>* checks = [_pendingReleases.allValues copy];
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
  OERemoveAutofillHandler();
  // Also cover retained retired wrappers and private sessions, on both normal
  // quit and the three-second renderer timeout path.
  for (OEBrowser* browser in self.browsers) [browser close];
  NSArray<OEBrowserContext*>* retained = [self oe_allContexts];
  for (OEBrowserContext* context in retained) [context oe_invalidate];
  if ([_configuration.additionalSwitches containsObject:@"--open-automation"]) {
    NSUInteger closed = 0;
    for (OEBrowserContext* context in retained)
      if (context.state == OEBrowserContextStateClosed && !context.oe_requestContext) closed++;
    fprintf(stderr, "OpenEngine: shutdown contexts=%lu inert=%lu deadline=%d deadlineSeconds=3\n",
            (unsigned long)retained.count, (unsigned long)closed, _quitDeadlineFired);
  }
  [_privateContexts removeAllObjects];
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
  if (!_running || _terminating) return _defaultContext;
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
  if (!_running || _terminating) return nil;
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
  if ([_closingDirectories containsObject:path]) return nil;
  if ([identifier isEqualToString:@"Default"] ||
      [path isEqualToString:_defaultContextDirectory.path]) {
    return self.defaultContext;
  }
  OEBrowserContext* context = _contexts[identifier];
  if (context && (context.state == OEBrowserContextStateClosed || context.oe_closing)) return nil;
  for (OEBrowserContext* existing in _contexts.allValues) {
    if ([existing.directory.path isEqualToString:path]) return existing;
  }
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
  if (context.ephemeral) context.oe_closing = YES;
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
  if (_defaultClient) _defaultClient->CloseForContext(context.oe_requestContext);
  // Done when no live web content uses the context any more; re-checked
  // after every browser close (-oe_browserDidClose).
  __weak OEBrowserContext* weakContext = context;
  void (^done)(void) = [completion copy];
  __block BOOL finished = NO;
  NSUUID* token = NSUUID.UUID;
  dispatch_block_t check = ^{
    if (finished) {
      return;
    }
    for (OEWebContent* w in OEEngine.shared.allWebContents) {
      if (w.context == weakContext && w.live) {
        return;
      }
    }
    if (self->_defaultClient &&
        self->_defaultClient->HasBrowsersForContext(weakContext.oe_requestContext)) {
      return;
    }
    finished = YES;
    [self->_pendingReleases removeObjectForKey:token];
    if (weakContext.ephemeral) [weakContext oe_invalidate];
    if (done) done();
  };
  if (!_pendingReleases) {
    _pendingReleases = [NSMutableDictionary dictionary];
  }
  _pendingReleases[token] = [check copy];
  check();
}

- (void)makeIncognitoContextForContext:(OEBrowserContext*)original
                          completion:(void (^)(OEBrowserContext*, NSError*))completion {
  void (^fail)(void) = ^{
    completion(nil, [NSError errorWithDomain:OEErrorDomain code:OEErrorContextClosed
        userInfo:@{NSLocalizedDescriptionKey: @"The parent profile is unavailable or incognito is disabled."}]);
  };
  if (!_running || _terminating || !original || original.ephemeral ||
      original.state == OEBrowserContextStateClosed || original.oe_closing ||
      ![[self oe_allContexts] containsObject:original]) { fail(); return; }
  [original oe_whenReady:^{
    if (!original.oe_isReady || self->_terminating) { fail(); return; }
    OEBrowserContext* context = self->_privateContexts[original.identifier];
    if (context.state == OEBrowserContextStateClosed) context = nil;
    if (!context) {
      NSString* identifier = [NSString stringWithFormat:@"Private-%lu", (unsigned long)++self->_ephemeralCount];
      context = [[OEBrowserContext alloc] initOEIncognitoWithIdentifier:identifier original:original];
      if (!context) { fail(); return; }
      self->_privateContexts[original.identifier] = context;
    }
    [context oe_whenReady:^{
      if (context.oe_isReady && original.oe_isReady) completion(context, nil);
      else fail();
    }];
  }];
}

- (void)deleteContext:(OEBrowserContext*)context completion:(void (^)(NSError*))completion {
  NSMutableArray* callbacks = context ? _deletionCompletions[context.identifier] : nil;
  if (callbacks) { [callbacks addObject:[completion copy]]; return; }
  if (!_running || _terminating || !context || context == _defaultContext ||
      context.ephemeral || context.state == OEBrowserContextStateClosed || context.oe_closing ||
      ![[self oe_allContexts] containsObject:context]) {
    completion([NSError errorWithDomain:OEErrorDomain code:OEErrorProfileDeletionFailed
        userInfo:@{NSLocalizedDescriptionKey: @"profile-deletion-refused"}]);
    return;
  }
  _deletionCompletions[context.identifier] = [NSMutableArray arrayWithObject:[completion copy]];
  void (^done)(NSError*) = ^(NSError* error) {
    NSArray* waiting = [self->_deletionCompletions[context.identifier] copy];
    [self->_deletionCompletions removeObjectForKey:context.identifier];
    for (void (^callback)(NSError*) in waiting) callback(error);
  };
  // Wait for native initialization before marking the wrapper closing. Other
  // work is blocked by the directory exclusion as soon as delete is requested.
  [_closingDirectories addObject:context.directory.path];
  [context oe_whenReady:^{
    if (!context.oe_isReady) {
      // Nothing was closed or deleted: release the folder again, or this
      // Profile could never be opened until relaunch.
      [self->_closingDirectories removeObject:context.directory.path];
      done([NSError errorWithDomain:OEErrorDomain code:OEErrorProfileDeletionFailed
          userInfo:@{NSLocalizedDescriptionKey: @"profile-not-initialized"}]);
      return;
    }
    NSMutableArray<OEBrowserContext*>* doomed = [NSMutableArray arrayWithObject:context];
    for (OEBrowserContext* other in [self oe_allContexts]) {
      if (other.originalContext == context) [doomed addObject:other];
    }
    for (OEBrowserContext* item in doomed) {
      item.oe_closing = YES;
      [item.extensions oe_contextClosed];
      for (OEDownload* download in item.downloads) [download cancel];
    }
    for (OEBrowser* browser in self.browsers) {
      if ([doomed containsObject:browser.context]) [browser close];
    }
    for (OEWebContent* content in self.allWebContents) {
      if ([doomed containsObject:content.context]) [content close];
    }
    // Chromium can restore/create pages handled by the default client before
    // the shell adopts them. They hold the native context too, even though no
    // OEBrowser/OEWebContent wrapper owns them.
    if (self->_defaultClient) {
      for (OEBrowserContext* item in doomed)
        self->_defaultClient->CloseForContext(item.oe_requestContext);
    }
    __block BOOL started = NO;
    NSUUID* token = NSUUID.UUID;
    dispatch_block_t check = ^{
      if (started) return;
      for (OEWebContent* content in self.allWebContents) {
        if ([doomed containsObject:content.context] && content.live) return;
      }
      if (self->_defaultClient) {
        for (OEBrowserContext* item in doomed)
          if (self->_defaultClient->HasBrowsersForContext(item.oe_requestContext)) {
            return;
          }
      }
      started = YES;
      [self->_pendingReleases removeObjectForKey:token];
      for (OEBrowserContext* item in doomed) {
        if (item != context) [item oe_invalidate];
      }
      CefRefPtr<OEProfileDeletionHandler> handler = new OEProfileDeletionHandler(^{
        // Track independently of the ordinary registry so retained aliases and
        // private children are invalidated too.
        for (OEBrowserContext* item in [self oe_allContexts]) {
          if (item == context || item.originalContext == context ||
              [item.directory.path isEqualToString:context.directory.path]) [item oe_invalidate];
        }
        [self->_contexts removeObjectForKey:context.identifier];
      }, done);
      if (!CefDeleteOpenProfile(context.oe_requestContext, handler))
        handler->OnComplete("profile-deletion-refused");
    };
    if (!self->_pendingReleases) self->_pendingReleases = [NSMutableDictionary dictionary];
    self->_pendingReleases[token] = [check copy];
    check();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
      if (!started) {
        started = YES;
        [self->_pendingReleases removeObjectForKey:token];
        done([NSError errorWithDomain:OEErrorDomain code:OEErrorProfileDeletionFailed
            userInfo:@{NSLocalizedDescriptionKey: @"profile-pages-still-live"}]);
      }
    });
  }];
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
    for (OEBrowserContext* context in [self oe_allContexts]) {
      auto native = context.oe_requestContext;
      if (native && context.state == OEBrowserContextStateLive && !context.oe_closing &&
          native->IsSharingWith(requestContext)) {
        return context;
      }
    }
  }
  return nil;
}

- (void)oe_registerContext:(OEBrowserContext*)context {
  [_allContexts addPointer:(__bridge void*)context];
}

- (NSArray<OEBrowserContext*>*)oe_allContexts {
  [_allContexts compact];
  NSMutableArray* contexts = [NSMutableArray array];
  for (OEBrowserContext* context in _allContexts) if (context) [contexts addObject:context];
  return contexts;
}

- (void)oe_contextClosed:(OEBrowserContext*)context {
  if (context.originalContext && _privateContexts[context.originalContext.identifier] == context)
    [_privateContexts removeObjectForKey:context.originalContext.identifier];
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

#pragma mark Task manager

- (BOOL)showTaskManager {
  int command = cef_id_for_command_id_name("IDC_TASK_MANAGER_MAIN_MENU");
  if (command < 0) {
    return NO;
  }
  // Any live Chrome style page's Chrome browser can open the (app-wide)
  // window: a hosted tab's hidden window or a Chrome Views window.
  for (OEWebContent* content in self.allWebContents) {
    CefRefPtr<CefBrowser> browser = content.oe_browser;
    if (!browser || !content.live) {
      continue;
    }
    CefRefPtr<CefBrowserHost> host = browser->GetHost();
    if (host->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME &&
        host->CanExecuteChromeCommand(command)) {
      host->ExecuteChromeCommand(command, CEF_WOD_CURRENT_TAB);
      return YES;
    }
  }
  return NO;
}

#pragma mark Tracing

- (BOOL)isTracing {
  return _tracing || _tracingEnding;
}

- (BOOL)beginTracingWithCategories:(NSString*)categories {
  if (!_running || _tracing || _tracingEnding) {
    return NO;
  }
  CefString list = categories.length ? OECef(categories) : CefString();
  _tracing = CefBeginTracing(list, nullptr);
  return _tracing;
}

- (void)endTracingToFile:(NSURL*)fileURL
              completion:(void (^)(NSURL*, NSError*))completion {
  void (^done)(NSURL*, NSError*) = [completion copy];
  NSError* (^failure)(NSString*) = ^(NSString* message) {
    return [NSError errorWithDomain:OEErrorDomain
                               code:OEErrorUnsupported
                           userInfo:@{NSLocalizedDescriptionKey : message}];
  };
  if (!_tracing || _tracingEnding || !fileURL.isFileURL) {
    done(nil, failure(_tracing ? @"Invalid trace file URL"
                               : @"No trace is being recorded"));
    return;
  }
  __weak OEEngine* weakSelf = self;
  CefRefPtr<OEEndTracingCallback> callback =
      new OEEndTracingCallback(^(NSString* path) {
        OEEngine* engine = weakSelf;
        if (engine) {
          engine->_tracingEnding = NO;
        }
        BOOL written = [NSFileManager.defaultManager fileExistsAtPath:path];
        done(written ? [NSURL fileURLWithPath:path] : nil,
             written ? nil : failure(@"Chromium did not write the trace"));
      });
  if (!CefEndTracing(OECef(fileURL.path), callback)) {
    done(nil, failure(@"Chromium refused to end the trace"));
    return;
  }
  _tracing = NO;
  _tracingEnding = YES;
}

- (void)cancelTracing {
  if (!_tracing || _tracingEnding) {
    return;
  }
  // An empty path makes CEF pick a temporary file; delete it when written.
  __weak OEEngine* weakSelf = self;
  CefRefPtr<OEEndTracingCallback> callback =
      new OEEndTracingCallback(^(NSString* path) {
        OEEngine* engine = weakSelf;
        if (engine) {
          engine->_tracingEnding = NO;
        }
        if (path.length) {
          [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        }
      });
  if (CefEndTracing(CefString(), callback)) {
    _tracing = NO;
    _tracingEnding = YES;
  }
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
