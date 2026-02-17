const WebcamCapture = @This();

const builtin = @import("builtin");
const std = @import("std");
const Core = @import("../Core.zig");
const log = std.log.scoped(.webcam_capture);

/// The device currently selected. Null means system default.
/// The device might not be connected.
selected: ?[:0]const u8,
/// Keyed by the device's unique ID.
devices: std.StringArrayHashMapUnmanaged(Webcam),
/// Os interface
os: switch (builtin.target.os.tag) {
    .macos => *MacOSInterface,
    else => *DummyInterface,
},

pub const Webcam = struct {
    id: [:0]const u8,
    name: [:0]const u8,
    connected: bool,
};

/// Must call start() next to subscribe to device update notifications.
/// WebcamCapture must be kept stored in Core as it uses fieldParentPtr to access it.
pub fn init() WebcamCapture {
    return .{
        .selected = null,
        .devices = .empty,
        .os = .init(),
    };
}

pub fn deinit(wc: *WebcamCapture) void {
    if (builtin.mode != .Debug) return;

    // Must be done first to ensure objc stops messing with our data
    wc.os.deinit();

    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    for (wc.devices.values()) |cam| {
        core.gpa.free(cam.id);
        core.gpa.free(cam.name);
    }

    wc.devices.deinit(core.gpa);
}

/// Collects device
pub fn discoverDevicesAndListen(wc: *WebcamCapture) void {
    wc.os.discoverDevicesAndListen(wc);
}

pub fn startCapture(wc: *WebcamCapture) void {
    const id = if (wc.selected) |s| s.ptr else null;
    _ = wc.os.startCapture(id, 1920, 1080, 30);
}

/// Function with C callconv that OS APIs can call to update the device list.
/// Uses fieldParentPtr to lock *Core while modifying the data.
/// `raw_id` and `raw_name` will be duped when inserting the device for the first time.
fn upsertDevice(
    wc: *WebcamCapture,
    raw_id: [*:0]const u8,
    raw_name: [*:0]const u8,
    connected: bool,
) callconv(.c) void {
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    var locked = Core.lockState(core);
    defer locked.unlock();

    const id = std.mem.span(raw_id);
    const gop = wc.devices.getOrPut(core.gpa, id) catch oom();

    log.debug("upserting Webcam(id: '{s}', name: '{s}', active: {})", .{ id, raw_name, connected });

    if (!gop.found_existing) {
        const name = std.mem.span(raw_name);
        const key = core.gpa.dupeSentinel(u8, id, 0) catch oom();
        gop.key_ptr.* = key;
        gop.value_ptr.* = .{
            .id = key,
            .name = core.gpa.dupeSentinel(u8, name, 0) catch oom(),
            .connected = connected,
        };
    } else {
        gop.value_ptr.connected = connected;
    }
}

/// See `media/webcam-capture-macos.m`
const MacOSInterface = opaque {
    comptime {
        @export(&upsertDevice, .{ .linkage = .strong, .name = "aweboWebcamUpsertCallback" });
    }

    extern fn webcamCaptureManagerInit() *MacOSInterface;
    pub fn init() *MacOSInterface {
        return webcamCaptureManagerInit();
    }

    extern fn webcamCaptureManagerDeinit(*MacOSInterface) void;
    pub fn deinit(mi: *MacOSInterface) void {
        return webcamCaptureManagerDeinit(mi);
    }

    extern fn webcamDiscoverDevicesAndListen(*MacOSInterface, *WebcamCapture) void;
    pub fn discoverDevicesAndListen(mi: *MacOSInterface, wc: *WebcamCapture) void {
        webcamDiscoverDevicesAndListen(mi, wc);
    }

    extern fn webcamStartCapture(*MacOSInterface, id: ?[*:0]const u8, width: c_int, height: c_int, fps: c_int) bool;
    pub fn startCapture(mi: *MacOSInterface, id: ?[*:0]const u8, width: i32, height: i32, fps: i32) bool {
        return webcamStartCapture(mi, id, width, height, fps);
    }
};

const DummyInterface = opaque {
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
            const id = std.fmt.bufPrintZ(&buf, "ID Dummy Device #{}", .{i}) catch unreachable;
            wc.upsertDevice(id.ptr, id[3..].ptr, true);
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
};

fn oom() noreturn {
    std.process.fatal("out of memory", .{});
}
