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
    const raw_subcmd = it.next() orelse {
        std.debug.print("missing command for user resource\n", .{});
        fatalHelp();
    };

    const subcmd = std.meta.stringToEnum(Subcommand, raw_subcmd) orelse {
        std.debug.print("unknown command '{s}' for user resource\n", .{raw_subcmd});
        fatalHelp();
    };

    switch (subcmd) {
        .add => add.run(io, gpa, it),
        .edit => edit.run(io, gpa, it),
        .list => list.run(io, gpa, it),
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

test {
    _ = add;
    _ = edit;
    _ = delete;
    _ = list;
}
