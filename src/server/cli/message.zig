const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const awebo = @import("../../awebo.zig");
const Database = awebo.Database;
const Query = Database.Query;

const cli = @import("../../cli.zig");

const Subcommand = enum {
    search,
    help,
    @"-h",
    @"--help",
};

const Queries = struct {
    search: Query(
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
    , .{
        .kind = .rows,
        .cols = struct {
            author: awebo.User.Id,
            handle: []const u8,
            channel_id: awebo.Channel.Id,
            channel_name: []const u8,
            hl_text: []const u8,
        },
        .args = struct { query: []const u8 },
    }),
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;

    const subcmd_arg = it.next() orelse {
        std.debug.print("error: missing subcommand for message resource\n", .{});
        exitHelp(1);
    };

    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_arg) orelse {
        std.debug.print("error: unknown subcommand for message resource: '{s}'\n", .{subcmd_arg});
        exitHelp(1);
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => exitHelp(0),
        .search => {},
    }

    const query = it.next() orelse cli.fatal("missing search term", .{});

    const db: Database = .init("awebo.db", .read_write);
    defer db.close();
    const qs = db.initQueries(Queries);

    var rows = qs.search.run(db, .{ .query = query });
    while (rows.next()) |r| {
        std.debug.print("{s} ({}) - {s} ({})\n---\n{s}\n---\n\n", .{
            r.textNoDupe(.handle),
            r.get(.author),
            r.textNoDupe(.channel_name),
            r.get(.channel_id),
            r.textNoDupe(.hl_text),
        });
    }
}

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server message search QUERY
        \\
        \\Search messages.
        \\
        \\Available commands:
        \\  search    Search messages.
        \\  help      Show this menu and exit.
        \\
        \\Use `awebo-server message COMMAND --help` for command-specific help information.
        \\
        \\
    , .{});

    std.process.exit(status);
}

test "message search queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
