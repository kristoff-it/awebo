const Interface = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const wayland = @import("wayland");
const wl = wayland.client.wl;
const wl_ext = wayland.client.ext;
const Allocator = std.mem.Allocator;
const awebo = @import("../../awebo.zig");
const media = awebo.protocol.media;
const ScreenCapture = @import("ScreenCapture.zig");
const framePush = ScreenCapture.framePush;
const streamWasInterrupted = ScreenCapture.streamWasInterrupted;
const VideoStream = @import("VideoStream.zig");
const log = std.log.scoped(.wayland_screen_capture);

const c = @import("c");

pub const supports_os_picker = false;

/// This mutex protects this entire struct. All reading or writing
/// must be done while holding the lock. Upon registering with Wayland,
/// a separate thread will receive events that will modify 'outputs' and
/// related fields.
mutex: Io.Mutex = .init,

io: Io,
gpa: Allocator,
arena: std.heap.ArenaAllocator,
event_loop: Io.Future(error{Canceled}!void) = undefined,
capture_session_loop: Io.Future(CaptureSessionError!void) = undefined,

// Singleton interfaces.
display: *wl.Display,
wl_shm: ?*wl.Shm = null,
ext_image_copy_capture_manager: ?*wl_ext.ImageCopyCaptureManagerV1 = null,
ext_output_image_capture_source_manager: ?*wl_ext.OutputImageCaptureSourceManagerV1 = null,

/// Each `wl_output` is bound from the registry and stored here.
outputs: std.array_hash_map.Auto(*wl.Output, struct {
    /// arena-allocated string
    name: ?[]const u8,
    /// arena-allocated string
    description: ?[]const u8,
}) = .empty,

/// Incremented when we bind an output and add it to `outputs`; decremented once we finish
/// learning properties of that output. So once this drops to 0, we have learnt about all
/// outputs.
pending_outputs: u32 = 0,

shm_formats: std.ArrayList(wl.Shm.Format) = .empty,
shm_formats_done: Io.Event = .unset,

buf_width: u32 = 0,
buf_height: u32 = 0,

frame_ready: Io.Event = .unset,
frames: [2]WaylandFrame = undefined,

pub const WaylandFrame = struct {
    height: u32,
    width: u32,
    wl_buffer_bytes: [*]u8,
    wl_buffer: *wl.Buffer,
    busy: std.atomic.Value(bool) = .init(false),
    nv12_buffer_bytes: [*]u8,

    pub fn deinit(f: *WaylandFrame) void {
        f.busy.store(false, .monotonic);
    }

    pub fn getImage(f: *WaylandFrame) VideoStream.Image {
        return .{
            .nv12 = .{
                .height = f.height,
                .width = f.width,
                .y = f.nv12_buffer_bytes,
                .y_stride = f.width,
                .cbcr = f.nv12_buffer_bytes[f.height * f.width ..],
                .cbcr_stride = f.width,
                .color = .bt709f,
            },
        };
    }
};

pub fn init(i: *Interface, io: Io, gpa: Allocator, _: *ScreenCapture) void {
    i.* = .{
        .io = io,
        .gpa = gpa,
        .arena = .init(gpa),
        .display = wl.Display.connect(null) catch @panic("could not connect to wayland display"),
    };
    i.event_loop = io.concurrent(eventLoop, .{i}) catch @panic("oom");
}

pub fn deinit(i: *Interface) void {
    i.event_loop.cancel(i.io) catch {};
    i.display.disconnect();
    i.outputs.deinit(i.gpa);
    i.shm_formats.deinit(i.gpa);
    i.arena.deinit();
}

fn eventLoop(i: *Interface) error{Canceled}!void {
    const registry = i.display.getRegistry() catch @panic("unable to get wayland registry");
    registry.setListener(*Interface, registryListener, i);

    if (i.display.roundtrip() != .SUCCESS) @panic("roundtrip");
    // TODO: state transition to let core know we can now start capture

    // We've learnt about all global objects, but an annoying thing in Wayland is that if an object
    // has "properties" it wants to tell you about, it will do that by sending events, which you
    // need to wait for. So we need to wait until we've learnt about our outputs. We just want their
    // names and descriptions to show the user.
    while (i.pending_outputs > 0) {
        if (i.display.dispatch() != .SUCCESS) @panic("dispatch");
    }

    for (i.outputs.values(), 0..) |info, idx| {
        log.debug("wl_output [{d}] {s} ({s})", .{
            idx,
            info.name orelse "(no name)",
            info.description orelse info.name orelse "(no desc)",
        });
    }

    while (true) {
        log.debug("dispatch!", .{});
        if (i.display.dispatch() != .SUCCESS) {
            log.debug("wayland event loop dispatch failed, exiting", .{});
            try i.io.checkCancel();
            return;
        }
    }
}

pub fn startCapture(i: *Interface, config: media.Config, display_idx: usize) void {
    i.capture_session_loop = i.io.concurrent(captureSessionLoop, .{ i, config, display_idx }) catch @panic("oom");
}

pub const CaptureSessionError = error{
    NameTooLong,
    OutOfMemory,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    SystemOutdated,
    Unexpected,
    AccessDenied,
    PermissionDenied,
    LockedMemoryLimitExceeded,
    MemoryMappingNotSupported,
    MappingAlreadyExists,
    Canceled,
};

pub fn captureSessionLoop(i: *Interface, config: media.Config, display_idx: usize) CaptureSessionError!void {
    log.debug("started capture session", .{});
    const wl_shm = i.wl_shm orelse {
        @panic("wl_shm unavailable");
    };

    const ext_image_copy_capture_manager = i.ext_image_copy_capture_manager orelse {
        @panic("ext_image_copy_capture_manager unavailable");
    };

    const ext_output_image_capture_source_manager = i.ext_output_image_capture_source_manager orelse {
        @panic("ext_output_image_capture_source_manager unavailable");
    };

    const output = if (display_idx < i.outputs.count())
        i.outputs.keys()[0]
    else
        @panic("display idx > i.outputs.count");

    // This "opaque image capture source" is a thing that produces frames (in this case from the given output):
    const capture_source = ext_output_image_capture_source_manager.createSource(output) catch @panic("wayland");
    defer capture_source.destroy();

    // This "image copy capture session" consumes those opaque frames and allows us to write them into a "buffer":
    const capture_session = ext_image_copy_capture_manager.createSession(capture_source, .{ .paint_cursors = true }) catch @panic("wayland");
    defer capture_session.destroy();

    // Before we can make the buffer, we need to learn a) how big the buffer should be, and b) what
    // pixel format it needs. The copy capture session sends us events to signal this.
    capture_session.setListener(*Interface, copyCaptureSessionListener, i);

    log.debug("waiting for shm_formats_done...", .{});
    if (i.display.flush() != .SUCCESS) @panic("flush failed");
    try i.shm_formats_done.wait(i.io);

    for (i.shm_formats.items) |shm_format| {
        log.debug("supported pix_fmt {t}", .{shm_format});
    }

    // We've been given a list of allowed shared memory formats. I'm pretty sure everything should
    // support either `.argb8888` or `.xrgb8888`. Note that those are written from least-significant
    // bit to most-significant bit of a little-endian u32, so in terms of *byte* order, they're
    // actually BGRA and BGRx respectively.
    const shm_format: wl.Shm.Format = for (i.shm_formats.items) |shm_format| {
        switch (shm_format) {
            .xrgb8888,
            .argb8888,
            .xbgr8888,
            => break shm_format,
            else => {},
        }
    } else @panic("pixel format not supported");

    // Either way, this is the number of bytes we need:
    const buf_size = i.buf_width * i.buf_height * 4 * 2;

    // We need to create a shared memory fd (memfd) to hold the data:
    const fd = try std.posix.memfd_create("mluggs-epic-fd", 0);
    if (std.posix.errno(std.posix.system.ftruncate(fd, buf_size)) != .SUCCESS) {
        @panic("failed to set memfd size");
    }

    // We want to mmap it, so that we can read the data:
    const buf_mapped = try std.posix.mmap(
        null,
        buf_size,
        .{ .READ = true, .WRITE = true },
        .{ .TYPE = .SHARED },
        fd,
        0,
    );
    defer std.posix.munmap(buf_mapped);

    // Now we can actually make the corresponding Wayland objects. We make a "shared memory pool"
    // from the memfd, and then a "buffer" from that.
    const shm_pool = try wl_shm.createPool(fd, @intCast(buf_size));
    defer shm_pool.destroy();
    const shm_buf1 = try shm_pool.createBuffer(
        0,
        @intCast(i.buf_width),
        @intCast(i.buf_height),
        @intCast(i.buf_width * 4), // stride
        shm_format,
    );
    defer shm_buf1.destroy();

    const shm_buf2 = try shm_pool.createBuffer(
        @intCast(@divExact(buf_size, 2)),
        @intCast(i.buf_width),
        @intCast(i.buf_height),
        @intCast(i.buf_width * 4), // stride
        shm_format,
    );
    defer shm_buf2.destroy();

    const src_pix_fmt = switch (shm_format) {
        .xrgb8888 => c.AV_PIX_FMT_RGB0,
        .argb8888 => c.AV_PIX_FMT_BGRA,
        .xbgr8888 => c.AV_PIX_FMT_BGR0,
        else => unreachable,
    };

    const sws_context = c.sws_getContext(
        //src
        @intCast(i.buf_width),
        @intCast(i.buf_height),
        src_pix_fmt,

        //dest
        @intCast(config.width),
        @intCast(config.height),
        c.AV_PIX_FMT_NV12,
        c.SWS_FAST_BILINEAR,

        //filters
        null,
        null,
        null,
    ) orelse {
        std.debug.panic("ffmpeg sws context creation failed", .{});
    };

    const c_height: u32 = config.height;
    const c_width: u32 = config.width;
    const nv12_bufs = try i.gpa.alloc(u8, 2 * ((c_height * c_width) + (c_width * c_height / 2)));
    defer i.gpa.free(nv12_bufs);

    i.frames = .{
        .{
            .height = config.height,
            .width = config.width,
            .wl_buffer_bytes = buf_mapped.ptr,
            .wl_buffer = shm_buf1,
            .nv12_buffer_bytes = nv12_bufs[0..].ptr,
        },
        .{
            .height = config.height,
            .width = config.width,
            .wl_buffer_bytes = buf_mapped[@divExact(buf_size, 2)..].ptr,
            .wl_buffer = shm_buf2,
            .nv12_buffer_bytes = nv12_bufs[@divExact(nv12_bufs.len, 2)..].ptr,
        },
    };

    // Now we're ready to start actually capturing frames! We'll use sleeps to limit the FPS. This
    // definitely isn't a great way of doing it, but for screen sharing it's... probably fine.
    const start_time: std.Io.Timestamp = .now(i.io, .awake);
    const frames_per_second = config.fps;

    var frame_index: usize = 1;
    while (true) : (frame_index += 1) {
        const delta_from_start_ms: u64 = frame_index * std.time.ms_per_s / frames_per_second;
        const capture_at = start_time.addDuration(.fromMilliseconds(@intCast(delta_from_start_ms)));
        try std.Io.Timeout.sleep(.{ .deadline = capture_at.withClock(.awake) }, i.io);

        log.debug("capture frame @ {d}!", .{delta_from_start_ms});
        const awebo_frame = if (!i.frames[0].busy.load(.monotonic)) &i.frames[0] else &i.frames[1];
        if (builtin.mode == .debug) assert(awebo_frame.busy.load(.monotonic) == false);

        const frame = try capture_session.createFrame();
        defer frame.destroy();
        frame.attachBuffer(awebo_frame.wl_buffer);
        frame.damageBuffer(0, 0, @intCast(i.buf_width), @intCast(i.buf_height));
        frame.setListener(*Interface, copyCaptureFrameListener, i);

        // This flag will be set by `copyCaptureFrameListener` once we're able to read the frame
        // from our buffer. Reset it to `false` now so we can poll it in a moment.
        i.frame_ready.reset();
        frame.capture();

        // Wait for the flag before attempting again to capture a new frame.
        // The main work will be done directly by the capture frame listener,
        // this wait is performed exclusively to avoid errors then the system
        // lags and capturing a frame takes too long. Without waiting, we might
        // end up asking for a new capture before the last one is done, which
        // might cause errors (not sure if that would result in a wayland protocol
        // error or some other kind of malfunction).
        if (i.display.flush() != .SUCCESS) @panic("flush failed");
        try i.frame_ready.wait(i.io);

        const rgb_planes: [4:null]?[*]const u8 = .{ awebo_frame.wl_buffer_bytes, null, null, null };
        const rgb_strides: [4]c_int = .{ @intCast(i.buf_width * 4), 0, 0, 0 };
        const nv12_planes: [4:null]?[*]u8 = .{
            awebo_frame.nv12_buffer_bytes[0..],
            awebo_frame.nv12_buffer_bytes[c_height * c_width ..],
            null,
            null,
        };
        const nv12_strides: [4]c_int = .{ @intCast(config.width), @intCast(config.width), 0, 0 };

        _ = c.sws_scale(
            sws_context,
            &rgb_planes,
            &rgb_strides,
            0,
            @intCast(i.buf_height),
            &nv12_planes,
            &nv12_strides,
        );

        const sc: *ScreenCapture = @fieldParentPtr("os", i);

        awebo_frame.busy.store(true, .monotonic);
        sc.framePush(awebo_frame, delta_from_start_ms);
    }
}

/// Unsupported by this implementation.
pub fn showOsPicker(i: *Interface, config: media.Config, img_kind: VideoStream.ImageKind) void {
    _ = .{ i, config, img_kind };
    @compileError("unsupported by this implementation");
}

pub fn stopCapture(i: *Interface) void {
    log.debug("stop capture requested", .{});
    i.capture_session_loop.cancel(i.io) catch {};
    log.debug("capture canceled", .{});
}

fn registryListener(registry: *wl.Registry, event: wl.Registry.Event, i: *Interface) void {
    i.mutex.lock(i.io) catch |err| switch (err) {
        error.Canceled => return,
    };
    defer i.mutex.unlock(i.io);

    switch (event) {
        .global => |global| if (std.mem.orderZ(u8, global.interface, wl.Output.interface.name).compare(.eq)) {
            const output = registry.bind(global.name, wl.Output, 4) catch |err| {
                std.debug.panic("error binding: {s}", .{@errorName(err)});
            };
            i.outputs.putNoClobber(i.gpa, output, .{ .name = null, .description = null }) catch @panic("oom");
            i.pending_outputs += 1;
            output.setListener(*Interface, outputListener, i);
        } else if (std.mem.orderZ(u8, global.interface, wl.Shm.interface.name).compare(.eq)) {
            i.wl_shm = registry.bind(global.name, wl.Shm, 2) catch |err| {
                std.debug.panic("error binding: {s}", .{@errorName(err)});
            };
        } else if (std.mem.orderZ(u8, global.interface, wl_ext.ImageCopyCaptureManagerV1.interface.name).compare(.eq)) {
            i.ext_image_copy_capture_manager = registry.bind(global.name, wl_ext.ImageCopyCaptureManagerV1, 1) catch |err| {
                std.debug.panic("error binding: {s}", .{@errorName(err)});
            };
        } else if (std.mem.orderZ(u8, global.interface, wl_ext.OutputImageCaptureSourceManagerV1.interface.name).compare(.eq)) {
            i.ext_output_image_capture_source_manager = registry.bind(global.name, wl_ext.OutputImageCaptureSourceManagerV1, 1) catch |err| {
                std.debug.panic("error binding: {s}", .{@errorName(err)});
            };
        } else {
            const name = std.mem.span(global.interface);
            std.debug.print("SAW: '{s}'\n", .{name});
        },
        .global_remove => {},
    }
}

fn outputListener(output: *wl.Output, event: wl.Output.Event, i: *Interface) void {
    i.mutex.lock(i.io) catch |err| switch (err) {
        error.Canceled => return,
    };
    defer i.mutex.unlock(i.io);

    const dest = i.outputs.getPtr(output).?;
    switch (event) {
        .name => |n| dest.name = i.arena.allocator().dupe(u8, std.mem.span(n.name)) catch @panic("oom"),
        .description => |d| dest.description = i.arena.allocator().dupe(u8, std.mem.span(d.description)) catch @panic("oom"),
        .done => i.pending_outputs -= 1,
        .scale, .mode, .geometry => {},
    }
}

fn copyCaptureSessionListener(
    capture_session: *wl_ext.ImageCopyCaptureSessionV1,
    event: wl_ext.ImageCopyCaptureSessionV1.Event,
    i: *Interface,
) void {
    _ = capture_session;
    log.debug("captureSessionListener new event: {any}", .{event});
    switch (event) {
        .shm_format => |f| {
            i.shm_formats.append(i.gpa, f.format) catch @panic("oom");
        },
        .buffer_size => |s| {
            i.buf_width = s.width;
            i.buf_height = s.height;
        },
        .done => i.shm_formats_done.set(i.io),
        .dmabuf_device, .dmabuf_format, .stopped => {},
    }
}

fn copyCaptureFrameListener(
    frame: *wl_ext.ImageCopyCaptureFrameV1,
    event: wl_ext.ImageCopyCaptureFrameV1.Event,
    i: *Interface,
) void {
    _ = frame;
    switch (event) {
        .transform, .damage, .presentation_time => {},
        .failed => @panic("oh deary me"),
        .ready => {
            i.frame_ready.set(i.io);
        },
    }
}
