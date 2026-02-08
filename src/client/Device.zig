/// A Device is a reference counted, serializable name/token pair.
/// It can be used to represent an audio device, webcam or screen.
/// The name is the string meant for the user to identify the device
/// and the token is a unique sequence of bytes that identifies the device.
/// Tokens can be stored to disk and the "same device" should retain it's
/// token even accross reboots.
const Device = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;

const Core = @import("Core.zig");
const StringPool = @import("StringPool.zig");
const audio = @import("audio.zig");

name: StringPool.String,
token: StringPool.String,

pub fn removeReference(self: Device, sp: *StringPool, gpa: Allocator) void {
    sp.removeReference(self.name, gpa);
    sp.removeReference(self.token, gpa);
}

pub fn addReference(self: Device, sp: *StringPool) void {
    sp.addReference(self.name);
    sp.addReference(self.token);
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
    backend: *audio.Backend,
    devices: *std.ArrayListUnmanaged(Device),
    on_event: *const fn (Core.UpdateDevicesEvent) void,
    sp: *StringPool,
) ?iteration.DeviceIteratorError {
    var new_device_count: usize = 0;

    const err: ?iteration.DeviceIteratorError = blk: {
        var err: iteration.DeviceIteratorError = undefined;

        var it = iteration.DeviceIterator.init(backend, &err) catch break :blk err;
        defer it.deinit();

        while (it.next(&err) catch break :blk err) |next_device| : (new_device_count += 1) {
            defer next_device.removeReference(sp, gpa);

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
                            sp.removeReference(existing.name, gpa);
                            existing.name = next_device.name;
                            sp.addReference(existing.name);
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
                next_device.addReference(sp);
                on_event(.{ .device_added = next_device });
            }
        }
        break :blk null;
    };

    for (new_device_count..devices.items.len) |i| {
        on_event(.{ .device_removed = devices.items[i] });
        devices.items[i].removeReference(sp, gpa);
    }
    devices.shrinkAndFree(gpa, new_device_count);

    return err;
}
