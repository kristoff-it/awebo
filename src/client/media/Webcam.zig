const WebcamCapture = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Core = @import("../Core.zig");
const ScreenCapture = @import("Screen.zig");
const MacOsInterface = @import("Webcam/MacOs.zig").Interface;
const LinuxInterface = @import("Webcam/Linux.zig").Interface;
const log = std.log.scoped(.webcam_capture);

/// True when the user initiated webcam sharing
share_intent: bool = false,

/// The unique id of the device currently selected.
/// Null means system default.
/// The device might not be connected.
selected: ?[:0]const u8,

/// Keyed by the device unique ID.
devices: std.StringArrayHashMapUnmanaged(Webcam),

/// While capturing, this value is atomically replaced
/// with a new frame by the OS.
/// Should be processed by the UI to show a preview of
/// the current stream, if desireable.
/// The application can ignore this value, in which case
/// the OS is expected to clean it up but, if used, the
/// client is expected to:
/// 1. call swapFrame() to swap the value with null
/// 2. if it got a new frame, quickly copy pixel data
///    out and call deinit.
new_frame: std.atomic.Value(?*Frame),

/// Os interface
os: switch (builtin.target.os.tag) {
    .macos => *MacOsInterface,
    .linux => *LinuxInterface,
    else => *DummyInterface,
},

pub const Frame = switch (builtin.target.os.tag) {
    .macos => MacOsInterface.MacOsFrame,
    else => DummyInterface.DummyFrame,
};

pub const Webcam = struct {
    id: [:0]const u8,
    name: [:0]const u8,
    connected: bool,
    os: OsWebcam,
};

pub const OsWebcam = switch (builtin.target.os.tag) {
    .macos => void,
    .linux => LinuxInterface.Webcam,
    else => void,
};

/// Must call start() next to subscribe to device update notifications.
/// WebcamCapture must be kept stored in Core as it uses fieldParentPtr to access it.
pub fn init() WebcamCapture {
    return .{
        .selected = null,
        .devices = .empty,
        .new_frame = .init(null),
        .os = .init(),
    };
}

pub fn deinit(wc: *WebcamCapture) void {
    if (builtin.mode != .debug) return;

    // Must be done first to ensure objc stops messing with our data
    wc.os.deinit();

    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    for (wc.devices.values()) |cam| {
        core.gpa.free(cam.id);
        core.gpa.free(cam.name);
    }

    wc.devices.deinit(core.gpa);
}

pub fn discoverDevicesAndListen(wc: *WebcamCapture) void {
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    wc.os.discoverDevicesAndListen(core.io, wc) catch {
        @panic("error while discovering webcams");
    };
}

pub fn startCapture(wc: *WebcamCapture) void {
    const id = if (wc.selected) |s| s.ptr else null;
    _ = wc.os.startCapture(id, 1920, 1080, 30);
}

pub fn stopCapture(wc: *WebcamCapture) void {
    wc.os.stopCapture();
}

/// Function with C callconv that the OS can invoke whenever
/// a new screen capture frame is ready.
pub fn swapFrame(sc: *WebcamCapture, new: ?*Frame) callconv(.c) ?*Frame {
    return sc.new_frame.swap(new, .acq_rel);
}

/// C-ABI compatible wrapper around 'upsertDevice' for C libraries.
/// Requires OsWebcam to be C-compatible.
fn upsertDeviceC(
    wc: *WebcamCapture,
    raw_id: [*:0]const u8,
    raw_name: [*:0]const u8,
    connected: bool,
    os: OsWebcam,
) callconv(.c) void {
    upsertDevice(wc, std.mem.span(raw_id), std.mem.span(raw_name), connected, os);
}

/// Called by OS implementations to update the device list.
/// Uses fieldParentPtr to lock *Core while modifying the data.
/// `raw_id` and `raw_name` will be duped when inserting the device for the first time.
pub fn upsertDevice(
    wc: *WebcamCapture,
    id: []const u8,
    name: []const u8,
    connected: bool,
    os: OsWebcam,
) void {
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    var locked = Core.lockState(core);
    defer locked.unlock();

    const gop = wc.devices.getOrPut(core.gpa, id) catch oom();

    log.debug("upserting Webcam(id: '{s}', name: '{s}', active: {})", .{ id, name, connected });

    if (!gop.found_existing) {
        const key = core.gpa.dupeSentinel(u8, id, 0) catch oom();
        gop.key_ptr.* = key;
        gop.value_ptr.* = .{
            .id = key,
            .name = core.gpa.dupeSentinel(u8, name, 0) catch oom(),
            .connected = connected,
            .os = os,
        };
    } else {
        gop.value_ptr.connected = connected;
    }
}

const DummyInterface = opaque {
    pub const DummyFrame = ScreenCapture.DummyInterface.DummyFrame;

    pub fn init() *DummyInterface {
        return undefined;
    }

    pub fn deinit(mi: *DummyInterface) void {
        _ = mi;
    }

    pub fn discoverDevicesAndListen(mi: *DummyInterface, wc: *WebcamCapture) void {
        _ = mi;
        var buf: [256]u8 = undefined;
        for (0..5) |i| {
            const id = std.fmt.bufPrintSentinel(&buf, "ID Dummy Device #{}", .{i}, 0) catch unreachable;
            wc.upsertDevice(id.ptr, id[3..].ptr, true, {});
        }
    }

    pub fn startCapture(mi: *DummyInterface, id: ?[*:0]const u8, width: i32, height: i32, fps: i32) bool {
        _ = mi;
        _ = id;
        _ = width;
        _ = height;
        _ = fps;
        return false;
    }

    pub fn stopCapture(mi: *DummyInterface) void {
        _ = mi;
    }
};

fn oom() noreturn {
    std.process.fatal("out of memory", .{});
}
