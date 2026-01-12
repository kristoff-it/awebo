const Home = @This();

readme: []const u8,

pub const protocol = struct {
    pub const sizes = struct {
        pub const readme = u16;
    };
};

const std = @import("std");
pub fn deinit(h: Home, gpa: std.mem.Allocator) void {
    gpa.free(h.readme);
}
