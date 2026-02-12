const Host = @This();

const context = @import("options").context;
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const proto = @import("protocol.zig");
const HostSync = proto.server.HostSync;
const Database = @import("Database.zig");
const Channel = @import("Channel.zig");
const User = @import("User.zig");
const Caller = @import("Caller.zig");

const log = std.log.scoped(.awebo_host);

name: []const u8 = "",
logo: []const u8 = "", // TODO: draw default logo
epoch: i64 = 0,
// max_uid: u64 = 0,
channels: Channels = .{},
users: Users = .{},

client: switch (context) {
    .client => ClientOnly,
    .server => struct {
        pub const protocol = struct {
            pub const skip = true;
        };
    },
} = .{},

pub const protocol = struct {
    pub const sizes = struct {
        pub const name = u16;
        pub const logo = u16;
        pub const identity = u16;
    };
};

pub fn deinit(hs: *const Host, gpa: std.mem.Allocator) void {
    gpa.free(hs.name);
    gpa.free(hs.logo);
    hs.users.deinit(gpa);
    hs.channels.deinit(gpa);
}

pub fn computeDelta(
    host: *Host,
    gpa: Allocator,
    user_id: User.Id,
    client_max_uid: u64,
    server_max_uid: u64,
) !HostSync {
    if (context != .server) @compileError("server only");

    log.debug("computing delta for user {} max_uid {}", .{
        user_id, client_max_uid,
    });

    var delta_users: std.ArrayList(User) = .empty;
    var delta_channels: std.ArrayList(Channel) = .empty;

    for (host.users.items.values()) |u| {
        if (u.update_uid <= client_max_uid) continue;
        try delta_users.append(gpa, u);
    }
    for (host.channels.items.values()) |ch| {
        const has_new_message = switch (ch.kind) {
            .voice => false,
            .chat => |chat| if (chat.messages.latest()) |m|
                m.id > client_max_uid
            else
                false,
        };

        if (!has_new_message and ch.update_uid <= client_max_uid) continue;

        try delta_channels.append(gpa, ch);

        const delta_ch = &delta_channels.items[delta_channels.items.len - 1];
        switch (delta_ch.kind) {
            .voice => {},
            .chat => |*chat| {
                if (!has_new_message) {
                    chat.messages.len = 0;
                } else {
                    assert(chat.messages.len > 0);
                    while (chat.messages.at(0).id <= client_max_uid) {
                        chat.messages.tail +%= 1;
                        chat.messages.len -= 1;
                    }
                }
            },
        }
    }

    return .{
        .user_id = user_id,
        .server_max_uid = server_max_uid,
        .name = host.name,
        .epoch = host.epoch,
        .users = .{ .mode = .delta, .items = delta_users.items },
        .channels = .{ .mode = .delta, .items = delta_channels.items },
    };
}

pub fn sync(host: *Host, gpa: Allocator, delta: *const HostSync) void {
    if (context != .client) @compileError("client only");

    host.client.user_id = delta.user_id;
    host.client.connection_status = .synced;

    const db = host.client.db;
    const qs = &host.client.qs;

    {
        gpa.free(host.name);
        host.name = delta.name;
        host.epoch = delta.epoch;
        qs.upsert_host_kv.run(@src(), db, .{
            .key = "name",
            .value = .init(host.name),
        });
    }

    switch (delta.users.mode) {
        .full => {
            @panic("TODO");
        },
        .delta => {
            for (delta.users.items) |new_user| {
                if (host.users.get(new_user.id)) |u| {
                    u.deinit(gpa);
                    u.* = new_user;
                } else {
                    host.users.set(gpa, new_user) catch @panic("oom");
                }

                std.log.debug("upsert {f}", .{new_user});

                qs.upsert_user.run(@src(), db, .{
                    .id = new_user.id,
                    .created = 0,
                    // .update_uid = new_user.update_id,
                    .update_uid = new_user.id,
                    .invited_by = new_user.invited_by,
                    .power = new_user.power,
                    .handle = new_user.handle,
                    .display_name = new_user.display_name,
                    .avatar = null,
                });
            }
        },
    }

    switch (delta.channels.mode) {
        .full => @panic("TODO"),
        .delta => {
            for (delta.channels.items) |new_ch| {
                if (host.channels.get(new_ch.id)) |ch| {
                    assert(@as(Channel.Kind.Enum, ch.kind) == new_ch.kind);
                    ch.sync(gpa, db, qs, &new_ch);
                    qs.upsert_channel.run(@src(), db, .{
                        .id = new_ch.id,
                        .update_uid = new_ch.id,
                        .section = null,
                        .sort = 0,
                        .name = new_ch.name,
                        .kind = new_ch.kind,
                        .privacy = new_ch.privacy,
                    });
                } else {
                    host.channels.set(gpa, new_ch) catch @panic("oom");
                    qs.upsert_channel.run(@src(), db, .{
                        .id = new_ch.id,
                        .update_uid = new_ch.id,
                        .section = null,
                        .sort = 0,
                        .name = new_ch.name,
                        .kind = new_ch.kind,
                        .privacy = new_ch.privacy,
                    });
                    switch (new_ch.kind) {
                        .chat => |*chat| {
                            const slices = chat.messages.slices();
                            var oldest_uid: ?u64 = null;
                            for (slices) |s| for (s) |msg| {
                                log.debug("first time chat sync, saving to db msg {}", .{msg.id});
                                oldest_uid = oldest_uid orelse msg.id;
                                qs.upsert_message.run(@src(), db, .{
                                    .uid = msg.id,
                                    .origin = msg.origin,
                                    .created = msg.created,
                                    .update_uid = msg.update_uid,
                                    .kind = msg.kind,
                                    .channel = new_ch.id,
                                    .author = msg.author,
                                    .body = msg.text,
                                });
                            };

                            if (slices[0].len + slices[1].len == Channel.window_size) {
                                qs.upsert_message.run(@src(), db, .{
                                    .uid = oldest_uid.? - 1,
                                    .origin = 0,
                                    .created = .epoch,
                                    .update_uid = null,
                                    .kind = .missing_history,
                                    .channel = new_ch.id,
                                    .author = delta.user_id,
                                    .body = "",
                                });
                            }
                        },
                        else => {},
                    }
                }
            }
        },
    }
}

pub const ClientOnly = struct {
    const network = @import("../client/Core/network.zig");
    const ui = @import("../client/Core/ui.zig");

    pub const Id = u32;

    identity: []const u8 = undefined,
    host_id: Id = undefined,
    max_uid: u64 = undefined,
    user_id: User.Id = undefined,
    username: []const u8 = undefined,
    password: []const u8 = undefined,
    db: Database = undefined,
    qs: Database.CommonQueries = undefined,

    callers: Callers = .{},

    input_buf: [256]u8 = undefined,
    input_len: usize = 0,
    active_channel: ?Channel.Id = null,

    connection: ?*network.HostConnection = null,
    connection_status: ConnectionStatus = .connecting,

    pending_messages: std.AutoArrayHashMapUnmanaged(
        proto.client.OriginId,
        struct {
            cms: proto.client.ChatMessageSend,
            push_future: Io.Future(error{ Closed, Canceled }!void),
        },
    ) = .{},
    pending_requests: std.AutoArrayHashMapUnmanaged(u64, *u8) = .{},

    last_sent_typing: u64 = 0,

    pub const ConnectionStatus = union(enum) {
        connecting, // essentially the same as .disconected but should NOT be shown in UI
        connected: *network.HostConnection, // TODO: this maybe should be host state
        synced,
        disconnected: u64, // essentially the esame as .connecting but should be shown in UI
        reconnecting,
        deleting, // host is being deleted
    };

    pub const protocol = struct {
        pub const skip = true;
    };
};

pub const Users = struct {
    items: std.AutoArrayHashMapUnmanaged(User.Id, User) = .{},
    indexes: struct {
        handle: std.StringHashMapUnmanaged(User.Id) = .{},
    } = .{},

    pub const protocol = struct {
        pub const sizes = struct {
            pub const items = u32;
        };

        pub inline fn serialize(users: Users, comptime serializeFn: anytype, w: *Io.Writer) !void {
            try w.writeInt(sizes.items, @intCast(users.items.count()), .little);
            for (users.items.values()) |user| try serializeFn(user, w);
        }

        pub fn deserializeAlloc(comptime deserializeFn: anytype, gpa: Allocator, r: *Io.Reader) !Users {
            var users: Users = .{};
            errdefer users.deinit(gpa);

            const len = try r.takeInt(sizes.items, .little);
            for (0..len) |_| {
                const u: User = try deserializeFn(User, gpa, r);
                try users.set(gpa, u);
            }
            return users;
        }
    };

    pub fn deinit(u: *const Users, gpa: std.mem.Allocator) void {
        for (u.items.values()) |user| user.deinit(gpa);
        @constCast(&u.items).deinit(gpa);
        @constCast(&u.indexes.handle).deinit(gpa);
    }

    pub fn set(u: *Users, gpa: std.mem.Allocator, user: User) !void {
        const gop = try u.items.getOrPut(gpa, user.id);
        if (gop.found_existing) {
            const new_handle = std.mem.eql(u8, user.handle, gop.value_ptr.handle);
            if (new_handle) {
                assert(u.indexes.handle.remove(gop.value_ptr.handle));
                try u.indexes.handle.put(gpa, user.handle, user.id);
            }
            gop.value_ptr.deinit(gpa);
        } else {
            try u.indexes.handle.put(gpa, user.handle, user.id);
        }

        gop.value_ptr.* = user;
    }

    pub fn get(u: Users, id: User.Id) ?*User {
        return u.items.getPtr(id);
    }

    pub fn getId(u: Users, handle_: []const u8) ?User.Id {
        return u.indexes.handle.get(handle_);
    }

    pub fn handle(u: Users, handle_: []const u8) ?*User {
        const id = u.getId(handle_) orelse return null;
        return u.get(id);
    }
};

pub const Channels = struct {
    items: std.AutoArrayHashMapUnmanaged(Channel.Id, Channel) = .{},
    indexes: struct {
        name: std.StringHashMapUnmanaged(Channel.Id) = .{},
    } = .{},

    pub const protocol = struct {
        pub const sizes = struct {
            pub const items = u32;
        };

        pub inline fn serialize(channels: Channels, comptime serializeFn: anytype, w: *Io.Writer) !void {
            try w.writeInt(sizes.items, @intCast(channels.items.count()), .little);
            for (channels.items.values()) |ch| try serializeFn(ch, w);
        }

        pub fn deserializeAlloc(comptime deserializeFn: anytype, gpa: Allocator, r: *Io.Reader) !Channels {
            var channels: Channels = .{};
            errdefer channels.deinit(gpa);

            const len = try r.takeInt(sizes.items, .little);
            for (0..len) |_| {
                const c: Channel = try deserializeFn(Channel, gpa, r);
                try channels.set(gpa, c);
            }
            return channels;
        }
    };

    pub fn deinit(c: *const @This(), gpa: std.mem.Allocator) void {
        var it = c.items.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(gpa);
        @constCast(&c.items).deinit(gpa);
        @constCast(&c.indexes.name).deinit(gpa);
    }

    pub fn create(
        u: *Channels,
        gpa: std.mem.Allocator,
        channel_name: []const u8,
    ) error{ OutOfMemory, NameTaken }!*Channel {
        if (true) @panic("todo");
        if (context != .server) @compileError("server only");

        const host: *Host = @fieldParentPtr("channels", u);
        _ = host;
        if (u.indexes.name.get(channel_name) != null) {
            return error.NameTaken;
        }
        const chat_counter = 10;
        const gop = try u.items.getOrPut(gpa, chat_counter);
        if (gop.found_existing) unreachable;

        gop.value_ptr.* = .{
            .id = chat_counter,
            .name = channel_name,
            .kind = .{ .chat = .{} },
            .privacy = .private,
        };

        try u.indexes.name.put(gpa, channel_name, chat_counter);
        return gop.value_ptr;
    }

    pub fn set(u: *@This(), gpa: std.mem.Allocator, channel: Channel) !void {
        const gop = try u.items.getOrPut(gpa, channel.id);
        if (gop.found_existing) {
            const new_name = std.mem.eql(u8, channel.name, gop.value_ptr.name);
            if (new_name) {
                assert(u.indexes.name.remove(gop.value_ptr.name));
                try u.indexes.name.put(gpa, channel.name, channel.id);
            }
            gop.value_ptr.deinit(gpa);
        } else {
            try u.indexes.name.put(gpa, channel.name, channel.id);
        }

        gop.value_ptr.* = channel;
    }

    pub fn get(u: @This(), id: Channel.Id) ?*Channel {
        return u.items.getPtr(id);
    }

    pub fn getId(u: @This(), name_: []const u8) ?Channel.Id {
        return u.indexes.name.get(name_);
    }

    pub fn name(u: @This(), name_: []const u8) ?*Channel {
        const id = u.getId(name_) orelse return null;
        return u.get(id);
    }
};

pub const Callers = struct {
    items: std.AutoArrayHashMapUnmanaged(Caller.Id, Caller) = .{},
    indexes: struct {
        rooms: std.AutoHashMapUnmanaged(
            Channel.Id,
            std.AutoArrayHashMapUnmanaged(Caller.Id, void),
        ) = .{},
    } = .{},

    pub fn deinit(callers: *Callers, gpa: std.mem.Allocator) void {
        callers.items.deinit(gpa);
        for (callers.indexes.rooms.values()) |room| {
            room.deinit(gpa);
        }
        callers.indexes.rooms.deinit(gpa);
    }

    pub fn set(
        callers: *Callers,
        gpa: std.mem.Allocator,
        caller: Caller,
    ) !void {
        const gop = try callers.items.getOrPut(gpa, caller.id);
        const old_caller = gop.value_ptr;
        if (gop.found_existing) {
            if (caller.voice != old_caller.voice) {
                const old_room = callers.indexes.rooms.getPtr(old_caller.voice).?;
                if (old_room.count() == 1) {
                    std.debug.assert(old_room.keys()[0] == caller.id);
                    _ = callers.indexes.rooms.remove(old_caller.voice);
                } else {
                    _ = old_room.swapRemove(caller.id);
                }
            }
        } else {
            const room_gop = try callers.indexes.rooms.getOrPut(gpa, caller.voice);
            if (!room_gop.found_existing) {
                room_gop.value_ptr.* = .{};
            }

            try room_gop.value_ptr.put(gpa, caller.id, {});
        }

        gop.value_ptr.* = caller;
    }

    pub fn remove(callers: *@This(), cid: Caller.Id) !void {
        const old = callers.items.fetchSwapRemove(cid) orelse {
            std.log.debug("tried to remove caller {}, but no entry was found, ignoring", .{cid});
            return;
        };

        const room = callers.indexes.rooms.getPtr(old.value.voice) orelse return;
        if (room.count() == 1) {
            std.debug.assert(room.keys()[0] == cid);
            _ = callers.indexes.rooms.remove(old.value.voice);
        } else {
            _ = room.swapRemove(cid);
        }
    }

    pub fn get(callers: *@This(), cid: Caller.Id) ?*Caller {
        return callers.items.getPtr(cid);
    }

    pub fn getVoiceRoom(callers: @This(), rid: Channel.Id) ?[]const Caller.Id {
        const room = callers.indexes.rooms.get(rid) orelse return null;
        return room.keys();
    }
};
