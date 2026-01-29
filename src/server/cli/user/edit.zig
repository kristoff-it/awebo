const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const Query = Database.Query;
const cli = @import("../../../cli.zig");

const log = std.log.scoped(.db);

const Queries = struct {
    update_password: Query(
        \\UPDATE passwords
        \\SET
        \\    updated = unixepoch(),
        \\    hash = ?2,
        \\    ip = ?3
        \\WHERE handle = (SELECT handle FROM users WHERE id = ?1);
    , .{
        .kind = .exec,
        .args = struct {
            id: awebo.User.Id,
            hash: []const u8,
            ip: ?[]const u8,
        },
    }),
    update_user: Query(std.fmt.comptimePrint(
        \\UPDATE users 
        \\SET 
        \\    handle = COALESCE(?3, handle),
        \\    display_name = COALESCE(?4, display_name),
        \\    update_uid = ({s})
        \\WHERE id = ?1;
    , .{@FieldType(Database.CommonQueries, "select_max_uid").sql}), .{
        .kind = .exec,
        .args = struct {
            id: awebo.User.Id,
            // update_uid: u64,
            handle: ?[]const u8,
            display_name: ?[]const u8,
        },
    }),
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_write);
    defer db.close();

    const qs = db.initQueries(Queries);
    defer db.deinitQueries(Queries, &qs);

    db.conn.transaction() catch db.fatal(@src());

    if (cmd.password) |password| {
        var out: [4096]u8 = undefined;
        const hash = std.crypto.pwhash.argon2.strHash(password, .{
            .allocator = gpa,
            .params = .interactive_2id,
        }, &out, io) catch |err| {
            cli.fatal("unable to hash user password: {t}", .{err});
        };

        qs.update_password.run(db, .{
            .id = cmd.user_id,
            .hash = hash,
            .ip = null,
        });
    }

    qs.update_user.run(db, .{
        .id = cmd.user_id,
        // .update_uid = latest_uid + 1,
        .handle = cmd.handle,
        .display_name = cmd.display_name,
    });

    db.conn.commit() catch db.fatal(@src());
}

const Command = struct {
    user_id: awebo.User.Id,
    db_path: [:0]const u8,

    /// Editing arguments, at least one must be specified
    handle: ?[]const u8,
    password: ?[]const u8,
    display_name: ?[]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var handle: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var display_name: ?[]const u8 = null;
        var db_path: ?[:0]const u8 = null;

        const user_id = blk: {
            const str = it.next() orelse {
                std.debug.print("error: missing USER_ID for edit\n", .{});
                exitHelp(1);
            };
            break :blk std.fmt.parseInt(awebo.User.Id, str, 10) catch {
                cli.fatal("unable to parse user id as a number", .{});
            };
        };

        const eql = std.mem.eql;
        while (it.next()) |arg| {
            if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) exitHelp(1);
            if (eql(u8, arg, "--handle")) {
                if (handle != null) cli.fatal("duplicate --handle flag", .{});
                handle = it.next() orelse cli.fatal("missing value for --handle", .{});
            } else if (eql(u8, arg, "--password")) {
                if (password != null) cli.fatal("duplicate --password flag", .{});
                password = it.next() orelse cli.fatal("missing value for --password", .{});
            } else if (eql(u8, arg, "--display-name")) {
                if (display_name != null) cli.fatal("duplicate --display-name flag", .{});
                display_name = it.next() orelse cli.fatal("missing value for --display-name", .{});
            } else if (eql(u8, arg, "--db-path")) {
                if (db_path != null) cli.fatal("duplicate --db-path flag", .{});
                db_path = it.next() orelse cli.fatal("missing value for --db-path", .{});
            } else {
                cli.fatal("unknown argument '{s}'", .{arg});
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

        cli.fatal("at least one user editing argument must be specified", .{});
    }
};

fn exitHelp(status: u8) noreturn {
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

    std.process.exit(status);
}

test "user edit queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
