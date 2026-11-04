const ScreenCapture = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const awebo = @import("../../awebo.zig");
const media = awebo.protocol.media;
const Core = @import("../Core.zig");
const PacketRing = @import("packet_ring.zig").PacketRing;
const ffmpeg = @import("ffmpeg.zig");
const VideoStream = @import("VideoStream.zig");
const MacOsInterface = @import("MacOS.zig").Interface;
const WaylandInterface = @import("Wayland.zig");

pub const State = union(enum) {
    off,
    active: Active,

    pub const Active = struct {
        config: media.Config,
        encoder: ffmpeg.Encoder,
    };
};

pub const Packet = struct {
    payload: enum { audio, audio_silence, video, video_keyframe },
    full_chunks: usize,
    last_chunk_data: usize,
    data: std.ArrayList(u8),
};

// This is where we might want to store state such as an array list of
// ScreenCapture sources in case that we can't rely on an OS-provided
// picker.
// windows: []Window
// displays: []Display

/// While capturing, this value is atomically replaced with a new frame by
/// the OS. Should be processed by the UI to show a preview of the current
/// stream, if desireable. The application can ignore this value, in which
/// case the OS is expected to clean it up but, if used, the client is
/// expected to:
/// 1. call swapFrame() to swap the value with null
/// 2. if it got a new frame, quickly copy pixel data out and call deinit.
new_frame: std.atomic.Value(?*Frame),
last_keyframe_ms: u64 = 0,
stop_mutex: Io.Mutex = .init,
sequence: u32 = 0,
packets: PacketRing(Packet, 8) = .empty,
state: State = .off,
send: std.atomic.Value(bool) = .init(false),
os: OsInterface,

pub const OsInterface = switch (builtin.target.os.tag) {
    .macos => *MacOsInterface,
    .linux => WaylandInterface,
    else => *DummyInterface,
};

pub const supports_os_picker = switch (builtin.target.os.tag) {
    .macos => MacOsInterface.supports_os_picker,
    .linux => WaylandInterface.supports_os_picker,
    else => false,
};

pub const Frame = switch (builtin.target.os.tag) {
    .macos => MacOsInterface.MacOsFrame,
    .linux => WaylandInterface.WaylandFrame,
    else => DummyInterface.DummyFrame,
};

pub fn init(sc: *ScreenCapture, io: Io, gpa: Allocator) void {
    sc.* = .{ .new_frame = .init(null), .os = undefined };
    switch (builtin.target.os.tag) {
        .linux => sc.os.init(io, gpa, sc),
        .macos => MacOsInterface.init(&sc.os, gpa, sc),
        else => unreachable,
    }

    for (&sc.packets.buffer) |*packet| {
        packet.data = std.ArrayList(u8).initCapacity(gpa, 200_000) catch @panic("oom");
    }
}

fn reset(sc: *ScreenCapture) void {
    sc.state = .off;
    sc.sequence = 0;
    sc.last_keyframe_ms = 0;
    sc.send.store(false, .unordered);
    sc.packets.reset();
}

pub fn deinit(sc: *ScreenCapture) void {
    if (builtin.mode != .debug) return;
    sc.os.deinit();
}

pub fn startCapture(
    sc: *ScreenCapture,
    lossless: bool,
    config: media.Config,
    display_idx: ?usize,
) !media.Format {
    assert(sc.state == .off);
    sc.reset();
    sc.state = .{
        .active = .{
            .config = config,
            .encoder = try .init(lossless, config),
        },
    };

    if (supports_os_picker) {
        sc.os.showOsPicker(config, sc.state.active.encoder.codec.pixFmtToImageKind());
    } else {
        sc.os.startCapture(config, display_idx.?);
    }

    return .{
        .config = config,
        .codec = sc.state.active.encoder.codec.kind,
    };
}

pub fn stopCapture(sc: *ScreenCapture) void {
    assert(sc.state == .active);

    sc.os.stopCapture();

    const core: *Core = @alignCast(@fieldParentPtr("screen_capture", sc));
    sc.stop_mutex.lockUncancelable(core.io);
    defer sc.stop_mutex.unlock(core.io);

    if (sc.frameSwap(null)) |frame| frame.deinit();
    sc.state.active.encoder.deinit();
    sc.state = .off;
}

// Called by the OS to signal that the stream was interruped externally.
pub fn streamWasInterrupted(sc: *ScreenCapture) callconv(.c) void {
    // todo
    _ = sc;
}

/// Called by the OS to provide a new frame.
pub fn framePush(sc: *ScreenCapture, frame: *Frame, delta_from_start_ms: u64) callconv(.c) void {
    const core: *Core = @alignCast(@fieldParentPtr("screen_capture", sc));
    if (!sc.stop_mutex.tryLock()) {
        frame.deinit();
        return;
    }
    defer sc.stop_mutex.unlock(core.io);
    blk: {
        const packet, const extradata = switch (sc.state.active.encoder.codec.pixFmtToImageKind()) {
            .videotoolbox => sc.state.active.encoder.encode(.{
                .videotoolbox = .{
                    .width = sc.state.active.config.width,
                    .height = sc.state.active.config.height,
                    .ptr = frame,
                },
            }, delta_from_start_ms) catch unreachable,
            else => sc.state.active.encoder.encode(frame.getImage(), delta_from_start_ms) catch unreachable,
        } orelse break :blk;
        const delta: u32 = @intCast(delta_from_start_ms - sc.last_keyframe_ms);
        const keyframe = extradata.len > 0;
        if (keyframe) sc.last_keyframe_ms = delta_from_start_ms;
        sc.encodedVideoFramePush(packet, extradata, delta);
    }
    if (sc.frameSwap(frame)) |old| {
        std.log.debug("gui thread dropped a frame!", .{});
        old.deinit();
    }
}

/// Called by UI to pull a new frame to show as a preview.
pub fn framePull(sc: *ScreenCapture) ?*Frame {
    return sc.frameSwap(null);
}

fn frameSwap(sc: *ScreenCapture, new: ?*Frame) ?*Frame {
    return sc.new_frame.swap(new, .acq_rel);
}

pub fn encodedVideoFramePush(
    sc: *ScreenCapture,
    data: []const u8,
    extradata: []const u8,
    delta: u32,
) void {
    if (!sc.send.load(.unordered)) return;

    const core: *Core = @alignCast(@fieldParentPtr("screen_capture", sc));
    const pw = sc.packets.beginWrite() orelse {
        std.log.debug("dropping screencapture frame, network thread is too slow!", .{});
        return;
    };

    sc.sequence += 1;
    pw.packet.data.clearRetainingCapacity();

    const header_size = @sizeOf(media.Header);
    const video_size = @sizeOf(media.Video);
    const framing_size: usize = header_size + video_size;
    const delta_size = @sizeOf(@TypeOf(delta));
    const extradata_size_size = @sizeOf(u16);
    const full_chunk_data = 1280 - framing_size;
    const total_size = delta_size + extradata_size_size + extradata.len + data.len;
    const full_chunks: usize = @intCast(@divTrunc(total_size, full_chunk_data));
    const last_chunk_data = total_size % full_chunk_data;
    const total_chunks = full_chunks + if (last_chunk_data > 0) 1 else @as(usize, 0);
    const total_size_framed = (total_chunks * framing_size) + total_size;
    const keyframe = extradata.len > 0;
    pw.packet.data.ensureUnusedCapacity(core.gpa, total_size_framed) catch @panic("oom");
    pw.packet.data.items.len = total_size_framed;

    std.log.debug("packet {} total size {} framed size {} extradata: [{x}]", .{
        sc.sequence,
        total_size,
        total_size_framed,
        extradata,
    });

    const header: media.Header = .{
        .stream_id = .{ .client_id = .{ .slot = 0, .user_id = .invalid }, .kind = .screen },
        .sequence = sc.sequence,
    };

    media.write.packedStruct(media.Header, pw.packet.data.items.ptr, header);
    media.write.packedStruct(media.Video, pw.packet.data.items.ptr + header_size, .{
        .chunk_id = 0,
        .total_chunks = @intCast(total_chunks),
        .keyframe = keyframe,
    });

    media.write.int(u32, pw.packet.data.items.ptr + framing_size, delta);
    media.write.int(u32, pw.packet.data.items.ptr + framing_size + delta_size, @intCast(extradata.len));
    @memcpy(pw.packet.data.items.ptr + framing_size + delta_size + extradata_size_size, extradata);

    const start = framing_size + delta_size + extradata_size_size + extradata.len;
    assert(start < full_chunk_data);

    const data_start = 1280 - start;
    @memcpy(pw.packet.data.items.ptr + start, data[0..@min(data_start, data.len)]);

    if (full_chunks > 1) {
        for (1..full_chunks) |chunk_id| {
            const chunk = pw.packet.data.items.ptr + (chunk_id * 1280);
            media.write.packedStruct(media.Header, chunk, header);
            media.write.packedStruct(media.Video, chunk + header_size, .{
                .chunk_id = @intCast(chunk_id),
                .total_chunks = @intCast(total_chunks),
                .keyframe = keyframe,
            });

            @memcpy(
                chunk + framing_size,
                data[data_start + (full_chunk_data * (chunk_id - 1)) ..][0..full_chunk_data],
            );
        }
    }

    if (full_chunks > 0 and last_chunk_data > 0) {
        const chunk = pw.packet.data.items.ptr + (full_chunks * 1280);
        media.write.packedStruct(media.Header, chunk, header);
        media.write.packedStruct(media.Video, chunk + header_size, .{
            .chunk_id = @intCast(full_chunks),
            .total_chunks = @intCast(total_chunks),
            .keyframe = keyframe,
        });

        @memcpy(
            chunk + framing_size,
            data[data_start + (full_chunk_data * (full_chunks - 1)) ..],
        );
    }

    pw.packet.payload = if (keyframe) .video_keyframe else .video;
    pw.packet.full_chunks = full_chunks;
    pw.packet.last_chunk_data = last_chunk_data;
    assert(full_chunks > 0 or last_chunk_data > 0);

    sc.packets.commitWrite(pw);
}

pub const DummyInterface = opaque {
    pub fn init(sc: *ScreenCapture) *DummyInterface {
        _ = sc;
        return undefined;
    }

    pub fn deinit(di: *DummyInterface) void {
        _ = di;
    }

    pub fn showOsPicker(di: *DummyInterface, config: media.Config, kind: VideoStream.ImageKind) void {
        _ = di;
        _ = config;
        _ = kind;
    }

    pub fn stopCapture(di: *DummyInterface) void {
        _ = di;
    }

    pub const DummyFrame = struct {
        pub fn deinit(f: *DummyFrame) void {
            _ = f;
        }

        pub fn getImage(f: *DummyFrame) VideoStream.Image {
            _ = f;
            return undefined;
        }
    };
};
