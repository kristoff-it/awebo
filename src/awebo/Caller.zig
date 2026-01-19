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
client: switch (context) {
    .client => ClientOnly,
    .server => struct {
        pub const protocol = struct {
            pub const skip = true;
        };
    },
} = .{},

pub const Status = enum(u8) {
    none,
    muted,
    server_muted,
    deafened,
    server_deafened,
};

pub const ClientOnly = struct {
    /// the last time this caller spoke,
    /// used to light up their name
    speaking_last_ms: u64 = 0,
    pub const protocol = struct {
        pub const skip = true;
    };
};

pub const protocol = struct {};

pub fn serialize(c: Caller, msg: TcpMessage) void {
    msg.writeInt(c.id);
    msg.writeInt(c.user);
    msg.writeInt(c.voice);
    msg.writeBool(c.screensharing);
    msg.writeEnum(c.status);
}

pub fn parse(r: anytype) !Caller {
    const id = try TcpMessage.readInt(Id, r);
    const user = try TcpMessage.readInt(User.Id, r);
    const voice = try TcpMessage.readInt(Channel.Id, r);
    const screensharing = try TcpMessage.readBool(r);
    const status = try TcpMessage.readEnum(Status, r);

    return .{
        .id = id,
        .user = user,
        .voice = voice,
        .screensharing = screensharing,
        .status = status,
    };
}
