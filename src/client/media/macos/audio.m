#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>

// Called by Zig to provide interleaved f32 stereo frames for playback
// Should fill `frames` with `frame_count` stereo frames (2 * frame_count
// floats)
void aweboAudioPlaybackFill(void *userdata, float *left, float *right,
                            uint32_t frame_count);
__attribute__((weak)) void aweboAudioPlaybackFill(void *userdata, float *left,
                                                  float *right,
                                                  uint32_t frame_count) {
  __builtin_unreachable();
}

void aweboAudioPlaybackSourceMonoFill(void *userdata, float *samples,
                                      uint32_t frame_count);
__attribute__((weak)) void aweboAudioPlaybackMonoFill(void *userdata,
                                                      float *samples,
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

// Called by Zig to consume interleaved f32 mono capture frames
// `frames` contains `frame_count` mono frames (frame_count floats)
void aweboAudioCapturePush(void *userdata, const float *frames,
                           uint32_t frame_count);
__attribute__((weak)) void aweboAudioCapturePush(void *userdata,
                                                 const float *frames,
                                                 uint32_t frame_count) {
  __builtin_unreachable();
}

// ---------------------------------------------------------------------------

static const double kSampleRate = 48000.0;

@interface AudioEngineManager : NSObject
@property(strong) AVAudioFormat *stereoFormat;
@property(strong) AVAudioEngine *playbackEngine;
@property(strong) AVAudioSourceNode *playbackMainSourceNode;
@property(strong) AVAudioFormat *monoFormat;
@property(strong) AVAudioEngine *captureEngine;
@property(strong) AVAudioSinkNode *captureSinkNode;
@property(strong) AVAudioMixerNode *captureMixerNode;
@end

@implementation AudioEngineManager
@end

// MARK: - Lifecycle

void *audioEngineManagerInit() {
  NSLog(@"creating audio manager");

  AudioEngineManager *manager = [[AudioEngineManager alloc] init];
  manager.playbackEngine = [[AVAudioEngine alloc] init];
  manager.captureEngine = [[AVAudioEngine alloc] init];
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

  return (__bridge_retained void *)manager;
}

void audioEngineManagerDeinit(void *ptr) {
  AudioEngineManager *manager = (__bridge_transfer AudioEngineManager *)ptr;
  [manager.playbackEngine stop];
  [manager.captureEngine stop];
}

// MARK: - Device Routing
//
// AVAudioEngine sits on top of AUGraph/CoreAudio. The simplest way to
// redirect it to a specific device is to set the underlying AudioUnit's
// kAudioOutputUnitProperty_CurrentDevice before starting the engine.

static bool setEngineDevice(AVAudioEngine *engine, AudioDeviceID deviceID,
                            bool isInput) {
  AudioUnit au =
      isInput ? engine.inputNode.audioUnit : engine.outputNode.audioUnit;
  if (!au) {
    NSLog(@"setEngineDevice: no AudioUnit on node");
    return false;
  }

  NSLog(@"set engine node isInput = %d deviceID = %d", isInput, deviceID);

  OSStatus status = AudioUnitSetProperty(
      au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
      &deviceID, sizeof(deviceID));
  if (status != noErr) {
    NSLog(@"setEngineDevice failed: %d", (int)status);
    return false;
  }

  return true;
}

// MARK: - Capture

bool audioCaptureStart(void *ptr, void *userdata, AudioDeviceID deviceID) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  AVAudioEngine *engine = manager.captureEngine;

  NSLog(@"capture start id = %d", deviceID);
  if (deviceID != 0) {
    if (!setEngineDevice(engine, deviceID, true)) {
      return false;
    }
  }

  AVAudioFormat *hwFormat = [engine.inputNode inputFormatForBus:0];
  NSLog(@"capture HW format: %@", hwFormat);
  // UInt32 bufferFrames = 0;
  // UInt32 dataSize = sizeof(bufferFrames);
  //                      kAudioUnitProperty_MaximumFramesPerSlice,
  //                      kAudioUnitScope_Global, 0, &bufferFrames,
  //                      &dataSize);

  // NSLog(@"input device bufferFrames %d", bufferFrames);

  // The mixer will receive the hardware format and output our desired mono
  AVAudioMixerNode *mixer = [[AVAudioMixerNode alloc] init];
  manager.captureMixerNode = mixer;
  [engine attachNode:mixer];
  [engine connect:engine.inputNode to:mixer format:hwFormat];

  AVAudioSinkNode *sink = [[AVAudioSinkNode alloc]
      initWithReceiverBlock:^OSStatus(const AudioTimeStamp *timestamp,
                                      AVAudioFrameCount frameCount,
                                      const AudioBufferList *inputData) {
        const float *samples = (const float *)inputData->mBuffers[0].mData;
        aweboAudioCapturePush(userdata, samples, frameCount);
        return noErr;
      }];

  manager.captureSinkNode = sink;
  [engine attachNode:sink];
  [engine connect:mixer to:sink format:manager.monoFormat];

  NSError *error = nil;
  if (![engine startAndReturnError:&error]) {
    NSLog(@"audioCaptureStart failed: %@", error);
    return false;
  }

  NSLog(@"audio capture started (device %u)", deviceID);
  return true;
}

void audioCaptureStop(void *ptr) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  [manager.captureEngine stop];

  if (manager.captureSinkNode) {
    [manager.captureEngine detachNode:manager.captureSinkNode];
    manager.captureSinkNode = nil;
  }
  if (manager.captureMixerNode) {
    [manager.captureEngine detachNode:manager.captureMixerNode];
    manager.captureMixerNode = nil;
  }

  NSLog(@"audio capture stopped");
}

// MARK: - Playback

bool audioPlaybackStart(void *ptr, void *userdata, AudioDeviceID deviceID) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  AVAudioEngine *engine = manager.playbackEngine;

  if (deviceID != 0) {
    if (!setEngineDevice(engine, deviceID, false)) {
      return false;
    }
  }

  AVAudioSourceNode *source = [[AVAudioSourceNode alloc]
      initWithFormat:manager.stereoFormat
         renderBlock:^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                               AVAudioFrameCount frameCount,
                               AudioBufferList *outputData) {
           float *left = (float *)outputData->mBuffers[0].mData;
           float *right = (float *)outputData->mBuffers[1].mData;
           aweboAudioPlaybackFill(userdata, left, right, frameCount);
           return noErr;
         }];

  manager.playbackMainSourceNode = source;

  AVAudioFormat *hwFormat = [engine.outputNode outputFormatForBus:0];
  NSLog(@"output hardware format: %@", hwFormat);

  [engine attachNode:source];
  [engine connect:source to:engine.mainMixerNode format:manager.stereoFormat];
  [engine connect:engine.mainMixerNode to:engine.outputNode format:hwFormat];

  NSError *error = nil;
  if (![engine startAndReturnError:&error]) {
    NSLog(@"audioStartPlayback failed: %@", error);
    return false;
  }

  NSLog(@"audio playback started (device %u)", deviceID);
  return true;
}

void *audioPlaybackSourceAdd(void *ptr, void *userdata, UInt32 kind) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  AVAudioEngine *engine = manager.playbackEngine;

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
             float *left = (float *)outputData->mBuffers[0].mData;
             float *right = (float *)outputData->mBuffers[1].mData;
             aweboAudioPlaybackSourceStereoFill(userdata, left, right,
                                                frameCount);
           }
           return noErr;
         }];

  [engine attachNode:source];
  [engine connect:source to:engine.mainMixerNode format:manager.monoFormat];

  return (__bridge_retained void *)source;
}

void audioPlaybackSourceRemove(void *mngr, void *src) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)mngr;
  AVAudioSourceNode *source = (__bridge_transfer AVAudioSourceNode *)src;
  AVAudioEngine *engine = manager.playbackEngine;
  [engine detachNode:source];
}

void audioPlaybackStop(void *ptr) {
  AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;
  [manager.playbackEngine stop];
  if (manager.playbackMainSourceNode) {
    [manager.playbackEngine detachNode:manager.playbackMainSourceNode];
    manager.playbackMainSourceNode = nil;
  }
  NSLog(@"audio playback stopped");
}

// bool audioCaptureStart(void *ptr, void *userdata, AudioDeviceID deviceID) {
//   AudioEngineManager *manager = (__bridge AudioEngineManager *)ptr;

//   AVAudioEngine *engine = manager.captureEngine;

//   // Must set device BEFORE accessing inputNode.inputFormat,
//   // otherwise you get the default hardware format
//   NSLog(@"capture start id = %d", deviceID);
//   if (deviceID != 0) {
//     if (!setEngineDevice(engine, deviceID, true)) {
//       return false;
//     }
//   }

//   AVAudioFormat *hwFormat = [engine.inputNode inputFormatForBus:0];
//   NSLog(@"capture HW format: %@", hwFormat);

//   UInt32 bufferFrames = 0;
//   UInt32 dataSize = sizeof(bufferFrames);
//   AudioUnitGetProperty(engine.inputNode.audioUnit,
//                        kAudioUnitProperty_MaximumFramesPerSlice,
//                        kAudioUnitScope_Global, 0, &bufferFrames,
//                        &dataSize);

//   NSLog(@"input device bufferFrames %d", bufferFrames);

//   // The mixer will receive the hardware format and output our desired mono
//   AVAudioMixerNode *mixer = [[AVAudioMixerNode alloc] init];
//   manager.mixerNode = mixer;
//   [engine attachNode:mixer];
//   [engine connect:engine.inputNode to:mixer format:hwFormat];

//   AVAudioFormat *downMixFormat =
//       [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
//                                        sampleRate:hwFormat.sampleRate
//                                          channels:1
//                                       interleaved:NO];

//   AVAudioFormat *outputFormat =
//       [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
//                                        sampleRate:hwFormat.sampleRate
//                                          channels:1
//                                       interleaved:NO];

//   AVAudioConverter *converter = nil;
//   if (hwFormat.sampleRate != kSampleRate) {
//     converter = [[AVAudioConverter alloc] initFromFormat:downMixFormat
//                                                 toFormat:outputFormat];
//   }

//   AVAudioSinkNode *sink = [[AVAudioSinkNode alloc]
//       initWithReceiverBlock:^OSStatus(const AudioTimeStamp *timestamp,
//                                       AVAudioFrameCount frameCount,
//                                       const AudioBufferList *inputData) {
//         if (converter) {
//           // Compute how many output frames we expect after resampling
//           AVAudioFrameCount outFrameCount = (AVAudioFrameCount)ceil(
//               frameCount * kSampleRate / downMixFormat.sampleRate);

//           AVAudioPCMBuffer *inputBuffer =
//               [[AVAudioPCMBuffer alloc] initWithPCMFormat:downMixFormat
//                                             frameCapacity:frameCount];
//           inputBuffer.frameLength = frameCount;
//           // Copy the AudioBufferList data into the AVAudioPCMBuffer
//           memcpy(inputBuffer.audioBufferList->mBuffers[0].mData,
//                  inputData->mBuffers[0].mData,
//                  inputData->mBuffers[0].mDataByteSize);

//           AVAudioPCMBuffer *outputBuffer =
//               [[AVAudioPCMBuffer alloc] initWithPCMFormat:outputFormat
//                                             frameCapacity:outFrameCount];

//           NSError *convError = nil;
//           __block BOOL inputConsumed = NO;
//           AVAudioConverterOutputStatus status =
//               [converter convertToBuffer:outputBuffer
//                                    error:&convError
//                       withInputFromBlock:^AVAudioBuffer *(
//                           AVAudioPacketCount inNumPackets,
//                           AVAudioConverterInputStatus *outStatus) {
//                         if (inputConsumed) {
//                           *outStatus =
//                           AVAudioConverterInputStatus_NoDataNow; return
//                           nil;
//                         }
//                         *outStatus = AVAudioConverterInputStatus_HaveData;
//                         inputConsumed = YES;
//                         return inputBuffer;
//                       }];

//           if (status == AVAudioConverterOutputStatus_Error) {
//             NSLog(@"AVAudioConverter error: %@", convError);
//             return noErr;
//           }

//           aweboAudioCapturePush(userdata, outputBuffer.floatChannelData[0],
//                                 outputBuffer.frameLength);
//         } else {
//           const float *samples = (const float
//           *)inputData->mBuffers[0].mData; aweboAudioCapturePush(userdata,
//           samples, frameCount);
//         }
//         return noErr;
//       }];

//   manager.sinkNode = sink;
//   [engine attachNode:sink];
//   [engine connect:mixer to:sink format:downMixFormat];

//   NSError *error = nil;
//   if (![engine startAndReturnError:&error]) {
//     NSLog(@"audioCaptureStart failed: %@", error);
//     return false;
//   }

//   NSLog(@"audio capture started (device %u)", deviceID);
//   return true;
