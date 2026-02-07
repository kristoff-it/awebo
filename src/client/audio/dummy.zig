const Dummy = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const audio = @import("../audio.zig");
const StringPool = @import("../StringPool.zig");
const Device = @import("../Device.zig");

pub fn init(d: *Dummy) !void {
    _ = d;
}

const device_count = 5;

pub const DeviceIteratorError = struct {
    pub fn format(self: DeviceIteratorError, writer: *Io.Writer) !void {
        _ = self;
        try writer.print("DeviceIteratorError", .{});
    }
};
pub const DeviceIterator = struct {
    direction: audio.Direction,
    next_index: u8 = 0,
    pub fn init(d: *Dummy, direction: audio.Direction, err: *DeviceIteratorError) error{DeviceIterator}!DeviceIterator {
        _ = d;
        _ = err;
        return .{ .direction = direction };
    }
    pub fn deinit(self: *DeviceIterator) void {
        _ = self;
    }
    pub fn next(self: *DeviceIterator, sp: *StringPool, gpa: Allocator, err: *DeviceIteratorError) error{DeviceIterator}!?Device {
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
            .name = sp.getOrCreate(gpa, name) catch @panic("OOM"),
            .token = sp.getOrCreate(gpa, &[_]u8{self.next_index}) catch @panic("OOM"),
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
        device: ?Device,
        string_pool: *StringPool,
        callback_fn: *const audio.CallbackFn,
        callback_data: *anyopaque,
    ) error{Stream}!void {
        _ = string_pool;
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
    pub fn close(self: *Stream, sp: *StringPool, gpa: Allocator) void {
        _ = self;
        _ = sp;
        _ = gpa;
    }
    pub fn getBuffer(self: *Stream, err: *Error) error{Stream}!audio.Buffer {
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
    pub fn releaseBuffer(self: *Stream, buffer: audio.Buffer) void {
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
