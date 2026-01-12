/// A reference-counted intern pool string. Allows each string to be
/// uniquely identified by its slice address and minimizes heap allocation.
const PoolString = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const core = @import("core.zig");
const global = core.global;

slice: [:0]const u8,

pub fn getOrCreate(gpa: Allocator, content: []const u8) error{OutOfMemory}!PoolString {
    global.enforceMainThread();
    const result = try global.pool_content_map.getOrPut(gpa, content);
    if (!result.found_existing) {
        errdefer std.debug.assert(global.pool_content_map.remove(content));
        const slice = try gpa.dupeZ(u8, content);
        errdefer gpa.free(slice);
        try global.pool_refcount_map.put(gpa, slice.ptr, 1);
        result.key_ptr.* = slice;
        result.value_ptr.* = slice;
    } else {
        const count_ref = global.pool_refcount_map.getPtr(result.value_ptr.ptr) orelse @panic("codebug");
        std.debug.assert(count_ref.* >= 1);
        count_ref.* += 1;
    }
    return .{ .slice = result.value_ptr.* };
}

pub fn getOrCreateWtf16Le(
    gpa: Allocator,
    comptime max_bytes: usize,
    wtf16le: []const u16,
) error{ TooBig, OutOfMemory }!PoolString {
    var buf: [max_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var al = std.array_list.Managed(u8).init(fba.allocator());
    if (std.unicode.wtf16LeToWtf8ArrayList(&al, wtf16le)) {
        return getOrCreate(gpa, al.items);
    } else |err| switch (err) {
        error.OutOfMemory => return error.TooBig,
    }
}

pub fn addReference(self: PoolString) void {
    global.enforceMainThread();
    const count_ref = global.pool_refcount_map.getPtr(self.slice.ptr) orelse @panic("codebug");
    std.debug.assert(count_ref.* >= 1);
    count_ref.* += 1;
}

pub fn removeReference(self: PoolString, gpa: Allocator) void {
    global.enforceMainThread();
    const count_ref = global.pool_refcount_map.getPtr(self.slice.ptr) orelse @panic("codebug");
    std.debug.assert(count_ref.* >= 1);
    count_ref.* -= 1;
    if (count_ref.* == 0) {
        std.debug.assert(global.pool_refcount_map.remove(self.slice.ptr));
        std.debug.assert(global.pool_content_map.remove(self.slice));
        gpa.free(self.slice);
    }
}

pub fn format(self: PoolString, writer: *Io.Writer) !void {
    try writer.print("{s}", .{self.slice});
}
