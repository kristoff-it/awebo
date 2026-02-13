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
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const awebo = @import("../awebo.zig");

const log = std.log.scoped(.db);

conn: zqlite.Conn,

pub const tables = @import("Database/tables.zig");

pub const CommonQueries = @import("Database/CommonQueries.zig");

pub const Mode = enum(c_int) {
    create = zqlite.OpenFlags.Create | zqlite.OpenFlags.Exclusive,
    read_write = zqlite.OpenFlags.ReadWrite,
    read_only = zqlite.OpenFlags.ReadOnly,
};

export fn errLog(_: *anyopaque, error_code: c_int, msg: [*:0]const u8) void {
    log.debug("sqlite err/warn log ({}): {s}", .{ error_code, msg });
}

pub fn init(db_path: [:0]const u8, mode: Mode) Database {
    if (builtin.mode == .Debug) {
        _ = zqlite.c.sqlite3_config(zqlite.c.SQLITE_CONFIG_LOG, &errLog, &errLog);
    }

    // Uncomment to see the latest id selection query on client/server startup
    // {
    //     const q: Queries = undefined;
    //     std.debug.print(@TypeOf(q.select_latest_id).sql, .{});
    // }

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

    if (db.isEmpty()) {
        db.initTables();
    }

    return db;
}

pub fn initTables(db: Database) void {
    tables.init(db) catch db.fatal(@src());
}

/// Initializes a "Queries" type.
/// A Queries type is a struct whose fields are all of type Query.
/// Queries should be passed around by pointer.
/// Queries should be deinited when disconnecting from the database.
pub fn initQueries(db: Database, Queries: type) Queries {
    var qs: Queries = undefined;
    inline for (@typeInfo(Queries).@"struct".fields) |f| {
        @field(qs, f.name) = f.type.init(db) catch {
            log.err("Error caused by {s}, query name: {s}", .{
                @typeName(Queries),
                f.name,
            });
            db.fatal(@src());
        };
    }
    return qs;
}

pub inline fn deinitQueries(db: Database, Queries: type, qs: *const Queries) void {
    _ = db;
    inline for (@typeInfo(Queries).@"struct".fields) |f| {
        @field(qs, f.name).deinit();
    }
}

pub fn close(db: Database) void {
    db.conn.close();
}

pub fn isEmpty(db: Database) bool {
    // This query runs before we prepare CommonQueries
    // And it doesn't run too often, on top of the fact
    // that it only refers to sqlite internal tables,
    // meaning that we're not going to break it.
    // For these reasons we don't try to make a prepared
    // statement out of it.
    const query =
        \\SELECT name FROM sqlite_master 
        \\WHERE type='table' AND name='host';
    ;

    const r = db.conn.row(query, .{}) catch db.fatal(@src());
    return r == null;
}

pub fn loadHost(
    db: Database,
    gpa: Allocator,
    qs: *const awebo.Database.CommonQueries,
    h: *awebo.Host,
) !void {
    if (context != .client) @compileError("client only");
    // {
    //     const query = "SELECT value FROM host WHERE key = 'name'";
    //     const maybe_row = db.row(query, .{}) catch db.fatal(@src());
    //     const r = maybe_row orelse {
    //         h.* = .{};
    //         return;
    //     };
    //     h.name = try r.text(gpa, .value);
    h.name = try gpa.dupe(u8, "banana");
    // }

    {
        var rs = qs.select_users.run(@src(), db, .{});
        while (rs.next()) |r| {
            const user: awebo.User = .{
                .id = r.get(.id),
                .created = r.get(.created),
                .handle = try r.text(gpa, .handle),
                .power = r.get(.power),
                .update_uid = r.get(.update_uid),
                .invited_by = r.get(.invited_by),
                .display_name = try r.text(gpa, .display_name),
                .avatar = "arst",
            };
            log.debug("loaded {f}", .{user});
            h.users.set(gpa, user) catch oom();
        }
    }

    {
        var rs = qs.select_channels.run(@src(), db, .{});
        while (rs.next()) |r| {
            const kind = r.get(.kind);
            const channel: awebo.Channel = .{
                .id = r.get(.id),
                .name = try r.text(gpa, .name),
                .update_uid = r.get(.update_uid),
                .privacy = r.get(.privacy),
                .kind = switch (kind) {
                    inline else => |tag| @unionInit(
                        awebo.Channel.Kind,
                        @tagName(tag),
                        .{},
                    ),
                },
            };

            try h.channels.set(gpa, channel);
            log.debug("loaded {f}", .{channel});

            //getme
            // if (channel.kind == .chat) {
            //     var msgs = qs.select_channel_messages.run(@src(), db, .{
            //         .channel = channel.id,
            //         .limit = 64,
            //     });

            //     while (msgs.next()) |m| {
            //         const msg: awebo.Message = .{
            //             .id = m.get(.uid),
            //             .origin = m.get(.origin),
            //             .created = m.get(.created),
            //             .update_uid = m.get(.update_uid),
            //             .kind = m.get(.kind),
            //             .author = m.get(.author),
            //             .text = try m.text(gpa, .body),
            //         };
            //         try channel.kind.chat.messages.backfill(gpa, msg);
            //         log.debug("loaded chat message: {f}", .{msg});
            //     }
            // }

        }
    }
}

pub fn fatal(db: Database, src: std.builtin.SourceLocation) noreturn {
    std.debug.panic("{s}:{}: fatal db error: {s}", .{ src.file, src.line, db.conn.lastError() });
}

fn fatalErr(err: anyerror) noreturn {
    log.err("fatal error: {t}", .{err});
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

fn oom() noreturn {
    std.process.fatal("oom", .{});
}

test "test common queries" {
    // Initializes the database and then prepares all queries
    const db: awebo.Database = .init(":memory:", .create);
    defer db.close();

    _ = db.initQueries(CommonQueries);
}

fn Result(config: QueryConfig) type {
    return switch (config.kind) {
        .row => ?Rows(config).Row,
        .rows => Rows(config),
        .exec => void,
        .returning => @compileError("returning queries must use .runReturning()"),
    };
}

const QueryConfig = struct {
    kind: enum { returning, row, rows, exec },
    cols: type = struct {},
    args: type = struct {},
};

pub fn Query(sql_query: [:0]const u8, config: QueryConfig) type {
    return struct {
        stmt: *zqlite.c.sqlite3_stmt,

        pub const cfg = config;
        pub const sql = sql_query;

        fn init(db: Database) !@This() {
            const prep = try db.conn.prepare(sql_query);
            return .{ .stmt = @ptrCast(prep.stmt) };
        }

        fn deinit(q: *const @This()) void {
            _ = zqlite.c.sqlite3_finalize(q.stmt);
        }

        ///To be used with '.returning' queries.
        ///Those are INSERT queries that also have a RETURNING clause.
        ///This function will:
        /// - run the query
        /// - assert that it returns one row
        /// - get the specified column value
        /// - reset the sqlite query statement
        ///In particular the early reset is important when this query is
        ///run within a transaction, see #73 for what happens when the
        ///statement is not reset before committing the transaction.
        pub fn runReturning(
            q: *const @This(),
            src: std.builtin.SourceLocation,
            db: Database,
            comptime col: std.meta.FieldEnum(config.cols),
            args: config.args,
        ) ColType(col) {
            if (config.kind != .returning) {
                @compileError("only to be used by .returning queries, use .run() instead");
            }

            const stmt: zqlite.Stmt = .{
                .conn = db.conn.conn,
                .stmt = @ptrCast(q.stmt),
            };

            bind(stmt, db, args);

            const one_row = stmt.step() catch db.fatal(src);
            assert(one_row);

            const r = Rows(config).Row{ .row = .{ .stmt = stmt } };
            defer stmt.reset() catch unreachable;

            const C = ColType(col);
            if (C == void) @compileError("unsupported");
            return r.coerce(C, @intFromEnum(col));
        }

        pub fn run(
            q: *const @This(),
            src: std.builtin.SourceLocation,
            db: Database,
            args: config.args,
        ) Result(config) {
            const stmt: zqlite.Stmt = .{
                .conn = db.conn.conn,
                .stmt = @ptrCast(q.stmt),
            };

            bind(stmt, db, args);

            switch (config.kind) {
                .returning => @compileError("use .runReturning()"),
                .row => {
                    const one_row = stmt.step() catch db.fatal(src);
                    if (!one_row) return null;
                    return Rows(config).Row{ .row = .{ .stmt = stmt } };
                },
                .rows => {
                    return Rows(config){ .rows = .{ .stmt = stmt, .err = null } };
                },
                .exec => {
                    stmt.stepToCompletion() catch db.fatal(src);
                },
            }
        }

        fn bind(stmt: zqlite.Stmt, db: Database, args: config.args) void {
            stmt.reset() catch db.fatal(@src());
            inline for (@typeInfo(config.args).@"struct".fields, 0..) |f, idx| {
                if (f.type == AnyArg) {
                    switch (@field(args, f.name)) {
                        inline else => |v| stmt.bindValue(v, idx) catch db.fatal(@src()),
                    }
                } else switch (@typeInfo(f.type)) {
                    .@"enum" => {
                        const value: u64 = @intFromEnum(@field(args, f.name));
                        stmt.bindValue(value, idx) catch db.fatal(@src());
                    },
                    else => stmt.bindValue(@field(args, f.name), idx) catch db.fatal(@src()),
                }
            }
        }

        fn ColType(col: std.meta.FieldEnum(config.cols)) type {
            const c: config.cols = undefined;
            return @TypeOf(@field(c, @tagName(col)));
        }
    };
}

pub fn Rows(config: QueryConfig) type {
    return struct {
        rows: zqlite.Rows,

        pub fn next(self: *@This()) ?Row {
            return .{ .row = self.rows.next() orelse return null };
        }

        pub const Row = struct {
            row: zqlite.Row,

            pub fn get(r: Row, comptime col: std.meta.FieldEnum(config.cols)) ColType(col) {
                const C = ColType(col);
                if (C == void) {
                    @compileError("column doesn't specify type, use .getAs()");
                }
                return r.coerce(C, @intFromEnum(col));
            }

            pub fn getAs(r: Row, T: type, comptime col: std.meta.FieldEnum(config.cols)) T {
                const C = ColType(col);
                if (C != void) {
                    @compileError("column has a specified type, use .get()");
                }
                return r.coerce(T, @intFromEnum(col));
            }

            fn coerce(r: Row, T: type, idx: usize) T {
                switch (T) {
                    u32, u64, i64 => return @intCast(r.row.int(idx)),
                    ?u64 => {
                        const value = r.row.nullableInt(idx) orelse return null;
                        log.debug("result: {}", .{value});
                        return @intCast(value);
                    },
                    []u8, []const u8 => @compileError("use text() or textNoDupe()"),
                    bool => return r.row.boolean(idx),
                    ?bool => return r.row.nullableBoolean(idx),
                    else => switch (@typeInfo(T)) {
                        .@"enum" => {
                            return @enumFromInt(r.row.int(idx));
                        },
                        else => @compileError("type " ++ @typeName(T) ++ " not supported"),
                    },
                }
            }

            /// Dupes the resulting value, use `textNoDupe` to avoid duping.
            pub fn text(r: Row, gpa: Allocator, col: std.meta.FieldEnum(config.cols)) ![]const u8 {
                return gpa.dupe(u8, r.row.text(@intFromEnum(col)));
            }

            pub fn textNoDupe(r: Row, col: std.meta.FieldEnum(config.cols)) []const u8 {
                return r.row.text(@intFromEnum(col));
            }

            fn ColType(col: std.meta.FieldEnum(config.cols)) type {
                const c: config.cols = undefined;
                return @TypeOf(@field(c, @tagName(col)));
            }
        };
    };
}

pub const AnyArg = union(enum) {
    string: []const u8,
    num: i64,

    pub fn init(value: anytype) AnyArg {
        const T = @TypeOf(value);
        switch (T) {
            []const u8 => return .{ .string = value },
            i64, u64, usize => return .{ .num = @intCast(value) },
            bool => .{ .num = @intFromBool(value) },
            else => @compileError("type " ++ @typeName(T) ++ " not supported"),
        }
    }
};
