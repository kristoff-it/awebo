#import <ScreenCaptureKit/ScreenCaptureKit.h>

@interface ScreenCaptureManager : NSObject <SCContentSharingPickerObserver>
@property(strong) SCContentSharingPicker *picker;
@property(strong) SCStream *stream;
@property void *userdata;
@end

@implementation ScreenCaptureManager

typedef struct Pixels {
  size_t width;
  size_t height;
  uint8_t *pixels;
} Pixels;

ScreenCaptureManager *screenCaptureManagerInit(void *userdata) {
  NSLog(@"creating capture manager");
  ScreenCaptureManager *manager = [[ScreenCaptureManager alloc] init];
  manager.userdata = userdata;

  return (__bridge_retained void *)manager;
}

void screenCaptureManagerDeinit(void *ptr) {
  ScreenCaptureManager *scm = (__bridge_transfer ScreenCaptureManager *)ptr;
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
  // Clean up if needed
}

- (void)contentSharingPicker:(SCContentSharingPicker *)picker
         didUpdateWithFilter:(SCContentFilter *)filter
                   forStream:(SCStream *)stream {
  NSLog(@"User selected content");

  // This is called when user selects something
  // Start capturing with the provided filter
  [self startCaptureWithFilter:filter];
}

- (void)contentSharingPickerStartDidFailWithError:(NSError *)error {
  NSLog(@"Picker failed to start: %@", error);
}

// MARK: - Start Capture

- (void)startCaptureWithFilter:(SCContentFilter *)filter {
  // Configure the stream
  SCStreamConfiguration *config = [[SCStreamConfiguration alloc] init];
  config.width = 1920;
  config.height = 1080;
  config.minimumFrameInterval = CMTimeMake(1, 30); // 30 fps
  // config.pixelFormat = kCVPixelFormatType_32RGBA;
  config.pixelFormat = kCVPixelFormatType_32BGRA;

  // AUDIO CONFIGURATION
  config.capturesAudio = YES;
  config.sampleRate = 44100;
  config.channelCount = 2; // Stereo

  // Exclude your own app's audio from capture
  config.excludesCurrentProcessAudio = YES;

  // Create stream with the filter from picker
  self.stream = [[SCStream alloc] initWithFilter:filter
                                   configuration:config
                                        delegate:self];
  // Add output handler
  dispatch_queue_t queue =
      dispatch_queue_create("awebo.awebo.awebo.capture", DISPATCH_QUEUE_SERIAL);

  NSError *error = nil;
  [self.stream addStreamOutput:self
                          type:SCStreamOutputTypeScreen
            sampleHandlerQueue:queue
                         error:&error];

  if (error) {
    NSLog(@"Failed to add video output: %@", error);
    return;
  }

  // Add AUDIO output
  [self.stream addStreamOutput:self
                          type:SCStreamOutputTypeAudio
            sampleHandlerQueue:queue
                         error:&error];

  if (error) {
    NSLog(@"Failed to add audio output: %@", error);
    return;
  }

  // Start the stream
  NSLog(@"stream is nil? %p", self.stream);
  [self.stream startCaptureWithCompletionHandler:^(NSError *error) {
    if (error) {
      NSLog(@"Failed to start capture: %@", error);
    } else {
      NSLog(@"Capture started successfully");
    }
  }];
}

// MARK: - SCStreamDelegate & SCStreamOutput

- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
  NSLog(@"Stream stopped: %@", error);
}

- (void)stream:(SCStream *)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
  if (type == SCStreamOutputTypeScreen) {
    // Get the frame
    CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    [self processVideoFrame:pixelBuffer];

  } else if (type == SCStreamOutputTypeAudio) {
    // Audio sample
    [self processAudioBuffer:sampleBuffer];
  }
}

CVPixelBufferRef aweboScreenCaptureSwapFrame(void *, CVPixelBufferRef);
__attribute__((weak)) CVPixelBufferRef
aweboScreenCaptureSwapFrame(void *userdata, CVPixelBufferRef ref) {
  __builtin_unreachable();
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

Pixels frameGetPixels(CVPixelBufferRef pixelBuffer) {
  // Lock the pixel buffer to get access to the memory
  CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);

  // Get buffer info
  size_t width = CVPixelBufferGetWidth(pixelBuffer);
  size_t height = CVPixelBufferGetHeight(pixelBuffer);
  size_t bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer);

  // Get pointer to the pixel data
  void *baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer);
  uint8_t *pixels = (uint8_t *)baseAddress;
  return (Pixels){width, height, pixels};
}

void frameDeinit(CVPixelBufferRef pixelBuffer) {
  CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
  CVPixelBufferRelease(pixelBuffer);
}

// MARK: - Cleanup

- (void)stopCapture {
  [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
    if (error) {
      NSLog(@"Error stopping: %@", error);
    }
  }];

  [self.picker removeObserver:self];
}

@end