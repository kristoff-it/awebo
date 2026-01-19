const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Core = @import("../../Core.zig");
const persistence = @import("../../Core/persistence.zig");

pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map, it: *std.process.Args.Iterator) void {
    var identity_arg: ?[]const u8 = null;
    const eql = std.mem.eql;
    while (it.next()) |arg| {
        if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) fatalHelp();
        if (eql(u8, arg, "--identity")) {
            if (identity_arg != null) fatal("identity --identity flag", .{});
            identity_arg = it.next() orelse fatal("missing value for --name", .{});
        } else {
            fatal("unknown argument '{s}'", .{arg});
        }
    }
    const identity = identity_arg orelse {
        std.debug.print("fatal error: missing --identity\n", .{});
        fatalHelp();
    };

    var core: Core = .init(gpa, io, environ, noopRefresh, &.{});
    defer core.deinit();

    persistence.load(&core) catch |e| {
        std.log.err("failed to load configuration: {t} \n", .{e});
        return;
    };

    for (core.hosts.items.values()) |host| {
        const client = host.client;
        if (!eql(u8, client.identity, identity)) continue;
        std.debug.print("identity: {s}\n", .{client.identity});
        std.debug.print("username: {s}\n", .{client.username});
        std.debug.print("password: {s}\n", .{client.password});
        return;
    }
    std.debug.print("server '{s}' not found\n", .{identity});
}

pub fn noopRefresh(_: *Core, _: std.builtin.SourceLocation, _: ?u64) void {}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo server show REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Show the configuration for a server.
        \\
        \\Required arguments:
        \\ --name NAME                Server name to show
        \\
        \\Optional arguments:
        \\ --help, -h                 Show this menu and exit.
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}
