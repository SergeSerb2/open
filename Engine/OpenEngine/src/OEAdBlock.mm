// Native per-context ad-block control. CEF owns the service and async loads.
#import "OEInternal.h"
#import <objc/runtime.h>

#include "include/cef_open_adblock.h"

@interface OEAdBlockState : NSObject
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy, nullable) NSURL* directory;
@property(nonatomic, copy) NSArray<NSString*>* excluded;
@property(nonatomic) BOOL applyQueued;
@property(nonatomic) BOOL reloadPending;
@end
@implementation OEAdBlockState
@end

static char kAdBlockState;

static BOOL OELiveAdBlockContext(OEBrowserContext* context) {
  return context.state == OEBrowserContextStateLive && !context.oe_closing;
}

static OEAdBlockState* OEAdBlockValues(OEBrowserContext* context) {
  OEAdBlockState* values = objc_getAssociatedObject(context, &kAdBlockState);
  if (!values) {
    values = [OEAdBlockState new];
    values.excluded = @[];
    objc_setAssociatedObject(context, &kAdBlockState, values,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  }
  return values;
}

static void OEApplyAdBlock(OEBrowserContext* context) {
  if (!OELiveAdBlockContext(context)) return;
  OEAdBlockState* values = OEAdBlockValues(context);
  if (!context.oe_isReady) {
    if (values.applyQueued) return;
    values.applyQueued = YES;
    __weak OEBrowserContext* weakContext = context;
    [context oe_whenReady:^{
      OEBrowserContext* live = weakContext;
      if (!live || !OELiveAdBlockContext(live)) return;
      OEAdBlockValues(live).applyQueued = NO;
      OEApplyAdBlock(live);
    }];
    return;
  }
  auto native = context.oe_requestContext;
  std::vector<CefString> domains;
  for (NSString* domain in values.excluded) domains.push_back(OECef(domain));
  // Publish the config before enabling it, including the pre-init path.
  CefSetOpenAdBlockExcludedDomains(native, domains);
  CefSetOpenAdBlockListDirectory(native, OECef(values.directory.path));
  CefSetOpenAdBlockEnabled(native, values.enabled);
  if (values.reloadPending) {
    values.reloadPending = NO;
    CefReloadOpenAdBlockLists(native);
  }
}

@implementation OEBrowserContext (OEAdBlock)
+ (BOOL)adBlockSupported { return YES; }

- (BOOL)isAdBlockEnabled {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  return OELiveAdBlockContext(self) && OEAdBlockValues(self).enabled;
}

- (void)setAdBlockEnabled:(BOOL)enabled {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  if (!OELiveAdBlockContext(self)) return;
  OEAdBlockValues(self).enabled = enabled;
  OEApplyAdBlock(self);
}

- (NSURL*)adBlockListDirectory {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  return OELiveAdBlockContext(self) ? OEAdBlockValues(self).directory : nil;
}

- (void)setAdBlockListDirectory:(NSURL*)directory {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  if (!OELiveAdBlockContext(self)) return;
  if (directory && !directory.isFileURL) return;
  OEAdBlockValues(self).directory = directory;
  OEApplyAdBlock(self);
}

- (NSArray<NSString*>*)adBlockExcludedDomains {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  return OELiveAdBlockContext(self) ? OEAdBlockValues(self).excluded : @[];
}

- (void)setAdBlockExcludedDomains:(NSArray<NSString*>*)domains {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  if (!OELiveAdBlockContext(self)) return;
  OEAdBlockValues(self).excluded = domains ?: @[];
  OEApplyAdBlock(self);
}

- (void)reloadAdBlockLists {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  if (!OELiveAdBlockContext(self)) return;
  OEAdBlockValues(self).reloadPending = YES;
  OEApplyAdBlock(self);
}

- (NSDictionary<NSString*, id>*)adBlockStatus {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  auto status = OELiveAdBlockContext(self)
      ? CefGetOpenAdBlockStatus(self.oe_requestContext) : nullptr;
  if (!status) {
    return @{@"enabled": @(self.isAdBlockEnabled), @"engine_loaded": @NO,
        @"engine_from_dat": @NO, @"engine_shared": @NO, @"dat_policy": @"",
        @"list_count": @0, @"resources_loaded": @0, @"last_build_ms": @(-1),
        @"last_error": @"", @"excluded_count": @(self.adBlockExcludedDomains.count),
        @"load_generation": @0};
  }
  NSMutableDictionary<NSString*, id>* result = [NSMutableDictionary dictionary];
  CefDictionaryValue::KeyList keys;
  status->GetKeys(keys);
  for (const auto& key : keys) {
    id value = nil;
    switch (status->GetType(key)) {
      case VTYPE_BOOL: value = @(status->GetBool(key)); break;
      case VTYPE_INT: value = @(status->GetInt(key)); break;
      case VTYPE_DOUBLE: value = @(status->GetDouble(key)); break;
      case VTYPE_STRING: value = OEString(status->GetString(key)); break;
      default: break;
    }
    if (value) result[OEString(key)] = value;
  }
  return [result copy];
}
@end

@implementation OEWebContent (OEAdBlock)
- (NSInteger)adBlockBlockedCount {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  return CefGetOpenAdBlockBlockedCount(self.oe_browser);
}
@end
