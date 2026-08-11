const std = @import("std");
const awebo = @import("../awebo.zig");

pub const Kind = enum { server, section, channel };

pub const user_default: Server = .{};

pub const Server = struct {
    authenticate: bool = true,

    pub const Enum = std.meta.FieldEnum(Server);
    pub const descriptions = struct {
        pub const authenticate =
            \\Clients belonging to this user can authenticate.
        ;

        comptime {
            for (@typeInfo(Server).@"struct".field_names) |f_name| {
                if (!@hasDecl(descriptions, f_name)) {
                    @compileError("Server." ++ f_name ++ " must have a corresponding description!");
                }
            }
        }
    };
};
