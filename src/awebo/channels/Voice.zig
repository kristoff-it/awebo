const std = @import("std");
const Io = std.Io;
const channel = @import("../channels.zig");
const User = @import("../User.zig");
const Voice = @This();

id: Id,
name: []const u8,

pub const Id = channel.Id;

pub const protocol = struct {
    pub const sizes = struct {
        pub const name = u16;
    };
};

pub fn deinit(v: Voice, gpa: std.mem.Allocator) void {
    gpa.free(v.name);
}

pub fn format(v: Voice, w: *Io.Writer) !void {
    try w.print("Voice(id: {} name: '{s}')", .{ v.id, v.name });
}
