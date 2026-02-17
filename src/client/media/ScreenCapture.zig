const ScreenCapture = @This();

const builtin = @import("builtin");
const std = @import("std");
const Core = @import("../Core.zig");

// This is where we might want to store state such as
// an array list of ScreenCapture sources in case that
// we can't rely on an OS-provided picker.
// windows: []Window
// displays: []Display

// True when the user initiated screen sharing
share_intent: bool = false,

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

pub fn init(sc: *ScreenCapture) void {
    sc.* = .{ .new_frame = .init(null), .os = .init(sc) };
}

pub fn deinit(sc: *ScreenCapture) void {
    if (builtin.mode != .Debug) return;
    sc.os.deinit();
}

/// Shows the OS-provided screenshare picker.
/// Might not be available on all OSs.
pub fn showOsPicker(sc: *ScreenCapture) void {
    sc.os.showOsPicker();
}

/// Function with C callconv that the OS can invoke whenever
/// a new screen capture frame is ready.
pub fn swapFrame(sc: *ScreenCapture, new: ?*Frame) callconv(.c) ?*Frame {
    return sc.new_frame.swap(new, .acq_rel);
}

/// See 'media/screen-share-macos.m'
pub const MacOsInterface = opaque {
    comptime {
        @export(&swapFrame, .{ .linkage = .strong, .name = "aweboScreenCaptureSwapFrame" });
    }

    pub const MacOsFrame = opaque {
        extern fn frameDeinit(*MacOsFrame) void;
        pub fn deinit(f: *MacOsFrame) void {
            frameDeinit(f);
        }

        extern fn frameGetPixels(*MacOsFrame) Pixels;
        pub fn getPixels(f: *MacOsFrame) Pixels {
            return frameGetPixels(f);
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

    pub const DummyFrame = struct {
        pub fn deinit(f: *DummyFrame) void {
            _ = f;
        }

        pub fn getPixels(f: *DummyFrame) Pixels {
            _ = f;
            return .{ .height = 0, .width = 0, .pixels = null };
        }
    };
};
