const Database = @This();

const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const awebo = @import("../awebo.zig");

const log = std.log.scoped(.db);

conn: zqlite.Conn,

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

    const db: Database = .{ .conn = conn };

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

// // host.users
// {
//     var rows = conn.rows(
//         "SELECT id, handle, display_name, avatar FROM users",
//         .{},
//     ) catch fatalDb(conn);
//     defer rows.deinit();

//     while (rows.next()) |row| {
//         const user: awebo.User = .{
//             .id = @intCast(row.get(i64, 0)),
//             .handle = row.text(1),
//             .display_name = row.text(2),
//             .avatar = row.blob(3),
//         };
//         try host.users.set(gpa, user);
//         log.debug("loaded user: {any}", .{user});
//     }
// }

/// Returns a user given its username and password.
/// Validation logic is part of this function to make efficient use of the memory returned from sqlite,
/// which becomes invalid as soon as the relative `Row` is deinited.
/// On success dupes `username`.
pub fn getUserByLogin(db: Database, gpa: Allocator, username: []const u8, password: []const u8) error{ NotFound, Password }!awebo.User {
    const maybe_pswd_row = db.row("SELECT pswd_hash FROM users WHERE handle = ?", .{
        username,
    }) catch db.fatal(@src());
    const pswd_row = maybe_pswd_row orelse {
        std.crypto.pwhash.argon2.strVerify("bananarama123", password, .{ .allocator = gpa }) catch {};
        return error.NotFound;
    };
    defer pswd_row.deinit();

    const pswd_hash = pswd_row.textNoDupe(.pswd_hash);

    std.crypto.pwhash.argon2.strVerify(pswd_hash, password, .{ .allocator = gpa }) catch |err| switch (err) {
        error.PasswordVerificationFailed => return error.Password,
        error.OutOfMemory => oom(),
        else => fatalErr(err),
    };

    const maybe_row = db.row("SELECT id, display_name, power, avatar FROM users WHERE handle = ?", .{
        username,
    }) catch db.fatal(@src());
    const user_row = maybe_row orelse return error.NotFound;
    defer user_row.deinit();

    return .{
        .id = @intCast(user_row.int(.id)),
        .power =  @enumFromInt(user_row.int(.power)),
        .display_name = user_row.text(gpa, .display_name) catch oom(),
        .avatar = user_row.text(gpa, .avatar) catch oom(),
        .handle = gpa.dupe(u8, username) catch oom(),
        .server = .{
            .pswd_hash = gpa.dupe(u8, pswd_hash) catch oom(),
        },
    };
}

pub fn serverPermission(db: Database, user: *const awebo.User, comptime key: awebo.permissions.Server.Enum) bool {
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

        var it = std.mem.tokenizeAny(u8, query, " ,=\n");
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
