const JitterBuffer = @This();

const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const awebo = @import("../../awebo.zig");

const log = std.log.scoped(.jitter);

/// Space for buffered packets. Must be a power of 2.
const buffer_len: usize = 16;
/// Number of packets that must be present in the buffer
/// before we start playing. Must be lower than `buffer_len`
const start_count = 5; // 5 packets @ 20ms = 100ms jitter
comptime {
    assert(std.math.isPowerOfTwo(buffer_len));
    assert(start_count < buffer_len);
}

/// Writer side
stats: struct {
    start_time: Io.Timestamp = undefined,
    seq: u32 = 0,
    restart: u32 = 0,
} = .{},

/// Reader side
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
current_restart: u32 = 0,
expected_next_seq: u32 = 0,
last_buffer_len: u32 = start_count,
max_deficit: u32 = 0,
dred_state: *awebo.opus.DredState,
dred_decoder: *awebo.opus.DredDecoder,

/// Shared (atomic)
packets: PlaybackPacketRing,

pub fn init() JitterBuffer {
    return .{
        .dred_state = awebo.opus.DredState.create() catch @panic("oom"),
        .dred_decoder = awebo.opus.DredDecoder.create() catch @panic("oom"),
        .packets = .init,
    };
}

/// This function is meant to be called by the network thread.
pub fn writePacket(jb: *JitterBuffer, io: Io, restart: u32, seq: u32, data: []const u8) void {
    if (jb.expected_next_seq == 0) {
        jb.current_restart = restart;
        jb.expected_next_seq = seq;
    }

    if (restart != jb.stats.restart) {
        jb.stats = .{
            .start_time = Io.Clock.real.now(io),
            .restart = restart,
            .seq = seq,
        };
        log.debug("stats: restart", .{});

        // On restart just write the packet and never process DRED.
        // We're starting from silence and there cannot be missing data.
        jb.packets.write(restart, seq, data) catch {
            log.warn("dropping audio packet, audio thread is too slow!", .{});
        };
    } else {
        const delta = jb.stats.start_time.addDuration(
            .fromMilliseconds(20 * (seq)),
        ).durationTo(Io.Clock.real.now(io)).toMilliseconds();

        if (delta < 0) {
            jb.stats.start_time = jb.stats.start_time.addDuration(.fromMilliseconds(delta));
        }

        log.debug("stats: packet jitter = {}ms ({})", .{
            delta,
            seq,
        });

        jb.packets.write(restart, seq, data) catch {
            log.warn("dropping audio packet, audio thread is too slow!", .{});
        };
    }
}

const NextPacket = union(enum) {
    /// When starting we should play silence.
    starting,

    /// Contains a compressed opus packet.
    /// If packet loss happened, this is the subsequent packet
    /// from the same restart and it contains FEC data.
    /// Use the Opus decoder with a matching fec setting.
    playing: Playing,

    /// Packet loss happened, this is a future packet
    /// from the same restart that you should get DRED
    /// samples from.
    dred: Dred,

    /// Packet is missing and there is no future packet
    /// available for DRED, play silence through Opus.
    missing,

    const Playing = struct {
        r: usize,
        data: []const u8,
        fec: bool,
    };

    const Dred = struct {
        // Distance in samples between the (missing) current packet
        // and the future packet we're using for DRED.
        // Guaranteed to be within the DRED window.
        distance_samples: u32,
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
            return .missing;
        },
        .playing => {},
    }

    assert(packet_slices.len() > 0); // invariant

    var idx: usize = 0;
    for (packet_slices.array()) |slice| for (slice) |n| {
        idx += 1;

        const next_meta = jb.packets.meta[n];
        if (next_meta.restart < jb.current_restart) {
            continue;
        }

        if (jb.packets.dred[n] == -1) {
            if (jb.dred_decoder.parse(
                jb.dred_state,
                jb.packets.data[n].slice(),
                48000,
                .deferred,
            )) |info| {
                jb.packets.dred[n] = @intCast(info.available);
            } else |err| {
                log.err("error parsing dred: {t}", .{err});
                // jb.expected_next_seq += 1;
                // if (idx > 1) jb.packets.commitRead(packet_slices.read_index + idx - 1);
                // return .missing;
            }
        }
        // {
        //     if (jb.dred_decoder.parse(
        //         jb.dred_state,
        //         48000,
        //         .deferred,
        //     )) |info| {
        //         log.debug("dred info ({}) = {any}", .{ next_meta.seq, info });
        //     } else |err| {
        //         log.err("error parsing dred: {t}", .{err});
        //     }
        // }

        if (next_meta.restart > jb.current_restart) {
            jb.state = .starting;
            jb.expected_next_seq = 1;
            jb.current_restart = next_meta.restart;

            log.debug("after restart max deficit was {}", .{jb.max_deficit});
            jb.last_buffer_len = start_count;
            jb.max_deficit = 0;
            return .starting;
        }

        if (next_meta.seq < jb.expected_next_seq) {
            log.debug("expected {} found {}", .{ jb.expected_next_seq, next_meta });
            continue;
        }

        {
            const current_len: u32 = @intCast(packet_slices.len() - idx);
            // log.debug("reader: current len {} ({}) ({})", .{
            //     current_len,
            //     packet_slices.len(),
            //     idx,
            // });
            if (current_len > jb.last_buffer_len) {
                jb.max_deficit = @max(jb.max_deficit, start_count -| jb.last_buffer_len);
                // log.debug("new max_deficit = {}", .{jb.max_deficit});
                jb.last_buffer_len = current_len;
            } else if (current_len < jb.last_buffer_len) {
                jb.last_buffer_len = current_len;
            } else {
                // if current_len == jb.last_buffer_len do nothing
            }
        }

        if (idx > 1) {
            // If we skipped over some old data, commit those slots as read.
            jb.packets.commitRead(packet_slices.read_index + idx - 1);
        }

        if (next_meta.seq == jb.expected_next_seq) {
            jb.expected_next_seq += 1;
            return .{
                .playing = .{
                    .data = jb.packets.data[n].slice(),
                    .r = packet_slices.read_index + idx,
                    .fec = false,
                },
            };
        }

        // Packet loss but we have a future packet on hand.
        // To perform FEC or DRED the packet must be in the current restart.
        if (next_meta.restart != jb.current_restart) {
            jb.expected_next_seq += 1;
            if (idx > 1) jb.packets.commitRead(packet_slices.read_index + idx - 1);
            return .missing;
        }

        assert(jb.expected_next_seq < next_meta.seq);

        const data = jb.packets.data[n].slice();
        const distance_packets = next_meta.seq - jb.expected_next_seq;
        log.debug("distance packets = {}", .{distance_packets});
        if (awebo.opus.FEC and distance_packets == 1) {
            jb.expected_next_seq += 1;
            if (idx > 1) jb.packets.commitRead(packet_slices.read_index + idx - 1);
            return .{
                .playing = .{
                    .data = jb.packets.data[n].slice(),
                    .r = undefined,
                    .fec = true,
                },
            };
        }
        const distance_samples = distance_packets * awebo.opus.PACKET_SAMPLE_COUNT;

        const available = jb.packets.dred[n];
        log.debug("used dred needed = {} available= {}", .{ distance_samples, available });

        const not_enough = available < distance_samples;
        if (not_enough) {
            log.debug(
                "packet available for dred, but it has not enough data: needed = {} had = {}",
                .{ distance_samples, available },
            );
            jb.expected_next_seq += 1;
            if (idx > 1) jb.packets.commitRead(packet_slices.read_index + idx - 1);
            return .missing;
        }

        const next: NextPacket = .{
            .dred = .{
                .distance_samples = distance_samples,
                .data = data,
            },
        };

        jb.expected_next_seq += 1;
        if (idx > 1) jb.packets.commitRead(packet_slices.read_index + idx - 1);
        return next;
    };

    // We looked through the full buffer and only found old data
    // which means we're back to buffering mode.
    jb.packets.commitRead(packet_slices.read_index + idx);
    jb.expected_next_seq += 1;
    jb.state = .buffering;
    return .missing;
}

pub fn nextPacketCommit(jb: *JitterBuffer, playing: NextPacket.Playing) void {
    if (playing.fec) return;
    jb.packets.commitRead(playing.r);
}

const PlaybackPacketRing = struct {
    /// Index indirection for faster sorting by the audio thread.
    indexes: [buffer_len]RingIndex = undefined,

    /// SoA-style Packet representation
    meta: [buffer_len]struct { seq: u32, restart: u32 } = undefined,
    data: [buffer_len]Data = undefined,
    dred: [buffer_len]i32 = @splat(-1),

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

    // pub const DredPacket = struct {
    //     state: *awebo.opus.DredState,
    //     info: awebo.opus.DredInfo = undefined,
    // };

    pub const init: PlaybackPacketRing = .{};
    pub const RingIndex = std.math.IntFittingRange(0, buffer_len);

    pub fn write(pb: *PlaybackPacketRing, restart: u32, seq: u32, data: []const u8) !void {
        const w = pb.write_index.load(.acquire);
        const r = pb.read_index.load(.acquire);
        if (mask2(w + buffer_len) == r) return error.Full;

        pb.meta[mask(w)] = .{ .restart = restart, .seq = seq };
        pb.data[mask(w)].len = data.len;
        pb.dred[mask(w)] = -1;
        const buf: [*]u8 = &pb.data[mask(w)].buf;
        assert(data.len <= pb.data[mask(w)].buf.len);
        @memcpy(buf, data);

        pb.indexes[mask(w)] = @intCast(mask(w));
        pb.write_index.store(mask2(w + 1), .release);
    }

    pub const DredWrite = struct {
        state: *awebo.opus.DredState,
        info: *awebo.opus.DredInfo,
        w: usize,
    };

    // pub fn writeDredBegin(pb: *PlaybackPacketRing) !DredWrite {
    //     const w = pb.write_index.load(.acquire);
    //     const r = pb.read_index.load(.acquire);
    //     if (mask2(w + buffer_len) == r) return error.Full;

    //     const dred = &pb.dred[mask(w)];
    //     return .{
    //         .state = dred.state,
    //         .info = &dred.info,
    //         .w = w,
    //     };
    // }

    // pub fn writeDredCommit(
    //     pb: *PlaybackPacketRing,
    //     restart: u32,
    //     seq: u32,
    //     data: []const u8,
    //     dw: DredWrite,
    // ) !void {
    //     const w = dw.w;
    //     pb.meta[mask(w)] = .{ .restart = restart, .seq = seq };
    //     pb.data[mask(w)].len = data.len;
    //     const buf: [*]u8 = &pb.data[mask(w)].buf;
    //     assert(data.len <= pb.data[mask(w)].buf.len);
    //     @memcpy(buf, data);

    //     pb.indexes[mask(w)] = @intCast(mask(w));
    //     pb.write_index.store(mask2(w + 1), .release);
    // }

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

    pub fn lessThan(pb: *const PlaybackPacketRing, lhs_idx: RingIndex, rhs_idx: RingIndex) bool {
        const lhs = pb.meta[lhs_idx];
        const rhs = pb.meta[rhs_idx];
        return if (lhs.restart == rhs.restart)
            lhs.seq < rhs.seq
        else
            lhs.restart < rhs.restart;
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
            jb.writePacket(0, @intCast(idx), &.{@intCast(idx)});

            const w = jb.packets.write_index.raw;
            const r = jb.packets.read_index.raw;
            try t.expectEqual(idx, PlaybackPacketRing.len(w, r));
            const slices = jb.packets.slices();
            try t.expectEqual(idx, slices.first.len);
            try t.expectEqual(0, slices.second.len);
            try t.expectEqual(0, slices.read_index);
            for (slices.first, 0..) |slot, x| {
                try t.expectEqual(x, slot);
                try t.expectEqual(x + 1, jb.packets.meta[slot].seq);
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
