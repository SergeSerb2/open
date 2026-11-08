#import <OpenEngine/OEBrowserContext.h>
#import <OpenEngine/OEWebContent.h>
#import <Security/Security.h>

NS_HEADER_AUDIT_BEGIN(nullability, sendability)

/// One effective per-origin exception from Chromium's content-settings registry.
NS_SWIFT_UI_ACTOR
OE_EXPORT @interface OESiteSetting : NSObject
@property(nonatomic, readonly, copy) NSString* kind;
/// allow, block, ask or session. A kind may support only some states.
@property(nonatomic, readonly, copy) NSString* state;
- (instancetype)init NS_UNAVAILABLE;
@end

typedef NS_OPTIONS(NSUInteger, OESiteDataType) {
  OESiteDataTypeCookies = 1u << 0,
  OESiteDataTypeCache = 1u << 1,
  OESiteDataTypeStorage = 1u << 2,
};

@interface OEBrowserContext (OESiteControl)
/// HTTP(S) only. Empty for an invalid origin or a context that is not ready.
/// Uses every registered scalar ContentSetting, including JavaScript/images.
- (NSArray<OESiteSetting*>*)changedSiteSettingsForOrigin:(NSURL*)origin
    NS_SWIFT_NAME(changedSiteSettings(origin:));
/// NO for an invalid origin, kind, state, or a context that is not ready.
/// Setting the global default removes the effective exception from the list.
- (BOOL)setSiteSetting:(NSString*)kind state:(NSString*)state origin:(NSURL*)origin
    NS_SWIFT_NAME(setSiteSetting(_:state:origin:));
/// Removes the selected data and completes once on the main thread. May be
/// called before context initialization. The completion may close the context.
/// Cache/storage match the exact origin in all storage-key contexts. Cookies
/// match its host and parent Domain cookies, across paths/partitions; cookies
/// intrinsically share schemes/ports. Unrelated host-only cookies stay intact.
/// Empty types succeeds; invalid inputs/backend failures return an error.
- (void)clearSiteDataForOrigin:(NSURL*)origin types:(OESiteDataType)types
                   completion:(void (^NS_SWIFT_UI_ACTOR)(NSError* _Nullable error))completion
    NS_SWIFT_NAME(clearSiteData(origin:types:completion:));
@end

@interface OEWebContent (OESiteControl)
/// secure, neutral, insecure, dangerous or mixedContent. HTTP (including
/// loopback) is insecure. Major certificate errors take precedence over mixed
/// content. Observe OEWebContentChangeSecurity and re-read both properties.
@property(nonatomic, readonly, copy) NSString* securityLevel
    NS_SWIFT_NAME(engineSecurityLevel);
/// SecCertificateRef objects, leaf first, then Chromium's issuer chain. Empty
/// for a non-TLS page or a chain beyond 32 certs / 1 MiB / 256 KiB per cert.
@property(nonatomic, readonly, copy) NSArray* certificateChain
    NS_SWIFT_NAME(engineCertificateChain);
@end

NS_HEADER_AUDIT_END(nullability, sendability)
