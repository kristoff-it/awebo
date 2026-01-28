const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Subcommand = enum {
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
        std.debug.print("missing command for invite resource\n", .{});
        fatalHelp();
    };

    const subcmd = std.meta.stringToEnum(Subcommand, raw_subcmd) orelse {
        std.debug.print("unknown command '{s}' for invite resource\n", .{raw_subcmd});
        fatalHelp();
    };

    switch (subcmd) {
        .add => @import("invite/add.zig").run(io, gpa, it),
        .edit => @import("invite/edit.zig").run(io, gpa, it),
        .list => @import("invite/list.zig").run(io, gpa, it),
        .show => @import("invite/show.zig").run(io, gpa, it),
        inline .delete => |subcommand| @panic("TODO: invite " ++ @tagName(subcommand)),
        .help, .@"-h", .@"--help" => fatalHelp(),
    }
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server invite COMMAND [ARGUMENTS]
        \\
        \\Manage invites.
        \\
        \\Available commands:
        \\  add       Add a new invite
        \\  edit      Edit an invite
        \\  delete    Delete an invite
        \\  list      List invite
        \\  show      Show an invite
        \\  help      Show this menu and exit
        \\
        \\Use `awebo-server invite COMMAND --help` for command-specific help information.
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
