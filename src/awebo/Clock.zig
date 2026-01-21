//!A Clock.Tick is both a timestamp and a sequence number baked into one integer.
//! The result is an integer that can be used as a unique identifier
const Clock = @This();

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.clock);

/// Server creation time
epoch: i64,
now: Tick,

pub const Tick = packed struct(u64) {
    counter: Counter,
    time: Time,

    pub const Counter = u8;
    pub const Time = @Int(.unsigned, 64 - @bitSizeOf(Counter));

    pub const zero: Tick = .{ .time = 0, .counter = 0 };

    pub fn id(t: Tick) u64 {
        return @bitCast(t);
    }
    pub fn fromId(_id: u64) Tick {
        return @bitCast(_id);
    }

    pub fn timestamp(t: Tick, epoch: i64) i64 {
        const tt: i64 = @intCast(t.time);
        return tt + epoch;
    }

    pub fn format(t: Tick, w: *Io.Writer) !void {
        try w.print("Id({d}-{d})", .{ t.time, t.counter });
    }
};

pub fn init(epoch: i64, now: Tick) Clock {
    return .{ .epoch = epoch, .now = now };
}

pub fn tick(clock: *Clock, io: Io) u64 {
    while (true) {
        const now = Io.Clock.real.now(io) catch @panic("server needs a working clock");
        const now_seconds = now.toSeconds();
        const system_time: u32 = @intCast(now_seconds - clock.epoch);

        if (system_time <= clock.now.time) {
            const delta = clock.now.time - system_time;
            if (delta > 60 * 60) {
                @panic("clock jumped backwards more than one hour!");
            }

            if (delta > 3) {
                @panic("clock jumped backwards more than three seconds!");
            }

            if (delta > 0) {
                log.warn("clock observed a clock skew of {} seconds, sleeping to compensate", .{delta});
                const target_ns = (now_seconds + 1) * std.time.ns_per_s;
                io.sleep(.fromNanoseconds(target_ns - now), .awake) catch continue;
                continue;
            }

            if (clock.now.counter == std.math.maxInt(Tick.Counter)) {
                log.warn("exhausted counter for {}, sleeping to compensate", .{now_seconds});
                const target_ns = (now_seconds + 1) * std.time.ns_per_s;
                io.sleep(.fromNanoseconds(target_ns - now), .awake) catch continue;
                continue;
            }

            clock.now.counter += 1;
            return clock.now.id();
        }

        // system_time > clock.now.time
        const new_tick: Tick = .{ .time = system_time, .counter = 0 };
        clock.now = new_tick;
        return new_tick.id();
    }
}
