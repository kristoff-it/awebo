const builtin = @import("builtin");
const std = @import("std");
const Core = @import("../Core.zig");

pub const ScreenShare = switch (builtin.target.os.tag) {
    else => struct {
        pub fn init() *ScreenShare {
            @panic("TODO");
        }

        pub fn deinit(s: *ScreenShare) void {
            _ = s;
        }

        /// Shows the screenshare picker
        pub fn showPicker(s: *ScreenShare) void {
            _ = s;
        }
    },

    // see media/screen-share-macos.m
    .macos => opaque {
        extern fn screenCaptureManagerInit() *ScreenShare;
        pub fn init() *ScreenShare {
            return screenCaptureManagerInit();
        }

        extern fn screenCaptureManagerDeinit(*ScreenShare) void;
        pub fn deinit(s: *ScreenShare) void {
            screenCaptureManagerDeinit(s);
        }

        extern fn screenCaptureManagerShowPicker(*ScreenShare) void;
        /// Shows the screenshare picker
        pub fn showPicker(s: *ScreenShare) void {
            screenCaptureManagerShowPicker(s);
        }
    },
};

pub const Pixels = extern struct {
    width: usize,
    height: usize,
    pixels: ?[*]u8,
};

pub const Frame = switch (builtin.target.os.tag) {
    else => struct {
        pub fn deinit(f: *Frame) void {
            _ = f;
        }

        pub fn getPixels(f: *Frame) Pixels {
            _ = f;
            return .{ .height = 0, .width = 0, .pixels = null };
        }
    },
    // see media/screen-share-macos.m
    .macos => opaque {
        extern fn frameDeinit(*Frame) void;
        pub fn deinit(f: *Frame) void {
            frameDeinit(f);
        }

        extern fn frameGetPixels(*Frame) Pixels;
        pub fn getPixels(f: *Frame) Pixels {
            return frameGetPixels(f);
        }
    },
};

// pub const Content = opaque {
//     pub fn fromPtr(c: ?*anyopaque) Content {
//         return @ptrCast(c.?);
//     }

//     extern fn contentDeinit(content: ?*anyopaque) void;
//     pub fn deinit(c: *Content) void {
//         contentDeinit(@ptrCast(c));
//     }

//     extern fn contentDisplayArray(*Content) *anyopaque;
//     pub fn displayIterator(c: *Content) DisplayIterator {
//         return .{ .nsarray = contentDisplayArray(c) };
//     }

//     pub const DisplayIterator = struct {
//         nsarray: *anyopaque,
//         index: usize = 0,

//         extern fn displayAt(?*anyopaque, usize) ?*Display;
//         pub fn next(di: *DisplayIterator) ?*Display {
//             defer di.index += 1;
//             return displayAt(di.nsarray, di.index);
//         }
//     };

//     pub const Display = opaque {
//         extern fn displayGetId(*Display) u32;
//         pub fn getId(d: *Display) u32 {
//             return displayGetId(d);
//         }

//         extern fn displayThumbnailCapture(*Display, *Core) void;
//         pub fn captureThumbnail(d: *Display, core: *Core) void {
//             displayThumbnailCapture(d, core);
//         }
//     };

//     pub const Image = opaque {
//         extern fn imageDeinit(*Image) void;
//         pub fn deinit(i: *Image) void {
//             imageDeinit(i);
//         }

//         pub const Pixels = extern struct {
//             width: usize,
//             height: usize,
//             pixels: ?[*]u8,
//         };

//         extern fn imageGetPixels(*Image) Pixels;
//         pub fn getPixels(i: *Image) Pixels {
//             return imageGetPixels(i);
//         }
//     };
// };

// export fn thumbnailReady(img: *Content.Image, id: u32, core: *Core) void {
//     core.putEvent(.{
//         .screen_share = .{
//             .thumbnail = .{
//                 .id = id,
//                 .kind = .display,
//                 .image = img,
//             },
//         },
//     }) catch {
//         // todo free ref
//         std.log.debug("error in thumbnailReady", .{});
//     };
// }
