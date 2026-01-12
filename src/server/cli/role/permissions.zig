const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const awebo = @import("../../../awebo.zig");

pub fn run(gpa: Allocator, it: *std.process.ArgIterator) void {
    _ = gpa;
    if (it.next()) |arg| {
        if (!std.mem.eql(u8, arg, "--help") and !std.mem.eql(u8, arg, "-h"))
            std.debug.print("unknown argument: '{s}'\n\n", .{arg});
        fatalHelp();
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

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server role permissions [--help]
        \\
        \\List permissions that can be granted or denied to a role.
        \\
        \\Optional arguments:
        \\ --help, -h                 Show this menu and exit.
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}
