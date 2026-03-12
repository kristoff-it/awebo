#import "video.h"
#import <AVFoundation/AVFoundation.h>
#import <VideoToolbox/VideoToolbox.h>

CVPixelBufferRef aweboVideoSwapFrame(void *, CVPixelBufferRef);
__attribute__((weak)) CVPixelBufferRef
aweboVideoSwapFrame(void *userdata, CVPixelBufferRef ref) {
  __builtin_unreachable();
}

// ---------------------------------------------

// ─── Codec Capability Probe
// ───────────────────────────────────────────────────

// static BOOL VTHasHardwareDecoder(CMVideoCodecType codec) {
//   // VTIsHardwareDecodeSupported is the correct API for decode (unlike
//   encode) if (@available(macOS 11.0, *)) {
//     return VTIsHardwareDecodeSupported(codec);
//   }
//   return NO;
// }

// static CMVideoCodecType SelectBestDecoderCodec(void) {
//   // AV1: Apple Silicon M3 / A17 Pro and later
//   if (@available(macOS 14.0, *)) {
//     if (VTHasHardwareDecoder(kCMVideoCodecType_AV1)) {
//       NSLog(@"AV1  hardware decoder available");
//       return kCMVideoCodecType_AV1;
//     }
//     NSLog(@"AV1  hardware decoder unavailable");
//   }

//   // HEVC: Apple Silicon + Intel Macs with T1/T2, AMD Vega
//   if (@available(macOS 10.13, *)) {
//     if (VTHasHardwareDecoder(kCMVideoCodecType_HEVC)) {
//       NSLog(@"HEVC hardware decoder available");
//       return kCMVideoCodecType_HEVC;
//     }
//     NSLog(@"HEVC hardware decoder unavailable");
//   }

//   NSLog(@"H.264 software decoder (universal fallback)");
//   return kCMVideoCodecType_H264;
// }

// ─── Format Description Factory ──────────────────────────────────────────────

// Build a minimal CMVideoFormatDescription from raw SPS+PPS NAL units (H.264)
// or from VPS+SPS+PPS (HEVC), or OBU sequence header (AV1).
// In a real pipeline these come from your container (MP4/MKV/ISOBMFF) demuxer.

static CMVideoFormatDescriptionRef
CreateFormatDescription(CMVideoCodecType codec, int32_t width, int32_t height,
                        const uint8_t *data) {
  CMVideoFormatDescriptionRef fmtDesc = NULL;
  OSStatus status = noErr;

  if (codec == kCMVideoCodecType_H264) {
    // Stub: in production, parse real SPS/PPS from the bitstream
    // CMVideoFormatDescriptionCreateFromH264ParameterSets(...)
    const H264ParamHeader *h = (H264ParamHeader *)data;
    const uint8_t *params[] = {data + sizeof(*h),
                               data + sizeof(*h) + h->sps_length};
    size_t sizes[] = {(size_t)h->sps_length, (size_t)h->pps_length};

    status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        kCFAllocatorDefault,
        2, // parameter set count
        params, sizes,
        4, // NAL unit header length (4 bytes)
        &fmtDesc);

  } else if (codec == kCMVideoCodecType_HEVC) {
    // VPS + SPS + PPS from the HEVC bitstream
    const HEVCParamHeader *h = (HEVCParamHeader *)data;
    const uint8_t *params[] = {
        data + sizeof(*h),
        data + sizeof(*h) + h->vps_length,
        data + sizeof(*h) + h->vps_length + h->sps_length,
    };
    size_t sizes[] = {(size_t)h->vps_length, (size_t)h->sps_length,
                      (size_t)h->pps_length};

    status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
        kCFAllocatorDefault, 3, params, sizes, 4,
        NULL, // extensions (HDR metadata, colour info, etc.)
        &fmtDesc);
  } else if (codec == kCMVideoCodecType_AV1) {
    if (@available(macOS 14.0, *)) {
      // For AV1 the "parameter set" is the AV1CodecConfigurationRecord
      // extracted from the 'av1C' box in ISOBMFF.
      // VT accepts it via extensions dict under
      // kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms
      uint8_t av1CData[] = {/* real av1C bytes */ 0};
      CFDataRef av1C =
          CFDataCreate(kCFAllocatorDefault, av1CData, sizeof(av1CData));

      CFStringRef atomKey = CFSTR("av1C");
      CFDictionaryRef atoms = CFDictionaryCreate(
          kCFAllocatorDefault, (const void **)&atomKey, (const void **)&av1C, 1,
          &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      CFRelease(av1C);

      CFStringRef extKey =
          kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms;
      CFDictionaryRef extensions = CFDictionaryCreate(
          kCFAllocatorDefault, (const void **)&extKey, (const void **)&atoms, 1,
          &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
      CFRelease(atoms);

      status = CMVideoFormatDescriptionCreate(kCFAllocatorDefault,
                                              kCMVideoCodecType_AV1, width,
                                              height, extensions, &fmtDesc);
      CFRelease(extensions);
    }
  }

  if (status != noErr) {
    NSLog(@"❌ CMVideoFormatDescriptionCreate failed: %d", (int)status);
    return NULL;
  }
  return fmtDesc;
}

// ─── Decoder ─────────────────────────────────────────────────────────────────

@interface VideoDecoder : NSObject
@property VTDecompressionSessionRef decompressionSession;
@property CMVideoFormatDescriptionRef formatDescription;
@property CMVideoCodecType codec;
@property int32_t width;
@property int32_t height;
@property void *userdata;
@end

@implementation VideoDecoder

void *videoDecoderInit(void *userdata, UInt32 codec, UInt32 width,
                       UInt32 height, const uint8_t *data) {
  VideoDecoder *decoder = [[VideoDecoder alloc] init];
  if (!decoder)
    return nil;

  decoder.userdata = userdata;
  decoder.width = width;
  decoder.height = height;
  if (codec == 0) {
    decoder.codec = kCMVideoCodecType_H264;
  } else if (codec == 1) {
    decoder.codec = kCMVideoCodecType_HEVC;
  } else if (codec == 2) {
    decoder.codec = kCMVideoCodecType_AV1;
  } else {
    __builtin_unreachable();
  }

  decoder.formatDescription =
      CreateFormatDescription(decoder.codec, width, height, data);

  if (!decoder.formatDescription)
    return nil;

  [decoder _createDecompressionSession];

  return (__bridge_retained void *)decoder;
}

// ─── Session Creation
// ─────────────────────────────────────────────────────────

- (void)_createDecompressionSession {
  // Destination pixel format: 420v is the most efficient path for all three
  // codecs. Use 'P010' (kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) for
  // HDR/10-bit HEVC or AV1.
  BOOL wantHDR = NO; // (_codec == kCMVideoCodecType_HEVC || _codec ==
                     // kCMVideoCodecType_AV1);
  // OSType pixelFmt =
  //     wantHDR ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange // 10-bit
  //     P010
  //             : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange; //  8-bit
  //             420v
  OSType pixelFmt = kCVPixelFormatType_32BGRA;

  NSDictionary *destAttrs = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(pixelFmt),
    (id)kCVPixelBufferWidthKey : @(self.width),
    (id)kCVPixelBufferHeightKey : @(self.height),
    // IOSurface-backed buffers allow zero-copy hand-off to Metal / CoreImage
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };

  VTDecompressionOutputCallbackRecord callbackRecord = {
      .decompressionOutputCallback = DecodedFrameCallback,
      .decompressionOutputRefCon = (__bridge void *)self};

  // Ask for hardware decoding
  NSDictionary *sessionProps = @{
    (id)
    kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder : @YES,
    (id)kVTDecompressionPropertyKey_ContentHasInterframeDependencies : @NO,
    // Prevents silent fallback to SW if HW is mandatory for your use case:
    // (id)kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder:
    // @YES,
  };

  VTDecompressionSessionRef ds;
  OSStatus status = VTDecompressionSessionCreate(
      kCFAllocatorDefault, self.formatDescription,
      (__bridge CFDictionaryRef)sessionProps,
      (__bridge CFDictionaryRef)destAttrs, &callbackRecord, &ds);

  if (status != noErr) {
    NSLog(@"VTDecompressionSessionCreate failed: %d", (int)status);
    return;
  }

  self.decompressionSession = ds;

  // Confirm whether HW was actually granted
  CFBooleanRef usingHW = NULL;
  VTSessionCopyProperty(
      _decompressionSession,
      kVTDecompressionPropertyKey_UsingHardwareAcceleratedVideoDecoder,
      kCFAllocatorDefault, &usingHW);

  NSLog(@"%@ decoder session created (%@)", [self _codecName],
        (usingHW &&CFBooleanGetValue(usingHW)) ? @"hardware" : @"software");

  if (usingHW)
    CFRelease(usingHW);
}

// ─── Decode
// ───────────────────────────────────────────────────────────────────
// ─── Call this when your UDP reassembly has a complete frame ─────────────────

UInt32 videoReceivedFrameBytes(void *ptr, const char *buffer, size_t len,
                               BOOL keyframe) {

  VideoDecoder *decoder = (__bridge VideoDecoder *)ptr;

  if (keyframe) {

    size_t skip;

    if (decoder.codec == kCMVideoCodecType_H264) {
      const H264ParamHeader *h = (H264ParamHeader *)buffer;
      skip = sizeof(*h) + h->sps_length + h->pps_length;
    } else if (decoder.codec == kCMVideoCodecType_HEVC) {
      const HEVCParamHeader *h = (HEVCParamHeader *)buffer;
      skip = sizeof(*h) + h->vps_length + h->sps_length + h->pps_length;
    } else if (decoder.codec == kCMVideoCodecType_AV1) {
      __builtin_unreachable();
    }

    [decoder receivedFrameBytes:buffer + skip + sizeof(UInt32)
                    totalLength:len - skip - sizeof(UInt32)
                     isKeyFrame:keyframe];

    UInt32 pts;
    memcpy(&pts, buffer + skip, sizeof(pts));
    return pts;
  } else {

    [decoder receivedFrameBytes:buffer + sizeof(UInt32)
                    totalLength:len - sizeof(UInt32)
                     isKeyFrame:keyframe];

    return *(UInt32 *)buffer;
  }
}

- (void)receivedFrameBytes:(const char *)buffer
               totalLength:(size_t)totalLength
                isKeyFrame:(BOOL)isKeyFrame {

  // ── 2. Rebuild CMBlockBuffer (zero-copy via kCMBlockBufferAlwaysCopyDataFlag
  //       = NO; the buffer must stay alive until the callback fires) ─────
  CMBlockBufferRef blockBuffer = NULL;
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault,
      (void *)buffer, // backing store — owned by your reassembly buffer
      totalLength,
      kCFAllocatorNull, // do NOT free: you manage this memory
      NULL,             // custom block source
      0,                // offset
      totalLength,
      0, // flags
      &blockBuffer);

  if (status != noErr || !blockBuffer) {
    NSLog(@"CMBlockBufferCreateWithMemoryBlock failed: %d", (int)status);
    return;
  }

  // ── 3. Rebuild timing ─────────────────────────────────────────────────
  CMTime pts = CMTimeMake(1, 30);

  // CMTime pts = CMTimeMake((int64_t)header.pts_value, header.pts_timescale);
  // CMTime dur =
  //     CMTimeMake((int64_t)header.duration_value, header.duration_timescale);

  CMSampleTimingInfo timing = {
      .duration = kCMTimeInvalid,
      .presentationTimeStamp = pts,
      .decodeTimeStamp = kCMTimeInvalid, // let VT infer DTS
  };

  // ── 4. Rebuild CMSampleBuffer ─────────────────────────────────────────
  // _formatDescription was created once at session setup (same as before)
  CMSampleBufferRef sampleBuffer = NULL;
  status = CMSampleBufferCreateReady(
      kCFAllocatorDefault, blockBuffer,
      _formatDescription, // the VTDecompressionSession's format desc
      1,                  // numSamples
      1,                  // numSampleTimingEntries
      &timing,
      1, // numSampleSizeEntries
      &totalLength, &sampleBuffer);
  CFRelease(blockBuffer);

  if (status != noErr || !sampleBuffer) {
    NSLog(@"CMSampleBufferCreateReady failed: %d", (int)status);
    return;
  }

  // ── 5. Tag keyframes (VT needs this to manage reference frames) ───────
  if (isKeyFrame) {
    CFArrayRef attachments =
        CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    CFMutableDictionaryRef att =
        (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(att, kCMSampleAttachmentKey_DisplayImmediately,
                         kCFBooleanTrue);
  }

  // ── 6. Decode ─────────────────────────────────────────────────────────
  [self decodeFrame:sampleBuffer];
  CFRelease(sampleBuffer);
}

- (void)decodeFrame:(CMSampleBufferRef)sampleBuffer {
  if (!_decompressionSession)
    return;

  // Decode asynchronously; callback fires on an internal VT thread
  // VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression |
  //                            kVTDecodeFrame_1xRealTimePlayback;
  VTDecodeFrameFlags flags = kVTDecodeFrame_1xRealTimePlayback;
  VTDecodeInfoFlags infoFlags;

  OSStatus status = VTDecompressionSessionDecodeFrame(
      _decompressionSession, sampleBuffer, flags,
      NULL, // sourceFrameRefCon — thread through any per-frame metadata
      &infoFlags);

  if (status != noErr) {
    NSLog(@"VTDecompressionSessionDecodeFrame failed: %d", (int)status);
  }

  if (infoFlags & kVTDecodeInfo_FrameDropped) {
    NSLog(@"Frame dropped by decoder");
  }
}

// ─── Decoded Frame
// ───────────────────────────────────────────────────

static void DecodedFrameCallback(void *decompressionOutputRefCon,
                                 void *sourceFrameRefCon, OSStatus status,
                                 VTDecodeInfoFlags infoFlags,
                                 CVImageBufferRef imageBuffer,
                                 CMTime presentationTimeStamp,
                                 CMTime presentationDuration) {
  if (status != noErr || !imageBuffer) {
    NSLog(@"Decode error: %d", (int)status);
    return;
  }

  // imageBuffer is a CVPixelBuffer backed by IOSurface —
  // hand it to Metal, CoreImage, AVSampleBufferDisplayLayer, etc.
  size_t width = CVPixelBufferGetWidth(imageBuffer);
  size_t height = CVPixelBufferGetHeight(imageBuffer);
  OSType fmt = CVPixelBufferGetPixelFormatType(imageBuffer);

  // NSLog(@"Decoded frame %lld | %lld | fmt: %.4s",
  // presentationTimeStamp.value,
  //       presentationDuration.value, (char *)&fmt);

  VideoDecoder *decoder = (__bridge VideoDecoder *)decompressionOutputRefCon;

  CVPixelBufferRetain(imageBuffer);
  CVPixelBufferRef dropped_frame =
      aweboVideoSwapFrame(decoder.userdata, imageBuffer);

  if (dropped_frame) {
    NSLog(@"decoder found dropped frame, releasing");
    CVPixelBufferRelease(dropped_frame);
  }
}

// ─── Session Management
// ───────────────────────────────────────────────────────

- (void)flush {
  if (_decompressionSession) {
    // Block until all queued frames are delivered
    VTDecompressionSessionWaitForAsynchronousFrames(_decompressionSession);
  }
}

- (void)invalidate {
  if (_decompressionSession) {
    VTDecompressionSessionInvalidate(_decompressionSession);
    CFRelease(_decompressionSession);
    _decompressionSession = NULL;
  }
  if (_formatDescription) {
    CFRelease(_formatDescription);
    _formatDescription = NULL;
  }
}

- (void)dealloc {
  [self invalidate];
}

// ─── Helpers
// ──────────────────────────────────────────────────────────────────

- (NSString *)_codecName {
  switch (_codec) {
  case kCMVideoCodecType_AV1:
    return @"AV1";
  case kCMVideoCodecType_HEVC:
    return @"HEVC";
  default:
    return @"H.264";
  }
}

@end