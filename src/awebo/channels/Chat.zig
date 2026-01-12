const context = @import("options").context;
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const options = @import("options");
const channel = @import("../channels.zig");
const Message = @import("../Message.zig");
const tcpSize = @import("../protocol.zig").tcpSize;
const Chat = @This();

pub const Id = channel.Id;

id: Id,
name: []const u8,

client: switch (context) {
    .client => ClientOnly,
    .server => struct {
        pub const protocol = struct {
            pub const skip = true;
        };
    },
} = .{},

pub const ClientOnly = struct {
    messages: Messages = .{},
    const Messages = struct {
        items: std.AutoArrayHashMapUnmanaged(Message.Id, Message) = .{},

        pub const protocol = struct {
            pub const sizes = struct {
                pub const items = u64;
            };

            pub inline fn serialize(messages: Messages, comptime serializeFn: anytype, w: *Io.Writer) !void {
                try w.writeInt(sizes.items, @intCast(messages.items.count()), .little);
                for (messages.items.values()) |message| try serializeFn(message, w);
            }

            pub fn deserializeAlloc(comptime deserializeFn: anytype, gpa: Allocator, r: *Io.Reader) !Messages {
                var messages: Messages = .{};
                errdefer messages.deinit(gpa);

                const len = try r.takeInt(sizes.items, .little);
                for (0..len) |_| {
                    const m: Message = try deserializeFn(Message, gpa, r);
                    try messages.add(gpa, m);
                }
                return messages;
            }
        };

        pub fn deinit(m: *Messages, gpa: std.mem.Allocator) void {
            for (m.items.values()) |msg| msg.deinit(gpa);
            m.items.deinit(gpa);
        }

        pub fn add(u: *Messages, gpa: std.mem.Allocator, msg: Message) !void {
            const gop = try u.items.getOrPut(gpa, msg.id);
            if (!gop.found_existing) {
                gop.value_ptr.* = msg;
            }
        }

        pub fn get(u: Messages, id: Message.Id) ?*Message {
            return u.items.getPtr(id);
        }
    };
    pub const protocol = struct {
        pub const skip = true;
    };
};

pub const protocol = struct {
    pub const sizes = struct {
        pub const name = u16;
    };
};

pub fn deinit(c: *Chat, gpa: std.mem.Allocator) void {
    gpa.free(c.name);
    // c.messages.deinit(gpa);
}

pub fn format(c: Chat, w: *Io.Writer) !void {
    try w.print("Chat(id: {} name: '{s}')", .{ c.id, c.name });
}

// -- Server only functions

pub const addMessage = switch (context) {
    .client => @compileError("server only"),
    .server => struct {
        const Database = @import("../../server/Database.zig");
        fn impl(chat: Chat, db: Database, msg: Message) !void {
            comptime assert(context == .server);

            const query =
                \\INSERT INTO messages (id, origin, channel, author, body, reactions) VALUES
                \\  (?, ?, ?, ?, ?, ?)
                \\;
            ;

            db.conn.exec(query, .{ msg.id, msg.origin, chat.id, msg.author, msg.text, "" }) catch {
                db.fatal(@src());
            };
        }
    }.impl,
};

pub const latestMessages = switch (context) {
    .client => @compileError("server only"),
    .server => struct {
        const Database = @import("../../server/Database.zig");
        fn impl(chat: Chat, db: Database) ![]Message {
            comptime assert(context == .server);
            _ = db;
            _ = chat;
        }
    }.impl,
};
