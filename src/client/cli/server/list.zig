const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Core = @import("../../Core.zig");
const persistence = @import("../../Core/persistence.zig");
const cli = @import("../../../cli.zig");

pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map, it: *std.process.Args.Iterator) void {
    const eql = std.mem.eql;
    while (it.next()) |arg| {
        if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) exitHelp(0);
        cli.fatal("unknown argument '{s}'", .{arg});
    }

    var core: Core = .init(gpa, io, environ, noopRefresh, &.{});
    defer core.deinit();

    persistence.load(&core) catch |e| {
        std.log.err("failed to load configuration: {t}\n", .{e});
        return;
    };

    var count: usize = 0;
    for (core.hosts.items.values()) |host| {
        const client = host.client;
        std.debug.print("identity:{s} username:{s}\n", .{ client.identity, client.username });
        count += 1;
    }

    if (count > 0) {
        std.debug.print("{d} server{s}\n", .{ count, if (count == 1) "" else "s" });
    } else {
        std.debug.print("no servers configured\n", .{});
    }
}

pub fn noopRefresh(_: *Core, _: std.builtin.SourceLocation, _: ?u64) void {}

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo server list REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\List configured servers.
        \\
        \\Optional arguments:
        \\ --help, -h                 Show this menu and exit.
        \\
    , .{});

    std.process.exit(status);
}
