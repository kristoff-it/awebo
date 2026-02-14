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

/// Holds scroll state
client: switch (context) {
    .client => ClientOnly,
    .server => void,
} = switch (context) {
    .client => .{},
    .server => {},
},

/// Holds latest messages
server: switch (context) {
    .client => void,
    .server => ServerOnly,
} = switch (context) {
    .client => {},
    .server => .{},
},

pub const protocol = struct {};

pub fn deinit(c: *Chat, gpa: std.mem.Allocator) void {
    switch (context) {
        .client => c.client.deinit(gpa),
        .server => c.server.deinit(gpa),
    }
}

pub const ServerOnly = struct {
    messages: MessageWindow = .{},

    pub const protocol = struct {
        pub const skip = true;
    };

    pub fn deinit(s: *ServerOnly, gpa: std.mem.Allocator) void {
        s.messages.deinit(gpa);
    }
};

pub const ClientOnly = struct {
    /// Core has pushed new messages in chat.messages,
    /// UI should set this to false when those messages
    /// have been rendered.
    new_messages: bool = false,
    /// Newest message in the message buffer before we switched to another
    /// channel. Used to restore scroll state when switching back.
    /// Defaults to maxint to guarantee that the query loads newest messages
    /// when showing the channel for the first time.
    last_newest: Message.Id = std.math.maxInt(i64),

    state: enum {
        /// Not waiting for any message chunk to load
        ready,
        waiting_present,
        waiting_past,
    } = .ready,

    fetched_all_old_messages: bool = false,
    loaded_all_old_messages: bool = false,
    fetched_all_new_messages: bool = false,
    loaded_all_new_messages: bool = false,

    /// UI-managed resource that keeps track of any other scrolling state,
    /// for example the precise pixel offset that we're scrolled at.
    scroll_info: ?*anyopaque = null,

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
    _ = chat;
    _ = gpa;
    _ = db;
    _ = qs;
    _ = new_channel;
}

pub const MessageWindow = struct {
    buffer: [Channel.window_size]Message = undefined,
    tail: Channel.WindowSize = 0,
    len: @TypeOf(Channel.window_size) = 0,

    indexes: struct {
        id: std.AutoHashMapUnmanaged(Message.Id, usize) = .empty,
    } = .{},

    pub fn reset(mw: *MessageWindow, gpa: std.mem.Allocator) void {
        mw.deinit(gpa);
        mw.* = .{};
    }

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
            } else mw.len += 1;

            mw.buffer[mw.tail] = msg;
            gop.value_ptr.* = mw.tail;
        }
    }

    pub fn pushNew(mw: *MessageWindow, gpa: std.mem.Allocator, msg: Message) !void {
        if (mw.latest()) |l| assert(l.id < msg.id);
        const gop = try mw.indexes.id.getOrPut(gpa, msg.id);
        log.debug("buffer {} == {}", .{ msg.id, gop.found_existing });
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
        const new_head = if (mw.len == Channel.window_size) blk: {
            const new_head = mw.tail;
            assert(mw.indexes.id.remove(mw.buffer[new_head].id));
            mw.buffer[new_head].deinit(gpa);
            mw.tail +%= 1;
            break :blk new_head;
        } else blk: {
            const tail_w: u32 = mw.tail;
            const head: Channel.WindowSize = @intCast(@mod(tail_w + mw.len, Channel.window_size));
            mw.len += 1;
            break :blk head;
        };
        mw.buffer[new_head] = msg;
        return new_head;
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
