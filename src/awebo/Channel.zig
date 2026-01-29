const Channel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Database = @import("Database.zig");

pub const Chat = @import("Channel/Chat.zig");
pub const Voice = @import("Channel/Voice.zig");

id: Id,
name: []const u8,
privacy: Privacy,
kind: Kind,

pub const Id = u64;

/// Number of messages clients will keep in cache per channel
pub const window_size: u32 = std.math.maxInt(WindowSize) + 1;
pub const WindowSize = u6;

pub const Kind = union(Enum) {
    chat: Chat,
    voice: Voice,

    pub const Enum = enum(u8) { chat, voice };
    pub const protocol = struct {};

    pub fn sync(
        kind: *Kind,
        gpa: Allocator,
        db: Database,
        qs: *Database.CommonQueries,
        id: Channel.Id,
        new: *const Kind,
    ) void {
        switch (kind.*) {
            inline else => |*k| k.sync(gpa, db, qs, id, new),
        }
    }
};

pub const Privacy = enum(u8) {
    // Only the owner, admins and users with the right permession can see this channel / section.
    secret,
    // All server users can see this channel / section.
    private,
    // The channel / section is publicly visible on the web.
    public,
};

pub fn shallowDeinit(c: *Channel, gpa: Allocator) void {
    gpa.free(c.name);
}

pub fn deinit(c: *Channel, gpa: Allocator) void {
    c.shallowDeinit(gpa);
    switch (c.kind) {
        inline else => |*kind| kind.deinit(gpa),
    }
}

/// See awebo.Host.sync for code that updates other channel metadata.
pub fn sync(
    c: *Channel,
    gpa: Allocator,
    db: Database,
    qs: *Database.CommonQueries,
    new: *const Channel,
) void {
    c.shallowDeinit(gpa);

    c.name = new.name;
    c.privacy = new.privacy;

    c.kind.sync(gpa, db, qs, c.id, &new.kind);
}

pub fn format(c: Channel, w: *Io.Writer) !void {
    try w.print("Channel(id: {} name: '{s}' kind: {t})", .{
        c.id,
        c.name,
        c.kind,
    });
}

pub const protocol = struct {
    pub const sizes = struct {
        pub const name = u16;
    };
};
