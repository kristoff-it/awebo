pub const Home = @import("channels/Home.zig");
pub const Chat = @import("channels/Chat.zig");
pub const Voice = @import("channels/Voice.zig");

pub const Id = u32;

pub const Privacy = enum(u8) {
    // Only the owner, admins and users with the right permession can see this channel / section.
    secret,
    // All server users can see this channel / section.
    private,
    // The channel / section is publicly visible on the web.
    public,
};

pub const Kind = enum(Size) {
    pub const Size = u8;

    home,
    chat,
    voice,
};
