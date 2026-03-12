const std = @import("std");
const assert = std.debug.assert;
const awebo = @import("../../awebo.zig");

pub fn PacketRing(T: type, comptime capacity: usize) type {
    assert(std.math.isPowerOfTwo(capacity));

    return struct {
        pub const Child = T;
        pub const cap = capacity;
        pub const RingIndex = std.math.IntFittingRange(0, capacity);

        buffer: [capacity]T,
        read_index: std.atomic.Value(usize) = .init(0),
        write_index: std.atomic.Value(usize) = .init(0),

        pub const empty: @This() = .{ .buffer = undefined };
        pub fn initSplat(value: T) @This() {
            return .{ .buffer = @splat(value) };
        }

        /// Sets read_index and write_index to zero, leaving the buffer data untouched.
        pub fn reset(pr: *@This()) void {
            pr.read_index = .init(0);
            pr.write_index = .init(0);
        }

        pub const Write = struct { packet: *T, w: usize };
        pub fn beginWrite(pr: *@This()) ?Write {
            const w = pr.write_index.load(.acquire);
            const r = pr.read_index.load(.acquire);

            if (mask2(w + capacity) == r) return null;
            return .{ .w = w, .packet = &pr.buffer[mask(w)] };
        }

        pub fn commitWrite(pr: *@This(), write: Write) void {
            pr.write_index.store(mask2(write.w + 1), .release);
        }

        pub const Read = struct { packet: *const T, r: usize };
        pub fn beginRead(pr: *@This()) ?Read {
            const w = pr.write_index.load(.acquire);
            const r = pr.read_index.load(.acquire);

            if (w == r) return null;
            const data = &pr.buffer[mask(r)];
            return .{ .r = r, .packet = data };
        }

        pub fn commitRead(pr: *@This(), read: Read) void {
            pr.read_index.store(mask2(read.r + 1), .release);
        }

        fn mask(index: usize) usize {
            return index % capacity;
        }

        fn mask2(index: usize) usize {
            return index % (2 * capacity);
        }

        fn len(w: usize, r: usize) usize {
            const wrap_offset = 2 * capacity * @intFromBool(w < r);
            const adjusted_write_index = w + wrap_offset;
            return adjusted_write_index - r;
        }
    };
}
