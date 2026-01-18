const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Core = @import("../../Core.zig");
const persistence = @import("../../Core/persistence.zig");

pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map, it: *std.process.Args.Iterator) void {
    var identity_arg: ?[]const u8 = null;
    var username_arg: ?[]const u8 = null;
    var password_arg: ?[]const u8 = null;

    const eql = std.mem.eql;
    while (it.next()) |arg| {
        if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) fatalHelp();
        if (eql(u8, arg, "--username")) {
            if (username_arg != null) fatal("duplicate --username flag", .{});
            username_arg = it.next() orelse fatal("missing value for --username", .{});
        } else if (eql(u8, arg, "--password")) {
            if (password_arg != null) fatal("duplicate --password flag", .{});
            password_arg = it.next() orelse fatal("missing value for --password", .{});
        } else if (eql(u8, arg, "--identity")) {
            if (identity_arg != null) fatal("duplicate --identity flag", .{});
            identity_arg = it.next() orelse fatal("missing value for --identity", .{});
        } else {
            fatal("unknown argument '{s}'", .{arg});
        }
    }

    const identity = identity_arg orelse fatal("missing --identity", .{});
    const username = username_arg orelse fatal("missing --username", .{});
    const password = password_arg orelse fatal("missing --password", .{});

    var core: Core = .init(gpa, io, environ, noopRefresh, &.{});
    defer core.deinit();

    persistence.load(&core) catch |e| {
        std.log.err("failed to load configuration: {t} \n", .{e});
        return;
    };

    _ = core.hosts.add(&core, identity, username, password) catch |e| {
        std.log.err("failed to add host: {t} \n", .{e});
        return;
    };
}

pub fn noopRefresh(_: *Core, _: std.builtin.SourceLocation, _: ?u64) void {}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo server add REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Add a server to the configuration.
        \\
        \\Required arguments:
        \\ --identity IDENTITY        Server identity to add
        \\ --username USERNAME        Server username
        \\ --password PASSWORD        Server password
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
