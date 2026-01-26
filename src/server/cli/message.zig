const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const awebo = @import("../../awebo.zig");
const Database = awebo.Database;

const Subcommand = enum {
    search,
    help,
    @"-h",
    @"--help",
};
pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;

    const raw_subcmd = it.next() orelse {
        std.debug.print("missing command for user resource\n", .{});
        fatalHelp();
    };

    const subcmd = std.meta.stringToEnum(Subcommand, raw_subcmd) orelse {
        std.debug.print("unknown command '{s}' for user resource\n", .{raw_subcmd});
        fatalHelp();
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => fatalHelp(),
        .search => {},
    }

    const query = it.next() orelse fatal("missing rearch term", .{});

    const db: Database = .init("awebo.db", .read_write);
    errdefer db.close();

    var rows = db.conn.rows(
        \\SELECT
        \\  messages_search.author,
        \\  users.handle,
        \\  messages_search.channel,
        \\  channels.name,
        \\  highlight(messages_search, 2, char(0x1b) || '[7m', char(0x1b) || '[27m')
        //messages_search.body
        \\FROM messages_search
        \\INNER JOIN users ON messages_search.author == users.id
        \\INNER JOIN channels ON messages_search.channel == channels.id
        \\WHERE body MATCH ?;
    , .{query}) catch db.fatal(@src());
    defer rows.deinit();

    while (rows.next()) |row| {
        std.debug.print("{s} ({}) - {s} ({})\n---\n{s}\n---\n\n", .{
            row.text(1),
            row.int(0),
            row.text(3),
            row.int(2),
            row.text(4),
        });
    }
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server message search QUERY
        \\
        \\Search messages.
        \\
        \\Available commands:
        \\  search    Search messages.
        \\  help      Show this menu and exit.
        \\
        \\Use `awebo user COMMAND --help` for command-specific help information.
        \\
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}
