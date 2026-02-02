const std = @import("std");
const Allocator = std.mem.Allocator;
const net = std.Io.net;

const Invite = @This();

// TODO: This should probably be a global constant like `awebo.default_tcp_port`
const default_tcp_port = 1991;

/// Unique identifier for the invite
slug: []const u8,
/// Host of the Awebo server
address: Address,
/// Port of the Awebo server
port: u16,

pub const Address = union(enum) {
    hostname: net.HostName,
    ip_address: net.IpAddress,

    pub fn parse(text: []const u8) error{InvalidHost}!Address {
        if (net.IpAddress.parse(text, 0)) |ip| {
            return .{ .ip_address = ip };
        } else |_| {}

        return .{
            .hostname = net.HostName.init(text) catch return error.InvalidHost,
        };
    }

    pub fn format(
        self: Address,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self) {
            .hostname => |h| try writer.writeAll(h.bytes),
            .ip_address => |ip| try ip.format(writer),
        }
    }
};

pub const ParseError = error{
    InvalidScheme,
    InvalidPath,
    InvalidCharacter,
    InvalidHost,
    MissingFragment,
    MissingHost,
    MissingSlug,
} || std.Uri.ParseError || Allocator.Error;

pub fn deinit(invite: Invite, gpa: Allocator) void {
    gpa.free(invite.slug);
    switch (invite.address) {
        .hostname => |h| gpa.free(h.bytes),
        .ip_address => {},
    }
}

/// Parse an invite from a URI.
///
/// The format of an Awebo invite URI is `awebo://<host>[:port]/invite/<slug>`.
/// This function also accepts `http(s)` URLs, in which case the invite is
/// parsed out of the URL fragment: `https://example.com/random/path#awebo://<host>[:port]/invite/<slug>`.
/// If the input is an `http(s)` URL, all components of the URL are ignored except for the fragment.
pub fn parse(gpa: Allocator, text: []const u8) ParseError!Invite {
    const uri = blk: {
        const outer = try std.Uri.parse(text);
        if (std.ascii.eqlIgnoreCase(outer.scheme, "awebo")) {
            break :blk outer;
        } else if (!std.ascii.eqlIgnoreCase(outer.scheme, "http") and !std.ascii.eqlIgnoreCase(outer.scheme, "https")) {
            // Scheme is not "awebo", "http", or "https"
            return error.InvalidScheme;
        }

        // Invite is in the fragment of the http(s) URL
        const fragment = if (outer.fragment) |f| switch (f) {
            inline else => |c| c,
        } else {
            return error.MissingFragment;
        };
        if (std.mem.indexOfScalar(u8, fragment, '%') != null) {
            return error.InvalidCharacter;
        }
        const inner = try std.Uri.parse(fragment);
        if (!std.ascii.eqlIgnoreCase(inner.scheme, "awebo")) {
            return error.InvalidScheme;
        }

        break :blk inner;
    };

    const path_prefix = "/invite/";
    const path = switch (uri.path) {
        inline else => |c| c,
    };
    if (!std.ascii.startsWithIgnoreCase(path, path_prefix)) {
        return error.InvalidPath;
    }

    const slug = switch (uri.path) {
        inline else => |c| try gpa.dupe(u8, c[path_prefix.len..]),
    };
    if (slug.len == 0) return error.MissingSlug;
    errdefer gpa.free(slug);
    for (slug) |c| if (!std.ascii.isPrint(c) or c == '/') {
        return error.InvalidCharacter;
    };

    const host_str = if (uri.host) |h| switch (h) {
        inline else => |c| try gpa.dupe(u8, c),
    } else {
        return error.MissingHost;
    };
    errdefer gpa.free(host_str);

    const invite: Invite = .{
        .slug = slug,
        .address = try Address.parse(host_str),
        .port = uri.port orelse default_tcp_port,
    };
    if (invite.address == .ip_address) {
        // Free now since it is not referenced in `invite.host`,
        // so it wouldn't be freed by `invite.deinit`
        gpa.free(host_str);
    }

    return invite;
}

test parse {
    const gpa = std.testing.allocator;

    { // Valid
        const invite: Invite = try .parse(gpa, "awebo://host/invite/blablabla");
        defer invite.deinit(gpa);

        try std.testing.expectEqualSlices(u8, "blablabla", invite.slug);
        try std.testing.expectEqualDeep(Address{ .hostname = .{ .bytes = "host" } }, invite.address);
        try std.testing.expectEqual(default_tcp_port, invite.port);
    }

    { // Valid, non-default port
        const invite: Invite = try .parse(gpa, "awebo://host:1234/invite/blablabla");
        defer invite.deinit(gpa);

        try std.testing.expectEqualSlices(u8, "blablabla", invite.slug);
        try std.testing.expectEqualDeep(Address{ .hostname = .{ .bytes = "host" } }, invite.address);
        try std.testing.expectEqual(1234, invite.port);
    }

    { // Valid, HTTP URL
        const invite: Invite = try .parse(gpa, "http://example.com/a/random/path?query=what#awebo://host/invite/blablabla");
        defer invite.deinit(gpa);

        try std.testing.expectEqualSlices(u8, "blablabla", invite.slug);
        try std.testing.expectEqualDeep(Address{ .hostname = .{ .bytes = "host" } }, invite.address);
        try std.testing.expectEqual(default_tcp_port, invite.port);
    }

    { // Missing fragment
        try std.testing.expectError(error.MissingFragment, Invite.parse(gpa, "http://example.com/a/random/path?query=what"));
    }

    { // Missing slug
        try std.testing.expectError(error.MissingSlug, Invite.parse(gpa, "awebo://host/invite/"));
    }

    { // Invalid path
        try std.testing.expectError(error.InvalidPath, Invite.parse(gpa, "awebo://host/hello/blablabla"));
    }

    { // Invalid scheme
        try std.testing.expectError(error.InvalidScheme, Invite.parse(gpa, "what://are/you/doing?"));
    }
}

/// Format as an `awebo://<host>[:port]/invite/<slug>` URI
pub fn format(
    self: Invite,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    // Scheme
    try writer.writeAll("awebo://");
    // Host
    switch (self.address) {
        .hostname => |h| {
            try writer.writeAll(h.bytes);
        },
        .ip_address => |ip| switch (ip) {
            .ip4 => |ip4| {
                const bytes = &ip4.bytes;
                try writer.print("{d}.{d}.{d}.{d}", .{ bytes[0], bytes[1], bytes[2], bytes[3] });
            },
            .ip6 => |ip6| {
                const u: net.Ip6Address.Unresolved = .{
                    .bytes = ip6.bytes,
                    .interface_name = null,
                };
                try writer.print("[{f}]", .{u});
            },
        },
    }
    // Port
    if (self.port != default_tcp_port) {
        try writer.print(":{d}", .{self.port});
    }
    // Path
    try writer.print("/invite/{s}", .{self.slug});
}

test format {
    try std.testing.expectFmt("awebo://host/invite/blablabla", "{f}", .{
        Invite{
            .slug = "blablabla",
            .address = .{ .hostname = .{ .bytes = "host" } },
            .port = 1991,
        },
    });

    try std.testing.expectFmt("awebo://host:1234/invite/blablabla", "{f}", .{
        Invite{
            .slug = "blablabla",
            .address = .{ .hostname = .{ .bytes = "host" } },
            .port = 1234,
        },
    });

    try std.testing.expectFmt("awebo://1.2.3.4:1234/invite/blablabla", "{f}", .{
        Invite{
            .slug = "blablabla",
            .address = .{
                .ip_address = .{
                    .ip4 = .{
                        .bytes = .{ 1, 2, 3, 4 },
                        .port = 4321, // This port should not be used
                    },
                },
            },
            .port = 1234,
        },
    });
}
