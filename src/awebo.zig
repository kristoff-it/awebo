pub const opus = @import("awebo/opus.zig");
pub const permissions = @import("awebo/permissions.zig");
pub const protocol = @import("awebo/protocol.zig");
pub const Clock = @import("awebo/Clock.zig");
pub const Channel = @import("awebo/Channel.zig");
pub const Host = @import("awebo/Host.zig");
pub const Message = @import("awebo/Message.zig");
pub const User = @import("awebo/User.zig");
pub const Caller = @import("awebo/Caller.zig");

pub const IdGenerator = struct {
    last: u64,

    pub fn init(last: u64) IdGenerator {
        return .{ .last = last };
    }

    pub fn new(g: *IdGenerator) u64 {
        g.last += 1;
        return g.last;
    }
};
