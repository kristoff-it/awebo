const context = @import("options").context;
const std = @import("std");
const Io = std.Io;
const proto = @import("../protocol.zig");
const User = @import("../User.zig");
const Caller = @import("../Caller.zig");
const Host = @import("../Host.zig");
const Channel = @import("../Channel.zig");
const Message = @import("../Message.zig");

const log = std.log.scoped(.protocol);

pub const AuthenticateReply = struct {
    protocol_version: u32,
    result: Result,

    pub const marker = 'a';
    pub const serialize = proto.MakeSerializeFn(AuthenticateReply);
    pub const serializeAlloc = proto.MakeSerializeAllocFn(AuthenticateReply);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(AuthenticateReply);
    pub const protocol = struct {
        pub const sizes = struct {};
    };

    pub const Result = union(Tag) {
        authorized,
        unauthorized: struct {
            code: ErrorCode,
            msg: []const u8 = "",

            pub const protocol = struct {
                pub const sizes = struct {
                    pub const msg = u16;
                };
            };
        },

        pub const Tag = enum(u8) { authorized, unauthorized };
        pub const protocol = struct {};
    };

    pub const ErrorCode = enum(u32) {
        unsupported_method,
        invalid_credentials,
        banned_user,
    };
};

pub const InviteInfoReply = struct {
    server_name: []const u8,

    pub const marker = 'i';
    pub const serialize = proto.MakeSerializeFn(InviteInfoReply);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(InviteInfoReply);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const server_name = u16;
        };
    };

    pub fn deinit(iir: InviteInfoReply, gpa: std.mem.Allocator) void {
        gpa.free(iir.server_name);
    }
};

/// Sent by the server to a client, usually by using a convenience
/// `reply` method from the original request. Complex requests might
/// have a dedicated reply type.
pub const ClientRequestReply = struct {
    origin: u64,
    reply_marker: u8,
    result: Result,

    pub const marker = 'R';
    pub const protocol = struct {
        pub const sizes = struct {};
    };

    pub const Result = union(Tag) {
        ok,
        rate_limit,
        no_permission,
        err: struct {
            code: u32, // request-specific error code
            msg: []const u8 = "",

            pub const protocol = struct {
                pub const sizes = struct {
                    pub const msg = u16;
                };
            };
        },
        pub const Tag = enum(u8) { ok, rate_limit, no_permission, err };
        pub const protocol = struct {
            pub const sizes = struct {
                pub const ok = u32;
            };
        };
    };

    pub const serializeAlloc = proto.MakeSerializeAllocFn(ClientRequestReply);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(ClientRequestReply);
};

pub const HostSync = struct {
    user_id: User.Id,
    host: Host,

    pub const marker = 'S';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(HostSync);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(HostSync);
    pub const protocol = struct {
        pub const sizes = struct {};
    };

    pub fn deinit(hs: *const HostSync, gpa: std.mem.Allocator) void {
        hs.host.deinit(gpa);
    }
};

pub const CallersUpdate = struct {
    caller: Caller,
    action: Action,

    const Action = enum(u8) { join, update, leave };

    pub const marker = 'C';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(CallersUpdate);
    pub const deserialize = proto.MakeDeserializeFn(CallersUpdate);
    pub const protocol = struct {};
};

pub const MediaConnectionDetails = struct {
    voice: Channel.Id,
    tcp_client: u64,
    nonce: u64,

    pub const marker = 'm';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(MediaConnectionDetails);
    pub const deserialize = proto.MakeDeserializeFn(MediaConnectionDetails);
    pub const protocol = struct {};
};

pub const ChatMessageNew = struct {
    origin: u64,
    channel: Channel.Id,
    msg: Message,

    pub const marker = 'M';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(ChatMessageNew);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(ChatMessageNew);
    pub const protocol = struct {};
};

pub const ChannelsUpdate = struct {
    kind: enum(u8) { full, delta },
    channels: []const Channel,

    pub const marker = 'H';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(ChannelsUpdate);
    pub const deserialize = proto.MakeDeserializeFn(ChannelsUpdate);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const channels = u32;
        };
    };
};

comptime {
    var names: []const []const u8 = &.{};
    var values: []const u8 = &.{};
    for (@typeInfo(@This()).@"struct".decls) |d| {
        names = names ++ &[1][]const u8{&.{@field(@This(), d.name).marker}};
        values = values ++ &[1]u8{@field(@This(), d.name).marker};
    }
    _ = @Enum(u8, .exhaustive, names, @ptrCast(values.ptr)); // on error we have a tag collision
}
