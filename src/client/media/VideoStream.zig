const VideoStream = @This();

const builtin = @import("builtin");
const options = @import("options");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const awebo = @import("../../awebo.zig");
const media = awebo.protocol.media;
const Core = @import("../Core.zig");
const log = std.log.scoped(.@"video-stream");
const FfmpegDecoder = @import("ffmpeg/Decoder.zig");

/// Space for buffered packets. Must be a power of 2.
const buffer_len: usize = 32;
/// Number of packets that must be present in the buffer
/// before we start playing. Must be lower than `buffer_len`
const start_count = 16; // 16 frames @ 33ms = 528ms jitter
comptime {
    assert(std.math.isPowerOfTwo(buffer_len));
    assert(start_count < buffer_len);
}

pub const Image = union(enum) {
    bgra: Bgra,
    yuv: Yuv,

    // This definition must be kept in sync with OS code.
    // - macos/video.h
    pub const Bgra = extern struct {
        width: usize,
        height: usize,
        pixels: ?[*]u8,
    };

    pub const Yuv = extern struct {
        width: usize,
        height: usize,
        planes: *const [3][*]const u8,
        color: enum(u32) {
            bt601v,
            bt601f,
            bt709v,
            bt709f,
            bt2020v,
            bt2020f,
        },
    };
};

pub const UiData = struct {
    data: ?*anyopaque,
    context: ?*anyopaque,
    deinit: *const fn (gpa: Allocator, context: ?*anyopaque, data: ?*anyopaque) void,
};

pub const Format = struct {
    codec: Codec,
    width: u16,
    height: u16,
    fps: f32,

    pub const Codec = enum(u32) {
        h264 = 0,
        h265 = 1,
        av1 = 2,
    };
};

core: *Core,
packets: JitterBuffer = .empty,
video_thread: Io.Future(anyerror!void),

frame_back: std.atomic.Value(?*Decoder.Frame) = .init(null),
frame_front: std.atomic.Value(?*Decoder.Frame) = .init(null),

/// Convenience field that the UI can use to tie
/// related artifacts to a video stream, e.g. the
/// texture used to render the current frame.
ui_data: ?UiData = null,
decoder: Decoder,

const Decoder = if (options.dummy) Dummy else if (options.ffmpeg) FfmpegDecoder else switch (builtin.target.os.tag) {
    .macos => MacOsNative,
    else => Dummy,
};

pub fn create(core: *Core, seq: u32, body: []u8) !?*VideoStream {
    const video_header, const video_data = media.Video.parse(body) orelse {
        log.debug("discarding malformed packet", .{});
        return null;
    };

    if (video_header.chunk_id != 0 or !video_header.keyframe) return null;

    const vs = try core.gpa.create(VideoStream);
    errdefer core.gpa.destroy(vs);

    vs.* = .{
        .core = core,
        .video_thread = undefined,
        .decoder = try .init(vs, core.gpa, .{
            .codec = .h265,
            .width = 1920,
            .height = 1080,
            .fps = 30,
        }, video_data),
    };

    errdefer vs.decoder.deinit();

    vs.video_thread = try core.io.concurrent(videoThread, .{vs});
    errdefer vs.video_thread.cancel(core.io) catch {};

    vs.packets.packets.warmup(core.gpa) catch unreachable;

    vs.pushChunk(seq, body);
    return vs;
}
pub fn destroy(vs: *VideoStream, gpa: Allocator) void {
    vs.decoder.deinit();
    vs.video_thread.cancel(vs.core.io) catch {};
    vs.packets.deinit(gpa);
    if (vs.swapBackFrame(null)) |frame| frame.deinit();
    if (vs.swapFrontFrame(null)) |frame| frame.deinit();
    if (vs.ui_data) |ui| ui.deinit(gpa, ui.context, ui.data);
    gpa.destroy(vs);
}

pub fn pushChunk(vs: *VideoStream, seq: u32, body: []u8) void {
    // const video_header: *align(1) awebo.protocol.media.Video = @ptrCast(body.ptr);
    vs.packets.writeChunk(vs.core.gpa, seq, body);
}

/// Function with C callconv that the OS can invoke whenever
/// a new video frame is ready.
pub fn swapBackFrame(vs: *VideoStream, new: ?*Decoder.Frame) callconv(.c) ?*Decoder.Frame {
    return vs.frame_back.swap(new, .acq_rel);
}

/// Called by the UI thread to update a texture with this frame.
pub fn swapFrontFrame(vs: *VideoStream, new: ?*Decoder.Frame) ?*Decoder.Frame {
    return vs.frame_front.swap(new, .acq_rel);
}

/// Runs as a high priority thread, pulls at regular intervals
/// from the JitterBuffer, decodes and schedules decoded frames
/// to the UI.
fn videoThread(vs: *VideoStream) anyerror!void {
    awebo.network_utils.setCurrentThreadRealtime(33);

    const io = vs.core.io;
    var start: Io.Timestamp = Io.Clock.awake.now(io);
    var first_frame = true;

    var last = start;
    var target = start;
    while (true) {
        const now = Io.Clock.awake.now(io);
        // log.warn("running video thread @ {} (delta {}ms) (target delta {}ms)", .{
        //     now.toMilliseconds(),
        //     last.durationTo(now).toMilliseconds(),
        //     target.durationTo(now).toMilliseconds(),
        // });

        last = now;
        switch (vs.packets.nextPacketBegin()) {
            .starting => {
                try io.sleep(.fromMilliseconds(33), .awake);
            },
            .missing => {
                first_frame = true;
                const front = vs.swapFrontFrame(vs.swapBackFrame(null));
                if (front) |f| {
                    log.warn("UI did not consume front frame!", .{});
                    f.deinit();
                }
                vs.core.refresh(vs.core, @src(), null);

                try io.sleep(.fromMilliseconds(33), .awake);
            },
            .decode => |d| {
                if (first_frame) {
                    start = Io.Clock.awake.now(io);
                }

                const front = vs.swapFrontFrame(vs.swapBackFrame(null));

                if (front) |f| {
                    log.warn("UI did not consume front frame!", .{});
                    f.deinit();
                }
                vs.core.refresh(vs.core, @src(), null);

                const delta = vs.decoder.decodeFrame(d.data.slice(), d.data.keyframe) catch |err| blk: {
                    log.debug("error while decoding frame: {t}", .{err});
                    break :blk 33;
                };

                d.meta.seq = 0;
                vs.packets.nextPacketCommit(d);

                if (first_frame) {
                    first_frame = false;
                    const timeout: Io.Timeout = .{
                        .deadline = start.addDuration(.fromMilliseconds(33)).withClock(.awake),
                    };
                    try timeout.sleep(io);
                } else {
                    const timeout: Io.Timeout = .{
                        .deadline = start.addDuration(.fromMilliseconds(delta)).withClock(.awake),
                    };
                    target = timeout.deadline.raw;
                    try timeout.sleep(io);
                    if (d.data.keyframe) {
                        start = start.addDuration(.fromMilliseconds(delta));
                    }
                }
            },
        }
    }
    comptime unreachable;
}

const JitterBuffer = struct {
    /// Writer side
    stats: struct {
        start_time: Io.Timestamp = undefined,
        seq: u32 = 0,
    } = .{},

    /// Reader side
    state: enum {
        /// Waiting for the buffer to fill up for the first time
        /// or after a silence reset.
        starting,
        /// Playing audio normally
        playing,
        /// After we started playing, we emptied our buffer and
        /// are now waiting for the buffer to fill up again
        buffering,
    } = .starting,
    expected_next_seq: u32 = 0,

    /// Shared
    packets: PacketRing,

    pub const empty: JitterBuffer = .{ .packets = .init };

    pub fn deinit(jb: *JitterBuffer, gpa: Allocator) void {
        jb.packets.deinit(gpa);
    }

    /// This function is meant to be called by the network thread.
    pub fn writeChunk(jb: *JitterBuffer, gpa: Allocator, seq: u32, body: []u8) void {
        if (jb.expected_next_seq == 0) {
            jb.expected_next_seq = seq;
        }

        jb.packets.write(gpa, seq, body) catch {
            log.warn("dropping video packet, video thread is too slow!", .{});
        };
    }

    const NextPacket = union(enum) {
        /// When starting we should play a loading animation.
        starting,

        /// Contains a video frame to decode.
        decode: Decode,

        /// We are missing a frame
        missing,

        const Decode = struct {
            r: usize,
            data: *PacketRing.Data,
            meta: *PacketRing.Meta,
            buffered: PacketRing.RingIndex,
        };
    };

    /// This function is meant to be called by the video thread.
    pub fn nextPacketBegin(jb: *JitterBuffer) NextPacket {
        const packet_slices = jb.packets.slices();
        switch (packet_slices.len()) {
            0 => if (jb.state == .playing) {
                jb.state = .buffering;
            },
            1...start_count - 1 => {},
            else => if (jb.state != .playing) {
                var discarded: usize = 0;
                for (packet_slices.array()) |slice| for (slice) |idx| {
                    const meta = &jb.packets.meta[idx];
                    const data = &jb.packets.data[idx];
                    if (!data.keyframe) {
                        meta.seq = 0;
                        discarded += 1;
                    } else {
                        jb.expected_next_seq = meta.seq;
                        break;
                    }
                };
                if (discarded > 0) {
                    jb.packets.commitRead(packet_slices.index + discarded);
                }

                if (packet_slices.len() - discarded >= start_count) {
                    // if (jb.state == .buffering) {

                    // }
                    jb.state = .playing;
                }
            },
        }

        switch (jb.state) {
            .starting => return .starting,
            .buffering => {
                return .missing;
            },
            .playing => {},
        }

        assert(packet_slices.len() > 0); // invariant

        for (packet_slices.array()) |slice| for (slice) |idx| {
            log.debug("r [{}] -> {} {s}", .{
                idx,
                jb.packets.meta[idx].seq,
                if (jb.packets.data[idx].keyframe) "K" else "",
            });
        };

        var slot: usize = 0;
        for (packet_slices.array()) |slice| for (slice) |idx| {
            slot += 1;

            const next_meta = &jb.packets.meta[idx];

            if (next_meta.seq < jb.expected_next_seq) {
                log.debug("expected {} found {}", .{ jb.expected_next_seq, next_meta });
                next_meta.seq = 0;
                continue;
            }

            if (slot > 1) jb.packets.commitRead(packet_slices.index + slot - 1);

            if (next_meta.seq == jb.expected_next_seq) {
                jb.expected_next_seq += 1;
                return .{
                    .decode = .{
                        .meta = &jb.packets.meta[idx],
                        .data = &jb.packets.data[idx],
                        .r = packet_slices.index + slot,
                        .buffered = @intCast(packet_slices.len() - slot),
                    },
                };
            }

            break;
        };

        // We looked through the full buffer and only found old data
        // which means we're back to buffering mode.
        log.debug("buffer underflow, return missing", .{});
        // jb.packets.commitRead(packet_slices.index + slot);
        // jb.expected_next_seq += 1;
        jb.state = .buffering;
        return .missing;
    }

    pub fn nextPacketCommit(jb: *JitterBuffer, decode: NextPacket.Decode) void {
        jb.packets.commitRead(decode.r);
    }

    const PacketRing = struct {
        /// Index indirection for faster sorting by the video thread.
        indexes: [buffer_len]RingIndex = blk: {
            var default: [buffer_len]RingIndex = undefined;
            for (0..buffer_len) |i| default[i] = i;
            break :blk default;
        },

        /// SoA-style Packet representation
        meta: [buffer_len]Meta = @splat(.{ .seq = 0 }),
        data: [buffer_len]Data = @splat(.{}),

        newest_seq: u32 = 0,
        read_index: std.atomic.Value(usize) = .init(0),
        write_index: std.atomic.Value(usize) = .init(0),

        pub const Meta = struct { seq: u32 };
        pub const Data = struct {
            buffer: []u8 = &.{},
            total_chunks: u32 = undefined,
            seen_chunks: std.DynamicBitSetUnmanaged = .{},
            last_chunk_len: u32 = undefined,
            keyframe: bool = undefined,

            pub fn slice(self: *const @This()) []u8 {
                assert(self.last_chunk_len > 0);
                const full_chunks_size = (self.total_chunks - 1) * media.Video.data_per_chunk;
                return self.buffer[0 .. full_chunks_size + self.last_chunk_len];
            }
        };

        pub const init: PacketRing = .{};
        pub const RingIndex = std.math.IntFittingRange(0, buffer_len);

        pub fn warmup(pb: *PacketRing, gpa: Allocator) !void {
            for (&pb.data) |*d| {
                d.buffer = try gpa.alloc(u8, media.Video.data_per_chunk * 500);
                d.seen_chunks = try .initEmpty(gpa, 500);
            }
        }

        pub fn deinit(pb: *PacketRing, gpa: Allocator) void {
            for (&pb.data) |*d| {
                log.debug("packet ring freeing {}bytes @ {*}", .{ d.buffer.len, d.buffer.ptr });
                gpa.free(d.buffer);
                d.seen_chunks.deinit(gpa);
            }
        }

        pub fn write(pb: *PacketRing, gpa: Allocator, seq: u32, body: []u8) !void {
            const max_data = media.Video.data_per_chunk;
            const video_header, const video_data = media.Video.parse(body) orelse {
                log.debug("discarding malformed packet", .{});
                return;
            };

            // log.debug("video chunk: {} len: {}", .{ video_header, video_data.len });
            errdefer |err| log.debug("video stream packet ring returning with error: {t}", .{err});

            const empty_slices = pb.emptySlices();

            pb.newest_seq = @max(pb.newest_seq, seq);
            const oldest_acceptable_seq = pb.newest_seq -| empty_slices.len();

            if (video_header.chunk_id == 0) {
                log.debug("received seq {}", .{seq});
            }

            // for (empty_slices.array()) |slice| for (slice) |idx| {
            //     const meta = &pb.meta[idx];
            //     const data = &pb.data[idx];

            //     log.debug("[{}] = seq {} chunks: {}, keyframe: {} ", .{
            //         idx,
            //         meta.seq,
            //         data.seen_chunks.count(),
            //         data.keyframe,
            //     });
            // };

            var slot: usize = 0;
            for (empty_slices.array()) |slice| for (slice) |idx| {
                defer slot += 1;

                const meta = &pb.meta[idx];
                const data = &pb.data[idx];
                if (seq == meta.seq or meta.seq == 0 or meta.seq < oldest_acceptable_seq) {
                    if (meta.seq == 0 or meta.seq < oldest_acceptable_seq) {
                        // none of the previous slots had same seq, must start a new one
                        const total_size = max_data * @as(usize, video_header.total_chunks);

                        const old = meta.seq;
                        meta.seq = seq;
                        errdefer meta.seq = old;

                        if (data.buffer.len < total_size) {
                            const oldb = data.buffer;
                            data.buffer = try gpa.alloc(u8, total_size);
                            gpa.free(oldb);
                            var oldc = data.seen_chunks;
                            data.seen_chunks = try .initEmpty(gpa, video_header.total_chunks);
                            oldc.deinit(gpa);
                        } else {
                            data.seen_chunks.unsetAll();
                        }

                        data.keyframe = video_header.keyframe;
                        data.total_chunks = video_header.total_chunks;
                    }

                    // Ignore duplicates
                    if (data.seen_chunks.isSet(video_header.chunk_id)) return;

                    data.seen_chunks.set(video_header.chunk_id);
                    if (video_header.chunk_id == data.total_chunks - 1) {
                        assert(video_data.len > 0);
                        assert(video_data.len <= max_data);

                        data.last_chunk_len = @intCast(video_data.len);
                        @memcpy(
                            data.buffer[max_data * video_header.chunk_id ..][0..video_data.len],
                            video_data,
                        );
                    } else {
                        assert(video_data.len == max_data);
                        @memcpy(
                            data.buffer[max_data * video_header.chunk_id ..][0..max_data],
                            video_data[0..max_data],
                        );
                    }
                    const seen = data.seen_chunks.count();
                    if (seen == data.total_chunks) {
                        // packet is fully reconstructed, ship it!
                        log.debug("packet {} ready, submitting!", .{seq});
                        const w = empty_slices.index;
                        const old_first = pb.indexes[mask(w)];
                        pb.indexes[mask(w)] = idx;
                        pb.indexes[mask(w + slot)] = old_first;
                        pb.write_index.store(mask2(w + 1), .release);
                    }

                    return;
                }
            };

            return error.Full;
        }

        pub const Slices = struct {
            index: usize,
            first: []RingIndex,
            second: []RingIndex,

            pub fn len(s: *const Slices) usize {
                return s.first.len + s.second.len;
            }

            /// Convenience method for iterating over both slices more easily.
            pub fn array(s: *const Slices) [2][]RingIndex {
                return .{ s.first, s.second };
            }
        };

        /// Returns two slices that contain written data.
        /// The first slice contains older data.
        pub fn slices(pb: *PacketRing) Slices {
            const w = pb.write_index.load(.acquire);
            const r = pb.read_index.load(.acquire);
            const l = len(w, r);

            const slice1_start = mask(r);
            const slice1_end = @min(buffer_len, slice1_start + l);

            const slice1 = pb.indexes[slice1_start..slice1_end];
            std.sort.pdq(RingIndex, slice1, pb, lessThan);

            const slice2 = pb.indexes[0 .. l - slice1.len];
            std.sort.pdq(RingIndex, slice2, pb, lessThan);

            return .{
                .index = r,
                .first = slice1,
                .second = slice2,
            };
        }

        pub fn emptySlices(pr: *PacketRing) Slices {
            const w = pr.write_index.load(.acquire);
            const r = pr.read_index.load(.acquire);
            const l = len(w, r);
            const free = buffer_len - l;

            const slice1_start = mask(w);
            const slice1_end = @min(buffer_len, slice1_start + free);
            const slice1 = pr.indexes[slice1_start..slice1_end];
            const slice2 = pr.indexes[0 .. free - slice1.len];

            return .{
                .index = w,
                .first = slice1,
                .second = slice2,
            };
        }

        pub fn commitRead(pb: *PacketRing, new_read_index: usize) void {
            pb.read_index.store(mask2(new_read_index), .release);
        }

        fn mask(index: usize) usize {
            return index % buffer_len;
        }

        fn mask2(index: usize) usize {
            return index % (2 * buffer_len);
        }

        pub fn len(w: usize, r: usize) usize {
            const wrap_offset = 2 * buffer_len * @intFromBool(w < r);
            const adjusted_write_index = w + wrap_offset;
            return adjusted_write_index - r;
        }

        pub fn lessThan(pb: *const PacketRing, lhs_idx: RingIndex, rhs_idx: RingIndex) bool {
            const lhs = pb.meta[lhs_idx];
            const rhs = pb.meta[rhs_idx];
            return lhs.seq < rhs.seq;
        }
    };
};

const MacOsNative = struct {
    comptime {
        @export(&swapBackFrame, .{ .linkage = .strong, .name = "aweboVideoSwapFrame" });
    }

    pub const Frame = opaque {
        extern fn frameDeinit(*Frame) void;
        pub fn deinit(f: *Frame) void {
            frameDeinit(f);
        }

        extern fn frameGetImage(*Frame) Image.Bgra;
        pub fn getImage(f: *Frame) Image {
            return .{ .bgra = frameGetImage(f) };
        }
    };

    decoder: *NativeDecoder,

    const NativeDecoder = opaque {};

    extern fn videoDecoderInit(*VideoStream, Format.Codec, u32, u32, [*]const u8) *NativeDecoder;
    pub fn init(c: *VideoStream, gpa: Allocator, format: Format, first_frame_data: []const u8) !MacOsNative {
        _ = gpa;
        return .{
            .decoder = videoDecoderInit(
                c,
                format.codec,
                format.width,
                format.height,
                first_frame_data.ptr,
            ),
        };
    }

    extern fn videoDecoderDeinit(*NativeDecoder) void;
    pub fn deinit(mc: *MacOsNative) void {
        videoDecoderDeinit(mc.decoder);
    }

    extern fn videoReceivedFrameBytes(*NativeDecoder, data: [*]const u8, len: usize, keyframe: bool) u32;
    pub fn decodeFrame(mc: *MacOsNative, data: []const u8, keyframe: bool) !u32 {
        return videoReceivedFrameBytes(mc.decoder, data.ptr, data.len, keyframe);
    }
};

const Dummy = struct {
    pub const Frame = opaque {
        pub fn deinit(f: *Frame) void {
            _ = f;
        }

        pub fn getImage(f: *Frame) Image {
            _ = f;
            return .{
                .bgra = .{
                    .height = 0,
                    .width = 0,
                    .pixels = &.{},
                },
            };
        }
    };

    pub fn init(c: *VideoStream, gpa: Allocator, format: Format, first_frame_data: []const u8) !Dummy {
        _ = c;
        _ = format;
        _ = first_frame_data;
        _ = gpa;
        return .{};
    }
    pub fn deinit(d: *Dummy) void {
        _ = d;
    }
    pub fn decodeFrame(d: *Dummy, data: []const u8, keyframe: bool) !u32 {
        _ = d;
        _ = data;
        _ = keyframe;
        return 0;
    }
};
