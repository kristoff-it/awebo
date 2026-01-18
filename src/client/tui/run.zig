const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const tui_log = std.log.scoped(.tui);

pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    tui_log.info("starting awebo client", .{});
    defer tui_log.info("goodbye", .{});
    _ = io;
    _ = gpa;
    _ = it;
}
