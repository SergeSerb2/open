#import "OEInternal.h"
#include "include/cef_site_control.h"
#include "include/cef_ssl_status.h"
#include <utility>

@interface OESiteSetting ()
- (instancetype)initOEWithKind:(NSString*)kind state:(NSString*)state;
@end
@implementation OESiteSetting
- (instancetype)initOEWithKind:(NSString*)kind state:(NSString*)state {
  if ((self = [super init])) { _kind = [kind copy]; _state = [state copy]; }
  return self;
}
@end

namespace {
// OECef uses a C string. Refuse embedded NUL or malformed UTF-16 so a value
// cannot be truncated into a different valid setting before CEF validates it.
bool InvalidString(NSString* value) {
  if (![value canBeConvertedToEncoding:NSUTF8StringEncoding]) return true;
  for (NSUInteger i = 0; i < value.length; ++i)
    if ([value characterAtIndex:i] == 0) return true;
  return false;
}
NSError* RemovalError(NSString* message) {
  return [NSError errorWithDomain:@"OpenEngine.SiteData" code:1
      userInfo:@{NSLocalizedDescriptionKey: message}];
}
class OESiteDataCallback : public CefSiteDataCallback {
 public:
  explicit OESiteDataCallback(void (^completion)(NSError*))
      : completion_([completion copy]) {}
  ~OESiteDataCallback() override {
    auto completion = std::exchange(completion_, nil);
    if (completion) dispatch_async(dispatch_get_main_queue(), ^{
      completion(RemovalError(@"Site-data removal was canceled."));
    });
  }
  void OnComplete(bool success) override {
    auto completion = std::exchange(completion_, nil);
    if (completion) completion(success ? nil : RemovalError(@"Site-data removal failed; some data may remain."));
  }
 private:
  void (^completion_)(NSError*);
  IMPLEMENT_REFCOUNTING(OESiteDataCallback);
};
}

@implementation OEBrowserContext (OESiteControl)
- (NSArray<OESiteSetting*>*)changedSiteSettingsForOrigin:(NSURL*)origin {
  if (origin.absoluteString.length > 16384 || InvalidString(origin.absoluteString)) return @[];
  auto values = CefGetChangedSiteSettings(self.oe_requestContext, OECef(origin.absoluteString));
  if (!values || values->GetSize() > 1024) return @[];
  NSMutableArray* result = [NSMutableArray arrayWithCapacity:values->GetSize()];
  for (size_t i = 0; i < values->GetSize(); ++i) {
    auto value = values->GetDictionary(i);
    if (!value) continue;
    NSString* kind = OEString(value->GetString("kind"));
    NSString* state = OEString(value->GetString("state"));
    if (kind.length > 128 || state.length > 16) return @[];
    [result addObject:[[OESiteSetting alloc] initOEWithKind:kind state:state]];
  }
  return result;
}
- (BOOL)setSiteSetting:(NSString*)kind state:(NSString*)state origin:(NSURL*)origin {
  if (kind.length > 128 || state.length > 16 || origin.absoluteString.length > 16384 ||
      InvalidString(kind) || InvalidString(state) || InvalidString(origin.absoluteString)) return NO;
  return CefSetSiteSetting(self.oe_requestContext, OECef(origin.absoluteString), OECef(kind), OECef(state));
}
- (void)clearSiteDataForOrigin:(NSURL*)origin types:(OESiteDataType)types
                   completion:(void (^)(NSError*))completion {
  if (origin.absoluteString.length > 16384 || InvalidString(origin.absoluteString) ||
      (types & ~(OESiteDataType)7)) {
    completion(RemovalError(@"Invalid site-data origin or types."));
    return;
  }
  // Create the callback only after validation, and explicitly complete refused
  // requests. Its destructor protects the caller if CEF drops pending work.
  CefRefPtr<OESiteDataCallback> callback = new OESiteDataCallback(completion);
  if (!CefClearSiteData(self.oe_requestContext, OECef(origin.absoluteString), (int)types, callback))
    callback->OnComplete(false);
}
@end

@implementation OEWebContent (OESiteControl)
- (NSString*)securityLevel { return OEString(CefGetSiteSecurityLevel(self.oe_browser)); }
- (NSArray*)certificateChain {
  auto browser = self.oe_browser;
  auto entry = browser ? browser->GetHost()->GetVisibleNavigationEntry() : nullptr;
  auto ssl = entry ? entry->GetSSLStatus() : nullptr;
  auto certificate = ssl ? ssl->GetX509Certificate() : nullptr;
  if (!certificate || certificate->GetIssuerChainSize() > 31) return @[];
  CefX509Certificate::IssuerChainBinaryList chain;
  certificate->GetDEREncodedIssuerChain(chain);
  chain.insert(chain.begin(), certificate->GetDEREncoded());
  if (chain.size() > 32) return @[];
  NSMutableArray* result = [NSMutableArray arrayWithCapacity:chain.size()];
  size_t total = 0;
  for (auto value : chain) {
    const size_t size = value ? value->GetSize() : 0;
    if (!size || size > 256 * 1024 || total + size > 1024 * 1024) return @[];
    total += size;
    // The native DER copy is at most 256 KiB; at most 1 MiB is retained.
    NSMutableData* data = [NSMutableData dataWithLength:size];
    if (value->GetData(data.mutableBytes, size, 0) != size) return @[];
    SecCertificateRef cert = SecCertificateCreateWithData(kCFAllocatorDefault, (__bridge CFDataRef)data);
    if (!cert) return @[];
    [result addObject:CFBridgingRelease(cert)];
  }
  return result;
}
@end
