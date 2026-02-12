const context = @import("options").context;
const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const options = @import("options");
const Database = @import("../Database.zig");
const Channel = @import("../Channel.zig");
const Message = @import("../Message.zig");
const User = @import("../User.zig");
const tcpSize = @import("../protocol.zig").tcpSize;
const Chat = @This();

const log = std.log.scoped(.chat);

messages: MessageWindow = .{},

client: switch (context) {
    .client => ClientOnly,
    .server => void,
} = switch (context) {
    .client => .{},
    .server => {},
},

pub const protocol = struct {};

const MessageWindow = struct {
    buffer: [Channel.window_size]Message = undefined,
    tail: Channel.WindowSize = 0,
    len: @TypeOf(Channel.window_size) = 0,

    indexes: struct {
        id: std.AutoHashMapUnmanaged(Message.Id, usize) = .empty,
    } = .{},

    pub const protocol = struct {
        pub const sizes = struct {
            pub const buffer = @Int(.unsigned, @sizeOf(Channel.WindowSize) * 8);
        };

        pub inline fn serialize(mw: MessageWindow, comptime serializeFn: anytype, w: *Io.Writer) !void {
            try w.writeInt(sizes.buffer, @intCast(mw.len), .little);
            for (mw.slices()) |s| for (s) |message| {
                log.debug("serializing {f}", .{message});
                try serializeFn(message, w);
            };
        }

        pub fn deserializeAlloc(comptime deserializeFn: anytype, gpa: Allocator, r: *Io.Reader) !MessageWindow {
            var mw: MessageWindow = .{};
            errdefer mw.deinit(gpa);

            const len = try r.takeInt(sizes.buffer, .little);
            for (0..len) |_| {
                const m: Message = try deserializeFn(Message, gpa, r);
                log.debug("deserialized {f}", .{m});
                try mw.frontfill(gpa, m);
            }
            return mw;
        }
    };

    pub fn deinit(mw: *MessageWindow, gpa: std.mem.Allocator) void {
        for (mw.slices()) |s| for (s) |msg| msg.deinit(gpa);
        mw.indexes.id.deinit(gpa);
    }

    pub fn pushOld(mw: *MessageWindow, gpa: Allocator, msg: Message) !void {
        if (mw.latest()) |l| assert(l.id > msg.id);
        const gop = try mw.indexes.id.getOrPut(gpa, msg.id);
        if (!gop.found_existing) {
            mw.tail -%= 1;
            if (mw.len == Channel.window_size) {
                assert(mw.indexes.id.remove(mw.buffer[mw.tail].id));
                mw.buffer[mw.tail].deinit(gpa);
            }
            mw.buffer[mw.tail] = msg;
            gop.value_ptr.* = mw.tail;
        }
    }

    pub fn pushNew(mw: *MessageWindow, gpa: std.mem.Allocator, msg: Message) !void {
        // if (mw.latest()) |l| assert(l.id < msg.id);
        const gop = try mw.indexes.id.getOrPut(gpa, msg.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = mw.doPushNew(gpa, msg);
        }
    }

    /// Asserts that mw.len < Channel.window_size.
    /// Used by server when initially loading messages from the database
    /// newest-to-oldest.
    pub fn backfill(mw: *MessageWindow, gpa: Allocator, msg: Message) !void {
        assert(mw.len < Channel.window_size);

        const idx = mw.tail -% 1;
        mw.buffer[idx] = msg;
        mw.len += 1;
        mw.tail = idx;

        const gop = try mw.indexes.id.getOrPut(gpa, msg.id);
        assert(!gop.found_existing);
        gop.value_ptr.* = idx;
    }

    /// Asserts that mw.tail == 0 and mw.len < Channel.window_size.
    /// Used by `protocol.deserialize` when we receive messages oldest-to-newest
    /// from the server.
    pub fn frontfill(mw: *MessageWindow, gpa: Allocator, msg: Message) !void {
        assert(mw.tail == 0);
        assert(mw.len < Channel.window_size);
        const idx = mw.len;
        mw.buffer[idx] = msg;
        mw.len += 1;

        const gop = try mw.indexes.id.getOrPut(gpa, msg.id);
        assert(!gop.found_existing);
        gop.value_ptr.* = idx;
    }

    pub fn get(mw: *const MessageWindow, id: Message.Id) ?*Message {
        return &mw.items[mw.indexes.id.get(id) orelse return null];
    }

    fn doPushNew(mw: *MessageWindow, gpa: Allocator, msg: Message) usize {
        const tail_w: u32 = mw.tail;
        const head: Channel.WindowSize = @intCast(@mod(tail_w + mw.len, Channel.window_size));
        if (head == mw.tail and mw.len == Channel.window_size) {
            assert(mw.indexes.id.remove(mw.buffer[head].id));
            mw.buffer[head].deinit(gpa);
            mw.tail +%= 1;
        } else {
            mw.len += 1;
        }
        mw.buffer[head] = msg;
        return head;
    }

    pub fn latest(mw: *const MessageWindow) ?*const Message {
        if (mw.len == 0) return null;
        const head: Channel.WindowSize = @intCast(mw.len - 1);
        const idx: Channel.WindowSize = mw.tail +% head;
        return &mw.buffer[idx];
    }

    pub fn oldest(mw: *MessageWindow) ?*Message {
        if (mw.len == 0) return null;
        return &mw.buffer[mw.tail];
    }

    /// First slice starts at mw.tail, second slice ends at newest message
    pub fn slices(mw: *const MessageWindow) [2][]const Message {
        const len_wraps = Channel.window_size - mw.tail < mw.len;

        if (len_wraps) {
            const tail_w: u32 = mw.tail;
            const end: Channel.WindowSize = @intCast(@mod(tail_w + mw.len, Channel.window_size));
            return .{ mw.buffer[mw.tail..], mw.buffer[0..end] };
        } else {
            return .{ mw.buffer[mw.tail..][0..mw.len], &.{} };
        }
    }

    pub fn at(mw: *MessageWindow, slot: usize) *Message {
        assert(slot < mw.len);
        const slot_t: Channel.WindowSize = @intCast(slot);
        const idx: Channel.WindowSize = mw.tail +% slot_t;
        return &mw.buffer[idx];
    }

    // pub fn load(mw: *MessageWindow, chat_id: Channel.Id, db: Database) !void {}
};

pub fn deinit(c: *Chat, gpa: std.mem.Allocator) void {
    c.messages.deinit(gpa);
    switch (context) {
        .client => c.client.deinit(gpa),
        .server => {},
    }
}

pub const ClientOnly = struct {
    scroll: enum {
        sticky_bottom,
        position,
    } = .sticky_bottom,

    /// Core has pushed new messages in chat.messages,
    /// UI should set this to false when those messages
    /// have been rendered.
    new_messages: bool = false,
    waiting_new_messages: bool = false,
    fetched_all_new_messages: bool = false,
    loaded_all_new_messages: bool = false,

    waiting_old_messages: bool = false,
    fetched_all_old_messages: bool = false,
    loaded_all_old_messages: bool = false,

    /// A FIFO hash set of users typing in this chat mapped to the time they started typing.
    typing: std.AutoArrayHashMapUnmanaged(User.Id, u64) = .empty,

    pub const protocol = struct {
        pub const skip = true;
    };

    pub fn deinit(self: *ClientOnly, gpa: std.mem.Allocator) void {
        self.typing.deinit(gpa);
        self.* = undefined;
    }
};

/// Synchronizes messages in bulk.
pub fn sync(
    chat: *Chat,
    gpa: Allocator,
    db: Database,
    qs: *Database.CommonQueries,
    new_channel: *const Channel,
) void {
    if (context != .client) @compileError("client only");

    const new_chat = &new_channel.kind.chat;
    const slices = new_chat.messages.slices();
    for (slices) |s| for (s) |msg| {
        log.debug("chat sync, saving to db msg {}", .{msg.id});
        chat.messages.pushNew(gpa, msg) catch @panic("oom");
        qs.upsert_message.run(@src(), db, .{
            .uid = msg.id,
            .origin = msg.origin,
            .created = msg.created,
            .update_uid = msg.update_uid,
            .channel = new_channel.id,
            .author = msg.author,
            .body = msg.text,
        });
    };

    // const msg_query =
    //     \\INSERT INTO messages(id, origin, updated, channel, author, body)
    //     \\VALUES (?1, ?2, ?3, ?4, ?5, ?6)
    //     \\ON CONFLICT(id) DO UPDATE
    //     \\SET (origin, updated, channel, author, body)
    //     \\ = (?2, ?3, ?4, ?5, ?6)
    // ;

    // for (messages) |slice| for (slice) |m| {
    //     db.conn.exec(msg_query, .{
    //         m.id,
    //         m.origin,
    //         0, //  m.updated,
    //         chat_id,
    //         m.author,
    //         m.text,
    //     }) catch db.fatal(@src());
    // };
}
