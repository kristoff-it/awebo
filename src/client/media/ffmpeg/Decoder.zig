const Decoder = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.@"ffmpeg-decoder");
const VideoStream = @import("../VideoStream.zig");

const c = @cImport({
    @cInclude("libavcodec/avcodec.h");
    @cInclude("libavutil/frame.h");
    @cInclude("libavutil/mem.h");
    @cInclude("libavutil/error.h");
    @cInclude("libavutil/pixdesc.h");
    @cInclude("errno.h");
});

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
        return .{
            .yuv = .{
                .height = @intCast(f.avframe.height),
                .width = @intCast(f.avframe.width),
                .planes = @ptrCast(&f.avframe.data),
                .color = .bt709f,
            },
        };
    }
};

video_stream: *VideoStream,
codec_ctx: *c.AVCodecContext,
packet: *c.AVPacket,
frames: [2]Frame,

pub fn init(vs: *VideoStream, gpa: Allocator, format: VideoStream.Format, first_frame_data: []u8) !Decoder {
    _ = gpa;
    log.debug("first_frame_data = {}", .{first_frame_data.len});

    const codec = c.avcodec_find_decoder(c.AV_CODEC_ID_HEVC) orelse
        return error.CodecNotFound;

    const codec_ctx: *c.AVCodecContext = c.avcodec_alloc_context3(codec) orelse
        return error.OutOfMemory;

    errdefer {
        var p = codec_ctx;
        c.avcodec_free_context(@ptrCast(&p));
    }

    codec_ctx.width = format.width;
    codec_ctx.height = format.height;
    codec_ctx.framerate = .{ .num = 30, .den = 1 };
    codec_ctx.pix_fmt = c.AV_PIX_FMT_YUV420P;

    codec_ctx.flags |= c.AV_CODEC_FLAG_LOW_DELAY;
    codec_ctx.flags2 |= c.AV_CODEC_FLAG2_FAST;
    codec_ctx.thread_type = c.FF_THREAD_SLICE;
    codec_ctx.thread_count = 0;

    const header = parseHevcPacket(first_frame_data, true) catch @panic("bad");
    codec_ctx.extradata = header.extradata.ptr;
    codec_ctx.extradata_size = @intCast(header.extradata.len);

    if (c.avcodec_open2(codec_ctx, codec, null) < 0)
        return error.CodecOpenFailed;

    // var pixel_format = codec_ctx.codec[0].pix_fmts;
    // log.debug("ffmpeg codec array @{*}", .{pixel_format});
    // while (pixel_format.* != c.AV_PIX_FMT_NONE) : (pixel_format += 1) {
    //     log.debug("ffmpeg codec support @{*}", .{pixel_format});
    //     log.debug("ffmpeg codec support: {s}", .{c.av_get_pix_fmt_name(pixel_format.*)});
    // }

    const packet: *c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
    errdefer {
        var p = packet;
        c.av_packet_free(@ptrCast(&p));
    }

    // Setting .buf = null tells FFmpeg the packet does not own its data,
    // so it won't try to call av_buffer_unref on it.
    packet.buf = null;

    const avframe1: *c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
    const avframe2: *c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;

    return .{
        .video_stream = vs,
        .codec_ctx = codec_ctx,
        .packet = packet,
        .frames = .{ .{ .avframe = avframe1 }, .{ .avframe = avframe2 } },
    };
}

pub fn decodeFrame(self: *Decoder, encoded_with_header: []u8, keyframe: bool) !u32 {
    const encoded_raw = if (!keyframe) encoded_with_header else blk: {
        const header = parseHevcPacket(encoded_with_header, false) catch @panic("bad");
        break :blk header.encoded_frame;
    };

    const delta: u32 = @bitCast(encoded_raw[0..@sizeOf(u32)].*);
    const encoded = encoded_raw[@sizeOf(u32)..];
    convertAvccToAnnexB(encoded) catch @panic("bad frame");

    self.packet.data = @constCast(encoded.ptr);
    self.packet.size = @intCast(encoded.len);
    // self.packet.buf = null;

    var ret = c.avcodec_send_packet(self.codec_ctx, self.packet);
    if (ret < 0) return error.SendPacketFailed;

    const frame: *Frame = frame: while (true) {
        for (&self.frames) |*f| {
            if (!f.busy.load(.unordered)) {
                f.busy.store(true, .unordered);
                break :frame f;
            }
        }

        if (self.video_stream.swapFrontFrame(null)) |f| {
            if (builtin.mode == .Debug) assert(f.busy.load(.unordered));
            break :frame f;
        }

        if (self.video_stream.swapBackFrame(null)) |f| {
            if (builtin.mode == .Debug) assert(f.busy.load(.unordered));
            break :frame f;
        }

        log.warn("both frames were busy and neither could be retreived!", .{});
    };

    ret = c.avcodec_receive_frame(self.codec_ctx, frame.avframe);
    if (ret < 0) {
        const averror_eagain = -@as(c_int, c.EAGAIN);
        if (ret == averror_eagain) return error.NeedMoreData;
        if (ret == c.AVERROR_EOF) return error.EndOfStream;
        return error.ReceiveFrameFailed;
    }

    if (self.video_stream.swapBackFrame(frame)) |dropped| {
        log.debug("freeing dropped frame", .{});
        dropped.deinit();
    }

    return delta;
}

pub fn deinit(self: *Decoder) void {
    for (&self.frames) |f| {
        var frame = f;
        c.av_frame_free(@ptrCast(&frame.avframe));
    }

    var pkt = self.packet;
    c.av_packet_free(@ptrCast(&pkt));

    var codec_ctx = self.codec_ctx;
    c.avcodec_free_context(@ptrCast(&codec_ctx)); // also frees extradata
}

const HevcParamHeader = packed struct {
    codec_id: u8,
    vps_length: u16,
    sps_length: u16,
    pps_length: u16,
};

const start_code = [4]u8{ 0x00, 0x00, 0x00, 0x01 };

pub const ParsedHevcPacket = struct {
    /// Annex B extradata (VPS + SPS + PPS, each prefixed with start code).
    /// Should only be allocated by setting `parse_extradata` to true when
    /// initializing the decoder, which then takes ownership of this memory.
    extradata: []u8,
    /// The raw frame payload as received — still in AVCC length-prefix format.
    encoded_frame: []u8,
};

/// Parse a packet produced by `_serializeHEVC:delta:data:len:`.
pub fn parseHevcPacket(packet: []u8, parse_extradata: bool) !ParsedHevcPacket {
    if (packet.len < @sizeOf(HevcParamHeader))
        return error.PacketTooShort;

    const header: *align(1) const HevcParamHeader = @ptrCast(packet.ptr);
    const vps_len: usize = header.vps_length;
    const sps_len: usize = header.sps_length;
    const pps_len: usize = header.pps_length;

    log.debug("decoder header: {}", .{header.*});

    const header_end = @bitSizeOf(HevcParamHeader) / 8;
    const param_end = header_end + vps_len + sps_len + pps_len;
    if (packet.len < param_end)
        return error.PacketTooShort;

    const encoded_frame = packet[param_end..];

    if (!parse_extradata) {
        return .{
            .encoded_frame = encoded_frame,
            .extradata = &.{},
        };
    }

    const vps = packet[header_end..][0..vps_len];
    const sps = packet[header_end + vps_len ..][0..sps_len];
    const pps = packet[header_end + vps_len + sps_len ..][0..pps_len];

    // FFmpeg expects: [start_code | VPS] [start_code | SPS] [start_code | PPS]
    // plus AV_INPUT_BUFFER_PADDING_SIZE (64) bytes of zero padding at the end
    // so SIMD bitstream readers can safely over-read.
    const av_padding = c.AV_INPUT_BUFFER_PADDING_SIZE;
    const extradata_len = (start_code.len + vps_len) +
        (start_code.len + sps_len) +
        (start_code.len + pps_len);

    const buf_raw: [*]u8 = @ptrCast(c.av_mallocz(extradata_len + av_padding) orelse return error.OutOfMemory);
    const buf = buf_raw[0 .. extradata_len + av_padding];
    var pos: usize = 0;
    for (&[_][]const u8{ vps, sps, pps }) |nal| {
        @memcpy(buf[pos..][0..4], &start_code);
        pos += 4;
        @memcpy(buf[pos..][0..nal.len], nal);
        pos += nal.len;
    }
    @memset(buf[extradata_len..], 0);

    return .{
        .extradata = buf[0..extradata_len], // excludes the padding intentionally
        .encoded_frame = encoded_frame,
    };
}

/// Convert a VideoToolbox AVCC frame (4-byte big-endian length-prefixed NALs)
/// to Annex B (start-code-prefixed NALs) in-place.
///
/// VideoToolbox produces frames where each NAL unit is preceded by a 4-byte
/// big-endian length rather than a start code.  FFmpeg's HEVC parser expects
/// Annex B.  Because both encodings use exactly 4 bytes as a prefix, we can
/// do this in-place: just overwrite the length with 0x00 0x00 0x00 0x01.
pub fn convertAvccToAnnexB(frame: []u8) !void {
    var pos: usize = 0;
    var idx: usize = 0;
    log.debug("frame len = {}", .{frame.len});
    while (pos + 4 <= frame.len) : (idx += 1) {
        const nal_len = std.mem.readInt(u32, frame[pos..][0..4], .big);
        log.debug("nal #{} len = {}", .{ idx, nal_len });
        @memcpy(frame[pos..][0..4], &start_code);
        pos += 4;
        if (pos + nal_len > frame.len) return error.MalformedAvccFrame;
        pos += nal_len;
    }
}
