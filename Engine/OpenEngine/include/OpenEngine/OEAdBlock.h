#import <OpenEngine/OEBrowserContext.h>
#import <OpenEngine/OEWebContent.h>

NS_ASSUME_NONNULL_BEGIN

/// Main thread only, including values remembered before context initialization.
@interface OEBrowserContext (OEAdBlock)
/// YES only when this engine implements native request blocking.
@property(class, nonatomic, readonly) BOOL adBlockSupported;
/// Native ad blocking for this context. Default NO. Takes effect on the next request.
@property(nonatomic, getter=isAdBlockEnabled) BOOL adBlockEnabled;
/// The adblock root (<Profile>/AdBlock/lists). Loads asynchronously; nil unloads.
@property(nonatomic, copy, nullable) NSURL* adBlockListDirectory;
/// Re-read the current generation after the App published a new one.
- (void)reloadAdBlockLists;
/// Registrable domains that skip blocking. Applies to the next request.
@property(nonatomic, copy) NSArray<NSString*>* adBlockExcludedDomains;
/// Debug snapshot (keys of CefGetOpenAdBlockStatus, NSNumber/NSString values).
@property(nonatomic, readonly, copy) NSDictionary<NSString*, id>* adBlockStatus;
@end

@interface OEWebContent (OEAdBlock)
/// Blocked + redirected subresources of the current document. 0 if none.
@property(nonatomic, readonly) NSInteger adBlockBlockedCount;
@end

NS_ASSUME_NONNULL_END
