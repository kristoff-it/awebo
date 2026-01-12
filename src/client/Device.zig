/// A Device is a reference counted, serializable name/token pair.
/// It can be used to represent an audio device, webcam or screen.
/// The name is the string meant for the user to identify the device
/// and the token is a unique sequence of bytes that identifies the device.
/// Tokens can be stored to disk and the "same device" should retain it's
/// token even accross reboots.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("core.zig");
const PoolString = @import("PoolString.zig");

name: PoolString,
token: PoolString,

pub fn removeReference(self: Device, gpa: Allocator) void {
    self.name.removeReference(gpa);
    self.token.removeReference(gpa);
}

pub fn addReference(self: Device) void {
    self.name.addReference();
    self.token.addReference();
}

/// updateArrayList takes an array list of devices and updates it based on
/// an iterator derived from the given `iteration` namespace.
///
/// iteration must contain the following:
///     DeviceIteratorError with a format function:
///         pub fn format(....args for std.fmt...)
///     DeviceIterator with the following functions:
///         pub fn init(*DeviceIteratorError) error{DeviceIterator}!DeviceIterator
///         pub fn deinit(*DeviceIterator) void
///         pub fn next(*DeviceIterator, *DeviceIteratorError) error{DeviceIterator}!?Device
pub fn updateArrayList(
    comptime iteration: anytype,
    gpa: std.mem.Allocator,
    devices: *std.ArrayListUnmanaged(Device),
    on_event: *const fn (core.UpdateDevicesEvent) void,
) ?iteration.DeviceIteratorError {
    var new_device_count: usize = 0;

    const err: ?iteration.DeviceIteratorError = blk: {
        var err: iteration.DeviceIteratorError = undefined;

        var it = iteration.DeviceIterator.init(&err) catch break :blk err;
        defer it.deinit();

        while (it.next(gpa, &err) catch break :blk err) |next_device| : (new_device_count += 1) {
            defer next_device.removeReference(gpa);

            // sanity check
            for (devices.items[0..new_device_count]) |other| {
                std.debug.assert(other.token.slice.ptr != next_device.token.slice.ptr);
            }

            // see if this device already exists
            const found_at_index: ?usize = found: {
                for (new_device_count..devices.items.len) |index| {
                    const existing = &devices.items[index];
                    if (existing.token.slice.ptr == next_device.token.slice.ptr) {
                        if (existing.name.slice.ptr != next_device.name.slice.ptr) {
                            on_event(.{ .device_name_changed = .{
                                .old_name = existing.name,
                                .new_name = next_device.name,
                                .token = next_device.name,
                            } });
                            existing.name.removeReference(gpa);
                            existing.name = next_device.name;
                            existing.name.addReference();
                        }
                        break :found index;
                    }
                }
                break :found null;
            };
            if (found_at_index) |index| {
                if (index != new_device_count) {
                    const tmp = devices.items[new_device_count];
                    devices.items[new_device_count] = devices.items[index];
                    devices.items[index] = tmp;
                }
            } else {
                devices.insert(gpa, new_device_count, next_device) catch @panic("OOM");
                next_device.addReference();
                on_event(.{ .device_added = next_device });
            }
        }
        break :blk null;
    };

    for (new_device_count..devices.items.len) |i| {
        on_event(.{ .device_removed = devices.items[i] });
        devices.items[i].removeReference(gpa);
    }
    devices.shrinkAndFree(gpa, new_device_count);

    return err;
}
