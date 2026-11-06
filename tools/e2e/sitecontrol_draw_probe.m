// Injected only by the real-App e2e flow. Never linked into the shipping App.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdint.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

static atomic_uint_fast64_t counts[6]; // calls: layout/display/flush, then delays
static _Thread_local BOOL awaitingFlush;

__attribute__((visibility("default"))) uint64_t open_scc_draw_probe_count(int32_t index) {
    return index >= 0 && index < 6 ? atomic_load(&counts[index]) : 0;
}

static BOOL isSiteControlView(NSView *view) {
    return [NSStringFromClass(view.class) hasSuffix:@".SiteControlView"];
}

static void recordPhase(int phase) {
    atomic_fetch_add(&counts[phase], 1);
    const char *selected = getenv("OPEN_SCC_DELAY_PHASE");
    const char *names[] = {"layout", "display", "flush"};
    if (selected && strcmp(selected, names[phase]) == 0) {
        atomic_fetch_add(&counts[phase + 3], 1);
        usleep(12000);
    }
}

@interface NSView (SCCDrawProbe)
- (void)openSCCProofLayout;
- (void)openSCCProofDisplay;
@end
@implementation NSView (SCCDrawProbe)
+ (void)load {
    Method layout = class_getInstanceMethod(self, @selector(layoutSubtreeIfNeeded));
    Method layoutProbe = class_getInstanceMethod(self, @selector(openSCCProofLayout));
    Method display = class_getInstanceMethod(self, @selector(displayIfNeeded));
    Method displayProbe = class_getInstanceMethod(self, @selector(openSCCProofDisplay));
    if (layout && layoutProbe && display && displayProbe) {
        method_exchangeImplementations(layout, layoutProbe);
        method_exchangeImplementations(display, displayProbe);
    }
}
- (void)openSCCProofLayout {
    if (isSiteControlView(self)) recordPhase(0);
    [self openSCCProofLayout];
}
- (void)openSCCProofDisplay {
    BOOL panel = isSiteControlView(self);
    if (panel) recordPhase(1);
    [self openSCCProofDisplay];
    if (panel) awaitingFlush = YES;
}
@end

@interface CATransaction (SCCDrawProbe)
+ (void)openSCCProofFlush;
@end
@implementation CATransaction (SCCDrawProbe)
+ (void)load {
    Method flush = class_getClassMethod(self, @selector(flush));
    Method probe = class_getClassMethod(self, @selector(openSCCProofFlush));
    if (flush && probe) method_exchangeImplementations(flush, probe);
}
+ (void)openSCCProofFlush {
    if (awaitingFlush) {
        awaitingFlush = NO;
        recordPhase(2);
    }
    [self openSCCProofFlush];
}
@end
