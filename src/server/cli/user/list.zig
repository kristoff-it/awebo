const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const cli = @import("../../../cli.zig");
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub const Queries = struct {
    select_users: @FieldType(Database.CommonQueries, "select_users"),
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_only);
    const qs = db.initQueries(Queries);

    var rows = qs.select_users.run(db, .{});

    std.debug.print("id\tupdate_uid\thandle\tdisplay_name\t\n\n", .{});
    while (rows.next()) |row| {
        std.debug.print("{}\t{}\t{s}\t{s}\n", .{
            row.get(.id),
            row.get(.update_uid),
            row.textNoDupe(.handle),
            row.textNoDupe(.display_name),
        });
    }
}

const Command = struct {
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var db_path: ?[:0]const u8 = null;

        var args: cli.Args = .init(it);

        while (args.peek()) |current_arg| {
            if (args.help()) exitHelp(0);
            if (args.option("db-path")) |db_path_opt| {
                db_path = db_path_opt;
            } else {
                cli.fatal("unknown argument '{s}'", .{current_arg});
            }
        }

        return .{ .db_path = db_path orelse "awebo.db" };
    }
};

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server user list [OPTIONAL_ARGS]
        \\
        \\List users.
        \\
        \\Optional arguments:
        \\  --db-path DB_PATH    Path to the SQLite database to be used.
        \\                       Defaults to 'awebo.db'.
        \\  --help, -h           Show this menu and exit.
        \\
    , .{});

    std.process.exit(status);
}

test "user list queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
