const context = @import("options").context;
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const options = @import("options");
const Channel = @import("../Channel.zig");
const Message = @import("../Message.zig");
const tcpSize = @import("../protocol.zig").tcpSize;
const Chat = @This();

messages: MessageWindow = .{},

pub const protocol = struct {};

const MessageWindow = struct {
    items: std.Deque(Message) = .empty,
    indexes: struct {
        id: std.AutoHashMapUnmanaged(Message.Id, usize) = .empty,
    } = .{},

    pub const protocol = struct {
        pub const sizes = struct {
            pub const items = u64;
        };

        pub inline fn serialize(mw: MessageWindow, comptime serializeFn: anytype, w: *Io.Writer) !void {
            try w.writeInt(sizes.items, @intCast(mw.items.len), .little);
            var it = mw.items.iterator();
            while (it.next()) |message| try serializeFn(message, w);
        }

        pub fn deserializeAlloc(comptime deserializeFn: anytype, gpa: Allocator, r: *Io.Reader) !MessageWindow {
            var mw: MessageWindow = .{};
            errdefer mw.deinit(gpa);

            const len = try r.takeInt(sizes.items, .little);
            for (0..len) |_| {
                const m: Message = try deserializeFn(Message, gpa, r);
                try mw.add(gpa, m, .front);
            }
            return mw;
        }
    };

    pub fn deinit(mw: *MessageWindow, gpa: std.mem.Allocator) void {
        var it = mw.items.iterator();
        while (it.next()) |msg| msg.deinit(gpa);
        mw.items.deinit(gpa);
        mw.indexes.id.deinit(gpa);
    }

    pub fn add(mw: *MessageWindow, gpa: std.mem.Allocator, msg: Message, end: enum { back, front }) !void {
        const gop = try mw.indexes.id.getOrPut(gpa, msg.id);
        if (!gop.found_existing) {
            switch (end) {
                .back => try mw.items.pushBack(gpa, msg),
                .front => try mw.items.pushFront(gpa, msg),
            }
            gop.value_ptr.* = mw.items.head;
        }
    }

    pub fn get(mw: MessageWindow, id: Message.Id) ?*Message {
        return &mw.items[mw.indexes.id.get(id) orelse return null];
    }
};

pub fn deinit(c: *Chat, gpa: std.mem.Allocator) void {
    c.messages.deinit(gpa);
}

// -- Server only functions

pub const addMessage = switch (context) {
    .client => @compileError("server only"),
    .server => struct {
        const Database = @import("../../server/Database.zig");
        fn impl(chat: *Chat, gpa: Allocator, chat_id: Channel.Id, db: Database, msg: Message) !void {
            const query =
                \\INSERT INTO messages (id, origin, channel, author, body, reactions) VALUES
                \\  (?, ?, ?, ?, ?, ?)
                \\;
            ;

            db.conn.exec(query, .{ msg.id, msg.origin, chat_id, msg.author, msg.text, "" }) catch {
                db.fatal(@src());
            };

            try chat.messages.add(gpa, msg, .front);
        }
    }.impl,
};
