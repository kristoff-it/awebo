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
        std.debug.print("error: unknown command for tui resource: '{s}'\n", .{raw_subcmd});
        exitHelp(1);
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => exitHelp(0),
        .run => return @import("tui/run.zig").run(io, gpa, it),
    }
}

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo tui COMMAND [ARGUMENTS]
        \\
        \\Initialize and run the awebo terminal client.
        \\
        \\Available commands:
        \\  run     Start the awebo terminal client.
        \\  help    Show this menu and exit.
        \\
        \\Use `awebo tui COMMAND --help` for command-specific help information.
        \\
        \\
    , .{});

    std.process.exit(status);
}
