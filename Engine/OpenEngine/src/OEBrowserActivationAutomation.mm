#import "OEClient.h"
#include "include/cef_command_line.h"

@implementation OEBrowser (ActivationAutomation)
+ (NSDictionary<NSString*, id>*)activationStateForAutomation:(BOOL)reset {
  auto state = CefGetOpenBrowserActivationDiagnostics(reset);
  if (!state) return @{};
  return @{@"invalidActivationRequests": @(state->GetInt("invalidActivationRequests")),
           @"activeChromeWindowID": @(state->GetInt("activeChromeWindowID"))};
}

- (NSDictionary<NSString*, id>*)probeCloseActivationForAutomation {
  if (!CefCommandLine::GetGlobalCommandLine()->HasSwitch("open-automation")) {
    return @{@"refused": @YES};
  }
  NSWindow* window = self.window;
  CefRefPtr<CefTabStrip> strip = [self oe_tabStripCreatingIfNeeded:NO];
  if (!window || !strip || strip->GetWindowId() < 0) {
    return @{@"prepared": @NO};
  }
  const int before = strip->GetWindowId();
  NSWindow* parking = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(120, 120, 240, 100)
                styleMask:NSWindowStyleMaskTitled
                  backing:NSBackingStoreBuffered defer:NO];
  parking.releasedWhenClosed = NO;
  [parking makeKeyAndOrderFront:nil];
  if (!parking.isKeyWindow) {
    [parking close];
    return @{@"prepared": @NO};
  }
  // Exercise the engine's public Close path, including its synchronous
  // Browser-closed notification and deferred deletion. OEBrowser::close
  // already detaches the host, which would hide this engine lifetime bug.
  strip->Close();
  const int after = strip->GetWindowId();
  strip->Close();  // Repeated close must remain safe.
  [window makeKeyAndOrderFront:nil];
  [parking close];
  return @{@"prepared": @YES, @"before": @(before), @"after": @(after),
           @"closed": @(!strip->IsValid()), @"hostVisible": @(window.isVisible),
           @"hostKey": @(window.isKeyWindow),
           @"diagnostic": [OEBrowser activationStateForAutomation:NO]};
}
@end
