const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const awebo = @import("../../../awebo.zig");
const Invite = awebo.Invite;
const Database = awebo.Database;
const Query = Database.Query;
const cli = @import("../../../cli.zig");

const log = std.log.scoped(.db);

pub const Queries = struct {
    select_invite: Query(
        \\SELECT slug, expiry, creator, handle, enabled, remaining
        \\FROM invites
        \\JOIN users
        \\ON users.id = invites.creator
        \\WHERE slug = ?;
    , .{
        .kind = .row,
        .cols = struct {
            slug: []const u8,
            expiry: u64,
            creator: awebo.User.Id,
            handle: []const u8,
            enabled: bool,
            remaining: ?u64,
        },
        .args = struct { slug: []const u8 },
    }),
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_only);
    defer db.close();

    const qs = db.initQueries(Queries);
    defer db.deinitQueries(Queries, &qs);

    const row = qs.select_invite.run(@src(), db, .{ .slug = cmd.slug });
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
            \\  enabled: {}
            \\  remaining: {?d}
            \\
        , .{
            r.textNoDupe(.slug),
            invite,
            r.get(.expiry),
            r.textNoDupe(.handle), // Creator handle
            r.get(.creator),
            r.get(.enabled),
            r.get(.remaining),
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

        var args: cli.Args = .init(it);

        if (args.help()) exitHelp(0);
        const invite_slug = args.next() orelse {
            std.debug.print("error: missing INVITE_SLUG for show\n", .{});
            exitHelp(1);
        };

        while (args.peek()) |current_arg| {
            if (args.help()) exitHelp(0);
            if (args.option("address")) |address_opt| {
                address = Invite.Address.parse(address_opt) catch {
                    cli.fatal("invalid value for --address (hostname or IP address): '{s}'", .{address_opt});
                };
            } else if (args.option("port")) |port_opt| {
                port = std.fmt.parseInt(u16, port_opt, 10) catch {
                    cli.fatal("invalid value for --port (integer): '{s}'", .{port_opt});
                };
            } else if (args.option("db-path")) |db_path_opt| {
                db_path = db_path_opt;
            } else {
                cli.fatal("unknown argument '{s}'", .{current_arg});
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

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server invite show INVITE_SLUG [OPTIONAL_ARGS]
        \\
        \\Show information about a specific invite.
        \\
        \\Optional arguments:
        \\  --address ADDRESS    Address to display in the `awebo://` invite. Defaults to 127.0.0.1
        \\  --port PORT          Port to display in the `awebo://` invite. Defaults to 1991
        \\  --db-path DB_PATH    Path to the SQLite database to be used.
        \\                       Defaults to 'awebo.db'.
        \\  --help, -h           Show this menu and exit.
        \\
    , .{});

    std.process.exit(status);
}

test "invite show queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
