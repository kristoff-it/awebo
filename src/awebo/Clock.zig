//!A Clock.Tick is both a timestamp and a sequence number baked into one integer.
//! The result is an integer that can be used as a unique identifier
const Clock = @This();

const std = @import("std");
const Io = std.Io;
const log = std.log.scoped(.clock);

/// Server creation time
epoch: i64,
now: Tick,

pub const Tick = struct {
    counter: Counter,
    time: Time,

    pub const Counter = u8;
    pub const Time = @Int(.unsigned, 64 - @bitSizeOf(Counter));

    pub const zero: Tick = .{ .time = 0, .counter = 0 };

    pub fn id(t: Tick) u64 {
        return t.time << @bitSizeOf(Counter) | t.counter;
    }

    pub fn fromId(_id: u64) Tick {
        return .{
            .time = @truncate(_id >> @bitSizeOf(Counter)),
            .counter = @truncate(_id),
        };
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
        log.debug("now = {}, epoch = {}", .{ now.toSeconds(), clock.epoch });
        const system_time: u32 = @intCast(now.toSeconds() - clock.epoch);

        if (system_time <= clock.now.time) {
            const delta = clock.now.time - system_time;
            if (delta > 60 * 60) {
                @panic("clock jumped backwards more than one hour!");
            }

            if (delta > 3) {
                @panic("clock jumped backwards more than three seconds!");
            }

            if (delta > 0) {
                log.warn("clock observed a clock skew of {}seconds!", .{delta});
                io.sleep(.fromSeconds(delta), .awake) catch continue;
                continue;
            }

            if (clock.now.counter == std.math.maxInt(Tick.Counter)) {
                @panic("exhausted the counter of a Clock.Tick, either a huge clock skew happened or spam got through");
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
