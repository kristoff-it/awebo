const builtin = @import("builtin");

const Media = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.media);
const assert = std.debug.assert;

const awebo = @import("../awebo.zig");
const audio = @import("audio.zig");
const network = @import("Core/network.zig");
const Core = @import("Core.zig");
const StringPool = @import("StringPool.zig");
const RingBuffer = @import("RingBuffer.zig");

// Media streaming state
playout: audio.Stream,
capture: audio.Stream,
capture_encoder: *awebo.opus.Encoder,

// These buffers are accessed by both the network thread
// and the audio thread.
playout_buffers: std.AutoArrayHashMapUnmanaged(u16, PlayoutBuffer) = .empty,
capture_buffer: CaptureBuffer,
seq: u32 = 0,

io: Io,

// end of media streaming state

// Called by the core app thread
pub fn init(m: *Media, core: *Core) !void {
    const io = core.io;
    const gpa = core.gpa;

    m.* = .{
        .playout = undefined,
        .capture = undefined,
        .capture_encoder = undefined,
        .capture_buffer = undefined,
        .io = io,
    };

    log.debug("opening playout stream", .{});
    var stream_error: audio.Stream.Error = undefined;
    audio.Stream.open(
        &m.playout,
        .playout,
        &stream_error,
        core.user_audio.playout.device,
        &core.string_pool,
        audioCallbackPlayout,
        &m.playout_buffers,
    ) catch {
        log.err("open playout failed: {f}", .{stream_error});
        return error.AudioPlayout;
    };
    errdefer m.playout.close(&core.string_pool, gpa);

    log.debug("opening capture stream", .{});
    audio.Stream.open(
        &m.capture,
        .capture,
        &stream_error,
        core.user_audio.capture.device,
        &core.string_pool,
        audioCallbackCapture,
        &m.capture_buffer,
    ) catch {
        log.err("open capture failed: {f}", .{stream_error});
        return error.AudioCapture;
    };
    errdefer m.capture.close(&core.string_pool, gpa);

    m.capture_encoder = try awebo.opus.Encoder.create();
    errdefer m.capture_encoder.destroy();

    m.capture_buffer = .{
        .format = m.capture.format,
        .resampler = try awebo.opus.Resampler.create(
            // We convert to opus preferred channel count before resampling
            opus_format.channel_count,
            m.capture.format.sample_rate,
            opus_format.sample_rate,
            8,
        ),
        .samples = try RingBuffer.init(
            gpa,
            m.capture.format.getFrameLen() * m.capture.max_buffer_frame_count * 10,
        ),
    };
    errdefer m.capture_buffer.deinit(gpa);

    log.debug("starting playout stream", .{});
    m.playout.start(&stream_error) catch {
        log.err("start playout failed: {f}", .{stream_error});
        return error.AudioPlayout;
    };
    errdefer m.playout.stop();

    log.debug("starting capture stream", .{});
    m.capture.start(&stream_error) catch {
        log.err("start capture failed: {f}", .{stream_error});
        return error.AudioCapture;
    };
    errdefer m.capture.stop();
}

pub fn stop(m: *Media, string_pool: *StringPool, gpa: Allocator) void {
    m.capture.stop();
    m.capture.close(string_pool, gpa);
    m.playout.stop();
    m.playout.close(string_pool, gpa);
}

pub fn deinit(m: *Media, gpa: Allocator) void {
    m.capture_buffer.deinit(gpa);
    m.capture_encoder.destroy();

    for (m.playout_buffers.values()) |*v| {
        v.deinit(gpa);
    }

    m.playout_buffers.clearRetainingCapacity();
    m.* = undefined;
}

/// Media data has been received and must be processed.
/// Called by the network thread, returns the power of
/// the decoded audio buffer computed as the root mean square.
pub fn receive(m: *Media, gpa: Allocator, message: []const u8) struct { f32, u16 } {
    const io = m.io;
    const data = message[@sizeOf(awebo.protocol.media.Header)..];
    const message_header = std.mem.bytesAsValue(
        awebo.protocol.media.Header,
        message[0..@sizeOf(awebo.protocol.media.Header)],
    );

    // log.debug("read {} bytes!", .{message.len});
    // log.debug("UDP SEQ: {}", .{message_header.sequence});

    const gop = m.playout_buffers.getOrPut(
        gpa,
        message_header.streamId(),
    ) catch unreachable;

    if (!gop.found_existing) {
        log.debug("new stream found: {}", .{message_header.streamId()});
        gop.value_ptr.* = .{
            .out_format = m.playout.format,
            .decoder = awebo.opus.Decoder.create() catch unreachable,
            .resampler = awebo.opus.Resampler.create(
                awebo.opus.CHANNELS,
                awebo.opus.FREQ,
                m.playout.format.sample_rate,
                8,
            ) catch unreachable,
            .samples = RingBuffer.init(
                gpa,
                25 * awebo.opus.SAMPLE_BUF_SIZE * awebo.opus.SAMPLE_SIZE, // 250ms
            ) catch unreachable,
        };
    }

    const playbuf = gop.value_ptr;

    var pcm: [4096 * 10]f32 = undefined;
    const written = playbuf.decoder.decodeFloat(
        data,
        &pcm,
        false,
    ) catch unreachable;

    playbuf.write(io, pcm[0..written]);

    var rms: f32 = 0;
    for (pcm[0..written]) |sample| {
        rms += sample * sample;
    }
    rms /= @floatFromInt(written);
    rms = std.math.sqrt(rms);
    return .{ rms * 100000, @intCast(message_header.id.client_id) };
}

/// Media data is ready to be sent to the server.
/// Called by the network thread.
pub fn send(m: *Media, outbuf: *[1280]u8) ![]const u8 {
    m.seq += 1;

    const header: awebo.protocol.media.Header = .{
        .id = .{
            .client_id = 0,
            .source = .mic,
        },
        .sequence = m.seq,
        .timestamp = 0,
    };

    var w = Io.Writer.fixed(outbuf);

    w.writeAll(std.mem.asBytes(&header)) catch unreachable;

    if (m.capture_buffer.samples.len() < awebo.opus.SAMPLE_BUF_SIZE * awebo.opus.SAMPLE_SIZE) {
        return error.NotReady;
    }

    var buf: [awebo.opus.SAMPLE_BUF_SIZE]f32 = undefined;
    m.capture_buffer.samples.readFirstAssumeLength(
        std.mem.sliceAsBytes(&buf),
        awebo.opus.SAMPLE_BUF_SIZE * awebo.opus.SAMPLE_SIZE,
    );

    const hlen = @sizeOf(awebo.protocol.media.Header);
    const data = outbuf[hlen..];

    const len = m.capture_encoder.encodeFloat(&buf, data) catch |err| {
        log.debug("opus encoder error: {t}", .{err});
        return error.EncodingFailure;
    };

    return outbuf[0 .. hlen + len];
}

// TODO: stream has callback_data but we don't care about it
fn audioCallbackCapture(
    userdata: *anyopaque,
    buffer: *align(audio.buffer_align) anyopaque,
    frame_count: usize,
) void {
    const stream: *audio.Stream = @ptrCast(@alignCast(userdata));
    assert(stream.direction == .capture);
    const m: *Media = @alignCast(@fieldParentPtr("capture", stream));
    const io = m.io;

    const buffer_u8: [*]align(audio.buffer_align) u8 = @ptrCast(buffer);
    const frame_len = stream.format.getFrameLen();

    const byte_len = frame_count * frame_len;
    // log.info("captured {} frames ({} bytes) of audio", .{ frame_count, byte_len });

    m.capture_buffer.write(io, buffer_u8[0..byte_len]);
}

// TODO: stream has callback_data but we don't care about it
fn audioCallbackPlayout(
    userdata: *anyopaque,
    buffer: *align(audio.buffer_align) anyopaque,
    frames_needed: usize,
) void {
    const stream: *audio.Stream = @ptrCast(@alignCast(userdata));
    // var timer = std.time.Timer.start() catch unreachable;
    // defer {
    // const t = timer.read();
    // log.debug("playout callback took {}ns", .{t});
    // }
    assert(stream.direction == .playout);
    const m: *Media = @alignCast(@fieldParentPtr("playout", stream));
    const io = m.io;

    const buffer_u8: [*]align(audio.buffer_align) u8 = @ptrCast(buffer);
    const frame_len = stream.format.getFrameLen();

    const out_pcm = buffer_u8[0 .. frame_len * frames_needed];

    @memset(out_pcm, 0);

    for (m.playout_buffers.values(), m.playout_buffers.keys()) |*playbuf, id| {
        const n = playbuf.read(io, out_pcm);
        _ = n;
        _ = id;
        // log.debug("read {} from stream {}", .{ n, id });
    }
}

const opus_format: audio.Format = .{
    .sample_type = .f32,
    .sample_rate = awebo.opus.FREQ,
    .channel_count = awebo.opus.CHANNELS,
};

const CaptureBuffer = struct {
    format: audio.Format,
    resampler: *awebo.opus.Resampler,
    samples: RingBuffer,

    // used to wake up the thread that writes to the network
    condition: Io.Condition = .init,
    mutex: Io.Mutex = .init,

    pub fn deinit(cb: *CaptureBuffer, allocator: std.mem.Allocator) void {
        cb.samples.deinit(allocator);
        cb.resampler.destroy();
        cb.* = undefined;
    }

    fn write(cb: *CaptureBuffer, io: Io, data: []align(4) const u8) void {
        // NOTE(loris): if the sample type used in opus changes, some things here
        //              might need to change past just swapping the types around
        //              which is why I didn't bother being precise with hardcoded
        //              f32 vs awebo.opus.SAMPLE_TYPE

        cb.mutex.lockUncancelable(io);
        defer {
            cb.condition.signal(io);
            cb.mutex.unlock(io);
        }
        if (opus_format.eql(cb.format)) {
            // log.debug("capture audio format matches opus, performing direct copy", .{});
            const available = cb.samples.data.len - cb.samples.len();
            if (available < data.len * @sizeOf(f32)) {
                // log.warn("capture buffer was full, flushing", .{});
                cb.samples.read_index = cb.samples.write_index;
            }

            cb.samples.writeSliceAssumeCapacity(std.mem.sliceAsBytes(data));
            return;
        }

        // log.debug("converting samples for capture", .{});

        // These buffers are used in case that the corresponding operation
        // has to be performed. When no resampling / conversion is required,
        // we pass around a slice of the original data instead of copying bytes.
        // The conversion buffer can be made smaller without breaking anything.
        // The resample buffer must be big enough to contain the result from
        // resampling, as currently there is no "chunking" implemented once we
        // have resampled the original input.
        var conversion_buffer: [awebo.opus.SAMPLE_BUF_SIZE * 5]f32 = undefined;
        var resample_buffer: [awebo.opus.SAMPLE_BUF_SIZE * 5]f32 = undefined;

        var remaining_data = data;
        while (remaining_data.len > 0) {
            const converted: []const f32 = switch (cb.format.sample_type) {
                .f32 => blk: {
                    assert(opus_format.channel_count == 2);
                    const remaining_f32: []const f32 = std.mem.bytesAsSlice(f32, remaining_data);
                    switch (cb.format.channel_count) {
                        1 => {
                            assert(conversion_buffer.len > remaining_f32.len * 2);
                            for (remaining_f32, 0..) |c, idx| {
                                conversion_buffer[idx * 2] = c;
                                conversion_buffer[(idx * 2) + 1] = c;
                            }
                            remaining_data = &.{};
                            break :blk conversion_buffer[0 .. remaining_f32.len * 2];
                        },
                        2 => {
                            remaining_data = &.{};
                            break :blk remaining_f32;
                        },
                        else => std.debug.panic("TODO: support input devices with > 2 channels", .{}),
                    }
                },
                inline else => |t| blk: {
                    // log.debug("capture: different sample type", .{});

                    const T = t.Native();
                    switch (cb.format.channel_count) {
                        1 => {
                            const sample_count = @divExact(remaining_data.len, @sizeOf(T));
                            assert(conversion_buffer.len >= sample_count * 2);
                            awebo.opus.signedToFloat(
                                T,
                                @sizeOf(T),
                                remaining_data,
                                f32,
                                @sizeOf(f32),
                                std.mem.sliceAsBytes(&conversion_buffer),
                                sample_count,
                            );

                            var idx: usize = sample_count;
                            while (idx > 0) {
                                idx -= 1;
                                conversion_buffer[idx * 2] = conversion_buffer[idx];
                                conversion_buffer[(idx * 2) + 1] = conversion_buffer[idx];
                            }

                            remaining_data = &.{};
                            break :blk conversion_buffer[0 .. sample_count * 2];
                        },
                        2 => {
                            const sample_count = @divExact(remaining_data.len, @sizeOf(T));
                            awebo.opus.signedToFloat(
                                T,
                                @sizeOf(T),
                                remaining_data,
                                f32,
                                @sizeOf(f32),
                                std.mem.sliceAsBytes(&conversion_buffer),
                                sample_count,
                            );

                            remaining_data = &.{};
                            break :blk conversion_buffer[0..sample_count];
                        },
                        else => std.debug.panic("TODO: support input devices with > 2 channels", .{}),
                    }
                },
            };

            const resampled = if (opus_format.sample_rate == cb.format.sample_rate) blk: {
                // log.debug("same sample rate", .{});
                break :blk converted;
            } else blk: { // must resample
                // log.debug("resampling from {}", .{cb.format.sample_rate});
                const processed = cb.resampler.processInterleavedFloat(
                    awebo.opus.CHANNELS,
                    converted,
                    &resample_buffer,
                ) catch |err| {
                    std.debug.panic("resampler error: {t}", .{err});
                };

                assert(processed.input.len == converted.len);
                break :blk processed.output;
            };

            const available = cb.samples.data.len - cb.samples.len();
            if (available < resampled.len * @sizeOf(f32)) {
                // log.warn("capture buffer was full, flushing", .{});
                cb.samples.read_index = cb.samples.write_index;
            }

            cb.samples.writeSliceAssumeCapacity(std.mem.sliceAsBytes(resampled));
        }

        // log.debug("playout sample write done", .{});
    }
};

const PlayoutBuffer = struct {
    out_format: audio.Format,
    started: bool = false,
    samples: RingBuffer,
    decoder: *awebo.opus.Decoder,
    resampler: *awebo.opus.Resampler,
    mutex: Io.Mutex = .init,

    pub fn deinit(pb: *PlayoutBuffer, allocator: std.mem.Allocator) void {
        pb.resampler.destroy();
        pb.samples.deinit(allocator);
        pb.decoder.destroy();
        pb.* = undefined;
    }

    pub fn write(pb: *PlayoutBuffer, io: Io, data: []const f32) void {
        // NOTE(loris): if the sample type used in opus changes, some things here
        //              might need to change past just swapping the types around
        //              which is why I didn't bother being precise with hardcoded
        //              f32 vs awebo.opus.SAMPLE_TYPE

        pb.mutex.lockUncancelable(io);
        defer pb.mutex.unlock(io);

        if (opus_format.eql(pb.out_format)) {
            const available = pb.samples.data.len - pb.samples.len();
            if (available < data.len * @sizeOf(f32)) {
                log.warn("playout buffer was full, flushing", .{});
                pb.samples.read_index = pb.samples.write_index;
            }

            pb.samples.writeSliceAssumeCapacity(std.mem.sliceAsBytes(data));
            return;
        }

        // log.debug("converting samples for playout", .{});

        // These buffers are used in case that the corresponding operation
        // has to be performed. When no resampling / conversion is required,
        // we pass around a slice of the original data instead of copying bytes.
        // The resample buffer can be made smaller without breaking anything.
        // The conversion buffer must be big enough to contain the result from
        // resampling, as currently there is no "chunking" implemented once we
        // have resampled the original input.
        var resample_buffer: [awebo.opus.SAMPLE_BUF_SIZE]f32 align(4) = undefined;
        var conversion_buffer: [awebo.opus.SAMPLE_BUF_SIZE * awebo.opus.SAMPLE_SIZE]u8 align(4) = undefined;

        var remaining_data = data;
        while (remaining_data.len > 0) {
            const resampled = if (opus_format.sample_rate == pb.out_format.sample_rate) blk: {
                // log.debug("same sample rate", .{});
                const resampled = remaining_data;
                remaining_data = &.{};
                break :blk resampled;
            } else blk: { // must resample
                // log.debug("resampling to {}", .{pb.out_format.sample_rate});
                const processed = pb.resampler.processInterleavedFloat(
                    awebo.opus.CHANNELS,
                    remaining_data,
                    &resample_buffer,
                ) catch |err| {
                    std.debug.panic("resampler error: {}", .{err});
                };

                assert(processed.input.len > 0);
                remaining_data = remaining_data[0..processed.input.len];
                break :blk processed.output;
            };

            const converted: []align(4) const u8 = switch (pb.out_format.sample_type) {
                .f32 => std.mem.sliceAsBytes(resampled),
                inline else => |t| blk: {
                    // log.debug("different sample type", .{});
                    const T = t.Native();
                    awebo.opus.floatToSigned(
                        f32,
                        @sizeOf(f32),
                        std.mem.sliceAsBytes(resampled),
                        T,
                        @sizeOf(T),
                        &conversion_buffer,
                        resampled.len,
                    );
                    break :blk conversion_buffer[0 .. resampled.len * @sizeOf(T)];
                },
            };

            assert(awebo.opus.CHANNELS == 2);
            const available = pb.samples.data.len - pb.samples.len();
            switch (pb.out_format.channel_count) {
                1 => {
                    // log.debug("mono, must be converted", .{});
                    const needed = @divExact(converted.len, 2);
                    assert(pb.samples.data.len >= needed);
                    if (available < needed) {
                        log.warn("playout buffer was full, flushing", .{});
                        pb.samples.read_index = pb.samples.write_index;
                    }

                    switch (pb.out_format.sample_type) {
                        inline else => |t| {
                            const T = t.Native();
                            const converted_t = std.mem.bytesAsSlice(T, converted);
                            var idx: usize = 0;
                            while (idx < converted_t.len) : (idx += 2) {
                                const left = converted_t[idx];
                                const right = converted_t[idx + 1];
                                const mix = switch (T) {
                                    f32 => (left + right) / 2,
                                    else => @divTrunc(left + right, 2),
                                };

                                // log.debug("writing l {} r {} mix {} ", .{ left, right, mix });

                                pb.samples.writeSliceAssumeCapacity(std.mem.asBytes(&mix));
                            }
                        },
                    }
                },
                2 => {
                    if (available < converted.len) {
                        log.warn("playout buffer was full, flushing", .{});
                        pb.samples.read_index = pb.samples.write_index;
                    }

                    pb.samples.writeSliceAssumeCapacity(converted);
                },
                else => std.debug.panic("TODO: support more than 2 channel output devices", .{}),
            }
        }

        // log.debug("playout sample write done", .{});
    }

    // Reads samples from the ringbuffer into the target buffer.
    // Adds the values into `out_pcm`, allowing you to mix
    // multiple audio streams into the same buffer.
    pub fn read(
        pb: *PlayoutBuffer,
        io: Io,
        out_pcm: []u8,
    ) usize {
        pb.mutex.lockUncancelable(io);
        defer pb.mutex.unlock(io);

        if (!pb.started and pb.samples.len() < out_pcm.len) {
            return 0;
        }

        pb.started = true;
        const read_len = @min(out_pcm.len, pb.samples.len());

        // NOTE: We can't just memcpy here because we want to *ADD* samples
        //       together. We should probably look into @Vector stuff.
        switch (pb.out_format.sample_type) {
            inline else => |t| {
                const T = t.Native();
                const out_pcm_t = std.mem.bytesAsSlice(T, out_pcm);

                for (0..read_len / @sizeOf(T)) |i| {
                    var sample: T = undefined;
                    pb.samples.readFirstAssumeLength(std.mem.asBytes(&sample), @sizeOf(T));
                    out_pcm_t[i] += sample;
                }
            },
        }

        return read_len;
    }
};
