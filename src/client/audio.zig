const builtin = @import("builtin");
const native_os = builtin.os.tag;

const std = @import("std");
const Allocator = std.mem.Allocator;

const Core = @import("Core.zig");
const Device = @import("Device.zig");
const StringPool = @import("StringPool.zig");

pub const Backend = switch (native_os) {
    .windows => @import("audio/Wasapi.zig"),
    .linux => @import("audio/PulseAudio.zig"),
    else => @import("audio/dummy.zig"),
};
pub const Direction = enum { capture, playout };

pub const Stream = Backend.Stream;
pub const CallbackFn = fn (
    stream: *anyopaque,
    buffer: *align(buffer_align) anyopaque,
    frame_count: usize,
) void;

pub const buffer_align = blk: {
    var a = @alignOf(f32);
    for (std.meta.fields(SampleType)) |field| {
        a = @max(a, @alignOf(@as(SampleType, @enumFromInt(field.value)).Native()));
    }
    break :blk a;
};

pub const SampleType = enum {
    i16,
    i32,
    f32,

    pub const max_byte_len = 4;
    pub fn Native(comptime self: SampleType) type {
        return switch (self) {
            .i16 => i16,
            .i32 => i32,
            .f32 => f32,
        };
    }
    pub fn max(comptime self: SampleType) self.Native() {
        return switch (self) {
            .i16 => std.math.maxInt(i16),
            .i32 => std.math.maxInt(i32),
            .f32 => 1.0,
        };
    }
    pub fn getByteLen(self: SampleType) usize {
        return switch (self) {
            .i16 => 2,
            .i32 => 4,
            .f32 => 4,
        };
    }
    pub fn asF32(comptime self: SampleType, sample: self.Native()) f32 {
        return switch (self) {
            .i16 => @floatFromInt(sample),
            .i32 => @floatFromInt(sample),
            .f32 => return sample,
        };
    }
    pub fn fromF32(comptime self: SampleType, float: f32) self.Native() {
        return switch (self) {
            .i16 => @intFromFloat(float),
            .i32 => @intFromFloat(float),
            .f32 => return float,
        };
    }
};

pub const Format = struct {
    sample_type: SampleType,
    channel_count: u16,
    sample_rate: u32,

    pub fn getFrameLen(self: Format) usize {
        const cc: usize = self.channel_count;
        const st: usize = self.sample_type.getByteLen();
        return cc * st;
    }

    pub fn eql(lhs: Format, rhs: Format) bool {
        return std.meta.eql(lhs, rhs);
    }
};

pub const Buffer = struct {
    frame_count: usize,
    ptr: *anyopaque,
};

/// One-time initialization for any process that uses audio.
pub const init = Backend.init;

fn iteration(comptime direction: Core.audio.Direction) type {
    return struct {
        pub const DeviceIteratorError = Backend.DeviceIteratorError;
        pub const DeviceIterator = struct {
            it: Backend.DeviceIterator,

            pub fn init(backend: *Backend, err: *DeviceIteratorError) error{DeviceIterator}!DeviceIterator {
                return .{ .it = try Backend.DeviceIterator.init(backend, direction, err) };
            }

            pub fn deinit(self: *DeviceIterator) void {
                self.it.deinit();
            }

            pub fn next(self: *DeviceIterator, err: *DeviceIteratorError) error{DeviceIterator}!?Core.Device {
                return self.it.next(err);
            }
        };
    };
}

pub const Directional = struct {
    direction: Direction,
    update_lock_count: usize = 0,
    devices: std.ArrayListUnmanaged(Device) = .{},

    pub const UpdateDevicesResult = union(enum) {
        locked: void,
        result: ?Backend.DeviceIteratorError,
    };
    pub fn updateDevices(
        self: *Directional,
        gpa: Allocator,
        backend: *Backend,
        on_event: *const fn (Core.UpdateDevicesEvent) void,
        sp: *StringPool,
    ) UpdateDevicesResult {
        if (self.update_lock_count != 0)
            return .locked;

        const result = switch (self.direction) {
            .capture => Device.updateArrayList(
                iteration(.capture),
                gpa,
                backend,
                &self.devices,
                on_event,
                sp,
            ),
            .playout => Device.updateArrayList(
                iteration(.playout),
                gpa,
                backend,
                &self.devices,
                on_event,
                sp,
            ),
        };
        return .{ .result = result };
    }

    pub fn lockDeviceUpdates(self: *Directional) []Device {
        self.update_lock_count += 1;
        return self.devices.items;
    }
    pub fn unlockDeviceUpdates(self: *Directional) void {
        std.debug.assert(self.update_lock_count > 0);
        self.update_lock_count -= 1;
    }
};
