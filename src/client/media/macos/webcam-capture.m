#import <AVFoundation/AVFoundation.h>

// Device info structure for passing to Zig
typedef struct VideoDevice {
  char uniqueID[256];
  char localizedName[256];
  bool isConnected;
} VideoDevice;

void aweboWebcamUpsert(void *, const char *, const char *, bool);
__attribute__((weak)) void aweboWebcamUpsert(void *userdata, const char *id,
                                             const char *name, bool active) {
  __builtin_unreachable();
}

CVPixelBufferRef aweboWebcamSwapFrame(void *, CVPixelBufferRef);
__attribute__((weak)) CVPixelBufferRef
aweboWebcamSwapFrame(void *userdata, CVPixelBufferRef ref) {
  __builtin_unreachable();
}

@interface WebcamCaptureManager
    : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(strong) AVCaptureSession *captureSession;
@property(strong) AVCaptureDeviceInput *videoInput;
@property(strong) AVCaptureVideoDataOutput *videoOutput;
@property(strong) dispatch_queue_t captureQueue;
@property void *userdata;
@end

@implementation WebcamCaptureManager

// MARK: - Lifecycle
void *webcamCaptureManagerInit() {
  NSLog(@"creating webcam capture manager");
  WebcamCaptureManager *manager = [[WebcamCaptureManager alloc] init];
  manager.captureQueue =
      dispatch_queue_create("awebo.webcam.capture", DISPATCH_QUEUE_SERIAL);

  return (__bridge_retained void *)manager;
}

void webcamCaptureManagerDeinit(void *ptr) {
  WebcamCaptureManager *manager = (__bridge_transfer WebcamCaptureManager *)ptr;
  [[NSNotificationCenter defaultCenter] removeObserver:manager];
  [manager stopCapture];
}

// MARK: - Device Enumeration
void webcamDiscoverDevicesAndListen(void *ptr, void *userdata) {
  WebcamCaptureManager *manager = (__bridge WebcamCaptureManager *)ptr;
  manager.userdata = userdata;

  // Register for device connection/disconnection notifications
  [[NSNotificationCenter defaultCenter]
      addObserver:manager
         selector:@selector(deviceWasConnected:)
             name:AVCaptureDeviceWasConnectedNotification
           object:nil];

  [[NSNotificationCenter defaultCenter]
      addObserver:manager
         selector:@selector(deviceWasDisconnected:)
             name:AVCaptureDeviceWasDisconnectedNotification
           object:nil];

  // Create discovery session for video devices
  // This finds built-in cameras and external USB cameras
  AVCaptureDeviceDiscoverySession *session = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:@[
        AVCaptureDeviceTypeBuiltInWideAngleCamera, // Built-in cameras
        AVCaptureDeviceTypeContinuityCamera,       // lmao iphones
        AVCaptureDeviceTypeDeskViewCamera,         // iiipphonnees
        AVCaptureDeviceTypeExternal                // USB/external cameras
      ]
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];

  NSArray<AVCaptureDevice *> *devices = session.devices;

  for (int i = 0; i < devices.count; i++) {
    AVCaptureDevice *device = devices[i];
    aweboWebcamUpsert(userdata, [device.uniqueID UTF8String],
                      [device.localizedName UTF8String], device.isConnected);
  }
}

// MARK: - Device Change Notifications

- (void)deviceWasConnected:(NSNotification *)notification {
  AVCaptureDevice *device = notification.object;
  if (![device hasMediaType:AVMediaTypeVideo])
    return;

  NSLog(@"Device connected: %@ (%@)", device.localizedName, device.uniqueID);
  aweboWebcamUpsert(self.userdata, [device.uniqueID UTF8String],
                    [device.localizedName UTF8String], device.isConnected);
}

- (void)deviceWasDisconnected:(NSNotification *)notification {
  AVCaptureDevice *device = notification.object;
  if (![device hasMediaType:AVMediaTypeVideo])
    return;

  NSLog(@"Device disconnected: %@ (%@)", device.localizedName, device.uniqueID);
  aweboWebcamUpsert(self.userdata, [device.uniqueID UTF8String],
                    [device.localizedName UTF8String], device.isConnected);
}

// MARK: - Capture Session

bool webcamStartCapture(void *manager, const char *deviceID, int width,
                        int height, int fps) {
  WebcamCaptureManager *self = (__bridge WebcamCaptureManager *)manager;
  return [self startCaptureWithDeviceID:deviceID
                                  width:width
                                 height:height
                                    fps:fps];
}

- (bool)startCaptureWithDeviceID:(const char *)deviceID
                           width:(int)width
                          height:(int)height
                             fps:(int)fps {
  // Find the device
  AVCaptureDevice *device = nil;

  if (deviceID == NULL || strlen(deviceID) == 0) {
    // Use default device
    device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
  } else {
    // Find specific device by ID
    NSString *targetID = [NSString stringWithUTF8String:deviceID];
    device = [AVCaptureDevice deviceWithUniqueID:targetID];
  }

  if (!device) {
    NSLog(@"Failed to find camera device");
    return false;
  }

  NSLog(@"Using camera: %@", device.localizedName);

  // Create capture session
  self.captureSession = [[AVCaptureSession alloc] init];

  // Set session preset (quality)
  if (width <= 640 && height <= 480) {
    self.captureSession.sessionPreset = AVCaptureSessionPreset640x480;
  } else if (width <= 1280 && height <= 720) {
    self.captureSession.sessionPreset = AVCaptureSessionPreset1280x720;
  } else {
    self.captureSession.sessionPreset = AVCaptureSessionPreset1920x1080;
  }

  NSError *error = nil;

  // Create device input
  self.videoInput = [AVCaptureDeviceInput deviceInputWithDevice:device
                                                          error:&error];
  if (error) {
    NSLog(@"Failed to create device input: %@", error);
    return false;
  }

  // Add input to session
  if ([self.captureSession canAddInput:self.videoInput]) {
    [self.captureSession addInput:self.videoInput];
  } else {
    NSLog(@"Cannot add video input to session");
    return false;
  }

  // Configure video output
  self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];

  // Set pixel format to BGRA (same as ScreenCaptureKit)
  self.videoOutput.videoSettings =
      @{(id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)};

  // Don't drop frames if processing is slow (or set to YES to drop)
  self.videoOutput.alwaysDiscardsLateVideoFrames = YES;

  // Set delegate for receiving frames
  [self.videoOutput setSampleBufferDelegate:self queue:self.captureQueue];

  // Add output to session
  if ([self.captureSession canAddOutput:self.videoOutput]) {
    [self.captureSession addOutput:self.videoOutput];
  } else {
    NSLog(@"Cannot add video output to session");
    return false;
  }

  // Configure frame rate if device supports it
  if ([device lockForConfiguration:&error]) {
    // Find the format that supports our desired frame rate
    AVCaptureDeviceFormat *bestFormat = nil;
    AVFrameRateRange *bestFrameRateRange = nil;

    for (AVCaptureDeviceFormat *format in device.formats) {
      for (AVFrameRateRange *range in format.videoSupportedFrameRateRanges) {
        if (range.maxFrameRate >= fps && range.minFrameRate <= fps) {
          bestFormat = format;
          bestFrameRateRange = range;
          break;
        }
      }
      if (bestFormat)
        break;
    }

    if (bestFormat) {
      device.activeFormat = bestFormat;
      device.activeVideoMinFrameDuration = CMTimeMake(1, fps);
      device.activeVideoMaxFrameDuration = CMTimeMake(1, fps);
      NSLog(@"Set frame rate to %d fps", fps);
    } else {
      NSLog(@"Device doesn't support %d fps, using default", fps);
    }

    [device unlockForConfiguration];
  }

  // Start the session
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
    [self.captureSession startRunning];
    NSLog(@"Webcam capture session started");
  });

  return true;
}

void webcamStopCapture(void *manager) {
  WebcamCaptureManager *self = (__bridge WebcamCaptureManager *)manager;
  [self stopCapture];
}

- (void)stopCapture {
  if (self.captureSession && self.captureSession.isRunning) {
    [self.captureSession stopRunning];
    NSLog(@"Webcam capture session stopped");
  }

  self.captureSession = nil;
  self.videoInput = nil;
  self.videoOutput = nil;
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {

  // Get the pixel buffer (same type as ScreenCaptureKit!)
  CVPixelBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);

  if (pixelBuffer) {
    [self processVideoFrame:pixelBuffer];
  }
}

- (void)captureOutput:(AVCaptureOutput *)output
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
         fromConnection:(AVCaptureConnection *)connection {
  NSLog(@"Dropped frame");
}

// MARK: - Frame Processing (reuses your existing functions)
- (void)processVideoFrame:(CVPixelBufferRef)pixelBuffer {
  CVPixelBufferRetain(pixelBuffer);
  CVPixelBufferRef dropped_frame =
      aweboWebcamSwapFrame(self.userdata, pixelBuffer);
  if (dropped_frame) {
    CVPixelBufferRelease(dropped_frame);
  }
}

// MARK: - Camera Permissions

bool webcamCheckPermission() {
  AVAuthorizationStatus status =
      [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
  return (status == AVAuthorizationStatusAuthorized);
}

void webcamRequestPermission(void (*callback)(bool granted)) {
  [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                           completionHandler:^(BOOL granted) {
                             NSLog(@"Camera permission: %@",
                                   granted ? @"granted" : @"denied");
                             if (callback) {
                               callback(granted);
                             }
                           }];
}

@end