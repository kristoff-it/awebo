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
    const subcmd_arg = it.next() orelse {
        std.debug.print("error: missing subcommand for server resource\n", .{});
        exitHelp(1);
    };

    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_arg) orelse {
        std.debug.print("error: unknown subcommand for server resource: '{s}'\n", .{subcmd_arg});
        exitHelp(1);
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => exitHelp(0),
        .add => return @import("server/add.zig").run(io, gpa, environ, it),
        .remove => @panic("not implemented"), //return @import("server/add.zig").run(io, gpa, it),
        .list => return @import("server/list.zig").run(io, gpa, environ, it),
        .show => return @import("server/show.zig").run(io, gpa, environ, it),
    }
}

fn exitHelp(status: u8) noreturn {
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

    std.process.exit(status);
}
