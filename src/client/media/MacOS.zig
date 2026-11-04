const std = @import("std");
const awebo = @import("../../awebo.zig");
const media = awebo.protocol.media;
const ScreenCapture = @import("ScreenCapture.zig");
const framePush = ScreenCapture.framePush;
const streamWasInterrupted = ScreenCapture.streamWasInterrupted;
const VideoStream = @import("VideoStream.zig");

pub const supports_os_picker = true;

/// See 'media/screen-share-macos.m'
pub const Interface = opaque {
    comptime {
        @export(&framePush, .{ .linkage = .strong, .name = "aweboScreenCapturePushFrame" });
        @export(&streamWasInterrupted, .{ .linkage = .strong, .name = "aweboScreenCaptureUpdate" });
    }

    pub const MacOsFrame = opaque {
        extern fn frameDeinit(*MacOsFrame) void;
        pub fn deinit(f: *MacOsFrame) void {
            frameDeinit(f);
        }

        pub const RawImage = extern struct {
            width: u32,
            height: u32,
            ptr1: ?*anyopaque,
            ptr2: ?*anyopaque,
            ptr3: ?*anyopaque,
            stride1: u32,
            stride2: u32,
            stride3: u32,
            kind: VideoStream.ImageKind,
        };
        extern fn frameGetImage(*MacOsFrame) RawImage;
        pub fn getImage(f: *MacOsFrame) VideoStream.Image {
            const raw = frameGetImage(f);
            return switch (raw.kind) {
                .videotoolbox => unreachable,
                //.{
                // .videotoolbox = .{
                //     .width = raw.width,
                //     .height = raw.height,
                //     .ptr = @ptrCast(raw.ptr1),
                // },
                //},
                .nv12 => .{
                    .nv12 = .{
                        .width = raw.width,
                        .height = raw.height,
                        .y = @ptrCast(raw.ptr1),
                        .y_stride = raw.stride1,
                        .cbcr = @ptrCast(raw.ptr2),
                        .cbcr_stride = raw.stride2,
                        .color = .bt709f,
                    },
                },
                .yuv => .{
                    .yuv = .{
                        .width = raw.width,
                        .height = raw.height,
                        .y = @ptrCast(raw.ptr1),
                        .y_stride = raw.stride1,
                        .cb = @ptrCast(raw.ptr2),
                        .cb_stride = raw.stride2,
                        .cr = @ptrCast(raw.ptr3),
                        .cr_stride = raw.stride2,
                        .color = .bt709f,
                    },
                },
                .bgra => .{
                    .bgra = .{
                        .width = raw.width,
                        .height = raw.height,
                        .pixels = @ptrCast(raw.ptr1),
                        .stride = raw.stride1,
                    },
                },
            };
        }
    };

    extern fn screenCaptureManagerInit(sc: *ScreenCapture) *Interface;
    pub fn init(i_ptr: **Interface, gpa: std.mem.Allocator, sc: *ScreenCapture) void {
        _ = gpa;
        i_ptr.* = screenCaptureManagerInit(sc);
    }

    extern fn screenCaptureManagerDeinit(*Interface) void;
    pub fn deinit(mi: *Interface) void {
        screenCaptureManagerDeinit(mi);
    }

    extern fn screenCaptureManagerShowPicker(*Interface, u32, u32, u8, u8) void;
    pub fn showOsPicker(mi: *Interface, config: media.Config, img_kind: VideoStream.ImageKind) void {
        screenCaptureManagerShowPicker(mi, config.width, config.height, config.fps, @backingInt(img_kind));
    }

    extern fn screenCaptureManagerStopCapture(*Interface) void;
    pub fn stopCapture(mi: *Interface) void {
        screenCaptureManagerStopCapture(mi);
    }
};
