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

pub const CallJoin = struct {
    origin: OriginId,
    voice: Channel.Id,

    pub const marker = 'J';
    pub const serialize = proto.MakeSerializeFn(CallJoin);
    pub const serializeAlloc = proto.MakeSerializeAllocFn(CallJoin);
    pub const deserialize = proto.MakeDeserializeFn(CallJoin);
    pub const protocol = struct {};
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
