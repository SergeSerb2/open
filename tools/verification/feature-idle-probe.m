// Harness-only observation. Injected by feature and App e2e gates, never linked into Open.
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <execinfo.h>
#import <dlfcn.h>
#import <stdatomic.h>

#define INTERPOSE(replacement, original) \
__attribute__((used)) static struct { const void *a; const void *b; } ip_##original \
__attribute__((section("__DATA,__interpose"))) = { (const void *)replacement, (const void *)original }

// Fixed storage: overflow fails the gate. References are retained until end(),
// for CF timers/links. Dispatch sources and native objects use weak references
// so observation does not keep work alive after its owner releases it.
#define LIMIT 512
static pthread_mutex_t guard = PTHREAD_MUTEX_INITIALIZER;
// Observe executable-owned startup schedulers before the first fixture too.
// A leaked eager timer must fail the observer's teardown canary, not escape it.
static _Atomic BOOL armed = YES;
static CFRunLoopTimerRef timers[LIMIT];
static CFRunLoopRef loops[LIMIT];
static __weak dispatch_source_t sources[LIMIT];
static CVDisplayLinkRef links[LIMIT];
static unsigned timerCount, sourceCount, linkCount;
static _Atomic uint64_t events[6]; // draw, layout, layer display, invalidation, scheduling, overflow
static NSHashTable *views, *layers, *displayLinks;
static NSMutableSet *hooked;

// Attribute CF timers by their runtime caller. AppKit owns quiet-safe-quit,
// outline cleanup and parked run-loop timers even in an empty native window.
// Skip framework wrapper frames; the first owner must be the harness executable
// (which statically links OpenFeatures). Do not subtract counts or allow a
// nonzero feature baseline. The real NSTimer canary proves this path each run.
static BOOL executableTimerCaller(void) {
    void *stack[32]; int n = backtrace(stack, 32);
    for (int i = 2; i < n; i++) {
        Dl_info info;
        if (!dladdr(stack[i], &info) || !info.dli_fname) continue;
        const char *path = info.dli_fname;
        if (strstr(path, "idle-probe.dylib") || strstr(path, "/Foundation.framework/") ||
            strstr(path, "/CoreFoundation.framework/") || strstr(path, "/libswift") ||
            strstr(path, "/libdispatch.dylib")) continue;
        // The split suite injects this observer into its own real Open instance.
        // Keep the original harness attribution unchanged unless explicitly selected.
        BOOL split = getenv("OPEN_IDLE_OWNER") && !strcmp(getenv("OPEN_IDLE_OWNER"), "split");
        if (split) {
            if (!strstr(path, "/Open") || strstr(path, ".framework/")) return NO;
            if (!info.dli_sname) return YES;
            return strstr(info.dli_sname, "SplitViewController") || strstr(info.dli_sname, "SplitDividerView") ||
                strstr(info.dli_sname, "WebContentContainer") || strstr(info.dli_sname, "PaneSlotView");
        }
        if (!strstr(path, "/features-render")) return NO;
        // Async harness waits can create transient Foundation timers too.
        // Attribute the first executable frame to the product or the canary.
        if (!info.dli_sname) return YES; // unresolved application frame: fail closed
        return strstr(info.dli_sname, "OpenFeatures") || strstr(info.dli_sname, "observerProof");
    }
    return NO;
}
static void scheduled(void) { events[4]++; }
// A self-requeued work item can burn CPU without invalidating a view or owning
// a public timer. Observe its actual queue submission too; legitimate one-shot
// toast expiry/hide requests occur before the idle events are reset.
static void queueWork(void) {
    if (!armed) return;
    pthread_mutex_lock(&guard);
    if (armed && executableTimerCaller()) scheduled();
    pthread_mutex_unlock(&guard);
}
static void enqueue(dispatch_queue_t queue, dispatch_block_t block) {
    queueWork(); dispatch_async(queue, block);
}
INTERPOSE(enqueue, dispatch_async);
static void enqueueFunction(dispatch_queue_t queue, void *context, dispatch_function_t work) {
    queueWork(); dispatch_async_f(queue, context, work);
}
INTERPOSE(enqueueFunction, dispatch_async_f);
static void enqueueAfter(dispatch_time_t time, dispatch_queue_t queue, dispatch_block_t block) {
    queueWork(); dispatch_after(time, queue, block);
}
INTERPOSE(enqueueAfter, dispatch_after);
static void enqueueAfterFunction(dispatch_time_t time, dispatch_queue_t queue, void *context, dispatch_function_t work) {
    queueWork(); dispatch_after_f(time, queue, context, work);
}
INTERPOSE(enqueueAfterFunction, dispatch_after_f);

static void addTimer(CFRunLoopRef loop, CFRunLoopTimerRef timer, CFRunLoopMode mode) {
    pthread_mutex_lock(&guard);
    if (armed && executableTimerCaller()) {
        scheduled();
        unsigned i; for (i = 0; i < timerCount; i++) if (timers[i] == timer && loops[i] == loop) break;
        if (i == timerCount) {
            if (timerCount == LIMIT) events[5]++;
            else { timers[i] = (CFRunLoopTimerRef)CFRetain(timer); loops[i] = (CFRunLoopRef)CFRetain(loop); timerCount++; }
        }
    }
    pthread_mutex_unlock(&guard);
    CFRunLoopAddTimer(loop, timer, mode);
}
INTERPOSE(addTimer, CFRunLoopAddTimer);

// Track creation as well as set_timer: a source parked at FOREVER, or resumed
// without a deadline, is still a live native timer source.
static dispatch_source_t createSource(dispatch_source_type_t type, uintptr_t handle,
                                     unsigned long mask, dispatch_queue_t queue) __attribute__((ns_returns_retained));
static dispatch_source_t createSource(dispatch_source_type_t type, uintptr_t handle,
                                     unsigned long mask, dispatch_queue_t queue) {
    dispatch_source_t source = dispatch_source_create(type, handle, mask, queue);
    if (type != DISPATCH_SOURCE_TYPE_TIMER || !source) return source;
    pthread_mutex_lock(&guard);
    if (armed && executableTimerCaller()) {
        scheduled();
        if (sourceCount == LIMIT) events[5]++;
        else sources[sourceCount++] = source;
    }
    pthread_mutex_unlock(&guard);
    return source;
}
INTERPOSE(createSource, dispatch_source_create);

static void setTimer(dispatch_source_t source, dispatch_time_t start, uint64_t interval, uint64_t leeway) {
    pthread_mutex_lock(&guard);
    if (armed && executableTimerCaller()) {
        scheduled();
        unsigned i; for (i = 0; i < sourceCount; i++) if (sources[i] == source) break;
        if (i == sourceCount) {
            if (sourceCount == LIMIT) events[5]++;
            else { sources[sourceCount++] = source; }
        }
    }
    pthread_mutex_unlock(&guard);
    dispatch_source_set_timer(source, start, interval, leeway);
}
INTERPOSE(setTimer, dispatch_source_set_timer);

static CVReturn startLink(CVDisplayLinkRef link) {
    pthread_mutex_lock(&guard);
    if (armed && executableTimerCaller()) {
        scheduled();
        unsigned i; for (i = 0; i < linkCount; i++) if (links[i] == link) break;
        if (i == linkCount) {
            if (linkCount == LIMIT) events[5]++;
            else { links[linkCount++] = CVDisplayLinkRetain(link); }
        }
    }
    pthread_mutex_unlock(&guard);
    return CVDisplayLinkStart(link);
}
INTERPOSE(startLink, CVDisplayLinkStart);

// Install each override once. Calling the original IMP preserves subclass and
// superclass behavior. Counting twice through super is harmless: idle is zero.
static void hook(Class cls, SEL sel, int event, BOOL rect, BOOL flag) {
    NSString *key = [NSString stringWithFormat:@"%s/%s", class_getName(cls), sel_getName(sel)];
    if ([hooked containsObject:key]) return;
    [hooked addObject:key];
    Method method = class_getInstanceMethod(cls, sel);
    if (!method) return;
    IMP original = method_getImplementation(method);
    IMP replacement;
    if (rect) replacement = imp_implementationWithBlock(^(id object, NSRect r) {
        if (armed && ([views containsObject:object] || [layers containsObject:object])) events[event]++;
        ((void (*)(id, SEL, NSRect))original)(object, sel, r);
    });
    else if (flag) replacement = imp_implementationWithBlock(^(id object, BOOL value) {
        if (armed && value && ([views containsObject:object] || [layers containsObject:object])) events[event]++;
        ((void (*)(id, SEL, BOOL))original)(object, sel, value);
    });
    else replacement = imp_implementationWithBlock(^(id object) {
        if (armed && ([views containsObject:object] || [layers containsObject:object])) events[event]++;
        ((void (*)(id, SEL))original)(object, sel);
    });
    class_replaceMethod(cls, sel, replacement, method_getTypeEncoding(method));
}

static void watchLayer(CALayer *layer) {
    if (!layer) return;
    [layers addObject:layer];
    hook(object_getClass(layer), @selector(display), 2, NO, NO);
    hook(object_getClass(layer), @selector(layoutSublayers), 1, NO, NO);
    hook(object_getClass(layer), @selector(setNeedsDisplay), 3, NO, NO);
    hook(object_getClass(layer), @selector(setNeedsDisplayInRect:), 3, YES, NO);
    hook(object_getClass(layer), @selector(setNeedsLayout), 3, NO, NO);
    Class cls = object_getClass(layer);
    SEL sel = @selector(addAnimation:forKey:);
    NSString *key = [NSString stringWithFormat:@"animation/%s", class_getName(cls)];
    if (![hooked containsObject:key]) {
        [hooked addObject:key];
        Method method = class_getInstanceMethod(cls, sel);
        IMP original = method_getImplementation(method);
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^(id object, CAAnimation *animation, NSString *name) {
            if (armed && [layers containsObject:object]) events[4]++;
            ((void (*)(id, SEL, id, id))original)(object, sel, animation, name);
        }), method_getTypeEncoding(method));
    }
    for (CALayer *child in layer.sublayers) watchLayer(child);
}
void open_idle_watch_view(void *pointer) {
    NSView *view = (__bridge NSView *)pointer;
    [views addObject:view];
    hook(object_getClass(view), @selector(drawRect:), 0, YES, NO);
    hook(object_getClass(view), @selector(layout), 1, NO, NO);
    hook(object_getClass(view), @selector(updateLayer), 2, NO, NO);
    hook(object_getClass(view), @selector(setNeedsDisplayInRect:), 3, YES, NO);
    hook(object_getClass(view), @selector(setNeedsDisplay:), 3, NO, YES);
    hook(object_getClass(view), @selector(setNeedsLayout:), 3, NO, YES);
    watchLayer(view.layer);
    for (NSView *child in view.subviews) open_idle_watch_view((__bridge void *)child);
}

static void hookDisplayLinkClass(Class cls) {
    if (!cls) return;
    NSString *key = [NSString stringWithFormat:@"displaylink/%s", class_getName(cls)];
    if ([hooked containsObject:key]) return;
    [hooked addObject:key];
    SEL add = @selector(addToRunLoop:forMode:), remove = @selector(removeFromRunLoop:forMode:), invalidate = @selector(invalidate);
    Method m = class_getInstanceMethod(cls, add);
    if (!m) { events[5]++; return; }
    IMP old = method_getImplementation(m);
    class_replaceMethod(cls, add, imp_implementationWithBlock(^(id object, NSRunLoop *loop, NSRunLoopMode mode) {
        if (armed) { [displayLinks addObject:object]; events[4]++; }
        ((void (*)(id, SEL, id, id))old)(object, add, loop, mode);
    }), method_getTypeEncoding(m));
    m = class_getInstanceMethod(cls, remove); IMP oldRemove = method_getImplementation(m);
    class_replaceMethod(cls, remove, imp_implementationWithBlock(^(id object, NSRunLoop *loop, NSRunLoopMode mode) {
        ((void (*)(id, SEL, id, id))oldRemove)(object, remove, loop, mode);
        // Keep it tracked until invalidate: removing one mode need not stop it.
    }), method_getTypeEncoding(m));
    m = class_getInstanceMethod(cls, invalidate); IMP oldInvalidate = method_getImplementation(m);
    class_replaceMethod(cls, invalidate, imp_implementationWithBlock(^(id object) {
        [displayLinks removeObject:object];
        ((void (*)(id, SEL))oldInvalidate)(object, invalidate);
    }), method_getTypeEncoding(m));
}

static void hookDisplayLinks(void) {
    hookDisplayLinkClass(NSClassFromString(@"CADisplayLink"));
    for (Class cls in @[NSView.class, NSWindow.class, NSScreen.class, object_getClass(NSClassFromString(@"CADisplayLink"))]) {
        SEL sel = @selector(displayLinkWithTarget:selector:);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) continue;
        IMP old = method_getImplementation(m);
        class_replaceMethod(cls, sel, imp_implementationWithBlock(^id(id object, id target, SEL action) {
            id link = ((id (*)(id, SEL, id, SEL))old)(object, sel, target, action);
            hookDisplayLinkClass(object_getClass(link));
            return link;
        }), method_getTypeEncoding(m));
    }
}

void open_idle_begin(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ hooked = [NSMutableSet new]; hookDisplayLinks(); });
    views = [NSHashTable weakObjectsHashTable]; layers = [NSHashTable weakObjectsHashTable];
    displayLinks = [NSHashTable weakObjectsHashTable];
    for (int i = 0; i < 6; i++) atomic_store(&events[i], 0);
    armed = YES;
}
void open_idle_reset_events(void) {
    pthread_mutex_lock(&guard);
    for (int i = 0; i < 5; i++) atomic_store(&events[i], 0);
    pthread_mutex_unlock(&guard);
}
int open_idle_ready(void) { return armed && views != nil && layers != nil && displayLinks != nil; }
// 0...5 event counts; 6 live CF timers in any mode; 7 uncancelled dispatch
// timers; 8 running CV links; 9 registered CA/NSView links (even if offscreen-paused).
uint64_t open_idle_count(int index) {
    pthread_mutex_lock(&guard);
    uint64_t count = 0;
    if (index < 6) count = events[index];
    else if (index == 6) {
        for (unsigned i = 0; i < timerCount; i++) {
            if (!CFRunLoopTimerIsValid(timers[i])) continue;
            CFArrayRef modes = CFRunLoopCopyAllModes(loops[i]);
            for (CFIndex n = 0; n < CFArrayGetCount(modes); n++) {
                if (CFRunLoopContainsTimer(loops[i], timers[i], CFArrayGetValueAtIndex(modes, n))) { count++; break; }
            }
            CFRelease(modes);
        }
    } else if (index == 7) {
        for (unsigned i = 0; i < sourceCount; i++) { dispatch_source_t source = sources[i]; if (source && !dispatch_source_testcancel(source)) count++; }
    } else if (index == 8) {
        for (unsigned i = 0; i < linkCount; i++) if (CVDisplayLinkIsRunning(links[i])) count++;
    } else if (index == 9) {
        count = displayLinks.count;
    }
    pthread_mutex_unlock(&guard); return count;
}
void open_idle_end(void) {
    armed = NO;
    for (unsigned i = 0; i < timerCount; i++) { CFRelease(timers[i]); CFRelease(loops[i]); }
    for (unsigned i = 0; i < sourceCount; i++) sources[i] = nil;
    for (unsigned i = 0; i < linkCount; i++) CVDisplayLinkRelease(links[i]);
    timerCount = sourceCount = linkCount = 0;
    views = nil; layers = nil; displayLinks = nil;
}
