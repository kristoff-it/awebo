const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;

const Subcommand = enum {
    add,
    edit,
    delete,
    list,
    permissions,
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
        .add => @import("role/add.zig").run(gpa, it),
        .edit => @import("role/edit.zig").run(gpa, it),
        .list => @import("role/list.zig").run(gpa, it),
        .permissions => @import("role/permissions.zig").run(gpa, it),
        .delete,
        .show,
        => @panic("TODO"),
        .help, .@"-h", .@"--help" => fatalHelp(),
    }
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server role COMMAND [ARGUMENTS]
        \\
        \\Add, edit, delete, list, show roles.
        \\Use command `permissions` to see which permissions can be granted or denied to a role.
        \\
        \\Available commands:
        \\  add                Add a new role
        \\  edit               Edit a role
        \\  delete             Delete a role
        \\  list               List roles
        \\  permissions        List all permissions
        \\  show               Show a role
        \\  help               Show this menu and exit
        \\
        \\Use awebo-server role COMMAND --help` for command-specific information.
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
