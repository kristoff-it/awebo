const builtin = @import("builtin");
const options = @import("options");
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Settings = @import("../../Settings.zig");
const RateLimiter = @import("../../RateLimiter.zig");
const awebo = @import("../../../awebo.zig");
const Database = awebo.Database;
const Query = Database.Query;
const Host = awebo.Host;
const Header = awebo.protocol.media.Header;
const OpenStream = awebo.protocol.media.OpenStream;
const cli = @import("../../../cli.zig");

const server_log = std.log.scoped(.server);

const HANDLER_ROUTINE = *const fn (dwCtrlType: std.os.windows.DWORD) callconv(.winapi) std.os.windows.BOOL;

extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?HANDLER_ROUTINE,
    Add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

var shutdown_event_io: Io = undefined;
var shutdown_event: Io.Event = .unset;
pub fn run(io: Io, gpa: Allocator, it: *std.process.Args.Iterator) void {
    const cmd: Command = .parse(it);

    server_log.info("starting awebo server", .{});
    defer server_log.info("goodbye", .{});

    // Setup graceful shutdown signal handler
    shutdown_event_io = io;
    switch (builtin.target.os.tag) {
        .linux, .macos => {
            const posix = std.posix;
            const act: posix.Sigaction = .{
                .handler = .{
                    .handler = struct {
                        fn handler(_: posix.SIG) callconv(.c) void {
                            server_log.info("received SIGINT", .{});
                            shutdown_event.set(shutdown_event_io);
                        }
                    }.handler,
                },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(.INT, &act, null);
        },
        .windows => {
            const win = std.os.windows;
            const Impl = struct {
                fn handler(crtl_type: win.DWORD) callconv(.winapi) win.BOOL {
                    const CTRL_C_EVENT: std.os.windows.DWORD = 0;
                    switch (crtl_type) {
                        CTRL_C_EVENT => {
                            shutdown_event.set(shutdown_event_io);
                            return win.TRUE;
                        },
                        else => return win.FALSE,
                    }
                }
            };

            if (SetConsoleCtrlHandler(&Impl.handler, std.os.windows.TRUE) == 0) {
                server_log.err("unable to setup ctrl+c handler, continuing anyway", .{});
            }
        },
        else => server_log.err(
            "ctrl+c handler for this platform was not implemented, " ++
                "consider adding support for it. continuing anyway.",
            .{},
        ),
    }

    if (options.slow) server_log.warn("slow mode enabled", .{});

    server_log.info("loading database", .{});
    db = .init(cmd.db_path, .read_write);
    defer if (builtin.mode == .Debug) db.close();
    qs = db.initQueries(Queries);
    cqs = db.initQueries(Database.CommonQueries);
    defer if (builtin.mode == .Debug) {
        db.deinitQueries(Queries, &qs);
        db.deinitQueries(Database.CommonQueries, &cqs);
    };
    ___state.init(io, gpa) catch |err| {
        cli.fatal("unable to load state from database: {t}", .{err});
    };
    defer ___state.deinit(gpa);

    server_log.info("server epoch: {d}, last id generated: {}", .{
        ___state.settings.epoch,
        ___state.id.last,
    });

    server_log.info("starting tcp interface at {f}", .{cmd.tcp});
    var tcp = cmd.tcp.listen(io, .{ .reuse_address = true }) catch |err| {
        cli.fatal("unable to listen to '{f}': {t}", .{ cmd.tcp, err });
    };
    defer tcp.deinit(io);

    var tcp_future = io.concurrent(runTcpAccept, .{ io, gpa, tcp }) catch |err| fatalIo(err);
    defer {
        server_log.info("shutting down tcp interface", .{});
        tcp_future.cancel(io) catch {};
    }

    server_log.info("starting udp interface at {f}", .{cmd.udp});
    const udp = cmd.udp.bind(io, .{ .mode = .dgram }) catch |err| {
        cli.fatal("unable to bind '{f}': {t}", .{ cmd.tcp, err });
    };
    defer udp.close(io);

    var udp_future = io.concurrent(runUdpSocket, .{ io, gpa, udp }) catch |err| fatalIo(err);
    defer {
        server_log.info("shutting down udp interface", .{});
        udp_future.cancel(io) catch {};
    }

    server_log.info("server started, send SIGINT (ctrl+c) to shutdown", .{});
    defer server_log.info("begin graceful shutdown", .{});
    shutdown_event.waitUncancelable(io);
}

/// Only canceled on a graceful shutdown by run
fn runTcpAccept(io: Io, gpa: Allocator, tcp: Io.net.Server) !void {
    var g: Io.Group = .init;
    defer g.cancel(io);

    var rl_map: std.AutoArrayHashMapUnmanaged(Io.net.IpAddress, RateLimiter) = .empty;
    defer rl_map.deinit(gpa);

    var tcp_copy = tcp;
    while (true) {
        const stream = try tcp_copy.accept(io);
        server_log.debug("new connnection from {f}", .{stream.socket.address});

        const gop = try rl_map.getOrPut(gpa, stream.socket.address);
        if (!gop.found_existing) gop.value_ptr.* = .init(io, .connect);

        gop.value_ptr.takeToken(io, .connect) catch {
            server_log.err("[fail2ban] {f} reconnection attempt exceeded rate limit", .{stream.socket.address});
            continue;
        };

        g.concurrent(io, runClientManager, .{ io, gpa, stream }) catch {
            stream.close(io);
        };
    }
}

/// Spawns runClientReceive and runClientSend for a TCP connection.
/// Failure in either child coroutine will trigger cancelation of all,
/// ending with the TCP connection getting closed.
fn runClientManager(io: Io, gpa: Allocator, stream: Io.net.Stream) void {
    server_log.debug("{s} starting", .{@src().fn_name});
    defer {
        server_log.debug("{s} exiting", .{@src().fn_name});
        stream.close(io);
    }

    var rbuf: [4096]u8 = undefined;
    var wbuf: [4096]u8 = undefined;
    var qbuf: [64]*TcpMessage = undefined;
    var client: Client = .{
        .tcp = .{
            .connected_at = tcpId(io),
            .stream = stream,
            .reader_state = stream.reader(io, &rbuf),
            .writer_state = stream.writer(io, &wbuf),
            .queue = .init(&qbuf),
        },
    };
    defer {
        const locked = lockState(io);
        defer locked.unlock(io);
        const state = locked.state;
        client.deinit(io, gpa, state);
    }

    const log = client.scopedLog();
    const reader = &client.tcp.reader_state.interface;

    // Authentication, client won't be able to send any other kind of command
    // until successfully authenticated.
    {
        // TODO: timeout
        const marker = reader.takeByte() catch return;
        if (marker != awebo.protocol.client.Authenticate.marker) {
            // TODO: failing auth should consume rate limiter tokens
            log.debug("unauthenticated client sent us wrong marker: '{c}'", .{marker});
            return;
        }

        client.authenticateRequest(io, gpa, reader) catch |err| {
            // TODO: failing auth should consume rate limiter tokens
            log.err("error processing Authenticate: {t}", .{err});
            return;
        };
    }

    var receive_future = io.concurrent(runClientTcpRead, .{ io, gpa, &client }) catch {
        log.debug("failed to start coroutine", .{});
        return;
    };
    defer receive_future.cancel(io) catch {};

    var send_future = io.concurrent(runClientTcpWrite, .{ io, gpa, &client }) catch {
        log.debug("failed to start coroutine", .{});
        return;
    };
    defer send_future.cancel(io) catch {};

    _ = io.select(.{ &receive_future, &send_future }) catch return;
}

/// Runs in a per-connection coroutine after successful authentication.
fn runClientTcpRead(io: Io, gpa: Allocator, client: *Client) !void {
    const log = client.scopedLog();

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exiting", .{@src().fn_name});

    assert(client.authenticated != null);

    var rl: RateLimiter = .init(io, .tcp_message);

    const reader = &client.tcp.reader_state.interface;
    while (true) {
        const marker = try reader.takeByte();
        log.debug("client request: '{f}'", .{std.zig.fmtChar(marker)});

        rl.takeToken(io, .tcp_message) catch |err| {
            // TODO: getting booted because of too many messages should
            //       consume runTcpAccept rate limiter tokens
            log.debug("connection exceeded rate limit, closing", .{});
            return err;
        };

        const marker_enum = std.enums.fromInt(awebo.protocol.client.Enum, marker) orelse {
            log.debug("unknown request marker, closing", .{});
            return error.BadRequest;
        };

        switch (marker_enum) {
            .Authenticate => {
                // TODO: this should consume runTcpAccept tokens
                log.debug("authenticated client attempted to authenticate again", .{});
                return error.AweboProtocolError;
            },
            .CallJoin => {
                client.callJoinRequest(io, gpa, reader) catch |err| {
                    log.err("error processing CallJoin: {t}", .{err});
                };
            },
            .CallLeave => {
                client.callLeaveRequest(io, gpa, reader) catch |err| {
                    log.err("error processing CallLeave: {t}", .{err});
                };
            },
            .ChatTypingNotify => {
                client.chatTypingNotifyRequest(io, gpa, reader) catch |err| {
                    log.err("error processing ChatMessageTyping: {t}", .{err});
                };
            },
            .ChatMessageSend => {
                client.chatMessageSendRequest(io, gpa, reader) catch |err| {
                    log.err("error processing ChatMessageSend: {t}", .{err});
                };
            },
            .ChatHistoryGet => {
                client.chatHistoryGet(io, gpa, reader) catch |err| {
                    log.err("error processing ChatMessageSend: {t}", .{err});
                };
            },
            .ChannelCreate => {
                client.channelCreate(io, gpa, reader) catch |err| {
                    log.err("error processing ChannelCreate: {t}", .{err});
                };
            },
            .SearchMessages => {
                client.searchMessages(io, gpa, reader) catch |err| {
                    log.err("error processing SearchMessages: {t}", .{err});
                };
            },
            .SignUp => @panic("TODO"),
            .InviteInfo => @panic("TODO"),
        }
    }
}

fn runClientTcpWrite(io: Io, gpa: Allocator, client: *Client) !void {
    const log = client.scopedLog();

    log.debug("{s} started", .{@src().fn_name});
    defer log.debug("{s} exiting", .{@src().fn_name});

    assert(client.authenticated != null);

    const writer = &client.tcp.writer_state.interface;
    while (true) {
        var msgbuf: [64]*TcpMessage = undefined;
        const messages = msgbuf[0..try client.tcp.queue.get(io, &msgbuf, 1)];
        log.debug("tcp write got {} messages to send", .{messages.len});
        if (options.slow) {
            for (messages) |m| {
                try io.sleep(.fromSeconds(1), .real);
                try writer.writeAll(m.bytes);
                try writer.flush();
            }
        } else {
            // TODO: remove this step if we ever get Io.MultiQueue
            var outbuf: [64][]const u8 = undefined;
            for (messages, outbuf[0..messages.len]) |m, *b| {
                b.* = m.bytes;
            }
            try writer.writeVecAll(outbuf[0..messages.len]);
            try writer.flush();
        }
        for (messages) |msg| msg.destroy(gpa);
    }
}

fn runUdpSocket(io: Io, gpa: Allocator, udp: Io.net.Socket) !void {
    server_log.debug("{s} started", .{@src().fn_name});
    defer server_log.debug("{s} exiting", .{@src().fn_name});

    var dbuf: [1280]u8 = undefined;

    while (true) {
        if (@hasDecl(Io.net.Socket, "receiveMany")) {
            @compileLog("please upgrade me");
        }

        const packet = udp.receive(io, &dbuf) catch |err| {
            switch (err) {
                error.Canceled => {},
                else => server_log.debug("udp socket error: '{t}'", .{err}),
            }
            return;
        };

        if (packet.flags.trunc or packet.flags.errqueue) {
            server_log.debug("dropping bad udp packet: {any}", .{packet.flags});
            continue;
        }

        var header, const body = Header.parse(packet.data) orelse {
            server_log.debug("not enough bytes to parse Header, ignoring", .{});
            continue;
        };

        var locked = lockState(io);
        defer locked.unlock(io);
        const state = locked.state;

        switch (header.kind()) {
            .open_stream => {
                const os = OpenStream.parse(body) orelse {
                    server_log.debug("not enough bytes to parse OpenStream, ignoring", .{});
                    continue;
                };

                server_log.debug("new udp client: {f} {any}", .{ packet.from, os });

                const client = state.clients.tcp_index.get(@intCast(os.tcp_client)) orelse {
                    server_log.debug("could not find matching TCP connection, ignoring", .{});
                    continue;
                };

                const v = client.voice orelse {
                    server_log.debug("TCP client did not request a UDP session, ignoring", .{});
                    continue;
                };

                if (v.nonce != os.nonce) {
                    server_log.debug("bad nonce, ignoring", .{});
                    continue;
                }

                if (client.udp != null) {
                    _ = state.removeUdp(io, gpa, client);
                }

                state.setUdp(gpa, client, packet.from);

                {
                    server_log.debug("CU JOIN = {}", .{client.udp.?.id});
                    const cu: awebo.protocol.server.CallersUpdate = .{
                        .caller = .{
                            .id = @intCast(client.udp.?.id),
                            .voice = client.voice.?.id,
                            .user = client.authenticated.?,
                        },
                        .action = .join,
                    };

                    const msg = cu.serializeAlloc(gpa) catch unreachable;
                    errdefer gpa.free(msg);

                    state.tcpBroadcast(io, gpa, msg);
                }
            },

            .media => {
                const sender = state.clients.udp_index.get(packet.from) orelse {
                    server_log.debug("received media udp packet from unknown source: {f}", .{packet.from});
                    continue;
                };

                sender.udp.?.last_msg_ms = state.id.new();
                header.id.client_id = sender.udp.?.id;

                const room = state.clients.voice_index.get(sender.voice.?.id).?;
                const receivers = room.keys();
                var batch: [64]Io.net.OutgoingMessage = undefined;
                var batch_idx: usize = 0;
                for (receivers, 0..) |client, idx| {
                    if (client.udp) |*receiver_udp| {
                        if (!options.echo) {
                            if (receiver_udp.id == sender.udp.?.id) continue;
                        }

                        if (options.echo or receiver_udp.id != sender.udp.?.id) {
                            // batch[batch_idx] = .{
                            //     .address = &receiver_udp.addr,
                            //     .data_ptr = packet.data.ptr,
                            //     .data_len = packet.data.len,
                            // };

                            // batch_idx += 1;

                            udp.send(io, &client.udp.?.addr, packet.data) catch unreachable;
                            _ = &batch;
                            _ = &batch_idx;
                            _ = idx;
                        } else {
                            server_log.debug("same user, skipping", .{});
                        }
                    } else {
                        server_log.debug("client {} has no udp yet, skipping", .{client.authenticated.?});
                    }

                    // if (batch_idx == batch.len or idx == receivers.len - 1) {
                    //     udp.sendMany(io, batch[0..batch_idx], .{}) catch |err| {
                    //         server_log.err("sendMany encountered error {t} while sending {} packets", .{
                    //             err, batch_idx,
                    //         });
                    //         continue;
                    //     };
                    //     batch_idx = 0;
                    // }
                }
            },
        }
    }
}

const TcpMessage = struct {
    refs: std.atomic.Value(usize),
    bytes: []const u8,

    pub fn create(gpa: Allocator, bytes: []const u8, initial: usize) *TcpMessage {
        const t = gpa.create(TcpMessage) catch oom();
        t.* = .{ .bytes = bytes, .refs = .init(initial) };
        return t;
    }

    // pub fn increment(t: *TcpMessage) void {
    //     assert(0 != t.refs.fetchAdd(1, .acq_rel));
    // }

    pub fn destroy(t: *TcpMessage, gpa: Allocator) void {
        if (0 == t.refs.fetchSub(1, .acq_rel)) {
            gpa.free(t.bytes);
            t.* = undefined;
            gpa.destroy(t);
        }
    }
};

const Client = struct {
    tcp: struct {
        connected_at: i96,
        stream: Io.net.Stream,
        reader_state: Io.net.Stream.Reader = undefined,
        writer_state: Io.net.Stream.Writer = undefined,
        /// Queue of messages to be sent to the client
        queue: Io.Queue(*TcpMessage),
    },

    authenticated: ?awebo.User.Id = null,
    voice: ?struct {
        id: awebo.Channel.Id,
        nonce: u64,
    } = null,

    udp: ?struct {
        id: u15,
        addr: Io.net.IpAddress,
        last_msg_ms: u64,
    } = null,

    next: ?*Client = null,
    prev: ?*Client = null,

    pub const Id = u64;

    /// Clean up all references to this client and deinit it
    fn deinit(client: *Client, io: Io, gpa: Allocator, state: *State) void {
        // remove from tcp linked list
        {
            if (client.next) |next| {
                next.prev = client.prev;
            }

            if (client.prev) |prev| {
                prev.next = client.next;
            } else state.clients.head = client.next;
        }

        // remove from tcp index
        _ = state.clients.tcp_index.remove(client.tcp.connected_at);

        // remove from callers
        _ = state.removeFromCall(io, gpa, client);

        // free unsent messages
        // for (0..client.tcp.queue.capacity()) |_| {
        //     // TODO: queue should exprose its front and back slices
        //     gpa.free(client.tcp.queue.getOneUncancelable(io));
        // }
    }

    fn authenticateRequest(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const log = client.scopedLog();

        const locked = lockState(io);
        defer locked.unlock(io);
        const state = locked.state;

        const cmd = try awebo.protocol.client.Authenticate.deserializeAlloc(gpa, reader);
        defer cmd.deinit(gpa);

        const user = getUserByLogin(io, gpa, cmd.method.login.username, cmd.method.login.password) catch |err| switch (err) {
            error.NotFound, error.Password => {
                log.debug("failed auth attempt for user '{s}': {t}", .{ cmd.method.login.username, err });
                const reply: awebo.protocol.server.AuthenticateReply = .{
                    .protocol_version = 1,
                    .result = .{ .unauthorized = .{ .code = .invalid_credentials } },
                };

                const w = &client.tcp.writer_state.interface;
                try reply.serialize(w);
                try w.flush();
                return error.Authentication;
            },
        };

        log.debug("checking auth permissions for user", .{});
        const can_auth = serverPermission(&user, .authenticate);
        if (!can_auth) {
            log.debug("no auth permission for user '{s}'", .{cmd.method.login.username});
            const reply: awebo.protocol.server.AuthenticateReply = .{
                .protocol_version = 1,
                .result = .{ .unauthorized = .{ .code = .banned_user } },
            };

            const w = &client.tcp.writer_state.interface;
            try reply.serialize(w);
            try w.flush();
            return error.Authentication;
        }

        try state.host.users.set(gpa, user);

        log.debug("client authenticated successfully as '{s}'", .{user.handle});
        client.authenticated = user.id;
        if (state.clients.head) |old_head| {
            client.next = old_head;
            old_head.prev = client;
        }

        state.clients.head = client;
        state.clients.tcp_index.putNoClobber(gpa, client.tcp.connected_at, client) catch @panic("oom");
        errdefer assert(state.clients.tcp_index.remove(client.tcp.connected_at));

        const reply: awebo.protocol.server.AuthenticateReply = .{
            .protocol_version = 1,
            .result = .authorized,
        };
        const auth_bytes = try reply.serializeAlloc(gpa);

        const hs = try state.host.computeDelta(gpa, &state.clients, user.id, cmd.max_uid, state.id.last);
        const bytes = try hs.serializeAlloc(gpa);
        errdefer gpa.free(bytes);

        // This is very wasteful, we could avoid this allocating by sneaking
        // refcounting into the message bytes themselves.
        const auth_msg: *TcpMessage = .create(gpa, auth_bytes, 1);
        const host_sync_msg: *TcpMessage = .create(gpa, bytes, 1);

        // order matters, we first confirm the auth request and second send the host sync data
        try client.tcp.queue.putAll(io, &.{ auth_msg, host_sync_msg });
    }

    fn bufferIndex(deque: *const std.Deque(awebo.Message), index: usize) usize {
        // This function is written in this way to avoid overflow and
        // expensive division.
        const head_len = deque.buffer.len - deque.head;
        if (index < head_len) {
            return deque.head + index;
        } else {
            return index - head_len;
        }
    }

    fn channelCreate(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const cc = try awebo.protocol.client.ChannelCreate.deserializeAlloc(gpa, reader);
        assert(cc.kind == .chat);

        const locked = lockState(io);
        defer locked.unlock(io);
        const state = locked.state;

        if (state.host.channels.name(cc.name) != null) {
            const ccr = cc.reply(.name_taken);
            const bytes = try ccr.serializeAlloc(gpa);
            errdefer gpa.free(bytes);
            const msg: *TcpMessage = .create(gpa, bytes, 1);
            try client.tcp.queue.putOne(io, msg);
            return;
        }

        const uid = state.id.new();
        const channel_id = cqs.insert_channel.runReturning(@src(), db, .id, .{
            .update_uid = uid,
            .sort = 0,
            .name = cc.name,
            .kind = cc.kind,
            .privacy = .private,
        });

        const channel: awebo.Channel = .{
            .id = channel_id,
            .update_uid = uid,
            .name = cc.name,
            .kind = switch (cc.kind) {
                inline else => |tag| @unionInit(
                    awebo.Channel.Kind,
                    @tagName(tag),
                    .{},
                ),
            },
            .privacy = .private,
        };

        try state.host.channels.set(gpa, channel);

        {
            const ccr = cc.reply(.ok);
            const bytes = try ccr.serializeAlloc(gpa);
            errdefer gpa.free(bytes);

            const msg: *TcpMessage = .create(gpa, bytes, 1);
            try client.tcp.queue.putOne(io, msg);
        }

        {
            const cu: awebo.protocol.server.ChannelsUpdate = .{
                .op = .create,
                .channels = &.{channel},
            };

            const bytes = try cu.serializeAlloc(gpa);
            errdefer gpa.free(bytes);
            const msg: *TcpMessage = .create(gpa, bytes, 1);
            try client.tcp.queue.putOne(io, msg);
        }
    }

    fn callJoinRequest(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const log = client.scopedLog();

        const cmd = try awebo.protocol.client.CallJoin.deserialize(reader);
        // TODO: decide if we should noop when old_voice == new voice
        {
            const locked = lockState(io);
            defer locked.unlock(io);
            const state = locked.state;

            {
                const gop = try state.user_limits.getOrPut(gpa, client.authenticated.?);
                if (!gop.found_existing) gop.value_ptr.* = .init(io, .user_action);

                const limiter = gop.value_ptr;

                limiter.takeToken(io, .user_action) catch {
                    log.debug("user {} exceeded user action limit", .{client.authenticated.?});
                    const fail: awebo.protocol.server.ClientRequestReply = .{
                        .origin = cmd.origin,
                        .reply_marker = awebo.protocol.client.CallJoin.marker,
                        .result = .rate_limit,
                    };

                    const bytes = try fail.serializeAlloc(gpa);

                    const msg: *TcpMessage = .create(gpa, bytes, 1);
                    try client.tcp.queue.putOne(io, msg);
                };
            }

            if (client.voice) |old_voice| {
                const gop = try state.clients.voice_index.getOrPutValue(
                    gpa,
                    old_voice.id,
                    .{},
                );

                _ = gop.value_ptr.swapRemove(client);
            }

            client.voice = .{
                .id = cmd.voice,
                .nonce = 12345,
            };

            const gop = try state.clients.voice_index.getOrPutValue(
                gpa,
                cmd.voice,
                .{},
            );
            errdefer assert(state.clients.voice_index.remove(cmd.voice));

            try gop.value_ptr.put(gpa, client, {});
        }

        const mcd: awebo.protocol.server.MediaConnectionDetails = .{
            .voice = cmd.voice,
            .tcp_client = client.tcp.connected_at,
            .nonce = 12345,
        };
        const bytes = try mcd.serializeAlloc(gpa);
        errdefer gpa.free(bytes);

        const msg: *TcpMessage = .create(gpa, bytes, 1);

        try client.tcp.queue.putOne(io, msg);
    }

    fn callLeaveRequest(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const log = client.scopedLog();

        _ = try awebo.protocol.client.CallLeave.deserialize(reader);
        {
            const locked = lockState(io);
            defer locked.unlock(io);
            const state = locked.state;

            // If the action results in the client leaving a channel, it
            // should not be subject to rate limiting, but it MUST be
            // subject to rate limiting if the request results in a noop.
            const was_noop = !state.removeFromCall(io, gpa, client);
            if (was_noop) {
                const gop = try state.user_limits.getOrPut(gpa, client.authenticated.?);
                if (!gop.found_existing) gop.value_ptr.* = .init(io, .user_action);

                const limiter = gop.value_ptr;

                limiter.takeToken(io, .user_action) catch {
                    log.debug("user {} exceeded user action limit", .{client.authenticated.?});
                    const fail: awebo.protocol.server.ClientRequestReply = .{
                        .origin = 0,
                        .reply_marker = awebo.protocol.client.CallJoin.marker,
                        .result = .rate_limit,
                    };

                    const bytes = try fail.serializeAlloc(gpa);

                    const msg: *TcpMessage = .create(gpa, bytes, 1);
                    try client.tcp.queue.putOne(io, msg);
                };
            }
        }
    }

    fn chatTypingNotifyRequest(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const log = client.scopedLog();
        const ctn = try awebo.protocol.client.ChatTypingNotify.deserialize(reader);

        const locked = lockState(io);
        defer locked.unlock(io);
        const state = locked.state;

        const gop = try state.user_limits.getOrPut(gpa, client.authenticated.?);
        if (!gop.found_existing) gop.value_ptr.* = .init(io, .user_action);

        const limiter = gop.value_ptr;

        limiter.takeToken(io, .user_action) catch {
            log.debug("exceeded user action limit", .{});
            return;
        };

        const channel = state.host.channels.get(ctn.channel) orelse {
            log.debug("unknown channel", .{});
            return;
        };

        const ct: awebo.protocol.server.ChatTyping = .{
            .uid = client.authenticated.?,
            .channel = channel.id,
        };

        const bytes = try ct.serializeAlloc(gpa);
        errdefer gpa.free(bytes);

        state.tcpBroadcast(io, gpa, bytes);
    }

    fn chatMessageSendRequest(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const log = client.scopedLog();
        const cms = try awebo.protocol.client.ChatMessageSend.deserializeAlloc(gpa, reader);

        const locked = lockState(io);
        defer locked.unlock(io);
        const state = locked.state;

        const gop = try state.user_limits.getOrPut(gpa, client.authenticated.?);
        if (!gop.found_existing) gop.value_ptr.* = .init(io, .user_action);

        const limiter = gop.value_ptr;

        limiter.takeToken(io, .user_action) catch {
            log.debug("exceeded user action limit", .{});
            const fail: awebo.protocol.server.ClientRequestReply = .{
                .origin = cms.origin,
                .reply_marker = awebo.protocol.client.ChatMessageSend.marker,
                .result = .rate_limit,
            };

            const bytes = try fail.serializeAlloc(gpa);
            const msg: *TcpMessage = .create(gpa, bytes, 1);
            try client.tcp.queue.putOne(io, msg);
            return;
        };

        const channel = state.host.channels.get(cms.channel) orelse {
            log.debug("unknown channel", .{});
            const reply = cms.replyErr(.unknown_channel);
            const bytes = try reply.serializeAlloc(gpa);
            errdefer gpa.free(bytes);

            const msg: *TcpMessage = .create(gpa, bytes, 1);
            try client.tcp.queue.putOne(io, msg);
            return;
        };

        const new: awebo.Message = .{
            .id = state.id.new(),
            .origin = cms.origin,
            .created = .now(io, state.host.epoch),
            .update_uid = null,
            .kind = .chat,
            .author = client.authenticated.?,
            .text = cms.text,
        };

        log.debug("adding new message: {f}", .{new});
        try channel.kind.chat.server.messages.pushNew(gpa, new);
        cqs.insert_message.run(@src(), db, .{
            .uid = new.id,
            .origin = new.origin,
            .created = new.created,
            .update_uid = new.update_uid,
            .channel = channel.id,
            .kind = new.kind,
            .author = new.author,
            .body = new.text,
        });

        {
            const cmn: awebo.protocol.server.ChatMessageNew = .{
                .origin = cms.origin,
                .channel = cms.channel,
                .msg = new,
            };

            const bytes = try cmn.serializeAlloc(gpa);
            errdefer gpa.free(bytes);

            state.tcpBroadcast(io, gpa, bytes);
        }
    }

    fn chatHistoryGet(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const log = client.scopedLog();
        const chg = try awebo.protocol.client.ChatHistoryGet.deserialize(reader);

        const locked = lockState(io);
        defer locked.unlock(io);
        const state = locked.state;

        const gop = try state.user_limits.getOrPut(gpa, client.authenticated.?);
        if (!gop.found_existing) gop.value_ptr.* = .init(io, .user_action);

        const limiter = gop.value_ptr;

        limiter.takeToken(io, .user_action) catch {
            log.debug("exceeded user action limit", .{});
            const fail: awebo.protocol.server.ClientRequestReply = .{
                .origin = chg.origin,
                .reply_marker = awebo.protocol.client.ChatHistoryGet.marker,
                .result = .rate_limit,
            };

            const bytes = try fail.serializeAlloc(gpa);
            const msg: *TcpMessage = .create(gpa, bytes, 1);
            try client.tcp.queue.putOne(io, msg);
            return;
        };

        const channel = state.host.channels.get(chg.chat_channel) orelse {
            log.debug("unknown channel", .{});
            const reply = chg.replyErr(.unknown_channel);
            const bytes = try reply.serializeAlloc(gpa);
            errdefer gpa.free(bytes);
            const msg: *TcpMessage = .create(gpa, bytes, 1);
            try client.tcp.queue.putOne(io, msg);
            return;
        };
        _ = channel;

        switch (chg.direction) {
            .older => try chatHistoryGetInner(io, gpa, chg, client, qs.select_chat_history.run(@src(), db, .{
                .channel = chg.chat_channel,
                .below_uid = chg.from_uid,
                .limit = awebo.Channel.window_size,
            })),
            .newer => try chatHistoryGetInner(io, gpa, chg, client, qs.select_chat_present.run(@src(), db, .{
                .channel = chg.chat_channel,
                .above_uid = chg.from_uid,
                .limit = awebo.Channel.window_size,
            })),
        }
    }

    fn chatHistoryGetInner(
        io: Io,
        gpa: Allocator,
        chg: awebo.protocol.client.ChatHistoryGet,
        client: *Client,
        outer_rs: anytype,
    ) !void {
        var rs = outer_rs;
        var messages: std.ArrayList(awebo.Message) = .empty;
        defer {
            for (messages.items) |m| gpa.free(m.text);
            messages.deinit(gpa);
        }

        while (rs.next()) |r| {
            try messages.append(gpa, .{
                .id = r.get(.uid),
                .origin = r.get(.origin),
                .created = r.get(.created),
                .update_uid = r.get(.update_uid),
                .kind = r.get(.kind),
                .author = r.get(.author),
                // TODO: we need protocol metaprogramming to skip this copy
                .text = try r.text(gpa, .body),
            });
        }

        const ch: awebo.protocol.server.ChatHistory = .{
            .channel = chg.chat_channel,
            .origin = chg.origin,
            .history = messages.items,
        };

        const bytes = try ch.serializeAlloc(gpa);
        errdefer gpa.free(bytes);

        const msg: *TcpMessage = .create(gpa, bytes, 1);
        try client.tcp.queue.putOne(io, msg);
    }

    fn searchMessages(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const sm: awebo.protocol.client.SearchMessages = try .deserializeAlloc(gpa, reader);
        defer sm.deinit(gpa);

        const locked = lockState(io);
        defer locked.unlock(io);

        var results: std.ArrayList(awebo.protocol.server.SearchMessagesReply.Result) = .empty;
        defer results.deinit(gpa);

        var rows = qs.search_messages.run(@src(), db, .{
            .query = sm.query,
        });
        while (rows.next()) |row| {
            const result = try results.addOne(gpa);
            result.* = .{
                .channel = row.get(.channel),
                .preview = .{
                    .id = row.get(.message_id),
                    .origin = row.get(.message_origin),
                    .created = row.get(.message_created),
                    .update_uid = row.get(.message_update_uid),
                    .kind = .chat,
                    .author = row.get(.message_author),
                    .text = try row.text(gpa, .message_hl_text),
                },
            };
        }

        const reply = sm.reply(results.items);
        const reply_bytes = try reply.serializeAlloc(gpa);
        errdefer gpa.free(reply_bytes);

        const msg: *TcpMessage = .create(gpa, reply_bytes, 1);
        try client.tcp.queue.putOne(io, msg);
    }

    /// Logger for user-specific operations.
    /// Prefixes each line with the IP address and user id of the current client.
    pub fn scopedLog(client: *const Client) ClientLog {
        return .{ .client = client };
    }

    pub const ClientLog = struct {
        client: *const Client,
        const fmt_prefix = "{f} ({?d}) ";
        pub fn debug(l: ClientLog, comptime fmt: []const u8, args: anytype) void {
            server_log.debug(fmt_prefix ++ fmt, .{ l.client.tcp.stream.socket.address, l.client.authenticated } ++ args);
        }
        pub fn info(l: ClientLog, comptime fmt: []const u8, args: anytype) void {
            server_log.info(fmt_prefix ++ fmt, .{ l.client.tcp.stream.socket.address, l.client.authenticated } ++ args);
        }
        pub fn err(l: ClientLog, comptime fmt: []const u8, args: anytype) void {
            server_log.err(fmt_prefix ++ fmt, .{ l.client.tcp.stream.socket.address, l.client.authenticated } ++ args);
        }
    };
};

pub fn lockState(io: Io) Locked {
    mutex.lockUncancelable(io);
    return .{ .state = &___state };
}

var mutex: Io.Mutex = .init;
pub const Locked = struct {
    state: *State,

    pub fn unlock(l: Locked, io: Io) void {
        _ = l;
        mutex.unlock(io);
    }
};

var db: Database = undefined;
var qs: Queries = undefined;
var cqs: Database.CommonQueries = undefined;

pub const State = @TypeOf(___state);
var ___state: struct {
    // clock: awebo.Clock = undefined,
    id: awebo.IdGenerator = undefined,
    settings: Settings = undefined,
    host: Host = .{},
    /// Per-user rate limiters, use User.Id to index into the array
    user_limits: std.AutoHashMapUnmanaged(awebo.User.Id, RateLimiter) = .empty,
    clients: struct {
        head: ?*Client = null,

        /// We use connection time of a TCP socket as a unique identifier
        tcp_index: std.AutoHashMapUnmanaged(i96, *Client) = .{},

        /// Clients gain a udp address when they connect to a call.
        udp_index: std.AutoHashMapUnmanaged(Io.net.IpAddress, *Client) = .{},

        /// Clients that express an intent to be in a voice call.
        /// Not all clients listed here have a UDP address yet.
        voice_index: std.AutoHashMapUnmanaged(
            awebo.Channel.Id,
            std.AutoArrayHashMapUnmanaged(*Client, void),
        ) = .{},

        fn deinit(self: *@This(), gpa: Allocator) void {
            assert(self.head == null);

            assert(self.tcp_index.count() == 0);
            self.tcp_index.deinit(gpa);

            assert(self.udp_index.count() == 0);
            self.udp_index.deinit(gpa);

            assert(self.voice_index.count() == 0);
            self.voice_index.deinit(gpa);
        }
    } = .{},

    var client_id: u15 = 0;

    fn init(state: *State, io: Io, gpa: Allocator) !void {
        _ = io;
        const latest_uid = cqs.select_max_uid.run(@src(), db, .{}).?.get(.max_uid);
        const settings = blk: {
            var settings: Settings = undefined;

            var rows = cqs.select_host_info.run(@src(), db, .{});

            outer: while (rows.next()) |r| {
                const key = r.textNoDupe(.key);
                inline for (std.meta.fields(Settings)) |f| {
                    if (std.mem.eql(u8, f.name, key)) {
                        @field(settings, f.name) = switch (f.type) {
                            []const u8 => try r.text(gpa, .value),
                            else => r.getAs(f.type, .value),
                        };
                        continue :outer;
                    }
                }
            }

            break :blk settings;
        };

        const host: awebo.Host = host: {
            const users = blk: {
                var rs = cqs.select_users.run(@src(), db, .{});
                var users: awebo.Host.Users = .{};

                while (rs.next()) |r| {
                    try users.set(gpa, .{
                        .id = r.get(.id),
                        .created = r.get(.created),
                        .update_uid = r.get(.update_uid),
                        .handle = try r.text(gpa, .handle),
                        .display_name = try r.text(gpa, .display_name),
                        .invited_by = r.get(.invited_by),
                        .power = r.get(.power),
                        .avatar = "",
                    });
                }
                break :blk users;
            };

            const channels = blk: {
                var rs = cqs.select_channels.run(@src(), db, .{});

                var channels: awebo.Host.Channels = .{};
                while (rs.next()) |r| {
                    const kind = r.get(.kind);
                    var channel: awebo.Channel = .{
                        .id = r.get(.id),
                        .name = try r.text(gpa, .name),
                        .update_uid = r.get(.update_uid),
                        .privacy = r.get(.privacy),
                        .kind = switch (kind) {
                            inline else => |tag| @unionInit(
                                awebo.Channel.Kind,
                                @tagName(tag),
                                .{},
                            ),
                        },
                    };

                    if (channel.kind == .chat) {
                        var msgs = cqs.select_channel_messages.run(@src(), db, .{
                            .channel = channel.id,
                            .limit = awebo.Channel.window_size,
                        });

                        while (msgs.next()) |m| {
                            const m_kind = m.get(.kind);
                            assert(m_kind != .missing_messages_older and m_kind != .missing_messages_newer);
                            const msg: awebo.Message = .{
                                .id = m.get(.uid),
                                .origin = m.get(.origin),
                                .created = m.get(.created),
                                .update_uid = m.get(.update_uid),
                                .kind = m_kind,
                                .author = m.get(.author),
                                .text = try m.text(gpa, .body),
                            };
                            try channel.kind.chat.server.messages.backfill(gpa, msg);
                            server_log.debug("loaded chat message: {f}", .{msg});
                        }
                    }

                    try channels.set(gpa, channel);
                    server_log.debug("loaded {f}", .{channel});
                }

                break :blk channels;
            };

            break :host .{
                .name = settings.name,
                .channels = channels,
                .users = users,
                .epoch = settings.epoch,
            };
        };

        state.* = .{
            .id = .init(latest_uid),
            .settings = settings,
            .host = host,
        };
    }

    fn deinit(state: *State, gpa: Allocator) void {
        if (builtin.mode != .Debug) return;

        state.host.deinit(gpa);
        state.clients.deinit(gpa);
        state.user_limits.deinit(gpa);
    }

    fn setUdp(state: *State, gpa: Allocator, client: *Client, addr: Io.net.IpAddress) void {
        std.debug.assert(client.udp == null);

        client_id += 1;
        client.udp = .{
            .id = client_id,
            .addr = addr,
            .last_msg_ms = state.id.new(),
        };

        server_log.debug("setting {f}", .{addr});

        state.clients.udp_index.put(gpa, addr, client) catch unreachable;
    }

    /// Returns whether the user was in a call or not
    fn removeFromCall(state: *State, io: Io, gpa: Allocator, client: *Client) bool {
        const vid = if (client.voice) |v| v.id else return false;
        assert(state.removeUdp(io, gpa, client));
        client.voice = null;

        const room = state.clients.voice_index.getPtr(vid).?;
        if (room.count() == 1) {
            std.debug.assert(room.keys()[0] == client);
            var kv = state.clients.voice_index.fetchRemove(vid).?;
            kv.value.deinit(gpa);
        } else {
            _ = room.swapRemove(client);
        }

        return true;
    }

    fn removeUdp(state: *State, io: Io, gpa: Allocator, client: *Client) bool {
        const udp = client.udp orelse return false;
        const vid = client.voice.?.id;
        server_log.debug("CU LEAVE = {}", .{udp.id});
        const cu: awebo.protocol.server.CallersUpdate = .{
            .caller = .{
                .id = @intCast(udp.id),
                .voice = vid,
                .user = client.authenticated.?,
            },
            .action = .leave,
        };

        const bytes = cu.serializeAlloc(gpa) catch @panic("oom");
        state.tcpBroadcast(io, gpa, bytes);

        _ = state.clients.udp_index.remove(client.udp.?.addr);
        client.udp = null;
        return true;
    }

    fn tcpBroadcast(state: *State, io: Io, gpa: Allocator, bytes: []const u8) void {
        const count = state.clients.tcp_index.count();
        if (count == 0) {
            gpa.free(bytes);
            return;
        }

        const msg: *TcpMessage = .create(gpa, bytes, count);

        var i: usize = 0;
        var maybe_cur: ?*Client = state.clients.head;
        while (maybe_cur) |cur| : (maybe_cur = cur.next) {
            // TODO: this needs to be a tryPut + client disconnection if the queue is full
            cur.tcp.queue.putOne(io, msg) catch @panic("TODO");
            i += 1;
        }

        assert(i == count);
    }
} = .{};

// const zqlite = @import("zqlite");
// const Event = enum(c_int) {
//     insert = zqlite.c.SQLITE_INSERT,
//     update = zqlite.c.SQLITE_UPDATE,
//     delete = zqlite.c.SQLITE_DELETE,
// };
// pub export fn onDbChange(
//     userdata: ?*anyopaque,
//     event_raw: c_int,
//     database: ?[*:0]const u8,
//     table: ?[*:0]const u8,
//     rowid: c_longlong,
// ) void {
//     _ = userdata;
//     const event: Event = @enumFromInt(event_raw);
//     log.debug("DB(event: {t} database: '{?s}' table: '{?s}' rowid: {})", .{ event, database, table, rowid });
// }

const Command = struct {
    tcp: Io.net.IpAddress,
    udp: Io.net.IpAddress,
    db_path: [:0]const u8,

    fn parse(it: *std.process.Args.Iterator) Command {
        var tcp: ?Io.net.IpAddress = null;
        var udp: ?Io.net.IpAddress = null;
        var db_path: ?[:0]const u8 = null;

        var args: cli.Args = .init(it);

        while (args.peek()) |current_arg| {
            if (args.help()) exitHelp(0);
            if (args.option("tcp")) |tcp_opt| {
                tcp = Io.net.IpAddress.parseLiteral(tcp_opt) catch |err| {
                    cli.fatal(
                        "unable to parse '{s}' as an ip address: {t}",
                        .{ tcp_opt, err },
                    );
                };
            } else if (args.option("udp")) |udp_opt| {
                udp = Io.net.IpAddress.parseLiteral(udp_opt) catch |err| {
                    cli.fatal(
                        "unable to parse '{s}' as an ip address with port: {t}",
                        .{ udp_opt, err },
                    );
                };
            } else if (args.option("db-path")) |db_path_opt| {
                db_path = db_path_opt;
            } else {
                cli.fatal("unknown argument: '{s}'", .{current_arg});
            }
        }

        const default_tcp_addr = comptime Io.net.IpAddress.parse("::", 1991) catch unreachable;
        const default_udp_addr = comptime Io.net.IpAddress.parse("::", 1992) catch unreachable;
        return .{
            .tcp = tcp orelse default_tcp_addr,
            .udp = udp orelse default_udp_addr,
            .db_path = db_path orelse "awebo.db",
        };
    }
};

fn oom() noreturn {
    cli.fatal("oom", .{});
}

fn fatalIo(err: anyerror) noreturn {
    cli.fatal("unable to perform I/O operation: {t}", .{err});
}

fn exitHelp(status: u8) noreturn {
    std.debug.print(
        \\Usage: awebo-server server run [OPTIONAL_ARGS]
        \\
        \\Start the Awebo server.
        \\
        \\Optional arguments:
        \\  --db-path DB_PATH    Path to the SQLite database to be used.
        \\                       Defaults to 'awebo.db'.
        \\  --tcp IP:PORT        Address and port for TCP communication.
        \\                       Defaults to '[::]:1991'.
        \\  --udp IP:PORT        Address and port for UDP communication.
        \\                       Defaults to '[::]:1992'.
        \\  --help, -h           Show this menu and exit.
        \\
        \\
    , .{});

    std.process.exit(status);
}

/// Returns a user given its username and password.
/// Validation logic is part of this function to make efficient use of the memory returned from sqlite,
/// which becomes invalid as soon as the relative `Row` is deinited.
/// On success dupes `username`.
fn getUserByLogin(
    io: Io,
    gpa: Allocator,
    username: []const u8,
    password: []const u8,
) error{ NotFound, Password }!awebo.User {
    const maybe_pswd_row = qs.select_password.run(@src(), db, .{ .handle = username });
    const pswd_row = maybe_pswd_row orelse {
        std.crypto.pwhash.argon2.strVerify("bananarama123", password, .{ .allocator = gpa }, io) catch {};
        return error.NotFound;
    };

    const pswd_hash = pswd_row.textNoDupe(.hash);

    std.crypto.pwhash.argon2.strVerify(pswd_hash, password, .{ .allocator = gpa }, io) catch |err| switch (err) {
        error.PasswordVerificationFailed => return error.Password,
        error.OutOfMemory => oom(),
        else => fatalIo(err),
    };

    const r = qs.select_user_by_handle.run(@src(), db, .{
        .handle = username,
    }) orelse return error.NotFound;

    return .{
        .id = r.get(.id),
        .created = r.get(.created),
        .power = r.get(.power),
        .display_name = r.text(gpa, .display_name) catch oom(),
        .update_uid = r.get(.update_uid),
        .avatar = r.text(gpa, .avatar) catch oom(),
        .handle = gpa.dupe(u8, username) catch oom(),
        .invited_by = r.get(.invited_by),
        .server = .{
            .pswd_hash = gpa.dupe(u8, pswd_hash) catch oom(),
        },
    };
}

fn serverPermission(
    user: *const awebo.User,
    key: awebo.permissions.Server.Enum,
) bool {
    const user_id = user.id;
    const user_default = @field(awebo.permissions.Server{}, @tagName(key));

    switch (user.power) {
        .banned => return false,
        .admin, .owner => return true,
        .user, .moderator => {},
    }

    const r = qs.select_permission.run(@src(), db, .{
        .user = user_id,
        .kind = .server,
        .key = key,
    }) orelse return user_default;

    server_log.debug("found {t} perm for user '{s}': {}", .{
        key, user.handle, r.get(.value),
    });

    return r.get(.value);
}

pub const Queries = struct {
    select_password: Query(
        \\SELECT hash FROM passwords WHERE handle = ?
    , .{
        .kind = .row,
        .cols = struct { hash: []const u8 },
        .args = struct { handle: []const u8 },
    }),

    select_user_by_handle: Query(
        \\SELECT id, created, display_name, update_uid, power, invited_by, avatar FROM users
        \\WHERE handle = ?;
    , .{
        .kind = .row,
        .cols = struct {
            id: u64,
            created: awebo.Date,
            display_name: []const u8,
            update_uid: u64,
            power: awebo.User.Power,
            invited_by: ?awebo.User.Id,
            avatar: []const u8,
        },
        .args = struct { handle: []const u8 },
    }),

    select_chat_history: @FieldType(Database.CommonQueries, "select_chat_history"),
    select_chat_present: @FieldType(Database.CommonQueries, "select_chat_present"),

    // select_user_permission: Query(
    //     \\SELECT value FROM user_permissions
    //     \\WHERE user = ?1 AND kind = ?2 AND key = ?3;
    // , .{
    //     .kind = .row,
    //     .cols = struct { value: bool },
    //     .args = struct {
    //         user: awebo.User.Id,
    //         kind: awebo.permissions.Kind,
    //         key: awebo.permissions.Server.Enum,
    //     },
    // }),

    // select_role_permission: Query(
    //     \\SELECT value FROM role_permissions
    //     \\INNER JOIN user_roles ON user_roles.role == role_permissions.role
    //     \\WHERE kind = ? AND key = ? AND user_roles.user = ?;
    // , .{
    //     .kind = .row,
    //     .cols = struct { value: bool },
    //     .args = struct {
    //         user: awebo.User.Id,
    //         kind: awebo.permissions.Kind,
    //         key: awebo.permissions.Server.Enum,
    //     },
    // }),

    select_permission: Query(
        \\SELECT value
        \\FROM (
        \\  SELECT value FROM user_permissions
        \\    WHERE user = ?1 AND kind = ?2 AND key = ?3
        \\  UNION ALL
        \\  SELECT MIN(value) FROM role_permissions
        \\    INNER JOIN user_roles ON user_roles.role == role_permissions.role
        \\    WHERE kind = ? AND key = ? AND user_roles.user = ?
        \\) WHERE value IS NOT NULL LIMIT 1;
    , .{
        .kind = .row,
        .cols = struct { value: bool },
        .args = struct {
            user: awebo.User.Id,
            kind: awebo.permissions.Kind,
            key: awebo.permissions.Server.Enum,
        },
    }),

    search_messages: Query(
        \\SELECT
        \\  messages.channel,
        \\  messages.uid,
        \\  messages.origin,
        \\  messages.created,
        \\  messages.update_uid,
        \\  messages.author,
        \\  highlight(messages_search, 2, char(0x20) || char(0x0B), char(0x20) || char(0x0B))
        \\FROM messages_search
        \\INNER JOIN messages on messages_search.rowid = messages.uid
        \\LEFT JOIN users ON messages_search.author == users.id
        \\WHERE messages_search.body MATCH ?1
        \\ORDER BY messages.created DESC;
    , .{
        .kind = .rows,
        .args = struct {
            query: []const u8,
        },
        .cols = struct {
            channel: awebo.Channel.Id,
            message_id: awebo.Message.Id,
            message_origin: u64,
            message_created: awebo.Date,
            message_update_uid: ?u64,
            message_author: awebo.User.Id,
            message_hl_text: []const u8,
        },
    }),
};

fn tcpId(io: Io) i96 {
    const ts = Io.Clock.awake.now(io);
    return ts.toNanoseconds();
}

test {
    _ = awebo;
}

test "server run queries" {
    const _db: awebo.Database = .init(":memory:", .create);
    defer _db.close();
    _ = _db.initQueries(Queries);
}
