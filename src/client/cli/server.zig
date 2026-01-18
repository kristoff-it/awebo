const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Subcommand = enum {
    add,
    remove,
    list,
    show,
    help,
    @"--help",
    @"-h",
};

pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map, it: *std.process.Args.Iterator) void {
    const raw_subcmd = it.next() orelse fatalHelp();

    const subcmd = std.meta.stringToEnum(Subcommand, raw_subcmd) orelse {
        std.debug.print("unknown command '{s}' for user resource\n", .{raw_subcmd});
        fatalHelp();
    };

    switch (subcmd) {
        .add => return @import("server/add.zig").run(io, gpa, it),
        .remove => @panic("not implemented"), //return @import("server/add.zig").run(io, gpa, it),
        .list => @panic("not implemented"), //return @import("server/add.zig").run(io, gpa, it),
        .show => return @import("server/show.zig").run(io, gpa, environ, it),
        .help, .@"-h", .@"--help" => fatalHelp(),
    }
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo server COMMAND [ARGUMENTS]
        \\
        \\Manage awebo server settings.
        \\
        \\Available commands:
        \\  add       Add a server.
        \\  remove    Remove a server.
        \\  list      List configured servers.
        \\  show      Show details of a configured server.
        \\  help      Show this menu and exit.
        \\
        \\Use `awebo server COMMAND --help` for command-specific help information.
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
