const std = @import("std");
const Io = std.Io;
const Channel = @import("../Channel.zig");
const User = @import("../User.zig");
const Voice = @This();

pub const protocol = struct {};

pub fn deinit(v: Voice, gpa: std.mem.Allocator) void {
    _ = v;
    _ = gpa;
}

pub fn format(v: Voice, w: *Io.Writer) !void {
    try w.print("Voice(id: {} name: '{s}')", .{ v.id, v.name });
}
