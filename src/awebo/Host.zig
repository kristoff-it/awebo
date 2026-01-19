const Host = @This();

const context = @import("options").context;
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const proto = @import("protocol.zig");
const Channel = @import("Channel.zig");
const User = @import("User.zig");
const Caller = @import("Caller.zig");

name: []const u8 = "",
logo: []const u8 = "", // TODO: draw default logo
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

pub const ClientOnly = struct {
    const network = @import("../client/Core/network.zig");
    const ui = @import("../client/Core/ui.zig");

    pub const Id = u32;

    identity: []const u8 = undefined,
    host_id: Id = undefined,
    user_id: User.Id = undefined,
    username: []const u8 = undefined,
    password: []const u8 = undefined,

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

pub fn deinit(hs: *Host, gpa: std.mem.Allocator) void {
    gpa.free(hs.name);
    gpa.free(hs.logo);
    hs.users.deinit(gpa);
    hs.channels.deinit(gpa);
}

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

    pub fn deinit(u: *Users, gpa: std.mem.Allocator) void {
        for (u.items.values()) |user| user.deinit(gpa);
        u.items.deinit(gpa);
        u.indexes.handle.deinit(gpa);
    }

    pub fn set(u: *Users, gpa: std.mem.Allocator, user: User) !void {
        const gop = try u.items.getOrPut(gpa, user.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = user;
        }

        try u.indexes.handle.put(gpa, user.handle, user.id);
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

    pub fn deinit(c: *@This(), gpa: std.mem.Allocator) void {
        var it = c.items.iterator();
        while (it.next()) |kv| kv.value_ptr.deinit(gpa);
        c.items.deinit(gpa);
        c.indexes.name.deinit(gpa);
    }

    pub const create: fn (
        u: *Channels,
        gpa: std.mem.Allocator,
        channel_name: []const u8,
    ) error{ OutOfMemory, NameTaken }!*Channel = switch (context) {
        .client => @compileError("server only"),
        .server => struct {
            var chat_counter: Channel.Id = 5;
            fn create(u: *Channels, gpa: std.mem.Allocator, channel_name: []const u8) !*Channel {
                if (u.indexes.name.get(channel_name) != null) {
                    return error.NameTaken;
                }
                chat_counter += 1;
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
        }.create,
    };

    pub fn set(u: *@This(), gpa: std.mem.Allocator, channel: Channel) !void {
        const gop = try u.items.getOrPut(gpa, channel.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = channel;
        }

        try u.indexes.name.put(gpa, channel.name, channel.id);
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
