const Caller = @This();

const context = @import("options").context;
const proto = @import("protocol.zig");
const TcpMessage = proto.TcpMessage;
const User = @import("User.zig");
const Channel = @import("Channel.zig");

pub const Id = proto.client.Id;

id: proto.client.Id,
voice: Channel.Id,
state: State,

pub const State = struct {
    muted: bool = false,
    muted_server: bool = false,
    deafened: bool = false,
    screenshare: bool = false,

    pub const protocol = struct {};
};

// pub const AudioState = enum(u8) {
//     none,
//     muted,
//     server_muted,
//     deafened,
//     server_deafened,
// };

pub const protocol = struct {};
