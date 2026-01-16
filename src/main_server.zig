const options = @import("options");
const builtin = @import("builtin");
const std = @import("std");
const process = std.process;
const Io = std.Io;

pub const Resource = enum {
    server,
    user,
    message,
    role,

    // resourceless commands
    version,
    help,
    @"--help",
    @"-h",
};

pub fn main(init: process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.skip();

    const resource = it.next() orelse {
        std.debug.print("fatal error: missing resource kind\n", .{});
        fatalHelp();
    };

    const resource_enum = std.meta.stringToEnum(Resource, resource) orelse {
        std.debug.print("fatal error: invalid resource '{s}'\n", .{resource});
        fatalHelp();
    };

    switch (resource_enum) {
        .version => exitVersion(),
        .help, .@"--help", .@"-h" => fatalHelp(),

        .role => @import("server/cli/role.zig").run(init.io, gpa, &it),
        .user => @import("server/cli/user.zig").run(init.io, gpa, &it),
        .message => @import("server/cli/message.zig").run(init.io, gpa, &it),
        .server => @import("server/cli/server.zig").run(init.io, gpa, &it),
    }
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server RESOURCE COMMAND [ARGUMENTS]
        \\
        \\Resources you can manage:
        \\
        \\  server    Initialize and run a server, manage its settings.
        \\  user      List, create, update, ban, delete users.
        \\  role      List, create, update, delete roles.
        \\
        \\Use `awebo-server RESOURCE help` for resource-specific help information.
        \\
        \\Resource-less commands:
        \\
        \\  version  Print the awebo-server version and exit
        \\  help     Show this menu and exit
        \\
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt, args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

fn exitVersion() noreturn {
    std.debug.print("{s}", .{options.version});
    std.process.exit(0);
}
