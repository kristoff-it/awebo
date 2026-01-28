const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const awebo = @import("../../../awebo.zig");
const Invite = awebo.Invite;
const Database = awebo.Database;
const zqlite = @import("zqlite");

const log = std.log.scoped(.db);

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_only);

    const row = db.row(
        \\SELECT slug, expiry, creator, handle, enabled, remaining
        \\FROM invites
        \\JOIN users
        \\ON users.id = invites.creator
        \\WHERE slug = $1;
    , .{cmd.slug}) catch db.fatal(@src());

    if (row) |r| {
        // NOTE: There is no need to `.deinit`
        const invite: Invite = .{
            .slug = cmd.slug,
            .address = cmd.address,
            .port = cmd.port,
        };

        std.debug.print(
            \\Invite ({s}): {f}
            \\  expiry: @{d}
            \\  creator: {s} ({d})
            \\  enabled: {s}
            \\  remaining: {d}
            \\
        , .{
            r.textNoDupe(.slug),
            invite,
            r.int(.expiry),
            r.textNoDupe(.handle), // Creator handle
            r.int(.creator),
            if (r.boolean(.enabled)) "true" else "false",
            r.int(.remaining),
        });
    } else {
        std.debug.print("No invite with slug '{s}'\n", .{cmd.slug});
    }
}

const Command = struct {
    slug: []const u8,
    address: Invite.Address,
    port: u16,
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var address: ?Invite.Address = null;
        var port: ?u16 = null;
        var db_path: ?[:0]const u8 = null;

        const invite_slug = it.next() orelse fatalHelp();

        const eql = std.mem.eql;
        if (eql(u8, invite_slug, "--help") or eql(u8, invite_slug, "-h")) fatalHelp();
        while (it.next()) |arg| {
            if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) fatalHelp();
            if (eql(u8, arg, "--address")) {
                if (address != null) fatal("duplicate --address flag", .{});
                const address_arg = it.next() orelse fatal("missing value for --address", .{});
                address = Invite.Address.parse(address_arg) catch {
                    fatal("invalid value for --address (hostname or IP address): '{s}'", .{address_arg});
                };
            } else if (eql(u8, arg, "--port")) {
                if (port != null) fatal("duplicate --port flag", .{});
                const port_arg = it.next() orelse fatal("missing value for --port", .{});
                port = std.fmt.parseInt(u16, port_arg, 10) catch {
                    fatal("invalid value for --port (integer): '{s}'", .{port_arg});
                };
            } else if (eql(u8, arg, "--db-path")) {
                if (db_path != null) fatal("duplicate --db-path flag", .{});
                db_path = it.next() orelse fatal("missing value for --db-path", .{});
            } else {
                fatal("unknown argument '{s}'", .{arg});
            }
        }

        return .{
            .slug = invite_slug,
            .address = address orelse .{ .ip_address = .{ .ip4 = .{
                .bytes = .{ 127, 0, 0, 1 },
                .port = 0,
            } } },
            .port = port orelse 1991,
            .db_path = db_path orelse "awebo.db",
        };
    }
};

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server invite show INVITE_SLUG [OPTIONAL_ARGS]
        \\
        \\Show information about a specific invite.
        \\
        \\Optional arguments:
        \\  --address ADDRESS     Address to display in the `awebo://` invite. Defaults to 127.0.0.1
        \\  --port PORT           port to display in the `awebo://` invite. Defaults to 1991
        \\  --db-path DB_PATH     Path to the SQLite database to be used.
        \\                        Defaults to 'awebo.db'.
        \\  --help, -h            Show this menu and exit.
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}
