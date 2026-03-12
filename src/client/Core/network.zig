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

pub const debug = if (builtin.mode != .Debug) void else struct {
    pub var send_bad_capture_packet: std.atomic.Value(bool) = .init(false);
    pub var drop_next_media_packets: std.atomic.Value(usize) = .init(0);
    var remaining_packets_to_drop: usize = 0;
    var dred_decoder: *awebo.opus.DredDecoder = undefined;
    var dred_state: *awebo.opus.DredState = undefined;
};

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
                        .host_update = .{ .disconnected = core.now() + (2 * std.time.ns_per_s) },
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

        awebo.network_utils.setTcpNoDelay(hc.tcp.stream.socket);

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

    const Select = Io.Select(union(enum) {
        receive: @typeInfo(@TypeOf(runHostReceive)).@"fn".return_type.?,
        send: @typeInfo(@TypeOf(runHostSend)).@"fn".return_type.?,
    });
    var buf: [2]Select.Union = undefined;
    var select: Select = .init(io, &buf);
    defer select.cancelDiscard();

    try select.concurrent(.receive, runHostReceive, .{ core, hc, host_id });
    try select.concurrent(.send, runHostSend, .{ core, hc });

    log.debug("notifying core we connected successfully", .{});
    try core.putEvent(.{ .network = .{ .host_id = host_id, .cmd = .{ .host_update = .{ .connected = hc } } } });

    _ = try select.await();

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

const udp_video_framing = @sizeOf(awebo.protocol.media.Header) + @sizeOf(awebo.protocol.media.Video);

// There should be only one of these tasks active at a time
pub fn runHostMediaManager(
    core: *Core,
    host_id: HostId,
    hc: *HostConnection,
    client_id: awebo.protocol.client.Id,
    nonce: u64,
) void {
    const io = core.io;

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exited", .{@src().fn_name});

    const server = Io.net.IpAddress.parse(hc.identity, 1992) catch unreachable;
    const addr = Io.net.IpAddress.parse("0.0.0.0", 0) catch unreachable;
    const sock: Io.net.Socket = addr.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch |err| {
        std.process.fatal("unable to bing socket: {t}", .{err});
    };
    defer sock.close(io);

    // set dscp to bump up priority of our packets.
    awebo.network_utils.setUdpDscp(sock);

    const Select = Io.Select(union(enum) {
        receive: @typeInfo(@TypeOf(runHostMediaReceiver)).@"fn".return_type.?,
        send: @typeInfo(@TypeOf(runHostMediaSender)).@"fn".return_type.?,
    });
    var sbuf: [2]Select.Union = undefined;
    var select: Select = .init(io, &sbuf);
    defer select.cancelDiscard();

    select.concurrent(.receive, runHostMediaReceiver, .{ core, sock, &server, host_id }) catch return;
    select.concurrent(.send, runHostMediaSender, .{ core, sock, &server, host_id }) catch return;

    const bytes = awebo.protocol.media.OpenPath.serialize(client_id, nonce);
    sock.send(io, &server, &bytes) catch return;
    _ = select.await() catch return;
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
    const dbuf = gpa.alloc(u8, imbuf.len * 1280) catch oom();
    defer gpa.free(dbuf);

    while (true) {
        const m = try sock.receive(io, dbuf);
        if (!m.from.eql(server)) continue;

        const header, const body = awebo.protocol.media.Header.parse(m.data) orelse continue;
        const cid = header.stream_id.client_id;
        {
            var locked = Core.lockState(core);
            defer locked.unlock();

            const active_call = &(core.active_call orelse {
                log.debug("media receiver no active call, ignoring", .{});
                continue;
            });

            const caller = active_call.callers.getPtr(cid) orelse {
                log.debug("media receiver can't find caller {f}, ignoring", .{cid});
                continue;
            };

            if (debug != void) {
                const update = debug.drop_next_media_packets.swap(0, .acq_rel);

                if (update > 0) {
                    debug.remaining_packets_to_drop = update;
                }

                if (debug.remaining_packets_to_drop > 0) {
                    debug.remaining_packets_to_drop -= 1;
                    log.debug("<<DROPPING MEDIA PACKET {}>>", .{debug.remaining_packets_to_drop});
                    continue;
                }
            }
            switch (header.stream_id.kind) {
                .voice => {
                    const voice, const data = awebo.protocol.media.Voice.parse(body) orelse continue;
                    caller.audio.packets.writePacket(io, voice.restart, header.sequence, data);

                    if (awebo.opus.packetHasLbrr(data) catch false) {
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
                },
                .screen => {
                    if (caller.screen) |screen| {
                        screen.pushChunk(header.sequence, body);
                    } else {
                        caller.screen = try .create(core, header.sequence, body);
                    }
                },
                else => @panic("TODO: implement support for other streams!"),
            }
        }
    }
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

    awebo.network_utils.setCurrentThreadRealtime(20);

    if (debug != void) {
        debug.dred_decoder = try .create();
        debug.dred_state = try .create();
    }

    var sequence: u32 = 0;
    var restart: u32 = 1;
    var was_muted = true;
    while (true) {
        const last = Io.Clock.awake.now(io);
        var nothing_found = true;

        while (core.audio.capture_packets.beginRead()) |read| {
            nothing_found = false;
            if (debug != void) {
                if (debug.send_bad_capture_packet.swap(false, .acq_rel)) {
                    const new_seq: u32 = 1 << 31;
                    log.debug("<<SETTING CAPTURE PACKET SEQ TO {}>>", .{new_seq});
                    sequence = new_seq;
                }

                // if (debug.dred_decoder.parse(debug.dred_state, read.data, .deferred)) |info| {
                //     log.debug("outbound dred = {any}", .{info});
                // } else |err| {
                //     log.debug("outbound dred err = {t}", .{err});
                // }
            }

            if (read.packet.len < 3) {
                if (!was_muted) {
                    sequence = 0;
                    restart += 1;
                    was_muted = true;
                }
                core.audio.capture_packets.commitRead(read);
                continue;
            }

            sequence += 1;
            was_muted = false;

            var buf: [1280]u8 = undefined;
            const packet = awebo.protocol.media.Voice.serialize(
                &buf,
                .voice,
                sequence,
                restart,
                read.packet.data[0..read.packet.len],
            ) catch unreachable;

            core.audio.capture_packets.commitRead(read);
            try sock.send(io, server, packet);
            if (!read.packet.silence) try core.putEvent(.{ .network = .{
                .host_id = host_id,
                .cmd = .{
                    .caller_speaking = .{
                        .time_ns = core.now(),
                        .caller = null,
                    },
                },
            } });
        }

        while (core.screen_capture.packets.beginRead()) |read| {
            nothing_found = false;
            var batch: [64]Io.net.OutgoingMessage = undefined;
            var batch_idx: usize = 0;

            for (0..read.packet.full_chunks) |chunk_id| {
                batch[batch_idx] = .{
                    .address = server,
                    .data_ptr = read.packet.data.items[chunk_id * 1280 ..].ptr,
                    .data_len = 1280,
                };
                batch_idx += 1;

                if (batch_idx == batch.len) {
                    sock.sendMany(io, &batch, .{}) catch |err| {
                        log.debug("sendmany error: {t}", .{err});
                        return;
                    };
                    batch_idx = 0;
                }
            }

            assert(batch_idx < batch.len); // guaranteed we have space for one more message

            if (read.packet.last_chunk_data > 0) {
                batch[batch_idx] = .{
                    .address = server,
                    .data_ptr = read.packet.data.items[read.packet.data.items.len..].ptr - (read.packet.last_chunk_data + udp_video_framing),
                    .data_len = read.packet.last_chunk_data + udp_video_framing,
                };
                batch_idx += 1;
            }

            if (batch_idx > 0) {
                sock.sendMany(io, batch[0..batch_idx], .{}) catch |err| {
                    log.debug("sendmany error: {t}", .{err});
                    return;
                };
            }

            core.screen_capture.packets.commitRead(read);
        }

        // nothing to read, sleep
        if (nothing_found) {
            try io.sleep(.fromMilliseconds(2), .awake);
        } else {
            const timeout: Io.Timeout = .{
                .deadline = last.addDuration(.fromMilliseconds(8)).withClock(.awake),
            };
            try timeout.sleep(io);
        }
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
