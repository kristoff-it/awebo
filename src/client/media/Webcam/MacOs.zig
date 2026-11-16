const std = @import("std");
const Io = std.Io;
const WebcamCapture = @import("../Webcam.zig");

/// See `media/webcam-capture-macos.m`
pub const Interface = opaque {
    comptime {
        @export(&WebcamCapture.upsertDeviceC, .{ .linkage = .strong, .name = "aweboWebcamUpsert" });
        @export(&WebcamCapture.swapFrame, .{ .linkage = .strong, .name = "aweboWebcamSwapFrame" });
    }

    pub const MacOsFrame = @import("../Screen/MacOS.zig").Interface.MacOsFrame;

    extern fn webcamCaptureManagerInit() *Interface;
    pub fn init() *Interface {
        return webcamCaptureManagerInit();
    }

    extern fn webcamCaptureManagerDeinit(*Interface) void;
    pub fn deinit(mi: *Interface) void {
        return webcamCaptureManagerDeinit(mi);
    }

    extern fn webcamDiscoverDevicesAndListen(*Interface, *WebcamCapture) void;
    pub fn discoverDevicesAndListen(mi: *Interface, io: Io, wc: *WebcamCapture) !void {
        _ = io;
        webcamDiscoverDevicesAndListen(mi, wc);
    }

    extern fn webcamStartCapture(*Interface, id: ?[*:0]const u8, width: c_int, height: c_int, fps: c_int) bool;
    pub fn startCapture(mi: *Interface, device: ?*WebcamCapture.Device, width: i32, height: i32, fps: i32) bool {
        const id = if (device) |d| d.id.ptr else null;
        return webcamStartCapture(mi, id, width, height, fps);
    }

    extern fn webcamStopCapture(*Interface) void;
    pub fn stopCapture(mi: *Interface) void {
        webcamStopCapture(mi);
    }
};
