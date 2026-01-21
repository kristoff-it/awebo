const context = @import("options").context;
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const options = @import("options");
const Database = @import("../Database.zig");
const Channel = @import("../Channel.zig");
const Message = @import("../Message.zig");
const tcpSize = @import("../protocol.zig").tcpSize;
const Chat = @This();

const log = std.log.scoped(.chat);

messages: MessageWindow = .{},

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

    pub fn add(mw: *MessageWindow, gpa: std.mem.Allocator, msg: Message) !void {
        const gop = try mw.indexes.id.getOrPut(gpa, msg.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = mw.pushNew(gpa, msg);
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

    fn pushNew(mw: *MessageWindow, gpa: Allocator, msg: Message) usize {
        const tail_w: u32 = mw.tail;
        const idx: Channel.WindowSize = @intCast(@mod(tail_w + mw.len, Channel.window_size));

        if (idx == mw.tail and mw.len == Channel.window_size) {
            mw.buffer[idx].deinit(gpa);
            mw.tail +%= 1;
        } else {
            mw.len += 1;
        }
        mw.buffer[idx] = msg;
        return idx;
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
};

pub fn deinit(c: *Chat, gpa: std.mem.Allocator) void {
    c.messages.deinit(gpa);
}

// -- Server only functions

pub const addMessage = switch (context) {
    .client => @compileError("server only"),
    .server => struct {
        fn impl(chat: *Chat, gpa: Allocator, chat_id: Channel.Id, db: Database, msg: Message) !void {
            const query =
                \\INSERT INTO messages (id, origin, channel, author, body, reactions) VALUES
                \\  (?, ?, ?, ?, ?, ?)
                \\;
            ;

            db.conn.exec(query, .{ msg.id, msg.origin, chat_id, msg.author, msg.text, "" }) catch {
                db.fatal(@src());
            };

            try chat.messages.add(gpa, msg);
        }
    }.impl,
};
