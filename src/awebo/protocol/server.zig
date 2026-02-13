const context = @import("options").context;
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const proto = @import("../protocol.zig");
const User = @import("../User.zig");
const Caller = @import("../Caller.zig");
const Host = @import("../Host.zig");
const Channel = @import("../Channel.zig");
const Message = @import("../Message.zig");
// const Role = @import("../Role.zig");

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

    pub fn deinit(iir: InviteInfoReply, gpa: Allocator) void {
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
    server_max_uid: u64,
    name: []const u8,
    epoch: i64,
    users: struct {
        full: []User.Id,
        delta: []User,
        pub const protocol = struct {
            pub const sizes = struct {
                pub const full = u64;
                pub const delta = u64;
            };
        };
    },
    channels: struct {
        full: []Channel.Id,
        delta: []ChannelDelta,

        pub const protocol = struct {
            pub const sizes = struct {
                pub const full = u64;
                pub const delta = u64;
            };
        };
    },

    pub const ChannelDelta = struct {
        id: Channel.Id,
        meta: ?Channel = null,
        messages: struct {
            /// Messages are stored in a ring buffer
            tail: []const Message = &.{},
            head: []const Message = &.{},

            pub fn slices(messages: *const @This()) [2][]const Message {
                return .{ messages.tail, messages.head };
            }

            pub fn totalLen(messages: *const @This()) usize {
                return @intCast(messages.tail.len + messages.head.len);
            }

            pub const protocol = struct {
                pub const sizes = struct {
                    pub const tail = u8;
                    pub const head = u8;
                };
            };
        } = .{},
        // modified_messages: []Message,

        pub const protocol = struct {};
    };

    pub fn deinit(hs: *const HostSync, gpa: Allocator) void {
        _ = hs;
        _ = gpa;
    }

    pub fn format(hs: *const HostSync, w: *Io.Writer) !void {
        try w.print(
            "HostSync(user_id: {} server_max_uid: {} name: '{s}' users: ({} {s}) [",
            .{
                hs.user_id, hs.server_max_uid,
                hs.name,    hs.users.delta.len,
                if (hs.users.full.len > 0)
                    "full"
                else
                    "",
            },
        );

        for (hs.users.delta, 0..) |u, i| {
            try w.print("(id: {} uid: {})", .{ u.id, u.update_uid });
            if (i < hs.users.delta.len - 1) {
                try w.writeAll(", ");
            }
        }

        try w.print("] channels: ({}) [", .{hs.channels.delta.len});

        for (hs.channels.delta, 0..) |ch, i| {
            try w.print("(id: {} uid: {?} msgs: {?})", .{
                ch.id,
                if (ch.meta) |m| m.update_uid else null,
                if (ch.meta) |m| switch (m.kind) {
                    .voice => null,
                    .chat => ch.messages.totalLen(),
                } else null,
            });
            if (i < hs.channels.delta.len - 1) {
                try w.writeAll(", ");
            }
        }

        try w.writeAll("])");
    }

    pub const marker = 'S';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(HostSync);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(HostSync);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const name = u64;
        };
    };
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
    tcp_client: i96,
    nonce: u64,

    pub const marker = 'm';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(MediaConnectionDetails);
    pub const deserialize = proto.MakeDeserializeFn(MediaConnectionDetails);
    pub const protocol = struct {};
};

pub const ChatTyping = struct {
    uid: User.Id,
    channel: Channel.Id,

    pub const marker = 'T';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(ChatTyping);
    pub const deserialize = proto.MakeDeserializeFn(ChatTyping);
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

pub const ChatHistory = struct {
    origin: u64,
    // TODO: this should be removed once we can
    //       cross-reference origins
    channel: Channel.Id,
    history: []Message,

    pub const marker = 'h';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(ChatHistory);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(ChatHistory);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const history = u64;
        };
    };
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

pub const SearchMessagesReply = struct {
    origin: u64,
    results: []const Result,

    pub const Result = struct {
        channel: Channel.Id,
        preview: Message,

        pub const protocol = struct {};
    };

    pub fn deinit(smr: SearchMessagesReply, gpa: Allocator) void {
        for (smr.results) |result| {
            result.preview.deinit(gpa);
        }
        gpa.free(smr.results);
    }

    pub const marker = 'F';
    pub const serializeAlloc = proto.MakeSerializeAllocFn(SearchMessagesReply);
    pub const deserializeAlloc = proto.MakeDeserializeAllocFn(SearchMessagesReply);
    pub const protocol = struct {
        pub const sizes = struct {
            pub const results = u32;
        };
    };
};

pub const Enum = blk: {
    var names: []const []const u8 = &.{};
    var values: []const u8 = &.{};
    for (@typeInfo(@This()).@"struct".decls) |d| {
        if (std.mem.eql(u8, d.name, "Enum")) continue;
        if (@typeInfo(@field(@This(), d.name)) != .@"struct") continue;
        names = names ++ &[1][]const u8{d.name};
        values = values ++ &[1]u8{@field(@This(), d.name).marker};
    }
    break :blk @Enum(u8, .exhaustive, names, @ptrCast(values.ptr)); // on error we have a tag collision
};
