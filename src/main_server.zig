const options = @import("options");
const builtin = @import("builtin");
const std = @import("std");
const process = std.process;
const Io = std.Io;

const server = @import("server/cli/server.zig");
const message = @import("server/cli/message.zig");
const invite = @import("server/cli/invite.zig");
const user = @import("server/cli/user.zig");
const role = @import("server/cli/role.zig");

pub const Resource = enum {
    server,
    user,
    message,
    role,
    invite,

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

    const resource_arg = it.next() orelse {
        std.debug.print("error: missing resource kind\n", .{});
        exitHelp(1);
    };

    const resource = std.meta.stringToEnum(Resource, resource_arg) orelse {
        std.debug.print("error: invalid resource '{s}'\n", .{resource_arg});
        exitHelp(1);
    };

    switch (resource) {
        .version => exitVersion(),
        .help, .@"--help", .@"-h" => exitHelp(0),

        .role => role.run(init.io, gpa, &it),
        .user => user.run(init.io, gpa, &it),
        .message => message.run(init.io, gpa, &it),
        .server => server.run(init.io, gpa, &it),
        .invite => invite.run(init.io, gpa, &it),
    }
}

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server RESOURCE COMMAND [ARGUMENTS]
        \\
        \\Resources you can manage:
        \\
        \\  server    Initialize and run a server, manage its settings.
        \\  user      List, create, update, ban, delete users.
        \\  role      List, create, update, delete roles.
        \\  invite    List, create, update, delete invites.
        \\
        \\Use `awebo-server RESOURCE help` for resource-specific help information.
        \\
        \\Resource-less commands:
        \\
        \\  version    Print the awebo-server version and exit
        \\  help       Show this menu and exit
        \\
        \\
    , .{});

    std.process.exit(status);
}

fn exitVersion() noreturn {
    std.debug.print("{s}", .{options.version});
    std.process.exit(0);
}

test {
    _ = server;
    _ = message;
    _ = invite;
    _ = user;
    _ = role;
}
