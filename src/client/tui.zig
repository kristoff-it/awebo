const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Subcommand = enum {
    run,
    help,
    @"--help",
    @"-h",
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const raw_subcmd = it.next() orelse "run";

    const subcmd = std.meta.stringToEnum(Subcommand, raw_subcmd) orelse {
        std.debug.print("unknown command '{s}' for tui resource\n", .{raw_subcmd});
        fatalHelp();
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => fatalHelp(),
        .run => return @import("tui/run.zig").run(io, gpa, it),
    }
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo tui COMMAND [ARGUMENTS]
        \\
        \\Initialize and run the awebo terminal client.
        \\
        \\Available commands:
        \\  run       Start the awebo terminal client.
        \\  help      Show this menu and exit.
        \\
        \\Use `awebo tui COMMAND --help` for command-specific help information.
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
