const options = @import("options");
const builtin = @import("builtin");
const std = @import("std");
const process = std.process;

pub const Resource = enum {
    server,
    tui,

    // resourceless commands
    version,
    help,
    @"--help",
    @"-h",
};

pub fn main(init: process.Init) !void {
    const arena = init.arena.allocator();
    const gpa = init.gpa;
    const environ = init.environ_map;

    var it = try init.minimal.args.iterateAllocator(arena);
    _ = it.skip();

    const resource = it.next() orelse "tui";

    const resource_enum = std.meta.stringToEnum(Resource, resource) orelse {
        std.debug.print("error: invalid resource '{s}'\n", .{resource});
        exitHelp(1);
    };

    switch (resource_enum) {
        .version => exitVersion(),
        .help, .@"--help", .@"-h" => exitHelp(0),

        .server => @import("client/cli/server.zig").run(init.io, gpa, environ, &it),
        .tui => @import("client/tui.zig").run(init.io, gpa, &it),
    }
}

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo RESOURCE COMMAND [ARGUMENTS]
        \\
        \\Resources you can manage:
        \\
        \\  server    Manage server settings.
        \\  tui       Start the awebo terminal client.
        \\
        \\Use `awebo RESOURCE help` for resource-specific help information.
        \\
        \\Resource-less commands:
        \\
        \\  version  Print the awebo version and exit
        \\  help     Show this menu and exit
        \\
        \\Running awebo with no RESOURCE will start the awebo terminal client.
        \\
        \\
    , .{});

    std.process.exit(status);
}

fn exitVersion() noreturn {
    std.debug.print("{s}", .{options.version});
    std.process.exit(0);
}
