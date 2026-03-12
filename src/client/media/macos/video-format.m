#include "video-format.h"
#include "video.h"

#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

@implementation VTParamSetSerializer

+ (nullable NSData *)serializeFormatDescription:
                         (CMVideoFormatDescriptionRef)fmtDesc
                                          delta:(UInt32)delta
                                           data:(const char *)data
                                            len:(size_t)len {
  CMVideoCodecType codec = CMFormatDescriptionGetMediaSubType(fmtDesc);
  switch (codec) {
  case kCMVideoCodecType_H264:
    return [self _serializeH264:fmtDesc delta:delta data:data len:len];
  case kCMVideoCodecType_HEVC:
    return [self _serializeHEVC:fmtDesc delta:delta data:data len:len];
  case kCMVideoCodecType_AV1:
    return [self _serializeAV1:fmtDesc delta:delta data:data len:len];
  default:
    NSLog(@"❌ Unsupported codec for param serialization: %d", codec);
    return nil;
  }
}

// ─── H.264
// ────────────────────────────────────────────────────────────────────

+ (nullable NSData *)_serializeH264:(CMVideoFormatDescriptionRef)fmtDesc
                              delta:(UInt32)delta
                               data:(const char *)data
                                len:(size_t)len {

  const uint8_t *spsPtr = NULL;
  size_t spsLen = 0;
  const uint8_t *ppsPtr = NULL;
  size_t ppsLen = 0;

  // SPS is index 0, PPS is index 1 (VT always orders them this way)
  CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmtDesc, 0, &spsPtr,
                                                     &spsLen, NULL, NULL);
  CMVideoFormatDescriptionGetH264ParameterSetAtIndex(fmtDesc, 1, &ppsPtr,
                                                     &ppsLen, NULL, NULL);

  if (spsLen > UINT16_MAX || ppsLen > UINT16_MAX) {
    NSLog(@"H264 param set too large");
    return nil;
  }

  H264ParamHeader header = {
      .codec_id = WireCodecH264,
      .sps_length = (uint16_t)spsLen,
      .pps_length = (uint16_t)ppsLen,
  };

  NSMutableData *out = [NSMutableData
      dataWithCapacity:sizeof(header) + spsLen + ppsLen + sizeof(UInt32) + len];
  [out appendBytes:&header length:sizeof(header)];
  [out appendBytes:spsPtr length:spsLen];
  [out appendBytes:ppsPtr length:ppsLen];
  [out appendBytes:&delta length:sizeof(UInt32)];
  [out appendBytes:data length:len];
  return out;
}

// ─── H.265 / HEVC
// ─────────────────────────────────────────────────────────────

+ (nullable NSData *)_serializeHEVC:(CMVideoFormatDescriptionRef)fmtDesc
                              delta:(UInt32)delta
                               data:(const char *)data
                                len:(size_t)len {

  // VPS = 0, SPS = 1, PPS = 2
  const uint8_t *params[3];
  size_t sizes[3];
  for (size_t i = 0; i < 3; i++) {
    CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(fmtDesc, i, &params[i],
                                                       &sizes[i], NULL, NULL);
  }

  size_t vpsLen = sizes[0], spsLen = sizes[1], ppsLen = sizes[2];
  if (vpsLen > UINT16_MAX || spsLen > UINT16_MAX || ppsLen > UINT16_MAX) {
    NSLog(@"HEVC param set too large");
    return nil;
  }

  HEVCParamHeader header = {
      .codec_id = WireCodecHEVC,
      .vps_length = (uint16_t)vpsLen,
      .sps_length = (uint16_t)spsLen,
      .pps_length = (uint16_t)ppsLen,
  };

  NSMutableData *out =
      [NSMutableData dataWithCapacity:sizeof(header) + vpsLen + spsLen +
                                      ppsLen + sizeof(UInt32) + len];
  [out appendBytes:&header length:sizeof(header)];
  [out appendBytes:params[0] length:vpsLen]; // VPS
  [out appendBytes:params[1] length:spsLen]; // SPS
  [out appendBytes:params[2] length:ppsLen]; // PPS
  [out appendBytes:&delta length:sizeof(UInt32)];
  [out appendBytes:data length:len];

  NSMutableString *hex = [NSMutableString string];
  const uint8_t *bytes = (const uint8_t *)out.bytes;

  for (NSUInteger i = 0; i < sizeof(header) + vpsLen + spsLen + ppsLen; i++) {
    [hex appendFormat:@"%02X", bytes[i]];
  }
  NSLog(@"Codec Data Out: %@", hex);

  return out;
}

// ─── AV1
// ──────────────────────────────────────────────────────────────────────

+ (nullable NSData *)_serializeAV1:(CMVideoFormatDescriptionRef)fmtDesc
                             delta:(UInt32)delta
                              data:(const char *)data
                               len:(size_t)len {
  if (@available(macOS 14.0, *)) {
    CFDictionaryRef extensions = CMFormatDescriptionGetExtensions(fmtDesc);
    if (!extensions) {
      NSLog(@"❌ AV1: no extensions");
      return nil;
    }

    CFDictionaryRef atoms = CFDictionaryGetValue(
        extensions,
        kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms);
    if (!atoms) {
      NSLog(@"❌ AV1: no atom dict");
      return nil;
    }

    CFDataRef av1C = CFDictionaryGetValue(atoms, CFSTR("av1C"));
    if (!av1C) {
      NSLog(@"❌ AV1: no av1C atom");
      return nil;
    }

    size_t av1cLen = (size_t)CFDataGetLength(av1C);
    if (av1cLen > UINT16_MAX) {
      NSLog(@"❌ AV1: av1C too large");
      return nil;
    }

    AV1ParamHeader header = {
        .codec_id = WireCodecAV1,
        .av1c_length = (uint16_t)av1cLen,
    };

    NSMutableData *out = [NSMutableData
        dataWithCapacity:sizeof(header) + av1cLen + sizeof(UInt32) + len];
    [out appendBytes:&header length:sizeof(header)];
    [out appendBytes:CFDataGetBytePtr(av1C) length:av1cLen];
    [out appendBytes:&delta length:sizeof(UInt32)];
    [out appendBytes:data length:len];
    return out;
  }
  return nil;
}

@end
