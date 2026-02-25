const CapturePacketRing = @This();

const std = @import("std");
const assert = std.debug.assert;
const awebo = @import("../../awebo.zig");
const log = std.log.scoped(.capture_packet_ring);

const buffer_len: usize = 4;
const RingIndex = std.math.IntFittingRange(0, buffer_len);

data: [buffer_len]Data = undefined,

/// This data structure operates similarly to a ring buffer.
read_index: std.atomic.Value(usize) = .init(0),
write_index: std.atomic.Value(usize) = .init(0),

pub const Data = struct {
    power: f32,
    buf: [1280]u8,
    len: usize,

    pub fn writeSlice(self: *@This()) []u8 {
        return self.buf[0..];
    }

    pub fn readSlice(self: *@This()) []u8 {
        return self.buf[0..self.len];
    }
};

pub const empty: CapturePacketRing = .{};

pub const Write = struct {
    w: usize,
    data: *Data,
};

// const Io = std.Io;
// var last: ?Io.Timestamp = null;
/// This function is meant to be called by the audio thread.
pub fn beginWrite(cpr: *CapturePacketRing) ?Write {
    // const io = @import("../Core.zig").tempio.*;
    // const now = Io.Clock.awake.now(io);

    // if (last) |l| log.debug("---->--->---> {}ms", .{l.durationTo(now).toMilliseconds()});
    // last = now;

    const w = cpr.write_index.load(.acquire);
    const r = cpr.read_index.load(.acquire);

    if (mask2(w + buffer_len) == r) return null;
    return .{ .w = w, .data = &cpr.data[mask(w)] };
}

pub fn commitWrite(cpr: *CapturePacketRing, write: Write) void {
    cpr.write_index.store(mask2(write.w + 1), .release);
}

pub const Read = struct {
    r: usize,
    data: []const u8,
    power: f32,
};

/// This function is meant to be called by the network thread.
pub fn beginRead(cpr: *CapturePacketRing) ?Read {
    const w = cpr.write_index.load(.acquire);
    const r = cpr.read_index.load(.acquire);

    // const l = len(w, r);
    // if (l > 1) std.debug.panic("capture ring len = {}", .{l});

    if (w == r) return null;
    const data = &cpr.data[mask(r)];
    return .{
        .r = r,
        .data = data.readSlice(),
        .power = data.power,
    };
}

pub fn commitRead(cpr: *CapturePacketRing, read: Read) void {
    cpr.read_index.store(mask2(read.r + 1), .release);
}

fn mask(index: usize) usize {
    return index % buffer_len;
}

fn mask2(index: usize) usize {
    return index % (2 * buffer_len);
}

fn len(w: usize, r: usize) usize {
    const wrap_offset = 2 * buffer_len * @intFromBool(w < r);
    const adjusted_write_index = w + wrap_offset;
    return adjusted_write_index - r;
}

test "ring basics" {
    const t = std.testing;

    var cpr: CapturePacketRing = .empty;
    try t.expectEqual(null, cpr.beginRead());

    {
        for (0..4) |idx| {
            errdefer std.debug.print("error at index {}\n", .{idx});
            const write = cpr.beginWrite().?;
            try t.expectEqual(idx, write.w);
            write.data.len = idx;
            cpr.commitWrite(write);
        }

        for (0..4) |idx| {
            errdefer std.debug.print("error at index {}\n", .{idx});
            const read = cpr.beginRead().?;
            try t.expectEqual(idx, read.r);
            try t.expectEqual(idx, read.data.len);
            cpr.commitRead(read);
        }

        try t.expectEqual(null, cpr.beginRead());

        for (0..4) |idx| {
            errdefer std.debug.print("error at index {}\n", .{idx});
            const write = cpr.beginWrite().?;
            try t.expectEqual(idx + 4, write.w);
            write.data.len = idx + 4;
            cpr.commitWrite(write);
        }

        for (0..4) |idx| {
            errdefer std.debug.print("error at index {}\n", .{idx});
            const read = cpr.beginRead().?;
            try t.expectEqual(idx + 4, read.r);
            try t.expectEqual(idx + 4, read.data.len);
            cpr.commitRead(read);
        }

        try t.expectEqual(null, cpr.beginRead());
        for (0..3) |idx| {
            errdefer std.debug.print("error at index {}\n", .{idx});
            const write = cpr.beginWrite().?;
            try t.expectEqual(idx, write.w);
            write.data.len = idx;
            cpr.commitWrite(write);
        }

        for (0..3) |idx| {
            errdefer std.debug.print("error at index {}\n", .{idx});
            const read = cpr.beginRead().?;
            try t.expectEqual(idx, read.r);
            try t.expectEqual(idx, read.data.len);
            cpr.commitRead(read);
        }

        try t.expectEqual(null, cpr.beginRead());

        for (0..4) |idx| {
            errdefer std.debug.print("error at index {}\n", .{idx});
            const write = cpr.beginWrite().?;
            try t.expectEqual(idx + 3, write.w);
            write.data.len = idx + 3;
            cpr.commitWrite(write);
        }

        for (0..4) |idx| {
            errdefer std.debug.print("error at index {}\n", .{idx});
            const read = cpr.beginRead().?;
            try t.expectEqual(idx + 3, read.r);
            try t.expectEqual(idx + 3, read.data.len);
            cpr.commitRead(read);
        }

        try t.expectEqual(null, cpr.beginRead());
    }
}
