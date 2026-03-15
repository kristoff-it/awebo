#import "utils.h"
#import "video-format.h"
#import "video.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>

CVPixelBufferRef aweboScreenCaptureSwapFrame(void *, CVPixelBufferRef);
__attribute__((weak)) CVPixelBufferRef
aweboScreenCaptureSwapFrame(void *userdata, CVPixelBufferRef ref) {
  __builtin_unreachable();
}

void aweboScreenCaptureEncodedVideoFrame(void *, const char *, size_t, BOOL);
__attribute__((weak)) void aweboScreenCaptureEncodedVideoFrame(void *userdata,
                                                               const char *data,
                                                               size_t len,
                                                               BOOL keyframe) {
  __builtin_unreachable();
};

void aweboScreenCaptureUpdate(void *, UInt32);
__attribute__((weak)) void aweboScreenCaptureUpdate(void *userdata,
                                                    UInt32 new) {
  __builtin_unreachable();
};

// --------------------------

@interface ScreenCaptureManager : NSObject <SCContentSharingPickerObserver,
                                            SCStreamDelegate, SCStreamOutput>
@property(strong) SCContentSharingPicker *picker;
@property(strong) SCStream *stream;
@property void *userdata;

@property(nonatomic, assign) VTCompressionSessionRef compressionSession;
@property(nonatomic, assign) CMVideoCodecType selectedCodec;
@property(nonatomic, assign) CMTime lastKeyframePts;

@end

@implementation ScreenCaptureManager

void *screenCaptureManagerInit(void *userdata) {
  NSLog(@"creating capture manager");
  ScreenCaptureManager *manager = [[ScreenCaptureManager alloc] init];
  manager.userdata = userdata;
  manager.selectedCodec = [manager bestAvailableCodec];

  return (__bridge_retained void *)manager;
}

void screenCaptureManagerDeinit(void *ptr) {
  ScreenCaptureManager *scm = (__bridge_transfer ScreenCaptureManager *)ptr;
  DDAssertLastRef(scm);
}

void screenCaptureManagerShowPicker(void *manager) {
  ScreenCaptureManager *self = (__bridge ScreenCaptureManager *)manager;
  [self showPicker];
}

- (void)showPicker {
  NSLog(@"showing picker!");
  // Create the picker
  self.picker = [SCContentSharingPicker sharedPicker];

  // Set yourself as the observer
  [self.picker addObserver:self];

  // Show the picker (this is async, returns immediately)
  self.picker.active = YES;
  [self.picker present];

  // Alternative: Present from a specific window
  // [self.picker presentPickerForWindow:myNSWindow];
}

// MARK: - SCContentSharingPickerObserver

- (void)contentSharingPicker:(SCContentSharingPicker *)picker
          didCancelForStream:(SCStream *)stream {
  NSLog(@"User cancelled picker");
  aweboScreenCaptureUpdate(self.userdata, 0);
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker
         didUpdateWithFilter:(SCContentFilter *)filter
                   forStream:(SCStream *)stream {
  NSLog(@"User selected content");

  aweboScreenCaptureUpdate(self.userdata, 2);
  [self startCaptureWithFilter:filter];
}

- (void)contentSharingPickerStartDidFailWithError:(NSError *)error {
  NSLog(@"Picker failed to start: %@", error);
  aweboScreenCaptureUpdate(self.userdata, 0);
}

// MARK: - Start Capture

- (void)startCaptureWithFilter:(SCContentFilter *)filter {

  [self setupCompressionSession];
  // Configure the stream
  SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
  config.width = 1920;
  config.height = 1080;
  config.minimumFrameInterval = CMTimeMake(1, 30); // 30 fps
  config.pixelFormat = kCVPixelFormatType_32BGRA;
  // config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
  config.ignoreGlobalClipDisplay = true;
  config.ignoreGlobalClipSingleWindow = true;
  config.scalesToFit = true;
  // config.showMouseClicks = false;
  // config.showsCursor = true;

  // AUDIO CONFIGURATION
  config.capturesAudio = NO;
  config.sampleRate = 48000;
  config.channelCount = 2; // Stereo

  // Exclude your own app's audio from capture
  config.excludesCurrentProcessAudio = YES;

  // Create stream with the filter from picker
  self.stream = [[SCStream alloc] initWithFilter:filter
                                   configuration:config
                                        delegate:self];
  // Add output handler
  dispatch_queue_t queue = dispatch_queue_create(
      "awebo.awebo.awebo.screenshare", DISPATCH_QUEUE_SERIAL);

  NSError *error = nil;
  [self.stream addStreamOutput:self
                          type:SCStreamOutputTypeScreen
            sampleHandlerQueue:queue
                         error:&error];

  if (error) {
    NSLog(@"Failed to add video output: %@", error);
    aweboScreenCaptureUpdate(self.userdata, 0);
    return;
  }

  // Add AUDIO output
  [self.stream addStreamOutput:self
                          type:SCStreamOutputTypeAudio
            sampleHandlerQueue:queue
                         error:&error];

  if (error) {
    NSLog(@"Failed to add audio output: %@", error);
    aweboScreenCaptureUpdate(self.userdata, 0);
    return;
  }

  // Start the stream
  NSLog(@"stream is nil? %p", self.stream);
  [self.stream startCaptureWithCompletionHandler:^(NSError *error) {
    if (error) {
      aweboScreenCaptureUpdate(self.userdata, 0);
      NSLog(@"Failed to start capture: %@", error);
    } else {
      NSLog(@"Capture started successfully");
    }
  }];
}

// MARK: - SCStreamDelegate & SCStreamOutput

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  NSLog(@"Stream stopped: %@", error);
  aweboScreenCaptureUpdate(self.userdata, 0);
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (type == SCStreamOutputTypeScreen) {
    // Get the frame
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    CMTime duration = CMSampleBufferGetDuration(sampleBuffer);

    VTEncodeInfoFlags flags;
    OSStatus status = VTCompressionSessionEncodeFrame(
        _compressionSession, pixelBuffer, pts, duration,
        NULL, // frameProperties (nil = defaults)
        NULL, // sourceFrameRefCon
        &flags);

    if (status != noErr) {
      NSLog(@"VTCompressionSessionEncodeFrame failed: %d", (int)status);
    }
    [self processVideoFrame:pixelBuffer];

  } else if (type == SCStreamOutputTypeAudio) {
    // Audio sample
    [self processAudioBuffer:sampleBuffer];
  }
}

- (void)processVideoFrame:(CVPixelBufferRef)pixelBuffer {
  CVPixelBufferRetain(pixelBuffer);
  CVPixelBufferRef dropped_frame =
      aweboScreenCaptureSwapFrame(self.userdata, pixelBuffer);

  if (dropped_frame) {
    CVPixelBufferRelease(dropped_frame);
  }
}

- (void)processAudioBuffer:(CMSampleBufferRef)audioBuffer {
  CMBlockBufferRef blockBuffer = CMSampleBufferGetDataBuffer(audioBuffer);

  size_t lengthAtOffset;
  size_t totalLength;
  char *dataPointer;

  OSStatus status = CMBlockBufferGetDataPointer(blockBuffer, 0, &lengthAtOffset,
                                                &totalLength, &dataPointer);

  if (status == kCMBlockBufferNoErr) {
    // dataPointer now points to raw audio data
    // totalLength is the size in bytes

    // Get format info
    CMFormatDescriptionRef format =
        CMSampleBufferGetFormatDescription(audioBuffer);
    const AudioStreamBasicDescription *asbd =
        CMAudioFormatDescriptionGetStreamBasicDescription(format);

    // Typically:
    // asbd->mSampleRate = 48000
    // asbd->mChannelsPerFrame = 2
    // asbd->mFormatID = kAudioFormatLinearPCM
    // asbd->mFormatFlags = kAudioFormatFlagIsFloat

    // Copy or encode the audio
    // memcpy(yourBuffer, dataPointer, totalLength);
    // NSLog(@"received audio sample rate: %f", asbd->mSampleRate);
  } else {
    NSLog(@"error getting audio data: %i", (int)status);
  }
}

Image frameGetImage(CVPixelBufferRef pixelBuffer) {
  // Lock the pixel buffer to get access to the memory
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  // Get buffer info
  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);
  size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

  // Get pointer to the pixel data
  void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
  uint8_t *pixels = (uint8_t *)baseAddress;
  return (Image){width, height, pixels};
}

void frameDeinit(CVPixelBufferRef pixelBuffer) {
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pixelBuffer);
}

// MARK: - Cleanup
void screenCaptureManagerStopCapture(void *manager) {
  ScreenCaptureManager *self = (__bridge ScreenCaptureManager *)manager;
  aweboScreenCaptureUpdate(self.userdata, 0);
  [self stopCapture];
}

- (void)stopCapture {
  [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
    if (error) {
      NSLog(@"Error stopping: %@", error);
    }
  }];

  if (_compressionSession) {
    VTCompressionSessionCompleteFrames(_compressionSession, kCMTimeIndefinite);
    VTCompressionSessionInvalidate(_compressionSession);
    CFRelease(_compressionSession);
    _compressionSession = NULL;
  }

  [self.picker removeObserver:self];
}

- (void)setupCompressionSession {
  self.lastKeyframePts = CMTimeMake(0, 1);
  BOOL isHEVC = (self.selectedCodec == kCMVideoCodecType_HEVC);
  NSLog(@"Using codec: %@", isHEVC ? @"H.265 (HEVC)" : @"H.264 (AVC)");

  OSStatus status = VTCompressionSessionCreate(
      kCFAllocatorDefault,
      1920, // width
      1080, // height
      self.selectedCodec,
      NULL,                  // encoderSpecification (nil = let VT choose)
      NULL,                  // sourceImageBufferAttributes
      NULL,                  // compressedDataAllocator
      EncodedFrameCallback,  // output callback
      (__bridge void *)self, // refcon
      &_compressionSession);

  if (status != noErr) {
    NSLog(@"VTCompressionSessionCreate failed: %d", (int)status);
    return;
  }

  // ── Common properties ──────────────────────────────────────────────────

  VTSessionSetProperty(_compressionSession,
                       kVTCompressionPropertyKey_AllowFrameReordering,
                       kCFBooleanFalse);

  VTSessionSetProperty(_compressionSession,
                       kVTCompressionPropertyKey_ExpectedFrameRate,
                       (__bridge CFTypeRef) @(30));

  VTSessionSetProperty(
      _compressionSession,
      kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
      kCFBooleanTrue);

  // Real-time encoding priority
  VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime,
                       kCFBooleanTrue);

  // Constant bitrate ~8 Mbps
  VTSessionSetProperty(_compressionSession,
                       kVTCompressionPropertyKey_AverageBitRate,
                       (__bridge CFTypeRef) @(8000000));

  // Keyframe interval (2 seconds at 30fps)
  VTSessionSetProperty(_compressionSession,
                       kVTCompressionPropertyKey_MaxKeyFrameInterval,
                       (__bridge CFTypeRef) @(60));

  // Prefer hardware
  VTSessionSetProperty(
      _compressionSession,
      kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
      kCFBooleanTrue);

  // ── Codec-specific properties ──────────────────────────────────────────
  if (isHEVC) {
    // Main profile for broad compatibility
    VTSessionSetProperty(_compressionSession,
                         kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_HEVC_Main_AutoLevel);
  } else {
    // High profile for H.264
    VTSessionSetProperty(_compressionSession,
                         kVTCompressionPropertyKey_ProfileLevel,
                         kVTProfileLevel_H264_High_AutoLevel);

    // // Enable B-frames for better compression
    // VTSessionSetProperty(_compressionSession,
    //                      kVTCompressionPropertyKey_AllowFrameReordering,
    //                      kCFBooleanTrue);
  }

  status = VTCompressionSessionPrepareToEncodeFrames(_compressionSession);

  if (status != noErr) {
    NSLog(@"CTCompressionsessionPrepareToEncodeFrames failed: %d", (int)status);
    return;
  }
}

- (CMVideoCodecType)bestAvailableCodec {
  if (@available(macOS 10.13, *)) {
    if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
      return kCMVideoCodecType_HEVC;
    }
  }

  NSLog(@"H.265 HW encoder unavailable, falling back to H.264");
  return kCMVideoCodecType_H264;
}

static void EncodedFrameCallback(void *outputCallbackRefCon,
                                 void *sourceFrameRefCon, OSStatus status,
                                 VTEncodeInfoFlags infoFlags,
                                 CMSampleBufferRef sampleBuffer) {
  if (status != noErr || !sampleBuffer) {
    NSLog(@"Encode error: %d", (int)status);
    return;
  }

  BOOL isKeyFrame = NO;
  CFArrayRef attachments =
      CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
  if (attachments && CFArrayGetCount(attachments) > 0) {
    CFDictionaryRef attachment = CFArrayGetValueAtIndex(attachments, 0);
    CFBooleanRef notSync =
        CFDictionaryGetValue(attachment, kCMSampleAttachmentKey_NotSync);
    isKeyFrame = (notSync == NULL || !CFBooleanGetValue(notSync));
  }

  // ── Consume encoded data here ──────────────────────────────────────────
  // e.g. write to file, send over network, mux into container, etc.
  CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
  size_t totalLength = 0;
  char *dataPointer = NULL;
  CMBlockBufferGetDataPointer(block, 0, NULL, &totalLength, &dataPointer);

  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  // CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
  CMFormatDescriptionRef fmt = CMSampleBufferGetFormatDescription(sampleBuffer);

  // NSMutableString *hex = [NSMutableString string];
  // const uint8_t *bytes = (const uint8_t *)header.bytes;

  // for (NSUInteger i = 0; i < header.length; i++) {
  //   [hex appendFormat:@"%0x02X, ", bytes[i]];
  // }

  // NSLog(@"Bytes: [%@]", hex);
  // Output: Bytes: 01 FF AB 3C

  // NSLog(@"%@ frame encoded, size: %zu bytes, pts: %lli, ptsts = %d, dur: % "
  //       @"lli, durts: %d",
  //       isKeyFrame ? @" Key" : @"  Delta", totalLength, pts.value,
  //       pts.timescale, duration.value, duration.timescale);

  ScreenCaptureManager *manager =
      (__bridge ScreenCaptureManager *)outputCallbackRefCon;

  UInt32 delta = 0;
  if (manager.lastKeyframePts.value != 0) {
    CMTime kf = manager.lastKeyframePts;
    double d = (double)(pts.value - kf.value) * 1000 / pts.timescale;
    delta += floor(d);

    // NSLog(@"computed delta = %d", delta);
  }

  if (isKeyFrame) {
    manager.lastKeyframePts = pts;

    NSData *out = [VTParamSetSerializer serializeFormatDescription:fmt
                                                             delta:delta
                                                              data:dataPointer
                                                               len:totalLength];
    NSLog(@"including codec header = %lu (%lu) delta %d", out.length,
          totalLength, delta);
    aweboScreenCaptureEncodedVideoFrame(
        manager.userdata, (const char *)out.bytes, out.length, isKeyFrame);
  } else {

    NSMutableData *out =
        [NSMutableData dataWithCapacity:sizeof(UInt32) + totalLength];

    [out appendBytes:&delta length:sizeof(UInt32)];
    [out appendBytes:dataPointer length:totalLength];

    aweboScreenCaptureEncodedVideoFrame(manager.userdata, out.bytes, out.length,
                                        isKeyFrame);
  }
}

- (void)invalidate {
  if (_compressionSession) {
    VTCompressionSessionInvalidate(_compressionSession);
    CFRelease(_compressionSession);
    _compressionSession = NULL;
  }
  if (_stream) {
    [_stream stopCaptureWithCompletionHandler:^(NSError *error) {
      if (error) {
        NSLog(@"Error stopping: %@", error);
      }
    }];
    _stream = NULL;
  }
}

- (void)dealloc {
  [self invalidate];
}

@end
