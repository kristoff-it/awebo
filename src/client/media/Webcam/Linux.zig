const Interface = @This();

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Core = @import("../../Core.zig");
const ffmpeg = @import("../ffmpeg.zig");
const VideoStream = @import("../VideoStream.zig");
const ScreenCapture = @import("../Screen.zig");
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
capture_thread: ?Io.Future(void) = null,

pub fn init(i: *Interface) void {
    i.* = .{};
}

pub fn deinit(i: *Interface) void {
    const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    const io = core.io;

    if (i.capture_thread) |*as| as.cancel(io);
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
    i.capture_thread = try core.io.concurrent(captureThread, .{ i, device, width, height, fps });
}

pub fn captureThread(i: *Interface, device: ?*WebcamCapture.Device, width: i32, height: i32, fps: i32) void {
    captureThreadFallible(i, device, width, height, fps) catch |err| switch (err) {
        error.Canceled => {
            // This indicates a non-error exit of the capture loop.
            // We don't need to propagate cancelation as this is the end of this
            // coroutine and our exit should not trigger the exit of any other
            // subsystem.
        },
        else => {
            // Something went wrong, we must cancel the webcam streaming session
            log.debug("capture loop exited with an error", .{});
            if (@errorReturnTrace()) |et| std.debug.dumpErrorReturnTrace(et);

            const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
            const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
            core.putEvent(.{ .capture_failed = .camera }) catch {};
        },
    };
}

pub fn captureThreadFallible(i: *Interface, device: ?*WebcamCapture.Device, width: i32, height: i32, fps: i32) !void {
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
    const src = try negotiateFormat(io, device_file);

    log.debug("active format: {}x{} {s}", .{
        src.width,
        src.height,
        @as([4]u8, @bitCast(src.pixfmt)),
    });

    var decoder: *c.AVCodecContext = if (src.pixfmt != c.V4L2_PIX_FMT_MJPEG) undefined else blk: {
        const codec = c.avcodec_find_decoder(c.AV_CODEC_ID_MJPEG) orelse {
            log.debug("unable to find decoder for mjpeg", .{});
            return error.Failed;
        };

        var ctx: *c.AVCodecContext = c.avcodec_alloc_context3(codec) orelse
            return error.OutOfMemory;
        errdefer c.avcodec_free_context(@ptrCast(&ctx));

        ctx.width = @intCast(src.width);
        ctx.height = @intCast(src.height);
        ctx.framerate = .{ .num = @intCast(src.fps), .den = 1 };
        ctx.pix_fmt = c.AV_PIX_FMT_YUV420P;

        ctx.flags = c.AV_CODEC_FLAG_LOW_DELAY;
        ctx.flags2 = c.AV_CODEC_FLAG2_FAST;
        ctx.thread_type = c.FF_THREAD_SLICE;
        ctx.thread_count = 0;

        {
            const ret = c.avcodec_open2(ctx, codec, null);
            if (ret < 0) {
                log.debug(
                    "unable to open decoder: '{s}'",
                    .{ffmpeg.err2str(ret)},
                );
                return error.NoSuitableCodec;
            }
        }

        break :blk ctx;
    };

    defer if (src.pixfmt != c.V4L2_PIX_FMT_MJPEG) {} else {
        c.avcodec_free_context(@ptrCast(&decoder));
    };

    var decoder_packet = if (src.pixfmt != c.V4L2_PIX_FMT_MJPEG) undefined else blk: {
        var packet: *c.AVPacket = c.av_packet_alloc() orelse return error.OutOfMemory;
        packet.buf = null;
        break :blk packet;
    };

    defer if (src.pixfmt != c.V4L2_PIX_FMT_MJPEG) {} else {
        c.av_packet_free(@ptrCast(&decoder_packet));
    };

    var decoder_frame = if (src.pixfmt != c.V4L2_PIX_FMT_MJPEG) undefined else blk: {
        const frame: *c.AVFrame = c.av_frame_alloc() orelse return error.OutOfMemory;
        break :blk frame;
    };

    var encoder: ffmpeg.Encoder = try .init(false, .{
        .width = @intCast(width),
        .height = @intCast(height),
        .fps = @intCast(fps),
    });
    assert(encoder.codec.kind == .h264);

    defer if (src.pixfmt != c.V4L2_PIX_FMT_MJPEG) {} else {
        c.av_frame_free(@ptrCast(&decoder_frame));
    };

    const src_fmt = switch (src.pixfmt) {
        c.V4L2_PIX_FMT_MJPEG => c.AV_PIX_FMT_YUV420P, // output from decoding mjpeg
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
        for (&i.frames) |*f| {
            // A busy frame is still being read by the GUI thread.
            while (f.busy.load(.monotonic)) {
                io.sleep(.fromMilliseconds(5), .awake) catch {};
                log.debug("waiting for frame to be released before exiting...", .{});
            }
        }
        log.debug("all frames released, returning", .{});
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
    defer log.debug("exiting main loop", .{});
    const start = Io.Timestamp.now(io, .awake).toMilliseconds();
    var last_keyframe_ms: i64 = start;
    var last_frame: i64 = start;
    while (true) {
        var buffer_info = std.mem.zeroes(c.v4l2_buffer);
        buffer_info.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
        buffer_info.memory = c.V4L2_MEMORY_MMAP;

        {
            const result = io.operateTimeout(.{
                .device_io_control = .{
                    .file = device_file,
                    .code = c.VIDIOC_DQBUF,
                    .arg = &buffer_info,
                },
            }, .{
                .duration = .{
                    .clock = .awake,
                    .raw = Io.Duration.fromSeconds(3),
                },
            }) catch |err| switch (err) {
                error.ConcurrencyUnavailable => return error.Failed,
                error.Canceled => return error.Canceled,
                error.Timeout => {
                    log.err("camera frame read timed out", .{});
                    return error.Failed;
                },
            };

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
        const now = Io.Timestamp.now(io, .awake).toMilliseconds();
        // log.debug("frame delta {}ms", .{now - last_frame});
        last_frame = now;

        const awebo_frame: *LinuxFrame = frame: while (true) {
            for (&i.frames) |*f| {
                const busy = f.busy.load(.acquire);
                if (busy == false) {
                    f.busy.store(true, .release);
                    break :frame f;
                }
            }

            unreachable; // this function fails to call awebo_frame.release() in some branch
        };

        const b = buffers[buffer_info.index];
        const src_planes: [8]?[*]const u8, const src_strides: [8]c_int = if (src.pixfmt != c.V4L2_PIX_FMT_MJPEG) .{
            .{ b.bytes.ptr, null, null, null, null, null, null, null },
            .{ @intCast(src.stride), 0, 0, 0, 0, 0, 0, 0 },
        } else blk: {
            decoder_packet.data = b.bytes.ptr;
            decoder_packet.size = @intCast(buffer_info.length);
            {
                const ret = c.avcodec_send_packet(decoder, decoder_packet);
                if (ret < 0) {
                    log.err("avcodec_send_packet failed", .{});
                    awebo_frame.release();
                    continue;
                }
            }

            {
                const ret = c.avcodec_receive_frame(decoder, decoder_frame);
                if (ret < 0) {
                    log.err("avcodec_receive_frame failed", .{});
                    awebo_frame.release();
                    continue;
                }
            }

            break :blk .{
                decoder_frame.data,
                decoder_frame.linesize,
            };
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

        const packet, const extradata = (try encoder.encode(
            awebo_frame.getImage(),
            @intCast(now - start),
        )) orelse {
            awebo_frame.release();
            continue;
        };

        ScreenCapture.pushPacket(gpa, &wc.sequence, &wc.packets, .camera, packet, extradata, @intCast(now - last_keyframe_ms));

        if (extradata.len > 0) last_keyframe_ms = now;
    }
}

pub fn stopCapture(i: *Interface) void {
    const wc: *WebcamCapture = @alignCast(@fieldParentPtr("os", i));
    const core: *Core = @alignCast(@fieldParentPtr("webcam_capture", wc));
    const io = core.io;

    i.capture_thread.?.cancel(io);
}

const SrcFormat = struct {
    height: u32,
    width: u32,
    pixfmt: u32,
    stride: u32,
    fps: u32,
};

fn negotiateFormat(io: Io, device_file: Io.File) !SrcFormat {
    var active = std.mem.zeroes(c.v4l2_format);
    active.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;

    // Get the current active config
    {
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_G_FMT,
                .arg = &active,
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

    // If the config doesn't have mjpeg as pixfmt, try to switch to it.
    // If that fails, switch to a non-compressed format as a fallback.
    if (active.fmt.pix.pixelformat != c.V4L2_PIX_FMT_MJPEG) {
        var has_mjpeg = false;
        var first_non_compressed: ?u32 = null;

        // Discover supported formats
        {
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
                        if (fmt_desc.pixelformat == c.V4L2_PIX_FMT_MJPEG) {
                            has_mjpeg = true;
                            continue;
                        }

                        const compressed = (fmt_desc.flags & c.V4L2_FMT_FLAG_COMPRESSED) != 0;
                        if (!compressed) {
                            first_non_compressed = fmt_desc.pixelformat;
                        }
                    },
                    else => break,
                }
            }
        }

        active.fmt.pix.width = 0;
        active.fmt.pix.height = 0;
        if (has_mjpeg) {
            active.fmt.pix.pixelformat = c.V4L2_PIX_FMT_MJPEG;
        } else if (first_non_compressed) |pixfmt| {
            active.fmt.pix.pixelformat = pixfmt;
        } else {
            log.err("unable to find a supported pixel format", .{});
            return error.Failed;
        }

        const change_result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_S_FMT,
                .arg = &active,
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
    }

    // Request 24fps.
    var active_stream = std.mem.zeroes(c.v4l2_streamparm);
    active_stream.type = c.V4L2_BUF_TYPE_VIDEO_CAPTURE;
    {
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_G_PARM,
                .arg = &active_stream,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable to get stream info ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }
    }

    // Set fps if needed

    const num: f32 = @floatFromInt(active_stream.parm.capture.timeperframe.numerator);
    const den: f32 = @floatFromInt(active_stream.parm.capture.timeperframe.denominator);
    if (num / den != 1.0 / 30.0) {
        log.debug("found fps {any}, setting to 1/30", .{active_stream.parm.capture.timeperframe});
        active_stream.parm.capture.timeperframe = .{
            .numerator = 1,
            .denominator = 30,
        };
        const result = try io.operate(.{
            .device_io_control = .{
                .file = device_file,
                .code = c.VIDIOC_S_PARM,
                .arg = &active_stream,
            },
        });

        switch (std.posix.errno(result.device_io_control)) {
            else => |err| {
                log.err("unable to set fps to 1/30 ({t}, {})", .{
                    err,
                    result.device_io_control,
                });
                return error.Failed;
            },
            .SUCCESS => {},
        }

        const num_after: f32 = @floatFromInt(active_stream.parm.capture.timeperframe.numerator);
        const den_after: f32 = @floatFromInt(active_stream.parm.capture.timeperframe.denominator);
        if (num_after / den_after != 1.0 / 30.0) {
            log.err("failed to set fps to 1/30 ({any})", .{
                active_stream.parm.capture.timeperframe,
            });
            return error.Failed;
        }
    }

    return .{
        .width = active.fmt.pix.width,
        .height = active.fmt.pix.height,
        .pixfmt = active.fmt.pix.pixelformat,
        .stride = active.fmt.pix.bytesperline,
        .fps = 30,
    };
}
