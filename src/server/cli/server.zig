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
    const raw_subcmd = it.next() orelse fatalHelp();

    const subcmd = std.meta.stringToEnum(Subcommand, raw_subcmd) orelse {
        std.debug.print("unknown command '{s}' for user resource\n", .{raw_subcmd});
        fatalHelp();
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => fatalHelp(),
        .init => return init_cmd.run(io, gpa, it),
        .run => return run_cmd.run(io, gpa, it),
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

test {
    _ = run_cmd;
    _ = init_cmd;
}
