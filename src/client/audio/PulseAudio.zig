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
seek_flag: bool,

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

    context.set_state_callback(contextStateCallback, p);
    try context.connect(null, .{}, null);
    errdefer context.disconnect();

    try main_loop.start();
    errdefer main_loop.stop();

    p.* = .{
        .context = context,
        .stream = null,
        .state = .UNCONNECTED,
        .stream_state = .UNCONNECTED,
        .main_loop = main_loop,
        .props = props,
        .seek_flag = false,
    };
}

fn contextStateCallback(context: *pa.context, userdata: ?*anyopaque) callconv(.c) void {
    const p: *PulseAudio = @ptrCast(@alignCast(userdata));
    p.state = context.get_state();
    log.debug("context state: {s}", .{@tagName(p.state)});
    switch (p.state) {
        .UNCONNECTED, .CONNECTING, .AUTHORIZING, .SETTING_NAME => return,
        .READY, .FAILED, .TERMINATED => p.main_loop.signal(0),
    }
}

pub fn threadInit() void {}
pub fn threadDeinit() void {}

pub const DeviceIteratorError = struct {
    pub fn format(self: DeviceIteratorError, writer: *Io.Writer) !void {
        _ = self;
        try writer.print("DeviceIteratorError", .{});
    }
};

pub const DeviceIterator = struct {
    direction: audio.Direction,
    next_index: u8 = 0,
    pub fn init(direction: audio.Direction, err: *DeviceIteratorError) error{DeviceIterator}!DeviceIterator {
        _ = err;
        return .{ .direction = direction };
    }
    pub fn deinit(di: *DeviceIterator) void {
        _ = di;
    }
    pub fn next(di: *DeviceIterator, sp: *StringPool, gpa: Allocator, err: *DeviceIteratorError) error{DeviceIterator}!?Device {
        _ = di;
        _ = sp;
        _ = gpa;
        _ = err;
        @panic("TODO");
    }
};
