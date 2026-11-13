const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const WebcamCapture = @import("../Webcam.zig");
const c = @import("c");
const log = std.log.scoped(.v4l2);

pub const LinuxFrame = undefined;

pub const Interface = opaque {
    pub const Webcam = struct {
        file: Io.File,
    };

    pub fn init() *Interface {
        return undefined;
    }

    pub fn deinit(i: *Interface) void {
        _ = i;
    }

    pub fn discoverDevicesAndListen(i: *Interface, io: Io, wc: *WebcamCapture) !void {
        _ = i;
        const v4l_dir = Io.Dir.cwd().openDir(io, "/dev", .{ .iterate = true }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.debug("unable to open /dev: {t}", .{err});
                return;
            },
        };

        var it = v4l_dir.iterateAssumeFirstIteration();
        outer: while (try it.next(io)) |entry| {
            if (!std.mem.startsWith(u8, entry.name, "video")) continue;

            const device = v4l_dir.openFile(io, entry.name, .{ .mode = .read_write }) catch |err| switch (err) {
                error.Canceled => return error.Canceled,
                else => {
                    log.info("unable to open /dev/v4l/by-id/{s}: {t}", .{ entry.name, err });
                    continue;
                },
            };

            var caps: c.v4l2_capability = undefined;
            while (true) {
                const result = try io.operate(.{
                    .device_io_control = .{
                        .file = device,
                        .code = c.VIDIOC_QUERYCAP,
                        .arg = &caps,
                    },
                });

                switch (std.posix.errno(result.device_io_control)) {
                    .SUCCESS => break,
                    else => continue :outer,
                }
            }

            const is_capture = (caps.capabilities & c.V4L2_CAP_VIDEO_CAPTURE) != 0;

            log.debug("webcam: {s} Driver: {s} Card: {s} Bus: {s} Version: {}.{}.{} is capture: {}", .{
                entry.name,
                caps.driver,
                caps.card,
                caps.bus_info,
                (caps.version >> 16) & 0xff,
                (caps.version >> 8) & 0xff,
                caps.version & 0xff,
                is_capture,
            });

            if (!is_capture) continue;

            var format = std.mem.zeroes(c.v4l2_fmtdesc);
            format.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
            format.index = 0;
            while (true) : (format.index += 1) {
                const result = try io.operate(.{
                    .device_io_control = .{
                        .file = device,
                        .code = c.VIDIOC_ENUM_FMT,
                        .arg = &format,
                    },
                });

                switch (result.device_io_control) {
                    0 => {
                        const compressed = (format.flags & c.V4L2_FMT_FLAG_COMPRESSED) != 0;
                        const emulated = (format.flags & c.V4L2_FMT_FLAG_EMULATED) != 0;
                        log.debug("format idx: {} desc: {s} foucc: {s} compressed: {} emulated: {}", .{
                            format.index,
                            format.description,
                            @as([4]u8, @bitCast(format.pixelformat)),
                            compressed,
                            emulated,
                        });
                        continue;
                    },
                    else => break,
                }
            }

            if (format.index == 0) {
                log.debug("device doesn't suport any format, skipping", .{});
                continue;
            }

            wc.upsertDevice(entry.name, &caps.card, true, .{
                .file = device,
            });
        }
    }

    pub fn startCapture(i: *Interface, id: ?[*:0]const u8, width: i32, height: i32, fps: i32) bool {
        _ = i;
        _ = id;
        _ = width;
        _ = height;
        _ = fps;
        return true;
    }

    pub fn stopCapture(i: *Interface) void {
        _ = i;
    }
};
