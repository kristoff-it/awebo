const std = @import("std");
const context = @import("options").context;
const awebo = @import("../../awebo.zig");

/// Contains host metadata such as the name and the creation datetime.
/// See awebo.Host
pub const host = .{
    \\CREATE TABLE host (
    \\  key          TEXT UNIQUE PRIMARY KEY NOT NULL,
    \\  value        NOT NULL
    \\);
};

pub const users = .{
    \\CREATE TABLE users (
    \\  id             INTEGER PRIMARY KEY ASC NOT NULL,
    \\  created        DATETIME NOT NULL,
    \\  updated        DATETIME NOT NULL,
    \\  invited_by     REFERENCES users ON DELETE SET NULL,
    //  awebo.User.Power
    \\  power          ENUM NOT NULL,
    \\  handle         TEXT UNIQUE NOT NULL,
    \\  display_name   TEXT NOT NULL,
    \\  avatar
    \\);
    ,
    \\CREATE UNIQUE INDEX users_by_handle ON users (handle);
    ,
};

pub const passwords = serverOnly(.{
    \\CREATE TABLE passwords (
    \\  id             REFERENCES users ON DELETE CASCADE PRIMARY KEY NOT NULL,
    \\  updated        DATETIME NOT NULL,
    // ip address that requested a password change, null if admin action
    \\  ip             IP NULL,
    \\  pswd_hash      TEXT NOT NULL
    \\);
});

pub const invites = serverOnly(.{
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
});

pub const roles = .{
    \\CREATE TABLE roles (
    \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
    \\  updated      DATETIME NOT NULL,
    \\  name         TEXT UNIQUE NOT NULL,
    \\  sort         INTEGER UNIQUE NOT NULL,
    \\  prominent    INTEGER NOT NULL
    \\);
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

pub const user_permissions = serverOnly(.{
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
});

pub const role_permissions = serverOnly(.{
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
});

pub const sections = .{
    \\CREATE TABLE sections (
    \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
    \\  updated      INTEGER NOT NULL,
    \\  sort         INTEGER UNIQUE NOT NULL,
    \\  name         TEXT UNIQUE,
    //  awebo.channels.Privacy
    \\  privacy      ENUM NOT NULL
    \\);
    ,

    serverOnly(
        std.fmt.comptimePrint(
            \\CREATE TRIGGER sections_cleanup AFTER DELETE ON sections BEGIN
            \\  DELETE FROM user_permissions WHERE kind = {0} AND resource = old.id; 
            \\  DELETE FROM role_permissions WHERE kind = {0} AND resource = old.id; 
            \\END;
        , .{@intFromEnum(awebo.permissions.Kind.section)}),
    ),
};

pub const channels = .{
    \\CREATE TABLE channels (
    \\  id           INTEGER PRIMARY KEY ASC NOT NULL,
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

    serverOnly(
        std.fmt.comptimePrint(
            \\CREATE TRIGGER channels_cleanup AFTER DELETE ON channels BEGIN
            \\  DELETE FROM user_permissions WHERE kind = {0} AND resource = old.id; 
            \\  DELETE FROM role_permissions WHERE kind = {0} AND resource = old.id; 
            \\END;
        , .{@intFromEnum(awebo.permissions.Kind.channel)}),
    ),
};

pub const messages = .{
    \\CREATE TABLE messages (
    \\  id           INTEGER PRIMARY KEY ASC,
    \\  origin       INTEGER,
    \\  updated      INTEGER,
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
};

pub const messages_search = serverOnly(.{
    \\CREATE VIRTUAL TABLE messages_search
    \\USING fts5(channel, author, body, content=messages, content_rowid=id)
    ,

    \\CREATE TRIGGER messages_search_insert AFTER INSERT ON messages BEGIN
    \\  INSERT INTO messages_search(rowid, channel, author, body)
    \\  VALUES (new.id, new.channel, new.author, new.body);
    \\END;
    ,

    \\CREATE TRIGGER messages_search_delete AFTER DELETE ON messages BEGIN
    \\  INSERT INTO messages_search(messages_search, rowid, channel, author, body)
    \\  VALUES ('delete', old.id, old.channel, old.author, old.body);
    \\END;
    ,
    \\CREATE TRIGGER messages_search_update AFTER UPDATE ON messages BEGIN
    \\  INSERT INTO messages_search(messages_search, rowid, channel, author, body)
    \\  VALUES ('delete', old.id, old.channel, old.author, old.body);
    \\
    \\  INSERT INTO messages_search(rowid, channel, author, body)
    \\  VALUES (new.id, new.channel, new.author, new.body);
    \\END;
});

pub const seen = serverOnly(.{
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
});

pub const notifications = serverOnly(.{
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
});

pub const emotes = serverOnly(.{
    \\CREATE TABLE emotes (
    \\  id           INTEGER PRIMARY KEY ASC AUTOINCREMENT,
    \\  created      TEXT NOT NULL,
    \\  name         TEXT NOT NULL,
    \\  image        TEXT NOT NULL
    \\);
    ,
    \\CREATE INDEX emotes_by_name ON emotes (name);
});

fn serverOnly(sql: anytype) ?@TypeOf(sql) {
    return switch (context) {
        .client => null,
        .server => sql,
    };
}
