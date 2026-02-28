#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <Foundation/Foundation.h>

void aweboAudioPlaybackSourceMonoFill(void *userdata, float *samples,
                                      uint32_t frame_count);
__attribute__((weak)) void
aweboAudioPlaybackSourceMonoFill(void *userdata, float *samples,
                                 uint32_t frame_count) {
  __builtin_unreachable();
}
void aweboAudioPlaybackSourceStereoFill(void *userdata, float *left,
                                        float *right, uint32_t frame_count);
__attribute__((weak)) void
aweboAudioPlaybackSourceStereoFill(void *userdata, float *left, float *right,
                                   uint32_t frame_count) {
  __builtin_unreachable();
}

void aweboUpdateCapturePermission(void *userdata, UInt32 permission);
__attribute__((weak)) void aweboUpdateCapturePermission(void *userdata,
                                                        UInt32 permission) {
  __builtin_unreachable();
}

// When the settings page "audio capture test" is enabled,
// the microphone's mixer gets connected to the main mixer
// and a tap is installed to look at the power level of a
// given buffer worth of samples. In other situations,
// power is computed within the audio callback on the Zig
// side (aweboAudioCapturePush).
void aweboComputePower(void *userdata, const float *samples,
                       uint32_t sample_count);
__attribute__((weak)) void
aweboComputePower(void *userdata, const float *samples, uint32_t sample_count) {
  __builtin_unreachable();
}

// Called by Zig to consume interleaved f32 mono capture frames.
void aweboAudioCapturePush(void *userdata, const float *frames,
                           uint32_t frame_count);
__attribute__((weak)) void aweboAudioCapturePush(void *userdata,
                                                 const float *frames,
                                                 uint32_t frame_count) {
  __builtin_unreachable();
}

// ---------------------------------------------------------------------------
// Return values synced with Audio.CapturePermission
UInt32 audioDiscoverCapturePermissionState() {
  AVAudioApplication *av = [AVAudioApplication sharedInstance];
  if (av.recordPermission == AVAudioApplicationRecordPermissionUndetermined) {
    return 0;
  }
  if (av.recordPermission == AVAudioApplicationRecordPermissionDenied) {
    return 1;
  } else { // if (av.recordPermission ==
           // AVAudioApplicationRecordPermissionGranted) {
    return 2;
  }
}

void audioRequestCapturePermission(void *userdata) {
  [AVAudioApplication
      requestRecordPermissionWithCompletionHandler:^(BOOL granted) {
        if (granted) {
          aweboUpdateCapturePermission(userdata, 2);
        } else {
          aweboUpdateCapturePermission(userdata, 1);
        }
      }];
}
// ---------------------------------------------------------------------------

static const double kSampleRate = 48000.0;

@interface AudioEngineManager : NSObject
@property(strong) AVAudioFormat *monoFormat;
@property(strong) AVAudioFormat *stereoFormat;
@property AudioDeviceID inputID;
@property AudioDeviceID outputID;
@property bool voiceProcessing;
@property bool inCall;
@property bool inTest;
@property void *testUserdata;
@property(strong) AVAudioEngine *engine;
@property(strong) AVAudioMixerNode *captureMixerNode;
@property(strong) AVAudioMixerNode *captureTestMixerNode;
@property(strong) AVAudioSinkNode *captureSinkNode;
@end

@implementation AudioEngineManager

void *audioManagerInit(void *userdata) {
  AudioEngineManager *manager = [[AudioEngineManager alloc] init];
  manager.stereoFormat =
      [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                       sampleRate:kSampleRate
                                         channels:2
                                      interleaved:NO];
  manager.monoFormat =
      [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                       sampleRate:kSampleRate
                                         channels:1
                                      interleaved:NO];

  manager.engine = [[AVAudioEngine alloc] init];
  manager.captureMixerNode = [[AVAudioMixerNode alloc] init];
  manager.captureTestMixerNode = [[AVAudioMixerNode alloc] init];
  manager.captureSinkNode = [[AVAudioSinkNode alloc]
      initWithReceiverBlock:^OSStatus(const AudioTimeStamp *timestamp,
                                      AVAudioFrameCount frameCount,
                                      const AudioBufferList *inputData) {
        const float *samples = (const float *)inputData->mBuffers[0].mData;
        if (userdata) {
          aweboAudioCapturePush(userdata, samples, frameCount);
        }
        return noErr;
      }];

  [manager.engine attachNode:manager.captureMixerNode];
  [manager.engine attachNode:manager.captureTestMixerNode];
  [manager.engine attachNode:manager.captureSinkNode];

  [manager.engine connect:manager.captureTestMixerNode
                       to:manager.engine.mainMixerNode
                   format:manager.monoFormat];
  [manager.engine connect:manager.captureMixerNode
                       to:manager.captureSinkNode
                   format:manager.monoFormat];

  manager.captureTestMixerNode.volume = 0;

  // Notifications
  [[NSNotificationCenter defaultCenter]
      addObserver:manager
         selector:@selector(handleEngineConfigChange:)
             name:AVAudioEngineConfigurationChangeNotification
           object:manager.engine];

  return (__bridge_retained void *)manager;
}
void audioManagerDeinit(void *ptr) {}

void audioCallBegin(void *ptr, void *userdata) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  NSLog(@"begin call");

  if (manager.inCall) {
    NSLog(@"already in a call!");
    __builtin_unreachable();
  }

  manager.inCall = true;
  // manager.callUserdata = userdata;
  [manager captureEngineStart];
}
void audioCallEnd(void *ptr) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  NSLog(@"end call");

  if (!manager.inCall) {
    NSLog(@"already NOT in a call!");
    __builtin_unreachable();
  }

  manager.inCall = false;
  [manager captureEngineStop];
}

void audioTestBegin(void *ptr, void *userdata) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  NSLog(@"begin capture test");

  if (manager.inTest) {
    NSLog(@"already in a capture test!");
    __builtin_unreachable();
  }
  manager.testUserdata = userdata;
  manager.inTest = true;
  [manager refreshTest];
  [manager.captureTestMixerNode
      installTapOnBus:0
           bufferSize:512
               format:nil
                block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
                  const float *samples = *[buffer floatChannelData];
                  aweboComputePower(userdata, samples,
                                    buffer.frameLength * buffer.stride);
                }];
  if (!manager.inCall) {
    [manager captureEngineStart];
  }
}

- (void)refreshTest {
  if (self.inTest) {
    self.captureMixerNode.volume = 0;
    self.captureTestMixerNode.volume = 1;
  } else {
    self.captureMixerNode.volume = 1;
    self.captureTestMixerNode.volume = 0;
  }
}

void audioTestEnd(void *ptr) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  NSLog(@"end capture test");

  if (!manager.inTest) {
    NSLog(@"already NOT in a capture test!");
    // __builtin_unreachable();
    return;
  }

  manager.inTest = false;
  [manager.captureTestMixerNode removeTapOnBus:0];
  [manager refreshTest];
  if (!manager.inCall) {
    [manager captureEngineStop];
  }
}

void *audioCallSourceAdd(void *ptr, void *userdata, UInt32 kind) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  AVAudioEngine *engine = manager.engine;

  NSLog(@"add caller %p", userdata);

  AVAudioFormat *format = kind == 1 ? manager.monoFormat : manager.stereoFormat;

  AVAudioSourceNode *source = [[AVAudioSourceNode alloc]
      initWithFormat:format
         renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                               AVAudioFrameCount frameCount,
                               AudioBufferList *outputData) {
           if (kind == 1) {
             float *samples = (float *)outputData->mBuffers[0].mData;
             aweboAudioPlaybackSourceMonoFill(userdata, samples, frameCount);
           } else {
             __builtin_unreachable();
             float *left = (float *)outputData->mBuffers[0].mData;
             float *right = (float *)outputData->mBuffers[1].mData;
             aweboAudioPlaybackSourceStereoFill(userdata, left, right,
                                                frameCount);
           }
           return noErr;
         }];

  [engine attachNode:source];
  [engine connect:source to:engine.mainMixerNode format:format];

  return (__bridge_retained void *)source;
}

void audioCallSourceRemove(void *mngr, void *src) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)mngr;
  AVAudioSourceNode *source = (__bridge_transfer AVAudioSourceNode *)src;
  [manager.engine detachNode:source];
}

void audioSetDevices(void *ptr, AudioDeviceID input, AudioDeviceID output,
                     bool voiceProcessing) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  NSLog(@"updating devices Input(%d) Output(%d) Voice(%d)", input, output,
        voiceProcessing);

  manager.inputID = input;
  manager.outputID = output;
  manager.voiceProcessing = voiceProcessing;

  if (manager.inputID) {
    const AudioDeviceID deviceID = manager.inputID;
    AudioObjectPropertyAddress propAddress = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};

    OSStatus status =
        AudioObjectSetPropertyData(kAudioObjectSystemObject, &propAddress, 0,
                                   NULL, sizeof(AudioDeviceID), &deviceID);

    if (status != noErr) {
      NSLog(@"unable to set INPUT device: %d", (int)status);
      return;
    }
  }
  if (manager.outputID) {
    const AudioDeviceID deviceID = manager.outputID;
    AudioObjectPropertyAddress propAddress = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};

    OSStatus status =
        AudioObjectSetPropertyData(kAudioObjectSystemObject, &propAddress, 0,
                                   NULL, sizeof(AudioDeviceID), &deviceID);
    if (status != noErr) {
      NSLog(@"unable to set OUTPUT device: %d", (int)status);
      return;
    }
  }

  [manager captureEngineRestart];
}

- (void)captureEngineStart {

  [self.engine disconnectNodeOutput:self.engine.inputNode bus:0];
  [self.engine disconnectNodeInput:self.engine.outputNode bus:0];
  // [self.engine reset];

  AudioStreamBasicDescription inputAsbd = [self currentInputDeviceFormat];
  AudioStreamBasicDescription outputAsbd = [self currentOutputDeviceFormat];

  // AVAudioFormat *rawInputFormat = [self audioFormatFromASBD:inputAsbd];
  // AVAudioFormat *rawOutputFormat = [self audioFormatFromASBD:outputAsbd];
  AVAudioFormat *rawInputFormat = [self.engine.inputNode inputFormatForBus:1];
  AVAudioFormat *rawOutputFormat =
      [self.engine.outputNode outputFormatForBus:0];

  NSLog(@"hw input format %@", rawInputFormat);
  NSLog(@"hw output format %@", rawOutputFormat);
  NSLog(@"ae input format %@", [self.engine.inputNode outputFormatForBus:0]);
  NSLog(@"ae output format %@", [self.engine.outputNode inputFormatForBus:0]);

  if (self.voiceProcessing) {
    NSLog(@"ENABLING VOICE PROCESSING");

    NSError *error = nil;
    if (![self.engine.inputNode setVoiceProcessingEnabled:true error:&error]) {
      NSLog(@"failed to enable voice processing: %@", error);
    }

    AVAudioVoiceProcessingOtherAudioDuckingConfiguration cfg;
    cfg.enableAdvancedDucking = true;
    cfg.duckingLevel = AVAudioVoiceProcessingOtherAudioDuckingLevelMin;
    self.engine.inputNode.voiceProcessingOtherAudioDuckingConfiguration = cfg;
    self.engine.inputNode.voiceProcessingInputMuted = false;
    self.engine.inputNode.voiceProcessingBypassed = false;
    self.engine.inputNode.voiceProcessingAGCEnabled = true;

    // To enable voice processing both input and output must share the same
    // format config.
    AVAudioFormat *inputOutputFormat = [[AVAudioFormat alloc]
        initStandardFormatWithSampleRate:rawInputFormat.sampleRate
                                channels:MIN(rawInputFormat.channelCount,
                                             rawOutputFormat.channelCount)];

    NSLog(@"voice processing input/output format: %@", inputOutputFormat);
    [self.engine connect:self.engine.inputNode
        toConnectionPoints:@[
          [[AVAudioConnectionPoint alloc] initWithNode:self.captureTestMixerNode
                                                   bus:0],
          [[AVAudioConnectionPoint alloc] initWithNode:self.captureMixerNode
                                                   bus:0]
        ]
                   fromBus:0
                    format:inputOutputFormat];
    // [self.engine connect:self.engine.inputNode
    //                   to:self.captureMixerNode
    //               format:inputOutputFormat];
    // [self.engine connect:self.engine.inputNode
    //                   to:self.captureTestMixerNode
    //               format:inputOutputFormat];
    [self.engine connect:self.engine.mainMixerNode
                      to:self.engine.outputNode
                  format:inputOutputFormat];
  } else {

    NSError *error = nil;
    if (![self.engine.inputNode setVoiceProcessingEnabled:false error:&error]) {
      NSLog(@"failed to disable voice processing: %@", error);
    }

    [self.engine connect:self.engine.inputNode
        toConnectionPoints:@[
          [[AVAudioConnectionPoint alloc] initWithNode:self.captureTestMixerNode
                                                   bus:0],
          [[AVAudioConnectionPoint alloc] initWithNode:self.captureMixerNode
                                                   bus:0]
        ]
                   fromBus:0
                    format:rawInputFormat];
    // [self.engine connect:self.engine.inputNode
    //                   to:self.captureMixerNode
    //               format:[self.engine.inputNode outputFormatForBus:0]];
    // [self.engine connect:self.engine.inputNode
    //                   to:self.captureTestMixerNode
    //               format:rawInputFormat];
    [self.engine connect:self.engine.mainMixerNode
                      to:self.engine.outputNode
                  format:rawOutputFormat];
  }

  [self refreshTest];

  NSError *error = nil;
  if (![self.engine startAndReturnError:&error]) {
    NSLog(@"engine start failed: %@", error);
  } else {
    NSLog(@"engine start success!");
  }
}

- (void)captureEngineStop {
  NSLog(@"stopping the engine");
  if (!self.engine.running) {
    NSLog(@"engine already not running!");
    __builtin_unreachable();
  }

  [self.engine stop];
}
void audioRestart(void *ptr) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  [manager captureEngineRestart];
}

- (void)captureEngineRestart {
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"restarting engine...");
    if (!self.inCall && !self.inTest) {
      NSLog(@"engine should not run, return");
      return;
    }
    if (self.engine.running) {
      [self captureEngineStop];
    }
    [self captureEngineStart];
  });
}

- (void)handleEngineConfigChange:(NSNotification *)note {
  NSLog(@"engine broke");
  [self captureEngineStart];
}

#import <CoreAudio/CoreAudio.h>
- (AudioStreamBasicDescription)currentInputDeviceFormat {
  // 1. Get default input device ID
  AudioDeviceID deviceID = kAudioDeviceUnknown;
  UInt32 size = sizeof(AudioDeviceID);
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDefaultInputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};

  OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                               0, NULL, &size, &deviceID);

  if (status != noErr || deviceID == kAudioDeviceUnknown) {
    NSLog(@"Failed to get default input device: %d", status);
    return (AudioStreamBasicDescription){};
  }

  // 2. Get the stream format for that device
  AudioStreamBasicDescription asbd = {};
  size = sizeof(AudioStreamBasicDescription);
  addr = (AudioObjectPropertyAddress){kAudioDevicePropertyStreamFormat,
                                      kAudioDevicePropertyScopeInput,
                                      kAudioObjectPropertyElementMain};

  status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &asbd);

  if (status != noErr) {
    NSLog(@"Failed to get input stream format: %d", status);
    return (AudioStreamBasicDescription){};
  }
  NSLog(@"input::");
  NSLog(@"Sample rate:  %.0f Hz", asbd.mSampleRate);
  NSLog(@"Channels:     %u", asbd.mChannelsPerFrame);
  NSLog(@"Bits/channel: %u", asbd.mBitsPerChannel);
  NSLog(@"Format flags: 0x%X", asbd.mFormatFlags);

  return asbd;
}

- (AudioStreamBasicDescription)currentOutputDeviceFormat {
  AudioDeviceID deviceID = kAudioDeviceUnknown;
  UInt32 size = sizeof(AudioDeviceID);
  AudioObjectPropertyAddress addr = {kAudioHardwarePropertyDefaultOutputDevice,
                                     kAudioObjectPropertyScopeGlobal,
                                     kAudioObjectPropertyElementMain};

  OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &addr,
                                               0, NULL, &size, &deviceID);

  if (status != noErr || deviceID == kAudioDeviceUnknown) {
    NSLog(@"Failed to get default output device: %d", status);
    return (AudioStreamBasicDescription){};
  }

  AudioStreamBasicDescription asbd = {};
  size = sizeof(AudioStreamBasicDescription);
  addr = (AudioObjectPropertyAddress){kAudioDevicePropertyStreamFormat,
                                      kAudioDevicePropertyScopeOutput,
                                      kAudioObjectPropertyElementMain};

  status = AudioObjectGetPropertyData(deviceID, &addr, 0, NULL, &size, &asbd);

  if (status != noErr) {
    NSLog(@"Failed to get output stream format: %d", status);
    return (AudioStreamBasicDescription){};
  }

  NSLog(@"outptut::");
  NSLog(@"Sample rate:  %.0f Hz", asbd.mSampleRate);
  NSLog(@"Channels:     %u", asbd.mChannelsPerFrame);
  NSLog(@"Bits/channel: %u", asbd.mBitsPerChannel);
  NSLog(@"Format flags: 0x%X", asbd.mFormatFlags);

  return asbd;
}

- (AVAudioFormat *)audioFormatFromASBD:(AudioStreamBasicDescription)asbd {
  // For non-interleaved PCM, AVAudioFormat has a dedicated initializer
  // that also captures the channel layout cleanly.
  if (asbd.mFormatID == kAudioFormatLinearPCM) {
    AVAudioFormat *format =
        [[AVAudioFormat alloc] initWithStreamDescription:&asbd];
    return format; // may be nil if the ASBD is malformed
  }
  return nil;
}

@end
