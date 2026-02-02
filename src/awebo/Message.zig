const Io = @import("std").Io;
const TcpMessage = @import("protocol.zig").TcpMessage;
const awebo = @import("../awebo.zig");
const Message = @This();

pub const Id = u64;

id: Id,
origin: u64,
created: awebo.Date,
update_uid: ?u64,
author: awebo.User.Id,
text: []const u8,

pub const protocol = struct {
    pub const sizes = struct {
        pub const text = u24;
    };
};

const std = @import("std");
pub fn deinit(m: Message, gpa: std.mem.Allocator) void {
    gpa.free(m.text);
}

pub fn serialize(msg: Message, tcp: TcpMessage) void {
    tcp.writeInt(msg.id);
    tcp.writeInt(msg.author);
    tcp.writeSlice(.u24, msg.text);
}

pub fn parseAlloc(gpa: std.mem.Allocator, r: anytype) !Message {
    const id = try TcpMessage.readInt(Id, r);
    const author = try TcpMessage.readInt(awebo.User.Id, r);
    const text = try TcpMessage.readSlice(gpa, .u24, r);

    return .{
        .id = id,
        .author = author,
        .text = text,
    };
}

pub fn format(msg: *const Message, w: *Io.Writer) !void {
    try w.print("Message(id: {} origin: {} created: {f} author: {}  text: '{s}')", .{
        msg.id, msg.origin, msg.created, msg.author, msg.text,
    });
}
