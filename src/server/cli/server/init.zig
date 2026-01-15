const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Settings = @import("../../Settings.zig");
const Database = @import("../../Database.zig");
const zqlite = @import("zqlite");
const awebo = @import("../../../awebo.zig");

const log = std.log.scoped(.db);

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .create);
    defer db.conn.close();

    initSchema(db.conn) catch |err| {
        fatal("unable to initialize database: {t}", .{err});
    };

    try seed(io, gpa, cmd, db.conn);
}

// Map table/index names to sql string
const TableMap = std.StringArrayHashMapUnmanaged([:0]const u8);
const TableSet = std.StringArrayHashMapUnmanaged(void);
const TableInfo = std.StringArrayHashMapUnmanaged(TableInfoEntry);

const TableInfoEntry = struct {
    cid: i64,
    type: []const u8,
    not_null: bool,
    default_value: ?[]const u8,
    primary_key: bool,
};

fn tableInfoEql(lhs: *const TableInfo, rhs: *const TableInfo) bool {
    if (lhs.count() != rhs.count())
        return false;

    // Check to ensure all of the same columns exist between the two
    for (lhs.keys()) |column_name| {
        if (!rhs.contains(column_name))
            return false;

        const lhs_info = lhs.get(column_name).?;
        const rhs_info = rhs.get(column_name).?;
        if (lhs_info.cid != rhs_info.cid)
            return false;

        if (!std.mem.eql(u8, lhs_info.type, rhs_info.type))
            return false;

        if (lhs_info.not_null != rhs_info.not_null)
            return false;

        if (lhs_info.primary_key != rhs_info.primary_key)
            return false;

        const lhs_default_value = lhs_info.default_value orelse {
            if (rhs_info.default_value != null)
                return false
            else
                continue;
        };

        const rhs_default_value = rhs_info.default_value orelse return false;
        if (!std.mem.eql(u8, lhs_default_value, rhs_default_value))
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

fn getTables(arena: Allocator, conn: zqlite.Conn) !TableMap {
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
fn setDiff(gpa: Allocator, lhs: *const TableMap, rhs: *const TableMap) !TableSet {
    var ret: TableSet = .{};

    for (lhs.keys()) |name|
        if (!rhs.contains(name))
            try ret.put(gpa, name, {});

    return ret;
}

fn setUnion(gpa: Allocator, lhs: *const TableMap, rhs: *const TableMap) !TableSet {
    var ret: TableSet = .{};

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
    const pristine: zqlite.Conn = try .init(
        ":memory:",
        @intFromEnum(Database.Mode.create) | zqlite.OpenFlags.EXResCode,
    );
    defer pristine.close();

    log.debug("pristine init schema", .{});
    try initSchema(pristine);

    // ====================================
    // TABLES
    // ====================================
    const pristine_tables = try getTables(arena, pristine);
    const db_tables = try getTables(arena, conn);

    const new_tables = try setDiff(arena, &pristine_tables, &db_tables);
    const removed_tables = try setDiff(arena, &db_tables, &pristine_tables);
    const same_tables = try setUnion(arena, &pristine_tables, &db_tables);

    for (new_tables.keys()) |name| {
        log.info("Creating new table '{s}'", .{name});
        try conn.execNoArgs(pristine_tables.get(name).?);
    }

    for (removed_tables.keys()) |name| {
        log.info("Dropping table '{s}'", .{name});
        try dropTable(conn, name);
    }

    // If any columns change, then run the 12 steps:
    for (same_tables.keys()) |table_name| {
        const pristine_info = try tableInfo(arena, pristine, table_name);
        const db_info = try tableInfo(arena, conn, table_name);
        if (tableInfoEql(&pristine_info, &db_info))
            continue;

        log.info("detected change in table {s}", .{table_name});

        // If foreign key constraints are enabled, disable them using PRAGMA
        // foreign_keys=OFF.
        try conn.execNoArgs("PRAGMA foreign_keys=OFF");
        defer conn.execNoArgs("PRAGMA foreign_keys=ON") catch |err|
            fatal("Failed to enable foreign keys: {t}", .{err});

        // Start a transaction.
        try conn.transaction();
        {
            errdefer conn.rollback();
            errdefer std.log.err("sqlite last error: {s}", .{conn.lastError()});

            // Remember the format of all indexes, triggers, and views associated
            // with table X. This information will be needed in step 8 below. One
            // way to do this is to run a query like the following: SELECT type,
            // sql FROM sqlite_schema WHERE tbl_name='X'.
            const dependents = try getDependents(arena, conn, table_name);

            // Use CREATE TABLE to construct a new table "new_X" that is in the
            // desired revised format of table X. Make sure that the name "new_X"
            // does not collide with any existing table name, of course.
            const sql = pristine_tables.get(table_name).?;
            const idx = std.mem.find(u8, sql, table_name) orelse fatal("table name not found in sql: name={s}, sql={s}", .{
                table_name,
                sql,
            });

            const table_x_query = try std.mem.joinZ(arena, "", &.{
                sql[0 .. idx + table_name.len],
                "_X",
                sql[idx + table_name.len ..],
            });

            std.log.info("table_x_query: {s}", .{table_x_query});
            try conn.execNoArgs(table_x_query);

            // Transfer content from X into new_X using a statement like: INSERT
            // INTO new_X SELECT ... FROM X.

            // TODO: we have to get the union of fields between pristine and db, and get the default for new columns
            var column_names: std.ArrayList([]const u8) = .{};
            for (pristine_info.keys()) |column_name| {
                if (db_info.contains(column_name))
                    try column_names.append(gpa, column_name);
            }

            const transfer_query = try std.fmt.allocPrintSentinel(arena, "INSERT INTO {s}_X ({s}) SELECT {s} FROM {s}", .{
                table_name,
                try std.mem.join(arena, ", ", column_names.items),
                try std.mem.join(arena, ", ", column_names.items),
                table_name,
            }, 0);

            std.log.info("transfer query: {s}", .{transfer_query});
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
            for (dependents) |dependent| {
                log.debug("running dependent: {s}", .{dependent.sql});
                try conn.execNoArgs(dependent.sql);
            }

            // If any views refer to table X in a way that is affected by the
            // schema change, then drop those views using DROP VIEW and recreate
            // them with whatever changes are necessary to accommodate the schema
            // change using CREATE VIEW.

            // If we use views in any way, here's where to do it.

            // If foreign key constraints were originally enabled then run PRAGMA
            // foreign_key_check to verify that the schema change did not break any
            // foreign key constraints.

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

    const new_indexes = try setDiff(arena, &pristine_indexes, &db_indexes);
    const removed_indexes = try setDiff(arena, &db_indexes, &pristine_indexes);

    for (new_indexes.keys()) |name| {
        log.debug("Creating new index '{s}'", .{name});
        try conn.execNoArgs(pristine_indexes.get(name).?);
    }

    for (removed_indexes.keys()) |name| {
        log.debug("Dropping index '{s}'", .{name});
        try dropIndex(conn, name);
    }
}

fn initSchema(conn: zqlite.Conn) !void {
    inline for (comptime std.meta.declarations(tables)) |d| {
        const s = @field(tables, d.name);
        inline for (s, 0..) |q, i| {
            conn.execNoArgs(q) catch {
                log.err("while processing query '{s}' idx {} ", .{ d.name, i });
                fatalDb(conn);
            };
        }
    }

    inline for (comptime std.meta.declarations(indexes)) |d| {
        const s = @field(tables, d.name);
        inline for (s, 0..) |q, i| {
            conn.execNoArgs(q) catch {
                log.err("while processing query '{s}' idx {} ", .{ d.name, i });
                fatalDb(conn);
            };
        }
    }
}

fn seed(io: std.Io, gpa: Allocator, cmd: Command, conn: zqlite.Conn) !void {
    var out: [4096]u8 = undefined;
    const pass_str = std.crypto.pwhash.argon2.strHash(cmd.owner.password, .{
        .allocator = gpa,
        .params = .interactive_2id,
    }, &out, io) catch |err| {
        fatal("unable to hash admin password: {t}", .{err});
    };

    const admin = std.fmt.comptimePrint(
        \\INSERT INTO users VALUES
        \\  (0, 0, 0, 0, 0, {}, ?, ?, 'Admin', NULL)
        \\;
    , .{@intFromEnum(awebo.User.Power.owner)});
    conn.exec(admin, .{ cmd.owner.handle, pass_str }) catch fatalDb(conn);

    const settings: Settings = .{
        .name = cmd.server.name,
    };

    const setting_kv =
        \\INSERT INTO settings VALUES
        \\  (?, ?)
        \\;
    ;

    inline for (std.meta.fields(Settings)) |f| {
        conn.exec(setting_kv, .{ f.name, @field(settings, f.name) }) catch fatalDb(conn);
    }

    // const owner_role =
    //     // Give Owner role to first user.
    //     \\INSERT INTO user_roles (user, role) VALUES
    //     \\  (0, 0)
    //     \\;
    // ;
    // conn.exec(owner_role, .{}) catch fatalDb(conn);
}

const tables = struct {
    pub const settings = .{
        \\CREATE TABLE settings (
        \\  key          TEXT UNIQUE PRIMARY KEY NOT NULL,
        \\  value        NOT NULL
        \\);
    };

    pub const users = .{
        \\CREATE TABLE users (
        \\  id             INTEGER PRIMARY KEY ASC AUTOINCREMENT,
        \\  created        DATETIME NOT NULL,
        \\  updated        DATETIME NOT NULL,
        // When a user has roles added or removed to/from it, this field must be updated:
        \\  updated_roles  DATETIME NOT NULL,
        \\  invited_by     REFERENCES users NOT NULL,
        //  awebo.User.Power
        \\  power          ENUM NOT NULL,
        \\  handle         TEXT UNIQUE NOT NULL,
        \\  pswd_hash      TEXT NOT NULL,
        \\  display_name   TEXT NOT NULL,
        \\  avatar
        \\);
        ,
        \\CREATE UNIQUE INDEX users_by_handle ON users (handle);
        ,
    };
    pub const invites = .{
        \\CREATE TABLE invites (
        \\  slug           TEXT PRIMARY KEY NOT NULL,
        \\  created        DATETIME NOT NULL,
        \\  updated        DATETIME NOT NULL,
        \\  expiry         DATETIME NOT NULL,
        \\  creator        REFERENCES users ON DELETE CASCADE NOT NULL,
        \\  enabled        BOOL NOT NULL,
        \\  remaining      INTEGER NOT NULL
        \\);
        ,
    };

    pub const roles = .{
        \\CREATE TABLE roles (
        \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
        \\  created      DATETIME NOT NULL,
        \\  updated      DATETIME NOT NULL,
        \\  name         TEXT UNIQUE NOT NULL,
        \\  sort         INTEGER UNIQUE NOT NULL,
        \\  visible      INTEGER NOT NULL
        \\);
        ,
        \\INSERT INTO roles (id, created, updated, name, sort, visible) VALUES
        \\  (1, 0,  0, 'Moderator', 2, true)
        \\;
        ,
    };

    pub const user_roles = .{
        \\CREATE TABLE user_roles (
        \\  user         REFERENCES users ON DELETE CASCADE NOT NULL,
        \\  role         REFERENCES roles ON DELETE CASCADE NOT NULL,
        \\  PRIMARY KEY (user, role)
        \\) WITHOUT ROWID;
        ,
    };

    pub const user_permissions = .{
        \\CREATE TABLE user_permissions (
        \\  updated      INTEGER NOT NULL,
        \\  user         REFERENCES users ON DELETE CASCADE NOT NULL,
        // PermissionResourceKind
        \\  kind         ENUM NOT NULL,
        \\  resource     INTEGER NOT NULL,
        // ServerResource,
        \\  key          ENUM NOT NULL,
        \\  value        INTEGER NOT NULL,
        \\
        \\  PRIMARY KEY (user, kind, resource, key)
        \\) WITHOUT ROWID;
        ,
    };
    pub const role_permissions = .{
        \\CREATE TABLE role_permissions (
        \\  updated      INTEGER NOT NULL,
        \\  role         REFERENCES roles ON DELETE CASCADE NOT NULL,
        // PermissionResourceKind
        \\  kind         INTEGER NOT NULL,
        \\  resource     INTEGER NOT NULL,
        // ServerResource,
        \\  key          INTEGER NOT NULL,
        \\  value        INTEGER NOT NULL,
        \\
        \\  PRIMARY KEY (role, kind, resource, key)
        \\) WITHOUT ROWID;
        ,
    };

    pub const sections = .{
        \\CREATE TABLE sections (
        \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
        \\  created      INTEGER NOT NULL,
        \\  sort         INTEGER UNIQUE NOT NULL,
        \\  name         TEXT UNIQUE,
        //  awebo.channels.Privacy
        \\  privacy      ENUM NOT NULL
        \\);
        ,

        std.fmt.comptimePrint(
            \\CREATE TRIGGER sections_cleanup AFTER DELETE ON sections BEGIN
            \\  DELETE FROM user_permissions WHERE kind = {0} AND resource = old.id; 
            \\  DELETE FROM role_permissions WHERE kind = {0} AND resource = old.id; 
            \\END;
        , .{@intFromEnum(awebo.permissions.Kind.section)}),
    };

    pub const channels = .{
        \\CREATE TABLE channels (
        \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
        \\  created      DATETIME NOT NULL,
        \\  updated      DATETIME NOT NULL,
        \\  section      REFERENCES sections ON DELETE SET NULL,
        \\  sort         INTEGER NOT NULL,
        \\  name         TEXT UNIQUE NOT NULL,
        \\  kind         INTEGER,
        //  awebo.channels.Privacy
        \\  privacy      ENUM NOT NULL,
        \\
        \\  UNIQUE (section, sort)
        \\);
        ,
        std.fmt.comptimePrint(
            \\INSERT INTO channels VALUES
            \\  (0, 0, 0, NULL, 0, 'Default Chat Channel', 1, {0}),
            \\  (1, 0, 0, NULL, 0, 'Default Voice Channel', 2, {0})
            \\;
        , .{@intFromEnum(awebo.channels.Privacy.private)}),

        std.fmt.comptimePrint(
            \\CREATE TRIGGER channels_cleanup AFTER DELETE ON channels BEGIN
            \\  DELETE FROM user_permissions WHERE kind = {0} AND resource = old.id; 
            \\  DELETE FROM role_permissions WHERE kind = {0} AND resource = old.id; 
            \\END;
        , .{@intFromEnum(awebo.permissions.Kind.channel)}),
    };

    pub const messages = .{
        \\CREATE TABLE messages (
        \\  id           INTEGER PRIMARY KEY ASC,
        \\  origin       INTEGER,
        \\  channel      REFERENCES channels ON DELETE CASCADE,
        \\  author       REFERENCES users ON DELETE CASCADE,
        \\  body         TEXT NOT NULL,
        \\  reactions    TEXT
        \\) WITHOUT ROWID;
        ,
        \\CREATE INDEX messages_by_channel ON messages (channel);
        ,
        \\CREATE INDEX messages_by_author ON messages (author);
        ,
        // fulltext search
        \\CREATE VIRTUAL TABLE messages_search USING fts5(channel, author, body, content=messages, content_rowid=id)
        ,

        \\CREATE TRIGGER messages_search_insert AFTER INSERT ON messages BEGIN
        \\  INSERT INTO messages_search(rowid, channel, author, body) VALUES (new.id, new.channel, new.author, new.body);
        \\END;
        ,

        \\CREATE TRIGGER messages_search_delete AFTER DELETE ON messages BEGIN
        \\  INSERT INTO messages_search(messages_search, rowid, channel, author, body) VALUES ('delete', old.id, old.channel, old.author, old.body);
        \\END;
        ,
        \\CREATE TRIGGER messages_search_update AFTER UPDATE ON messages BEGIN
        \\  INSERT INTO messages_search(messages_search, rowid, channel, author, body) VALUES ('delete', old.id, old.channel, old.author, old.body);
        \\  INSERT INTO messages_search(rowid, channel, author, body) VALUES (new.id, new.channel, new.author, new.body);
        \\END;
    };

    pub const seen = .{
        \\CREATE TABLE seen (
        \\  user         REFERENCES users ON DELETE CASCADE NOT NULL,
        \\  channel      REFERENCES channels ON DELETE CASCADE NOT NULL,
        \\  last         INTEGER NOT NULL,
        \\
        \\  PRIMARY KEY (user, channel)
        \\);
        ,
        \\CREATE INDEX seen_by_user ON seen (user);
        ,
    };

    pub const notifications = .{
        \\CREATE TABLE notifications (
        \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
        \\  user         REFERENCES users ON DELETE CASCADE NOT NULL,
        \\  message      REFERENCES messages ON DELETE CASCADE NOT NULL,
        \\  created      INTEGER NOT NULL
        \\);
        ,
        \\CREATE INDEX notifications_by_user ON notifications (user);
        ,
        \\CREATE INDEX notifications_by_created ON notifications (created);
        ,
    };

    pub const emotes = .{
        \\CREATE TABLE emotes (
        \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
        \\  created      TEXT NOT NULL,
        \\  name         TEXT NOT NULL,
        \\  image        TEXT NOT NULL
        \\);
        ,
        \\CREATE INDEX emotes_by_name ON emotes (name);
    };
};

const indexes = struct {};

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

        const eql = std.mem.eql;
        while (it.next()) |arg| {
            if (eql(u8, arg, "--server-name")) {
                if (server_name != null) {
                    fatal("duplicate --server-name argument", .{});
                }
                server_name = it.next() orelse fatal("missing argument to --server-name", .{});
            } else if (eql(u8, arg, "--owner-handle")) {
                if (owner_handle != null) {
                    fatal("duplicate --owner-handle argument", .{});
                }
                owner_handle = it.next() orelse fatal("missing argument to --owner-handle", .{});
            } else if (eql(u8, arg, "--owner-pass")) {
                if (owner_pass != null) {
                    fatal("duplicate --owner-pass argument", .{});
                }
                owner_pass = it.next() orelse fatal("missing argument to --owner-pass", .{});
            } else if (eql(u8, arg, "--db-path")) {
                if (db_path != null) {
                    fatal("duplicate --db-path argument", .{});
                }
                db_path = it.next() orelse fatal("missing argument to --db-path", .{});
            } else if (eql(u8, arg, "--help") or eql(u8, arg, "-h")) {
                fatalHelp();
            } else {
                std.debug.print("unknown argument '{s}'\n", .{arg});
                fatalHelp();
            }
        }

        return .{
            .server = .{ .name = server_name orelse fatal("missing --server-name argument", .{}) },
            .owner = .{
                .handle = owner_handle orelse fatal("missing --owner-handle argument", .{}),
                .password = owner_pass orelse fatal("missing --owner-pass argument", .{}),
            },
            .db_path = db_path orelse "awebo.db",
        };
    }
};

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server server init REQUIRED_ARGS [OPTIONAL_ARGS]
        \\
        \\Create a SQLite database for a fresh new Awebo server.
        \\
        \\Required arguments:
        \\ --server-name NAME             Name of this Awebo server instance.
        \\ --owner-handle OWNER_HANDLE    Owner account username.
        \\ --owner-pass OWNER_PASS        Owner account password.
        \\
        \\Optional arguments:
        \\ --db-path DB_PATH              Path where to place the generated SQLite database.
        \\                                Defaults to 'awebo.db'.
        \\ --help, -h                     Show this menu and exit.
        \\
    , .{});

    std.process.exit(1);
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

fn fatalDb(conn: zqlite.Conn) noreturn {
    log.err("fatal db error: {s}", .{conn.lastError()});
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}
