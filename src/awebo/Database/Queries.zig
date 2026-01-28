const Queries = @This();
const context = @import("options").context;
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const awebo = @import("../../awebo.zig");
const zqlite = @import("zqlite");

const log = std.log.scoped(.query);

pub fn init(conn: zqlite.Conn) Queries {
    var qs: Queries = undefined;
    inline for (@typeInfo(Queries).@"struct".fields) |f| {
        @field(qs, f.name) = f.type.init(conn) catch fatalDb(conn);
    }
    return qs;
}

fn Result(config: QueryConfig) type {
    return switch (config.kind) {
        .row => ?Rows(config).Row,
        .rows => Rows(config),
    };
}

// -- Queries --
select_latest_id: Query(blk: {
    // This query finds the highest id value.
    //  - In awebo-server it's used to know which id to generate next
    //  - In awebo-client it's used to know which is the last observed event
    //
    // The query is generated automatically from the database schema by
    // looking for columns either named 'uid' or suffixed by '_uid'.
    //
    // The query has this shape:
    //
    //  SELECT MAX(value) as max_uid
    //  FROM (
    //      SELECT MAX(uid) as value FROM users
    //      UNION ALL
    //      SELECT MAX(update_uid) as value FROM users
    //      UNION ALL
    //      SELECT MAX(update_uid) as value FROM channels
    //      UNION ALL
    //      SELECT MAX(uid) as value FROM messages
    //  );
    //
    // See awebo.Database.init for some commented code that can print
    // the end result of this comptime query builder.
    var query: [:0]const u8 = "SELECT MAX(value) as max_uid \nFROM (\n";

    var first = true;
    for (@typeInfo(awebo.Database.tables).@"struct".decls) |decl| {
        const table = @field(awebo.Database.tables, decl.name);
        if (@TypeOf(table) != awebo.Database.tables.Table) continue;
        if (table.context) |ctx| if (context != ctx) continue;

        const schema = table.schema;
        var line_it = std.mem.tokenizeScalar(u8, schema, '\n');
        while (line_it.next()) |line| {
            var it = std.mem.tokenizeScalar(u8, line, ' ');
            const col_name = it.next() orelse continue;

            if (std.mem.eql(u8, col_name, "uid") or
                std.mem.endsWith(u8, col_name, "_uid"))
            {
                query = query ++ std.fmt.comptimePrint((if (first)
                    ""
                else
                    "    UNION ALL\n") ++
                    \\    SELECT MAX({s}) as value FROM {s}
                    \\
                , .{ col_name, decl.name });
                first = false;
            }
        }
    }

    query = query ++ "\n);";
    break :blk query;
}, .{
    .kind = .row,
    .cols = &.{.{ .max_uid, u64 }},
}),

select_user_limits: Query(
    \\SELECT COUNT(*) FROM users;
,
    .{
        .kind = .row,
        .cols = &.{.{ .count, u64 }},
    },
),

select_host_info: Query(
    \\SELECT key, value FROM host;
,
    .{
        .kind = .rows,
        .cols = &.{
            .{ .key, []const u8 },
            .{ .value, void },
            // value has a different type per row,
            // use .getAs() to coerce the type
        },
    },
),

select_channels: Query(
    \\SELECT id, name, privacy, kind FROM channels;
, .{
    .kind = .rows,
    .cols = &.{
        .{ .id, u64 },
        .{ .name, []const u8 },
        .{ .privacy, awebo.Channel.Privacy },
        .{ .kind, awebo.Channel.Kind.Enum },
    },
}),

select_channel_messages: Query(
    \\SELECT uid, origin, author, body FROM messages
    \\WHERE channel = ? ORDER BY uid DESC LIMIT ?;
, .{
    .kind = .rows,
    .cols = &.{
        .{ .id, u64 },
        .{ .origin, u64 },
        .{ .author, awebo.User.Id },
        .{ .body, []const u8 },
    },
    .args = struct {
        channel: awebo.Channel.Id,
        limit: u64,
    },
}),

const QueryConfig = struct {
    ctx: ?@TypeOf(context) = null,
    kind: enum { row, rows },
    cols: []const struct { @EnumLiteral(), type } = &.{},
    args: type = struct {},
};

fn Query(sql_query: [:0]const u8, config: QueryConfig) type {
    if (config.ctx) |ctx| if (ctx != context) return void;

    return struct {
        stmt: zqlite.Stmt,

        pub const cfg = config;
        pub const sql = sql_query;

        fn init(conn: zqlite.Conn) !@This() {
            const prep = conn.prepare(sql_query) catch fatalDb(conn, sql_query);
            return .{ .stmt = prep };
        }

        pub fn run(q: *@This(), args: config.args) Result(config) {
            const conn: zqlite.Conn = .{ .conn = q.stmt.conn };
            q.stmt.reset() catch fatalDb(conn, "reset");

            inline for (@typeInfo(config.args).@"struct".fields, 0..) |f, idx| {
                q.stmt.bindValue(@field(args, f.name), idx) catch fatalDb(conn, sql_query);
            }

            switch (config.kind) {
                .row => {
                    const one_row = q.stmt.step() catch fatalDb(conn, sql_query);
                    if (!one_row) return null;
                    return Rows(config).Row{ .row = .{ .stmt = q.stmt } };
                },
                .rows => {
                    return Rows(config){ .rows = .{ .stmt = q.stmt, .err = null } };
                },
            }
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

            pub fn deinit(self: Row) void {
                self.row.deinit();
            }

            pub fn get(r: Row, comptime col: @EnumLiteral()) ColType(col) {
                inline for (config.cols, 0..) |def, idx| {
                    if (def[0] == col) {
                        if (def[1] == void) @compileError("column doesn't specify type, use .getAs()");
                        return r.coerce(def[1], idx);
                    }
                }

                @compileError("column " ++ @tagName(col) ++ " does not exist in query");
            }

            pub fn getAs(r: Row, T: type, comptime col: @EnumLiteral()) T {
                inline for (config.cols, 0..) |def, idx| {
                    if (def[0] == col) {
                        if (def[1] != void) @compileError("column has a specified type, use .get()");
                        return r.coerce(T, idx);
                    }
                }

                @compileError("column " ++ @tagName(col) ++ " does not exist in query");
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
                    else => switch (@typeInfo(T)) {
                        .@"enum" => {
                            return @enumFromInt(r.row.int(idx));
                        },
                        else => @compileError("type " ++ @typeName(T) ++ " not supported"),
                    },
                }
            }

            /// Dupes the resulting value, use `textNoDupe` to avoid duping.
            pub fn text(r: Row, gpa: Allocator, comptime col: @EnumLiteral()) ![]const u8 {
                inline for (config.cols, 0..) |def, idx| {
                    if (def[0] == col) {
                        return gpa.dupe(u8, r.row.text(idx));
                    }
                }
                @compileError("column " ++ @tagName(col) ++ " does not exist in query");
            }
            pub fn textNoDupe(r: Row, comptime col: @EnumLiteral()) []const u8 {
                inline for (config.cols, 0..) |def, idx| {
                    if (def[0] == col) {
                        return r.row.text(idx);
                    }
                }
                @compileError("column " ++ @tagName(col) ++ " does not exist in query");
            }

            fn ColType(col: @EnumLiteral()) type {
                inline for (config.cols) |def| if (def[0] == col) return def[1];
                @compileError("column " ++ @tagName(col) ++ " does not exist in query");
            }
        };
    };
}

pub fn fatalDb(conn: zqlite.Conn, sql: []const u8) noreturn {
    log.err("fatal db error: {s} on query:\n{s}\n", .{ conn.lastError(), sql });
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}
