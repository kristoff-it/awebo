const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const Database = @import("../../Database.zig");
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub fn run(gpa: Allocator, it: *std.process.ArgIterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_write);

    var out: [4096]u8 = undefined;
    const pass_str = std.crypto.pwhash.argon2.strHash(cmd.password, .{
        .allocator = gpa,
        .params = .interactive_2id,
    }, &out) catch |err| {
        fatal("unable to hash user password: {t}", .{err});
    };

    const admin =
        \\INSERT INTO users (created, updated, handle, pswd_hash, display_name, avatar) VALUES
        \\  (unixepoch(), unixepoch(), $1, $2, $3, NULL)
        \\;
    ;
    db.conn.exec(admin, .{ cmd.handle, pass_str, cmd.display_name }) catch db.fatal(@src());
}

const Command = struct {
    handle: []const u8,
    password: []const u8,
    display_name: []const u8,
    db_path: [:0]const u8,

    fn parse(it: *std.process.ArgIterator) Command {
        var handle: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var display_name: ?[]const u8 = null;
        var db_path: ?[:0]const u8 = null;

        const eql = std.mem.eql;
        while (it.next()) |arg| {
            if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) fatalHelp();
            if (eql(u8, arg, "--handle")) {
                if (handle != null) fatal("duplicate --handle flag", .{});
                handle = it.next() orelse fatal("missing value for --handle", .{});
            } else if (eql(u8, arg, "--password")) {
                if (password != null) fatal("duplicate --password flag", .{});
                password = it.next() orelse fatal("missing value for --password", .{});
            } else if (eql(u8, arg, "--display_name")) {
                if (display_name != null) fatal("duplicate --display_name flag", .{});
                display_name = it.next() orelse fatal("missing value for --display_name", .{});
            } else if (eql(u8, arg, "--db_path")) {
                if (db_path != null) fatal("duplicate --db_path flag", .{});
                db_path = it.next() orelse fatal("missing value for --db_path", .{});
            } else {
                fatal("unknown argument '{s}'", .{arg});
            }
        }

        const h = handle orelse {
            std.debug.print("fatal error: missing --handle\n", .{});
            fatalHelp();
        };
        return .{
            .handle = h,
            .password = password orelse fatal("missing --password", .{}),
            .display_name = display_name orelse h,
            .db_path = db_path orelse "awebo.db",
        };
    }
};

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server role add REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Add a new role.
        \\
        \\Required arguments:
        \\ --name NAME                Role name
        \\
        \\Optional arguments:
        \\ --grant KEY [RESOURCE]     Grant a premission to this role.
        \\ --deny  KEY [RESOURCE]     Deny a premission to this role.
        \\ --db-path DB_PATH          Path where to place the generated SQLite database.
        \\                            Defaults to 'awebo.db'.
        \\ --help, -h                 Show this menu and exit.
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}
