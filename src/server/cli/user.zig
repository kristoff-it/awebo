const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const Subcommand = enum {
    ban,
    add,
    edit,
    delete,
    list,
    show,
    help,
    @"-h",
    @"--help",
};
pub fn run(gpa: Allocator, it: *std.process.ArgIterator) void {
    const raw_subcmd = it.next() orelse {
        std.debug.print("missing command for user resource\n", .{});
        fatalHelp();
    };

    const subcmd = std.meta.stringToEnum(Subcommand, raw_subcmd) orelse {
        std.debug.print("unknown command '{s}' for user resource\n", .{raw_subcmd});
        fatalHelp();
    };

    switch (subcmd) {
        .add => @import("user/add.zig").run(gpa, it),
        .edit => @import("user/edit.zig").run(gpa, it),
        .list => @import("user/list.zig").run(gpa, it),
        .ban,
        .delete,
        .show,
        => @panic("TODO"),
        .help, .@"-h", .@"--help" => fatalHelp(),
    }
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server user COMMAND [ARGUMENTS]
        \\
        \\Ban, add, edit, delete, list, show users.
        \\
        \\Available commands:
        \\  ban       Ban an existing user
        \\  add       Add a new user
        \\  edit      Edit a user
        \\  delete    Delete a user
        \\  list      List users
        \\  show      Show a user
        \\  help      Show this menu and exit.
        \\
        \\Use `awebo-server user COMMAND --help` for command-specific help information.
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
