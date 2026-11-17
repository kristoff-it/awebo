const Interface = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Core = @import("../../Core.zig");
const VideoStream = @import("../VideoStream.zig");
const WebcamCapture = @import("../Webcam.zig");
const c = @import("c");
const log = std.log.scoped(.v4l2);

pub const Webcam = struct {};
pub const LinuxFrame = struct {
    width: u32,
    height: u32,
    bytes: [*]u8,
    busy: std.atomic.Value(bool) = .init(false),

    pub fn getImage(f: *LinuxFrame) VideoStream.Image {
        return .{
            .nv12 = .{
                .height = f.height,
                .width = f.width,
                .y = f.bytes,
                .y_stride = f.width,
                .cbcr = f.bytes[f.height * f.width ..],
                .cbcr_stride = f.width,
                .color = .bt709f,
            },
        };
    }

    pub fn release(lf: *LinuxFrame) void {
        lf.busy.store(false, .release);
    }
};

frames: [2]LinuxFrame = undefined,
capture_loop: ?Io.Future(void) = null,

pub fn init(i: *Interface) void {
    i.* = .{};
}

pub fn deinit(i: *Interface) void {
    const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    const io = core.io;

    if (i.capture_loop) |*as| as.cancel(io);
}

pub fn discoverDevicesAndListen(i: *Interface) !void {
    const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    const io = core.io;

    const v4l_dir = Io.Dir.cwd().openDir(io, "/dev", .{ .iterate = true }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => {
            log.debug("unable to open /dev: {t}", .{err});
            return;
        },
    };
    defer v4l_dir.close(io);

    var it = v4l_dir.iterateAssumeFirstIteration();
    while (try it.next(io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "video")) continue;

        const file = v4l_dir.openFile(io, entry.name, .{ .mode = .read_write }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                log.info("unable to open /dev/{s}: {t}", .{ entry.name, err });
                continue;
            },
        };
        defer file.close(io);

        var caps = std.mem.zeroes(c.v4l2_capability);
        {
            const result = try io.operate(.{
                .device_io_control = .{
                    .file = file,
                    .code = c.VIDIOC_QUERYCAP,
                    .arg = &caps,
                },
            });

            switch (std.posix.errno(result.device_io_control)) {
                else => continue,
                .SUCCESS => {},
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
        }

        var fmt_desc = std.mem.zeroes(c.v4l2_fmtdesc);
        fmt_desc.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt_desc.index = 0;
        var uncompressed_fmt: ?u32 = null;
        while (true) : (fmt_desc.index += 1) {
            const result = try io.operate(.{
                .device_io_control = .{
                    .file = file,
                    .code = c.VIDIOC_ENUM_FMT,
                    .arg = &fmt_desc,
                },
            });

            switch (result.device_io_control) {
                0 => {
                    const compressed = (fmt_desc.flags & c.V4L2_FMT_FLAG_COMPRESSED) != 0;
                    const emulated = (fmt_desc.flags & c.V4L2_FMT_FLAG_EMULATED) != 0;
                    log.debug("format idx: {} desc: {s} foucc: {s} compressed: {} emulated: {}", .{
                        fmt_desc.index,
                        fmt_desc.description,
                        @as([4]u8, @bitCast(fmt_desc.pixelformat)),
                        compressed,
                        emulated,
                    });

                    if (!compressed) {
                        uncompressed_fmt = fmt_desc.pixelformat;
                    }

                    continue;
                },
                else => break,
            }
        }

        if (fmt_desc.index == 0) {
            log.debug("device doesn't suport any format, skipping", .{});
            continue;
        }

        if (uncompressed_fmt == null) {
            log.debug("device doesn't suport any non-compressed format, skipping", .{});
            continue;
        }

        wc.upsertDevice(entry.name, &caps.card, true, .{});
    }
}

pub fn startCapture(i: *Interface, device: ?*WebcamCapture.Device, width: i32, height: i32, fps: i32) !void {
    const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    i.capture_loop = try core.io.concurrent(captureLoop, .{ i, device, width, height, fps });
}

pub fn captureLoop(i: *Interface, device: ?*WebcamCapture.Device, width: i32, height: i32, fps: i32) void {
    captureLoopFallible(i, device, width, height, fps) catch |err| switch (err) {
        error.Canceled => {
            // This indicates a non-error exit of the capture loop.
            // We don't need to propagate cancelation as this is the end of this
            // coroutine and our exit should not trigger the exit of any other
            // subsystem.
        },
        else => {
            // Something went wrong, we must cancel the webcam streaming session
            // TODO: core.disableWebcamSession();
            log.debug("capture loop exited with an error", .{});
            if (@errorReturnTrace()) |et| {
                std.debug.dumpErrorReturnTrace(et);
            }
        },
    };
}

pub fn captureLoopFallible(i: *Interface, device: ?*WebcamCapture.Device, width: i32, height: i32, fps: i32) !void {
    _ = fps;

    const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    const io = core.io;
    const gpa = core.gpa;

    const dev_dir = Io.Dir.cwd().openDir(io, "/dev", .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            log.err("unable to open /dev: {t}", .{e});
            return e;
        },
    };
    defer dev_dir.close(io);

    const device_name = if (device) |d| d.id else "video0";
    const device_file = dev_dir.openFile(io, device_name, .{ .mode = .read_write }) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            log.err("unable to open /dev/{s}: {t}", .{ device_name, e });
            return e;
        },
    };
    defer device_file.close(io);

    // Source format

    const src: struct {
        height: u32,
        width: u32,
        fourcc: u32,
        stride: u32,
    } = blk: {
        var fmt = std.mem.zeroes(c.v4l2_format);
        fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;

        {
            const result = try io.operate(.{
                .device_io_control = .{
                    .file = device_file,
                    .code = c.VIDIOC_G_FMT,
                    .arg = &fmt,
                },
            });

            switch (std.posix.errno(result.device_io_control)) {
                else => |err| {
                    log.err("unable to query pixel format ({t}, {})", .{
                        err,
                        result.device_io_control,
                    });
                    return error.Failed;
                },
                .SUCCESS => {},
            }
        }

        var fmt_desc = std.mem.zeroes(c.v4l2_fmtdesc);
        fmt_desc.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        fmt_desc.index = 0;
        while (true) : (fmt_desc.index += 1) {
            const result = try io.operate(.{
                .device_io_control = .{
                    .file = device_file,
                    .code = c.VIDIOC_ENUM_FMT,
                    .arg = &fmt_desc,
                },
            });

            switch (result.device_io_control) {
                0 => {
                    const compressed = (fmt_desc.flags & c.V4L2_FMT_FLAG_COMPRESSED) != 0;
                    if (compressed) continue;

                    log.debug("selected uncompressed format #{} {s} [{s}]", .{
                        fmt_desc.index,
                        fmt_desc.description,
                        @as([4]u8, @bitCast(fmt_desc.pixelformat)),
                    });

                    if (fmt_desc.pixelformat == fmt.fmt.pix.pixelformat) break;

                    fmt.fmt.pix.pixelformat = fmt_desc.pixelformat;
                    fmt.fmt.pix.width = 1920;
                    fmt.fmt.pix.height = 1080;
                    const change_result = try io.operate(.{
                        .device_io_control = .{
                            .file = device_file,
                            .code = c.VIDIOC_S_FMT,
                            .arg = &fmt,
                        },
                    });

                    switch (std.posix.errno(change_result.device_io_control)) {
                        else => |err| {
                            log.err("unable to change pixel format ({t}, {})", .{
                                err,
                                change_result.device_io_control,
                            });
                            return error.Failed;
                        },
                        .SUCCESS => {},
                    }
                },
                else => {
                    log.err("unable to select uncompressed format, aborting", .{});
                    return error.Failed;
                },
            }
        }

        break :blk .{
            .width = fmt.fmt.pix.width,
            .height = fmt.fmt.pix.height,
            .fourcc = fmt.fmt.pix.pixelformat,
            .stride = fmt.fmt.pix.bytesperline,
        };
    };

    log.debug("active format: {}x{} {s}", .{
        src.width,
        src.height,
        @as([4]u8, @bitCast(src.fourcc)),
    });

    const src_fmt = switch (src.fourcc) {
        c.V4L2_PIX_FMT_YUYV => c.AV_PIX_FMT_YUYV422,
        else => std.debug.panic("missing support for this pixel format", .{}),
    };

    const sws_context = c.sws_getContext(
        //src
        @intCast(src.width),
        @intCast(src.height),
        src_fmt,

        //dest
        @intCast(width),
        @intCast(height),
        c.AV_PIX_FMT_NV12,
        c.SWS_FAST_BILINEAR,

        //filters
        null,
        null,
        null,
    ) orelse {
        std.debug.panic("ffmpeg sws context creation failed", .{});
    };
    defer c.sws_freeContext(sws_context);

    const c_width: usize = @intCast(width);
    const c_height: usize = @intCast(height);
    const nv12_bufs = try gpa.alloc(u8, 2 * ((c_height * c_width) + (c_width * c_height / 2)));
    defer gpa.free(nv12_bufs);

    i.frames = .{
        .{
            .width = @intCast(width),
            .height = @intCast(height),
            .bytes = nv12_bufs.ptr,
        },
        .{
            .width = @intCast(width),
            .height = @intCast(height),
            .bytes = nv12_bufs.ptr + @divExact(nv12_bufs.len, 2),
        },
    };

    defer {
        if (wc.framePull()) |f| f.release();
    }

    var reqbuf = std.mem.zeroes(c.v4l2_requestbuffers);
    reqbuf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    reqbuf.memory = c.V4L2_MEMORY_MMAP;
    reqbuf.count = 5;

    {
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_REQBUFS,
                .arg = &reqbuf,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable to setup v4l2 memory buffers ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }
    }

    log.debug("got {} buffers", .{reqbuf.count});

    if (reqbuf.count < 2 or reqbuf.count > 5) {
        // It's not clear to me what exactly I should expect to get from
        // v4l2 in this case. Am I setting the maximum number of buffers?
        // Why do we need more than 2?
        log.err("unexpected number of buffers: {}", .{reqbuf.count});
        return error.Failed;
    }

    var max_buffers: [5]struct {
        // info.length contains the number of valid planes.
        info: c.v4l2_buffer = std.mem.zeroes(c.v4l2_buffer),
        planes_buf: [3]c.v4l2_plane = @splat(std.mem.zeroes(c.v4l2_plane)),
        bytes: []u8 = undefined,
    } = @splat(.{});
    const buffers = max_buffers[0..reqbuf.count];

    // init_index is used to both index buffers for the ioctl call, and
    // also to track partial initialization for the subsequent
    // errdefer.
    var init_index: usize = 0;
    defer for (buffers[0..init_index]) |b| {
        std.posix.munmap(@alignCast(b.bytes));
    };

    for (buffers) |*b| {
        b.info = std.mem.zeroes(c.v4l2_buffer);
        b.info.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        b.info.memory = c.V4L2_MEMORY_MMAP;
        b.info.index = @intCast(init_index);

        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_QUERYBUF,
                .arg = &b.info,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable query buffer info ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }

        log.debug("mmapping #{} {any}", .{ init_index, b.info });

        b.bytes = try std.posix.mmap(
            null,
            b.info.length,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            device_file.handle,
            b.info.m.offset,
        );
        init_index += 1;
    }

    log.debug("mmap complete", .{});

    for (buffers) |*b| {
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_QBUF,
                .arg = &b.info,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable enqueue buffer ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }
    }

    var buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    {
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_STREAMON,
                .arg = &buf_type,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable to start streaming ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }
    }

    log.debug("capture stream on!", .{});

    defer {
        const try_result = io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_STREAMOFF,
                .arg = &buf_type,
            },
        });

        if (try_result) |result| {
            switch (std.posix.errno(result.device_io_control)) {
                else => |err| {
                    log.warn("error while stopping streaming ({t}, {})", .{
                        err,
                        result.device_io_control,
                    });
                },
                .SUCCESS => {},
            }
        } else |err| log.warn(
            "error while stopping streaming ({t})",
            .{err},
        );
    }

    // main capture loop
    while (true) {
        var planes_buf: [3]c.v4l2_plane = @splat(std.mem.zeroes(c.v4l2_plane));
        var buffer_info = std.mem.zeroes(c.v4l2_buffer);
        buffer_info.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer_info.memory = c.V4L2_MEMORY_MMAP;
        buffer_info.m.planes = &planes_buf;

        {
            const result = try io.operate(.{
                .device_io_control = .{
                    .file = device_file,
                    .code = c.VIDIOC_DQBUF,
                    .arg = &buffer_info,
                },
            });

            switch (std.posix.errno(result.device_io_control)) {
                else => |err| {
                    log.err("unable to dequeue buffer ({t}, {})", .{
                        err,
                        result.device_io_control,
                    });
                    return error.Failed;
                },
                .SUCCESS => {},
            }
        }

        const awebo_frame: *LinuxFrame = frame: while (true) {
            for (&i.frames) |*f| {
                if (!f.busy.load(.monotonic)) {
                    f.busy.store(true, .monotonic);
                    break :frame f;
                }
            }

            // The GUI might not be rendering for performance optimization reasons
            // (e.g. it's not visible), so we might need to yank that frame back.
            if (wc.framePull()) |f| break :frame f;

            log.warn("both frames were busy and neither could be retreived!", .{});
        };

        const b = buffers[buffer_info.index];
        const src_planes: [4:null]?[*]const u8 = .{ b.bytes.ptr, null, null, null };
        const src_strides: [4:0]c_int = .{ @intCast(src.stride), 0, 0, 0 };
        const nv12_planes: [4:null]?[*]u8 = .{
            awebo_frame.bytes[0..],
            awebo_frame.bytes[c_height * c_width ..],
            null,
            null,
        };

        const nv12_strides: [4]c_int = .{ @intCast(width), @intCast(width), 0, 0 };

        _ = c.sws_scale(
            sws_context,
            &src_planes,
            &src_strides,
            0,
            @intCast(src.height),
            &nv12_planes,
            &nv12_strides,
        );

        // Release v4l2 frame
        {
            const result = try io.operate(.{
                .device_io_control = .{
                    .file = device_file,
                    .code = c.VIDIOC_QBUF,
                    .arg = &buffer_info,
                },
            });

            switch (std.posix.errno(result.device_io_control)) {
                else => |err| {
                    log.err("unable to re-queue buffer ({t}, {})", .{
                        err,
                        result.device_io_control,
                    });
                    return error.Failed;
                },
                .SUCCESS => {},
            }
        }

        wc.framePush(awebo_frame);
    }
}

pub fn captureLoopFallibleMplane(i: *Interface, device: ?*WebcamCapture.Device, width: i32, height: i32, fps: i32) !void {
    _ = fps;

    const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    const io = core.io;
    const gpa = core.gpa;

    const dev_dir = Io.Dir.cwd().openDir(io, "/dev", .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            log.err("unable to open /dev: {t}", .{e});
            return e;
        },
    };
    defer dev_dir.close(io);

    const device_name = if (device) |d| d.id else "video0";
    const device_file = dev_dir.openFile(io, device_name, .{}) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        else => |e| {
            log.err("unable to open /dev/{s}: {t}", .{ device_name, e });
            return e;
        },
    };
    defer device_file.close(io);

    // Source format

    const src: struct {
        height: u32,
        width: u32,
        fourcc: u32,
        colorspace: u32,
        num_planes: u8,
        strides: [3]u32,
    } = blk: {
        var fmt = std.mem.zeroes(c.v4l2_format);
        fmt.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;

        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_G_FMT,
                .arg = &fmt,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable to query pixel format ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }

        break :blk .{
            .width = fmt.fmt.pix_mp.width,
            .height = fmt.fmt.pix_mp.height,
            .fourcc = fmt.fmt.pix_mp.pixelformat,
            .colorspace = fmt.fmt.pix_mp.colorspace,
            .num_planes = fmt.fmt.pix_mp.num_planes,
            .strides = .{
                fmt.fmt.pix_mp.plane_fmt[0].bytesperline,
                fmt.fmt.pix_mp.plane_fmt[1].bytesperline,
                fmt.fmt.pix_mp.plane_fmt[2].bytesperline,
            },
        };
    };

    log.debug("active format: {}x{} {s} ({} planes)", .{
        src.width,
        src.height,
        @as([4]u8, @bitCast(src.fourcc)),
        src.num_planes,
    });

    const sws_context = c.sws_getContext(
        //src
        @intCast(src.width),
        @intCast(src.height),
        @intCast(src.fourcc),

        //dest
        @intCast(width),
        @intCast(height),
        c.AV_PIX_FMT_NV12,
        c.SWS_FAST_BILINEAR,

        //filters
        null,
        null,
        null,
    ) orelse {
        std.debug.panic("ffmpeg sws context creation failed", .{});
    };

    const c_width: usize = @intCast(width);
    const c_height: usize = @intCast(height);
    const nv12_bufs = try gpa.alloc(u8, 2 * ((c_height * c_width) + (c_width * c_height / 2)));
    defer gpa.free(nv12_bufs);

    i.frames = .{
        .{
            .width = @intCast(width),
            .height = @intCast(height),
            .bytes = nv12_bufs.ptr,
        },
        .{
            .width = @intCast(width),
            .height = @intCast(height),
            .bytes = nv12_bufs.ptr + @divExact(nv12_bufs.len, 2),
        },
    };

    var reqbuf = std.mem.zeroes(c.v4l2_requestbuffers);
    reqbuf.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    reqbuf.memory = c.V4L2_MEMORY_MMAP;
    reqbuf.count = 5;

    {
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_REQBUFS,
                .arg = &reqbuf,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable to setup v4l2 memory buffers ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }
    }

    if (reqbuf.count < 2 or reqbuf.count > 5) {
        // It's not clear to me what exactly I should expect to get from
        // v4l2 in this case. Am I setting the maximum number of buffers?
        // Why do we need more than 2?
        log.err("unexpected number of buffers: {}", .{reqbuf.count});
        return error.Failed;
    }

    var max_buffers: [5]struct {
        // info.length contains the number of valid planes.
        info: c.v4l2_buffer = std.mem.zeroes(c.v4l2_buffer),
        planes_buf: [3]c.v4l2_plane = @splat(std.mem.zeroes(c.v4l2_plane)),
        planes_bytes: [3][]u8 = undefined,
    } = @splat(.{});
    const buffers = max_buffers[0..reqbuf.count];

    // init_index is used to both index buffers for the ioctl call, and
    // also to track partial initialization for the subsequent
    // errdefer.
    var init_index: usize = 0;
    errdefer for (buffers[0..init_index]) |b| {
        for (b.planes_bytes) |p| std.posix.munmap(@alignCast(p));
    };

    for (buffers) |*b| {
        b.info.type = reqbuf.type;
        b.info.memory = c.V4L2_MEMORY_MMAP;
        b.info.index = @intCast(init_index);
        b.info.length = b.planes_buf.len;
        b.info.m.planes = &b.planes_buf;

        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_QUERYBUF,
                .arg = &b.info,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable query buffer info ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }

        for (b.planes_buf[0..b.info.length], b.planes_bytes[0..b.info.length]) |plane_info, *plane_bytes| {
            plane_bytes.* = try std.posix.mmap(
                null,
                plane_info.length,
                .{ .READ = true, .WRITE = true },
                .{ .TYPE = .SHARED },
                device_file.handle,
                plane_info.m.mem_offset,
            );
        }
        init_index += 1;
    }

    for (buffers) |*b| {
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_QBUF,
                .arg = &b.info,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable enqueue buffer ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }
    }

    var buf_type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    {
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_STREAMON,
                .arg = &buf_type,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable to start streaming ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }
    }

    defer {
        const try_result = io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_STREAMOFF,
                .arg = &buf_type,
            },
        });

        if (try_result) |result| {
            switch (std.posix.errno(result.device_io_control)) {
                else => |err| {
                    log.warn("error while stopping streaming ({t}, {})", .{
                        err,
                        result.device_io_control,
                    });
                },
                .SUCCESS => {},
            }
        } else |err| log.warn(
            "error while stopping streaming ({t})",
            .{err},
        );
    }

    // main capture loop
    while (true) {
        var planes_buf: [3]c.v4l2_plane = @splat(std.mem.zeroes(c.v4l2_plane));
        var buffer_info = std.mem.zeroes(c.v4l2_buffer);
        buffer_info.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer_info.memory = c.V4L2_MEMORY_MMAP;
        buffer_info.m.planes = &planes_buf;

        {
            const result = try io.operate(.{
                .device_io_control = .{
                    .file = device_file,
                    .code = c.VIDIOC_DQBUF,
                    .arg = &buffer_info,
                },
            });

            switch (std.posix.errno(result.device_io_control)) {
                else => |err| {
                    log.err("unable to dequeue buffer ({t}, {})", .{
                        err,
                        result.device_io_control,
                    });
                    return error.Failed;
                },
                .SUCCESS => {},
            }
        }

        log.debug("got camera frame", .{});

        const awebo_frame: *LinuxFrame = frame: while (true) {
            for (&i.frames) |*f| {
                if (!f.busy.load(.monotonic)) {
                    f.busy.store(true, .monotonic);
                    break :frame f;
                }
            }

            // The GUI might not be rendering for performance optimization reasons
            // (e.g. it's not visible), so we might need to yank that frame back.
            if (wc.framePull()) |f| break :frame f;

            log.warn("both frames were busy and neither could be retreived!", .{});
        };

        const b = buffers[buffer_info.index];
        const src_planes: [4:null]?[*]const u8 = .{
            b.planes_bytes[0].ptr,
            b.planes_bytes[1].ptr,
            b.planes_bytes[2].ptr,
            null,
        };
        const src_strides: [4:0]c_int = .{
            @intCast(src.strides[0]),
            @intCast(src.strides[1]),
            @intCast(src.strides[2]),
            0,
        };
        const nv12_planes: [4:null]?[*]u8 = .{
            awebo_frame.bytes[0..],
            awebo_frame.bytes[c_height * c_width ..],
            null,
            null,
        };

        const nv12_strides: [4]c_int = .{ @intCast(width), @intCast(width), 0, 0 };

        _ = c.sws_scale(
            sws_context,
            &src_planes,
            &src_strides,
            0,
            @intCast(src.height),
            &nv12_planes,
            &nv12_strides,
        );

        // Release v4l2 frame
        {
            const result = try io.operate(.{
                .device_io_control = .{
                    .file = device_file,
                    .code = c.VIDIOC_QBUF,
                    .arg = &buffer_info,
                },
            });

            switch (std.posix.errno(result.device_io_control)) {
                else => |err| {
                    log.err("unable to re-queue buffer ({t}, {})", .{
                        err,
                        result.device_io_control,
                    });
                    return error.Failed;
                },
                .SUCCESS => {},
            }
        }

        wc.framePush(awebo_frame);
    }
}

pub fn stopCapture(i: *Interface) void {
    const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    const io = core.io;

    i.capture_loop.?.cancel(io);
}
