const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
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

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const subcmd_arg = it.next() orelse {
        std.debug.print("error: missing subcommand for role resource\n", .{});
        exitHelp(1);
    };

    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_arg) orelse {
        std.debug.print("error: unknown subcommand for role resource: '{s}'\n", .{subcmd_arg});
        exitHelp(1);
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => exitHelp(0),
        .add => @import("role/add.zig").run(io, gpa, it),
        .edit => @import("role/edit.zig").run(io, gpa, it),
        .list => @import("role/list.zig").run(io, gpa, it),
        .permissions => @import("role/permissions.zig").run(io, gpa, it),
        .delete,
        .show,
        => @panic("TODO"),
    }
}

fn exitHelp(status: u8) noreturn {
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

    std.process.exit(status);
}
