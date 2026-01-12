const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Database = @import("../../Database.zig");
const zqlite = @import("zqlite");
const awebo = @import("../../../awebo.zig");

const log = std.log.scoped(.db);

pub fn run(gpa: Allocator, it: *std.process.ArgIterator) void {
    const cmd: Command = .parse(it);

    const db: Database = .init(cmd.db_path, .create);
    defer db.conn.close();

    initTables(gpa, cmd, db.conn) catch |err| {
        fatal("unable to initialize database: {t}", .{err});
    };
}

fn initTables(gpa: Allocator, cmd: Command, conn: zqlite.Conn) !void {
    inline for (comptime std.meta.declarations(tables)) |d| {
        const s = @field(tables, d.name);
        inline for (s, 0..) |q, i| {
            conn.execNoArgs(q) catch {
                log.err("while processing query '{s}' idx {} ", .{ d.name, i });
                fatalDb(conn);
            };
        }
    }

    var out: [4096]u8 = undefined;
    const pass_str = std.crypto.pwhash.argon2.strHash(cmd.owner.password, .{
        .allocator = gpa,
        .params = .interactive_2id,
    }, &out) catch |err| {
        fatal("unable to hash admin password: {t}", .{err});
    };

    const admin = std.fmt.comptimePrint(
        \\INSERT INTO users VALUES
        \\  (0, 0, 0, 0, 0, {}, ?, ?, 'Admin', NULL)
        \\;
    , .{@intFromEnum(awebo.User.Power.owner)});
    conn.exec(admin, .{ cmd.owner.handle, pass_str }) catch fatalDb(conn);

    const server_name =
        \\INSERT INTO settings VALUES
        \\  ('server_name', ?)
        \\;
    ;
    conn.exec(server_name, .{cmd.server.name}) catch fatalDb(conn);

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

const Command = struct {
    server: struct { name: []const u8 },
    owner: struct {
        handle: []const u8,
        password: []const u8,
    },
    db_path: [:0]const u8,

    fn parse(it: *std.process.ArgIterator) Command {
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
                .handle = owner_handle orelse fatal("missing --owner-name argument", .{}),
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
