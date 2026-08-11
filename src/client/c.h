#include "awebo/c.h"

#include "libavcodec/avcodec.h"
#include "libavutil/avutil.h"
#include "libavutil/pixdesc.h"
#include <errno.h>

// @cInclude("libavutil/frame.h");
// @cInclude("libavutil/mem.h");
// @cInclude("libavutil/error.h");
// if (builtin.os.tag == .macos) {
//     @cInclude("VideoToolbox/VideoToolbox.h");
// }
