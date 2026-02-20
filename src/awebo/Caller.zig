const Caller = @This();

const context = @import("options").context;
const TcpMessage = @import("protocol.zig").TcpMessage;
const User = @import("User.zig");
const Channel = @import("Channel.zig");

pub const Id = u16;

id: Id,
user: User.Id,
voice: Channel.Id,
screensharing: bool = false,
status: Status = .none,

pub const Status = enum(u8) {
    none,
    muted,
    server_muted,
    deafened,
    server_deafened,
};

pub const protocol = struct {};
