const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const Query = Database.Query;

const alphnumeric_ascii = std.ascii.letters ++ "0123456789";

const log = std.log.scoped(.db);

const Queries = struct {
    insert_invite: Query(
        \\INSERT INTO invites
        \\  (slug, created,     updated,     expiry, enabled, remaining, creator)
        \\SELECT
        \\  ?1,    unixepoch(), unixepoch(), ?2,     ?3,      ?4,        users.id
        \\FROM users
        \\WHERE users.handle = ?5
        \\RETURNING creator;
    , .{
        .kind = .row,
        .cols = struct { creator: awebo.User.Id },
        .args = struct {
            slug: []const u8,
            expiry: i64,
            enabled: bool,
            remaining: ?u64,
            handle: []const u8,
        },
    }),
};

pub fn run(io: Io, _: Allocator, it: *std.process.Args.Iterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_write);
    defer db.close();

    const qs = db.initQueries(Queries);
    defer db.deinitQueries(Queries, &qs);

    var slug_buf: [16]u8 = undefined;
    const slug = cmd.slug orelse blk: {
        // is there a simpler way of getting a random ascii string?
        const now = std.Io.Clock.real.now(io) catch @panic("clock is required for PRNG seed");
        const nanoseconds_bits: u96 = @bitCast(now.nanoseconds);
        var prng: std.Random.DefaultPrng = .init(@truncate(nanoseconds_bits));
        var rand = prng.random();
        for (&slug_buf) |*c| {
            c.* = alphnumeric_ascii[rand.intRangeLessThan(usize, 0, alphnumeric_ascii.len)];
        }
        break :blk &slug_buf;
    };

    const now = std.Io.Clock.real.now(io) catch @panic("unable to get current time");
    const creator_id_row = qs.insert_invite.run(db, .{
        .slug = slug,
        .expiry = cmd.expiry orelse now.toSeconds(),
        .enabled = cmd.enabled,
        .remaining = cmd.user_limit,
        .handle = cmd.creator_handle,
    });

    const creator_id = if (creator_id_row) |r| r.get(.creator) else {
        // In this case, no rows were returned by the SELECT statement, so no rows were inserted
        fatal("no user with handle '{s}'", .{cmd.creator_handle});
    };

    std.debug.print(
        \\Created invite:
        \\  creator: {s} ({d})
        \\  slug: {s}
        \\
    , .{ cmd.creator_handle, creator_id, slug });
}

const Command = struct {
    slug: ?[]const u8,
    expiry: ?i64,
    creator_handle: []const u8,
    enabled: bool,
    user_limit: ?u64,
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var slug: ?[]const u8 = null;
        var expiry: ?i64 = null;
        var creator: ?[]const u8 = null;
        var enabled: ?bool = null;
        var user_limit: union(enum) { limit: u32, no_limit, unset } = .unset;
        var db_path: ?[:0]const u8 = null;

        const eql = std.mem.eql;
        while (it.next()) |arg| {
            if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) fatalHelp();
            if (eql(u8, arg, "--slug")) {
                if (slug != null) fatal("duplicate --slug flag", .{});
                slug = it.next() orelse fatal("missing value for --slug", .{});
            } else if (eql(u8, arg, "--expiry")) {
                if (expiry != null) fatal("duplicate --expiry flag", .{});
                const expiry_arg = it.next() orelse fatal("missing value for --expiry", .{});
                expiry = std.fmt.parseInt(i64, expiry_arg, 10) catch {
                    fatal("invalid value for --expiry (integer): '{s}'", .{expiry_arg});
                };
            } else if (eql(u8, arg, "--creator-handle")) {
                if (creator != null) fatal("duplicate --creator-handle flag", .{});
                creator = it.next() orelse fatal("missing value for --creator-handle", .{});
            } else if (eql(u8, arg, "--enabled")) {
                if (enabled != null) fatal("duplicate --enabled flag", .{});
                const enabled_arg = it.next() orelse fatal("missing value for --enabled", .{});
                if (eql(u8, enabled_arg, "true")) {
                    enabled = true;
                } else if (eql(u8, enabled_arg, "true")) {
                    enabled = false;
                } else {
                    fatal("invalid value for --enabled (boolean): '{s}'", .{enabled_arg});
                }
            } else if (eql(u8, arg, "--user-limit")) {
                if (user_limit != .unset) fatal("duplicate --user-limit flag", .{});
                const user_limit_arg = it.next() orelse fatal("missing value for --user-limit", .{});
                if (std.ascii.eqlIgnoreCase(user_limit_arg, "null")) {
                    user_limit = .no_limit;
                } else {
                    user_limit = .{
                        .limit = std.fmt.parseInt(u32, user_limit_arg, 10) catch {
                            fatal("invalid value for --user-limit (integer or 'null'): '{s}'", .{user_limit_arg});
                        },
                    };
                }
            } else if (eql(u8, arg, "--db-path")) {
                if (db_path != null) fatal("duplicate --db-path flag", .{});
                db_path = it.next() orelse fatal("missing value for --db-path", .{});
            } else {
                fatal("unknown argument '{s}'", .{arg});
            }
        }

        return .{
            .slug = slug,
            .creator_handle = creator orelse fatal("--creator-handle argument is required", .{}),
            .expiry = expiry,
            .enabled = enabled orelse true,
            .user_limit = switch (user_limit) {
                .limit => |l| l,
                .no_limit => null,
                .unset => 1,
            },
            .db_path = db_path orelse "awebo.db",
        };
    }
};

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server invite add REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Add a new invite.
        \\
        \\Required arguments:
        \\ --creator-handle HANDLE  @handle of the user that created the invite
        \\
        \\Optional arguments:
        \\ --slug SLUG         Invite's slug (default: a random, unique string)
        \\ --expiry TIME       Time the invite will expire (default: never)
        \\ --enabled ENABLED   Whether the invite is enabled (default: true)
        \\ --user-limit LIMIT  Number of users allowed to use the invite (default: 1)
        \\ --db-path DB_PATH   Path to the SQLite database to be used. (default: awebo.db)
        \\ --help, -h          Show this menu and exit.
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

test "invite add queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
