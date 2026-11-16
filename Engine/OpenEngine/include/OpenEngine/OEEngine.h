#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEBrowser;
@class OEEngine;
@class OEBrowserContext;
@class OEWebContent;
@class OEOpenRequest;
@class OEProcessMetrics;

/// Startup options. Copied by -[OEEngine startWithConfiguration:error:].
OE_EXPORT @interface OEEngineConfiguration : NSObject <NSCopying>

/// Chromium's root_cache_path. Every persistent browser context lives
/// under it. The global context (the default profile) is always
/// <userDataDirectory>/Default: CEF ignores any other child path for it
/// (cef_types.h, CefSettings.cache_path). Other contexts must be direct
/// children: CEF keeps a deeper folder's profile in memory. Default:
/// ~/Library/Application Support/Open.
@property(nonatomic, copy) NSURL* userDataDirectory;

/// Replaces the "Chrome/<version>" product token of the User-Agent. Leave
/// nil: without the Chrome token, sites and extensions (Bitwarden) treat the
/// browser as Safari.
@property(nonatomic, copy, nullable) NSString* userAgentProduct;

/// UI locale such as "en-US". nil uses the system locale.
@property(nonatomic, copy, nullable) NSString* locale;

/// Runtime style for web contents that do not choose one. Default: Alloy.
@property(nonatomic) OERuntimeStyle defaultRuntimeStyle;

/// Opens the DevTools remote debugging port when > 0. Default: 0.
@property(nonatomic) NSInteger remoteDebuggingPort;

/// Extra Chromium switches, for example "--enable-features=Foo" or
/// "--load-extension=/path". Applied in OnBeforeCommandLineProcessing.
/// OpenEngine always adds MediaRouter to --disable-features (Cast is out of
/// v1, plans/page-platform.md EP-12), merged with any list given here.
@property(nonatomic, copy) NSArray<NSString*>* additionalSwitches;

/// Optional log file. Default: <userDataDirectory>/engine.log.
@property(nonatomic, copy, nullable) NSURL* logFile;

/// Verbose Chromium logging. Default: NO.
@property(nonatomic) BOOL verboseLogging;

/// Route HTTP/proxy authentication to OEWebContentDelegate instead of the
/// Chromium login dialog. Default: NO. Enable only when the shell installs
/// its authentication handler; unanswered/unhandled requests then cancel.
@property(nonatomic) BOOL handlesHTTPAuthentication;

/// Keychain item that holds the cookie and password encryption key.
/// Default: "Open Safe Storage" / "Open". Stock Chromium uses the shared
/// "Chromium Safe Storage" item, which other Chromium-based apps may own,
/// and accessing that makes macOS ask the user. Changing these later makes
/// stored cookies and passwords unreadable.
@property(nonatomic, copy) NSString* keychainServiceName;
@property(nonatomic, copy) NSString* keychainAccountName;

/// Use an in-memory mock key instead of the keychain. For ad-hoc signed
/// development builds only: their signature changes on every build, so
/// macOS would ask for keychain access each time. Default: NO.
@property(nonatomic) BOOL useMockKeychain;

@end

/// Engine-level callbacks. All on the main thread.
NS_SWIFT_UI_ACTOR
@protocol OEEngineDelegate <NSObject>
@optional
/// The browser process finished initialization. Create web contents after
/// this (earlier ones wait for it).
- (void)engineDidInitialize;

/// A TYPE_POPUP hidden Browser with its own strip. Host content.view in a
/// native window, set window.window, and retain both objects. Frame is Cocoa
/// screen coordinates; NSZeroRect means no explicit frame. Delivered outside
/// Chromium observers; closing from this callback is safe.
- (void)engine:(OEEngine*)engine didOpenExtensionWindow:(OEBrowser*)window
        content:(OEWebContent*)content requestedFrame:(NSRect)frame
      extension:(NSString*)extensionIdentifier
    NS_SWIFT_NAME(engine(_:didOpenExtensionWindow:content:requestedFrame:extension:));
/// chrome.windows.update bounds/focus request. The frame uses Cocoa coordinates.
- (void)engine:(OEEngine*)engine extensionWindow:(OEBrowser*)window
    requestsFrame:(NSRect)frame focused:(BOOL)focused;

/// Chromium opened a page that no OEWebContent asked for: chrome.tabs.create()
/// from an extension service worker, chrome.runtime.openOptionsPage(), or a
/// notification click. Return a web content to host it (the shell adds it as
/// a tab), or nil to let Chromium show its own window.
- (nullable OEWebContent*)engineWebContentForUnownedOpenRequest:
    (OEOpenRequest*)request
    NS_SWIFT_NAME(engineWebContent(forUnownedOpenRequest:));

/// Every web content is closed and the message loop is about to quit.
- (void)engineWillShutDown;
@end

/// Process-wide engine (ADK "Application"). Lifecycle:
///
///     let app = OEApplication.shared          // first AppKit call
///     try OEEngine.shared.start(configuration: config)
///     OEEngine.shared.runMessageLoop()        // blocks; runs NSApp
///     OEEngine.shared.shutdown()              // after the loop returns
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEEngine : NSObject

@property(class, nonatomic, readonly) OEEngine* shared;

@property(nonatomic, weak, nullable) id<OEEngineDelegate> delegate;
@property(nonatomic, readonly, copy) OEEngineConfiguration* configuration;
@property(nonatomic, readonly, getter=isRunning) BOOL running;
/// YES after -engineDidInitialize.
@property(nonatomic, readonly, getter=isInitialized) BOOL initialized;

/// "156.0.8078.48" and "156.0.14+g4fa4ab5+chromium-156.0.8078.48".
@property(nonatomic, readonly, copy) NSString* chromiumVersion;
@property(nonatomic, readonly, copy) NSString* cefVersion;

/// Initializes Chromium. Call once, on the main thread, after
/// OEApplication.shared exists.
- (BOOL)startWithConfiguration:(OEEngineConfiguration*)configuration
                         error:(NSError**)error
    NS_SWIFT_NAME(start(configuration:));

/// Runs the NSApplication event loop under Chromium's message pump. Returns
/// after -terminate closed every web content.
- (void)runMessageLoop;

/// Closes every web content (beforeunload handlers are skipped), then quits
/// the message loop. -[OEApplication terminate:] calls this.
- (void)terminate;

/// Releases Chromium. Call after -runMessageLoop returns.
- (void)shutdown;

#pragma mark Browser contexts (profiles)

/// The global context (the default profile), stored in
/// <userDataDirectory>/Default.
@property(nonatomic, readonly) OEBrowserContext* defaultContext;

/// The context stored in `directory`, a direct child of userDataDirectory,
/// created on first use and cached by `identifier`. Contexts have separate
/// cookies, storage, cache, extensions, permissions, and history (Arc
/// "Profiles"). The default context's directory returns defaultContext, so
/// two contexts never share one Chromium profile folder. Any other folder is
/// refused (nil): Chromium would silently keep that profile in memory as an
/// off-the-record profile of the default profile.
- (nullable OEBrowserContext*)contextWithIdentifier:(NSString*)identifier
                                          directory:(NSURL*)directory
    NS_SWIFT_NAME(context(identifier:directory:));

/// Same, in <userDataDirectory>/<identifier>. nil in the same cases (also
/// before start, while terminating, or when `identifier` names no direct child).
- (nullable OEBrowserContext*)contextWithIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(context(identifier:));

/// Closes every web content of `context`, forgets the context, and calls
/// `completion` when Chromium has closed them (profile deletion,
/// incognito window close). The default context cannot be released.
- (void)releaseContext:(OEBrowserContext*)context
            completion:(void (^NS_SWIFT_UI_ACTOR _Nullable)(void))completion
    NS_SWIFT_NAME(releaseContext(_:completion:));

/// Shares one primary incognito session per initialized regular parent. The
/// last private Browser closes the session. A later call creates a fresh one.
/// Does not seed cookies. Native installation-wide files may still change.
- (void)makeIncognitoContextForContext:(OEBrowserContext*)original
                          completion:(void (^NS_SWIFT_UI_ACTOR)(
                              OEBrowserContext* _Nullable context,
                              NSError* _Nullable error))completion
    NS_SWIFT_NAME(makeIncognitoContext(for:completion:));

/// Closes this regular profile and its private children, wipes native browsing
/// data, invalidates wrappers, waits for actual native destruction, then commits
/// its Local State removal. Only successful completion permits folder removal.
/// Rejects Default/private contexts. Duplicate calls share one operation.
- (void)deleteContext:(OEBrowserContext*)context
            completion:(void (^NS_SWIFT_UI_ACTOR)(NSError* _Nullable error))completion
    NS_SWIFT_NAME(deleteContext(_:completion:));

@property(nonatomic, readonly, copy) NSArray<OEBrowserContext*>* contexts;

#pragma mark Live objects

/// Every OEBrowser, in creation order.
@property(nonatomic, readonly, copy) NSArray<OEBrowser*>* browsers;

/// Every live web content, in creation order.
@property(nonatomic, readonly, copy) NSArray<OEWebContent*>* allWebContents;

/// The web content whose identifier matches.
- (nullable OEWebContent*)webContentWithIdentifier:(NSInteger)identifier
    NS_SWIFT_NAME(webContent(identifier:));

#pragma mark Diagnostics

/// Samples Chromium's task manager (one entry per process) and calls back
/// after `interval` seconds, so CPU usage has a measurement window.
- (void)sampleProcessMetricsAfter:(NSTimeInterval)interval
                       completion:(void (^NS_SWIFT_UI_ACTOR)(
                                      NSArray<OEProcessMetrics*>* metrics))
                                      completion
    NS_SWIFT_NAME(sampleProcessMetrics(after:completion:));

/// Shows Chromium's task manager window (plans/page-platform.md EP-10a) by
/// running IDC_TASK_MANAGER_MAIN_MENU on a live Chrome style page's browser.
/// A second call brings the open window to the front. Returns NO when no
/// live Chrome style page exists (the command needs a Chrome browser).
- (BOOL)showTaskManager;

#pragma mark Tracing

/// YES from -beginTracingWithCategories: until the trace ends or is
/// cancelled (EP-11).
@property(nonatomic, readonly, getter=isTracing) BOOL tracing;

/// Starts tracing in every process (CefBeginTracing). `categories` is a
/// comma-separated list of category wildcards; nil uses CEF's defaults.
/// Returns NO while a trace runs or ends, or when Chromium refuses. CEF has
/// no privacy filter: a trace can contain page URLs.
- (BOOL)beginTracingWithCategories:(nullable NSString*)categories
    NS_SWIFT_NAME(beginTracing(categories:));

/// Ends the trace and writes Chromium's JSON trace (`traceEvents`) to
/// `fileURL` (CefEndTracing). `completion` gets the written file, or an
/// error when no trace runs or the file could not be written. Runs on the
/// main thread.
- (void)endTracingToFile:(NSURL*)fileURL
              completion:(void (^NS_SWIFT_UI_ACTOR)(NSURL* _Nullable file,
                                                    NSError* _Nullable error))
                             completion
    NS_SWIFT_NAME(endTracing(to:completion:));

/// Ends the trace into a temporary file and deletes that file. Does nothing
/// when no trace runs.
- (void)cancelTracing;
@end

typedef NS_ENUM(NSInteger, OEProcessKind) {
  OEProcessKindUnknown = 0,
  OEProcessKindBrowser,
  OEProcessKindGPU,
  OEProcessKindRenderer,
  OEProcessKindExtension,
  OEProcessKindUtility,
  OEProcessKindServiceWorker,
  OEProcessKindOther,
};

/// One task-manager row.
OE_EXPORT @interface OEProcessMetrics : NSObject
@property(nonatomic, readonly) int64_t taskIdentifier;
@property(nonatomic, readonly) OEProcessKind kind;
@property(nonatomic, readonly, copy) NSString* title;
/// Private memory footprint in bytes, or -1 when unknown.
@property(nonatomic, readonly) int64_t memoryFootprint;
/// GPU memory in bytes, or -1 when unknown.
@property(nonatomic, readonly) int64_t gpuMemory;
/// Percent of one core (0...cores*100).
@property(nonatomic, readonly) double cpuUsage;
@end

NS_SWIFT_UI_ACTOR
@interface OEEngine (CodeSignClones)

/// Call after the first content frame (or the native frame for an empty window).
/// Once per process, removes obsolete code-sign clones on a utility worker.
/// Keeps the current install and any clone leased by another live process.
/// Completion runs on the main thread and reports counts, never cache paths.
- (void)pruneUnusedCodeSignClonesWithCompletion:
    (void (^NS_SWIFT_UI_ACTOR)(NSDictionary<NSString*, NSNumber*>* counts))completion
    NS_SWIFT_NAME(pruneUnusedCodeSignClones(completion:));

@end

/// The NSApplication subclass that Chromium's message pump needs. Set it as
/// NSPrincipalClass and create it with `OEApplication.shared` before any other
/// AppKit call.
///
/// Keyboard: -sendEvent: offers every Command/Control key-down to
/// `keyEquivalentHandler` before any view sees it. Return YES to consume it.
/// The shell uses this for shortcuts that must win over the page (Arc
/// reserves Cmd-T, Cmd-W, Cmd-L, Cmd-S, ...); all other shortcuts reach the
/// page first and come back through -webContent:handleUnconsumedKeyEvent:.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEApplication : NSApplication
@property(nonatomic, copy, nullable) BOOL (^keyEquivalentHandler)
    (NSEvent* event);
@end

/// Entry point for the five helper executables (renderer, GPU, utility,
/// plugin, alerts). `int main(int argc, char* argv[]) { return
/// OEHelperMain(argc, argv); }`.
OE_EXTERN int OEHelperMain(int argc, char* _Nonnull argv[_Nonnull]);

NS_HEADER_AUDIT_END(nullability, sendability)
