const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const awebo = @import("../../awebo.zig");

pub const StreamId = packed struct(u32) {
    client_id: awebo.protocol.client.Id,
    kind: StreamKind,

    pub fn format(sid: StreamId, w: *Io.Writer) !void {
        try w.print("Stream({f}, {t})", .{ sid.client_id, sid.kind });
    }
};

pub const StreamKind = enum(u2) {
    voice = 0,
    camera = 1,
    screen = 2,
    reserved = 3,
};

/// Header attached to all UDP messages.
pub const Header = extern struct {
    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                       IP + UDP Header                         | 28
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                          User ID                  |  CSN  | S | 4 (StreamId)
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                    Packet Sequence Number                     | 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                                                               |
    // |              Packet-specific fields and data                  | 1256
    // |                                                               |
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    stream_id: StreamId,
    sequence: u32,

    comptime {
        std.debug.assert(@bitSizeOf(Header) == 64);
    }

    /// If there are not enough bytes to parse a Header,
    /// returns null, otherwise returns a header and a slice
    /// to the bytes after the header.
    pub fn parse(udp_data: []u8) ?struct { *align(1) Header, []u8 } {
        if (udp_data.len < @sizeOf(Header)) return null;
        const header = std.mem.bytesAsValue(
            Header,
            udp_data[0..@sizeOf(Header)],
        );

        return .{ header, udp_data[@sizeOf(Header)..] };
    }
};

/// A open path request sends to the server the same nonce we received
/// when first asking to join a call over TCP. Confirmation will be sent
/// by the server over TCP if the packet was received and the UDP stream
/// has been opened successfully. If the client doesn't receive such
/// confirmation after a short timeout, it should assume that the packet
/// was lost and send it again. The server should ignore duplicates and
/// spurious requests.
///
/// An open path request is marked by Packet Sequence Number set to 0.
/// Additionally an OpenStream packet must:
/// - have S (StreamType) set to 0 (2 lowest bits of StreamId)
/// - not contain any other data
pub const OpenPath = extern struct {
    nonce: u64,

    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                       IP + UDP Header                         | 28
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                          User ID                  |  CID  | S | 4  (client id << 2)
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                    Packet Sequence Number                     | 4  (end of header)
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                            Nonce                              | 8
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    pub inline fn serialize(
        client_id: awebo.protocol.client.Id,
        nonce: u64,
    ) [@sizeOf(Header) + @sizeOf(OpenPath)]u8 {
        const header: Header = .{
            .stream_id = .{
                .client_id = client_id,
                .kind = @enumFromInt(0),
            },
            .sequence = 0,
        };

        const open: OpenPath = .{
            .nonce = nonce,
        };

        var out: [@sizeOf(Header) + @sizeOf(OpenPath)]u8 = undefined;
        _ = std.fmt.bufPrint(&out, "{s}{s}", .{
            std.mem.asBytes(&header),
            std.mem.asBytes(&open),
        }) catch unreachable;

        return out;
    }

    pub fn parse(body: []const u8) ?OpenPath {
        if (body.len != @sizeOf(OpenPath)) return null;
        return std.mem.bytesToValue(OpenPath, body);
    }
};

/// A packet containing voice data.
/// Both Packet Sequence Number and Restart Sequence Number start at 1.
/// Contains Opus encoded data, usually smaller than 200 bytes.
pub const Voice = extern struct {
    restart: u32,

    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                           Header                              | 36
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                   Restart Sequence Number                     | 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                            Data                               |  1256
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    pub fn serialize(
        out: []u8,
        stream_type: StreamKind,
        sequence: u32,
        restart: u32,
        data: []const u8,
    ) ![]const u8 {
        const header: Header = .{
            .stream_id = .{
                .client_id = undefined,
                .kind = stream_type,
            },
            .sequence = sequence,
        };

        const voice: Voice = .{
            .restart = restart,
        };

        return std.fmt.bufPrint(out, "{s}{s}{s}", .{
            std.mem.asBytes(&header),
            std.mem.asBytes(&voice),
            data,
        });
    }

    pub fn parse(body: []const u8) ?struct { Voice, []const u8 } {
        if (body.len < @sizeOf(Voice)) return null;
        return .{
            std.mem.bytesToValue(Voice, body[0..@sizeOf(Voice)]),
            body[@sizeOf(Voice)..],
        };
    }
};

/// Represents a video packet from either the 'camera' or the 'screen' stream.
/// Since video produces big frames, a video packet can be split into multiple
/// chunks. Chunk sequence numbers start at the total number of chunks and
/// are decremented until reaching 0. Chunk ID 0 is always the last UDP packet
/// that makes up a Video packet. The first chunk will also have F (first_of_chunk)
/// set to true.
pub const Video = packed struct {
    keyframe: bool,
    chunk_id: u15,
    unused: bool = false,
    total_chunks: u15,

    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                           Header                              | 36
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |K|          Chunk ID           |U|         Total Chunks        | 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                            Data                               |  1258
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    /// Number of bytes present in a full chunk.
    /// All chunks are full except the last one, which might be shorter.
    pub const data_per_chunk: usize = 1280 - (@sizeOf(Header) + @sizeOf(Video));

    pub fn serialize(
        out: []u8,
        stream: StreamId,
        sequence: u32,
        chunk_id: @FieldType(Video, "chunk_id"),
        total_chunks: @FieldType(Video, "total_chunks"),
        keyframe: bool,
        data: []const u8,
    ) ![]const u8 {
        const header: Header = .{
            .stream_id = stream,
            .sequence = sequence,
        };

        const video: Video = .{
            .keyframe = @intFromBool(keyframe),
            .chunk_id = chunk_id,
            .total_chunks = total_chunks,
        };

        return std.fmt.bufPrint(out, "{s}{s}{s}", .{
            std.mem.asBytes(&header),
            std.mem.asBytes(&video),
            data,
        });
    }

    pub fn parse(body: []const u8) ?struct { Video, []const u8 } {
        if (body.len < @sizeOf(Video)) return null;
        return .{
            std.mem.bytesToValue(Video, body[0..@sizeOf(Video)]),
            body[@sizeOf(Video)..],
        };
    }
};

/// Requests to resend one or more UDP packets that make up a Video packet.
/// Can be sent by both clients and server.
pub const ResendVideoChunk = packed struct {

    //  0                   1                   2                   3
    //  0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |                                                               |
    // |                           Header                              | 36
    // |                                                               |
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
    // |      Chunk ID Start       | U |       Chunk ID End        | U | 4
    // +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+

    pub fn serialize(
        out: *[@sizeOf(ResendVideoChunk)]u8,
        stream: StreamId,
        sequence: u32,
        chunk_start: u14,
        chunk_end: u14,
    ) ![]const u8 {
        const header: Header = .{
            .stream_id = stream,
            .sequence = sequence,
        };

        const video: Video = .{
            .chunk_start = chunk_start,
            .chunk_end = chunk_end,
        };

        return std.fmt.bufPrint(out, "{s}{s}", .{
            std.mem.asBytes(&header),
            std.mem.asBytes(&video),
        });
    }

    pub fn parse(body: []const u8) ?@This() {
        if (body.len < @sizeOf(@This())) return null;
        return std.mem.bytesToValue(@This(), body[0..@sizeOf(@This())]);
    }
};
