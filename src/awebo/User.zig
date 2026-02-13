const User = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const context = @import("options").context;
const awebo = @import("../awebo.zig");

// - u26 max 67_108_864 users per server
// - u4 max 16 clients connected
// - u2 max 4 media streams (cam, voice, screenshare, screenshare audio)

pub const Id = u64;

id: Id,
created: awebo.Date,
update_uid: u64,
invited_by: ?Id,
power: Power,
handle: []const u8,
display_name: []const u8,
avatar: []const u8,
server: switch (context) {
    .server => ServerOnly,
    .client => struct {
        pub const protocol = struct {
            pub const skip = true;
        };
    },
} = .{},

/// Permission baseline for this user.
/// Banned users must fail all permission checks.
/// Users must be subject to default permissions and cooldowns, which can be tweaked at runtime via database entries.
/// Owner and Admins must pass all permission checks and must not be subject to any cooldown limitation.
/// Owner and Admins can access the moderator panel and the admin panel.
/// Moderators can access the moderator panel and moderator operations (e.g. 'ban user').
/// Admins can demote moderators and other admins, but not the owner.
/// There can only be one owner.
pub const Power = enum(u8) {
    banned,
    user,
    moderator,
    admin,
    owner,
};

pub const ServerOnly = struct {
    pswd_hash: []const u8 = undefined,

    pub const protocol = struct {
        pub const skip = true;
    };

    fn deinit(self: @This(), gpa: Allocator) void {
        gpa.free(self.pswd_hash);
    }
};

pub const protocol = struct {
    pub const sizes = struct {
        pub const handle = u16;
        pub const display_name = u16;
        pub const avatar = u16;
    };
};

pub fn deinit(u: User, gpa: Allocator) void {
    gpa.free(u.handle);
    gpa.free(u.display_name);
    gpa.free(u.avatar);

    switch (context) {
        .client => {},
        .server => u.server.deinit(gpa),
    }
}

pub fn format(user: *const User, w: *Io.Writer) !void {
    try w.print(
        "User(id: {} power: {} invited_by: {?} handle: '{s}' display_name: '{s}')",
        .{ user.id, user.power, user.invited_by, user.handle, user.display_name },
    );
}
