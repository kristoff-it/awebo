/// A reference-counted interned string. Allows each string to be uniquely
/// identified by its slice address and minimizes heap allocation.
const StringPool = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

content_map: std.StringHashMapUnmanaged([:0]const u8) = .{},
refcount_map: std.AutoHashMapUnmanaged([*:0]const u8, usize) = .{},

pub const String = struct {
    slice: [:0]const u8,

    pub fn format(string: String, writer: *std.Io.Writer) !void {
        try writer.print("{s}", .{string.slice});
    }
};

pub fn getOrCreate(sp: *StringPool, gpa: Allocator, content: []const u8) error{OutOfMemory}!String {
    const result = try sp.content_map.getOrPut(gpa, content);
    if (!result.found_existing) {
        errdefer assert(sp.content_map.remove(content));
        const slice = try gpa.dupeZ(u8, content);
        errdefer gpa.free(slice);
        try sp.refcount_map.put(gpa, slice.ptr, 1);
        result.key_ptr.* = slice;
        result.value_ptr.* = slice;
    } else {
        const count_ref = sp.refcount_map.getPtr(result.value_ptr.ptr) orelse @panic("codebug");
        assert(count_ref.* >= 1);
        count_ref.* += 1;
    }
    return .{ .slice = result.value_ptr.* };
}

pub fn getOrCreateWtf16Le(
    sp: *StringPool,
    gpa: Allocator,
    comptime max_bytes: usize,
    wtf16le: []const u16,
) error{ TooBig, OutOfMemory }!String {
    var buf: [max_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    var al = std.array_list.Managed(u8).init(fba.allocator());
    if (std.unicode.wtf16LeToWtf8ArrayList(&al, wtf16le)) {
        return getOrCreate(sp, gpa, al.items);
    } else |err| switch (err) {
        error.OutOfMemory => return error.TooBig,
    }
}

pub fn addReference(sp: *StringPool, string: String) void {
    const count_ref = sp.refcount_map.getPtr(string.slice.ptr) orelse @panic("codebug");
    assert(count_ref.* >= 1);
    count_ref.* += 1;
}

pub fn removeReference(sp: *StringPool, string: String, gpa: Allocator) void {
    const count_ref = sp.refcount_map.getPtr(string.slice.ptr) orelse @panic("codebug");
    assert(count_ref.* >= 1);
    count_ref.* -= 1;
    if (count_ref.* == 0) {
        assert(sp.refcount_map.remove(string.slice.ptr));
        assert(sp.content_map.remove(string.slice));
        gpa.free(string.slice);
    }
}
