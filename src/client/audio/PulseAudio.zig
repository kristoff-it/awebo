const PulseAudio = @This();

const pa = @import("pulseaudio");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.PulseAudio);

const StringPool = @import("../StringPool.zig");
const audio = @import("../audio.zig");
const Device = @import("../Device.zig");
const Core = @import("../Core.zig");

context: *pa.context,
state: pa.context.state_t,
stream_state: pa.stream.state_t,
main_loop: *pa.threaded_mainloop,
stream: ?*pa.stream,
props: *pa.proplist,

core: *Core,
device_status: DeviceStatus,
/// Once this bit flips, the audio backend is cooked and you have to use
/// `deinit` / `init` to recover.
failed: bool,
playout_devices: std.ArrayList(Device),
capture_devices: std.ArrayList(Device),

pub const DeviceStatus = enum { ready, queued, oom };

pub const Stream = struct {
    direction: audio.Direction,
    format: audio.Format,
    max_buffer_frame_count: u32,

    pub const Error = struct {
        msg: []const u8,
        pub fn set(self: *Error, msg: []const u8) error{Stream} {
            self.* = .{ .msg = msg };
            return error.Stream;
        }
        pub fn format(self: Error, writer: *Io.Writer) !void {
            try writer.writeAll(self.msg);
        }
    };

    pub fn stop(s: *Stream) void {
        _ = s;
        @panic("TODO implement stop");
    }

    pub fn close(self: *Stream, sp: *StringPool, gpa: Allocator) void {
        _ = self;
        _ = sp;
        _ = gpa;
        @panic("TODO implement close");
    }

    pub fn open(
        out_stream: *Stream,
        direction: audio.Direction,
        err: *Error,
        device: ?Device,
        string_pool: *StringPool,
        callback_fn: *const audio.CallbackFn,
        callback_data: *anyopaque,
    ) error{Stream}!void {
        _ = out_stream;
        _ = direction;
        _ = string_pool;
        _ = err;
        _ = device;
        _ = callback_fn;
        _ = callback_data;
        @panic("TODO");
    }

    pub fn start(self: *Stream, err: *Error) error{Stream}!void {
        _ = self;
        _ = err;
        @panic("TODO");
    }
};

pub fn init(core: *Core) !void {
    const p: *PulseAudio = &core.audio_backend;

    const main_loop = try pa.threaded_mainloop.new();
    errdefer main_loop.free();

    const props = try pa.proplist.new();
    errdefer props.free();

    try props.sets("media.role", "phone");
    try props.sets("media.software", "awebo");

    const context = try pa.context.new_with_proplist(main_loop.get_api(), "awebo", props);
    errdefer context.unref();

    try context.connect(null, .{}, null);
    errdefer context.disconnect();

    p.* = .{
        .context = context,
        .stream = null,
        .state = .UNCONNECTED,
        .stream_state = .UNCONNECTED,
        .main_loop = main_loop,
        .props = props,
        .device_status = .queued,
        .failed = false,
        .playout_devices = .empty,
        .capture_devices = .empty,
        .core = core,
    };

    context.set_state_callback(contextStateCallback, p);
    context.set_subscribe_callback(subscribeCallback, p);

    try main_loop.start();
    errdefer main_loop.stop();

    {
        // Block until ready.
        main_loop.lock();
        defer main_loop.unlock();

        while (true) {
            main_loop.wait();
            switch (p.state) {
                .READY => break,
                .FAILED => return error.AudioFailed,
                .TERMINATED => return error.AudioTerminated,
                else => continue,
            }
        }

        const subscribe_op = try context.subscribe(.{
            .SINK = true,
            .SOURCE = true,
            .SERVER = true,
        }, null, null);
        subscribe_op.unref();
    }
}

pub fn deinit(p: *PulseAudio) void {
    p.main_loop.stop();
    p.context.disconnect();
    p.context.unref();
    p.props.free();
    p.main_loop.free();
}

fn contextStateCallback(context: *pa.context, userdata: ?*anyopaque) callconv(.c) void {
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));
    p.state = context.get_state();
    log.debug("context state: {t}", .{p.state});
    switch (p.state) {
        .UNCONNECTED, .CONNECTING, .AUTHORIZING, .SETTING_NAME => return,
        .READY, .TERMINATED => p.main_loop.signal(0),
        .FAILED => {
            p.failed = true;
            p.main_loop.signal(0);
        },
    }
}

fn subscribeCallback(
    context: *pa.context,
    event: pa.subscription_event_type_t,
    index: u32,
    userdata: ?*anyopaque,
) callconv(.c) void {
    _ = context;
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));
    log.debug("subscription event: {any} index {d}", .{ event, index });
    p.device_status = .queued;
    p.main_loop.signal(0);
}

pub const DeviceIteratorError = struct {
    err: error{ OutOfMemory, Disconnected },

    pub fn format(self: DeviceIteratorError, writer: *Io.Writer) !void {
        try writer.print("{t}", .{self.err});
    }
};

pub const DeviceIterator = struct {
    p: *PulseAudio,
    devices: []Device,
    next_index: usize,

    pub fn init(
        p: *PulseAudio,
        direction: audio.Direction,
        diags: *DeviceIteratorError,
    ) error{DeviceIterator}!DeviceIterator {
        flushEvents(p);
        switch (p.device_status) {
            .ready => {},
            .oom => {
                diags.err = error.OutOfMemory;
                return error.DeviceIterator;
            },
            .queued => unreachable,
        }
        return .{
            .p = p,
            .devices = switch (direction) {
                .playout => p.playout_devices.items,
                .capture => p.capture_devices.items,
            },
            .next_index = 0,
        };
    }

    pub fn deinit(di: *DeviceIterator) void {
        _ = di;
    }

    pub fn next(
        di: *DeviceIterator,
        diags: *DeviceIteratorError,
    ) error{DeviceIterator}!?Device {
        _ = diags;
        if (di.devices.len - di.next_index == 0) return null;
        const device = di.devices[di.next_index];
        di.next_index += 1;
        // The calling code will unref the device but we want to keep our ref.
        const sp = &di.p.core.string_pool;
        device.addReference(sp);
        return device;
    }
};

fn waitOperation(p: *PulseAudio, op: *pa.operation) error{OperationCanceled}!void {
    while (true) switch (op.get_state()) {
        .RUNNING => {
            p.main_loop.wait();
            continue;
        },
        .DONE => return,
        .CANCELLED => return error.OperationCanceled,
    };
}

fn sinkInfoCallback(context: *pa.context, info: *const pa.sink_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));

    if (eol != 0) {
        p.main_loop.signal(0);
        return;
    }

    sinkInfoCallbackFallible(p, info) catch |err| switch (err) {
        error.OutOfMemory => {
            p.device_status = .oom;
            return;
        },
    };
}

fn sinkInfoCallbackFallible(p: *PulseAudio, info: *const pa.sink_info) Allocator.Error!void {
    log.debug("sink: name={s} description={s} sample_rate={d} format={t} channels={d}", .{
        info.name, info.description, info.sample_spec.rate, info.sample_spec.format, info.sample_spec.channels,
    });

    const gpa = p.core.gpa;
    const sp = &p.core.string_pool;

    try p.playout_devices.ensureUnusedCapacity(gpa, 1);

    const name = try sp.getOrCreate(gpa, std.mem.span(info.name));
    errdefer sp.removeReference(name, gpa);

    const description = try sp.getOrCreate(gpa, std.mem.span(info.description));
    errdefer sp.removeReference(description, gpa);

    p.playout_devices.appendAssumeCapacity(.{
        .name = description,
        .token = name,
    });
}

fn sourceInfoCallback(context: *pa.context, info: *const pa.source_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));

    if (eol != 0) {
        p.main_loop.signal(0);
        return;
    }

    sourceInfoCallbackFallible(p, info) catch |err| switch (err) {
        error.OutOfMemory => {
            p.device_status = .oom;
            return;
        },
    };
}

fn sourceInfoCallbackFallible(p: *PulseAudio, info: *const pa.source_info) Allocator.Error!void {
    log.debug("source: name={s} description={s} sample_rate={d} format={t} channels={d}", .{
        info.name, info.description, info.sample_spec.rate, info.sample_spec.format, info.sample_spec.channels,
    });

    const gpa = p.core.gpa;
    const sp = &p.core.string_pool;

    try p.capture_devices.ensureUnusedCapacity(gpa, 1);

    const name = try sp.getOrCreate(gpa, std.mem.span(info.name));
    errdefer sp.removeReference(name, gpa);

    const description = try sp.getOrCreate(gpa, std.mem.span(info.description));
    errdefer sp.removeReference(description, gpa);

    p.capture_devices.appendAssumeCapacity(.{
        .name = description,
        .token = name,
    });
}

fn serverInfoCallback(context: *pa.context, info: *const pa.server_info, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));

    log.debug("server: name={s} version={s} default_sink={s} default_source={s}", .{
        info.server_version,
        info.server_name,
        info.default_sink_name,
        info.default_source_name,
    });

    p.main_loop.signal(0);
}

fn refreshDevices(p: *PulseAudio) error{ OutOfMemory, OperationCanceled }!void {
    clearDevices(p);

    const list_sink_op = try p.context.get_sink_info_list(sinkInfoCallback, p);
    defer list_sink_op.unref();
    const list_source_op = try p.context.get_source_info_list(sourceInfoCallback, p);
    defer list_source_op.unref();
    const server_info_op = try p.context.get_server_info(serverInfoCallback, p);
    defer server_info_op.unref();

    try p.waitOperation(list_source_op);
    try p.waitOperation(list_sink_op);
    try p.waitOperation(server_info_op);
}

fn flushEvents(p: *PulseAudio) void {
    p.main_loop.lock();
    defer p.main_loop.unlock();

    if (p.device_status != .ready and !p.failed) {
        refreshDevices(p) catch |err| switch (err) {
            error.OutOfMemory => {
                p.device_status = .oom;
                return;
            },
            error.OperationCanceled => {
                p.failed = true;
                return;
            },
        };
        p.device_status = .ready;
    }
}

fn clearDevices(p: *PulseAudio) void {
    const gpa = p.core.gpa;
    const sp = &p.core.string_pool;

    for (p.playout_devices.items) |device| device.removeReference(sp, gpa);
    for (p.capture_devices.items) |device| device.removeReference(sp, gpa);
    p.playout_devices.clearRetainingCapacity();
    p.capture_devices.clearRetainingCapacity();
}
