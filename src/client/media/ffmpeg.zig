const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const awebo = @import("../../awebo.zig");
const media = awebo.protocol.media;
const log = std.log.scoped(.@"ffmpeg-decoder");
const VideoStream = @import("VideoStream.zig");

pub const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/avutil.h");
    // @cInclude("libavutil/frame.h");
    // @cInclude("libavutil/mem.h");
    // @cInclude("libavutil/error.h");
    @cInclude("libavutil/pixdesc.h");
    @cInclude("errno.h");

    // if (builtin.os.tag == .macos) {
    //     @cInclude("VideoToolbox/VideoToolbox.h");
    // }
});

/// Concrete codec implementation being used in a video stream.
pub const Codec = struct {
    name: [:0]const u8,
    /// The protocol-level codec tag which will be used by other clients to
    /// decode the stream (likely using a different concrete implementation
    /// of the same codec).
    kind: media.Format.Codec,

    /// Whether we are currently using a software or a hardware encoder.
    /// This information is statically known for some codec
    /// implementations, while for hardware implementations (called
    /// 'hybrid' by ffmpeg) , in some cases they might internally fallback
    /// to software operation if the hardware unit is busy (e.g.
    /// VideoToolbox). The encoder / decoder init function should take care
    /// to probe hybrid codecs to learn what the operating mode is for the
    /// current session.
    software: bool = false,

    /// Preferred pixel format by the codec which will then be used:
    /// - as output from camera/screen capture in case of encoding
    /// - as output to be rendered in case of decoding
    /// This value is hardcoded manually and chosen by crossreferencing the
    /// capabilities of each codec implementation (by reading ffmpeg source
    /// code) and what other subsystems are capable of outputting and/or
    /// rendering.
    /// For example ScreenCaptureKit on macOS can only output NV12
    /// (biplanar 4:2:0 YUV) so this pixel format will be preferred over,
    /// say, 3-planar YUV even if this format is listed above NV12 in
    /// ffmpeg.
    pix_fmt: c.AVPixelFormat,

    fn kindToAvCodecId(mfc: media.Format.Codec) c.AVCodecID {
        return switch (mfc) {
            .h264 => c.AV_CODEC_ID_H264,
            .hevc => c.AV_CODEC_ID_HEVC,
            .av1 => c.AV_CODEC_ID_AV1,
            .ffv1 => c.AV_CODEC_ID_FFV1,
        };
    }

    pub fn lossless(mfc: media.format.Codec) bool {
        return switch (mfc) {
            .h264, .hevc, .av1 => false,
            .ffv1,
            => true,
        };
    }

    pub fn pixFmtToImageKind(codec: *const Codec) VideoStream.ImageKind {
        return switch (codec.pix_fmt) {
            c.AV_PIX_FMT_VIDEOTOOLBOX => .videotoolbox,
            c.AV_PIX_FMT_YUV420P => .yuv,
            c.AV_PIX_FMT_NV12 => .nv12,
            c.AV_PIX_FMT_BGRA => .bgra,
            else => unreachable,
        };
    }
};

const candidates: struct {
    lossless: []const Codec,
    lossy: []const Codec,
} = switch (builtin.os.tag) {
    else => @compileError("TODO: define codec candidates for OS"),
    .macos => .{
        .lossless = &.{
            .{ .name = "ffv1", .kind = .ffv1, .software = true, .pix_fmt = c.AV_PIX_FMT_BGRA },
        },
        .lossy = &.{
            // .{ .name = "hevc_videotoolbox", .kind = .hevc, .pix_fmt = c.AV_PIX_FMT_NV12 },
            // .{ .name = "h264_videotoolbox", .kind = .h264, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "hevc_videotoolbox", .kind = .hevc, .pix_fmt = c.AV_PIX_FMT_VIDEOTOOLBOX },
            .{ .name = "h264_videotoolbox", .kind = .h264, .pix_fmt = c.AV_PIX_FMT_VIDEOTOOLBOX },
            // No fallback, all supported macOS devices should have at least one of these available.
        },
    },
    .linux, .windows => .{
        .lossless = &.{
            //ffv1
            .{ .name = "ffv1_vulkan", .kind = .ffv1, .pix_fmt = c.AV_PIX_FMT_VULKAN },
            .{ .name = "ffv1", .kind = .ffv1, .pix_fmt = c.AV_PIX_FMT_YUV420P },
        },
        .lossy = &.{
            //av1
            .{ .name = "av1_nvenc", .kind = .av1, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "av1_amf", .kind = .av1, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "av1_qsv", .kind = .av1, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "av1_vaapi", .kind = .av1, .pix_fmt = c.AV_PIX_FMT_VAAPI },
            //hevc
            .{ .name = "hevc_nvenc", .kind = .hevc, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "hevc_amf", .kind = .hevc, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "hevc_qsv", .kind = .hevc, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "hevc_vaapi", .kind = .hevc, .pix_fmt = c.AV_PIX_FMT_VAAPI },
            //h264
            .{ .name = "h264_nvenc", .kind = .h264, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "h264_amf", .kind = .h264, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "h264_qsv", .kind = .h264, .pix_fmt = c.AV_PIX_FMT_NV12 },
            .{ .name = "h264_vaapi", .kind = .h264, .pix_fmt = c.AV_PIX_FMT_VAAPI },
        },
    },
};

pub const Encoder = struct {
    codec: Codec,
    ctx: *c.AVCodecContext,
    frame: *c.AVFrame,
    packet: *c.AVPacket,

    pub fn init(lossless: bool, config: media.Config) !Encoder {
        const list = if (lossless)
            candidates.lossless
        else
            candidates.lossy;

        for (list) |candidate| {
            const codec: *const c.AVCodec = c.avcodec_find_encoder_by_name(candidate.name.ptr) orelse {
                log.debug("unable to find codec '{s}', skipping", .{candidate.name});
                continue;
            };

            var ctx: *c.AVCodecContext = c.avcodec_alloc_context3(codec) orelse
                return error.OutOfMemory;
            errdefer c.avcodec_free_context(@ptrCast(&ctx));

            switch (candidate.pix_fmt) {
                c.AV_PIX_FMT_VIDEOTOOLBOX => {
                    var device_ctx: *c.AVBufferRef = undefined;
                    {
                        const ret = c.av_hwdevice_ctx_create(
                            @ptrCast(&device_ctx),
                            c.AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                            null,
                            null,
                            0,
                        );

                        if (ret < 0) {
                            std.log.debug("failed hwdevice ctx init: {s}", .{err2str(ret)});
                            return error.FailedHardwareInit;
                        }
                    }

                    const frame_ctx_ref: *c.AVBufferRef = c.av_hwframe_ctx_alloc(device_ctx) orelse
                        return error.OutOfMemory;

                    const frame_ctx: *c.AVHWFramesContext = @ptrCast(@alignCast(frame_ctx_ref.data));
                    frame_ctx.format = c.AV_PIX_FMT_VIDEOTOOLBOX;
                    frame_ctx.sw_format = c.AV_PIX_FMT_NV12;
                    frame_ctx.width = config.width;
                    frame_ctx.height = config.height;
                    frame_ctx.initial_pool_size = 0;
                    const ret = c.av_hwframe_ctx_init(frame_ctx_ref);

                    if (ret < 0) {
                        std.log.debug("failed hwframes ctx init: {s}", .{err2str(ret)});
                        return error.FailedHardwareInit;
                    }

                    ctx.hw_frames_ctx = c.av_buffer_ref(frame_ctx_ref);
                },
                else => {},
            }

            ctx.width = @intCast(config.width);
            ctx.height = @intCast(config.height);
            ctx.time_base = .{ .num = 1, .den = config.fps };
            ctx.framerate = .{ .num = config.fps, .den = 1 };
            ctx.bit_rate = 3_500_000;
            ctx.pix_fmt = candidate.pix_fmt;
            ctx.flags = c.AV_CODEC_FLAG_LOW_DELAY | c.AV_CODEC_FLAG_GLOBAL_HEADER;
            ctx.flags2 = c.AV_CODEC_FLAG2_FAST;
            ctx.gop_size = config.fps * 2;
            ctx.max_b_frames = 0;
            // ctx.color_range = c.AVCOL_RANGE_JPEG;

            // _ = c.av_opt_set_int(ctx, "loglevel", c.AV_LOG_FATAL, 0);

            if (c.avcodec_open2(ctx, codec, null) < 0) {
                log.debug("unable to open codec '{s}', skipping", .{candidate.name});
                continue;
            }

            log.debug("initialized encoder '{s}' ({t}, {t})", .{ candidate.name, candidate.kind, candidate.pixFmtToImageKind() });

            return .{
                .codec = candidate,
                .ctx = ctx,
                .frame = c.av_frame_alloc() orelse return error.OutOfMemory,
                .packet = c.av_packet_alloc() orelse return error.OutOfMemory,
            };
        }

        return error.NoSuitableCodec;
    }

    pub fn deinit(e: *Encoder) void {
        c.avcodec_free_context(@ptrCast(&e.ctx));
        c.av_packet_free(@ptrCast(&e.packet));
        c.av_frame_free(@ptrCast(&e.frame));
    }

    pub fn encode(e: *Encoder, img: VideoStream.Image) !?struct { []const u8, []const u8 } {
        e.frame.pts = 0;
        switch (e.codec.pix_fmt) {
            c.AV_PIX_FMT_VIDEOTOOLBOX => {
                const i = img.videotoolbox;
                e.frame.format = c.AV_PIX_FMT_VIDEOTOOLBOX;
                e.frame.width = @intCast(i.width);
                e.frame.height = @intCast(i.height);
                e.frame.data[3] = @ptrCast(i.ptr);
                e.frame.buf[0] = c.av_buffer_create(@ptrCast(i.ptr), 0, &struct {
                    fn noop(_: ?*anyopaque, _: ?[*]u8) callconv(.c) void {}
                }.noop, @ptrCast(i.ptr), c.AV_BUFFER_FLAG_READONLY);
                e.frame.hw_frames_ctx = c.av_buffer_ref(e.ctx.hw_frames_ctx);
            },
            c.AV_PIX_FMT_NV12 => {
                const i = img.nv12;
                e.frame.format = c.AV_PIX_FMT_NV12;
                e.frame.width = @intCast(i.width);
                e.frame.height = @intCast(i.height);
                e.frame.data[0] = i.y;
                e.frame.data[1] = i.cbcr;
                e.frame.linesize[0] = @intCast(i.y_stride);
                e.frame.linesize[1] = @intCast(i.cbcr_stride);
            },
            c.AV_PIX_FMT_BGRA => {
                const i = img.bgra;
                e.frame.format = c.AV_PIX_FMT_BGRA;
                e.frame.width = @intCast(i.width);
                e.frame.height = @intCast(i.height);
                e.frame.data[0] = i.pixels;
                e.frame.linesize[0] = @intCast(i.stride);
            },
            else => unreachable,
        }
        {
            // @breakpoint();
            const res = c.avcodec_send_frame(e.ctx, e.frame);
            if (res < 0) {
                std.log.debug("error sending frame: {s}", .{err2str(res)});
                return error.SendFrameFailed;
            }
        }
        // c.av_frame_unref(e.frame);

        // c.av_packet_unref(e.packet);
        {
            const res = c.avcodec_receive_packet(e.ctx, e.packet);
            if (res < 0) {
                const averror_eagain = -@as(c_int, c.EAGAIN);
                if (res == averror_eagain) return null;
                std.log.debug("error receiving packet: {s}", .{err2str(res)});
                return error.ReceivePacketFailed;
            }
        }

        const keyframe = e.packet.flags & c.AV_PKT_FLAG_KEY != 0;
        const extradata = if (keyframe) e.ctx.extradata[0..@intCast(e.ctx.extradata_size)] else &.{};
        return .{ e.packet.data[0..@intCast(e.packet.size)], extradata };
    }
};

pub const Decoder = struct {
    video_stream: *VideoStream,
    ctx: *c.AVCodecContext,
    packet: *c.AVPacket,
    frames: [2]Frame,

    /// `avframe.data[0..3]` are the plane pointers (Y, U, V for YUV formats).
    /// `avframe.linesize[0..3]` are the row strides in bytes.
    /// `avframe.width` / `frame.height` / `frame.format` (AVPixelFormat)
    /// describe the image layout.
    pub const Frame = struct {
        avframe: *c.AVFrame,
        busy: std.atomic.Value(bool) = .init(false),

        pub fn deinit(self: *Frame) void {
            self.busy.store(false, .unordered);
            c.av_frame_unref(self.avframe);
        }

        pub fn getImage(f: *Frame) VideoStream.Image {
            return switch (f.avframe.format) {
                c.AV_PIX_FMT_YUV420P, c.AV_PIX_FMT_YUVJ420P => .{
                    .yuv = .{
                        .height = @intCast(f.avframe.height),
                        .width = @intCast(f.avframe.width),
                        .y = @ptrCast(f.avframe.data[0]),
                        .cb = @ptrCast(f.avframe.data[1]),
                        .cr = @ptrCast(f.avframe.data[2]),
                        .y_stride = @intCast(f.avframe.linesize[0]),
                        .cb_stride = @intCast(f.avframe.linesize[1]),
                        .cr_stride = @intCast(f.avframe.linesize[2]),
                        .color = if (f.avframe.format == c.AV_PIX_FMT_YUV420P) .bt709v else .bt709f,
                    },
                },
                c.AV_PIX_FMT_BGRA => .{
                    .bgra = .{
                        .height = @intCast(f.avframe.height),
                        .width = @intCast(f.avframe.width),
                        .pixels = @ptrCast(f.avframe.data[0]),
                        .stride = @intCast(f.avframe.linesize[0]),
                    },
                },

                else => unreachable,
            };
        }
    };

    pub fn init(vs: *VideoStream, data: []const u8) !Decoder {
        const extradata_size: usize = media.read.int(u16, data.ptr[@sizeOf(u32)..][0..@sizeOf(u16)]);
        const extradata = data[@sizeOf(u32) + @sizeOf(u16) ..][0..extradata_size];

        const codec_id: c_uint = switch (vs.format.codec) {
            .h264 => c.AV_CODEC_ID_H264,
            .hevc => c.AV_CODEC_ID_HEVC,
            .av1 => c.AV_CODEC_ID_AV1,
            .ffv1 => c.AV_CODEC_ID_FFV1,
        };
        const codec = c.avcodec_find_decoder(codec_id) orelse {
            log.debug("unable to find decoder '{t}'", .{vs.format.codec});
            return error.NoSuitableCodec;
        };

        var ctx: *c.AVCodecContext = c.avcodec_alloc_context3(codec) orelse
            return error.OutOfMemory;
        errdefer c.avcodec_free_context(@ptrCast(&ctx));

        // var hw_device_ctx: c.AVBufferRef = undefined;
        // const ret = c.av_hwdevice_ctx_create(&hw_device_ctx, c.HW_DEVICE_TYPE, null, null);
        // if (ret < 0) {
        //     log.debug(
        //         "unable to create hw device for decoding, fallback to software: '{s}'",
        //         .{c.av_err2str(ret)},
        //     );
        // } else {
        //     ctx.hw_device_ctx = c.av_buffer_ref(hw_device_ctx);
        //     ctx.get_format = &get_format;
        //     ctx.extra_hw_frames = 3;
        // }

        ctx.width = @intCast(vs.format.config.width);
        ctx.height = @intCast(vs.format.config.height);
        ctx.framerate = .{ .num = @intCast(vs.format.config.fps), .den = 1 };
        ctx.pix_fmt = c.AV_PIX_FMT_YUV420P;

        ctx.flags = c.AV_CODEC_FLAG_LOW_DELAY;
        ctx.flags2 = c.AV_CODEC_FLAG2_FAST;
        ctx.thread_type = c.FF_THREAD_SLICE;
        ctx.thread_count = 0;

        const wide_extradata = c.av_mallocz(extradata_size + c.AV_INPUT_BUFFER_PADDING_SIZE) orelse
            return error.OutOfMemory;
        ctx.extradata = @ptrCast(wide_extradata);
        ctx.extradata_size = @intCast(extradata_size);
        @memcpy(ctx.extradata, extradata);

        std.log.debug("open start", .{});
        {
            const ret = c.avcodec_open2(ctx, codec, null);
            if (ret < 0) {
                log.debug(
                    "unable to open decoder: '{s}'",
                    .{err2str(ret)},
                );
                return error.NoSuitableCodec;
            }
        }

        var packet: *c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
        errdefer c.av_packet_free(@ptrCast(&packet));

        // Setting .buf = null tells FFmpeg the packet does not own its data,
        // so it won't try to call av_buffer_unref on it.
        packet.buf = null;

        const avframe1: *c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
        const avframe2: *c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;

        return .{
            .video_stream = vs,
            .ctx = ctx,
            .packet = packet,
            .frames = .{ .{ .avframe = avframe1 }, .{ .avframe = avframe2 } },
        };

        // var pixel_format = codec_ctx.codec[0].pix_fmts;
        // log.debug("ffmpeg codec array @{*}", .{pixel_format});
        // while (pixel_format.* != c.AV_PIX_FMT_NONE) : (pixel_format += 1) {
        //     log.debug("ffmpeg codec support @{*}", .{pixel_format});
        //     log.debug("ffmpeg codec support: {s}", .{c.av_get_pix_fmt_name(pixel_format.*)});
        // }

    }

    pub fn deinit(d: *Decoder) void {
        for (&d.frames) |*f| c.av_frame_free(@ptrCast(&f.avframe));
        c.av_packet_free(@ptrCast(&d.packet));
        c.avcodec_free_context(@ptrCast(&d.ctx)); // also frees extradata
    }

    pub fn decodeFrame(d: *Decoder, framed_data: []u8, keyframe: bool) !u32 {
        _ = keyframe;
        const delta: u32 = media.read.int(u32, framed_data[0..@sizeOf(u32)]);
        const extradata_size = media.read.int(u16, framed_data[@sizeOf(u32)..][0..@sizeOf(u16)]);
        const encoded = framed_data[@sizeOf(u32) + @sizeOf(u16) + extradata_size ..];

        d.packet.data = @constCast(encoded.ptr);
        d.packet.size = @intCast(encoded.len);
        // self.packet.buf = null;

        var ret = c.avcodec_send_packet(d.ctx, d.packet);
        if (ret < 0) return error.SendPacketFailed;

        const frame: *Frame = frame: while (true) {
            for (&d.frames) |*f| {
                if (!f.busy.load(.unordered)) {
                    f.busy.store(true, .unordered);
                    break :frame f;
                }
            }

            if (d.video_stream.swapFrontFrame(null)) |f| {
                if (builtin.mode == .Debug) assert(f.busy.load(.unordered));
                break :frame f;
            }

            if (d.video_stream.swapBackFrame(null)) |f| {
                if (builtin.mode == .Debug) assert(f.busy.load(.unordered));
                break :frame f;
            }

            log.warn("both frames were busy and neither could be retreived!", .{});
        };

        ret = c.avcodec_receive_frame(d.ctx, frame.avframe);
        if (ret < 0) {
            const averror_eagain = -@as(c_int, c.EAGAIN);
            if (ret == averror_eagain) return error.NeedMoreData;
            if (ret == c.AVERROR_EOF) return error.EndOfStream;
            return error.ReceiveFrameFailed;
        }

        // std.log.debug("decode format: {s}", .{c.av_get_pix_fmt_name(frame.avframe.format)});

        if (d.video_stream.swapBackFrame(frame)) |dropped| {
            log.debug("freeing dropped frame", .{});
            dropped.deinit();
        }

        return delta;
    }
};

// ffmpeg has a crappy untranslatable macro for this.
inline fn err2str(errnum: c_int) [c.AV_ERROR_MAX_STRING_SIZE:0]u8 {
    var buf: [c.AV_ERROR_MAX_STRING_SIZE:0]u8 = @splat(0);
    _ = c.av_make_error_string(&buf, buf.len, errnum);
    return buf;
}
