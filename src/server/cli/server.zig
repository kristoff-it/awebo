const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const awebo = @import("../../awebo.zig");
const Database = awebo.Database;

const run_cmd = @import("server/run.zig");
const init_cmd = @import("server/init.zig");

const Subcommand = enum {
    init,
    run,
    help,
    @"--help",
    @"-h",
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const subcmd_arg = it.next() orelse {
        std.debug.print("error: missing subcommand for server\n", .{});
        exitHelp(1);
    };

    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_arg) orelse {
        std.debug.print("error: unknown subcommand for server: '{s}'\n", .{subcmd_arg});
        exitHelp(1);
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => exitHelp(0),
        .init => return init_cmd.run(io, gpa, it),
        .run => return run_cmd.run(io, gpa, it),
    }
}

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server server COMMAND [ARGUMENTS]
        \\
        \\Initialize and run a server, manage its settings.
        \\
        \\Available commands:
        \\  init    Create a SQLite database for a fresh new Awebo server.
        \\  run     Start the Awebo server.
        \\  help    Show this menu and exit.
        \\
        \\Use `awebo-server server COMMAND --help` for command-specific help information.
        \\
        \\
    , .{});

    std.process.exit(status);
}

test {
    _ = run_cmd;
    _ = init_cmd;
}
