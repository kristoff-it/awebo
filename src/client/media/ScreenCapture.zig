const ScreenCapture = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const awebo = @import("../../awebo.zig");
const Core = @import("../Core.zig");
const PacketRing = @import("packet_ring.zig").PacketRing;

pub const State = enum(u32) {
    off = 0,
    picking = 1,
    on = 2,
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
sequence: u32 = 0,
packets: PacketRing(Packet, 8) = .empty,
state: State = .off,

/// Os interface
os: switch (builtin.target.os.tag) {
    .macos => *MacOsInterface,
    else => *DummyInterface,
},

pub const Frame = switch (builtin.target.os.tag) {
    .macos => MacOsInterface.MacOsFrame,
    else => DummyInterface.DummyFrame,
};

pub const Pixels = extern struct {
    width: usize,
    height: usize,
    pixels: ?[*]u8,
};

pub fn init(sc: *ScreenCapture, gpa: Allocator) void {
    sc.* = .{ .new_frame = .init(null), .os = .init(sc) };
    for (&sc.packets.buffer) |*packet| {
        packet.data = std.ArrayList(u8).initCapacity(gpa, 200_000) catch @panic("oom");
    }
}

pub fn deinit(sc: *ScreenCapture) void {
    if (builtin.mode != .Debug) return;
    sc.os.deinit();
}

/// Shows the OS-provided screenshare picker.
/// Might not be available on all OSs.
/// Once the user has selected a window or display to share,
/// a the stream will start automatically.
pub fn showOsPicker(sc: *ScreenCapture) void {
    assert(sc.state == .off);
    sc.os.showOsPicker();
    sc.state = .picking;
    sc.sequence = 0;
    sc.packets.reset();
}

pub fn stopCapture(sc: *ScreenCapture) void {
    assert(sc.state == .on);
    sc.os.stopCapture();
    sc.state = .off;
}

fn updateState(sc: *ScreenCapture, new: State) callconv(.c) void {
    sc.state = new;
}

/// Function with C callconv that the OS can invoke whenever
/// a new screen capture frame is ready.
pub fn swapFrame(sc: *ScreenCapture, new: ?*Frame) callconv(.c) ?*Frame {
    return sc.new_frame.swap(new, .acq_rel);
}

fn encodedVideoFramePush(
    sc: *ScreenCapture,
    data: [*]const u8,
    len: usize,
    keyframe: bool,
) callconv(.c) void {
    const core: *Core = @alignCast(@fieldParentPtr("screen_capture", sc));
    const w = sc.packets.beginWrite() orelse {
        std.log.debug("dropping screencapture frame, network thread is too slow!", .{});
        return;
    };

    sc.sequence += 1;
    w.packet.data.clearRetainingCapacity();

    const media = awebo.protocol.media;
    const header_size = @sizeOf(media.Header);
    const video_size = @sizeOf(media.Video);
    const framing_size: usize = header_size + video_size;
    const full_chunk_data = 1280 - framing_size;
    const full_chunks: u15 = @intCast(@divTrunc(len, full_chunk_data));
    const last_chunk_data = len % full_chunk_data;
    const total_chunks: u15 = full_chunks + if (last_chunk_data > 0) 1 else @as(u15, 0);
    const total = (total_chunks * framing_size) + len;
    w.packet.data.ensureUnusedCapacity(core.gpa, total) catch @panic("oom");
    w.packet.data.items.len = total;

    std.log.debug("packet {} data size {} total size {}", .{ sc.sequence, len, total });

    for (0..full_chunks) |chunk_id| {
        const chunk = w.packet.data.items[chunk_id * 1280 ..][0..1280];
        const header: *align(1) media.Header = @ptrCast(chunk.ptr);
        const video: *align(1) media.Video = @ptrCast(chunk[header_size..].ptr);
        const data_out = chunk[framing_size..];

        header.stream_id.kind = .screen;
        header.sequence = sc.sequence;

        video.chunk_id = @intCast(chunk_id);
        video.total_chunks = total_chunks;
        video.keyframe = keyframe;

        @memcpy(data_out, data[full_chunk_data * chunk_id ..][0..full_chunk_data]);
    }

    if (last_chunk_data > 0) {
        const chunk = w.packet.data.items[@as(usize, full_chunks) * 1280 ..];
        const header: *align(1) media.Header = @ptrCast(chunk.ptr);
        const video: *align(1) media.Video = @ptrCast(chunk[header_size..].ptr);
        const data_out = chunk[framing_size..];

        header.stream_id.kind = .screen;
        header.sequence = sc.sequence;

        video.chunk_id = full_chunks;
        video.total_chunks = total_chunks;
        video.keyframe = keyframe;

        @memcpy(data_out, data[full_chunk_data * full_chunks ..]);
    }

    w.packet.payload = if (keyframe) .video_keyframe else .video;
    w.packet.full_chunks = full_chunks;
    w.packet.last_chunk_data = last_chunk_data;
    assert(full_chunks > 0 or last_chunk_data > 0);

    sc.packets.commitWrite(w);
}

/// See 'media/screen-share-macos.m'
pub const MacOsInterface = opaque {
    comptime {
        @export(&swapFrame, .{ .linkage = .strong, .name = "aweboScreenCaptureSwapFrame" });
        @export(&encodedVideoFramePush, .{ .linkage = .strong, .name = "aweboScreenCaptureEncodedVideoFrame" });
        @export(&updateState, .{ .linkage = .strong, .name = "aweboScreenCaptureUpdate" });
    }

    pub const MacOsFrame = opaque {
        extern fn frameDeinit(*MacOsFrame) void;
        pub fn deinit(f: *MacOsFrame) void {
            frameDeinit(f);
        }

        extern fn frameGetImage(*MacOsFrame) Pixels;
        pub fn getImage(f: *MacOsFrame) Pixels {
            return frameGetImage(f);
        }
    };

    extern fn screenCaptureManagerInit(sc: *ScreenCapture) *MacOsInterface;
    pub fn init(sc: *ScreenCapture) *MacOsInterface {
        return screenCaptureManagerInit(sc);
    }

    extern fn screenCaptureManagerDeinit(*MacOsInterface) void;
    pub fn deinit(mi: *MacOsInterface) void {
        screenCaptureManagerDeinit(mi);
    }

    extern fn screenCaptureManagerShowPicker(*MacOsInterface) void;
    pub fn showOsPicker(mi: *MacOsInterface) void {
        screenCaptureManagerShowPicker(mi);
    }

    extern fn screenCaptureManagerStopCapture(*MacOsInterface) void;
    pub fn stopCapture(mi: *MacOsInterface) void {
        screenCaptureManagerStopCapture(mi);
    }
};

pub const DummyInterface = opaque {
    pub fn init(sc: *ScreenCapture) *DummyInterface {
        _ = sc;
        return undefined;
    }

    pub fn deinit(di: *DummyInterface) void {
        _ = di;
    }

    pub fn showOsPicker(di: *DummyInterface) void {
        _ = di;
    }

    pub fn stopCapture(di: *DummyInterface) void {
        _ = di;
    }

    pub const DummyFrame = struct {
        pub fn deinit(f: *DummyFrame) void {
            _ = f;
        }

        pub fn getImage(f: *DummyFrame) Pixels {
            _ = f;
            return .{ .height = 0, .width = 0, .pixels = null };
        }
    };
};
