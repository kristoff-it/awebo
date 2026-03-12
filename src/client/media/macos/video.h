#pragma once

#import <CoreMedia/CoreMedia.h>
#import <VideoToolbox/VideoToolbox.h>

typedef struct Image {
  size_t width;
  size_t height;
  uint8_t *pixels;
} Image;

// ─── Wire codec IDs
typedef NS_ENUM(uint8_t, WireCodecID) {
  WireCodecH264 = 0,
  WireCodecHEVC = 1,
  WireCodecAV1 = 2,
};

#pragma pack(push, 1)
// H.264 — SPS + PPS
// [0x00][sps_len:2][pps_len:2][sps bytes][pps bytes]
typedef struct {
  uint8_t codec_id; // WireCodecH264
  uint16_t sps_length;
  uint16_t pps_length;
} H264ParamHeader;

// H.265 — VPS + SPS + PPS
// [0x01][vps_len:2][sps_len:2][pps_len:2][vps bytes][sps bytes][pps bytes]
typedef struct {
  uint8_t codec_id; // WireCodecHEVC
  uint16_t vps_length;
  uint16_t sps_length;
  uint16_t pps_length;
} HEVCParamHeader;

// AV1 — av1C config record (the `av1C` box from ISOBMFF)
// [0x02][av1c_len:2][av1c bytes]
typedef struct {
  uint8_t codec_id; // WireCodecAV1
  uint16_t av1c_length;
} AV1ParamHeader;
#pragma pack(pop)
