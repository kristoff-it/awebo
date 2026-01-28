const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_write);

    var out: [4096]u8 = undefined;
    const pass_str = std.crypto.pwhash.argon2.strHash(cmd.password, .{
        .allocator = gpa,
        .params = .interactive_2id,
    }, &out, io) catch |err| {
        fatal("unable to hash user password: {t}", .{err});
    };

    db.conn.transaction() catch db.fatal(@src());
    if (cmd.invite_slug) |invite_slug| {
        var invite_status_row = db.conn.row(
            \\SELECT
            \\  CASE
            \\    WHEN NOT EXISTS (
            \\      SELECT 1
            \\      FROM invites
            \\      WHERE slug = $1
            \\        AND enabled = 1
            \\        AND (remaining IS NULL OR remaining != 0)
            // 0: Slug does not exist, invite is not enabled, or no usages are remaining
            \\    ) THEN 0
            \\
            \\    WHEN EXISTS (
            \\      SELECT 1
            \\      FROM invites
            \\      WHERE slug = $1
            \\        AND enabled = 1
            \\        AND expiry <= unixepoch()
            // 1: Slug exists and invite is enabled, but it is expired
            \\    ) THEN 1
            \\
            // 2: Slug exists, invite is enabled, and it is not expired
            \\    ELSE 2
            \\  END AS invite_status;
        , .{invite_slug}) catch db.fatal(@src());
        switch (invite_status_row.?.int(0)) {
            0 => fatal("invite does not exist with slug '{s}'", .{invite_slug}),
            // TODO: Respect invite expiration, after proper datetime handling is implemented
            1 => std.debug.print("NOTE: invite expired. ignoring\n", .{}),
            2 => {}, // Invite is valid
            else => unreachable,
        }

        // Create user row
        db.conn.exec(
            \\INSERT INTO users
            \\  (created,    updated,     invited_by,      power, handle, display_name, avatar)
            \\SELECT
            \\  unixepoch(), unixepoch(), invites.creator, $1,   $2,      $3,           NULL
            \\FROM invites
            \\WHERE slug = $4;
        , .{
            @intFromEnum(awebo.User.Power.user), // $1
            cmd.handle, // $2
            cmd.display_name, // $3
            invite_slug, // $4
        }) catch db.fatal(@src());

        // Create password for user
        db.conn.exec(
            \\INSERT INTO passwords
            \\  (id,                  updated,     ip,   pswd_hash)
            \\VALUES
            \\  (last_insert_rowid(), unixepoch(), NULL, $1)
            \\;
        , .{pass_str}) catch db.fatal(@src());

        // Decrement "remaining" for invite (if it is not NULL)
        db.conn.exec(
            \\UPDATE invites
            \\SET remaining = remaining - 1
            \\WHERE slug = $1
            \\  AND remaining IS NOT NULL;
        , .{invite_slug}) catch db.fatal(@src());
    } else {
        // Create user row
        db.conn.exec(
            \\INSERT INTO users
            \\  (created,     updated,     power, handle, display_name, avatar)
            \\VALUES
            \\  (unixepoch(), unixepoch(), $1,   $2,      $3,           NULL)
            \\;
        , .{
            @intFromEnum(awebo.User.Power.user), // $1
            cmd.handle, // $2
            cmd.display_name, // $3
        }) catch db.fatal(@src());

        // Create password for user
        db.conn.exec(
            \\INSERT INTO passwords
            \\  (id,                  updated,     ip,   pswd_hash)
            \\VALUES
            \\  (last_insert_rowid(), unixepoch(), NULL, $1)
            \\;
        , .{pass_str}) catch db.fatal(@src());
    }
    db.conn.commit() catch db.fatal(@src());

    std.debug.print("Created new user @{s} \"{s}\"", .{ cmd.handle, cmd.display_name });
    if (cmd.invite_slug) |slug| std.debug.print(" using invite \"{s}\"", .{slug});
    std.debug.print("\n", .{});
}

const Command = struct {
    handle: []const u8,
    password: []const u8,
    display_name: []const u8,
    invite_slug: ?[]const u8,
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var handle: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var display_name: ?[]const u8 = null;
        var invite_slug: ?[]const u8 = null;
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
            } else if (eql(u8, arg, "--display-name")) {
                if (display_name != null) fatal("duplicate --display-name flag", .{});
                display_name = it.next() orelse fatal("missing value for --display-name", .{});
            } else if (eql(u8, arg, "--invite-slug")) {
                if (invite_slug != null) fatal("duplicate --invite-slug flag", .{});
                invite_slug = it.next() orelse fatal("missing value for --invite-slug", .{});
            } else if (eql(u8, arg, "--db-path")) {
                if (db_path != null) fatal("duplicate --db-path flag", .{});
                db_path = it.next() orelse fatal("missing value for --db-path", .{});
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
            .invite_slug = invite_slug,
            .db_path = db_path orelse "awebo.db",
        };
    }
};

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server user add REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Add a new user.
        \\
        \\Required arguments:
        \\ --handle HANDLE            User's new '@handle'
        \\ --password PASSWORD        User password
        \\
        \\Optional arguments:
        \\ --display-name NAME        User's display name, defaults to the handle value.
        \\ --invite-slug INVITE_SLUG  Use an invite to create the user.
        \\ --db-path DB_PATH          Path where to find the SQLite database.
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
