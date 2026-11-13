#include "awebo/c.h"

// opus
#include "opus.h"

// speex (opus-tools)
#define OUTSIDE_SPEEX 1
#define RANDOM_PREFIX speex
#include "speex_resampler.h"

// ffmpeg
#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libavutil/pixdesc.h"
#include "libswscale/swscale.h"
#include <errno.h>

#ifdef __APPLE__
#include <CoreAudio/CoreAudio.h>
#endif

#ifdef __linux__
    #include <linux/videodev2.h>
    // #include <va/va.h>
    // #include <va/va_wayland.h>
#endif

// @cInclude("libavutil/frame.h");
// @cInclude("libavutil/mem.h");
// @cInclude("libavutil/error.h");
// if (builtin.os.tag == .macos) {
//     @cInclude("VideoToolbox/VideoToolbox.h");
// }
