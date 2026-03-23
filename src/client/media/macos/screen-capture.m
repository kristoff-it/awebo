#import "utils.h"
#import "video.h"
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>

void aweboScreenCapturePushFrame(void *, CVPixelBufferRef, UInt64);
__attribute__((weak)) void
aweboScreenCapturePushFrame(void *userdata, CVPixelBufferRef ref,
                            UInt64 delta_from_start) {
  __builtin_unreachable();
}

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
@property int32_t width;
@property int32_t height;
@property int32_t fps;
@property OSType pixelFormat;
@property CMTime startTime;
@end

@implementation ScreenCaptureManager

void *screenCaptureManagerInit(void *userdata) {
  NSLog(@"creating capture manager");
  ScreenCaptureManager *manager = [[ScreenCaptureManager alloc] init];
  manager.userdata = userdata;

  return (__bridge_retained void *)manager;
}

void screenCaptureManagerDeinit(void *ptr) {
  ScreenCaptureManager *scm = (__bridge_transfer ScreenCaptureManager *)ptr;
  DDAssertLastRef(scm);
}

void screenCaptureManagerShowPicker(void *manager, UInt32 width, UInt32 height,
                                    UInt8 fps, AweboPixelFmtID imgKind) {
  ScreenCaptureManager *self = (__bridge ScreenCaptureManager *)manager;
  self.width = width;
  self.height = height;
  self.fps = fps;

  switch (imgKind) {
  case AweboYUV:
    // self.pixelFormat = kCVPixelFormatType_420YpCbCr8PlanarFullRange;
    __builtin_unreachable(); // not supported by screencapturekit
  case AweboNV12:
  case AweboVideoToolbox:
    self.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
    break;
  case AweboBGRA:
    self.pixelFormat = kCVPixelFormatType_32BGRA;
    break;
  default:
    __builtin_unreachable();
  }

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

  // Configure the stream
  SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
  config.width = self.width;
  config.height = self.height;
  config.minimumFrameInterval = CMTimeMake(1, self.fps);
  config.pixelFormat = self.pixelFormat;
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
    [self processVideoFrame:sampleBuffer];
  } else if (type == SCStreamOutputTypeAudio) {
    [self processAudioBuffer:sampleBuffer];
  }
}

- (void)processVideoFrame:(CMSampleBufferRef)sampleBuffer {
  CMTime pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
  UInt64 delta_from_start = 0;
  if (self.startTime.value == 0) {
    self.startTime = pts;
  } else {
    CMTime kf = self.startTime;
    double d = (double)(pts.value - kf.value) * 1000 / pts.timescale;
    delta_from_start += round(d);
  }

  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  CVPixelBufferRetain(pixelBuffer);
  aweboScreenCapturePushFrame(self.userdata, pixelBuffer, delta_from_start);
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

RawImage frameGetImage(CVPixelBufferRef pixelBuffer) {
  // Lock the pixel buffer to get access to the memory
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  OSType pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer);
  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);

  switch (pixelFormat) {
  case kCVPixelFormatType_420YpCbCr8PlanarFullRange: {
    // --- Plane 0: Luma (Y) ---
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    uint8_t *yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);

    // --- Plane 1: Cb ---
    size_t cbStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    uint8_t *cbPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);

    // --- Plane 2: Cr ---
    size_t crStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 2);
    uint8_t *crPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 2);

    return (RawImage){width,   height,   yPlane,   cbPlane, crPlane,
                      yStride, cbStride, crStride, 0};
  }
  case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange: {
    // --- Plane 0: Luma (Y) ---
    size_t yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
    uint8_t *yPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0);

    // --- Plane 1: Chroma (CbCr, interleaved) ---
    size_t cbcrStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
    uint8_t *cbcrPlane = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1);

    return (RawImage){width,   height,     yPlane, cbcrPlane, 0,
                      yStride, cbcrStride, 0,      1};
  }

  case kCVPixelFormatType_32BGRA: {
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);
    void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
    uint8_t *pixels = (uint8_t *)baseAddress;

    return (RawImage){width, height, pixels, 0, 0, bytesPerRow, 0, 0, 3};
  }

  default:
    NSLog(@"requested unsupported pixel format: %c%c%c%c",
          *((UInt8 *)&pixelFormat), *(((UInt8 *)&pixelFormat) + 1),
          *(((UInt8 *)&pixelFormat) + 2), *(((UInt8 *)&pixelFormat) + 3));
    __builtin_unreachable();
  }
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

  [self.picker removeObserver:self];
}

// VTSessionSetProperty(_compressionSession,
//                      kVTCompressionPropertyKey_AllowFrameReordering,
//                      kCFBooleanFalse);

// VTSessionSetProperty(_compressionSession,
//                      kVTCompressionPropertyKey_ExpectedFrameRate,
//                      (__bridge CFTypeRef) @(30));

// VTSessionSetProperty(
//     _compressionSession,
//     kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality,
//     kCFBooleanTrue);

// // Real-time encoding priority
// VTSessionSetProperty(_compressionSession, kVTCompressionPropertyKey_RealTime,
//                      kCFBooleanTrue);

// // Constant bitrate ~8 Mbps
// VTSessionSetProperty(_compressionSession,
//                      kVTCompressionPropertyKey_AverageBitRate,
//                      (__bridge CFTypeRef) @(8000000));

// // Keyframe interval (2 seconds at 30fps)
// VTSessionSetProperty(_compressionSession,
//                      kVTCompressionPropertyKey_MaxKeyFrameInterval,
//                      (__bridge CFTypeRef) @(60));

// // Prefer hardware
// VTSessionSetProperty(
//     _compressionSession,
//     kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
//     kCFBooleanTrue);

- (void)invalidate {
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
