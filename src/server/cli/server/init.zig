const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zqlite = @import("zqlite");
const Settings = @import("../../Settings.zig");
const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const Query = Database.Query;
const user_add = @import("../user/add.zig");
const cli = @import("../../../cli.zig");

const log = std.log.scoped(.db);

pub const Queries = struct {
    insert_user: @FieldType(Database.CommonQueries, "insert_user"),
    insert_password: @FieldType(user_add.Queries, "insert_password"),
    insert_channels: @FieldType(Database.CommonQueries, "insert_channels"),
    insert_message: @FieldType(Database.CommonQueries, "insert_message"),
    insert_roles: @FieldType(Database.CommonQueries, "insert_roles"),
    insert_host_kv: @FieldType(Database.CommonQueries, "insert_host_kv"),
};

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .create);
    defer db.conn.close();

    const qs = db.initQueries(Queries);
    defer db.deinitQueries(Queries, &qs);

    try seed(io, gpa, cmd, db, &qs);
}

fn seed(
    io: std.Io,
    gpa: Allocator,
    cmd: Command,
    db: Database,
    qs: *const Queries,
) !void {
    var id: awebo.IdGenerator = .init(0);

    var out: [4096]u8 = undefined;
    const pass_str = std.crypto.pwhash.argon2.strHash(cmd.owner.password, .{
        .allocator = gpa,
        .params = .interactive_2id,
    }, &out, io) catch |err| {
        cli.fatal("unable to hash admin password: {t}", .{err});
    };

    const admin = qs.insert_user.run(@src(), db, .{
        .created = 0,
        .update_uid = id.new(),
        .handle = cmd.owner.handle,
        .invited_by = 1,
        .power = .owner,
        .display_name = "Admin",
    }).?.get(.id);

    qs.insert_password.run(@src(), db, .{
        .handle = cmd.owner.handle,
        .hash = pass_str,
    });

    const user = qs.insert_user.run(@src(), db, .{
        .created = 0,
        .update_uid = id.new(),
        .handle = "user",
        .invited_by = 1,
        .power = .user,
        .display_name = "Other User",
    }).?.get(.id);

    qs.insert_password.run(@src(), db, .{
        .handle = "user",
        .hash = pass_str,
    });

    qs.insert_channels.run(@src(), db, .{
        id.new(),
        id.new(),
        id.new(),
    });

    const epoch = Io.Clock.real.now(io);

    // _ = user;
    // _ = admin;
    var buf: [1024]u8 = undefined;
    for (0..100) |i| {
        qs.insert_message.run(@src(), db, .{
            .uid = id.new(),
            .origin = 0,
            .created = .now(io, epoch.toSeconds()),
            .update_uid = null,
            .author = if (i % 2 == 0) admin else user,
            .channel = 1,
            .body = std.fmt.bufPrint(&buf, "message #{}", .{i}) catch unreachable,
        });
    }

    qs.insert_roles.run(@src(), db, .{id.new()});

    const settings: Settings = .{
        .name = cmd.server.name,
        .epoch = epoch.toSeconds(),
    };

    inline for (std.meta.fields(Settings)) |f| {
        qs.insert_host_kv.run(@src(), db, .{
            .key = f.name,
            .value = .init(@field(settings, f.name)),
        });
    }

    std.debug.print(
        \\Database initialized correctly, you can now start your awebo server:
        \\$ awebo-server server run
        \\
        \\
    , .{});
}

// Map table/index names to sql string
const StringMap = std.StringArrayHashMapUnmanaged;
const StringSet = std.StringArrayHashMapUnmanaged(void);
const TableMap = StringMap([:0]const u8);
const IndexMap = StringMap([:0]const u8);
const TableInfo = StringMap(TableInfoEntry);

const TableInfoEntry = struct {
    cid: i64,
    type: []const u8,
    not_null: bool,
    default_value: ?[]const u8,
    primary_key: bool,
};

fn tableInfoEntryEql(lhs: *const TableInfoEntry, rhs: *const TableInfoEntry) bool {
    if (lhs.cid != rhs.cid)
        return false;

    if (!std.mem.eql(u8, lhs.type, rhs.type))
        return false;

    if (lhs.not_null != rhs.not_null)
        return false;

    if (lhs.primary_key != rhs.primary_key)
        return false;

    const lhs_default_value = lhs.default_value orelse {
        if (rhs.default_value != null)
            return false
        else
            return true;
    };

    const rhs_default_value = rhs.default_value orelse return false;
    if (!std.mem.eql(u8, lhs_default_value, rhs_default_value))
        return false;

    return true;
}

fn tableInfoEql(lhs: *const TableInfo, rhs: *const TableInfo) bool {
    if (lhs.count() != rhs.count())
        return false;

    // Check to ensure all of the same columns exist between the two
    for (lhs.keys()) |column_name| {
        if (!rhs.contains(column_name))
            return false;

        const lhs_info = lhs.getPtr(column_name).?;
        const rhs_info = rhs.getPtr(column_name).?;
        if (!tableInfoEntryEql(lhs_info, rhs_info))
            return false;
    }

    return true;
}

fn tableInfo(arena: Allocator, conn: zqlite.Conn, table_name: []const u8) !TableInfo {
    errdefer std.log.err("sqlite last error: {s}", .{conn.lastError()});
    var buf: [256]u8 = undefined;
    const query = try std.fmt.bufPrint(&buf, "PRAGMA table_info({s})", .{table_name});

    var rows = try conn.rows(query, .{});
    defer rows.deinit();

    var table_info: TableInfo = .{};
    while (rows.next()) |row| {
        const cid = row.int(0);
        const column_name = try arena.dupe(u8, row.text(1));
        const sqlite_type = try arena.dupe(u8, row.text(2));
        const not_null = if (row.int(3) == 0) false else true;
        const default_value = if (row.nullableText(4)) |text| try arena.dupe(u8, text) else null;
        const primary_key = if (row.int(5) == 0) false else true;
        try table_info.put(arena, column_name, .{
            .cid = cid,
            .type = sqlite_type,
            .not_null = not_null,
            .default_value = default_value,
            .primary_key = primary_key,
        });
    }

    return table_info;
}

fn getTables(arena: Allocator, db: awebo.Database) !TableMap {
    const conn = db.conn;
    var rows = try conn.rows(
        \\SELECT name, sql FROM sqlite_schema
        \\WHERE type = 'table' AND name != 'sqlite_sequence'
    , .{});
    defer rows.deinit();

    var ret: TableMap = .{};
    while (rows.next()) |row| {
        const name = try arena.dupe(u8, row.text(0));
        const sql = try arena.dupeZ(u8, row.text(1));
        try ret.put(arena, name, sql);
    }

    if (rows.err) |err|
        return err;

    return ret;
}

fn getIndexes(arena: Allocator, conn: zqlite.Conn) !TableMap {
    var rows = try conn.rows(
        \\SELECT name, sql FROM sqlite_schema
        \\WHERE type = 'index' AND sql IS NOT NULL
    , .{});
    defer rows.deinit();

    var ret: TableMap = .{};
    while (rows.next()) |row| {
        const name = try arena.dupe(u8, row.text(0));
        const sql = try arena.dupeZ(u8, row.text(1));
        try ret.put(arena, name, sql);
    }

    if (rows.err) |err|
        return err;

    return ret;
}

const Dependent = struct {
    type: []const u8,
    name: []const u8,
    sql: [:0]const u8,
};

fn getDependents(gpa: Allocator, conn: zqlite.Conn, table_name: []const u8) ![]Dependent {
    var rows = try conn.rows(
        \\SELECT type, name, sql
        \\FROM sqlite_schema
        \\ WHERE tbl_name = ? AND type IS NOT 'table' AND sql IS NOT NULL
    , .{table_name});
    defer rows.deinit();

    var list: std.ArrayList(Dependent) = .{};
    while (rows.next()) |row| {
        try list.append(gpa, .{
            .type = try gpa.dupe(u8, row.text(0)),
            .name = try gpa.dupe(u8, row.text(1)),
            .sql = try gpa.dupeZ(u8, row.text(2)),
        });
    }

    return try list.toOwnedSlice(gpa);
}

// Subtract one set from another, gives you the keys that are in lhs but not rhs
fn setDiff(comptime Map: type, comptime Set: type, gpa: Allocator, lhs: *const Map, rhs: *const Map) !Set {
    var ret: Set = .{};

    for (lhs.keys()) |name|
        if (!rhs.contains(name))
            try ret.put(gpa, name, {});

    return ret;
}

fn setUnion(comptime Map: type, comptime Set: type, gpa: Allocator, lhs: *const Map, rhs: *const Map) !Set {
    var ret: Set = .{};

    for (lhs.keys()) |name|
        if (rhs.contains(name))
            try ret.put(gpa, name, {});

    return ret;
}

fn dropTable(conn: zqlite.Conn, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf, "DROP TABLE {s};", .{name});
    try conn.execNoArgs(sql);
}

fn dropIndex(conn: zqlite.Conn, name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&buf, "DROP INDEX {s}", .{name});
    try conn.execNoArgs(sql);
}

// https://www.sqlite.org/lang_altertable.html
pub fn migrateSchema(gpa: Allocator, conn: zqlite.Conn) !void {
    var arena_alloc: std.heap.ArenaAllocator = .init(gpa);
    defer arena_alloc.deinit();

    const arena = arena_alloc.allocator();

    log.debug("creating pristine", .{});
    const pristine: awebo.Database = try .init(
        ":memory:",
        @intFromEnum(Database.Mode.create) | zqlite.OpenFlags.EXResCode,
    );
    defer pristine.close();

    log.debug("pristine init schema", .{});
    try pristine.createSchema();

    var changes_made = false;

    // ====================================
    // TABLES
    // ====================================
    const pristine_tables = try getTables(arena, pristine);
    const db_tables = try getTables(arena, conn);

    const new_tables = try setDiff(TableMap, StringSet, arena, &pristine_tables, &db_tables);
    const removed_tables = try setDiff(TableMap, StringSet, arena, &db_tables, &pristine_tables);
    const same_tables = try setUnion(TableMap, StringSet, arena, &pristine_tables, &db_tables);

    for (new_tables.keys()) |name| {
        changes_made = true;
        log.info("Creating new table '{s}'", .{name});
        try conn.execNoArgs(pristine_tables.get(name).?);
    }

    for (removed_tables.keys()) |name| {
        changes_made = true;
        log.info("Dropping table '{s}'", .{name});
        try dropTable(conn, name);
    }

    // If any columns change, then run the 12 steps:
    for (same_tables.keys()) |table_name| {
        const pristine_info = try tableInfo(arena, pristine, table_name);
        const db_info = try tableInfo(arena, conn, table_name);
        if (tableInfoEql(&pristine_info, &db_info))
            continue;

        changes_made = true;

        // If foreign key constraints are enabled, disable them using PRAGMA
        // foreign_keys=OFF.
        try conn.execNoArgs("PRAGMA foreign_keys=OFF");
        defer conn.execNoArgs("PRAGMA foreign_keys=ON") catch |err|
            cli.fatal("Failed to enable foreign keys: {t}", .{err});

        // Start a transaction.
        try conn.transaction();
        {
            errdefer conn.rollback();

            // Remember the format of all indexes, triggers, and views associated
            // with table X. This information will be needed in step 8 below. One
            // way to do this is to run a query like the following: SELECT type,
            // sql FROM sqlite_schema WHERE tbl_name='X'.
            const dependents = try getDependents(arena, conn, table_name);

            // Use CREATE TABLE to construct a new table "new_X" that is in the
            // desired revised format of table X. Make sure that the name "new_X"
            // does not collide with any existing table name, of course.
            const sql = pristine_tables.get(table_name).?;
            const idx = std.mem.find(u8, sql, table_name) orelse cli.fatal("Table name not found in sql: name={s}, sql={s}", .{
                table_name,
                sql,
            });

            const table_x_query = try std.mem.joinZ(arena, "", &.{
                sql[0 .. idx + table_name.len],
                "_X",
                sql[idx + table_name.len ..],
            });

            try conn.execNoArgs(table_x_query);

            const new_columns = try setDiff(TableInfo, StringSet, arena, &pristine_info, &db_info);
            const removed_columns = try setDiff(TableInfo, StringSet, arena, &db_info, &pristine_info);
            const same_columns = try setUnion(TableInfo, StringSet, arena, &pristine_info, &db_info);
            for (new_columns.keys()) |column_name| {
                const info = pristine_info.get(column_name).?;
                const default_value: []const u8 = if (info.not_null)
                    if (info.default_value) |dv| dv else {
                        log.err("When creating a new column, if it is NOT NULL, you must give it a default value: table={s} column={s}", .{
                            table_name,
                            column_name,
                        });

                        return error.InvalidSchema;
                    }
                else
                    "NULL";
                log.info("Adding new column to table '{s}': '{s}', default_value={s}", .{ table_name, column_name, default_value });
            }

            for (removed_columns.keys()) |column_name|
                log.info("Dropping column from table '{s}': '{s}'", .{ table_name, column_name });

            for (same_columns.keys()) |column_name| {
                const original_col = db_info.getPtr(column_name).?;
                const pristine_col = pristine_info.getPtr(column_name).?;
                if (!tableInfoEntryEql(original_col, pristine_col)) {
                    log.info("Column modified in table '{s}': '{s}'", .{ table_name, column_name });
                }
            }

            // Transfer content from X into new_X using a statement like: INSERT
            // INTO new_X SELECT ... FROM X.
            const column_list = try std.mem.join(arena, ", ", same_columns.keys());
            const transfer_query = try std.fmt.allocPrintSentinel(arena, "INSERT INTO {s}_X ({s}) SELECT {s} FROM {s}", .{
                table_name,
                column_list,
                column_list,
                table_name,
            }, 0);

            try conn.execNoArgs(transfer_query);

            // Drop the old table X: DROP TABLE X.
            try dropTable(conn, table_name);

            // Change the name of new_X to X using: ALTER TABLE new_X RENAME TO X.
            const rename_query = try std.fmt.allocPrintSentinel(arena, "ALTER TABLE {s}_X RENAME TO {s}", .{
                table_name,
                table_name,
            }, 0);
            try conn.execNoArgs(rename_query);

            // Use CREATE INDEX, CREATE TRIGGER, and CREATE VIEW to reconstruct
            // indexes, triggers, and views associated with table X. Perhaps use
            // the old format of the triggers, indexes, and views saved from step 3
            // above as a guide, making changes as appropriate for the alteration.
            for (dependents) |dependent|
                try conn.execNoArgs(dependent.sql);

            // If any views refer to table X in a way that is affected by the
            // schema change, then drop those views using DROP VIEW and recreate
            // them with whatever changes are necessary to accommodate the schema
            // change using CREATE VIEW.

            // If we use views in any way, here's where to do it.

            // If foreign key constraints were originally enabled then run PRAGMA
            // foreign_key_check to verify that the schema change did not break any
            // foreign key constraints.
            try conn.execNoArgs("PRAGMA foreign_key_check");
        }

        // Commit the transaction started in step 2.
        try conn.commit();

        // If foreign keys constraints were originally enabled, reenable them
        // now.
    }

    // ====================================
    // INDEXES
    // ====================================
    const pristine_indexes = try getIndexes(arena, pristine);
    const db_indexes = try getIndexes(arena, conn);

    const new_indexes = try setDiff(IndexMap, StringSet, arena, &pristine_indexes, &db_indexes);
    const removed_indexes = try setDiff(IndexMap, StringSet, arena, &db_indexes, &pristine_indexes);

    for (new_indexes.keys()) |name| {
        changes_made = true;
        log.debug("Creating new index '{s}'", .{name});
        try conn.execNoArgs(pristine_indexes.get(name).?);
    }

    for (removed_indexes.keys()) |name| {
        changes_made = true;
        log.debug("Dropping index '{s}'", .{name});
        try dropIndex(conn, name);
    }

    if (!changes_made)
        log.info("No changes made to DB schema", .{});
}

const Command = struct {
    server: struct { name: []const u8 },
    owner: struct {
        handle: []const u8,
        password: []const u8,
    },
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var server_name: ?[]const u8 = null;
        var owner_handle: ?[]const u8 = null;
        var owner_pass: ?[]const u8 = null;
        var db_path: ?[:0]const u8 = null;

        var args: cli.Args = .init(it);

        while (args.peek()) |current_arg| {
            if (args.help()) exitHelp(0);
            if (args.option("server-name")) |server_name_opt| {
                server_name = server_name_opt;
            } else if (args.option("owner-handle")) |owner_handle_opt| {
                owner_handle = owner_handle_opt;
            } else if (args.option("owner-pass")) |owner_pass_opt| {
                owner_pass = owner_pass_opt;
            } else if (args.option("db-path")) |db_path_opt| {
                db_path = db_path_opt;
            } else {
                cli.fatal("unknown argument '{s}'", .{current_arg});
            }
        }

        return .{
            .server = .{ .name = server_name orelse cli.fatal("missing --server-name argument", .{}) },
            .owner = .{
                .handle = owner_handle orelse cli.fatal("missing --owner-handle argument", .{}),
                .password = owner_pass orelse cli.fatal("missing --owner-pass argument", .{}),
            },
            .db_path = db_path orelse "awebo.db",
        };
    }
};

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server server init REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Create a SQLite database for a fresh new Awebo server.
        \\
        \\Required arguments:
        \\  --server-name NAME             Name of this Awebo server instance.
        \\  --owner-handle OWNER_HANDLE    Owner account username.
        \\  --owner-pass OWNER_PASS        Owner account password.
        \\
        \\Optional arguments:
        \\  --db-path DB_PATH    Path where to place the generated SQLite database.
        \\                       Defaults to 'awebo.db'.
        \\  --help, -h           Show this menu and exit.
        \\
    , .{});

    std.process.exit(status);
}

pub fn fatalDb(conn: zqlite.Conn, src: std.builtin.SourceLocation) noreturn {
    log.err("{s}:{}: fatal db error: {s}", .{ src.file, src.line, conn.lastError() });
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

test "server init queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
