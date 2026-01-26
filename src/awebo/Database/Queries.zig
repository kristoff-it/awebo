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

pub fn run(qs: *const Queries, comptime query: std.meta.FieldEnum(Queries), args: Args(query)) Result(query) {
    const db: awebo.Database = @fieldParentPtr("queries", qs);

    switch (query) {
        inline else => |tag| {
            const q = @field(qs, @tagName(tag));
            const config = @TypeOf(q).cfg;

            const s: zqlite.Stmt = .{
                .conn = db.conn,
                .stmt = q.stmt,
            };

            s.reset() catch db.fatal(@src());
            s.bind(args) catch db.fatal(@src());

            switch (config.kind) {
                .row => {
                    s.step() catch db.fatal(@src());
                    assert(false == s.step() catch db.fatal(@src()));
                    return Rows(config).Row{ .row = .{ .stmt = s } };
                },
                .rows => {
                    return Rows(config){ .rows = .{ .stmt = s } };
                },
            }
        },
    }
}

fn Args(query: std.meta.FieldEnum(Queries)) type {
    var qs: Queries = undefined;
    const config = @TypeOf(@field(qs, @tagName(query))).cfg;
    return config.args;
}

fn Result(query: std.meta.FieldEnum(Queries)) type {
    var qs: Queries = undefined;
    const config = @TypeOf(@field(qs, @tagName(query))).cfg;
    return switch (config.kind) {
        .row => Rows(config).Row,
        .rows => Rows(config),
    };
}

// -- Queries --
select_host_info: Query(
    \\SELECT key, value FROM host;
,
    .{
        .kind = .rows,
        .cols = &.{
            .{ .key, []const u8 },
            .{ .value, void },
            // value has a different type per row,
            // use the raw statement type to access it
        },
    },
),

select_user_limits: Query(
    \\SELECT COUNT(*), MAX(id) FROM users;
,
    .{
        .kind = .row,
        .cols = &.{
            .{ .count, u64 },
            .{ .max_id, u64 },
        },
    },
),

const QueryConfig = struct {
    ctx: ?@TypeOf(context) = null,
    kind: enum { row, rows },
    cols: []const struct { @EnumLiteral(), type } = &.{},
    args: type = struct {},
};

fn Query(sql: [:0]const u8, config: QueryConfig) type {
    if (config.ctx) |ctx| if (ctx != context) return void;

    return struct {
        // We unwrap zqlite.Stmt to remove the redundant
        // pointer to the database connection
        stmt: *zqlite.c.sqlite3_stmt,

        pub var cfg = config;
        fn init(conn: zqlite.Conn) !@This() {
            const prep = conn.prepare(sql) catch fatalDb(conn);
            return .{ .stmt = @ptrCast(prep.stmt) };
        }
    };
}

fn fatalDb(conn: zqlite.Conn) noreturn {
    log.err("fatal db error: {s}", .{conn.lastError()});
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

pub fn Rows(config: QueryConfig) type {
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

            pub fn get(r: Row, comptime col: @EnumLiteral()) ColType(col) {
                inline for (config.cols, 0..) |def, idx| {
                    if (def[0] == col) {
                        switch (def[1]) {
                            u64 => return @as(u64, @intCast(r.row.int(idx))),
                            []u8, []const u8 => @compileError("use text() or textNoDupe()"),
                        }
                    }
                }
            }

            /// Dupes the resulting value, use `textNoDupe` to avoid duping.
            pub fn text(r: Row, gpa: Allocator, comptime col: @EnumLiteral()) ![]const u8 {
                inline for (config.cols, 0..) |def, idx| {
                    if (def[0] == col) {
                        return gpa.dupe(u8, r.row.text(idx));
                    }
                }
                @compileError("column " ++ @tagName(col) ++ "does not exist in query");
            }
            pub fn textNoDupe(r: Row, comptime col: @EnumLiteral()) []const u8 {
                inline for (config.cols, 0..) |def, idx| {
                    if (def[0] == col) {
                        return r.row.text(idx);
                    }
                }
                @compileError("column " ++ @tagName(col) ++ "does not exist in query");
            }

            fn ColType(col: @EnumLiteral()) type {
                inline for (config.cols) |def| if (def[0] == col) return def[1];
                @compileError("column " ++ @tagName(col) ++ "does not exist in query");
            }
        };
    };
}
