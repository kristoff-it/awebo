const std = @import("std");
const server = @import("server.zig");
const proto = @import("../protocol.zig");
const User = @import("../User.zig");
const Host = @import("../Host.zig");
const Message = @import("../Message.zig");
const Channel = @import("../Channel.zig");

pub const OriginId = u64;

/// This is the first request that the client sends before even knowing
/// which version of the protocol the server uses. It's important we
/// keep it "append only" (same with the reply).
pub const Authenticate = struct {
    // The latest uid observed by the client, used for efficient
    // state synchronization.
    max_uid: u64,
    device_kind: enum(u8) { pc, mobile },
    method: union(Method) {
        login: struct {
            username: []const u8,
            password: []const u8,

            pub const protocol = struct {
                pub const sizes = struct {
                    pub const username = u16;
                    pub const password = u16;
                };
            };
        },

        pub const protocol = struct {};
    },

    pub const marker = 'A';
    pub const serialize = proto.MakeSerializeFn(Authenticate);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(Authenticate);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const username = u16;
        };
    };

    pub const Method = enum(u8) {
        login,
    };

    pub fn deinit(auth: Authenticate, gpa: std.mem.Allocator) void {
        switch (auth.method) {
            .login => |login| {
                gpa.free(login.username);
                gpa.free(login.password);
            },
        }
    }
};

/// Get information for an invite.
/// Must be sent unauthenticated.
///
/// Response type:
/// - on error: ClientRequestReply
/// - on success: InviteInfoReply
pub const InviteInfo = struct {
    slug: []const u8,

    pub const marker = 'I';
    pub const serialize = proto.MakeSerializeFn(InviteInfo);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(InviteInfo);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const slug = u16;
        };
    };

    pub const Error = enum { invite_invalid, invite_expired };

    pub fn replyErr(_: InviteInfo, err: Error) server.ClientRequestReply {
        return .{
            .origin = 0, // No origin
            .reply_marker = marker,
            .result = .{ .err = .{ .code = @intFromEnum(err) } },
        };
    }

    pub fn deinit(ii: InviteInfo, gpa: std.mem.Allocator) void {
        gpa.free(ii.slug);
    }
};

/// Get information for an invite.
/// Must be sent unauthenticated.
///
/// Response type:
/// - on error: ClientRequestReply
/// - on success: HostSync
pub const SignUp = struct {
    invite_slug: []const u8,
    username: []const u8,
    password: []const u8,

    pub const marker = 'S';
    pub const protocol = struct {
        pub const sizes = struct {
            pub const invite_slug = u16;
            pub const username = u16;
            pub const password = u16;
        };
    };

    pub const Error = enum { invite_invalid, invite_expired, username_duplicate };

    pub fn replyErr(_: SignUp, err: Error) server.ClientRequestReply {
        return .{
            .origin = 0, // No origin
            .reply_marker = marker,
            .result = .{ .err = .{ .code = @intFromEnum(err) } },
        };
    }

    pub fn deinit(su: SignUp, gpa: std.mem.Allocator) void {
        gpa.free(su.invite_slug);
        gpa.free(su.username);
        gpa.free(su.password);
    }
};

pub const CallJoin = struct {
    origin: OriginId,
    voice: Channel.Id,

    pub const marker = 'J';
    pub const serialize = proto.MakeSerializeFn(CallJoin);
    pub const serializeAlloc = proto.MakeSerializeAllocFn(CallJoin);
    pub const deserialize = proto.MakeDeserializeFn(CallJoin);
    pub const protocol = struct {};
};

pub const ChatHistoryGet = struct {
    origin: OriginId,
    chat_channel: Channel.Id,
    oldest_uid: u64,

    pub const marker = 'H';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(ChatHistoryGet);
    pub const deserialize = proto.MakeDeserializeFn(ChatHistoryGet);
    pub const protocol = struct {};

    pub const Error = enum {
        unknown_channel,
    };

    pub fn replyErr(chg: ChatHistoryGet, err: Error) server.ClientRequestReply {
        return .{
            .origin = chg.origin,
            .reply_marker = marker,
            .result = .{ .err = .{ .code = @intFromEnum(err) } },
        };
    }
};

pub const ChatMessageSend = struct {
    origin: OriginId,
    channel: Channel.Id,
    text: []const u8,

    pub const marker = 'M';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(ChatMessageSend);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(ChatMessageSend);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const text = u24;
        };
    };

    pub const Error = enum {
        unknown_channel,
        too_long,
    };

    pub fn replyErr(cms: ChatMessageSend, err: Error) server.ClientRequestReply {
        return .{
            .origin = cms.origin,
            .reply_marker = marker,
            .result = .{ .err = .{ .code = @intFromEnum(err) } },
        };
    }

    pub fn deinit(cms: ChatMessageSend, gpa: std.mem.Allocator) void {
        gpa.free(cms.text);
    }
};

pub const ChannelCreate = struct {
    origin: OriginId,
    kind: Channel.Kind,
    name: []const u8,

    pub const marker = 'C';
    pub const serialize = proto.MakeSerializeFn(ChannelCreate);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(ChannelCreate);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const name = u16;
        };
    };

    pub fn deinit(ca: ChannelCreate, gpa: std.mem.Allocator) void {
        gpa.free(ca.name);
    }

    pub const Result = enum { ok, name_taken };
    pub fn reply(
        cc: ChannelCreate,
        result: Result,
    ) server.ClientRequestReply {
        return .{
            .origin = cc.origin,
            .reply_marker = ChannelCreate.marker,
            .result = if (result == .ok) .ok else .{ .err = .{ .code = 0 } },
            // .extra = switch (result) {
            //     .ok => "",
            //     .name_taken => "name taken",
            //     // .fail => "fail",
            // },
        };
    }
};

comptime {
    var names: []const []const u8 = &.{};
    var values: []const u8 = &.{};
    for (@typeInfo(@This()).@"struct".decls) |d| {
        if (@typeInfo(@TypeOf(@field(@This(), d.name))) != .@"struct") continue;
        names = names ++ &[1][]const u8{&.{@field(@This(), d.name).marker}};
        values = values ++ &[1]u8{@field(@This(), d.name).marker};
    }
    _ = @Enum(u8, .exhaustive, names, @ptrCast(values.ptr)); // on error we have a tag collision
}
