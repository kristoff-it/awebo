pub const opus = @import("awebo/opus.zig");
pub const permissions = @import("awebo/permissions.zig");
pub const protocol = @import("awebo/protocol.zig");
// pub const Clock = @import("awebo/Clock.zig");
pub const Database = @import("awebo/Database.zig");
pub const Channel = @import("awebo/Channel.zig");
pub const Host = @import("awebo/Host.zig");
pub const Message = @import("awebo/Message.zig");
pub const User = @import("awebo/User.zig");
pub const Caller = @import("awebo/Caller.zig");
pub const Invite = @import("awebo/Invite.zig");

pub const IdGenerator = struct {
    last: u64,

    pub fn init(last: u64) IdGenerator {
        return .{ .last = last };
    }

    pub fn new(g: *IdGenerator) u64 {
        g.last += 1;
        return g.last;
    }
};

// An awebo datetime is the number of seconds from the server epoch.
pub const Date = enum(u32) {
    epoch = 0,
    _,

    pub fn init(ts: Io.Timestamp, server_epoch: i64) Date {
        return @enumFromInt(ts.toSeconds() - server_epoch);
    }

    pub fn now(io: Io, server_epoch: i64) Date {
        const ts = Io.Clock.real.now(io) catch @panic("clock");
        return .init(ts, server_epoch);
    }

    // pub fn toTimestamp(d: Date, server_epoch: i64) Io.Timestamp {
    //     const dd: i64 = @intCast(d);
    //     const unix_seconds = server_epoch + dd;
    //     return .fromNanoseconds(unix_seconds * std.time.ns_per_s);
    // }

    /// To be used in a call to 'print()' with a '{f}' placeholder.
    pub fn fmt(d: Date, tz: *const zeit.TimeZone, server_epoch: i64) Formatter {
        return .{
            .date = d,
            .server_epoch = server_epoch,
            .tz = tz,
        };
    }

    /// For debugging, see Date.fmt() for pretty printing.
    pub fn format(d: Date, w: *Io.Writer) !void {
        try w.print("Date({})", .{@intFromEnum(d)});
    }

    pub const Formatter = struct {
        server_epoch: i64,
        date: Date,
        tz: *const zeit.TimeZone,
        gofmt: []const u8 = "Jan 2 15:04:05 2006",

        pub fn format(f: Formatter, w: *Io.Writer) !void {
            const instant = zeit.instant(undefined, .{
                .source = .{
                    .unix_timestamp = f.server_epoch + @intFromEnum(f.date),
                },
                .timezone = f.tz,
            }) catch unreachable;
            const time = instant.time();
            time.gofmt(w, f.gofmt) catch return error.WriteFailed;
        }
    };

    const std = @import("std");
    const Io = std.Io;
    const zeit = @import("zeit");
};

test {
    _ = Database;
}
