const JitterBuffer = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const log = std.log.scoped(.jitter);

/// Space for buffered packets. Must be a power of 2.
const buffer_len: usize = 16;
/// Number of packets that must be present in the buffer
/// before we start playing. Must be lower than `buffer_len`
const start_count = 8; // 5 packets @ 20ms = 100ms jitter
comptime {
    assert(std.math.isPowerOfTwo(buffer_len));
    assert(start_count < buffer_len);
}

state: enum {
    /// Waiting for the buffer to fill up for the first time
    /// or after a silence reset.
    starting,
    /// Playing audio normally
    playing,
    /// After we started playing, we emptied our buffer and
    /// are now waiting for the buffer to fill up again
    buffering,
} = .starting,
/// Expected next sequence number, 0 essentially means unset,
/// write() will set it to the seqence number of the first
/// packet you write.
expected_next_seq: u32 = 0,
packets: PlaybackPacketRing = .empty,

pub const init: JitterBuffer = .{};

/// This function is meant to be called by the network thread.
pub fn writePacket(jb: *JitterBuffer, seq: u32, data: []const u8) void {
    if (jb.expected_next_seq == 0) jb.expected_next_seq = seq;
    jb.packets.write(seq, data) catch {
        log.warn("dropping audio packet, audio thread is too slow!", .{});
    };
}

const NextPacket = union(enum) {
    /// When starting we should play silence.
    starting,
    /// Contains a compressed opus packet.
    /// If payload is null it means that the packet was lost.
    playing: ?Playing,

    const Playing = struct {
        r: usize,
        data: []const u8,
    };
};

/// This function is meant to be called by the audio thread.
pub fn nextPacketBegin(jb: *JitterBuffer) NextPacket {
    const packet_slices = jb.packets.slices();
    switch (packet_slices.len()) {
        0 => if (jb.state == .playing) {
            jb.state = .buffering;
        },
        1...start_count - 1 => {},
        else => jb.state = .playing,
    }

    switch (jb.state) {
        .starting => return .starting,
        .buffering => {
            jb.expected_next_seq += 1;
            return .{ .playing = null };
        },
        .playing => {},
    }

    assert(packet_slices.len() > 0); // invariant

    var idx: usize = 0;
    for (packet_slices.array()) |slice| for (slice) |n| {
        idx += 1;

        const next_seq = jb.packets.sequence_ids[n];
        if (next_seq == 1 and jb.expected_next_seq != 1) {
            jb.state = .starting;
            jb.expected_next_seq = 1;
            return .starting;
        }

        if (next_seq < jb.expected_next_seq) {
            log.debug("expected {} found {}", .{ jb.expected_next_seq, next_seq });
            continue;
        }

        if (idx > 1) {
            // If we skipped over some old data, commit those slots as read.
            jb.packets.commitRead(packet_slices.read_index + idx - 1);
        }

        if (next_seq == jb.expected_next_seq) {
            jb.expected_next_seq += 1;
            return .{
                .playing = .{
                    .data = jb.packets.data[n].slice(),
                    .r = packet_slices.read_index + idx,
                },
            };
        }

        jb.expected_next_seq += 1;
        if (idx > 1) jb.packets.commitRead(packet_slices.read_index + idx - 1);
        return .{ .playing = null };
    };

    // We looked through the full buffer and only found old data
    // which means we're back to buffering mode.
    jb.packets.commitRead(packet_slices.read_index + idx);
    jb.expected_next_seq += 1;
    jb.state = .buffering;
    return .{ .playing = null };
}

pub fn nextPacketCommit(jb: *JitterBuffer, playing: NextPacket.Playing) void {
    jb.packets.commitRead(playing.r);
}

const PlaybackPacketRing = struct {
    /// Index indirection for faster sorting by the audio thread.
    indexes: [buffer_len]RingIndex = undefined,

    /// SoA-style Packet representation
    sequence_ids: [buffer_len]u32 = undefined,
    data: [buffer_len]Data = undefined,

    /// This data structure operates similarly to a ring buffer.
    read_index: std.atomic.Value(usize) = .init(0),
    write_index: std.atomic.Value(usize) = .init(0),

    pub const Data = struct {
        buf: [1280]u8,
        len: usize,
        pub fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };

    pub const empty: PlaybackPacketRing = .{};
    pub const RingIndex = std.math.IntFittingRange(0, buffer_len);

    pub fn write(pb: *PlaybackPacketRing, seq: u32, data: []const u8) !void {
        const w = pb.write_index.load(.acquire);
        const r = pb.read_index.load(.acquire);
        if (mask2(w + buffer_len) == r) return error.Full;

        pb.sequence_ids[mask(w)] = seq;
        pb.data[mask(w)].len = data.len;
        const buf: [*]u8 = &pb.data[mask(w)].buf;
        assert(data.len <= pb.data[mask(w)].buf.len);
        @memcpy(buf, data);

        pb.indexes[mask(w)] = @intCast(mask(w));
        pb.write_index.store(mask2(w + 1), .release);
    }

    pub const Slices = struct {
        read_index: usize,
        first: []RingIndex,
        second: []RingIndex,

        pub fn len(s: *const Slices) usize {
            return s.first.len + s.second.len;
        }

        /// Convenience method for iterating over both slices more easily.
        pub fn array(s: *const Slices) [2][]RingIndex {
            return .{ s.first, s.second };
        }
    };

    /// Returns two slices that contain written data.
    /// The first slice contains older data.
    pub fn slices(pb: *PlaybackPacketRing) Slices {
        const w = pb.write_index.load(.acquire);
        const r = pb.read_index.load(.acquire);
        const l = len(w, r);

        const slice1_start = mask(r);
        const slice1_end = @min(buffer_len, slice1_start + l);

        const slice1 = pb.indexes[slice1_start..slice1_end];
        std.sort.pdq(RingIndex, slice1, pb, lessThan);

        const slice2 = pb.indexes[0 .. l - slice1.len];
        std.sort.pdq(RingIndex, slice2, pb, lessThan);

        return .{
            .read_index = r,
            .first = slice1,
            .second = slice2,
        };
    }

    pub fn commitRead(pb: *PlaybackPacketRing, new_read_index: usize) void {
        pb.read_index.store(mask2(new_read_index), .release);
    }

    fn mask(index: usize) usize {
        return index % buffer_len;
    }

    fn mask2(index: usize) usize {
        return index % (2 * buffer_len);
    }

    pub fn len(w: usize, r: usize) usize {
        const wrap_offset = 2 * buffer_len * @intFromBool(w < r);
        const adjusted_write_index = w + wrap_offset;
        return adjusted_write_index - r;
    }

    pub fn lessThan(pb: *const PlaybackPacketRing, lhs: RingIndex, rhs: RingIndex) bool {
        return pb.sequence_ids[lhs] < pb.sequence_ids[rhs];
    }
};

test "jitter buffer basics" {
    const t = std.testing;

    var jb: JitterBuffer = .init;
    try t.expectEqual(0, jb.expected_next_seq);
    try t.expectEqual(jb.nextPacketBegin(), .starting);
    try t.expectEqual(0, jb.expected_next_seq);

    {
        for (1..start_count + 1) |idx| {
            jb.writePacket(@intCast(idx), &.{@intCast(idx)});

            const w = jb.packets.write_index.raw;
            const r = jb.packets.read_index.raw;
            try t.expectEqual(idx, PlaybackPacketRing.len(w, r));
            const slices = jb.packets.slices();
            try t.expectEqual(idx, slices.first.len);
            try t.expectEqual(0, slices.second.len);
            try t.expectEqual(0, slices.read_index);
            for (slices.first, 0..) |slot, x| {
                try t.expectEqual(x, slot);
                try t.expectEqual(x + 1, jb.packets.sequence_ids[slot]);
            }
        }

        try t.expectEqual(1, jb.expected_next_seq);

        for (1..start_count + 1) |idx| {
            try t.expectEqual(idx, jb.expected_next_seq);
            const next = jb.nextPacketBegin();
            try t.expectEqualStrings("playing", @tagName(next));
            try t.expectEqual(idx + 1, jb.expected_next_seq);
            const p = next.playing orelse return error.Null;
            defer jb.nextPacketCommit(p);
            try t.expectEqual(1, p.data.len);
            try t.expectEqual(idx, p.data[0]);
        }
    }
}
