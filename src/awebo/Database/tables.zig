const builtin = @import("builtin");
const std = @import("std");
const context = @import("options").context;
const awebo = @import("../../awebo.zig");
const zqlite = @import("zqlite");

const log = std.log.scoped(.tables);

pub const Table = struct {
    context: ?@TypeOf(context) = null,
    schema: [:0]const u8,
    indexes: []const [:0]const u8 = &.{},
    triggers: []const [:0]const u8 = &.{},
    server_only: struct {
        triggers: []const [:0]const u8 = &.{},
    } = .{},
};

pub fn init(db: awebo.Database) !void {
    try db.conn.transaction();

    inline for (comptime std.meta.declarations(@This())) |d| {
        const table = @field(@This(), d.name);
        if (@TypeOf(table) != @This().Table) continue;
        if (table.context) |ctx| if (ctx != context) continue;

        errdefer log.err("error creating table {s}", .{d.name});

        try db.conn.execNoArgs(table.schema);

        for (table.indexes, 0..) |index, i| {
            errdefer log.err("error creating index #{}", .{i});
            db.conn.execNoArgs(index) catch db.fatal(@src());
        }

        for (table.triggers, 0..) |trigger, i| {
            errdefer log.err("error creating trigger #{}", .{i});
            db.conn.execNoArgs(trigger) catch db.fatal(@src());
        }

        if (context == .server) {
            for (table.server_only.triggers, 0..) |trigger, i| {
                errdefer log.err("error creating server-only trigger #{}", .{i});
                db.conn.execNoArgs(trigger) catch db.fatal(@src());
            }
        }
    }

    try db.conn.commit();
}

/// Contains host metadata such as the name and the creation datetime.
/// See awebo.Host
pub const host: Table = .{ .schema =
    \\CREATE TABLE host (
    \\  key          TEXT UNIQUE PRIMARY KEY NOT NULL,
    \\  value        ANY NOT NULL
    \\);
};

pub const users: Table = .{
    .schema =
    \\CREATE TABLE users (
    \\  id             INTEGER PRIMARY KEY ASC NOT NULL,
    \\  created        DATETIME NOT NULL,
    \\  update_uid     INTEGER UNIQUE NOT NULL,
    // Before deleting a user, we must manually "detatch" any
    // invitee that we want to keep around, and make sure to
    // also update `update_uid`.
    \\  invited_by     REFERENCES users ON DELETE CASCADE NULL,
    //  awebo.User.Power
    \\  power          ENUM NOT NULL,
    \\  handle         TEXT UNIQUE NOT NULL,
    \\  display_name   TEXT NOT NULL,
    \\  avatar
    \\);
    ,
    .indexes = &.{
        \\CREATE UNIQUE INDEX users_by_handle ON users (handle);
    },
};

pub const passwords: Table = .{
    .context = .server,
    .schema =
    \\CREATE TABLE passwords (
    \\  handle         REFERENCES users(handle) ON DELETE CASCADE ON UPDATE CASCADE PRIMARY KEY NOT NULL,
    \\  updated        DATETIME NOT NULL,
    \\  hash           TEXT NOT NULL,
    // ip address that requested a password change, null if admin action
    \\  ip             IP NULL
    \\);
    ,
};

pub const invites: Table = .{
    .context = .server,
    .schema =
    \\CREATE TABLE invites (
    \\  slug           TEXT PRIMARY KEY NOT NULL,
    \\  created        DATETIME NOT NULL,
    \\  updated        DATETIME NOT NULL,
    \\  expiry         DATETIME NOT NULL,
    \\  creator        REFERENCES users ON DELETE CASCADE NOT NULL,
    \\  enabled        BOOL NOT NULL,
    \\  remaining      INTEGER NULL
    \\);
    ,
};

pub const roles: Table = .{
    .schema =
    \\CREATE TABLE roles (
    \\  id           INTEGER PRIMARY KEY ASC NOT NULL,
    \\  update_uid   INTEGER UNIQUE NOT NULL,
    \\  name         TEXT UNIQUE NOT NULL,
    \\  sort         INTEGER UNIQUE NOT NULL,
    \\  prominent    BOOL NOT NULL
    \\);
    ,
};

pub const user_roles: Table = .{
    .schema =
    \\CREATE TABLE user_roles (
    \\  user         REFERENCES users ON DELETE CASCADE NOT NULL,
    \\  role         REFERENCES roles ON DELETE CASCADE NOT NULL,
    \\  PRIMARY KEY (user, role)
    \\) WITHOUT ROWID;
    ,
};

pub const user_permissions: Table = .{
    .context = .server,
    .schema =
    \\CREATE TABLE user_permissions (
    // PermissionResourceKind
    \\  kind         ENUM NOT NULL,
    \\  resource     INTEGER NOT NULL,
    \\  key          ENUM NOT NULL,
    \\  value        INTEGER NOT NULL,
    \\  user         REFERENCES users ON DELETE CASCADE NOT NULL,
    \\
    \\  PRIMARY KEY (kind, resource, key, user)
    \\) WITHOUT ROWID;
    ,
};

pub const role_permissions: Table = .{
    .context = .server,
    .schema =
    \\CREATE TABLE role_permissions (
    // PermissionResourceKind
    \\  kind         INTEGER NOT NULL,
    \\  resource     INTEGER NOT NULL,
    \\  key          INTEGER NOT NULL,
    \\  value        INTEGER NOT NULL,
    \\  role         REFERENCES roles ON DELETE CASCADE NOT NULL,
    \\
    \\  PRIMARY KEY (kind, resource, key, role)
    \\) WITHOUT ROWID;
    ,
};

pub const sections: Table = .{
    .schema =
    \\CREATE TABLE sections (
    \\  id           INTEGER PRIMARY KEY ASC,
    \\  update_uid   INTEGER UNIQUE NOT NULL,
    \\  sort         INTEGER UNIQUE NOT NULL,
    \\  name         TEXT UNIQUE,
    //  awebo.channels.Privacy
    \\  privacy      ENUM NOT NULL
    \\);
    ,

    .server_only = .{
        .triggers = &.{
            std.fmt.comptimePrint(
                \\CREATE TRIGGER sections_cleanup AFTER DELETE ON sections BEGIN
                \\  DELETE FROM user_permissions WHERE kind = {0} AND resource = old.id; 
                \\  DELETE FROM role_permissions WHERE kind = {0} AND resource = old.id; 
                \\END;
            , .{@intFromEnum(awebo.permissions.Kind.section)}),
        },
    },
};

pub const channels: Table = .{
    .schema =
    \\CREATE TABLE channels (
    \\  id           INTEGER PRIMARY KEY ASC NOT NULL,
    \\  update_uid   INTEGER UNIQUE NOT NULL,
    // Before deleting a section all connected channels
    // must be detached first.
    \\  section      REFERENCES sections ON DELETE CASCADE,
    \\  sort         INTEGER NOT NULL,
    \\  name         TEXT NOT NULL,
    //  awebo.Channel.Kind.Enum
    \\  kind         INTEGER,
    //  awebo.Channel.Privacy
    \\  privacy      ENUM NOT NULL,
    \\
    \\  UNIQUE (section, sort),
    \\  UNIQUE (section, name)
    \\);
    ,

    .server_only = .{
        .triggers = &.{
            std.fmt.comptimePrint(
                \\CREATE TRIGGER channels_cleanup AFTER DELETE ON channels BEGIN
                \\  DELETE FROM user_permissions WHERE kind = {0} AND resource = old.id; 
                \\  DELETE FROM role_permissions WHERE kind = {0} AND resource = old.id; 
                \\END;
            , .{@intFromEnum(awebo.permissions.Kind.channel)}),
        },
    },
};

pub const messages: Table = .{
    .schema =
    \\CREATE TABLE messages (
    \\  uid          INTEGER PRIMARY KEY ASC NOT NULL,
    \\  origin       INTEGER,
    \\  created      DATETIME NOT NULL DEFAULT (unixepoch()),
    \\  update_uid   INTEGER NULL DEFAULT NULL,
    \\  channel      REFERENCES channels ON DELETE CASCADE NOT NULL,
    \\  author       REFERENCES users ON DELETE CASCADE NULL,
    \\  body         TEXT NOT NULL,
    \\  reactions    TEXT
    \\);
    ,
    .indexes = &.{
        // For queries that search for newly updated messages
        \\CREATE UNIQUE INDEX messages_by_update_uid ON messages (channel)
        \\WHERE update_uid != NULL;
        ,
        \\CREATE INDEX messages_by_channel ON messages (channel);
        ,
        // Searching by author should ignore messages that
        // have been assigned to 'deleted user' (i.e NULL)
        \\CREATE INDEX messages_by_author ON messages (author)
        \\WHERE author != NULL;
        ,
    },
};

pub const messages_search: Table = .{
    .context = .server,
    .schema =
    \\CREATE VIRTUAL TABLE messages_search
    \\USING fts5(channel, author, body, content=messages, content_rowid=uid)
    ,
    .triggers = &.{
        \\CREATE TRIGGER messages_search_insert AFTER INSERT ON messages BEGIN
        \\  INSERT INTO messages_search(rowid, channel, author, body)
        \\  VALUES (new.uid, new.channel, new.author, new.body);
        \\END;
        ,

        \\CREATE TRIGGER messages_search_delete AFTER DELETE ON messages BEGIN
        \\  INSERT INTO messages_search(messages_search, rowid, channel, author, body)
        \\  VALUES ('delete', old.uid, old.channel, old.author, old.body);
        \\END;
        ,
        \\CREATE TRIGGER messages_search_update AFTER UPDATE ON messages BEGIN
        \\  INSERT INTO messages_search(messages_search, rowid, channel, author, body)
        \\  VALUES ('delete', old.uid, old.channel, old.author, old.body);
        \\
        \\  INSERT INTO messages_search(rowid, channel, author, body)
        \\  VALUES (new.uid, new.channel, new.author, new.body);
        \\END;
    },
};

pub const seen: Table = .{
    .context = .server,
    .schema =
    \\CREATE TABLE seen (
    \\  user         REFERENCES users ON DELETE CASCADE NOT NULL,
    \\  channel      REFERENCES channels ON DELETE CASCADE NOT NULL,
    \\  last         INTEGER NOT NULL,
    \\
    \\  PRIMARY KEY (user, channel)
    \\);
    ,
    .indexes = &.{
        \\CREATE INDEX seen_by_user ON seen (user);
        ,
    },
};

pub const notifications: Table = .{
    .context = .server,
    .schema =
    \\CREATE TABLE notifications (
    \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
    \\  user         REFERENCES users ON DELETE CASCADE NOT NULL,
    \\  message      REFERENCES messages ON DELETE CASCADE NOT NULL,
    \\  created      INTEGER NOT NULL
    \\);
    ,
    .indexes = &.{
        \\CREATE INDEX notifications_by_user ON notifications (user);
        ,
        \\CREATE INDEX notifications_by_created ON notifications (created);
        ,
    },
};

pub const emotes: Table = .{
    .context = .server,
    .schema =
    \\CREATE TABLE emotes (
    \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
    \\  created      TEXT NOT NULL,
    \\  name         TEXT NOT NULL,
    \\  image        TEXT NOT NULL
    \\);
    ,
    .indexes = &.{
        \\CREATE INDEX emotes_by_name ON emotes (name);
        ,
    },
};
