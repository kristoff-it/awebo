const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Database = @import("../Database.zig");
const Channel = @import("../Channel.zig");
const User = @import("../User.zig");
const Voice = @This();

pub const protocol = struct {};

pub fn deinit(v: Voice, gpa: std.mem.Allocator) void {
    _ = v;
    _ = gpa;
}

pub fn sync(
    v: *Voice,
    gpa: Allocator,
    db: Database,
    id: Channel.Id,
    new: *const Channel.Kind,
) void {
    _ = v;
    _ = gpa;
    _ = db;
    _ = id;
    assert(new.* == Channel.Kind.Enum.voice);
}

pub fn format(v: Voice, w: *Io.Writer) !void {
    try w.print("Voice(id: {} name: '{s}')", .{ v.id, v.name });
}
