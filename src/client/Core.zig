const Core = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.core);
const Io = std.Io;
const Allocator = std.mem.Allocator;
const awebo = @import("../awebo.zig");
const Host = awebo.Host;
const HostId = awebo.Host.ClientOnly.Id;
const Channel = awebo.Channel;
const Chat = Channel.Chat;
const Voice = Channel.Voice;
const Media = @import("Media.zig");
const network = @import("Core/network.zig");
const persistence = @import("Core/persistence.zig");
const screen_capture = @import("media/screen-capture.zig");
const ScreenShare = screen_capture.ScreenShare;

gpa: Allocator,
io: Io,
environ: *std.process.Environ.Map,
audio_backend: audio.Backend,
/// Protects all the fields after this one.
mutex: Io.Mutex = .init,
/// Set to an error message when the core logic encounters an unrecoverable error.
/// The application should show an error dialog and shutdown when this happens.
failure: UnrecoverableFailure = .none,
/// Set to true once data has been loaded from disk.
loaded: bool = false,
cache_path: []const u8 = undefined,
hosts: Hosts = .{},
active_host: awebo.Host.ClientOnly.Id = 0,
message_window: awebo.Channel.Chat.MessageWindow = .{},

cfg: std.StringHashMapUnmanaged([]const u8) = .{},

user_audio: struct {
    capture: UserAudio = .{ .direction = .capture, .volume = 0.5 },
    playout: UserAudio = .{ .direction = .playout, .volume = 0.5 },
} = .{},
audio_capture: audio.Directional = .{ .direction = .capture },
audio_playout: audio.Directional = .{ .direction = .playout },

active_call: ?ActiveCall = null,

// This is temporarily put in the main state scope so that it can be
// tested locally without needing to enter a voice channel first.
// Once the lcoal work is done and we decide to start wiring it over
// the network, it will have to be moved into `active_call` and
// integrated with the call lifecycle.
screenshare_intent: bool = false,

command_queue: Io.Queue(Event),
refresh: *const RefreshFn,
start_time: Io.Timestamp,

// this is only set to pass the message to `chat_panel`
search_messages_reply: ?awebo.protocol.server.SearchMessagesReply = null,

media: Media,
string_pool: StringPool,

pub const audio = @import("audio.zig");
pub const ui = @import("Core/ui.zig");
pub const Device = @import("Device.zig");
pub const StringPool = @import("StringPool.zig");

pub const RefreshFn = fn (core: *Core, src: std.builtin.SourceLocation, id: ?u64) void;

pub const UnrecoverableFailure = union(enum) {
    none,
    audio_process_init: anyerror,
    db_load: anyerror,
};

pub const Hosts = struct {
    last_id: u32 = 0,
    items: std.AutoArrayHashMapUnmanaged(Host.ClientOnly.Id, Host) = .{},
    identities: std.StringHashMapUnmanaged(Host.ClientOnly.Id) = .{},

    pub fn get(hosts: @This(), id: Host.ClientOnly.Id) ?*Host {
        return hosts.items.getPtr(id);
    }

    pub fn add(
        hosts: *@This(),
        core: *Core,
        identity: []const u8,
        username: []const u8,
        password: []const u8,
        save: bool,
    ) error{ DuplicateHost, OutOfMemory }!*Host {
        const gpa = core.gpa;
        const io = core.io;
        const index_gop = try hosts.identities.getOrPut(gpa, identity);
        if (index_gop.found_existing) return error.DuplicateHost;
        errdefer _ = hosts.identities.remove(identity);

        hosts.last_id += 1;
        index_gop.value_ptr.* = hosts.last_id;

        const gop = try hosts.items.getOrPutValue(gpa, hosts.last_id, .{
            .client = .{
                .identity = identity,
                .host_id = hosts.last_id,
                .username = username,
                .password = password,
            },
        });

        // We gained a new server, let's update our persisted data.
        if (save) persistence.updateHosts(io, hosts.items.values()) catch |err| {
            log.err("error while saving config: {t}", .{err});
        };
        return gop.value_ptr;
    }
};

pub fn init(
    gpa: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    refreshFn: *const RefreshFn,
    command_queue_buffer: []Event,
) Core {
    return .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .start_time = .now(io, .awake),
        .refresh = refreshFn,
        .command_queue = .init(command_queue_buffer),
        .media = undefined,
        .string_pool = .{},
        .audio_backend = undefined,
    };
}

pub fn deinit(core: *Core) void {
    core.hosts.identities.deinit(core.gpa);
    core.hosts.items.deinit(core.gpa);
    var iter = core.cfg.iterator();
    while (iter.next()) |entry| {
        core.gpa.free(entry.key_ptr.*);
        core.gpa.free(entry.value_ptr.*);
    }
    core.cfg.deinit(core.gpa);
}

pub fn run(core: *Core) void {
    const io = core.io;

    log.debug("started", .{});
    defer log.debug("goodbye", .{});

    log.debug("starting audio support", .{});
    audio.init(core) catch |err| {
        log.err("failed to initialize audio: {t}", .{err});

        var locked = lockState(core);
        defer locked.unlock();

        core.failure = .{ .audio_process_init = err };
        return;
    };

    log.debug("load state and begin connecting to hosts", .{});
    var first_connect_group: Io.Group = .init;
    defer first_connect_group.cancel(io);
    {
        var locked = lockState(core);
        defer locked.unlock();
        persistence.load(core) catch return;
        const hosts = core.hosts.items.values();
        for (hosts) |h| first_connect_group.async(io, network.runHostManager, .{
            core,
            .{
                .connect = .{
                    .host_id = h.client.host_id,
                    .max_uid = h.client.max_uid,
                },
            },
            h.client.identity,
            h.client.username,
            h.client.password,
        });
    }

    while (true) {
        const event = core.command_queue.getOne(io) catch return;
        switch (event) {
            .network => |msg| {
                log.debug("from host {} got {any}", .{ msg.host_id, msg.cmd });
                switch (msg.cmd) {
                    .host_connection_update => |hcu| hostConnectionUpdate(core, msg.host_id, hcu),
                    .caller_speaking => |cs| {
                        var locked = lockState(core);
                        defer locked.unlock();

                        const host = core.hosts.get(msg.host_id).?;
                        const caller = host.client.callers.get(cs.caller) orelse continue;
                        caller.client.speaking_last_ms = cs.time_ms;
                    },

                    .host_sync => |*hs| hostSync(core, msg.host_id, hs),
                    .chat_typing => |ct| chatTyping(core, msg.host_id, ct),
                    .chat_message_new => |cms| chatMessageNew(core, msg.host_id, cms),
                    .chat_history => |chg| chatHistory(core, msg.host_id, chg),
                    .media_connection_details => |mcd| mediaConnectionDetails(core, msg.host_id, mcd),
                    .callers_update => |cu| callersUpdate(core, msg.host_id, cu),

                    .search_messages_reply => |smr| core.search_messages_reply = smr,
                    .client_request_reply => |crr| core.handleRequestReply(crr),
                    .channels_update => |cu| core.channelsUpdate(cu),
                }
            },
            .audio_ready => {
                log.info("audio ready", .{});
            },
        }

        core.refresh(core, @src(), null);
    }
}

pub const Event = union(enum) {
    network: Network,
    audio_ready: void,

    pub const Network = struct {
        host_id: awebo.Host.ClientOnly.Id,
        cmd: union(enum) {
            host_connection_update: awebo.Host.ClientOnly.ConnectionStatus,
            caller_speaking: CallerSpeaking,

            host_sync: awebo.protocol.server.HostSync,
            chat_typing: awebo.protocol.server.ChatTyping,
            chat_message_new: awebo.protocol.server.ChatMessageNew,
            chat_history: awebo.protocol.server.ChatHistory,
            media_connection_details: awebo.protocol.server.MediaConnectionDetails,
            callers_update: awebo.protocol.server.CallersUpdate,

            search_messages_reply: awebo.protocol.server.SearchMessagesReply,

            channels_update: awebo.protocol.server.ChannelsUpdate,
            client_request_reply: awebo.protocol.server.ClientRequestReply,
        },

        pub const CallerSpeaking = struct {
            time_ms: u64,
            caller: awebo.Caller.Id,
        };
    };
};

pub fn putEvent(core: *Core, event: Event) error{ Canceled, Closed }!void {
    return core.command_queue.putOne(core.io, event);
}

fn hostConnectionUpdate(core: *Core, id: HostId, hcu: awebo.Host.ClientOnly.ConnectionStatus) void {
    var locked = lockState(core);
    defer locked.unlock();

    const host = core.hosts.get(id).?;

    host.client.connection_status = hcu;
    switch (hcu) {
        .connected => |hc| host.client.connection = hc,
        else => {},
    }

    core.refresh(core, @src(), 0);
}

fn hostSync(core: *Core, id: HostId, hs: *const awebo.protocol.server.HostSync) void {
    var locked = lockState(core);
    defer locked.unlock();

    log.debug("host sync data: {f}", .{hs});

    if (core.hosts.get(id)) |host| {
        const db = host.client.db;
        db.conn.transaction() catch db.fatal(@src());
        host.sync(core.gpa, hs);
        db.conn.commit() catch db.fatal(@src());
    } else {
        // Not considering this a programming error because it seems possible for
        // a message to be stuck in the queue while this host is being deleted by the user.
        log.debug("received update for host (id={}) that doesn't exist, dropping it", .{id});
        hs.deinit(core.gpa);
    }
}

fn channelsUpdate(core: *Core, cu: awebo.protocol.server.ChannelsUpdate) void {
    const gpa = core.gpa;

    var locked = lockState(core);
    defer locked.unlock();

    const h = core.hosts.get(1).?;
    switch (cu.op) {
        .create => {
            for (cu.channels) |channel| {
                h.client.qs.upsert_channel.run(@src(), h.client.db, .{
                    .id = channel.id,
                    .update_uid = channel.update_uid,
                    .section = null,
                    .sort = 0,
                    .name = channel.name,
                    .kind = channel.kind,
                    .privacy = channel.privacy,
                });
                h.channels.set(gpa, channel) catch oom();
            }
        },
        .delete => {},
    }
}
fn handleRequestReply(core: *Core, crr: awebo.protocol.server.ClientRequestReply) void {
    var locked = lockState(core);
    defer locked.unlock();

    log.debug("Reply(m: '{c}' orig: {} res: {t})", .{
        crr.reply_marker,
        crr.origin,
        crr.result,
    });

    switch (crr.reply_marker) {
        awebo.protocol.client.ChannelCreate.marker => {
            const h = core.hosts.get(1).?;

            if (h.client.pending_requests.get(crr.origin)) |status| {
                const new: ui.ChannelCreate.Status.Enum = switch (crr.result) {
                    .ok => .ok,
                    .rate_limit => .rate_limit,
                    .no_permission => .no_permission,
                    .err => |err| @enumFromInt(err.code),
                };

                @atomicStore(u8, status, @intFromEnum(new), .release);
            }
        },
        else => log.warn("unhandled ClientRequestReply marker '{c}'", .{
            crr.reply_marker,
        }),
    }
}

fn chatTyping(core: *Core, host_id: HostId, ct: awebo.protocol.server.ChatTyping) void {
    var locked = lockState(core);
    defer locked.unlock();

    const h = core.hosts.get(host_id).?;
    const u = h.users.get(ct.uid).?;
    const c = &h.channels.get(ct.channel).?.kind.chat;

    _ = c.client.typing.orderedRemove(u.id);
    c.client.typing.putNoClobber(core.gpa, u.id, core.now()) catch oom();
}

fn chatMessageNew(core: *Core, host_id: HostId, cmn: awebo.protocol.server.ChatMessageNew) void {
    var locked = lockState(core);
    defer locked.unlock();

    const h = core.hosts.get(host_id).?;
    const channel = h.channels.get(cmn.channel).?;
    const chat = &channel.kind.chat;
    const u = h.users.get(cmn.msg.author).?;

    const db = h.client.db;
    const new = cmn.msg;
    h.client.qs.insert_message.run(@src(), db, .{
        .uid = new.id,
        .origin = new.origin,
        .created = new.created,
        .update_uid = new.update_uid,
        .channel = cmn.channel,
        .kind = new.kind,
        .author = new.author,
        .body = new.text,
    });
    _ = chat.client.typing.orderedRemove(u.id);

    if (cmn.origin != 0) {
        if (chat.client.pending_messages.orderedRemove(cmn.origin)) {
            core.refresh(core, @src(), 0);
        }
    }

    if (host_id == core.active_host) {
        if (h.client.active_channel) |ac| {
            if (ac == channel.id) {
                chat.client.new_messages = true;
                if (chat.client.loaded_all_new_messages) {
                    core.message_window.pushNew(core.gpa, new) catch @panic("oom");
                }
            }
        }
    }
}

fn chatHistory(core: *Core, host_id: HostId, ch: awebo.protocol.server.ChatHistory) void {
    const h = core.hosts.get(host_id).?;
    const channel = h.channels.get(ch.channel) orelse {
        log.err("received a chat history message for a channel that doesn't exist", .{});
        return;
    };

    for (ch.history, 0..) |msg, idx| {
        log.debug("chatHistory channel ({}): saving history message {}", .{ ch.channel, msg });

        if (idx != awebo.Channel.window_size - 1) {
            h.client.qs.upsert_message.run(@src(), h.client.db, .{
                .uid = msg.id,
                .origin = msg.origin,
                .created = msg.created,
                .update_uid = msg.update_uid,
                .channel = ch.channel,
                .kind = msg.kind,
                .author = msg.author,
                .body = msg.text,
                .reactions = null,
            });
        } else {
            // We received a full chunk but we might have already
            // re-connected to another chunk, meaning that we don't
            // necessarily need to create a missing messages marker.

            log.debug("saving missing messages marker at uid = {}", .{msg.id});

            const kind: awebo.Message.Kind = if (ch.history[0].id > ch.history[1].id)
                .missing_messages_older
            else
                .missing_messages_newer;
            h.client.qs.insert_message_or_ignore.run(@src(), h.client.db, .{
                .uid = msg.id,
                .origin = msg.origin,
                .created = msg.created,
                .update_uid = msg.update_uid,
                .channel = ch.channel,
                .kind = kind,
                .author = msg.author,
                .body = msg.text,
            });
        }
    }

    channel.kind.chat.client.state = .ready;
    if (ch.history.len < awebo.Channel.window_size) {
        channel.kind.chat.client.fetched_all_old_messages = true;
    }
}
fn callersUpdate(core: *Core, host_id: HostId, cu: awebo.protocol.server.CallersUpdate) void {
    var locked = lockState(core);
    defer locked.unlock();

    const h = core.hosts.get(host_id).?;

    if (cu.action == .join and cu.caller.user == h.client.user_id) {
        if (core.active_call) |*ac| {
            _ = ac.status.updateCompare(core, @src(), .connecting, .connected);
        }
    }

    switch (cu.action) {
        .join, .update => h.client.callers.set(core.gpa, cu.caller) catch oom(),
        .leave => h.client.callers.remove(cu.caller.id) catch oom(),
    }
}

fn mediaConnectionDetails(
    core: *Core,
    host_id: HostId,
    mcd: awebo.protocol.server.MediaConnectionDetails,
) void {
    const io = core.io;

    var locked = lockState(core);
    defer locked.unlock();

    if (core.active_call) |*ac| {
        if (ac.host_id == host_id and ac.voice_id == mcd.voice) {
            if (ac.status.updateCompare(core, @src(), .intent, .connecting) == .intent) {
                errdefer {
                    ac.deinit();
                    core.active_call = null;
                }

                // Activates audio streams
                core.media.init(core) catch |err| std.debug.panic("err staring audio: {t}", .{err});

                // Asks to the network layer to start the UDP data transfer
                // for this call.
                const host = core.hosts.get(host_id).?;
                _ = io.concurrent(network.runHostMediaManager, .{
                    core,
                    host_id,
                    host.client.connection.?,
                    mcd.tcp_client,
                    mcd.nonce,
                }) catch @panic("no concurrency");
            } else log.debug(
                "ignoring media connection info, already connected or quit",
                .{},
            );
        } else log.debug(
            "ignoring info for channel we don't care about",
            .{},
        );
    } else log.debug(
        "ignoring media connection info as we don't want to be in a call anymore",
        .{},
    );
}

pub const Locked = struct {
    core: *Core,

    pub fn unlock(l: *Locked) void {
        const core = l.core;
        const io = core.io;
        core.mutex.unlock(io);
        l.* = undefined;
    }
};

pub fn lockState(core: *Core) Locked {
    const io = core.io;
    core.mutex.lockUncancelable(io);
    return .{ .core = core };
}
pub const DeviceSelection = struct {
    device: ?Device,
};
pub const UpdateDevicesEvent = union(enum) {
    device_removed: Device,
    device_added: Device,
    device_name_changed: struct {
        old_name: StringPool.String,
        new_name: StringPool.String,
        token: StringPool.String,
    },
};

fn logAudioDeviceEvent(comptime direction: audio.Direction) *const fn (UpdateDevicesEvent) void {
    return struct {
        pub fn onEvent(event: UpdateDevicesEvent) void {
            switch (event) {
                .device_added => |device| {
                    std.log.info("audio {t} device added: {f}", .{ direction, device.name });
                },
                .device_removed => |device| {
                    std.log.info("audio {t} device removed: {f}", .{ direction, device.name });
                },
                .device_name_changed => |info| {
                    std.log.info(
                        "audio {t} device named changed from '{f}' to '{f}'",
                        .{ direction, info.old_name, info.new_name },
                    );
                },
            }
        }
    }.onEvent;
}

pub const UserAudio = struct {
    direction: audio.Direction,
    volume: f32,
    device: ?Device = null,

    selecting_devices: ?[]Device = null,
    pub fn selectInit(self: *UserAudio, core: *Core) []Device {
        if (self.selecting_devices == null) {
            const on_event = switch (self.direction) {
                .capture => logAudioDeviceEvent(.capture),
                .playout => logAudioDeviceEvent(.playout),
            };
            const directional = core.audioDirectional(self.direction);
            switch (directional.updateDevices(core.gpa, &core.audio_backend, on_event, &core.string_pool)) {
                .locked => {
                    std.log.err("unable to update devices, something else has a lock?", .{});
                },
                .result => |maybe_err| if (maybe_err) |err| {
                    // TODO: display this to the user
                    std.log.err(
                        "error while updating audio {t} devices: {f}",
                        .{ self.direction, err },
                    );
                },
            }
            self.selecting_devices = directional.lockDeviceUpdates();
        }
        return self.selecting_devices.?;
    }
    pub fn deinitSelect(self: *UserAudio, core: *Core, maybe_selection: ?DeviceSelection) void {
        std.debug.assert(self.selecting_devices != null);
        if (maybe_selection) |selection| {
            const directional = core.audioDirectional(self.direction);
            directional.unlockDeviceUpdates();
            self.device = selection.device;
            if (self.device) |d| {
                d.addReference(&core.string_pool);
            }
            self.selecting_devices = null;
        }
    }
};

pub const ActiveCall = struct {
    host_id: Host.ClientOnly.Id = undefined,
    voice_id: Channel.Id = undefined,
    status: Status = .{},
    push_future: ?Io.Future(error{ Closed, Canceled }!void) = null,
    manager_future: ?Io.Future(void) = null,

    pub const Status = ui.AtomicEnum(true, .intent, &.{
        .connecting,
        .connected,
        .disconnected,
    }, &.{.quit});

    pub fn getVoice(ac: *const ActiveCall, core: *Core) *Voice {
        return core.hosts.get(ac.host_id).?.shared.voices.get(ac.voice_id).?;
    }

    pub fn disconnect(ac: *const ActiveCall, core: *Core) void {
        _ = ac;
        const io = core.io;
        const gpa = core.gpa;
        const call = &(core.active_call orelse return);
        if (call.push_future) |*push_future| push_future.cancel(io) catch {};
        if (call.manager_future) |*manager_future| manager_future.cancel(io);
        core.media.stop(&core.string_pool, gpa);
        core.media.deinit(gpa);
        core.active_call = null;
    }
};

pub fn chatHistoryGet(
    core: *Core,
    h: *Host,
    channel_id: awebo.Channel.Id,
    from_uid: u64,
    direction: awebo.protocol.client.ChatHistoryGet.Direction,
) void {
    switch (h.client.connection_status) {
        .connecting, .connected, .disconnected, .reconnecting, .deleting => unreachable, // UI should have prevented this attempt
        .synced => {},
    }
    const conn = h.client.connection.?; // connection must be present if status == .synced

    const chg: awebo.protocol.client.ChatHistoryGet = .{
        .chat_channel = channel_id,
        .origin = 0,
        .direction = direction,
        .from_uid = switch (direction) {
            .newer => from_uid - 1,
            .older => from_uid + 1,
        },
    };

    const bytes = chg.serializeAlloc(core.gpa) catch oom();
    errdefer core.gpa.free(bytes);

    conn.tcp.queue.putOne(core.io, bytes) catch oom();
}

pub fn chatTypingNotify(core: *Core, h: *Host, c: *Channel) !void {
    // Throttle to 2 seconds
    const throttle = 2 * std.time.ns_per_s;
    const timestamp = core.now();
    if (timestamp -% h.client.last_sent_typing <= throttle) return;
    h.client.last_sent_typing = timestamp;

    switch (h.client.connection_status) {
        .connecting, .connected, .disconnected, .reconnecting, .deleting => unreachable, // UI should have prevented this attempt
        .synced => {},
    }
    const conn = h.client.connection.?; // connection must be present if status == .synced

    const ChatTypingNotify = awebo.protocol.client.ChatTypingNotify;
    const ctn: ChatTypingNotify = .{
        .channel = c.id,
    };

    const bytes = try ctn.serializeAlloc(core.gpa);
    errdefer core.gpa.free(bytes);

    try conn.tcp.queue.putOne(core.io, bytes);
}

/// On error return, the message was not scheduled for sending and should be
/// left untouched in the UI text input element, letting the user know that
/// more resources must be freed in order to be able to complete the operation.
pub fn messageSend(core: *Core, h: *Host, c: *Channel, text: []const u8) !void {
    const gpa = core.gpa;
    const io = core.io;
    const ChatMessageSend = awebo.protocol.client.ChatMessageSend;
    const cms: ChatMessageSend = .{
        .origin = core.now(),
        .channel = c.id,
        .text = text,
    };

    switch (h.client.connection_status) {
        .connecting, .connected, .disconnected, .reconnecting, .deleting => unreachable, // UI should have prevented this attempt
        .synced => {},
    }
    const conn = h.client.connection.?; // connection must be present if status == .synced

    // for max performance it would be better to do serialization work in a separate coroutine
    // but from a robustness perspective doing the work here lets us rollback gracefully
    // once we realize we don't have enough resources to complete the task
    const bytes = try cms.serializeAlloc(gpa);
    errdefer gpa.free(bytes);

    // peding_messages now owns `text` and is expected to free it once confirmation arrives
    // in case of network errors, this is where the "retry" option will also be present
    const gop = try c.kind.chat.client.pending_messages.getOrPut(gpa, cms.origin);
    errdefer _ = c.kind.chat.client.pending_messages.swapRemove(cms.origin);
    assert(!gop.found_existing);
    gop.value_ptr.* = .{
        .cms = cms,
        .push_future = try io.concurrent(@TypeOf(conn.tcp.queue).putOne, .{
            &conn.tcp.queue,
            io,
            bytes,
        }),
    };
}

pub fn channelCreate(core: *Core, cmd: *ui.ChannelCreate) !void {
    const gpa = core.gpa;
    const io = core.io;

    const msg: awebo.protocol.client.ChannelCreate = .{
        .kind = .chat,
        .name = cmd.name,
        .origin = cmd.origin,
    };

    const bytes = try msg.serializeAlloc(gpa);
    try cmd.host.client.pending_requests.put(gpa, cmd.origin, @ptrCast(&cmd.status.impl.raw));
    try cmd.host.client.connection.?.tcp.queue.putOne(io, bytes);
}

/// Returns a future representing the frist connection attempt.
pub fn hostJoin(
    core: *Core,
    identity: []const u8,
    username: []const u8,
    password: []const u8,
    fcs: *ui.FirstConnectionStatus,
) !Io.Future(error{Canceled}!void) {
    const io = core.io;
    if (core.hosts.identities.contains(identity)) return error.Duplicate;
    return io.concurrent(network.runHostManager, .{ core, .{ .join = fcs }, identity, username, password });
}

pub fn callJoin(
    core: *Core,
    host_id: HostId,
    voice_id: Channel.Id,
) !void {
    const gpa = core.gpa;
    const io = core.io;
    const host = core.hosts.get(host_id).?;
    switch (host.client.connection_status) {
        .connecting, .connected, .disconnected, .reconnecting, .deleting => unreachable, // UI should have prevented this attempt
        .synced => {},
    }
    const conn = host.client.connection.?; // connection must be present if status == .synced

    log.debug("call join: '{}'", .{voice_id});

    const cj: awebo.protocol.client.CallJoin = .{ .voice = voice_id, .origin = core.now() };
    const bytes = try cj.serializeAlloc(gpa);
    errdefer gpa.free(bytes);

    var call: ActiveCall = .{
        .host_id = host_id,
        .voice_id = voice_id,
    };

    // Attempt to push immediately, in case of contention spawn a coroutine for doing it.
    if (conn.tcp.queue.put(io, &.{bytes}, 0) catch 0 == 0) {
        call.push_future = try io.concurrent(@TypeOf(conn.tcp.queue).putOne, .{
            &conn.tcp.queue,
            io,
            bytes,
        });
    }

    if (core.active_call) |*ac| ac.disconnect(core);
    core.active_call = call;
}

var screenshare: *ScreenShare = undefined;
pub fn callBeginScreenShare(core: *Core) !void {
    // TODO: network setup will go here
    core.screenshare_intent = true;
    // getAvailableSources(core);
    screenshare = .init();
    screenshare.showPicker();
}

pub fn callLeave(core: *Core) !void {
    const ac = &(core.active_call orelse return);
    ac.disconnect(core);
}

pub fn now(core: *Core) u64 {
    const io = core.io;
    const n = Io.Clock.awake.now(io);
    return @intCast(core.start_time.durationTo(n).toNanoseconds());
}

pub fn audioDirectional(core: *Core, direction: audio.Direction) *audio.Directional {
    return switch (direction) {
        .capture => &core.audio_capture,
        .playout => &core.audio_playout,
    };
}

fn oom() noreturn {
    @panic("oom");
}

test {
    _ = awebo;
}
