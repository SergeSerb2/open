#import <AppKit/AppKit.h>
#import <objc/runtime.h>

// Opt-in negative proof for F19. The old click helper queues mouse-up before
// directly sending mouse-down. Force the queued up to run first, which leaves
// the control gesture waiting for its up and lets AppKit filter Return. A native
// queued down is NSApp.currentEvent, so the fixed click never takes this path.
// This probe does not intercept, replace, or consume a keyboard event.
static IMP originalSendEvent;

static void forceEarlyMouseUp(id self, SEL command, NSEvent *event) {
  if (event.type == NSEventTypeLeftMouseDown && NSApp.currentEvent != event) {
    NSView *root = event.window.contentView;
    NSPoint point = [root.superview convertPoint:event.locationInWindow fromView:nil];
    NSView *hit = [root hitTest:point];
    BOOL findQuery = NO;
    for (NSView *view = hit; view; view = view.superview) {
      if (strstr(object_getClassName(view), "FindQueryField") &&
          [view isKindOfClass:NSTextField.class] &&
          [[(NSTextField *)view stringValue] isEqualToString:@"orbit"]) {
        findQuery = YES;
      }
    }
    if (findQuery) {
      NSEvent *up = [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp
        untilDate:NSDate.distantPast inMode:NSDefaultRunLoopMode dequeue:YES];
      if (up && up.windowNumber == event.windowNumber) {
        fprintf(stderr, "F19_FORCE early mouse-up before direct mouse-down\n");
        ((void (*)(id, SEL, id))originalSendEvent)(self, command, up);
      } else if (up) {
        [NSApp postEvent:up atStart:YES];
      }
    }
  }
  ((void (*)(id, SEL, id))originalSendEvent)(self, command, event);
}

__attribute__((constructor)) static void install(void) {
  Class application = NSClassFromString(@"OEApplication");
  Method method = class_getInstanceMethod(application, @selector(sendEvent:));
  if (!method) return;
  originalSendEvent = method_getImplementation(method);
  class_replaceMethod(application, @selector(sendEvent:), (IMP)forceEarlyMouseUp,
                      method_getTypeEncoding(method));
}
