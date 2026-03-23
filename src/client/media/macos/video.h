#pragma once

#import <CoreMedia/CoreMedia.h>

typedef struct RawImage {
  UInt32 width;
  UInt32 height;
  UInt8 *ptr1;
  UInt8 *ptr2;
  UInt8 *ptr3;
  UInt32 stride1;
  UInt32 stride2;
  UInt32 stride3;
  UInt8 img_kind;
} RawImage;

// Must be kept in sync with awebo.protocol.media.Format.Codec
typedef NS_ENUM(UInt8, AweboPixelFmtID) {
  AweboYUV = 0,
  AweboNV12 = 1,
  AweboVideoToolbox = 2,
  AweboBGRA = 3,
};
