const builtin = @import("builtin");
const options = @import("options");
const std = @import("std");
const Io = std.Io;
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Settings = @import("../../Settings.zig");
const Database = @import("../../Database.zig");
const RateLimiter = @import("../../RateLimiter.zig");
const awebo = @import("../../../awebo.zig");
const Host = awebo.Host;
const Header = awebo.protocol.media.Header;
const OpenStream = awebo.protocol.media.OpenStream;

const server_log = std.log.scoped(.server);

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
                    switch (crtl_type) {
                        win.CTRL_C_EVENT => {
                            shutdown_event.set();
                            return win.TRUE;
                        },
                        else => return win.FALSE,
                    }
                }
            };

            win.SetConsoleCtrlHandler(&Impl.handler, true) catch {
                server_log.err("unable to setup ctrl+c handler, continuing anyway", .{});
            };
        },
        else => server_log.err(
            "ctrl+c handler for this platform was not implemented, " ++
                "consider adding support for it. continuing anyway.",
            .{},
        ),
    }

    if (options.slow) server_log.warn("slow mode enabled", .{});
    server_start = std.time.Instant.now() catch @panic("server needs a working clock");

    server_log.info("loading database", .{});
    db = .init(cmd.db_path, .read_write);
    ___state.init(io, gpa) catch |err| {
        fatal("unable to load state from database: {t}", .{err});
    };
    defer ___state.deinit(gpa);

    server_log.info("starting tcp interface at {f}", .{cmd.tcp});
    var tcp = cmd.tcp.listen(io, .{ .reuse_address = true }) catch |err| {
        fatal("unable to listen to '{f}': {t}", .{ cmd.tcp, err });
    };
    defer tcp.deinit(io);

    var tcp_future = io.concurrent(runTcpAccept, .{ io, gpa, tcp }) catch |err| fatalIo(err);
    defer {
        server_log.info("shutting down tcp interface", .{});
        tcp_future.cancel(io) catch {};
    }

    server_log.info("starting udp interface at {f}", .{cmd.udp});
    const udp = cmd.udp.bind(io, .{ .mode = .dgram }) catch |err| {
        fatal("unable to bind '{f}': {t}", .{ cmd.tcp, err });
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
    var qbuf: [64][]const u8 = undefined;
    var client: Client = .{
        .tcp = .{
            .connected_at = now(),
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

        switch (marker) {
            else => {
                // TODO: this should consume runTcpAccept tokens
                log.debug("bad request marker, closing connection", .{});
                return error.BadRequest;
            },
            awebo.protocol.client.Authenticate.marker => {
                // TODO: this should consume runTcpAccept tokens
                log.debug("authenticated client attempted to authenticate again", .{});
                return error.AweboProtocolError;
            },
            awebo.protocol.client.CallJoin.marker => {
                client.callJoinRequest(io, gpa, reader) catch |err| {
                    log.err("error processing CallJoin: {t}", .{err});
                };
            },
            awebo.protocol.client.ChatMessageSend.marker => {
                client.chatMessageSendRequest(io, gpa, reader) catch |err| {
                    log.err("error processing ChatMessageSend: {t}", .{err});
                };
            },
            awebo.protocol.client.ChannelCreate.marker => {
                client.channelCreate(io, gpa, reader) catch |err| {
                    log.err("error processing ChannelCreate: {t}", .{err});
                };
            },
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
        var msgbuf: [64][]const u8 = undefined;
        const messages = msgbuf[0..try client.tcp.queue.get(io, &msgbuf, 1)];
        log.debug("tcp write got {} messages to send", .{messages.len});
        if (options.slow) {
            for (messages) |m| {
                try io.sleep(.fromSeconds(1), .real);
                try writer.writeAll(m);
                try writer.flush();
            }
        } else {
            try writer.writeVecAll(messages);
            try writer.flush();
        }
        for (messages) |msg| gpa.free(msg);
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

                const client = state.clients.tcp_index.get(os.tcp_client) orelse {
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
                    state.removeUdp(io, gpa, client);
                }

                state.setUdp(gpa, client, packet.from);

                {
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

                    state.tcpBroadcast(io, msg);
                }
            },

            .media => {
                const sender = state.clients.udp_index.get(packet.from) orelse {
                    server_log.debug("received media udp packet from unknown source: {f}", .{packet.from});
                    continue;
                };

                sender.udp.?.last_msg_ms = now();
                header.id.client_id = sender.udp.?.id;

                const room = state.clients.voice_index.get(sender.voice.?.id).?;
                const receivers = room.keys();
                var batch: [64]Io.net.OutgoingMessage = undefined;
                var batch_idx: usize = 0;
                for (receivers, 0..) |client, idx| {
                    const receiver_udp = client.udp orelse continue;
                    if (!options.echo and receiver_udp.id == sender.voice.?.id) continue;
                    batch[batch_idx] = .{
                        .address = &client.udp.?.addr,
                        .data_ptr = packet.data.ptr,
                        .data_len = packet.data.len,
                    };
                    batch_idx += 1;
                    if (batch_idx == batch.len or idx == receivers.len - 1) {
                        udp.sendMany(io, batch[0..batch_idx], .{}) catch |err| {
                            server_log.err("sendMany encountered error {t} while sending {} packets", .{
                                err, batch_idx,
                            });
                            continue;
                        };
                    }
                }
            },
        }
    }
}

const Client = struct {
    tcp: struct {
        connected_at: u64,
        stream: Io.net.Stream,
        reader_state: Io.net.Stream.Reader = undefined,
        writer_state: Io.net.Stream.Writer = undefined,
        /// Queue of messages to be sent to the client
        queue: Io.Queue([]const u8),
    },

    authenticated: ?awebo.User.Id = null,
    voice: ?struct {
        id: awebo.channels.Voice.Id,
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
        state.removeFromCall(io, gpa, client);

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

        const user = db.getUserByLogin(io, gpa, cmd.method.login.username, cmd.method.login.password) catch |err| switch (err) {
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
        const can_auth = db.serverPermission(&user, .authenticate);
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
        client.authenticated = 0;
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

        log.debug("latest_messages.buffer.len = {} head = {} len = {}", .{
            state.latest_messages.buffer.len,
            state.latest_messages.head,
            state.latest_messages.len,
        });
        const head = state.latest_messages.head;
        const len = state.latest_messages.len;
        const buflen = state.latest_messages.buffer.len;
        const slice_front, const slice_back = if (head + len < buflen) blk: {
            break :blk .{
                state.latest_messages.buffer[head..][0..len],
                &.{},
            };
        } else blk: {
            break :blk .{
                state.latest_messages.buffer[0 .. (head + len) - buflen],
                state.latest_messages.buffer[head..buflen],
            };
        };
        const hs: awebo.protocol.server.HostSync = .{
            .host = state.host,
            .user_id = client.authenticated.?,
            .messages_front = slice_front,
            .messages_back = slice_back,
        };
        const bytes = try hs.serializeAlloc(gpa);
        errdefer gpa.free(bytes);

        // order matters, we first confirm the auth request and second send the host sync data
        try client.tcp.queue.putAll(io, &.{ auth_bytes, bytes });
        log.debug("queued 2 replies", .{});
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

        const chat = state.host.chats.create(gpa, cc.name) catch |err| switch (err) {
            error.OutOfMemory => @panic("oom"),
            error.NameTaken => {
                const ccr = cc.reply(.name_taken);
                const bytes = try ccr.serializeAlloc(gpa);
                errdefer gpa.free(bytes);
                try client.tcp.queue.putOne(io, bytes);
                return;
            },
        };

        {
            const ccr = cc.reply(.ok);
            const bytes = try ccr.serializeAlloc(gpa);
            errdefer gpa.free(bytes);

            try client.tcp.queue.putOne(io, bytes);
        }

        {
            const cu: awebo.protocol.server.ChannelsUpdate = .{
                .kind = .delta,
                .channels = &.{chat.*},
            };

            const bytes = try cu.serializeAlloc(gpa);
            errdefer gpa.free(bytes);
            try client.tcp.queue.putOne(io, bytes);
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
                state.user_limits.items[client.authenticated.?].takeToken(io, .user_action) catch {
                    log.debug("user {} exceeded user action limit", .{client.authenticated.?});
                    const fail: awebo.protocol.server.ClientRequestReply = .{
                        .origin = cmd.origin,
                        .reply_marker = awebo.protocol.client.CallJoin.marker,
                        .result = .rate_limit,
                    };

                    const bytes = try fail.serializeAlloc(gpa);
                    try client.tcp.queue.putOne(io, bytes);
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

        try client.tcp.queue.putOne(io, bytes);
    }

    fn chatMessageSendRequest(client: *Client, io: Io, gpa: Allocator, reader: *Io.Reader) !void {
        const log = client.scopedLog();
        const cms = try awebo.protocol.client.ChatMessageSend.deserializeAlloc(gpa, reader);

        const locked = lockState(io);
        defer locked.unlock(io);
        const state = locked.state;

        state.user_limits.items[client.authenticated.?].takeToken(io, .user_action) catch {
            log.debug("exceeded user action limit", .{});
            const fail: awebo.protocol.server.ClientRequestReply = .{
                .origin = cms.origin,
                .reply_marker = awebo.protocol.client.ChatMessageSend.marker,
                .result = .rate_limit,
            };

            const bytes = try fail.serializeAlloc(gpa);
            try client.tcp.queue.putOne(io, bytes);
        };

        const chat = state.host.chats.get(cms.chat) orelse {
            log.debug("unknown channel", .{});
            const reply = cms.replyErr(.unknown_channel);
            const bytes = try reply.serializeAlloc(gpa);
            errdefer gpa.free(bytes);
            try client.tcp.queue.putOne(io, bytes);
            return;
        };

        const new: awebo.Message = .{
            .id = now(),
            .origin = cms.origin,
            .channel = chat.id,
            .author = client.authenticated.?,
            .text = cms.text,
        };

        try chat.addMessage(db, new);
        try state.latest_messages.pushFront(gpa, new);
        if (state.latest_messages.len > 128) state.latest_messages.popBack().?.deinit(gpa);

        {
            const cmn: awebo.protocol.server.ChatMessageNew = .{
                .origin = cms.origin,
                .chat = cms.chat,
                .msg = new,
            };

            const bytes = try cmn.serializeAlloc(gpa);
            errdefer gpa.free(bytes);

            state.tcpBroadcast(io, bytes);
        }
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

pub const State = @TypeOf(___state);
var ___state: struct {
    settings: Settings = undefined,
    host: Host = .{},
    callers: struct {} = .{},
    /// Cache of latest messages we received, so that we can quickly sync
    /// new clients without having to hit the database every time.
    latest_messages: std.Deque(awebo.Message) = .empty,
    /// Per-user rate limiters, use User.Id to index into the array
    user_limits: std.ArrayList(RateLimiter) = .empty,
    clients: struct {
        head: ?*Client = null,

        /// We use connection time of a TCP socket as a unique identifier
        tcp_index: std.AutoHashMapUnmanaged(u64, *Client) = .{},

        /// Clients gain a udp address when they connect to a call.
        udp_index: std.AutoHashMapUnmanaged(Io.net.IpAddress, *Client) = .{},

        /// Clients that express an intent to be in a voice call.
        /// Not all clients listed here have a UDP address yet.
        voice_index: std.AutoHashMapUnmanaged(
            awebo.channels.Voice.Id,
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
        const user_limits = blk: {
            var r = db.conn.row("SELECT COUNT(*) FROM users", .{}) catch db.fatal(@src());
            defer r.?.deinit();

            const user_count: usize = @intCast(r.?.int(0));

            var user_limits: std.ArrayList(RateLimiter) = .empty;

            const elems = try user_limits.addManyAt(gpa, 0, user_count);
            for (elems) |*e| e.* = .init(io, .user_action);

            break :blk user_limits;
        };

        const settings = blk: {
            var settings: Settings = undefined;

            var rows = db.rows("SELECT key, value FROM settings", .{}) catch db.fatal(@src());
            defer rows.deinit();

            outer: while (rows.next()) |r| {
                const key = r.textNoDupe(.key);
                inline for (std.meta.fields(Settings)) |f| {
                    if (std.mem.eql(u8, f.name, key)) {
                        @field(settings, f.name) = switch (f.type) {
                            []const u8 => try r.text(gpa, .value),
                            usize => @intCast(r.int(.value)),
                            else => @compileError("implement mapping for " ++ @typeName(f.type)),
                        };
                        continue :outer;
                    }
                }
            }
            break :blk settings;
        };

        const host: awebo.Host = host: {
            const chats = blk: {
                var rs = db.rows("SELECT id, name FROM channels WHERE kind = ?", .{
                    @intFromEnum(awebo.channels.Kind.chat),
                }) catch db.fatal(@src());
                defer rs.deinit();

                var chats: awebo.Host.Chats = .{};

                while (rs.next()) |r| {
                    const chat: awebo.channels.Chat = .{
                        .id = @intCast(r.int(.id)),
                        .name = try r.text(gpa, .name),
                    };
                    try chats.set(gpa, chat);
                    server_log.debug("loaded chat: {f}", .{chat});
                }

                break :blk chats;
            };

            const voices = blk: {
                var rs = db.rows("SELECT id, name FROM channels WHERE kind = ?", .{
                    @intFromEnum(awebo.channels.Kind.voice),
                }) catch db.fatal(@src());
                defer rs.deinit();

                var voices: awebo.Host.Voices = .{};

                while (rs.next()) |r| {
                    const voice: awebo.channels.Voice = .{
                        .id = @intCast(r.int(.id)),
                        .name = try r.text(gpa, .name),
                    };
                    try voices.set(gpa, voice);
                    server_log.debug("loaded voice chat: {f}", .{voice});
                }

                break :blk voices;
            };

            break :host .{
                .name = settings.name,
                .chats = chats,
                .voices = voices,
            };
        };

        const latest_messages = blk: {
            var rs = db.rows(
                "SELECT id, origin, channel, author, body FROM messages ORDER BY id DESC LIMIT 128",
                .{},
            ) catch db.fatal(@src());
            defer rs.deinit();

            var latest_messages: std.Deque(awebo.Message) = .empty;

            while (rs.next()) |r| {
                const msg: awebo.Message = .{
                    .id = @intCast(r.int(.id)),
                    .origin = @intCast(r.int(.origin)),
                    .channel = @intCast(r.int(.channel)),
                    .author = @intCast(r.int(.author)),
                    .text = try r.text(gpa, .body),
                };
                try latest_messages.pushFront(gpa, msg);
                server_log.debug("loaded chat message: {f}", .{msg});
            }

            break :blk latest_messages;
        };

        state.* = .{
            .settings = settings,
            .host = host,
            .latest_messages = latest_messages,
            .user_limits = user_limits,
        };
    }

    fn deinit(state: *State, gpa: Allocator) void {
        if (builtin.mode != .Debug) return;

        {
            var it = state.latest_messages.iterator();
            while (it.next()) |msg| msg.deinit(gpa);
            state.latest_messages.deinit(gpa);
        }

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
            .last_msg_ms = now(),
        };

        server_log.debug("setting {f}", .{addr});

        state.clients.udp_index.put(gpa, addr, client) catch unreachable;
    }

    fn removeFromCall(state: *State, io: Io, gpa: Allocator, client: *Client) void {
        const vid = if (client.voice) |v| v.id else return;
        state.removeUdp(io, gpa, client);
        client.voice = null;

        const room = state.clients.voice_index.getPtr(vid).?;
        if (room.count() == 1) {
            std.debug.assert(room.keys()[0] == client);
            var kv = state.clients.voice_index.fetchRemove(vid).?;
            kv.value.deinit(gpa);
        } else {
            _ = room.swapRemove(client);
        }
    }

    fn removeUdp(state: *State, io: Io, gpa: Allocator, client: *Client) void {
        const udp = client.udp orelse return;
        const vid = client.voice.?.id;
        const cu: awebo.protocol.server.CallersUpdate = .{
            .caller = .{
                .id = @intCast(udp.id),
                .voice = vid,
                .user = client.authenticated.?,
            },
            .action = .leave,
        };

        const bytes = cu.serializeAlloc(gpa) catch @panic("oom");
        state.tcpBroadcast(io, bytes);

        _ = state.clients.udp_index.remove(client.udp.?.addr);
        client.udp = null;
    }

    fn tcpBroadcast(state: *State, io: Io, msg: []const u8) void {
        var maybe_cur: ?*Client = state.clients.head;
        while (maybe_cur) |cur| : (maybe_cur = cur.next) {
            // TODO: this needs to be a tryPut + client disconnection if the queue is full
            cur.tcp.queue.putOne(io, msg) catch @panic("TODO");
        }
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

        const eql = std.mem.eql;
        while (it.next()) |arg| {
            if (eql(u8, arg, "--tcp")) {
                if (tcp != null) fatal("duplicate --tcp argument", .{});
                const ip = it.next() orelse fatal("missing argument to --tcp", .{});
                tcp = Io.net.IpAddress.parseLiteral(ip) catch |err| {
                    fatal(
                        "unable to parse '{s}' as an ip address: {t}",
                        .{ arg, err },
                    );
                };
            } else if (eql(u8, arg, "--udp")) {
                if (udp != null) fatal("duplicate --udp argument", .{});
                const ip = it.next() orelse fatal("missing argument to --udp", .{});
                udp = Io.net.IpAddress.parseLiteral(ip) catch |err| {
                    fatal(
                        "unable to parse '{s}' as an ip address with port: {t}",
                        .{ arg, err },
                    );
                };
            } else if (eql(u8, arg, "--db-path")) {
                if (db_path != null) fatal("duplicate --db-path argument", .{});
                db_path = arg;
            } else {
                fatalHelp();
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

fn fatalIo(err: anyerror) noreturn {
    fatal("unable to perform I/O operation: {t}", .{err});
}

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    server_log.err("fatal error: " ++ fmt ++ "\n", args);
    if (builtin.mode == .Debug) @breakpoint();
    std.process.exit(1);
}

pub var server_start: std.time.Instant = undefined;
fn now() u64 {
    const n = std.time.Instant.now() catch @panic("server needs a working clock");
    return n.since(server_start);
}

fn fatalHelp() noreturn {
    std.debug.print(
        \\Usage: awebo-server server run [OPTIONAL_ARGS]
        \\
        \\Start the Awebo server.
        \\
        \\Optional arguments:
        \\ --db-path DB_PATH     Path to the SQLite database to be used.
        \\                       Defaults to 'awebo.db'.
        \\ --tcp IP:PORT         Address and port for TCP communication.
        \\                       Defaults to '[::]:1991'.
        \\ --udp IP:PORT         Address and port for UDP communication.
        \\                       Defaults to '[::]:1992'.
        \\ --help, -h            Show this menu and exit.
        \\
        \\
    , .{});

    std.process.exit(1);
}
