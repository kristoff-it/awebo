const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const core = @import("root").core;
const audio = core.audio;

pub const kind: core.audio.Kind = .new_hotness;

pub fn processInit() !void {}
pub fn threadInit() void {}
pub fn threadDeinit() void {}

const device_count = 5;

pub const DeviceIteratorError = struct {
    pub fn format(self: DeviceIteratorError, writer: *Io.Writer) !void {
        _ = self;
        try writer.print("DeviceIteratorError", .{});
    }
};
pub const DeviceIterator = struct {
    direction: core.audio.Direction,
    next_index: u8 = 0,
    pub fn init(direction: core.audio.Direction, err: *DeviceIteratorError) error{DeviceIterator}!DeviceIterator {
        _ = err;
        return .{ .direction = direction };
    }
    pub fn deinit(self: *DeviceIterator) void {
        _ = self;
    }
    pub fn next(self: *DeviceIterator, gpa: Allocator, err: *DeviceIteratorError) error{DeviceIterator}!?core.Device {
        _ = err;
        if (self.next_index == device_count) return null;
        defer self.next_index += 1;

        var name_buf: [100]u8 = undefined;
        const name = std.fmt.bufPrint(
            &name_buf,
            "Dummy {t} Device {}",
            .{ self.direction, self.next_index },
        ) catch unreachable;
        return .{
            .name = core.PoolString.getOrCreate(gpa, name) catch @panic("OOM"),
            .token = core.PoolString.getOrCreate(gpa, &[_]u8{self.next_index}) catch @panic("OOM"),
        };
    }
};

pub const Stream = struct {
    // public fields
    direction: audio.Direction,
    callback_data: *anyopaque,
    format: audio.Format,
    max_buffer_frame_count: u32 = 480,

    device_index: ?u8,
    callback_fn: *const audio.CallbackFn,
    last_get_buffer_timestamp: ?i64 = null,
    buffer: [480]f32 = undefined,

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

    pub fn open(
        out_stream: *Stream,
        direction: audio.Direction,
        err: *Error,
        device: ?core.Device,
        callback_fn: *const core.audio.CallbackFn,
        callback_data: *anyopaque,
    ) error{Stream}!void {
        _ = err;
        const device_index: ?u8 = blk: {
            const d = device orelse break :blk null;
            std.debug.assert(d.token.slice.len == 1);
            const index = d.token.slice[0];
            std.debug.assert(index <= device_count);
            break :blk index;
        };
        out_stream.* = .{
            .direction = direction,
            .callback_data = callback_data,
            .device_index = device_index,
            .callback_fn = callback_fn,
            .format = .{
                .sample_type = .f32,
                .channel_count = 1,
                .sample_rate = 48000,
            },
        };
    }
    pub fn close(self: *Stream, gpa: Allocator) void {
        _ = gpa;
        _ = self;
    }
    pub fn getBuffer(self: *Stream, err: *Error) error{Stream}!core.audio.Buffer {
        _ = err;
        // just do something dumb/simple for now
        const now = std.time.milliTimestamp();
        if (self.last_get_buffer_timestamp) |t| {
            const diff = now - t;
            if (diff < 10) return .{ .frame_count = 0, .ptr = undefined };
        }
        self.last_get_buffer_timestamp = now;
        return .{ .frame_count = self.max_buffer_frame_count, .ptr = &self.buffer };
    }
    pub fn releaseBuffer(self: *Stream, buffer: core.audio.Buffer) void {
        _ = self;
        _ = buffer;
    }
    pub fn start(self: *Stream, err: *Error) error{Stream}!void {
        _ = self;
        _ = err;
    }
    pub fn stop(self: *Stream) void {
        _ = self;
    }
};
