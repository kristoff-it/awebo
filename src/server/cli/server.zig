const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const Database = @import("../Database.zig");

const Subcommand = enum {
    init,
    run,
    help,
    @"--help",
    @"-h",
};

pub fn run(gpa: Allocator, it: *std.process.ArgIterator) void {
    const raw_subcmd = it.next() orelse fatalHelp();

    const subcmd = std.meta.stringToEnum(Subcommand, raw_subcmd) orelse {
        std.debug.print("unknown command '{s}' for user resource\n", .{raw_subcmd});
        fatalHelp();
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => fatalHelp(),
        .init => return @import("server/init.zig").run(gpa, it),
        .run => return @import("server/run.zig").run(it),
    }
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server server COMMAND [ARGUMENTS]
        \\
        \\Initialize and run a server, manage its settings.
        \\
        \\Available commands:
        \\  init      Create a SQLite database for a fresh new Awebo server.
        \\  run       Start the Awebo server.
        \\  help      Show this menu and exit.
        \\
        \\Use `awebo-server server COMMAND --help` for command-specific help information.
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
