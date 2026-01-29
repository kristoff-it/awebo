const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const Query = Database.Query;

const log = std.log.scoped(.db);

const Queries = struct {
    update_invite: Query(
        \\UPDATE invites 
        \\SET 
        \\    updated = unixepoch(),
        \\    expiry  = COALESCE(?2, expiry),
        \\    enabled = COALESCE(?3, enabled),
        \\    remaining = IIF(?4, ?5, remaining)
        \\WHERE slug = ?1;
    , .{
        .kind = .exec,
        .args = struct {
            slug: []const u8,
            expiry: ?i64,
            enabled: ?bool,
            remaining_set: bool,
            remaining_value: ?u64,
        },
    }),
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    _ = io;
    _ = gpa;
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .read_write);
    defer db.close();

    const qs = db.initQueries(Queries);
    defer db.deinitQueries(Queries, &qs);

    qs.update_invite.run(db, .{
        .slug = cmd.slug,
        .expiry = cmd.expiry,
        .enabled = cmd.enabled,
        .remaining_set = cmd.user_limit_set,
        .remaining_value = cmd.user_limit_value,
    });
}

const Command = struct {
    slug: []const u8, // string representing a number
    db_path: [:0]const u8,

    /// Editing arguments, at least one must be specified
    expiry: ?i64,
    enabled: ?bool,
    user_limit_set: bool,
    user_limit_value: ?u64,

    fn parse(it: *std.process.Args.Iterator) Command {
        var expiry: ?i64 = null;
        var enabled: ?bool = null;
        var user_limit_set: ?bool = null;
        var user_limit_value: ?u64 = null;
        var db_path: ?[:0]const u8 = null;

        const invite_slug = it.next() orelse fatalHelp();

        const eql = std.mem.eql;
        if (eql(u8, invite_slug, "--help") or eql(u8, invite_slug, "-h")) fatalHelp();
        while (it.next()) |arg| {
            if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) fatalHelp();
            if (eql(u8, arg, "--expiry")) {
                if (expiry != null) fatal("duplicate --expiry flag", .{});
                const expiry_arg = it.next() orelse fatal("missing value for --expiry", .{});
                expiry = std.fmt.parseInt(i64, expiry_arg, 10) catch {
                    fatal("invalid value for --expiry (integer): '{s}'", .{expiry_arg});
                };
            } else if (eql(u8, arg, "--enabled")) {
                if (enabled != null) fatal("duplicate --enabled flag", .{});
                const enabled_arg = it.next() orelse fatal("missing value for --enabled", .{});
                if (eql(u8, enabled_arg, "true")) {
                    enabled = true;
                } else if (eql(u8, enabled_arg, "false")) {
                    enabled = false;
                } else {
                    fatal("invalid value for --enabled (boolean): '{s}'", .{enabled_arg});
                }
            } else if (eql(u8, arg, "--user-limit")) {
                if (user_limit_set != null) fatal("duplicate --user-limit flag", .{});
                user_limit_set = true;

                const user_limit_arg = it.next() orelse fatal("missing value for --user-limit", .{});
                if (std.ascii.eqlIgnoreCase(user_limit_arg, "null")) {
                    user_limit_value = null;
                } else {
                    user_limit_value = std.fmt.parseInt(u32, user_limit_arg, 10) catch {
                        fatal("invalid value for --user-limit (integer or 'null'): '{s}'", .{user_limit_arg});
                    };
                }
            } else if (eql(u8, arg, "--db_path")) {
                if (db_path != null) fatal("duplicate --db_path flag", .{});
                db_path = it.next() orelse fatal("missing value for --db_path", .{});
            } else {
                fatal("unknown argument '{s}'", .{arg});
            }
        }

        const cmd: Command = .{
            .slug = invite_slug,
            .expiry = expiry,
            .enabled = enabled,
            .user_limit_set = user_limit_set orelse false,
            .user_limit_value = user_limit_value,
            .db_path = db_path orelse "awebo.db",
        };

        // at least one invite editing argument must be specified
        inline for (@typeInfo(Command).@"struct".fields[2..]) |f| {
            if (@FieldType(Command, f.name) == bool) {
                if (@field(cmd, f.name)) return cmd;
                continue;
            }
            if (@field(cmd, f.name) != null) return cmd;
        }

        fatal("at least one invite editing argument must be specified", .{});
    }
};

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server invite edit INVITE_SLUG EDIT_ARGS [OPTIONAL_ARGS]
        \\
        \\Edit an invite.
        \\
        \\Invite editing arguments (at least one must be specified):
        \\  --expiry EXPIRY          Change the invite's expiration time
        \\  --creator-handle HANDLE  Change the invite's creator
        \\  --enabled ENABLED        Enable/disable the invite
        \\  --user-limit LIMIT       Change the invite's user limit
        \\
        \\Optional arguments:
        \\ --db-path DB_PATH     Path to the SQLite database to be used.
        \\                       Defaults to 'awebo.db'.
        \\ --help, -h            Show this menu and exit.
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

test "invite edit queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
