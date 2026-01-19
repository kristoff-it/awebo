const Channel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Chat = @import("Channel/Chat.zig");
pub const Voice = @import("Channel/Voice.zig");

id: Id,
name: []const u8,
privacy: Privacy,
kind: Kind,

pub const Id = u32;

/// Number of messages clients will keep in cache per channel
pub const window_size: u32 = std.math.maxInt(WindowSize) + 1;
pub const WindowSize = u6;

pub const Kind = union(Enum) {
    chat: Chat,
    voice: Voice,

    pub const Enum = enum(u8) { chat, voice };
    pub const protocol = struct {};
};

pub const Privacy = enum(u8) {
    // Only the owner, admins and users with the right permession can see this channel / section.
    secret,
    // All server users can see this channel / section.
    private,
    // The channel / section is publicly visible on the web.
    public,
};

pub fn deinit(c: *Channel, gpa: Allocator) void {
    gpa.free(c.name);
    switch (c.kind) {
        inline else => |*kind| kind.deinit(gpa),
    }
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
