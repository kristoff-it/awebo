const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const awebo = @import("../../awebo.zig");
const core = @import("../core.zig");
const media = @import("../media.zig");
const HostView = core.HostView;
const TcpMessage = awebo.protocol.TcpMessage;
const ClientRequestReply = awebo.protocol.server.ClientRequestReply;
const HostId = awebo.Host.ClientOnly.Id;

const log = std.log.scoped(.net);

pub const HostConnectMode = union(enum) {
    join: *core.ui.FirstConnectionStatus,
    connect: HostId,
};

pub fn runHostManager(
    io: Io,
    gpa: Allocator,
    mode: HostConnectMode,
    identity: []const u8,
    username: []const u8,
    password: []const u8,
) error{Canceled}!void {
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
            if (mode == .connect) core.command_queue.putOne(io, .{
                .host_id = mode.connect,
                .cmd = .{
                    .host_connection_update = .{ .disconnected = core.now() + (2 * std.time.ns_per_s) },
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

        runHostManagerFallible(io, gpa, mode, &hc) catch |err| switch (err) {
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
                    .join => |fcs| fcs.update(@src(), .network_error),
                    .connect => {},
                }
                return;
            },
            error.Closed => {
                log.debug("channel closed", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(@src(), .canceled),
                    .connect => {},
                }
                return;
            },
            error.Canceled => {
                log.debug("canceled", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(@src(), .canceled),
                    .connect => {},
                }
                return error.Canceled;
            },
            error.AweboProtocol => {
                log.debug("protocol error", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(@src(), .network_error),
                    .connect => {},
                }
                return;
            },
            error.AuthenticationFailed => {
                log.debug("authentication failure", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(@src(), .authentication_failure),
                    .connect => {},
                }
                return;
            },
            error.DuplicateHost => {
                log.debug("duplicate host", .{});
                switch (mode) {
                    .join => |fcs| fcs.update(@src(), .duplicate),
                    .connect => {},
                }
                return;
            },
            error.ConcurrencyUnavailable => fatal("concurrency unavaliable", .{}),
        };
    }
}

fn runHostManagerFallible(
    io: Io,
    gpa: Allocator,
    mode: HostConnectMode,
    hc: *HostConnection,
) !void {
    log.debug("connected", .{});
    switch (mode) {
        .join => |fcs| fcs.update(@src(), .connected),
        .connect => {},
    }

    const identity = hc.identity;
    const username = hc.username;
    const password = hc.password;
    const w = &hc.tcp.writer_state.interface;
    const r = &hc.tcp.reader_state.interface;

    const auth: awebo.protocol.client.Authenticate = .{
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
        .join => |fcs| fcs.update(@src(), .authenticated),
        .connect => {},
    }

    const host_id = switch (mode) {
        .connect => |host_id| host_id,
        .join => |fcs| blk: {
            const host_id = lock: {
                var locked = core.lockState(io);
                defer locked.unlock(io);
                const host = try locked.state.hosts.add(io, gpa, identity, username, password);
                break :lock host.client.host_id;
            };

            log.debug("host added successfully", .{});
            fcs.update(@src(), .success);
            break :blk host_id;
        },
    };

    var receive_future = try io.concurrent(runHostReceive, .{ io, gpa, hc, host_id });
    defer receive_future.cancel(io) catch {};

    var send_future = try io.concurrent(runHostSend, .{ io, gpa, hc });
    defer send_future.cancel(io) catch {};

    log.debug("notifying core we connected successfully", .{});
    try core.command_queue.putOne(io, .{ .host_id = host_id, .cmd = .{ .host_connection_update = .{ .connected = hc } } });

    _ = io.select(.{ &receive_future, &send_future }) catch return error.Canceled;

    //hc.tcp.manager_future =

}

fn runHostReceive(
    io: Io,
    gpa: Allocator,
    hc: *HostConnection,
    id: awebo.Host.ClientOnly.Id,
) !void {
    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    const reader = &hc.tcp.reader_state.interface;
    while (true) {
        const marker = try reader.takeByte();
        log.debug("seen marker '{c}'", .{marker});
        switch (marker) {
            awebo.protocol.server.HostSync.marker => {
                const hs: awebo.protocol.server.HostSync = try .deserializeAlloc(gpa, reader);
                try core.command_queue.putOne(io, .{ .host_id = id, .cmd = .{ .host_sync = hs } });
            },
            awebo.protocol.server.ChatMessageNew.marker => {
                const cmn: awebo.protocol.server.ChatMessageNew = try .deserializeAlloc(gpa, reader);
                try core.command_queue.putOne(io, .{ .host_id = id, .cmd = .{ .chat_message_new = cmn } });
            },
            awebo.protocol.server.MediaConnectionDetails.marker => {
                const mcd: awebo.protocol.server.MediaConnectionDetails = try .deserialize(reader);
                try core.command_queue.putOne(io, .{ .host_id = id, .cmd = .{ .media_connection_details = mcd } });
            },
            awebo.protocol.server.CallersUpdate.marker => {
                const cu: awebo.protocol.server.CallersUpdate = try .deserialize(reader);
                try core.command_queue.putOne(io, .{ .host_id = id, .cmd = .{ .callers_update = cu } });
            },

            else => {
                log.debug("unknown server message marker '{f}', ignoring", .{std.zig.fmtChar(marker)});
                continue;
            },
        }
    }
}

fn runHostSend(
    io: Io,
    gpa: Allocator,
    hc: *HostConnection,
) !void {
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
    io: Io,
    gpa: Allocator,
    host_id: HostId,
    hc: *HostConnection,
    tcp_client: u64,
    nonce: u64,
) !void {
    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    const server = Io.net.IpAddress.parse(hc.identity, 1992) catch unreachable;
    const addr = Io.net.IpAddress.parse("0.0.0.0", 0) catch unreachable;
    const sock: Io.net.Socket = try addr.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer sock.close(io);

    var receiver_future = io.concurrent(runHostMediaReceiver, .{ io, gpa, sock, &server, host_id }) catch return;
    defer receiver_future.cancel(io) catch {};

    var sender_future = io.concurrent(runHostMediaSender, .{ io, sock, &server }) catch return;
    defer sender_future.cancel(io) catch {};

    const open: awebo.protocol.media.OpenStream = .{
        .tcp_client = tcp_client,
        .nonce = nonce,
    };

    const bytes = try open.serialize(gpa);
    defer gpa.free(bytes);

    sock.send(io, &server, bytes) catch return;

    _ = io.select(.{ &receiver_future, &sender_future }) catch return;
}

pub fn runHostMediaReceiver(
    io: Io,
    gpa: Allocator,
    sock: Io.net.Socket,
    server: *const Io.net.IpAddress,
    host_id: HostId,
) !void {
    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    var imbuf: [64]Io.net.IncomingMessage = undefined;
    var csbuf: [64]core.NetworkCommand = undefined;
    var csbuf_idx: usize = 0;
    const dbuf = gpa.alloc(u8, imbuf.len * 1280) catch oom();
    while (true) {
        const m = try sock.receive(io, dbuf);
        if (!m.from.eql(server)) continue;
        const power, const cid = media.receive(m.data);
        // log.debug("cid: {} pow: {}", .{ cid, power });
        if (power > 200) {
            try core.command_queue.putOne(io, .{
                .host_id = host_id,
                .cmd = .{
                    .caller_speaking = .{
                        .time_ms = core.now(),
                        .caller = cid,
                    },
                },
            });
        }

        _ = &csbuf;
        _ = &csbuf_idx;
        //     const err, const n = sock.receiveManyTimeout(io, &imbuf, dbuf, .{}, .none);
        //     if (err) |e| return e;

        //     const messages = imbuf[0..n];
        //     for (messages) |m| {
        //         const power, const cid = media.receive(m.data);
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
pub fn runHostMediaSender(
    io: Io,
    sock: Io.net.Socket,
    server: *const Io.net.IpAddress,
) !void {
    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    while (true) {
        try media.capture_buffer.mutex.lock(io);
        try media.capture_buffer.condition.wait(io, &media.capture_buffer.mutex);
        const message = blk: {
            defer media.capture_buffer.mutex.unlock(io);
            var buf: [1280]u8 = undefined;
            const message = media.send(&buf) catch |err| switch (err) {
                error.NotReady => {
                    log.debug("capture buffer not ready to send", .{});
                    continue;
                },
            };

            break :blk message;
        };

        try sock.send(io, server, message);
    }
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
