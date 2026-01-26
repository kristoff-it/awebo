//!Database is an abstraction over a sqlite connection that adds
//!comptime / test-time safety to queries.
//!
//!This is one of the most comptime heavy parts of awebo.
//!
//!When initing a Database the following happens:
//! - The sqlite database file is opened.
//! - A query is run to see if the database is empty
//!   (we consider absence of a 'host' table to denote an empty server)
//! - If the database is considered empty, then all table creation
//!   queries are run (from Database/tables.zig).
//! - All queries in Database/Queries.zig are prepared, which will
//!   both act as an optimization (since we're pre-compiling them)
//!   and will also catch most semantic errors in the query.
//!
//!Things to keep in mind:
//! - Database holds Queries, which is a struct with many pointers,
//!   (somewhat like a vtable), so you should pass around instances
//!   of Database by pointer.
//! - Both table queries and normal queries are defined to be
//!   either shared or server-only. The goal is to share as much
//!   logic between server and client, but some things do have
//!   to be different. The metaprogramming code in Database that
//!   wraps the sqlite connection will poduce a compile error if
//!   you attempt to use a query that is not meant to be run in
//!   your context (client or server).
//! - Each non-schema query (so the ones in Queries.zig) also
//!   defines which arguments it expects as input, which columns
//!   it outputs, and if it's meant to produce many rows or just
//!   one. It's important to keep this metadata in sync with the
//!   query text as there is currently no automated veryfication.
const Database = @This();

const context = @import("options").context;
const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const awebo = @import("../awebo.zig");

const log = std.log.scoped(.db);

conn: zqlite.Conn,
queries: Queries,

pub const tables = @import("Database/tables.zig");
pub const Queries = @import("Database/Queries.zig");

pub const Mode = enum(c_int) {
    create = zqlite.OpenFlags.Create | zqlite.OpenFlags.Exclusive,
    read_write = zqlite.OpenFlags.ReadWrite,
    read_only = zqlite.OpenFlags.ReadOnly,
};

pub fn init(db_path: [:0]const u8, mode: Mode) Database {
    var conn = zqlite.open(db_path, @intFromEnum(mode) | zqlite.OpenFlags.EXResCode) catch |err| {
        switch (mode) {
            .create => std.debug.print("error while creating database file: {s}\n", .{@errorName(err)}),
            else => std.debug.print("error while loading database file: {s}\n", .{@errorName(err)}),
        }
        std.process.exit(1);
    };
    errdefer conn.close();

    if (isEmpty(conn)) {
        tables.init(conn);
    }

    const db: Database = .{
        .conn = conn,
        .queries = .init(conn),
    };

    const pragmas = switch (mode) {
        .read_only =>
        \\PRAGMA query_only = true;
        ,
        else =>
        \\PRAGMA locking_mode = EXCLUSIVE;
        \\PRAGMA foreign_keys = true;
        \\PRAGMA journal_mode = WAL;
        \\PRAGMA synchronous = NORMAL;
        \\PRAGMA temp_store = memory;
        ,
    };
    conn.execNoArgs(pragmas) catch db.fatal(@src());

    return db;
}

pub fn close(db: Database) void {
    db.conn.close();
}

fn isEmpty(conn: zqlite.Conn) bool {
    const query =
        \\SELECT name FROM sqlite_master 
        \\WHERE type='table' AND name='host';
    ;

    const r = conn.row(query, .{}) catch |err| fatalErr(err);
    return r == null;
}

/// See docs for `rows`
pub fn row(db: Database, comptime query: []const u8, args: anytype) !?Rows(query).Row {
    return .{ .row = (try db.conn.row(query, args)) orelse return null };
}

/// Wrapper around zqlite's rows function. Returns wrappers around zqlite.Rows and zqlite.Row.
/// The wrappers have slightly modified member functions that use enum literals instead of indices
/// to refer to columns (e.g. zqlite.row.text(0) -> db.row.text(.body)).
/// Column name validation and mapping happens at comptime.
/// Validation is somewhat simplistic so for advanced queries consider using the original API
/// available by calling `db.conn.rows` directly.
pub fn rows(db: Database, comptime query: []const u8, args: anytype) !Rows(query) {
    return .{ .rows = try db.conn.rows(query, args) };
}

pub fn Rows(comptime query: []const u8) type {
    @setEvalBranchQuota(900000);
    const columns = blk: {
        var columns: []const struct { []const u8, u8 } = &.{};

        var it = std.mem.tokenizeAny(u8, query, " ,\n");
        if (!std.mem.eql(u8, it.next() orelse "", "SELECT")) {
            @compileError("query must start with SELECT");
        }

        var idx: u8 = 0; // on overflow, before bumping, ask yourself: who's in the wrong, the code or you?
        while (it.next()) |tok| : (idx += 1) {
            if (std.mem.eql(u8, tok, "*")) {
                @compileError("never do SELECT *, always write column names explicitly");
            }
            if (std.mem.eql(u8, tok, "FROM")) break;
            columns = columns ++ .{.{ tok, idx }};
        } else @compileError("query missing uppecase 'FROM' keyword");

        break :blk columns;
    };

    const col_map: std.StaticStringMap(u8) = .initComptime(columns);

    return struct {
        rows: zqlite.Rows,

        pub fn next(self: *@This()) ?Row {
            return .{ .row = self.rows.next() orelse return null };
        }

        pub fn deinit(self: @This()) void {
            self.rows.deinit();
        }

        pub const Row = struct {
            row: zqlite.Row,

            pub fn deinit(self: Row) void {
                self.row.deinit();
            }

            pub fn int(r: Row, comptime col: @EnumLiteral()) i64 {
                const idx = comptime col_map.get(@tagName(col)) orelse {
                    @compileError("column '" ++ @tagName(col) ++ "' not found in query");
                };
                return r.row.int(idx);
            }

            /// Dupes the resulting value, use `textNoDupe` to avoid duping.
            pub fn text(r: Row, gpa: Allocator, comptime col: @EnumLiteral()) ![]const u8 {
                const idx = comptime col_map.get(@tagName(col)) orelse {
                    @compileError("column '" ++ @tagName(col) ++ "' not found in query");
                };
                return gpa.dupe(u8, r.row.text(idx));
            }
            pub fn textNoDupe(r: Row, comptime col: @EnumLiteral()) []const u8 {
                const idx = comptime col_map.get(@tagName(col)) orelse {
                    @compileError("column '" ++ @tagName(col) ++ "' not found in query");
                };
                return r.row.text(idx);
            }
        };
    };
}

pub const loadHost = switch (context) {
    .server => @compileError("client only"),
    .client => struct {
        fn impl(db: Database, gpa: Allocator, h: *awebo.Host) void {
            loadData(db, gpa, h) catch oom();
        }

        fn loadData(db: Database, gpa: Allocator, h: *awebo.Host) !void {
            {
                const query = "SELECT value FROM host WHERE key = 'name'";
                const maybe_row = db.row(query, .{}) catch db.fatal(@src());
                const r = maybe_row orelse @panic("missing server name");
                h.name = try r.text(gpa, .value);
            }

            {
                var rs = db.rows("SELECT id, handle, power, invited_by, display_name FROM users", .{}) catch db.fatal(@src());
                defer rs.deinit();

                var users: awebo.Host.Users = .{};
                while (rs.next()) |r| {
                    const user: awebo.User = .{
                        .id = @intCast(r.int(.id)),
                        .handle = try r.text(gpa, .handle),
                        .power = @enumFromInt(r.int(.power)),
                        // arst
                        .invited_by = @intCast(r.int(.invited_by)),
                        .display_name = try r.text(gpa, .display_name),
                        .avatar = "arst",
                    };
                    log.debug("loaded {f}", .{user});
                    users.set(gpa, user) catch oom();
                }
            }

            {
                var rs = db.rows("SELECT id, name, privacy, kind FROM channels", .{}) catch db.fatal(@src());
                defer rs.deinit();

                var channels: awebo.Host.Channels = .{};
                while (rs.next()) |r| {
                    const kind: awebo.Channel.Kind.Enum = @enumFromInt(r.int(.kind));
                    var channel: awebo.Channel = .{
                        .id = @intCast(r.int(.id)),
                        .name = try r.text(gpa, .name),
                        .privacy = @enumFromInt(r.int(.privacy)),
                        .kind = switch (kind) {
                            inline else => |tag| @unionInit(
                                awebo.Channel.Kind,
                                @tagName(tag),
                                .{},
                            ),
                        },
                    };

                    if (channel.kind == .chat) {
                        var msgs = db.rows(
                            \\SELECT id, origin, author, body FROM messages
                            \\WHERE channel = ? ORDER BY id DESC;
                        ,
                            .{channel.id},
                        ) catch db.fatal(@src());
                        defer msgs.deinit();

                        while (msgs.next()) |m| {
                            const msg: awebo.Message = .{
                                .id = @intCast(m.int(.id)),
                                .origin = @intCast(m.int(.origin)),
                                .author = @intCast(m.int(.author)),
                                .text = try m.text(gpa, .body),
                            };
                            try channel.kind.chat.messages.backfill(gpa, msg);
                            log.debug("loaded chat message: {f}", .{msg});
                        }
                    }

                    try channels.set(gpa, channel);
                    log.debug("loaded {f}", .{channel});
                }
            }
        }
    }.impl,
};

/// Returns a user given its username and password.
/// Validation logic is part of this function to make efficient use of the memory returned from sqlite,
/// which becomes invalid as soon as the relative `Row` is deinited.
/// On success dupes `username`.
pub const getUserByLogin = if (context == .client)
    @compileError("server only")
else
    struct {
        fn impl(
            db: Database,
            io: Io,
            gpa: Allocator,
            username: []const u8,
            password: []const u8,
        ) error{ NotFound, Password }!awebo.User {
            const maybe_pswd_row = db.row("SELECT pswd_hash, handle FROM users JOIN passwords ON users.id == passwords.id WHERE handle = ?", .{
                username,
            }) catch db.fatal(@src());
            const pswd_row = maybe_pswd_row orelse {
                std.crypto.pwhash.argon2.strVerify("bananarama123", password, .{ .allocator = gpa }, io) catch {};
                return error.NotFound;
            };
            defer pswd_row.deinit();

            const pswd_hash = pswd_row.textNoDupe(.pswd_hash);

            std.crypto.pwhash.argon2.strVerify(pswd_hash, password, .{ .allocator = gpa }, io) catch |err| switch (err) {
                error.PasswordVerificationFailed => return error.Password,
                error.OutOfMemory => oom(),
                else => fatalErr(err),
            };

            const maybe_row = db.row(
                \\SELECT id, display_name, power, invited_by, avatar FROM users
                \\WHERE handle = ?;
            , .{username}) catch db.fatal(@src());
            const user_row = maybe_row orelse return error.NotFound;
            defer user_row.deinit();

            return .{
                .id = @intCast(user_row.int(.id)),
                .power = @enumFromInt(user_row.int(.power)),
                .display_name = user_row.text(gpa, .display_name) catch oom(),
                .avatar = user_row.text(gpa, .avatar) catch oom(),
                .handle = gpa.dupe(u8, username) catch oom(),
                .invited_by = @intCast(user_row.int(.invited_by)),
                .server = .{
                    .pswd_hash = gpa.dupe(u8, pswd_hash) catch oom(),
                },
            };
        }
    }.impl;

pub const serverPermission = if (context == .client)
    @compileError("server only")
else
    struct {
        fn impl(
            db: Database,
            user: *const awebo.User,
            comptime key: awebo.permissions.Server.Enum,
        ) bool {
            const user_id = user.id;
            const user_default = @field(awebo.permissions.Server{}, @tagName(key));

            switch (user.power) {
                .banned => return false,
                .admin, .owner => return true,
                .user, .moderator => {},
            }

            const user_perm_query =
                \\SELECT value FROM user_permissions WHERE user = ? AND kind = ? AND key = ?;
            ;
            const roles_perm_query =
                \\SELECT permissions.value FROM permissions
                \\INNER JOIN user_roles ON user_roles.role == permissions.role
                \\WHERE user_roles.user = ? AND permissions.kind = ? AND permissions.key = ?;
            ;
            for (&[_][]const u8{ user_perm_query, roles_perm_query }) |q| {
                var result_rows = db.conn.rows(q, .{
                    user_id,
                    @intFromEnum(awebo.permissions.Kind.server),
                    @intFromEnum(key),
                }) catch db.fatal(@src());
                defer result_rows.deinit();

                var found = false;
                while (result_rows.next()) |r| {
                    const value = r.int(0);
                    if (value == 0) return false;
                    found = true;
                }

                if (found) return true;
            } else return user_default;
        }
    }.impl;

pub fn fatal(db: Database, src: std.builtin.SourceLocation) noreturn {
    log.err("{s}:{}: fatal db error: {s}", .{ src.file, src.line, db.conn.lastError() });
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

fn fatalErr(err: anyerror) noreturn {
    log.err("fatal error: {t}", .{err});
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

fn oom() noreturn {
    std.process.fatal("oom", .{});
}

test "test all queries" {
    // Initializes the database and then prepares all queries
    const db: awebo.Database = .init(":memory:", .create);
    defer db.close();
}
