const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const cli = @import("../../../cli.zig");

const log = std.log.scoped(.db);

const Queries = struct {};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_write);
    defer db.close();
    const qs = db.initQueries(Queries);
    defer db.deinitQueries(Queries, &qs);

    _ = io;
    _ = gpa;
}

const Command = struct {
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        _ = it;
        @panic("TODO");
    }
};

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server role add REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Add a new role.
        \\
        \\Required arguments:
        \\  --name NAME    Role name
        \\
        \\Optional arguments:
        \\  --grant KEY [RESOURCE]    Grant a premission to this role.
        \\  --deny  KEY [RESOURCE]    Deny a premission to this role.
        \\  --db-path DB_PATH         Path where to place the generated SQLite database.
        \\                            Defaults to 'awebo.db'.
        \\  --help, -h                Show this menu and exit.
        \\
    , .{});

    std.process.exit(status);
}

test "role add queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
