#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEBrowserContext;
@class OEDownload;
@class OEExtensionManager;
@class OEWebContent;

#pragma mark - User scripts (Boosts, Zap)

typedef NS_ENUM(NSInteger, OEUserScriptInjectionTime) {
  /// Before any page script runs (V8 context creation).
  OEUserScriptInjectionTimeDocumentStart = 0,
  /// At DOMContentLoaded.
  OEUserScriptInjectionTimeDocumentEnd = 1,
};

typedef NS_ENUM(NSInteger, OEUserScriptKind) {
  OEUserScriptKindJavaScript = 0,
  /// The source is a style sheet; the engine inserts it as a <style> element
  /// as soon as <html> exists.
  OEUserScriptKindStyleSheet = 1,
};

/// A script or style sheet injected into matching frames of every web content
/// in a context. Runs in the page's main world (see docs/engine-api.md for the
/// isolated-world gap).
OE_EXPORT @interface OEUserScript : NSObject <NSCopying>
- (instancetype)initWithIdentifier:(NSString*)identifier
                            source:(NSString*)source
                              kind:(OEUserScriptKind)kind
                     injectionTime:(OEUserScriptInjectionTime)injectionTime
                     matchPatterns:(NSArray<NSString*>*)matchPatterns
                     mainFrameOnly:(BOOL)mainFrameOnly
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSString* source;
@property(nonatomic, readonly) OEUserScriptKind kind;
@property(nonatomic, readonly) OEUserScriptInjectionTime injectionTime;
/// Chrome match patterns ("*://*.example.com/*", "<all_urls>").
@property(nonatomic, readonly, copy) NSArray<NSString*>* matchPatterns;
@property(nonatomic, readonly) BOOL mainFrameOnly;
@end

#pragma mark - Network filter (ad blocking)

typedef NS_ENUM(NSInteger, OEResourceType) {
  OEResourceTypeMainFrame = 0,
  OEResourceTypeSubFrame,
  OEResourceTypeStylesheet,
  OEResourceTypeScript,
  OEResourceTypeImage,
  OEResourceTypeFont,
  OEResourceTypeMedia,
  OEResourceTypeXHR,
  OEResourceTypeFetch,
  OEResourceTypePing,
  OEResourceTypeWorker,
  OEResourceTypeServiceWorker,
  OEResourceTypeFavicon,
  OEResourceTypeOther,
};

/// Read-only description of one network request. Immutable, so it is safe to
/// use on the network thread.
NS_SWIFT_SENDABLE
OE_EXPORT @interface OEResourceRequest : NSObject
@property(nonatomic, readonly, copy) NSString* URLString;
@property(nonatomic, readonly, copy) NSString* method;
/// Top-level site of the page that made the request ("" if none).
@property(nonatomic, readonly, copy) NSString* firstPartyURLString;
/// Origin that initiated the request ("" if none).
@property(nonatomic, readonly, copy) NSString* initiator;
@property(nonatomic, readonly) OEResourceType resourceType;
@property(nonatomic, readonly) BOOL isNavigation;
/// OEWebContent identifier, or 0 for requests from service workers and
/// other contexts without a web content.
@property(nonatomic, readonly) NSInteger webContentIdentifier;
@end

typedef NS_ENUM(NSInteger, OERequestDecision) {
  OERequestDecisionAllow = 0,
  OERequestDecisionBlock = 1,
};

/// Called on Chromium's network (IO) thread for every request in the
/// context, including extension and service-worker requests. Must be fast
/// and thread-safe.
typedef OERequestDecision (^OERequestFilter)(OEResourceRequest* request)
    NS_SWIFT_SENDABLE;

#pragma mark - Site permissions (Site Control Center)

typedef NS_OPTIONS(uint32_t, OEPermissionKind) {
  OEPermissionKindCamera = 1u << 0,
  OEPermissionKindMicrophone = 1u << 1,
  OEPermissionKindGeolocation = 1u << 2,
  OEPermissionKindNotifications = 1u << 3,
  OEPermissionKindClipboard = 1u << 4,
  OEPermissionKindMIDI = 1u << 5,
  OEPermissionKindScreenCapture = 1u << 6,
  OEPermissionKindMultipleDownloads = 1u << 7,
  OEPermissionKindStorageAccess = 1u << 8,
  OEPermissionKindWindowManagement = 1u << 9,
  OEPermissionKindLocalFonts = 1u << 10,
  OEPermissionKindIdleDetection = 1u << 11,
  OEPermissionKindOther = 1u << 31,
};

typedef NS_ENUM(NSInteger, OEPermissionState) {
  OEPermissionStateAsk = 0,
  OEPermissionStateAllow = 1,
  OEPermissionStateBlock = 2,
};

#pragma mark - Browser context

NS_SWIFT_UI_ACTOR
@protocol OEBrowserContextDelegate <NSObject>
@optional
/// A download is about to start. Call `completion` with a destination file
/// URL, or nil to cancel. If not implemented, files go to ~/Downloads.
- (void)browserContext:(OEBrowserContext*)context
    decideDestinationForDownload:(OEDownload*)download
               suggestedFilename:(NSString*)suggestedFilename
                      completion:(void (^NS_SWIFT_UI_ACTOR)(
                                     NSURL* _Nullable destination))completion
    NS_SWIFT_NAME(browserContext(_:decideDestinationFor:suggestedFilename:completion:));
/// Progress, completion, cancel, or interruption.
- (void)browserContext:(OEBrowserContext*)context
     downloadDidUpdate:(OEDownload*)download
    NS_SWIFT_NAME(browserContext(_:downloadDidUpdate:));
@end

/// One browsing profile (ADK "BrowserContext"): its own cookie jar, storage,
/// cache, extensions, permissions, and history. Backed by a CEF request
/// context with its own cache path, which is a Chrome Profile underneath.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEBrowserContext : NSObject

@property(nonatomic, readonly, copy) NSString* identifier;
/// The profile folder. nil for ephemeral (in-memory) contexts.
@property(nonatomic, readonly, copy, nullable) NSURL* directory;
@property(nonatomic, readonly, getter=isEphemeral) BOOL ephemeral;
@property(nonatomic, weak, nullable) id<OEBrowserContextDelegate> delegate;

/// Extensions installed in this context.
@property(nonatomic, readonly) OEExtensionManager* extensions;

/// User scripts. Changes apply to new documents in every web content of the
/// context, including documents in web contents that already exist.
@property(nonatomic, readonly, copy) NSArray<OEUserScript*>* userScripts;
- (void)addUserScript:(OEUserScript*)script NS_SWIFT_NAME(addUserScript(_:));
- (void)removeUserScriptWithIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(removeUserScript(identifier:));
- (void)removeAllUserScripts;

/// Network filter for the whole context. nil allows everything. The block is
/// read atomically on the network thread.
@property(atomic, copy, nullable) OERequestFilter requestFilter;

/// Per-site permission state (Chromium content settings).
- (OEPermissionState)permissionStateForKind:(OEPermissionKind)kind
                                     origin:(NSURL*)origin
    NS_SWIFT_NAME(permissionState(for:origin:));
- (void)setPermissionState:(OEPermissionState)state
                   forKind:(OEPermissionKind)kind
                    origin:(NSURL*)origin
    NS_SWIFT_NAME(setPermissionState(_:for:origin:));

/// Deletes cookies (for one origin when `origin` is non-nil) and, for all
/// sites, the HTTP cache.
- (void)clearBrowsingDataForOrigin:(nullable NSURL*)origin
                        completion:(void (^NS_SWIFT_UI_ACTOR _Nullable)(void))
                                       completion
    NS_SWIFT_NAME(clearBrowsingData(origin:completion:));

/// Every download of this context since launch.
@property(nonatomic, readonly, copy) NSArray<OEDownload*>* downloads;
@end

#pragma mark - Downloads

typedef NS_ENUM(NSInteger, OEDownloadState) {
  OEDownloadStatePending = 0,
  OEDownloadStateInProgress,
  OEDownloadStateComplete,
  OEDownloadStateCancelled,
  OEDownloadStateInterrupted,
};

NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OEDownload : NSObject
@property(nonatomic, readonly) uint32_t identifier;
@property(nonatomic, readonly, copy) NSURL* sourceURL;
@property(nonatomic, readonly, copy, nullable) NSURL* destinationURL;
@property(nonatomic, readonly, copy) NSString* suggestedFilename;
@property(nonatomic, readonly, copy) NSString* MIMEType;
@property(nonatomic, readonly) OEDownloadState state;
@property(nonatomic, readonly) int64_t receivedBytes;
/// -1 when unknown.
@property(nonatomic, readonly) int64_t totalBytes;
@property(nonatomic, readonly) int64_t bytesPerSecond;
/// Web content that started the download, if it still exists.
@property(nonatomic, readonly, weak, nullable) OEWebContent* webContent;
- (void)cancel;
- (void)pause;
- (void)resume;
@end

NS_HEADER_AUDIT_END(nullability, sendability)
