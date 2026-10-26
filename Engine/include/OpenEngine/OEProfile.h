#import <AppKit/AppKit.h>
#import <OpenEngine/OEDefines.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

@class OEProfile;
@class OEDownload;
@class OEExtensionManager;
@class OEWebView;

#pragma mark - User scripts (Boosts, Zap)

typedef NS_ENUM(NSInteger, OEUserScriptInjectionTime) {
  /// Before any page script runs (V8 context creation).
  OEUserScriptInjectionTimeDocumentStart = 0,
  /// At DOMContentLoaded.
  OEUserScriptInjectionTimeDocumentEnd = 1,
} NS_SWIFT_NAME(UserScriptInjectionTime);

typedef NS_ENUM(NSInteger, OEUserScriptKind) {
  OEUserScriptKindJavaScript = 0,
  /// The source is a style sheet; the engine inserts it as a <style> element.
  OEUserScriptKindStyleSheet = 1,
} NS_SWIFT_NAME(UserScriptKind);

/// A script or style sheet injected into matching frames of every web view in
/// a profile. Runs in the page's main world (see docs/engine-api.md for the
/// isolated-world gap).
NS_SWIFT_NAME(UserScript)
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
} NS_SWIFT_NAME(ResourceType);

/// Read-only description of one network request. Immutable, so it is safe to
/// use on the network thread.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(ResourceRequest)
OE_EXPORT @interface OEResourceRequest : NSObject
@property(nonatomic, readonly, copy) NSString* URLString;
@property(nonatomic, readonly, copy) NSString* method;
/// Top-level site of the page that made the request ("" if none).
@property(nonatomic, readonly, copy) NSString* firstPartyURLString;
/// Origin that initiated the request ("" if none).
@property(nonatomic, readonly, copy) NSString* initiator;
@property(nonatomic, readonly) OEResourceType resourceType;
@property(nonatomic, readonly) BOOL isNavigation;
/// OEWebView identifier, or 0 for requests from service workers and other
/// contexts without a web view.
@property(nonatomic, readonly) NSInteger webViewIdentifier;
@end

typedef NS_ENUM(NSInteger, OERequestDecision) {
  OERequestDecisionAllow = 0,
  OERequestDecisionBlock = 1,
} NS_SWIFT_NAME(RequestDecision);

/// Called on Chromium's network (IO) thread for every request in the profile,
/// including extension and service-worker requests. Must be fast and
/// thread-safe.
typedef OERequestDecision (^OERequestFilter)(OEResourceRequest* request)
    NS_SWIFT_SENDABLE NS_SWIFT_NAME(RequestFilter);

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
} NS_SWIFT_NAME(PermissionKind);

typedef NS_ENUM(NSInteger, OEPermissionState) {
  OEPermissionStateAsk = 0,
  OEPermissionStateAllow = 1,
  OEPermissionStateBlock = 2,
} NS_SWIFT_NAME(PermissionState);

#pragma mark - Profile

NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(ProfileDelegate)
@protocol OEProfileDelegate <NSObject>
@optional
/// A download is about to start. Call `completion` with a destination file
/// URL, or nil to cancel. If not implemented, files go to ~/Downloads.
- (void)profile:(OEProfile*)profile
    decideDestinationForDownload:(OEDownload*)download
               suggestedFilename:(NSString*)suggestedFilename
                      completion:(void (^NS_SWIFT_UI_ACTOR)(
                                     NSURL* _Nullable destination))completion
    NS_SWIFT_NAME(profile(_:decideDestinationFor:suggestedFilename:completion:));
/// Progress, completion, cancel, or interruption.
- (void)profile:(OEProfile*)profile
    downloadDidUpdate:(OEDownload*)download
    NS_SWIFT_NAME(profile(_:downloadDidUpdate:));
@end

/// A browsing profile: its own cookie jar, storage, cache, extensions,
/// permissions and history. Backed by a CefRequestContext with its own
/// cache path (a Chrome Profile underneath).
NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(Profile)
OE_EXPORT @interface OEProfile : NSObject

@property(nonatomic, readonly, copy) NSString* identifier;
@property(nonatomic, readonly, copy) NSURL* directory;
@property(nonatomic, weak, nullable) id<OEProfileDelegate> delegate;

/// Extensions installed in this profile.
@property(nonatomic, readonly) OEExtensionManager* extensions;

/// User scripts. Changes apply to new documents in every web view of the
/// profile, including documents in web views that already exist.
@property(nonatomic, readonly, copy) NSArray<OEUserScript*>* userScripts;
- (void)addUserScript:(OEUserScript*)script NS_SWIFT_NAME(addUserScript(_:));
- (void)removeUserScriptWithIdentifier:(NSString*)identifier
    NS_SWIFT_NAME(removeUserScript(identifier:));
- (void)removeAllUserScripts;

/// Network filter for the whole profile. nil allows everything. The block is
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

/// Deletes cookies, cache, and site storage for every site, or for one origin
/// when `origin` is non-nil.
- (void)clearBrowsingDataForOrigin:(nullable NSURL*)origin
                        completion:(void (^NS_SWIFT_UI_ACTOR _Nullable)(void))
                                       completion
    NS_SWIFT_NAME(clearBrowsingData(origin:completion:));

/// Every live download in this profile.
@property(nonatomic, readonly, copy) NSArray<OEDownload*>* downloads;
@end

#pragma mark - Downloads

typedef NS_ENUM(NSInteger, OEDownloadState) {
  OEDownloadStatePending = 0,
  OEDownloadStateInProgress,
  OEDownloadStateComplete,
  OEDownloadStateCancelled,
  OEDownloadStateInterrupted,
} NS_SWIFT_NAME(DownloadState);

NS_SWIFT_UI_ACTOR
NS_SWIFT_NAME(Download)
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
/// Web view that started the download, if it still exists.
@property(nonatomic, readonly, weak, nullable) OEWebView* webView;
- (void)cancel;
- (void)pause;
- (void)resume;
@end

NS_HEADER_AUDIT_END(nullability, sendability)
