// const c = @cImport({
//     @cInclude("opus.h");
//     @cDefine("OUTSIDE_SPEEX", "1");
//     @cDefine("RANDOM_PREFIX", "speex");
//     @cInclude("speex_resampler.h");
// });
const opus_h = @import("opus.h.zig");
const speex_h = @import("speex_resampler.h.zig");

const std = @import("std");
const assert = std.debug.assert;

pub const SAMPLE_SIZE = @sizeOf(f32);
pub const CHANNELS = 1;
pub const FREQ = 48000;
pub const FRAME_COUNT = 960; // 20ms
pub const PACKET_SIZE = FRAME_COUNT * CHANNELS;

pub const Encoder = opaque {
    pub fn create() !*Encoder {
        var err: c_int = undefined;
        const h = opus_h.opus_encoder_create(FREQ, CHANNELS, opus_h.OPUS_APPLICATION_AUDIO, &err);
        try checkErr(err);
        return @ptrCast(h.?);
    }

    pub fn destroy(e: *Encoder) void {
        opus_h.opus_encoder_destroy(@ptrCast(e));
    }

    /// Returns the number of bytes written to `out`.
    pub fn encodeFloat(e: *Encoder, pcm: *const [PACKET_SIZE]f32, out: []u8) !usize {
        const res = opus_h.opus_encode_float(
            @ptrCast(e),
            pcm,
            FRAME_COUNT,
            out.ptr,
            @intCast(out.len),
        );
        return @intCast(res);
    }
};

pub const Decoder = opaque {
    pub fn create() !*Decoder {
        var err: c_int = undefined;
        const h = opus_h.opus_decoder_create(FREQ, CHANNELS, &err);
        try checkErr(err);
        return @ptrCast(h.?);
    }

    pub fn destroy(d: *Decoder) void {
        opus_h.opus_decoder_destroy(@ptrCast(d));
    }

    /// Returns the number of SAMPLES written to `out`.
    pub fn decodeFloat(d: *Decoder, in: []const u8, pcm: []f32, fec: bool) !usize {
        assert(@divExact(pcm.len, CHANNELS) == FRAME_COUNT);
        const res = opus_h.opus_decode_float(
            @ptrCast(d),
            in.ptr,
            @intCast(in.len),
            pcm.ptr,
            FRAME_COUNT,
            if (fec) 1 else 0,
        );

        if (res < 0) {
            try checkErr(res);
        }

        return @intCast(res * CHANNELS);
    }

    /// pcm.len defines how much silence to produce
    pub fn decodeMissing(d: *Decoder, pcm: []f32, fec: bool) !usize {
        const res = opus_h.opus_decode_float(
            @ptrCast(d),
            null,
            0,
            pcm.ptr,
            @intCast(@divExact(pcm.len, CHANNELS)),
            if (fec) 1 else 0,
        );
        return @intCast(res);
    }
};

fn checkErr(err: c_int) !void {
    const e: OpusErrorEnum = @enumFromInt(err);
    return switch (e) {
        .OPUS_OK => {},
        .OPUS_BAD_ARG => error.OpusBadArg,
        .OPUS_BUFFER_TOO_SMALL => error.OpusBufferTooSmall,
        .OPUS_INTERNAL_ERROR => error.OpusInternalError,
        .OPUS_INVALID_PACKET => error.OpusInvalidPacket,
        .OPUS_UNIMPLEMENTED => error.OpusUnimplemented,
        .OPUS_INVALID_STATE => error.OpusInvalidState,
        .OPUS_ALLOC_FAIL => error.OutOfMemory,
    };
}

const OpusErrorEnum = enum(c_int) {
    OPUS_OK = 0,
    // /** One or more invalid/out of range arguments @hideinitializer*/
    OPUS_BAD_ARG = -1,
    // /** Not enough bytes allocated in the buffer @hideinitializer*/
    OPUS_BUFFER_TOO_SMALL = -2,
    // /** An internal error was detected @hideinitializer*/
    OPUS_INTERNAL_ERROR = -3,
    // /** The compressed data passed is corrupted @hideinitializer*/
    OPUS_INVALID_PACKET = -4,
    // /** Invalid/unsupported request number @hideinitializer*/
    OPUS_UNIMPLEMENTED = -5,
    // /** An encoder or decoder structure is invalid or already freed @hideinitializer*/
    OPUS_INVALID_STATE = -6,
    // /** Memory allocation has failed @hideinitializer*/
    OPUS_ALLOC_FAIL = -7,
};

pub const Resampler = opaque {
    // How much of the input buffer has been processed,
    // how much of the output buffer has been written.
    pub fn Processed(T: type) type {
        return struct {
            input: []const T,
            output: []T,
        };
    }

    pub fn create(
        channels: u32,
        input_rate: u32,
        output_rate: u32,
        quality: i32,
    ) !*Resampler {
        // /** Create a new resampler with integer input and output rates.
        //  * @param nb_channels Number of channels to be processed
        //  * @param in_rate Input sampling rate (integer number of Hz).
        //  * @param out_rate Output sampling rate (integer number of Hz).
        //  * @param quality Resampling quality between 0 and 10, where 0 has poor quality
        //  * and 10 has very high quality.
        //  * @return Newly created resampler state
        //  * @retval NULL Error: not enough memory
        //  */
        var err: i32 = undefined;
        const res = speex_h.speex_resampler_init(
            channels,
            input_rate,
            output_rate,
            quality,
            &err,
        );

        try checkResamplerErr(err);
        return @ptrCast(res.?);
    }

    pub fn processInterleavedFloat(
        r: *Resampler,
        channels: u32,
        input_pcm: []const f32,
        output_pcm: []f32,
    ) !Processed(f32) {
        // /** Resample an interleaved float array. The input and output buffers must *not* overlap.
        //  * @param st Resampler state
        //  * @param in Input buffer
        //  * @param in_len Number of input samples in the input buffer. Returns the number
        //  * of samples processed. This is all per-channel.
        //  * @param out Output buffer
        //  * @param out_len Size of the output buffer. Returns the number of samples written.
        //  * This is all per-channel.
        //  */
        var input_len: u32 = @intCast(@divExact(input_pcm.len, channels));
        var output_len: u32 = @intCast(@divExact(output_pcm.len, channels));
        const err = speex_h.speex_resampler_process_interleaved_float(
            @ptrCast(r),
            input_pcm.ptr,
            &input_len,
            output_pcm.ptr,
            &output_len,
        );

        try checkResamplerErr(err);

        return .{
            .input = input_pcm[0 .. input_len * channels],
            .output = output_pcm[0 .. output_len * channels],
        };
    }
    pub fn destroy(r: *Resampler) void {
        speex_h.speex_resampler_destroy(@ptrCast(r));
    }

    fn checkResamplerErr(code: i32) !void {
        const ResamplerErrorEnum = enum(i32) {
            RESAMPLER_ERR_SUCCESS = 0,
            RESAMPLER_ERR_ALLOC_FAILED = 1,
            RESAMPLER_ERR_BAD_STATE = 2,
            RESAMPLER_ERR_INVALID_ARG = 3,
            RESAMPLER_ERR_PTR_OVERLAP = 4,
            RESAMPLER_ERR_OVERFLOW = 5,
        };

        const resampler_err: ResamplerErrorEnum = @enumFromInt(code);
        return switch (resampler_err) {
            .RESAMPLER_ERR_SUCCESS => {},
            .RESAMPLER_ERR_ALLOC_FAILED => error.OutOfMemory,
            .RESAMPLER_ERR_BAD_STATE => error.BadState,
            .RESAMPLER_ERR_INVALID_ARG => error.InvalidArg,
            .RESAMPLER_ERR_PTR_OVERLAP => error.PtrOverlap,
            .RESAMPLER_ERR_OVERFLOW => error.Overflow,
        };
    }
};

// From https://github.com/hexops/mach/blob/main/src/sysaudio/conv.zig
pub fn floatToUnsigned(
    comptime SrcType: type,
    src_stride: u8,
    src: []const u8,
    comptime DstType: type,
    dst_stride: u8,
    dst: []u8,
    len: usize,
) void {
    const half = std.math.maxInt(DstType) / 2;
    const half_plus_one = half + 1;
    var i: usize = 0;

    // Use SIMD when available
    if (std.simd.suggestVectorLength(SrcType)) |vec_size| {
        const VecSrc = @Vector(vec_size, SrcType);
        const VecDst = @Vector(vec_size, DstType);
        const half_vec: VecSrc = @splat(half);
        const half_plus_one_vec: VecSrc = @splat(half_plus_one);
        const vec_blocks_len = len - (len % vec_size);
        while (i < vec_blocks_len) : (i += vec_size) {
            const src_vec = std.mem.bytesAsValue(
                VecSrc,
                src[i * src_stride ..][0 .. vec_size * src_stride],
            ).*;
            const dst_sample: VecDst = @intFromFloat(src_vec * half_vec + half_plus_one_vec);
            @memcpy(
                dst[i * dst_stride ..][0 .. vec_size * dst_stride],
                std.mem.asBytes(&dst_sample)[0 .. vec_size * dst_stride],
            );
        }
    }

    // Convert the remaining samples
    while (i < len) : (i += 1) {
        const src_sample: *const SrcType = @ptrCast(
            @alignCast(src[i * src_stride ..][0..src_stride]),
        );
        const dst_sample: DstType = @intFromFloat(src_sample.* * half + half_plus_one);
        @memcpy(
            dst[i * dst_stride ..][0..dst_stride],
            std.mem.asBytes(&dst_sample)[0..dst_stride],
        );
    }
}
pub fn floatToSigned(
    comptime SrcType: type,
    src_stride: u8,
    src: []const u8,
    comptime DstType: type,
    dst_stride: u8,
    dst: []u8,
    len: usize,
) void {
    const max = std.math.maxInt(DstType) + 1;
    var i: usize = 0;

    // Use SIMD when available
    if (std.simd.suggestVectorLength(SrcType)) |vec_size| {
        const VecSrc = @Vector(vec_size, SrcType);
        const VecDst = @Vector(vec_size, DstType);
        const max_vec: VecSrc = @splat(max);
        const vec_blocks_len = len - (len % vec_size);
        while (i < vec_blocks_len) : (i += vec_size) {
            const src_vec = std.mem.bytesAsValue(
                VecSrc,
                src[i * src_stride ..][0 .. vec_size * src_stride],
            ).*;
            const dst_sample: VecDst = @intFromFloat(src_vec * max_vec);
            @memcpy(
                dst[i * dst_stride ..][0 .. vec_size * dst_stride],
                std.mem.asBytes(&dst_sample)[0 .. vec_size * dst_stride],
            );
        }
    }

    // Convert the remaining samples
    while (i < len) : (i += 1) {
        const src_sample: *const SrcType = @ptrCast(@alignCast(
            src[i * src_stride ..][0..src_stride],
        ));
        const dst_sample: DstType = @truncate(@as(i32, @intFromFloat(src_sample.* * max)));
        @memcpy(
            dst[i * dst_stride ..][0..dst_stride],
            std.mem.asBytes(&dst_sample)[0..dst_stride],
        );
    }
}

pub fn signedToFloat(
    comptime SrcType: type,
    src_stride: u8,
    src: []const u8,
    comptime DstType: type,
    dst_stride: u8,
    dst: []u8,
    len: usize,
) void {
    const div_by_max = 1.0 / @as(comptime_float, std.math.maxInt(SrcType) + 1);
    var i: usize = 0;

    // Use SIMD when available
    if (std.simd.suggestVectorLength(SrcType)) |vec_size| {
        const VecSrc = @Vector(vec_size, SrcType);
        const VecDst = @Vector(vec_size, DstType);
        const vec_blocks_len = len - (len % vec_size);
        const div_by_max_vec: VecDst = @splat(div_by_max);
        while (i < vec_blocks_len) : (i += vec_size) {
            const src_vec = std.mem.bytesAsValue(
                VecSrc,
                src[i * src_stride ..][0 .. vec_size * src_stride],
            ).*;
            const dst_sample: VecDst = @as(VecDst, @floatFromInt(src_vec)) * div_by_max_vec;
            @memcpy(
                dst[i * dst_stride ..][0 .. vec_size * dst_stride],
                std.mem.asBytes(&dst_sample)[0 .. vec_size * dst_stride],
            );
        }
    }

    // Convert the remaining samples
    while (i < len) : (i += 1) {
        const src_sample: *const SrcType = @ptrCast(@alignCast(
            src[i * src_stride ..][0..src_stride],
        ));
        const dst_sample: DstType = @as(DstType, @floatFromInt(src_sample.*)) * div_by_max;
        @memcpy(
            dst[i * dst_stride ..][0..dst_stride],
            std.mem.asBytes(&dst_sample)[0..dst_stride],
        );
    }
}
