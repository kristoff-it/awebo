const PulseAudio = @This();

const pa = @import("pulseaudio");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const log = std.log.scoped(.PulseAudio);

const StringPool = @import("../StringPool.zig");
const audio = @import("../audio.zig");
const Device = @import("../Device.zig");

context: *pa.context,
state: pa.context.state_t,
stream_state: pa.stream.state_t,
main_loop: *pa.threaded_mainloop,
stream: ?*pa.stream,
props: *pa.proplist,
device_scan_queued: bool,

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

pub fn processInit(p: *PulseAudio) !void {
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
        .device_scan_queued = true,
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

fn contextStateCallback(context: *pa.context, userdata: ?*anyopaque) callconv(.c) void {
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));
    p.state = context.get_state();
    log.debug("context state: {t}", .{p.state});
    switch (p.state) {
        .UNCONNECTED, .CONNECTING, .AUTHORIZING, .SETTING_NAME => return,
        .READY, .FAILED, .TERMINATED => p.main_loop.signal(0),
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
    std.log.info("subscription event: {any} index {d}", .{ event, index });
    p.device_scan_queued = true;
    p.main_loop.signal(0);
}

pub fn threadInit() void {}
pub fn threadDeinit() void {}

pub const DeviceIteratorError = struct {
    err: error{ OutOfMemory, OperationCanceled },

    pub fn format(self: DeviceIteratorError, writer: *Io.Writer) !void {
        try writer.print("{t}", .{self.err});
    }
};

pub const DeviceIterator = struct {
    p: *PulseAudio,
    direction: audio.Direction,
    next_index: u8,
    pub fn init(p: *PulseAudio, direction: audio.Direction, err: *DeviceIteratorError) error{DeviceIterator}!DeviceIterator {
        _ = err;
        return .{
            .direction = direction,
            .next_index = 0,
            .p = p,
        };
    }
    pub fn deinit(di: *DeviceIterator) void {
        _ = di;
    }
    pub fn next(di: *DeviceIterator, sp: *StringPool, gpa: Allocator, diags: *DeviceIteratorError) error{DeviceIterator}!?Device {
        const p = di.p;
        if (p.device_scan_queued) {
            p.device_scan_queued = false;
            p.refreshDevices() catch |err| {
                diags.err = err;
                return error.DeviceIterator;
            };
        }
        _ = sp;
        _ = gpa;
        @panic("TODO");
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

    std.log.info("sink: name={s} description={s} sample_rate={d} format={t} channels={d}", .{
        info.name, info.description, info.sample_spec.rate, info.sample_spec.format, info.sample_spec.channels,
    });
}

fn sourceInfoCallback(context: *pa.context, info: *const pa.source_info, eol: c_int, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));

    if (eol != 0) {
        p.main_loop.signal(0);
        return;
    }

    std.log.info("source: name={s} description={s} sample_rate={d} format={t} channels={d}", .{
        info.name, info.description, info.sample_spec.rate, info.sample_spec.format, info.sample_spec.channels,
    });
}

fn serverInfoCallback(context: *pa.context, info: *const pa.server_info, userdata: ?*anyopaque) callconv(.c) void {
    _ = context;
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));

    std.log.info("server: name={s} version={s} default_sink={s} default_source={s}", .{
        info.server_version,
        info.server_name,
        info.default_sink_name,
        info.default_source_name,
    });

    p.main_loop.signal(0);
}

fn refreshDevices(p: *PulseAudio) error{ OutOfMemory, OperationCanceled }!void {
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
