// Benchmark-only probe, injected into our own automation app. Uses the same
// next-display-link receipt as App/main.swift's FirstWindowFrameObserver.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

@interface LittleOpenFrameProbe : NSObject
@property(nonatomic, strong) CADisplayLink *link;
@property(nonatomic) NSInteger number;
@property(nonatomic) CFTimeInterval submitted;
@end
@implementation LittleOpenFrameProbe
- (void)frame:(CADisplayLink *)link {
  if (link.timestamp < self.submitted) return;
  NSDictionary *row = @{ @"window": @(self.number), @"uptime": @(NSProcessInfo.processInfo.systemUptime) };
  NSData *data = [NSJSONSerialization dataWithJSONObject:row options:0 error:nil];
  NSString *path = NSProcessInfo.processInfo.environment[@"OPEN_LITTLEOPEN_FRAME_LOG"];
  NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
  [file seekToEndOfFile]; [file writeData:data]; [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
  [self.link invalidate]; self.link = nil;
}
@end

@interface NSWindow (LittleOpenFrameProbe)
- (void)lo_probe_makeKeyAndOrderFront:(id)sender;
@end
@implementation NSWindow (LittleOpenFrameProbe)
+ (void)load {
  if (!NSProcessInfo.processInfo.environment[@"OPEN_LITTLEOPEN_FRAME_LOG"]) return;
  method_exchangeImplementations(class_getInstanceMethod(self, @selector(makeKeyAndOrderFront:)),
                                class_getInstanceMethod(self, @selector(lo_probe_makeKeyAndOrderFront:)));
}
- (void)lo_probe_makeKeyAndOrderFront:(id)sender {
  [self lo_probe_makeKeyAndOrderFront:sender];
  if (![NSStringFromClass(self.class) containsString:@"LittleOpenNativeWindow"] || objc_getAssociatedObject(self, @selector(lo_probe_makeKeyAndOrderFront:))) return;
  LittleOpenFrameProbe *probe = [LittleOpenFrameProbe new];
  probe.number = self.windowNumber; probe.submitted = CACurrentMediaTime();
  probe.link = [self.contentView displayLinkWithTarget:probe selector:@selector(frame:)];
  objc_setAssociatedObject(self, @selector(lo_probe_makeKeyAndOrderFront:), probe, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
  [probe.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
@end
