const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Core = @import("../../Core.zig");
const persistence = @import("../../Core/persistence.zig");

pub fn run(io: Io, gpa: Allocator, environ: *std.process.Environ.Map, it: *std.process.Args.Iterator) void {
    _ = it;

    var core: Core = .init(gpa, io, environ, noopRefresh, &.{});

    persistence.load(&core) catch |e| {
        std.log.err("failed to load configuration: {t} \n", .{e});
        return;
    };
}

pub fn noopRefresh(_: *Core, _: std.builtin.SourceLocation, _: ?u64) void {}
