const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Database = @import("../../Database.zig");
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_only);

    var rows = db.rows("SELECT id, handle, display_name FROM users", .{}) catch db.fatal(@src());
    defer rows.deinit();

    // var wbuf: [4096]u8 = undefined;
    // var writer_state = Io.File.stdout().writer(&wbuf);
    // const w = &writer_state.interface;

    std.debug.print("id\thandle\tdisplay_name\t\n\n", .{});
    while (rows.next()) |row| {
        std.debug.print("{}\t{s}\t{s}\n", .{
            row.int(.id),
            row.textNoDupe(.handle),
            row.textNoDupe(.display_name),
        });
    }

    // try w.flush();
}

const Command = struct {
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var db_path: ?[:0]const u8 = null;

        const eql = std.mem.eql;
        while (it.next()) |arg| {
            if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) fatalHelp();
            if (eql(u8, arg, "--db_path")) {
                if (db_path != null) fatal("duplicate --db_path flag", .{});
                db_path = it.next() orelse fatal("missing value for --db_path", .{});
            } else {
                fatal("unknown argument '{s}'", .{arg});
            }
        }

        return .{ .db_path = db_path orelse "awebo.db" };
    }
};

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server user list [OPTIONAL_ARGS]
        \\
        \\List users.
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
