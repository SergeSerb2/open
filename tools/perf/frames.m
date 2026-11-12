// App-scoped ScreenCaptureKit detector. Emits numbers only; never writes pixels.
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <mach/mach_time.h>

static double ms(uint64_t n) { mach_timebase_info_data_t t; mach_timebase_info(&t); return (double)n*t.numer/t.denom/1e6; }
static void emit(NSDictionary *o) { @synchronized(NSFileHandle.fileHandleWithStandardOutput) {
  NSData *d=[NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
  [NSFileHandle.fileHandleWithStandardOutput writeData:d]; [NSFileHandle.fileHandleWithStandardOutput writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]];
}}
static NSMutableData *sample(CVPixelBufferRef pixel, CGRect roi, NSUInteger stride) {
  if(!pixel)return nil;
  CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
  const unsigned char *base=CVPixelBufferGetBaseAddress(pixel);size_t row=CVPixelBufferGetBytesPerRow(pixel);
  NSUInteger x0=MAX(0,(NSInteger)roi.origin.x),y0=MAX(0,(NSInteger)roi.origin.y);
  NSUInteger x1=MIN(CVPixelBufferGetWidth(pixel),(NSUInteger)CGRectGetMaxX(roi));
  NSUInteger y1=MIN(CVPixelBufferGetHeight(pixel),(NSUInteger)CGRectGetMaxY(roi));
  if(x1<=x0||y1<=y0){CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);return nil;}
  NSUInteger count=((x1-x0+stride-1)/stride)*((y1-y0+stride-1)/stride);
  // At most 64 MiB per allocation; accepted 2560×1440/stride2 uses 3,686,400 bytes.
  if(count>16*1024*1024){CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);return nil;}
  NSMutableData *data=[NSMutableData dataWithLength:count*4];uint32_t *dest=data.mutableBytes;NSUInteger i=0;
  for(NSUInteger y=y0;y<y1;y+=stride)for(NSUInteger x=x0;x<x1;x+=stride)dest[i++]=*(const uint32_t *)(base+y*row+x*4);
  CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);return data;
}
static NSString *signature(NSData *data) {
  const unsigned char *bytes=data.bytes;uint64_t hash=1469598103934665603ULL;
  for(NSUInteger i=0;i<data.length;i++){hash^=bytes[i];hash*=1099511628211ULL;}
  return [NSString stringWithFormat:@"%016llx",hash];
}
@interface Detector:NSObject<SCStreamOutput,SCStreamDelegate>
@property SCStream *stream;
@property CVPixelBufferRef cached;
@property dispatch_queue_t queue;
@property NSMutableData *previous;
@property NSMutableData *baseline;
@property NSDictionary *trial;
@property NSMutableArray *frames;
@property NSMutableArray *changes;
@property uint64_t armTicks;
@property uint64_t inputTicks;
@property uint64_t endTicks;
@property uint64_t lastFrame;
@property uint64_t serial;
@property CGRect roi;
@property NSUInteger width;
@property NSUInteger height;
@property NSUInteger stride;
@property double hz;
@end
@implementation Detector
-(void)stream:(SCStream *)s didStopWithError:(NSError *)e { emit(@{@"event":@"error",@"error":e.localizedDescription}); }
-(void)finish {
  if (!_trial) return;
  NSMutableDictionary *r=[@{@"event":@"result",@"id":_trial[@"id"] ?: @0,@"input_ticks":@(_inputTicks),
    @"armed_ticks":@(_armTicks),@"frames":_frames ?: @[],@"changes":_changes ?: @[],
    @"requested_hz":@(_hz),@"roi":@[@(_roi.origin.x),@(_roi.origin.y),@(_roi.size.width),@(_roi.size.height)],
    @"sample_stride":@(_stride),@"ended_ticks":@(mach_absolute_time())} mutableCopy];
  if(_baseline)r[@"baseline_signature"]=signature(_baseline);
  if (_changes.count) {
    r[@"first_changed_ms"]=@(ms([_changes.firstObject unsignedLongLongValue]-_inputTicks));
    r[@"last_changed_ms"]=@(ms([_changes.lastObject unsignedLongLongValue]-_inputTicks));
  }
  if (_frames.count) {
    NSString *expected=_trial[@"target_signature"] ?: _frames.lastObject[@"signature"];
    r[@"final_signature"]=_frames.lastObject[@"signature"];
    r[@"target_signature"]=expected;
    for(NSDictionary *frame in _frames)if([frame[@"signature"] isEqual:expected]) {
      r[@"first_final_content_ms"]=@(ms([frame[@"ticks"] unsignedLongLongValue]-_inputTicks));break;
    }
  }
  emit(r); _trial=nil;_baseline=nil;_frames=nil;_changes=nil;
}
-(void)command:(NSDictionary *)c {
  if(![c isKindOfClass:NSDictionary.class]){emit(@{@"event":@"error",@"error":@"Expected command object"});return;}
  for(id key in c)if(![@[@"cmd",@"id",@"roi",@"duration_ms",@"target_signature",@"ticks"] containsObject:key]){emit(@{@"event":@"error",@"error":@"Unknown command field"});return;}
  for(id key in @[@"id",@"duration_ms",@"ticks"])if(c[key]&&![c[key] isKindOfClass:NSNumber.class]){emit(@{@"event":@"error",@"error":@"Expected command number"});return;}
  if(c[@"target_signature"]&&(![c[@"target_signature"] isKindOfClass:NSString.class]||[c[@"target_signature"] length]!=16)){emit(@{@"event":@"error",@"error":@"Invalid target signature"});return;}
  NSString *action=c[@"cmd"];
  if ([action isEqual:@"quit"]) { [_stream stopCaptureWithCompletionHandler:^(NSError *e){exit(e?1:0);}]; return; }
  if ([action isEqual:@"stop"]) {[self finish];return;}
  if ([action isEqual:@"mark"]) {
    if (!_trial || ![c[@"id"] isEqual:_trial[@"id"]]) {emit(@{@"event":@"error",@"error":@"No matching armed trial"});return;}
    _inputTicks=[c[@"ticks"] unsignedLongLongValue];
    NSIndexSet *early=[_frames indexesOfObjectsPassingTest:^BOOL(NSDictionary *v,NSUInteger i,BOOL *stop){return [v[@"ticks"] unsignedLongLongValue]<self.inputTicks;}];
    [_frames removeObjectsAtIndexes:early];
    early=[_changes indexesOfObjectsPassingTest:^BOOL(NSNumber *v,NSUInteger i,BOOL *stop){return v.unsignedLongLongValue<self.inputTicks;}];
    [_changes removeObjectsAtIndexes:early];
    _endTicks=_inputTicks+(uint64_t)([(_trial[@"duration_ms"] ?: @1500) doubleValue]/ms(1));
    emit(@{@"event":@"marked",@"id":c[@"id"]});return;
  }
  if (![action isEqual:@"arm"] || _trial) {emit(@{@"event":@"error",@"error":@"Unknown command or active trial"});return;}
  NSArray *r=c[@"roi"];
  double duration=[(c[@"duration_ms"] ?: @1500) doubleValue];
  if(!isfinite(duration)||duration<1||duration>10000 || (r && (![r isKindOfClass:NSArray.class]||r.count!=4))){emit(@{@"event":@"error",@"error":@"Invalid region or duration limit"});return;}
  for(id v in r)if(![v isKindOfClass:NSNumber.class]||!isfinite([v doubleValue])||fabs([v doubleValue])>16384){emit(@{@"event":@"error",@"error":@"Invalid region number"});return;}
  _roi=r?CGRectMake([r[0] doubleValue],[r[1] doubleValue],[r[2] doubleValue],[r[3] doubleValue]):CGRectMake(0,0,_width,_height);
  _roi=CGRectIntersection(_roi,CGRectMake(0,0,_width,_height));
  if (CGRectIsNull(_roi) || _roi.size.width<4 || _roi.size.height<4) {emit(@{@"event":@"error",@"error":@"Invalid target region"});return;}
  if(ceil(_roi.size.width/_stride)*ceil(_roi.size.height/_stride)>16*1024*1024){emit(@{@"event":@"error",@"error":@"Region allocation limit"});return;}
  _armTicks=mach_absolute_time();_inputTicks=0;_endTicks=0;_trial=c;_frames=[NSMutableArray array];_changes=[NSMutableArray array];
  _baseline=sample(_cached,_roi,_stride);_previous=_baseline;
  if(_baseline)emit(@{@"event":@"armed",@"id":_trial[@"id"] ?: @0,@"baseline_ticks":@(_lastFrame),@"baseline_signature":signature(_baseline),@"samples":@(_baseline.length/4)});
}
-(void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)sb ofType:(SCStreamOutputType)type {
  if (type!=SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sb))return;
  NSArray *attachments=CFBridgingRelease(CMSampleBufferGetSampleAttachmentsArray(sb,YES)?CFRetain(CMSampleBufferGetSampleAttachmentsArray(sb,YES)):NULL);
  NSDictionary *info=attachments.firstObject;
  NSInteger status=[info[SCStreamFrameInfoStatus] integerValue];
  if (status!=SCFrameStatusComplete && status!=SCFrameStatusStarted)return;
  uint64_t stamp=[info[SCStreamFrameInfoDisplayTime] unsignedLongLongValue];
  if (!stamp) {emit(@{@"event":@"error",@"error":@"Missing SCK displayTime"});return;}
  _lastFrame=stamp;_serial++;
  CVPixelBufferRef pixel=CMSampleBufferGetImageBuffer(sb);if(!pixel)return;
  if(_cached)CVPixelBufferRelease(_cached);_cached=CVPixelBufferRetain(pixel);
  if (!_trial)return;
  NSMutableData *data=sample(pixel,_roi,_stride);if(!data)return;
  if (!_baseline) {
    _baseline=data;_previous=data;
    emit(@{@"event":@"armed",@"id":_trial[@"id"] ?: @0,@"baseline_ticks":@(stamp),@"baseline_signature":signature(_baseline),@"samples":@(data.length/4)});return;
  }
  if (!_inputTicks || stamp<_inputTicks) {_baseline=data;_previous=data;return;}
  if (_endTicks && stamp>_endTicks) {[self finish];return;}
  const unsigned char *a=data.bytes,*b=_previous.bytes;NSUInteger count=MIN(data.length,_previous.length)/4,changed=0;
  for(NSUInteger i=0;i<count;i++) {NSUInteger j=i*4;int delta=abs(a[j]-b[j])+abs(a[j+1]-b[j+1])+abs(a[j+2]-b[j+2]);if(delta>=24)changed++;}
  double fraction=count?(double)changed/count:0;
  double callbackLag=(double)((int64_t)mach_absolute_time()-(int64_t)stamp)*ms(1);
  if(_frames.count>=4096){emit(@{@"event":@"error",@"error":@"Frame count limit"});[self finish];return;}
  [_frames addObject:@{@"ticks":@(stamp),@"changed_fraction":@(fraction),@"signature":signature(data),@"callback_lag_ms":@(callbackLag)}];
  if(changed>=MAX(4,(NSUInteger)ceil(count*.0005))) [_changes addObject:@(stamp)];
  _previous=data;
}
@end
int main(int argc,const char **argv) {@autoreleasepool {
  if(argc<2)return 2;
  NSNumber *size=[[NSFileManager.defaultManager attributesOfItemAtPath:@(argv[1]) error:nil] objectForKey:NSFileSize];
  if(!size||size.unsignedLongLongValue>4096){emit(@{@"event":@"error",@"error":@"Configuration byte limit"});return 2;}
  NSDictionary *cfg=[NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:@(argv[1])] options:0 error:nil];
  if([cfg isKindOfClass:NSDictionary.class])for(id key in @[@"pid",@"display_id",@"stride",@"hz"])if(![cfg[key] isKindOfClass:NSNumber.class]){emit(@{@"event":@"error",@"error":@"Expected configuration number"});return 2;}
  if(![cfg isKindOfClass:NSDictionary.class]||[cfg[@"pid"] intValue]<=0||[cfg[@"stride"] intValue]<1||[cfg[@"stride"] intValue]>16||!isfinite([cfg[@"hz"] doubleValue])||[cfg[@"hz"] doubleValue]<1||[cfg[@"hz"] doubleValue]>480){emit(@{@"event":@"error",@"error":@"Invalid configuration"});return 2;}
  for(id key in cfg)if(![@[@"pid",@"display_id",@"stride",@"hz"] containsObject:key]){emit(@{@"event":@"error",@"error":@"Unknown configuration field"});return 2;}
  // Never request permission or open its dialog. A denial is a hard stop.
  if(!CGPreflightScreenCaptureAccess()){emit(@{@"event":@"error",@"error":@"Screen Recording preflight denied; no prompt requested"});return 77;}
  Detector *d=[Detector new];d.queue=dispatch_queue_create("open.perf.frames",DISPATCH_QUEUE_SERIAL);
  d.stride=MAX(1,[cfg[@"stride"] unsignedIntegerValue]);d.hz=[cfg[@"hz"] doubleValue]?:240;
  [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:NO completionHandler:^(SCShareableContent *content,NSError *error){
    if(error){emit(@{@"event":@"error",@"error":error.localizedDescription});exit(77);}
    SCDisplay *display=nil;for(SCDisplay *item in content.displays)if(item.displayID==[cfg[@"display_id"] unsignedIntValue])display=item;
    SCRunningApplication *app=nil;for(SCRunningApplication *item in content.applications)if(item.processID==[cfg[@"pid"] intValue])app=item;
    if(!display||!app){emit(@{@"event":@"error",@"error":@"Exact display or app missing"});exit(1);}
    d.width=display.width;d.height=display.height;
    if(d.width>8192||d.height>8192){emit(@{@"event":@"error",@"error":@"Display dimension limit"});exit(2);}
    SCContentFilter *filter=[[SCContentFilter alloc]initWithDisplay:display includingApplications:@[app] exceptingWindows:@[]];filter.includeMenuBar=NO;
    // SCK documents zero as the display's native refresh rate. A nonzero
    // minimum is a throttle and can quantize a nominal 240 Hz request.
    SCStreamConfiguration *c=[SCStreamConfiguration new];c.width=d.width;c.height=d.height;c.minimumFrameInterval=kCMTimeZero;
    c.queueDepth=8;c.pixelFormat=kCVPixelFormatType_32BGRA;c.showsCursor=NO;c.capturesAudio=NO;c.ignoreShadowsDisplay=YES;
    d.stream=[[SCStream alloc]initWithFilter:filter configuration:c delegate:d];NSError *e=nil;
    if(![d.stream addStreamOutput:d type:SCStreamOutputTypeScreen sampleHandlerQueue:d.queue error:&e]){emit(@{@"event":@"error",@"error":e.localizedDescription});exit(1);}
    [d.stream startCaptureWithCompletionHandler:^(NSError *e){if(e){emit(@{@"event":@"error",@"error":e.localizedDescription});exit(77);}
      emit(@{@"event":@"ready",@"width":@(d.width),@"height":@(d.height),@"hz":@(d.hz),@"owner_only":@YES});
    }];
  }];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
    char line[4097];
    while(fgets(line,sizeof(line),stdin)){
      if(!strchr(line,'\n')&&!feof(stdin)){emit(@{@"event":@"error",@"error":@"Command byte limit"});exit(2);}
      NSData *bytes=[[@(line) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] dataUsingEncoding:NSUTF8StringEncoding];
      NSDictionary *cmd=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];if(!cmd){emit(@{@"event":@"error",@"error":@"Malformed input"});continue;}
      dispatch_sync(d.queue,^{[d command:cmd];});
    }dispatch_async(d.queue,^{[d.stream stopCaptureWithCompletionHandler:^(NSError *e){exit(0);}];});
  });
  dispatch_source_t timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,d.queue);
  dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC),10*NSEC_PER_MSEC,NSEC_PER_MSEC);
  dispatch_source_set_event_handler(timer,^{if(d.trial&&d.inputTicks&&d.endTicks&&mach_absolute_time()>d.endTicks)[d finish];});dispatch_resume(timer);
  [NSRunLoop.currentRunLoop run];
}return 0;}
