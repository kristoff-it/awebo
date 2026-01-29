const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const Query = Database.Query;
const cli = @import("../../../cli.zig");

const log = std.log.scoped(.db);

pub const Queries = struct {
    select_max_uid: @FieldType(Database.CommonQueries, "select_max_uid"),
    insert_user: @FieldType(Database.CommonQueries, "insert_user"),
    insert_password: Query(
        \\INSERT INTO passwords(handle, updated, ip, hash) VALUES
        \\  (?, unixepoch(), NULL, ?)
        \\;
    , .{
        .kind = .exec,
        .args = struct {
            handle: []const u8,
            hash: []const u8,
        },
    }),
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_write);
    defer db.close();

    const qs = db.initQueries(Queries);
    defer db.deinitQueries(Queries, &qs);

    var out: [4096]u8 = undefined;
    const hash = std.crypto.pwhash.argon2.strHash(cmd.password, .{
        .allocator = gpa,
        .params = .interactive_2id,
    }, &out, io) catch |err| {
        cli.fatal("unable to hash user password: {t}", .{err});
    };

    db.conn.transaction() catch db.fatal(@src());

    const max_uid = qs.select_max_uid.run(db, .{}).?.get(.max_uid);

    _ = qs.insert_user.run(db, .{
        .created = 0,
        .update_uid = max_uid + 1,
        .invited_by = null,
        .power = .user,
        .handle = cmd.handle,
        .display_name = cmd.display_name,
    }).?;

    qs.insert_password.run(db, .{
        .handle = cmd.handle,
        .hash = hash,
    });

    db.conn.commit() catch db.fatal(@src());

    std.debug.print("Created new user @{s} \"{s}\"\n", .{
        cmd.handle,
        cmd.display_name,
    });
}

const Command = struct {
    handle: []const u8,
    password: []const u8,
    display_name: []const u8,
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var handle: ?[]const u8 = null;
        var password: ?[]const u8 = null;
        var display_name: ?[]const u8 = null;
        var db_path: ?[:0]const u8 = null;

        var args: cli.Args = .init(it);

        while (args.peek()) |current_arg| {
            if (args.help()) exitHelp(0);
            if (args.option("handle")) |handle_opt| {
                handle = handle_opt;
            } else if (args.option("password")) |password_opt| {
                password = password_opt;
            } else if (args.option("display-name")) |display_name_opq| {
                display_name = display_name_opq;
            } else if (args.option("db-path")) |db_path_opq| {
                db_path = db_path_opq;
            } else {
                cli.fatal("unknown argument '{s}'", .{current_arg});
            }
        }

        const h = handle orelse {
            std.debug.print("error: missing --handle\n", .{});
            exitHelp(1);
        };
        return .{
            .handle = h,
            .password = password orelse cli.fatal("missing --password", .{}),
            .display_name = display_name orelse h,
            .db_path = db_path orelse "awebo.db",
        };
    }
};

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server user add REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Add a new user.
        \\
        \\Required arguments:
        \\  --handle HANDLE        User's new '@handle'
        \\  --password PASSWORD    User password
        \\
        \\Optional arguments:
        \\  --display-name NAME    User's display name, defaults to the handle value.
        \\  --db-path DB_PATH      Path where to find the SQLite database.
        \\                         Defaults to 'awebo.db'.
        \\  --help, -h             Show this menu and exit.
        \\
    , .{});

    std.process.exit(status);
}

test "user add queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
