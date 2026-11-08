// Placeholder until the cef_open_adblock.h engine API (Section 13 E2); no blocking happens.
// Associated values are context-owned, survive initialization, and never outlive the wrapper.
#import <OpenEngine/OEAdBlock.h>
#import <objc/runtime.h>

static char kEnabled, kListDirectory, kExcludedDomains;

@implementation OEBrowserContext (OEAdBlock)
+ (BOOL)adBlockSupported { return NO; }
- (BOOL)isAdBlockEnabled {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  return self.state == OEBrowserContextStateLive &&
      [objc_getAssociatedObject(self, &kEnabled) boolValue];
}
- (void)setAdBlockEnabled:(BOOL)enabled {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  if (self.state != OEBrowserContextStateLive) return;
  objc_setAssociatedObject(self, &kEnabled, @(enabled), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
- (NSURL*)adBlockListDirectory {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  return self.state == OEBrowserContextStateLive ? objc_getAssociatedObject(self, &kListDirectory) : nil;
}
- (void)setAdBlockListDirectory:(NSURL*)directory {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  if (self.state != OEBrowserContextStateLive) return;
  objc_setAssociatedObject(self, &kListDirectory, directory, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (NSArray<NSString*>*)adBlockExcludedDomains {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  return self.state == OEBrowserContextStateLive ?
      (objc_getAssociatedObject(self, &kExcludedDomains) ?: @[]) : @[];
}
- (void)setAdBlockExcludedDomains:(NSArray<NSString*>*)domains {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  if (self.state != OEBrowserContextStateLive) return;
  objc_setAssociatedObject(self, &kExcludedDomains, domains, OBJC_ASSOCIATION_COPY_NONATOMIC);
}
- (void)reloadAdBlockLists {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  // Placeholder: no engine API exists in the recorded distribution yet.
}
- (NSDictionary<NSString*, id>*)adBlockStatus {
  return @{@"enabled": @(self.isAdBlockEnabled),
           @"list_directory_set": @(self.adBlockListDirectory != nil),
           @"excluded_count": @(self.adBlockExcludedDomains.count), @"engine": @"pending"};
}
@end

@implementation OEWebContent (OEAdBlock)
- (NSInteger)adBlockBlockedCount {
  NSAssert(NSThread.isMainThread, @"OpenEngine is main-thread only");
  return 0;
}
@end
