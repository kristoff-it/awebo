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
    select_invites: Query(
        \\SELECT slug, expiry, creator, handle, enabled, remaining
        \\FROM invites
        \\JOIN users
        \\ON users.id = invites.creator;
    , .{
        .kind = .rows,
        .cols = struct {
            slug: []const u8,
            expiry: u64,
            creator: awebo.User.Id,
            handle: []const u8,
            enabled: bool,
            remaining: ?u64,
        },
    }),
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_only);
    defer db.close();

    const qs = db.initQueries(Queries);
    defer db.deinitQueries(Queries, &qs);

    var rows = qs.select_invites.run(db, .{});
    var no_invites = true;
    while (rows.next()) |r| {
        no_invites = false;
        std.debug.print(
            \\Invite ({s}):
            \\  expiry: @{d}
            \\  creator: {s} ({d})
            \\  enabled: {}
            \\  remaining: {?d}
            \\
            \\
        , .{
            r.textNoDupe(.slug),
            r.get(.expiry),
            r.textNoDupe(.handle), // Creator handle
            r.get(.creator),
            r.get(.enabled),
            r.get(.remaining),
        });
    }
    if (no_invites) {
        std.debug.print("There are no invites (use `awebo-server invite add` to create one)\n", .{});
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
        \\Usage: awebo-server invite list [OPTIONAL_ARGS]
        \\
        \\List invites.
        \\
        \\Optional arguments:
        \\  --db-path DB_PATH    Path to the SQLite database to be used.
        \\                       Defaults to 'awebo.db'.
        \\  --help, -h           Show this menu and exit.
        \\
    , .{});

    std.process.exit(status);
}

test "invite list queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
