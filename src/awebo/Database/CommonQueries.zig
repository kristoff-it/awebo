const context = @import("options").context;
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const awebo = @import("../../awebo.zig");
const Database = awebo.Database;
const Query = Database.Query;

const log = std.log.scoped(.query);

// -- Queries --
select_max_uid: Query(blk: {
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

    // NOTE: this query cannot end in a semicolon because we embed it
    //       in some other queries and the semicolon would be a syntax
    //       error in that context, even though this query by itself
    //       would be correct.
    query = query ++ "\n)";
    break :blk query;
}, .{
    .kind = .row,
    .cols = struct { max_uid: u64 },
}),

select_host_info: Query(
    \\SELECT key, value FROM host;
,
    .{
        .kind = .rows,
        .cols = struct {
            key: []const u8,
            value: void,
            // value has a different type per row,
            // use .getAs() to specify the expected type
        },
    },
),

select_channels: Query(
    \\SELECT id, name, update_uid, privacy, kind FROM channels;
, .{
    .kind = .rows,
    .cols = struct {
        id: u64,
        name: []const u8,
        update_uid: u64,
        privacy: awebo.Channel.Privacy,
        kind: awebo.Channel.Kind.Enum,
    },
}),

select_channel_messages: Query(
    \\SELECT uid, origin, created, update_uid, author, body FROM messages
    \\WHERE channel = ? ORDER BY uid DESC LIMIT ?;
, .{
    .kind = .rows,
    .cols = struct {
        uid: u64,
        origin: u64,
        created: awebo.Date,
        update_uid: u64,
        author: awebo.User.Id,
        body: []const u8,
    },
    .args = struct {
        channel: awebo.Channel.Id,
        limit: u64,
    },
}),

select_channel_history: Query(
    \\SELECT uid, origin, created, update_uid, author, body FROM messages
    \\WHERE channel = ?1 AND uid < ?2 ORDER BY uid DESC LIMIT ?3;
, .{
    .kind = .rows,
    .cols = struct {
        uid: awebo.Message.Id,
        origin: u64,
        created: awebo.Date,
        update_uid: u64,
        author: awebo.User.Id,
        body: []const u8,
    },
    .args = struct {
        channel: awebo.Channel.Id,
        below_uid: awebo.Message.Id,
        limit: u64,
    },
}),

select_channel_present: Query(
    \\SELECT uid, origin, created, update_uid, author, body FROM messages
    \\WHERE channel = ?1 AND uid > ?2 ORDER BY uid ASC LIMIT ?3;
, .{
    .kind = .rows,
    .cols = struct {
        uid: awebo.Message.Id,
        origin: u64,
        created: awebo.Date,
        update_uid: u64,
        author: awebo.User.Id,
        body: []const u8,
    },
    .args = struct {
        channel: awebo.Channel.Id,
        above_uid: awebo.Message.Id,
        limit: u64,
    },
}),

select_users: Query(
    \\SELECT id, created, update_uid, handle, power, invited_by, display_name FROM users
, .{
    .kind = .rows,
    .cols = struct {
        id: u64,
        created: awebo.Date,
        update_uid: u64,
        handle: []const u8,
        power: awebo.User.Power,
        invited_by: awebo.User.Id,
        display_name: []const u8,
    },
}),

insert_user: Query(
    \\INSERT INTO users
    \\  (created, update_uid, invited_by, power, handle,
    \\     display_name, avatar)
    \\  VALUES
    \\  (?1,         ?2,         ?3,         ?4,     ?5,
    \\     ?6,           NULL)
    \\RETURNING users.id
    \\;
, .{
    .kind = .row,
    .cols = struct { id: awebo.User.Id },
    .args = struct {
        created: u64,
        update_uid: u64,
        invited_by: ?awebo.User.Id,
        power: awebo.User.Power,
        handle: []const u8,
        display_name: []const u8,
    },
}),

insert_channels: Query(std.fmt.comptimePrint(
    \\INSERT INTO channels
    \\  (update_uid, section, sort, name, kind, privacy)
    \\ VALUES
    \\  (?1, NULL, 0, 'Default Chat Channel', 0, {0}),
    \\  (?2, NULL, 0, 'Second Chat Channel', 0, {0}),
    \\  (?3, NULL, 0, 'Default Voice Channel', 1, {0})
    \\;
, .{@intFromEnum(awebo.Channel.Privacy.private)}), .{
    .kind = .exec,
    .args = struct { u64, u64, u64 },
}),

insert_roles: Query(
    \\INSERT INTO roles (update_uid, name, sort, prominent) VALUES
    \\  (?, 'Moderator', 2, true)
    \\;
, .{
    .kind = .exec,
    .args = struct { u64 },
}),

insert_host_kv: Query(
    \\INSERT INTO host VALUES
    \\  (?, ?)
    \\;
, .{
    .kind = .exec,
    .args = struct { key: []const u8, value: Database.AnyArg },
}),

insert_message: Query(
    \\INSERT INTO messages
    \\    (uid, origin, created, update_uid, channel, author, body)
    \\  VALUES
    \\    (?, ?, ?, ?, ?, ?, ?)
    \\;
, .{
    .kind = .exec,
    .args = struct {
        uid: u64,
        origin: u64,
        created: awebo.Date,
        update_uid: ?u64,
        channel: awebo.Channel.Id,
        author: ?awebo.User.Id,
        body: []const u8,
    },
}),

delete_message: Query(
    "DELETE FROM messages WHERE uid = ?",
    .{ .kind = .exec, .args = struct { awebo.Message.Id } },
),

// client queries

upsert_host_kv: Query(
    \\INSERT INTO host(key, value) VALUES (?1, ?2)
    \\ON CONFLICT(key) DO UPDATE SET value = ?2
, .{
    .kind = .exec,
    .args = struct { key: []const u8, value: Database.AnyArg },
}),

upsert_user: Query(
    \\INSERT INTO users(id, created, update_uid, invited_by, power, handle, display_name, avatar)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
    \\ON CONFLICT(id) DO UPDATE
    \\SET (created, update_uid, invited_by, power, handle, display_name, avatar)
    \\ = (?2, ?3, ?4, ?5, ?6, ?7, ?8)
    \\ON CONFLICT(handle) DO UPDATE
    \\SET (created, update_uid, invited_by, power, handle, display_name, avatar)
    \\ = (?2, ?3, ?4, ?5, ?6, ?7, ?8)
, .{
    .kind = .exec,
    .args = struct {
        id: awebo.User.Id,
        created: u64,
        update_uid: u64,
        invited_by: awebo.User.Id,
        power: awebo.User.Power,
        handle: []const u8,
        display_name: []const u8,
        avatar: ?[]const u8,
    },
}),

upsert_channel: Query(
    \\INSERT INTO channels(id, update_uid, section, sort, name, kind, privacy)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
    \\ON CONFLICT(id) DO UPDATE
    \\SET (update_uid, section, sort, name, kind, privacy)
    \\ = (?2, ?3, ?4, ?5, ?6, ?7)
    \\ON CONFLICT(update_uid) DO UPDATE
    \\SET (update_uid, section, sort, name, kind, privacy)
    \\ = (?2, ?3, ?4, ?5, ?6, ?7)
, .{
    .kind = .exec,
    .args = struct {
        id: awebo.Channel.Id,
        update_uid: u64,
        section: ?u64,
        sort: u64,
        name: []const u8,
        kind: awebo.Channel.Kind.Enum,
        privacy: awebo.Channel.Privacy,
    },
}),

upsert_message: Query(
    \\INSERT INTO
    \\messages(uid, origin, created, update_uid, channel, author, body, reactions)
    \\VALUES  (?1,  ?2,     ?3,      ?4,         ?5,      ?6,     ?7,   ?8)
    \\ON CONFLICT(uid) DO UPDATE
    \\SET(origin, created, update_uid, channel, author, body, reactions)
    \\ = (?2,     ?3,      ?4,         ?5,      ?6,     ?7,   ?8)
    // \\ON CONFLICT(update_uid) DO UPDATE
    // \\SET(origin, created, update_uid, channel, author, body, reactions)
    // \\ = (?2,     ?3,      ?4,         ?5,      ?6,     ?7,   ?8)
, .{
    .kind = .exec,
    .args = struct {
        uid: awebo.Message.Id,
        origin: u64,
        created: awebo.Date,
        update_uid: ?u64,
        channel: awebo.Channel.Id,
        author: awebo.User.Id,
        body: []const u8,
        reactions: ?[]const u8 = null,
    },
}),
