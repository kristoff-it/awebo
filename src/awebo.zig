const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;

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
        const ts = Io.Clock.real.now(io);
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

    const zeit = @import("zeit");
};

pub const network_utils = struct {
    pub fn setTcpNoDelay(socket: Io.net.Socket) void {
        const yes: c_int = 1;
        setsockopt(
            socket.handle,
            std.c.IPPROTO.TCP,
            std.c.TCP.NODELAY,
            &std.mem.toBytes(yes),
        ) catch |err| {
            std.log.debug("failed to enable TCP_NODELAY: {t}", .{err});
        };
    }
    pub fn setUdpDscp(socket: Io.net.Socket) void {
        const lvl: c_int = 46 << 2;
        setsockopt(
            socket.handle,
            switch (socket.address) {
                .ip4 => std.os.linux.IPPROTO.IP,
                .ip6 => std.os.linux.IPPROTO.IPV6,
            },
            switch (socket.address) {
                .ip4 => std.os.linux.IP.TOS,
                .ip6 => std.os.linux.IPV6.TCLASS,
            },
            &std.mem.toBytes(lvl),
        ) catch |err| {
            std.log.err("unable to set UDP DSCP: {t}", .{err});
        };
    }

    pub const SetSockOptError = error{
        /// The socket is already connected, and a specified option cannot be set while the socket is connected.
        AlreadyConnected,

        /// The option is not supported by the protocol.
        InvalidProtocolOption,

        /// The send and receive timeout values are too big to fit into the timeout fields in the socket structure.
        TimeoutTooBig,

        /// Insufficient resources are available in the system to complete the call.
        SystemResources,

        /// Setting the socket option requires more elevated permissions.
        PermissionDenied,

        OperationUnsupported,
        NetworkDown,
        FileDescriptorNotASocket,
        SocketNotBound,
        NoDevice,

        Unexpected,
    };

    /// Set a socket's options.
    fn setsockopt(fd: Io.net.Socket.Handle, level: i32, optname: u32, opt: []const u8) SetSockOptError!void {
        const system = switch (builtin.target.os.tag) {
            else => @compileLog("TODO: implement setsockopt for this target"),
            .macos => std.c,
            .linux => std.os.linux,
            .windows => {
                const windows = std.os.windows;
                const rc = windows.ws2_32.setsockopt(fd, level, @intCast(optname), opt.ptr, @intCast(opt.len));
                if (rc == windows.ws2_32.SOCKET_ERROR) {
                    switch (windows.ws2_32.WSAGetLastError()) {
                        .NOTINITIALISED => unreachable,
                        .ENETDOWN => return error.NetworkDown,
                        .EFAULT => unreachable,
                        .ENOTSOCK => return error.FileDescriptorNotASocket,
                        .EINVAL => return error.SocketNotBound,
                        else => |err| return windows.unexpectedWSAError(err),
                    }
                }
                return;
            },
        };
        switch (system.errno(system.setsockopt(fd, level, optname, opt.ptr, @intCast(opt.len)))) {
            .SUCCESS => {},
            .BADF => unreachable, // always a race condition
            .NOTSOCK => unreachable, // always a race condition
            .INVAL => unreachable,
            .FAULT => unreachable,
            .DOM => return error.TimeoutTooBig,
            .ISCONN => return error.AlreadyConnected,
            .NOPROTOOPT => return error.InvalidProtocolOption,
            .NOMEM => return error.SystemResources,
            .NOBUFS => return error.SystemResources,
            .PERM => return error.PermissionDenied,
            .NODEV => return error.NoDevice,
            .OPNOTSUPP => return error.OperationUnsupported,
            else => |err| {
                if (builtin.mode == .Debug) {
                    std.debug.print("unexpected errno: {d}\n", .{@intFromEnum(err)});
                    std.debug.dumpCurrentStackTrace(.{});
                }
                return error.Unexpected;
            },
        }
    }
};

test {
    _ = Database;
}
