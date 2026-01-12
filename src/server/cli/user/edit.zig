const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Database = @import("../../Database.zig");
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub fn run(gpa: Allocator, it: *std.process.ArgIterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_write);

    db.conn.transaction() catch db.fatal(@src());

    if (cmd.handle) |handle| {
        db.conn.exec("UPDATE users SET handle = ? WHERE id = ?", .{ handle, cmd.user_id }) catch db.fatal(@src());
    }

    if (cmd.password) |password| {
        var out: [4096]u8 = undefined;
        const pswd_hash = std.crypto.pwhash.argon2.strHash(password, .{
            .allocator = gpa,
            .params = .interactive_2id,
        }, &out) catch |err| {
            fatal("unable to hash user password: {t}", .{err});
        };
        db.conn.exec("UPDATE users SET pswd_hash = ? WHERE id = ?", .{ pswd_hash, cmd.user_id }) catch db.fatal(@src());
    }

    if (cmd.display_name) |display_name| {
        db.conn.exec("UPDATE users SET display_name = ? WHERE id = ?", .{ display_name, cmd.user_id }) catch db.fatal(@src());
    }

    db.conn.commit() catch db.fatal(@src());
}

const Command = struct {
    user_id: []const u8, // string representing a number
    db_path: [:0]const u8,

    /// Editing arguments, at least one must be specified
    handle: ?[]const u8,
    password: ?[]const u8,
    display_name: ?[]const u8,

    fn parse(it: *std.process.ArgIterator) Command {
        var handle: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var display_name: ?[]const u8 = null;
        var db_path: ?[:0]const u8 = null;

        const user_id = it.next() orelse fatalHelp();

        const eql = std.mem.eql;
        while (it.next()) |arg| {
            if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) fatalHelp();
            if (eql(u8, arg, "--handle")) {
                if (handle != null) fatal("duplicate --handle flag", .{});
                handle = it.next() orelse fatal("missing value for --handle", .{});
            } else if (eql(u8, arg, "--password")) {
                if (password != null) fatal("duplicate --password flag", .{});
                password = it.next() orelse fatal("missing value for --password", .{});
            } else if (eql(u8, arg, "--display-name")) {
                if (display_name != null) fatal("duplicate --display-name flag", .{});
                display_name = it.next() orelse fatal("missing value for --display-name", .{});
            } else if (eql(u8, arg, "--db_path")) {
                if (db_path != null) fatal("duplicate --db_path flag", .{});
                db_path = it.next() orelse fatal("missing value for --db_path", .{});
            } else {
                fatal("unknown argument '{s}'", .{arg});
            }
        }

        const cmd: Command = .{
            .user_id = user_id,
            .handle = handle,
            .password = password,
            .display_name = display_name,
            .db_path = db_path orelse "awebo.db",
        };

        // at least one user editing argument must be specified
        inline for (@typeInfo(Command).@"struct".fields[2..]) |f| {
            if (@field(cmd, f.name) != null) return cmd;
        }

        fatal("at least one user editing argument must be specified", .{});
    }
};

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server user edit USER_ID EDIT_ARGS [OPTIONAL_ARGS]
        \\
        \\Edit a user.
        \\
        \\User edit arguments (at least one must be specified):
        \\ --handle HANDLE       Change the user's @handle (user will be logged out)
        \\ --password password   Change the user's password (user will be logged out)
        \\ --display-name        Change the user's display name
        \\
        \\Optional arguments:
        \\ --db-path DB_PATH     Path to the SQLite database to be used.
        \\                       Defaults to 'awebo.db'.
        \\ --help, -h            Show this menu and exit.
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}
