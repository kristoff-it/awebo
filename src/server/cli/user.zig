const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const add = @import("user/add.zig");
const edit = @import("user/edit.zig");
const delete = @import("user/delete.zig");
const list = @import("user/list.zig");

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

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const subcmd_arg = it.next() orelse {
        std.debug.print("error: missing subcommand for user resource\n", .{});
        exitHelp(1);
    };

    const subcmd = std.meta.stringToEnum(Subcommand, subcmd_arg) orelse {
        std.debug.print("error: unknown subcommand for user resource: '{s}'\n", .{subcmd_arg});
        exitHelp(1);
    };

    switch (subcmd) {
        .help, .@"-h", .@"--help" => exitHelp(0),
        .add => add.run(io, gpa, it),
        .edit => edit.run(io, gpa, it),
        .list => list.run(io, gpa, it),
        .ban,
        .delete,
        .show,
        => @panic("TODO"),
    }
}

fn exitHelp(status: u8) noreturn {
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

    std.process.exit(status);
}

test {
    _ = add;
    _ = edit;
    _ = delete;
    _ = list;
}
