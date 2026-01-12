//!A ClockId is both a timestamp and a sequence number baked into one integer.
//! as a counter.
//! The result is an integer that can be used as a unique
const std = @import("std");
const log = std.log.scoped(.clock);

pub fn Id(comptime size: enum { u32, u64 }) type {
    return struct {
        epoch: i64,
        now: Tick,

        pub const Tick = packed struct(u64) {
            t: u32,
            c: u32,

            pub fn timestamp(id: Tick, epoch: i64) i64 {
                const t: i64 = @intCast(id.t);
                return t + epoch;
            }
        };

        pub fn init(epoch: i64, now: ?Tick) Clock {
            return .{
                .epoch = epoch,
                .now = now orelse 0,
            };
        }

        pub fn tick(clock: *Clock) Tick {
            while (true) {
                const system_time: u32 = @intCast(std.time.timestamp() -| clock.epoch);

                if (system_time <= clock.now.t) {
                    const delta = clock.now.t - system_time;
                    if (delta > 60 * 60) {
                        log.err("clock jumped backwards more than one hour!", .{});
                    }

                    if (delta > 1) {
                        log.warn("clock observed a clock skew of {}seconds!", .{delta});
                    }

                    if (clock.now.c == std.math.maxInt(u32)) {
                        @panic("exhausted the 32bit counter of a Clock.Tick, either a huge clock skew happened or spam got through");
                    }

                    clock.now.c += 1;
                    return clock.now;
                }

                // system_time > clock.now.t
                const new_tick: Tick = .{ .t = system_time, .c = 0 };
                clock.now = new_tick;
                return new_tick;
            }
        }
    };
}
