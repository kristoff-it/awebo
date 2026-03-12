const Core = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const log = std.log.scoped(.core);
const Io = std.Io;
const Allocator = std.mem.Allocator;
const zeit = @import("zeit");
const cli = @import("../cli.zig");
const awebo = @import("../awebo.zig");
const Host = awebo.Host;
const HostId = awebo.Host.ClientOnly.Id;
const Channel = awebo.Channel;
const Chat = Channel.Chat;
const Voice = Channel.Voice;
const network = @import("Core/network.zig");
const persistence = @import("Core/persistence.zig");
pub const ScreenCapture = @import("media/ScreenCapture.zig");
pub const WebcamCapture = @import("media/WebcamCapture.zig");
pub const Audio = @import("media/Audio.zig");
pub const VideoStream = @import("media/VideoStream.zig");

io: Io,
gpa: Allocator,
environ: *std.process.Environ.Map,
/// Set to true once data has been loaded from disk.
loaded: std.atomic.Value(bool) = .init(false),
command_queue: Io.Queue(Event),
refresh: *const RefreshFn,
start_time: Io.Timestamp,
cache_path: []const u8 = undefined,
tz: zeit.TimeZone,

/// Protects all the fields after this one.
mutex: Io.Mutex = .init,
/// Set to an error message when the core logic encounters an unrecoverable error.
/// The application should show an error dialog and shutdown when this happens.
failure: UnrecoverableFailure = .none,
hosts: Hosts = .{},
active_host: awebo.Host.ClientOnly.Id = 0,
message_window: awebo.Channel.Chat.MessageWindow = .{},

cfg: std.StringHashMapUnmanaged([]const u8) = .{},

active_call: ?ActiveCall = null,

audio: Audio,
screen_capture: ScreenCapture = undefined,
webcam_capture: WebcamCapture,

// this is only set to pass the message to `chat_panel`
search_messages_reply: ?awebo.protocol.server.SearchMessagesReply = null,

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

// This init function should be kept lightweight, we run it in the main thread
// and it blocks showing the initial spinner animation. Core.run will perform
// secondary initialization (eg starting audio) in a separate thread.
pub fn init(
    gpa: Allocator,
    io: Io,
    environ: *std.process.Environ.Map,
    refreshFn: *const RefreshFn,
    command_queue_buffer: []Event,
) !Core {
    return .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .start_time = .now(io, .awake),
        .refresh = refreshFn,
        .command_queue = .init(command_queue_buffer),
        .tz = zeit.local(gpa, io, .{}) catch |err| {
            cli.fatal("unable to load local timezone: {t}", .{err});
        },
        .webcam_capture = undefined, // inited in Core.run
        .audio = undefined, // inited in Core.run
    };
}

// Should only denit what is inited in init().
// Resources inited in Core.run should be deinited by Core.run.
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
    const capture_buf = core.gpa.alloc(f32, 4096) catch oom();
    const playback_buf_left = core.gpa.alloc(f32, 4096) catch oom();
    const playback_buf_right = core.gpa.alloc(f32, 4096) catch oom();
    core.audio.init(capture_buf, .{ playback_buf_left, playback_buf_right });
    defer core.audio.deinit();

    log.debug("starting screen capture support", .{});
    core.screen_capture.init(core.gpa);

    log.debug("discovering camera devices", .{});
    core.webcam_capture = .init();
    core.webcam_capture.discoverDevicesAndListen();
    defer core.webcam_capture.deinit();

    log.debug("load state and begin connecting to hosts", .{});
    var first_connect_group: Io.Group = .init;
    defer first_connect_group.cancel(io);
    {
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

    // Done loading, we can now show the main application screen.
    core.loaded.store(true, .unordered);

    defer {
        if (core.active_call) |*ac| {
            ac.disconnect(core);
        }
    }

    while (true) {
        const event = core.command_queue.getOne(io) catch return;
        switch (event) {
            .network => |msg| {
                // log.debug("from host {} got {any}", .{ msg.host_id, msg.cmd });
                switch (msg.cmd) {
                    .host_update => |hcu| hostUpdate(core, msg.host_id, hcu),
                    .caller_speaking => |cs| {
                        var locked = lockState(core);
                        defer locked.unlock();
                        if (core.active_call) |*ac| {
                            const caller = ac.callers.get(cs.caller orelse ac.caller_id orelse continue) orelse continue;
                            caller.audio.speaking_last_ns = cs.time_ns;
                        }
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
            host_update: awebo.Host.ClientOnly.Status,
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
            time_ns: u64,
            caller: ?awebo.Caller.Id, // null means ourselves
        };
    };
};

pub fn putEvent(core: *Core, event: Event) error{ Canceled, Closed }!void {
    return core.command_queue.putOne(core.io, event);
}

fn hostUpdate(core: *Core, id: HostId, hu: awebo.Host.ClientOnly.Status) void {
    var locked = lockState(core);
    defer locked.unlock();

    const host = core.hosts.get(id).?;
    host.client.status = hu;
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

    if (core.active_call) |*ac| if (cu.caller.voice == ac.voice_id) {
        // if we see ourselves join, we know we're in
        if (cu.action == .join and cu.caller.id == h.client.id) {
            ac.caller_id = cu.caller.id;
            _ = ac.status.updateCompare(core, @src(), .connecting, .connected);
        }

        switch (cu.action) {
            .join => {
                const entry = ac.callers.getOrPut(core.gpa, cu.caller.id) catch oom();
                log.debug("ACTIVE CALL JOIN cid = {} you = {}", .{
                    cu.caller.id,
                    cu.caller.id == h.client.id,
                });
                assert(!entry.found_existing);
                entry.value_ptr.* = .{
                    .audio = Audio.Caller.create(core.gpa, core) catch oom(),
                    .screen = null,
                };
            },
            .update => {},
            .leave => {
                if (ac.callers.fetchSwapRemove(cu.caller.id)) |entry| {
                    entry.value.audio.destroy(core.gpa, &core.audio);
                    if (entry.value.screen) |s| s.destroy(core.gpa);
                }
            },
        }
    };

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

    // Only trust the server if we have expressed the intent to join a call.
    // The intent is represented by having a non-null core.active_call.
    const ac = &(core.active_call orelse {
        log.debug(
            "ignoring media connection info as we don't want to be in a call anymore",
            .{},
        );
        return;
    });

    // Only trust the server if the call is in the host and channel we want to join.
    if (ac.host_id != host_id or ac.voice_id != mcd.voice) {
        log.debug(
            "ignoring info for channel we don't care about",
            .{},
        );
        return;
    }

    // Ignore the message if the user has already decided to quit the call.
    if (ac.status.updateCompare(core, @src(), .intent, .connecting) != .intent) {
        log.debug(
            "ignoring media connection info, already connected or quit",
            .{},
        );
    }

    // Reaching this point means:
    // - We have an active intent to be in a call.
    // - The right server has given us MCD for the right channel.
    // - The active_call has successfully transitioned state to 'connecting'.

    const host = core.hosts.get(host_id).?;
    if (host.client.callers.getVoiceRoom(ac.voice_id)) |callers| {
        for (callers) |c| {
            const gop = ac.callers.getOrPut(core.gpa, c) catch oom();
            if (!gop.found_existing) {
                gop.value_ptr.* = .{
                    .audio = Audio.Caller.create(core.gpa, core) catch oom(),
                    .screen = null,
                };
            }
        }
    }

    core.audio.capture_packets.reset();
    core.screen_capture.packets.reset();

    // Activate audio streams, which we know will not fail for missing
    // microphone permissions because callJoin esures it.
    core.audio.callBegin();
    ac.manager_future = io.concurrent(network.runHostMediaManager, .{
        core,
        host_id,
        host.client.status.synced,
        host.client.id,
        mcd.nonce,
    }) catch @panic("no concurrency");
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

pub const ActiveCall = struct {
    host_id: Host.ClientOnly.Id = undefined,
    voice_id: Channel.Id = undefined,
    caller_id: ?awebo.Caller.Id = null,
    status: Status = .{},
    push_future: ?Io.Future(error{ Closed, Canceled }!void) = null,
    manager_future: ?Io.Future(void) = null,
    callers: std.AutoArrayHashMapUnmanaged(awebo.Caller.Id, struct {
        audio: *Audio.Caller,
        screen: ?*VideoStream, // created when the first frame is received
        // camera: *Video.Caller,
    }),

    /// The user has pressed the mute button and expressed the intent of
    /// staying muted. The server might apply server-side mute but, once
    /// that ends, this variable is the source of truth for whether to
    /// unmute the audio interface or not.
    ///
    /// Lastly, the audio interface also has a muted state but that
    /// represents the state of the audio device, not the user intent. For
    /// example when we are affected by server side mute the audio
    /// interface will be set to muted as well, but this variable will be
    /// still set to `unmuted`, which should result in the audio device
    /// becoming unmuted once server mute ends.
    muted: Audio.DeviceMuteState = .unmuted,
    screenshare: bool = false,

    pub const Status = ui.AtomicEnum(true, .intent, &.{
        .connecting,
        .connected,
        .disconnected,
    }, &.{.quit});

    pub fn getVoice(ac: *const ActiveCall, core: *Core) *Voice {
        return core.hosts.get(ac.host_id).?.shared.voices.get(ac.voice_id).?;
    }

    pub fn screenshareBegin(ac: *ActiveCall, core: *Core) void {
        assert(!ac.screenshare);
        core.screen_capture.showOsPicker();
        ac.screenshare = true;
    }

    pub fn screenshareEnd(ac: *ActiveCall, core: *Core) void {
        assert(ac.screenshare);
        core.screen_capture.stopCapture();
        ac.screenshare = false;
    }

    pub fn disconnect(ac: *const ActiveCall, core: *Core) void {
        _ = ac;
        const io = core.io;
        const call = &(core.active_call orelse return);
        core.audio.callEnd();
        log.debug("stopped capturing, cleaning up futures", .{});
        if (call.push_future) |*push_future| push_future.cancel(io) catch {};
        log.debug("push future done", .{});
        if (call.manager_future) |*manager_future| manager_future.cancel(io);
        log.debug("manager future done", .{});
        for (call.callers.values()) |caller| {
            caller.audio.destroy(core.gpa, &core.audio);
            if (caller.screen) |s| s.destroy(core.gpa);
        }

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
    const conn = h.client.status.synced; // UI must prevent chatHistoryGet when disconnected

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

    const conn = switch (h.client.status) {
        .synced => |conn| conn,
        else => return, // do nothing if we're not synced
    };

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

    const conn = h.client.status.synced; // UI must prevent messageSend if disconnected

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
    try cmd.host.client.status.synced.tcp.queue.putOne(io, bytes);
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
    return io.concurrent(network.runHostManager, .{
        core,
        .{ .join = fcs },
        identity,
        username,
        password,
    });
}

pub fn callJoin(
    core: *Core,
    host_id: HostId,
    voice_id: Channel.Id,
) !Core.Audio.CapturePermission {
    const gpa = core.gpa;
    const io = core.io;

    // We ensure now that we can use the microphone but the actual audio
    // activation will happen once we receve MediaConnectionDetails from
    // the host.
    const permission = core.audio.ensureCapturePermission();
    if (permission != .granted) return permission;

    const host = core.hosts.get(host_id).?;
    const conn = host.client.status.synced; // UI must prevent callJoin in other states

    log.debug("call join: '{}'", .{voice_id});
    const cj: awebo.protocol.client.CallJoin = .{
        .voice = voice_id,
        .origin = core.now(),
        .muted = core.audio.capture_mute_state == .muted,
        .deafened = core.audio.playback_mute_state == .muted,
    };
    const bytes = try cj.serializeAlloc(gpa);
    errdefer gpa.free(bytes);

    var call: ActiveCall = .{
        .host_id = host_id,
        .voice_id = voice_id,
        .callers = .empty,
    };

    // Attempt to push immediately, in case of contention spawn a coroutine for doing it.
    if (0 == conn.tcp.queue.put(io, &.{bytes}, 0) catch return .granted) {
        call.push_future = try io.concurrent(@TypeOf(conn.tcp.queue).putOne, .{
            &conn.tcp.queue,
            io,
            bytes,
        });
    }

    if (core.active_call) |*ac| ac.disconnect(core);
    core.active_call = call;
    return .granted;
}

pub fn callSetMute(core: *Core, new_state: Audio.DeviceMuteState) void {
    const ac = &(core.active_call orelse return);
    const transition = core.audio.setCaptureMute(new_state) catch {
        log.debug("unable to toggle capture mute state", .{});
        return;
    };
    ac.muted = new_state;
    if (transition) {
        const host = core.hosts.get(ac.host_id).?;
        const msg: awebo.protocol.client.CallUpdate = .{
            .muted = new_state == .muted,
            .deafened = false,
            .screenshare = ac.screenshare,
        };
        const bytes = msg.serializeAlloc(core.gpa) catch oom();
        host.client.status.synced.tcp.queue.putOne(core.io, bytes) catch {
            log.debug("unable to push message!", .{});
        };
        core.refresh(core, @src(), 0);
    }
}

pub fn callLeave(core: *Core) !void {
    const io = core.io;
    const gpa = core.gpa;

    const ac = &(core.active_call orelse return);
    const host_id = ac.host_id;
    ac.disconnect(core);

    const host = core.hosts.get(host_id).?;
    const msg: awebo.protocol.client.CallLeave = .{};
    const bytes = try msg.serializeAlloc(gpa);
    try host.client.status.synced.tcp.queue.putOne(io, bytes);
}

pub fn now(core: *Core) u64 {
    const io = core.io;
    const n = Io.Clock.awake.now(io);
    return @intCast(core.start_time.durationTo(n).toNanoseconds());
}

fn oom() noreturn {
    @panic("oom");
}

test {
    _ = awebo;
    _ = Audio;
}
