const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const awebo = @import("../../../awebo.zig");
const cli = @import("../../../cli.zig");

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;
    if (it.next()) |arg| {
        const eql = std.mem.eql;
        if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) exitHelp(0);

        cli.fatal("unknown argument: '{s}'\n\n", .{arg});
    }

    std.debug.print("-- server-level permissions --\n\n", .{});
    inline for (@typeInfo(awebo.permissions.Server).@"struct".fields) |f| {
        std.debug.print("- {s}, default: {any} ({s})\n", .{ f.name, f.defaultValue().?, @typeName(f.type) });
        const desc = @field(awebo.permissions.Server.descriptions, f.name);
        var line_it = std.mem.tokenizeScalar(u8, desc, '\n');
        while (line_it.next()) |line| {
            std.debug.print("\t{s}\n", .{line});
        }

        std.debug.print("\n", .{});
    }
}

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server role permissions [--help]
        \\
        \\List permissions that can be granted or denied to a role.
        \\
        \\Optional arguments:
        \\ --help, -h                 Show this menu and exit.
        \\
    , .{});

    std.process.exit(status);
}
