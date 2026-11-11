// Permission-free macOS measurements. Never reads window names or pixels.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <libproc.h>
#import <mach/mach_time.h>
#import <sys/resource.h>
#import <sys/sysctl.h>
#import <CommonCrypto/CommonDigest.h>

static NSString *sha256(NSData *data) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH];
  CC_SHA256(data.bytes, (CC_LONG)data.length, digest);
  NSMutableString *hash = [NSMutableString string];
  for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) [hash appendFormat:@"%02x", digest[i]];
  return hash;
}

static double seconds(uint64_t ticks) {
  mach_timebase_info_data_t tb; mach_timebase_info(&tb);
  return (double)ticks * tb.numer / tb.denom / 1e9;
}
static void emit(id object) {
  NSData *d = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];
  puts([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String); fflush(stdout);
}
static NSArray *windows(void) {
  NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary *w in all) {
    if ([w[(id)kCGWindowLayer] intValue] != 0) continue;
    CGRect r; if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
    if (r.size.width < 30 || r.size.height < 30) continue;
    [out addObject:@{@"pid": w[(id)kCGWindowOwnerPID], @"id": w[(id)kCGWindowNumber],
      @"bounds": @[@(r.origin.x), @(r.origin.y), @(r.size.width), @(r.size.height)]}];
  }
  return out;
}
static NSDictionary *usage(pid_t pid) {
  struct rusage_info_v4 u = {0};
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&u)) return nil;
  char path[PROC_PIDPATHINFO_MAXSIZE] = {0}; proc_pidpath(pid, path, sizeof(path));
  NSString *p = [NSString stringWithUTF8String:path];
  // Store only generic process kind, never arguments (which may contain URLs).
  NSString *kind = [p containsString:@"Renderer"] ? @"renderer" : [p containsString:@"GPU"] ? @"gpu" : @"helper";
  return @{@"pid": @(pid), @"kind": kind, @"birth_ticks": @(u.ri_proc_start_abstime),
    @"stamp_ticks": @(mach_absolute_time()), @"cpu_seconds": @(seconds(u.ri_user_time + u.ri_system_time)),
    @"reaped_cpu_seconds": @(seconds(u.ri_child_user_time + u.ri_child_system_time)),
    @"reaped_wakeups": @(u.ri_child_pkg_idle_wkups + u.ri_child_interrupt_wkups),
    @"wakeups": @(u.ri_pkg_idle_wkups + u.ri_interrupt_wkups), @"footprint_bytes": @(u.ri_phys_footprint),
    @"rss_bytes": @(u.ri_resident_size)};
}
static NSDictionary *snapshot(pid_t root) {
  int size = proc_listallpids(NULL, 0); pid_t *pids = calloc(size + 128, sizeof(pid_t));
  int n = proc_listallpids(pids, (size + 128) * sizeof(pid_t));
  NSMutableDictionary *parents = [NSMutableDictionary dictionary];
  for (int i = 0; i < n; i++) {
    struct proc_bsdinfo b = {0};
    if (proc_pidinfo(pids[i], PROC_PIDTBSDINFO, 0, &b, sizeof(b)) == sizeof(b)) parents[@(pids[i])] = @(b.pbi_ppid);
  }
  free(pids);
  NSMutableSet *tree = [NSMutableSet setWithObject:@(root)];
  for (int pass = 0; pass < 32; pass++) {
    NSUInteger before = tree.count;
    for (NSNumber *pid in parents) if ([tree containsObject:parents[pid]]) [tree addObject:pid];
    if (tree.count == before) break;
  }
  NSMutableArray *out = [NSMutableArray array];
  for (NSNumber *pid in tree) {
    NSMutableDictionary *row = [usage(pid.intValue) mutableCopy];
    if (!row) continue;
    row[@"ppid"] = parents[pid] ?: @0;
    if (pid.intValue == root) row[@"kind"] = @"browser";
    [out addObject:row];
  }
  return @{@"processes": out, @"windows": windows(), @"wall_seconds": @([NSDate timeIntervalSinceReferenceDate] + NSTimeIntervalSince1970),
    @"monotonic_seconds": @(seconds(mach_absolute_time()))};
}
int main(int argc, const char **argv) { @autoreleasepool {
  if (argc < 2) return 2;
  NSString *mode = @(argv[1]);
  if ([mode isEqual:@"snapshot"]) { emit(snapshot(atoi(argv[2]))); return 0; }
  if ([mode isEqual:@"windows"]) { emit(windows()); return 0; }
  if ([mode isEqual:@"metadata"]) {
    NSMutableArray *screens = [NSMutableArray array];
    for (NSScreen *s in NSScreen.screens) {
      NSNumber *number = s.deviceDescription[@"NSScreenNumber"];
      CGDirectDisplayID did = number.unsignedIntValue;
      CGDisplayModeRef dm = CGDisplayCopyDisplayMode(did);
      NSData *icc = s.colorSpace.ICCProfileData;
      if (!dm || icc.length < 128 || icc.length > 4194304 || memcmp((const char *)icc.bytes + 36, "acsp", 4)) {
        if (dm) CGDisplayModeRelease(dm);
        fputs("perf: unsupported display mode or ICC profile\n", stderr); return 1;
      }
      // Same icc-header-v1 scheme as tools/verification/display-environment.swift.
      // Exclude only creation date and profile ID; every colour tag remains.
      NSMutableData *normalized = [icc mutableCopy];
      [normalized resetBytesInRange:NSMakeRange(24, 12)];
      [normalized resetBytesInRange:NSMakeRange(84, 16)];
      [screens addObject:@{@"id": number, @"width": @(s.frame.size.width), @"height": @(s.frame.size.height),
        @"scale": @(s.backingScaleFactor), @"pixels_width": @(CGDisplayModeGetPixelWidth(dm)),
        @"pixels_height": @(CGDisplayModeGetPixelHeight(dm)), @"refresh_hz": @(CGDisplayModeGetRefreshRate(dm)),
        @"builtin": @(CGDisplayIsBuiltin(did)), @"icc_sha256": sha256(icc),
        @"icc_digest_scheme": @"icc-header-v1", @"icc_header_sha256": sha256(normalized)}];
      CGDisplayModeRelease(dm);
    }
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    emit(@{@"screens": screens, @"mach_timebase": @[@(tb.numer), @(tb.denom)]}); return 0;
  }
  if ([mode isEqual:@"terminate"]) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[2])];
    emit(@{@"requested": @([app terminate])}); return 0;
  }
  if ([mode isEqual:@"hide"]) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[2])];
    BOOL activated = [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]];
    BOOL requested = [app hide];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]];
    emit(@{@"requested": @(requested), @"activated": @(activated), @"hidden": @(app.hidden),
      @"active": @(app.active), @"policy": @(app.activationPolicy)}); return 0;
  }
  if ([mode isEqual:@"unhide"]) {
    NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:atoi(argv[2])];
    [app unhide];
    BOOL requested = [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.25]];
    emit(@{@"requested": @(requested), @"hidden": @(app.hidden), @"active": @(app.active)}); return 0;
  }
  if (![mode isEqual:@"launch"]) return 2;
  NSData *d = [NSData dataWithContentsOfFile:@(argv[2])];
  NSDictionary *cfg = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
  NSURL *bundle = [NSURL fileURLWithPath:cfg[@"bundle"]];
  NSWorkspaceOpenConfiguration *c = NSWorkspaceOpenConfiguration.configuration;
  c.createsNewApplicationInstance = [cfg[@"new_instance"] boolValue]; c.activates = YES;
  c.arguments = cfg[@"args"] ?: @[]; c.environment = cfg[@"environment"] ?: @{};
  NSString *executable = [[[NSBundle bundleWithURL:bundle] executablePath] stringByResolvingSymlinksInPath];
  __block NSRunningApplication *app = nil; __block NSError *error = nil; __block BOOL done = NO;
  __block uint64_t completionTicks = 0; __block pid_t completionPID = 0;
  uint64_t request = mach_absolute_time();
  void (^completion)(NSRunningApplication *, NSError *) = ^(NSRunningApplication *a, NSError *e) {
    app = a; error = e; done = YES; completionTicks = mach_absolute_time(); completionPID = a.processIdentifier;
  };
  NSMutableArray *urls = [NSMutableArray array];
  for (NSString *u in cfg[@"urls"]) [urls addObject:[NSURL URLWithString:u]];
  if (urls.count) [NSWorkspace.sharedWorkspace openURLs:urls withApplicationAtURL:bundle configuration:c completionHandler:completion];
  else [NSWorkspace.sharedWorkspace openApplicationAtURL:bundle configuration:c completionHandler:completion];
  uint64_t detected = 0; NSMutableArray *gaps = [NSMutableArray array]; uint64_t last = request;
  NSMutableArray *timeline = [NSMutableArray array]; NSMutableSet *seenStates = [NSMutableSet set];
  NSMutableDictionary *matches = [NSMutableDictionary dictionary];
  pid_t ownerPID = 0; BOOL beforeCompletion = NO;
  NSArray *found = @[];
  while (seconds(mach_absolute_time() - request) < 60) {
    // A 0.1 ms target leaves headroom for window-server query cost; retain actual gaps.
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.0001]];
    uint64_t stamp = mach_absolute_time();
    [gaps addObject:@(seconds(stamp - last) * 1000)]; last = stamp;
    if (done && error) break;
    NSMutableArray *owned = [NSMutableArray array];
    NSArray *all = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListOptionAll | kCGWindowListExcludeDesktopElements, kCGNullWindowID));
    for (NSDictionary *w in all) {
      NSNumber *pid = w[(id)kCGWindowOwnerPID];
      if (!matches[pid]) {
        char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
        matches[pid] = @NO;
        if (proc_pidpath(pid.intValue, path, sizeof(path)))
          matches[pid] = @([[[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath] isEqual:executable]);
      }
      if (![matches[pid] boolValue]) continue;
      ownerPID = pid.intValue;
      CGRect r; if (!CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)w[(id)kCGWindowBounds], &r)) continue;
      NSDictionary *entry = @{@"pid":pid, @"id":w[(id)kCGWindowNumber], @"layer":w[(id)kCGWindowLayer],
        @"onscreen":w[(id)kCGWindowIsOnscreen] ?: @NO, @"alpha":w[(id)kCGWindowAlpha] ?: @0,
        @"bounds":@[@(r.origin.x),@(r.origin.y),@(r.size.width),@(r.size.height)]};
      NSString *state = [entry description];
      if (![seenStates containsObject:state]) {
        [seenStates addObject:state]; NSMutableDictionary *event = [entry mutableCopy];
        event[@"ticks"] = @(mach_absolute_time()); [timeline addObject:event];
      }
      if ([entry[@"layer"] intValue] == 0 && [entry[@"onscreen"] boolValue] &&
          r.size.width > 0 && r.size.height > 0 && [entry[@"alpha"] doubleValue] > 0)
        [owned addObject:@{@"pid":pid,@"id":entry[@"id"],@"bounds":entry[@"bounds"]}];
    }
    if (!app && ownerPID > 0) app = [NSRunningApplication runningApplicationWithProcessIdentifier:ownerPID];
    if (owned.count) {
      detected = mach_absolute_time(); found = owned; beforeCompletion = !done;
      // Do not gate window observation on LaunchServices' completion callback.
      app = [NSRunningApplication runningApplicationWithProcessIdentifier:ownerPID]; break;
    }
    if (done && app.terminated) break;
  }
  pid_t measuredPID = ownerPID > 0 ? ownerPID : app.processIdentifier;
  if (!measuredPID) {
    int capacity = proc_listallpids(NULL, 0) + 128;
    pid_t *candidates = calloc(capacity, sizeof(pid_t));
    int count = proc_listallpids(candidates, capacity * sizeof(pid_t));
    for (int i = 0; i < count; i++) {
      char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
      if (!proc_pidpath(candidates[i], path, sizeof(path))) continue;
      if (![[[NSString stringWithUTF8String:path] stringByResolvingSymlinksInPath] isEqual:executable]) continue;
      NSDictionary *candidate = usage(candidates[i]);
      if ([candidate[@"birth_ticks"] unsignedLongLongValue] >= request) {
        measuredPID = candidates[i]; app = [NSRunningApplication runningApplicationWithProcessIdentifier:measuredPID]; break;
      }
    }
    free(candidates);
  }
  NSMutableDictionary *out = [@{@"pid": @(measuredPID), @"request_ticks": @(request), @"poll_gaps_ms": gaps,
    @"window_detected": @(detected != 0), @"windows": found, @"error": error.localizedDescription ?: @"",
    @"application_hidden": @(app.hidden), @"application_active": @(app.active),
    @"application_terminated": @(app.terminated)} mutableCopy];
  out[@"detector_version"] = @3;
  out[@"target_poll_interval_ms"] = @0.1;
  out[@"completion_received"] = @(done); out[@"completion_ticks"] = @(completionTicks);
  out[@"completion_pid"] = @(completionPID); out[@"window_before_completion"] = @(beforeCompletion);
  out[@"window_timeline"] = timeline;
  NSDictionary *u = usage(measuredPID);
  if (u) {
    uint64_t birth = [u[@"birth_ticks"] unsignedLongLongValue];
    out[@"birth_ticks"] = @(birth);
    if (completionTicks) out[@"completion_after_birth_ms"] = @(seconds(completionTicks - birth) * 1000);
    for (NSMutableDictionary *event in timeline)
      event[@"after_birth_ms"] = @(seconds([event[@"ticks"] unsignedLongLongValue] - birth) * 1000);
    out[@"birth_wall_seconds"] = @([NSDate date].timeIntervalSince1970 - seconds(mach_absolute_time() - birth));
    if (detected) out[@"window_ms"] = @(seconds(detected - birth) * 1000);
    if (detected) out[@"request_window_ms"] = @(seconds(detected - request) * 1000);
  }
  NSArray *sorted = [gaps sortedArrayUsingSelector:@selector(compare:)];
  if (sorted.count) {
    out[@"poll_p50_ms"] = sorted[sorted.count / 2];
    out[@"poll_p95_ms"] = sorted[(NSUInteger)((sorted.count - 1) * .95)];
    out[@"poll_max_ms"] = sorted.lastObject;
    out[@"poll_count"] = @(sorted.count);
    out[@"last_poll_gap_ms"] = gaps.lastObject;
    out[@"average_poll_hz"] = @(sorted.count / seconds(mach_absolute_time() - request));
  }
  emit(out); return detected ? 0 : 1;
}}
