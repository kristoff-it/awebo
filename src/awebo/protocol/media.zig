const std = @import("std");
const Allocator = std.mem.Allocator;
const awebo = @import("../../awebo.zig");
const Voice = awebo.channels.Voice;

/// Header attached to all UDP messages
pub const Header = extern struct {
    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                       IP + UDP Header                         | 28
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |             Unused            |            Client ID        |S| 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                    Packet Sequence Number                     | 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                          Timestamp                            | 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                                                               |
    // |                             Data                              | 1460
    // |                                                               |
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    unused: u16 = 0,
    id: Id,
    sequence: u32,
    timestamp: u32,

    comptime {
        std.debug.assert(@sizeOf(Header) == 12);
    }

    pub const Id = packed struct(u16) {
        /// Always left unset by clients and set by the server
        /// before broadcasting the message to other clients
        client_id: u15, // 32k clients, 64k streams
        source: enum(u1) { mic, share },
    };

    pub fn streamId(h: Header) u16 {
        const ptr: *const u16 = @ptrCast(&h.id.client_id);
        return ptr.*;
    }

    /// If there are not enough bytes to parse a Header,
    /// returns null, otherwise returns a header and a slice
    /// to the bytes after the header.
    pub fn parse(msg: []u8) ?struct { *align(1) Header, []u8 } {
        if (msg.len < @sizeOf(Header)) return null;
        const header = std.mem.bytesAsValue(
            Header,
            msg[0..@sizeOf(Header)],
        );

        return .{ header, msg[@sizeOf(Header)..] };
    }

    const Kind = enum {
        media,
        open_stream,
    };
    pub fn kind(h: Header) Kind {
        if (h.sequence == 0) {
            return .open_stream;
        }

        return .media;
    }
};

/// A open stream request sends to the server the same nonce we received
/// when first asking to join a call over TCP. Confirmation will be sent
/// by the server over TCP if the packet was received and the UDP stream
/// has been opened successfully. If the client doesn't receive such
/// confirmation after a short timeout, it should assume that the packet
/// was lost and send it again. The server should ignore duplicates and
/// spurious requests.
///
/// An open stream request is marked by Packet Sequence Number set to 0.
/// The rest of the header data will be ignored.
pub const OpenStream = extern struct {
    tcp_client: u64,
    nonce: u64,

    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                       IP + UDP Header                         | 28
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |             Unused            |            Client ID        |S| 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                    Packet Sequence Number                     | 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                          Timestamp                            | 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                        TCP Client ID                          | 8
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                            Nonce                              | 8
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                           Unused                              |
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    pub fn serialize(os: OpenStream, gpa: Allocator) ![]const u8 {
        const header: Header = .{
            .id = .{
                .client_id = 0,
                .source = .mic,
            },
            .sequence = 0,
            .timestamp = 0,
        };

        return std.fmt.allocPrint(gpa, "{s}{s}", .{
            std.mem.asBytes(&header),
            std.mem.asBytes(&os),
        });
    }

    pub fn parse(buf: []const u8) ?OpenStream {
        if (buf.len != @sizeOf(OpenStream)) return null;
        return std.mem.bytesToValue(OpenStream, buf);
    }
};

// pub const Connect = struct {
//     pub const marker = .connect;

//     // Client
//     pub const Request = struct {
//         token: [6]u8,

//         comptime {
//             std.debug.assert(@sizeOf(Request) + 1 < awebo.srt.MESSAGE_SIZE);
//         }

//         pub fn serialize(req: Request, buf: *[awebo.srt.MESSAGE_SIZE]u8) []const u8 {
//             var fbs = std.io.fixedBufferStream(buf);
//             const w = fbs.writer();
//             w.writeByte(marker) catch unreachable;
//             w.writeAll(&req.token) catch unreachable;
//             return fbs.getWritten();
//         }
//     };

//     // Server
//     pub const Response = struct {
//         ok: bool,
//         err: []const u8,

//         comptime {
//             std.debug.assert(@sizeOf(Response) + 1 < awebo.srt.MESSAGE_SIZE);
//         }

//         pub fn serialize(res: Response, gpa: std.mem.Allocator) ![]const u8 {
//             var buf = std.ArrayList(u8).init(gpa);
//             const w = buf.writer();

//             try w.writeByte(@intFromBool(res.ok));
//             try utils.writeSmallSlice(w, res.err);

//             return try buf.toOwnedSlice();
//         }
//     };
// };

// pub const CloseStream = struct {
//     pub const marker = 'C';

//     // Client
//     pub const Request = struct {
//         stream: enum { mic, screenshare },

//         comptime {
//             std.debug.assert(@sizeOf(Request) + 1 < awebo.srt.MESSAGE_SIZE);
//         }

//         pub fn serialize(req: Request, gpa: std.mem.Allocator) ![]const u8 {
//             var buf = std.ArrayList(u8).init(gpa);
//             const w = buf.writer();
//             try w.writeAll(req.token);
//             return try buf.toOwnedSlice();
//         }
//     };

//     // Server
//     pub const Response = struct {
//         ok: bool,
//         err: []const u8,

//         comptime {
//             std.debug.assert(@sizeOf(Response) + 1 < awebo.srt.MESSAGE_SIZE);
//         }

//         pub fn serialize(res: Response, gpa: std.mem.Allocator) ![]const u8 {
//             var buf = std.ArrayList(u8).init(gpa);
//             const w = buf.writer();

//             try w.writeByte(@intFromBool(res.ok));
//             try utils.writeSmallSlice(w, res.err);

//             return try buf.toOwnedSlice();
//         }
//     };
// };
