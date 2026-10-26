#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEProfile;
@class OEWebView;
@class OEOpenRequest;
@class OEProcessMetrics;

/// Startup options. Copied by -[OEEngine startWithConfiguration:error:].
NS_SWIFT_NAME(EngineConfiguration)
OE_EXPORT @interface OEEngineConfiguration : NSObject <NSCopying>

/// Chromium "user data dir". Every profile lives in a subdirectory.
/// Default: ~/Library/Application Support/Open.
@property(nonatomic, copy) NSURL* userDataDirectory;

/// Appended to the Chrome user agent product token, e.g. "Open/0.1".
@property(nonatomic, copy, nullable) NSString* userAgentProduct;

/// UI locale such as "en-US". nil uses the system locale.
@property(nonatomic, copy, nullable) NSString* locale;

/// Runtime style for web views that do not choose one. Default: Alloy.
@property(nonatomic) OERuntimeStyle defaultRuntimeStyle;

/// Opens the DevTools remote debugging port when > 0. Default: 0.
@property(nonatomic) NSInteger remoteDebuggingPort;

/// Extra Chromium switches, for example "--enable-features=Foo" or
/// "--load-extension=/path". Applied in OnBeforeCommandLineProcessing.
@property(nonatomic, copy) NSArray<NSString*>* additionalSwitches;

/// Optional log file. Default: <userDataDirectory>/engine.log.
@property(nonatomic, copy, nullable) NSURL* logFile;

/// Verbose Chromium logging (LOGSEVERITY_VERBOSE). Default: NO.
@property(nonatomic) BOOL verboseLogging;

@end

/// Engine-level callbacks. All on the main thread.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(EngineDelegate)
@protocol OEEngineDelegate <NSObject>
@optional
/// The browser process finished initialization (CEF OnContextInitialized).
/// Create web views after this.
- (void)engineDidInitialize;

/// Chromium opened a page that no OEWebView asked for: chrome.tabs.create()
/// from an extension, chrome.runtime.openOptionsPage(), a notification click,
/// or a DevTools window. Return a web view to host it (the shell adds it as a
/// tab), or nil to let Chromium show a default window.
- (nullable OEWebView*)engineWebViewForUnownedOpenRequest:
    (OEOpenRequest*)request
    NS_SWIFT_NAME(engineWebView(forUnownedOpenRequest:));

/// Every OEWebView is closed and the message loop is about to quit.
- (void)engineWillShutDown;
@end

/// Process-wide engine. Lifecycle:
///
///     Engine.shared.start(configuration)   // after NSApplication exists
///     Engine.shared.runMessageLoop()       // blocks; runs NSApp
///     Engine.shared.shutdown()             // after the loop returns
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(Engine)
OE_EXPORT @interface OEEngine : NSObject

@property(class, nonatomic, readonly) OEEngine* shared;

@property(nonatomic, weak, nullable) id<OEEngineDelegate> delegate;
@property(nonatomic, readonly, copy) OEEngineConfiguration* configuration;
@property(nonatomic, readonly, getter=isRunning) BOOL running;

/// "156.0.8078.48" and "156.0.14+g4fa4ab5+chromium-156.0.8078.48".
@property(nonatomic, readonly, copy) NSString* chromiumVersion;
@property(nonatomic, readonly, copy) NSString* cefVersion;

/// Initializes Chromium. Call once, on the main thread, after
/// NSApplication.shared (an OEApplication) exists.
- (BOOL)startWithConfiguration:(OEEngineConfiguration*)configuration
                         error:(NSError**)error
    NS_SWIFT_NAME(start(configuration:));

/// Runs the NSApplication event loop under Chromium's message pump. Returns
/// after -terminate finished closing every web view.
- (void)runMessageLoop;

/// Closes all web views (running beforeunload handlers is skipped), then quits
/// the message loop. -[OEApplication terminate:] calls this.
- (void)terminate;

/// Releases Chromium. Call after -runMessageLoop returns.
- (void)shutdown;

/// The profile that uses <userDataDirectory>/Default.
@property(nonatomic, readonly) OEProfile* defaultProfile;

/// Returns the profile stored in <userDataDirectory>/<identifier>, creating
/// it if needed. Profiles have separate cookies, storage, cache, extensions,
/// permissions, and history (Arc "Profiles").
- (OEProfile*)profileWithIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(profile(identifier:));

@property(nonatomic, readonly, copy) NSArray<OEProfile*>* profiles;

/// Every live web view, in creation order.
@property(nonatomic, readonly, copy) NSArray<OEWebView*>* allWebViews;

/// Returns the web view whose identifier (CEF browser id, also the
/// chrome.tabs tab id for Chrome-style views) matches.
- (nullable OEWebView*)webViewWithIdentifier:(NSInteger)identifier
    NS_SWIFT_NAME(webView(identifier:));

/// Samples Chromium's task manager (one entry per process) and calls back
/// after `interval` seconds, so CPU usage has a measurement window.
- (void)sampleProcessMetricsAfter:(NSTimeInterval)interval
                       completion:(void (^NS_SWIFT_UI_ACTOR)(
                                      NSArray<OEProcessMetrics*>* metrics))
                                      completion
    NS_SWIFT_NAME(sampleProcessMetrics(after:completion:));
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
} NS_SWIFT_NAME(ProcessKind);

/// One task-manager row.
NS_SWIFT_NAME(ProcessMetrics)
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

/// NSApplication subclass that Chromium's message pump needs
/// (CefAppProtocol). Set it as NSPrincipalClass and create it with
/// `OEApplication.shared` before any other AppKit call.
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(EngineApplication)
OE_EXPORT @interface OEApplication : NSApplication
@end

/// Entry point for the five helper executables (renderer, GPU, utility,
/// plugin, alerts). `int main(int argc, char* argv[]) { return
/// OEHelperMain(argc, argv); }`.
OE_EXTERN int OEHelperMain(int argc, char* _Nonnull argv[_Nonnull]);

NS_HEADER_AUDIT_END(nullability, sendability)
