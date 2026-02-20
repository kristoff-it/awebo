const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const awebo = @import("../../awebo.zig");
const persistence = @import("../Core/persistence.zig");
const Core = @import("../Core.zig");
const Media = @import("../Media.zig");
const HostView = Core.HostView;
const TcpMessage = awebo.protocol.TcpMessage;
const ClientRequestReply = awebo.protocol.server.ClientRequestReply;
const HostId = awebo.Host.ClientOnly.Id;
const log = std.log.scoped(.net);

pub const HostConnectMode = union(enum) {
    join: *Core.ui.FirstConnectionStatus,
    connect: struct {
        host_id: HostId,
        max_uid: u64,
    },
};

pub fn runHostManager(
    core: *Core,
    mode: HostConnectMode,
    identity: []const u8,
    username: []const u8,
    password: []const u8,
) error{Canceled}!void {
    const io = core.io;

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    // On return this fuction must have progressed `fcs` to a terminal state.
    defer if (builtin.mode == .Debug) switch (mode) {
        .join => |fcs| assert(fcs.isDone()),
        .connect => {},
    };

    const addr = Io.net.IpAddress.parse(identity, 1991) catch unreachable; // already validated
    var hc: HostConnection = .{
        .identity = identity,
        .username = username,
        .password = password,
        .tcp = .{
            .addr = addr,
            .stream = undefined,
        },
    };

    var retry_count: usize = 0;
    while (true) : (retry_count += 1) {
        if (retry_count > 0) {
            if (mode == .connect) core.putEvent(.{
                .network = .{
                    .host_id = mode.connect.host_id,
                    .cmd = .{
                        .host_connection_update = .{ .disconnected = core.now() + (2 * std.time.ns_per_s) },
                    },
                },
            }) catch return;
            log.debug("disconnected, sleeping", .{});
            io.sleep(.fromSeconds(2), .real) catch return;
        }

        hc.tcp.stream = addr.connect(io, .{
            .mode = .stream,
            .protocol = .tcp,
            // TODO: re-enable when implemented in Zig
            // .timeout = .{ .duration = .{ .raw = .fromSeconds(10), .clock = .real } },
        }) catch |err| switch (err) {
            error.Canceled => return,
            else => continue,
        };

        const yes: c_int = 1;
        std.posix.setsockopt(
            hc.tcp.stream.socket.handle,
            std.c.IPPROTO.TCP,
            std.c.TCP.NODELAY,
            &std.mem.toBytes(yes),
        ) catch |err| {
            log.debug("failed to enable TCP_NODELAY: {t}", .{err});
        };

        if (retry_count > 0) {
            log.debug("reconnected", .{});
        }

        defer hc.tcp.stream.close(io);

        hc.tcp.queue = .init(&hc.tcp.qbuf);
        hc.tcp.reader_state = hc.tcp.stream.reader(io, &hc.tcp.rbuf);
        hc.tcp.writer_state = hc.tcp.stream.writer(io, &hc.tcp.wbuf);

        runHostManagerFallible(core, mode, &hc) catch |err| switch (err) {
            // error.SystemResources,
            // error.ProcessFdQuotaExceeded,
            // error.UnsupportedClock,
            error.OutOfMemory,
            => oom(), // noreturn
            // error.Timeout,
            error.WriteFailed,
            error.ReadFailed,
            error.EndOfStream,
            // error.ConnectionResetByPeer,
            // error.WouldBlock,
            // error.AccessDenied,
            // error.Unexpected,
            // error.AddressUnavailable,
            // error.NetworkDown,
            // error.AddressFamilyUnsupported,
            // error.ProtocolUnsupportedBySystem,
            // error.ProtocolUnsupportedByAddressFamily,
            // error.SocketModeUnsupported,
            // error.OptionUnsupported,
            // error.ConnectionPending,
            // error.ConnectionRefused,
            // error.HostUnreachable,
            // error.NetworkUnreachable,
            => {
                log.debug("network error: {t}", .{err});
                switch (mode) {
                    .join => |fcs| fcs.update(core, @src(), .network_error),
                    .connect => {},
                }
                return;
            },
            error.Closed => {
                log.debug("channel closed", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(core, @src(), .canceled),
                    .connect => {},
                }
                return;
            },
            error.Canceled => {
                log.debug("canceled", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(core, @src(), .canceled),
                    .connect => {},
                }
                return error.Canceled;
            },
            error.AweboProtocol => {
                log.debug("protocol error", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(core, @src(), .network_error),
                    .connect => {},
                }
                return;
            },
            error.AuthenticationFailed => {
                log.debug("authentication failure", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(core, @src(), .authentication_failure),
                    .connect => {},
                }
                return;
            },
            error.DuplicateHost => {
                log.debug("duplicate host", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(core, @src(), .duplicate),
                    .connect => {},
                }
                return;
            },
            error.ConcurrencyUnavailable => fatal("concurrency unavaliable", .{}),
        };
    }
}

fn runHostManagerFallible(
    core: *Core,
    mode: HostConnectMode,
    hc: *HostConnection,
) !void {
    const gpa = core.gpa;
    const io = core.io;

    log.debug("connected", .{});
    switch (mode) {
        .join => |fcs| fcs.update(core, @src(), .connected),
        .connect => {},
    }

    const identity = hc.identity;
    const username = hc.username;
    const password = hc.password;
    const w = &hc.tcp.writer_state.interface;
    const r = &hc.tcp.reader_state.interface;

    const auth: awebo.protocol.client.Authenticate = .{
        .max_uid = switch (mode) {
            .join => 0,
            .connect => |c| c.max_uid,
        },
        .device_kind = .pc,
        .method = .{
            .login = .{
                .username = username,
                .password = password,
            },
        },
    };

    try auth.serialize(w);
    try w.flush();

    log.debug("sent auth request", .{});

    const marker = try r.takeByte();
    log.debug("got marker '{c}'", .{marker});
    if (marker != awebo.protocol.server.AuthenticateReply.marker) {
        log.debug("expected ClientReply marker, got '{c}'", .{marker});
        return error.AweboProtocol;
    }
    const reply = try awebo.protocol.server.AuthenticateReply.deserializeAlloc(gpa, r);
    if (reply.result != .authorized) return error.AuthenticationFailed;

    log.debug("authenticated successfully", .{});
    switch (mode) {
        .join => |fcs| fcs.update(core, @src(), .authenticated),
        .connect => {},
    }

    const host_id = switch (mode) {
        .connect => |c| c.host_id,
        .join => |fcs| blk: {
            const host_id = lock: {
                var locked = core.lockState();
                defer locked.unlock();
                const host = try core.hosts.add(core, identity, username, password, true);
                try persistence.initHostDb(gpa, core.cache_path, host);
                break :lock host.client.host_id;
            };

            log.debug("host added successfully", .{});
            fcs.update(core, @src(), .success);
            break :blk host_id;
        },
    };

    var receive_future = try io.concurrent(runHostReceive, .{ core, hc, host_id });
    defer receive_future.cancel(io) catch {};

    var send_future = try io.concurrent(runHostSend, .{ core, hc });
    defer send_future.cancel(io) catch {};

    log.debug("notifying core we connected successfully", .{});
    try core.putEvent(.{ .network = .{ .host_id = host_id, .cmd = .{ .host_connection_update = .{ .connected = hc } } } });

    _ = io.select(.{ &receive_future, &send_future }) catch return error.Canceled;

    //hc.tcp.manager_future =

}

fn runHostReceive(
    core: *Core,
    hc: *HostConnection,
    id: awebo.Host.ClientOnly.Id,
) !void {
    const gpa = core.gpa;

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    const reader = &hc.tcp.reader_state.interface;
    while (true) {
        const marker = try reader.takeByte();
        log.debug("seen marker '{c}'", .{marker});
        const marker_enum: awebo.protocol.server.Enum = @enumFromInt(marker);
        switch (marker_enum) {
            .AuthenticateReply, .InviteInfoReply => unreachable, // handled while establishing a connection
            .HostSync => {
                const hs: awebo.protocol.server.HostSync = try .deserializeAlloc(gpa, reader);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .host_sync = hs } } });
            },
            .ChatTyping => {
                const ct: awebo.protocol.server.ChatTyping = try .deserialize(reader);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .chat_typing = ct } } });
            },
            .ChatMessageNew => {
                const cmn: awebo.protocol.server.ChatMessageNew = try .deserializeAlloc(gpa, reader);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .chat_message_new = cmn } } });
            },
            .ChatHistory => {
                const ch: awebo.protocol.server.ChatHistory = try .deserializeAlloc(gpa, reader);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .chat_history = ch } } });
            },
            .MediaConnectionDetails => {
                const mcd: awebo.protocol.server.MediaConnectionDetails = try .deserialize(reader);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .media_connection_details = mcd } } });
            },
            .CallersUpdate => {
                const cu: awebo.protocol.server.CallersUpdate = try .deserialize(reader);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .callers_update = cu } } });
            },
            .SearchMessagesReply => {
                const smr: awebo.protocol.server.SearchMessagesReply = try .deserializeAlloc(gpa, reader);
                errdefer smr.deinit(gpa);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .search_messages_reply = smr } } });
            },
            .ClientRequestReply => {
                const crr: awebo.protocol.server.ClientRequestReply = try .deserializeAlloc(gpa, reader);
                errdefer crr.deinit(gpa);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .client_request_reply = crr } } });
            },
            .ChannelsUpdate => {
                const cu: awebo.protocol.server.ChannelsUpdate = try .deserializeAlloc(gpa, reader);
                errdefer cu.deinit(gpa);
                try core.putEvent(.{ .network = .{ .host_id = id, .cmd = .{ .channels_update = cu } } });
            },
        }
    }
}

fn runHostSend(
    core: *Core,
    hc: *HostConnection,
) !void {
    const gpa = core.gpa;
    const io = core.io;

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    const writer = &hc.tcp.writer_state.interface;
    while (true) {
        var msgbuf: [64][]const u8 = undefined;
        const messages = msgbuf[0..try hc.tcp.queue.get(io, &msgbuf, 1)];
        log.debug("tcp write got {} messages to send", .{messages.len});
        try writer.writeVecAll(messages);
        for (messages) |msg| gpa.free(msg);
        try writer.flush();
    }
}

// There should be only one of these tasks active at a time
pub fn runHostMediaManager(
    core: *Core,
    host_id: HostId,
    hc: *HostConnection,
    tcp_client: i96,
    nonce: u64,
) void {
    const gpa = core.gpa;
    const io = core.io;

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    const server = Io.net.IpAddress.parse(hc.identity, 1992) catch unreachable;
    const addr = Io.net.IpAddress.parse("0.0.0.0", 0) catch unreachable;
    const sock: Io.net.Socket = addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
        std.process.fatal("unable to bing socket: {t}", .{err});
    };
    defer sock.close(io);

    var receiver_future = io.concurrent(runHostMediaReceiver, .{ core, sock, &server, host_id }) catch return;
    defer receiver_future.cancel(io) catch {};

    var sender_future = io.concurrent(runHostMediaSender, .{ core, sock, &server, host_id }) catch return;
    defer sender_future.cancel(io) catch {};

    const open: awebo.protocol.media.OpenStream = .{
        .tcp_client = tcp_client,
        .nonce = nonce,
    };

    const bytes = open.serialize(gpa) catch oom();
    defer gpa.free(bytes);

    sock.send(io, &server, bytes) catch return;

    _ = io.select(.{ &receiver_future, &sender_future }) catch return;
}

pub fn runHostMediaReceiver(
    core: *Core,
    sock: Io.net.Socket,
    server: *const Io.net.IpAddress,
    host_id: HostId,
) !void {
    const gpa = core.gpa;
    const io = core.io;

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    var imbuf: [64]Io.net.IncomingMessage = undefined;
    var csbuf_idx: usize = 0;
    const dbuf = gpa.alloc(u8, imbuf.len * 1280) catch oom();
    while (true) {
        const m = try sock.receive(io, dbuf);
        log.debug("got media! {}", .{m.data.len});
        if (!m.from.eql(server)) continue;
        log.debug("right server! {}", .{m.data.len});
        const power, const cid = (try receive(core, m.data) orelse continue);
        // log.debug("cid: {} pow: {}", .{ cid, power });
        if (power > 200) {
            try core.putEvent(.{ .network = .{
                .host_id = host_id,
                .cmd = .{
                    .caller_speaking = .{
                        .time_ns = core.now(),
                        .caller = cid,
                    },
                },
            } });
        }

        _ = &csbuf_idx;
        //     const err, const n = sock.receiveManyTimeout(io, &imbuf, dbuf, .{}, .none);
        //     if (err) |e| return e;

        //     const messages = imbuf[0..n];
        //     for (messages) |m| {
        //         const power, const cid = core.media.receive(m.data);
        //         if (power > 200) {
        //             csbuf[csbuf_idx] = .{
        //                 .host_id = 0,
        //                 .cmd = .{
        //                     .caller_speaking = .{
        //                         .time_ms = core.now(),
        //                         .caller = cid,
        //                     },
        //                 },
        //             };
        //             csbuf_idx += 1;
        //         }
        //     }

        //     if (csbuf_idx > 0) {
        //         try core.command_queue.putAll(io, csbuf[0..csbuf_idx]);
        //         csbuf_idx = 0;
        //     }
    }
}

fn receive(core: *Core, message: []const u8) !?struct { f32, u16 } {
    const io = core.io;
    const data = message[@sizeOf(awebo.protocol.media.Header)..];
    const message_header = std.mem.bytesAsValue(
        awebo.protocol.media.Header,
        message[0..@sizeOf(awebo.protocol.media.Header)],
    );

    const cid = message_header.id.client_id;
    log.debug("receive cid = {}", .{cid});

    const active_call = &(core.active_call orelse return null);
    const caller = active_call.callers.get(cid) orelse return null;

    log.debug("caller found!", .{});

    var pcm: [awebo.opus.PACKET_SIZE]f32 = undefined;
    const written = caller.decoder.decodeFloat(
        data,
        &pcm,
        false,
    ) catch unreachable;

    try caller.voice.writeBoth(io, pcm[0..written]);

    var rms: f32 = 0;
    for (pcm[0..written]) |sample| {
        rms += sample * sample;
    }
    rms /= @floatFromInt(written);
    rms = std.math.sqrt(rms);
    return .{ rms * 100000, @intCast(cid) };
}

pub fn runHostMediaSender(
    core: *Core,
    sock: Io.net.Socket,
    server: *const Io.net.IpAddress,
    host_id: HostId,
) !void {
    const io = core.io;

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    while (true) {
        try core.audio.capture_stream.mutex.lock(io);
        defer core.audio.capture_stream.mutex.unlock(io);
        try core.audio.capture_stream.condition.wait(io, &core.audio.capture_stream.mutex);
        const message, const power = blk: {
            var buf: [1280]u8 = undefined;
            const message, const power = send(&core.audio, &buf) catch |err| switch (err) {
                error.NotReady => {
                    // log.debug("capture buffer not ready to send", .{});
                    continue;
                },
            };

            break :blk .{ message, power };
        };

        if (power > 200) {
            try core.putEvent(.{ .network = .{
                .host_id = host_id,
                .cmd = .{
                    .caller_speaking = .{
                        .time_ns = core.now(),
                        .caller = null,
                    },
                },
            } });
        }

        try sock.send(io, server, message);
    }
}

var seq: u32 = 0;
fn send(audio: *Core.Audio, outbuf: *[1280]u8) !struct { []const u8, f32 } {
    seq += 1;

    const header: awebo.protocol.media.Header = .{
        .id = .{
            .client_id = 0,
            .source = .mic,
        },
        .sequence = seq,
        .timestamp = 0,
    };

    var w = Io.Writer.fixed(outbuf);
    w.writeAll(std.mem.asBytes(&header)) catch unreachable;

    if (audio.capture_stream.channels[0].len() < awebo.opus.PACKET_SIZE) {
        return error.NotReady;
    }

    var pcm: [awebo.opus.PACKET_SIZE]f32 = undefined;
    audio.capture_stream.channels[0].readFirstAssumeCount(
        &pcm,
        awebo.opus.PACKET_SIZE,
    );

    const hlen = @sizeOf(awebo.protocol.media.Header);
    const data = outbuf[hlen..];

    const len = audio.capture_encoder.encodeFloat(&pcm, data) catch |err| {
        log.debug("opus encoder error: {t}", .{err});
        return error.EncodingFailure;
    };

    var rms: f32 = 0;
    for (pcm) |sample| {
        rms += sample * sample;
    }
    rms /= @floatFromInt(pcm.len);
    rms = std.math.sqrt(rms);

    return .{ outbuf[0 .. hlen + len], rms * 100000 };
}

pub const HostConnection = struct {
    identity: []const u8,
    username: []const u8,
    password: []const u8,
    tcp: struct {
        addr: Io.net.IpAddress,
        stream: Io.net.Stream,

        qbuf: [256][]const u8 = undefined,
        queue: Io.Queue([]const u8) = undefined,

        rbuf: [4096]u8 = undefined,
        reader_state: Io.net.Stream.Reader = undefined,

        wbuf: [4096]u8 = undefined,
        writer_state: Io.net.Stream.Writer = undefined,

        manager_future: Io.Future(void) = undefined,
    },
    udp: ?struct {
        addr: Io.net.IpAddress,
        sock: Io.net.Socket,
        read_buf: [1472]u8 = undefined,
    } = null,
};

fn oom() noreturn {
    fatal("oom", .{});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print(fmt, args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}
