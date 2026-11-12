// Read-only, batched AX geometry for the authorized performance sessions.
#import <Foundation/Foundation.h>
#import <ApplicationServices/ApplicationServices.h>

static double deadline;
static BOOL complete=YES;
static NSArray *keys;
static BOOL allowWeb=NO;
static BOOL webGeometryOnly=NO;
static int webNodes=0;
static double webDeadline=0;
static id attr(AXUIElementRef e, CFStringRef key) {
  CFTypeRef value=NULL;
  if (AXUIElementCopyAttributeValue(e,key,&value)!=kAXErrorSuccess)return nil;
  return CFBridgingRelease(value);
}
static NSDictionary *node(AXUIElementRef e, int depth, int maxDepth) {
  if (CFAbsoluteTimeGetCurrent()>deadline) {complete=NO;return @{};}
  if (webDeadline>0 && (webNodes>=3000 || CFAbsoluteTimeGetCurrent()>webDeadline)) {
    complete=NO;return @{};
  }
  CFArrayRef values=NULL;
  if (AXUIElementCopyMultipleAttributeValues(e,(__bridge CFArrayRef)keys,0,&values)!=kAXErrorSuccess)return @{};
  NSArray *v=CFBridgingRelease(values);
  if (v.count!=keys.count)return @{};
  BOOL webRoot=[v[0] isEqual:@"AXWebArea"];
  BOOL inWeb=webDeadline>0;
  if (webRoot) {
    NSString *title=[v[1] isKindOfClass:NSString.class]?v[1]:@"";
    BOOL synthetic=[title hasPrefix:@"Perf local "] || [title isEqual:@"Open performance DOM fixture"] ||
      [title isEqual:@"Tab Discards"] || [title isEqual:@"Discards"];
    id address=allowWeb && !synthetic?attr(e,kAXURLAttribute):nil;
    NSURL *url=[address isKindOfClass:NSURL.class]?address:
      ([address isKindOfClass:NSString.class]?[NSURL URLWithString:address]:nil);
    BOOL discards=[@[@"chrome",@"arc"] containsObject:url.scheme] &&
      [@[@"discards",@"debug-webuis-disabled",@"chrome-urls"] containsObject:url.host];
    synthetic=synthetic || discards;
    if (allowWeb && synthetic) {webDeadline=CFAbsoluteTimeGetCurrent()+3;webNodes=0;inWeb=YES;}
    else return @{@"role":@"AXWebArea",@"content_omitted":@YES,@"title":title,
      @"url_scheme":url.scheme?:@"",@"url_host":url.host?:@""};
  }
  if (inWeb && (++webNodes>3000 || CFAbsoluteTimeGetCurrent()>webDeadline)) {complete=NO;return @{};}
  NSMutableDictionary *d=[NSMutableDictionary dictionary];
  for (NSUInteger i=0;i<4;i++) {
    if ([v[i] isKindOfClass:NSString.class] && [v[i] length])
      d[@[@"role",@"title",@"desc",@"value"][i]]=v[i];
    else if (i==3 && [v[i] isKindOfClass:NSNumber.class])d[@"value"]=[v[i] stringValue];
  }
  CGPoint p;CGSize s;
  if (CFGetTypeID((__bridge CFTypeRef)v[4])==AXValueGetTypeID() &&
      CFGetTypeID((__bridge CFTypeRef)v[5])==AXValueGetTypeID() &&
      AXValueGetValue((__bridge AXValueRef)v[4],kAXValueCGPointType,&p) &&
      AXValueGetValue((__bridge AXValueRef)v[5],kAXValueCGSizeType,&s))
    d[@"frame"]=@[@(p.x),@(p.y),@(s.width),@(s.height)];
  BOOL skipNativeList=(!inWeb && ([v[0] isEqual:@"AXOutline"] || [v[0] isEqual:@"AXList"])) || (webRoot && webGeometryOnly);
  if (depth<maxDepth && !skipNativeList && [v[6] isKindOfClass:NSArray.class]) {
    NSMutableArray *children=[NSMutableArray array];
    for(id child in v[6]) {
      if (CFAbsoluteTimeGetCurrent()>deadline) {complete=NO;break;}
      if (inWeb && (webNodes>=3000 || CFAbsoluteTimeGetCurrent()>webDeadline)) {complete=NO;break;}
      NSDictionary *next=node((__bridge AXUIElementRef)child,depth+1,inWeb?MIN(maxDepth,30):maxDepth);
      if (next.count)[children addObject:next];
    }
    d[@"children"]=children;
  }
  if (webRoot)webDeadline=0;
  return d;
}
int main(int argc,const char **argv) { @autoreleasepool {
  if (argc<2)return 2;
  AXUIElementRef app=AXUIElementCreateApplication(atoi(argv[1]));
  AXUIElementSetMessagingTimeout(app,.3);
  if (argc>3 && !strcmp(argv[2],"manual")) {
    id original=attr(app,CFSTR("AXManualAccessibility"));
    BOOL readable=[original isKindOfClass:NSNumber.class];
    AXError status=AXUIElementSetAttributeValue(app,CFSTR("AXManualAccessibility"),
      !strcmp(argv[3],"true")?kCFBooleanTrue:kCFBooleanFalse);
    NSDictionary *receipt=@{@"original":readable?original:@"unreadable (write-only)",@"set_success":@(status==kAXErrorSuccess),@"status":@(status)};
    NSData *data=[NSJSONSerialization dataWithJSONObject:receipt options:0 error:nil];
    fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);CFRelease(app);return status==kAXErrorSuccess?0:4;
  }
  webGeometryOnly=argc>3 && !strcmp(argv[3],"web-frame");
  allowWeb=argc>3 && (!strcmp(argv[3],"web") || webGeometryOnly);
  keys=@[(__bridge id)kAXRoleAttribute,(__bridge id)kAXTitleAttribute,
    (__bridge id)kAXDescriptionAttribute,(__bridge id)kAXValueAttribute,
    (__bridge id)kAXPositionAttribute,(__bridge id)kAXSizeAttribute,
    (__bridge id)kAXChildrenAttribute];
  deadline=CFAbsoluteTimeGetCurrent()+18;
  id wins=attr(app,kAXWindowsAttribute);NSMutableArray *result=[NSMutableArray array];
  if ([wins isKindOfClass:NSArray.class])for(id win in wins)
    [result addObject:node((__bridge AXUIElementRef)win,0,argc>2?atoi(argv[2]):22)];
  NSData *data=[NSJSONSerialization dataWithJSONObject:@{@"windows":result,@"complete":@(complete)} options:NSJSONWritingSortedKeys error:nil];
  fwrite(data.bytes,1,data.length,stdout);fputc('\n',stdout);CFRelease(app);
  return complete?0:3;
} }
