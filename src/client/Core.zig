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

command_queue: Io.Queue(NetworkCommand),
refresh: *const RefreshFn,
start_time: std.time.Instant,

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
    command_queue_buffer: []NetworkCommand,
) Core {
    return .{
        .gpa = gpa,
        .io = io,
        .environ = environ,
        .start_time = std.time.Instant.now() catch @panic("need clock"),
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
    audio.processInit(&core.audio_backend) catch |err| {
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
            core, .{ .connect = h.client.host_id }, h.client.identity, h.client.username, h.client.password,
        });
    }

    while (true) {
        const msg = core.command_queue.getOne(io) catch return;
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

            .host_sync => |hs| hostSync(core, msg.host_id, hs),
            .chat_message_new => |cms| chatMessageNew(core, msg.host_id, cms),
            .media_connection_details => |mcd| mediaConnectionDetails(core, msg.host_id, mcd),
            .callers_update => |cu| callersUpdate(core, msg.host_id, cu),
            // .msg => |msg| switch (msg.bytes[0]) {
            //     else => std.debug.panic("unexpected marker: '{c}'", .{
            //         msg.bytes[0],
            //     }),
            //     awebo.protocol.server.ChannelsUpdate.marker => {
            //         try channelsUpdate(msg);
            //     },
            //     awebo.protocol.server.ClientRequestReply.marker => {
            //         try handleRequestReply(core);
            //     },
            // },

        }

        core.refresh(core, @src(), null);
    }
}

pub const NetworkCommand = struct {
    host_id: awebo.Host.ClientOnly.Id,
    cmd: union(enum) {
        host_connection_update: awebo.Host.ClientOnly.ConnectionStatus,
        caller_speaking: CallerSpeaking,

        host_sync: awebo.protocol.server.HostSync,
        chat_message_new: awebo.protocol.server.ChatMessageNew,
        media_connection_details: awebo.protocol.server.MediaConnectionDetails,
        callers_update: awebo.protocol.server.CallersUpdate,
    },

    pub const CallerSpeaking = struct {
        time_ms: u64,
        caller: awebo.Caller.Id,
    };
};

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

fn hostSync(core: *Core, id: HostId, hs: awebo.protocol.server.HostSync) void {
    var locked = lockState(core);
    defer locked.unlock();

    if (core.hosts.get(id)) |host| {
        const db = host.client.db;
        db.conn.transaction() catch db.fatal(@src());
        host.sync(core.gpa, &hs.host, hs.user_id);
        db.conn.commit() catch db.fatal(@src());
    } else {
        // Not considering this a programming error because it seems possible for
        // a message to be stuck in the queue while this host is being deleted by the user.
        log.debug("received update for host (id={}) that doesn't exist, dropping it", .{id});
        hs.deinit(core.gpa);
    }
}

fn channelsUpdate(core: *Core, msg: NetworkCommand.Msg) !void {
    const gpa = core.gpa;

    var fbs = std.io.fixedBufferStream(msg.bytes[1..]);
    const crr = try awebo.protocol.server.ChannelsUpdate.parseAlloc(gpa, fbs.reader());
    log.debug("CU: {any}", .{crr});

    std.debug.assert(crr.kind == .delta);

    var locked = lockState(core);
    defer locked.unlock();

    const h = core.hosts.get(1).?;
    for (crr.channels) |chat| {
        try h.chats.set(gpa, chat);
    }
}
fn handleRequestReply(core: *Core, msg: NetworkCommand.Msg) !void {
    var fbs = std.io.fixedBufferStream(msg.bytes[1..]);
    const crr = try awebo.protocol.server.ClientRequestReply.parseAlloc(core.gpa, fbs.reader());
    log.debug("CRR: {any}", .{crr});

    var locked = lockState(core);
    defer locked.unlock();

    switch (crr.reply_marker) {
        awebo.protocol.client.ChannelCreate.marker => {
            const h = core.hosts.get(1).?;

            if (h.client.pending_requests.get(crr.origin)) |status| {
                const server: awebo.protocol.client.ChannelCreate.Result = @enumFromInt(crr.result);
                const new: ui.ChannelCreate.Status.Enum = switch (server) {
                    .ok => .ok,
                    .name_taken => .name_taken,
                    .fail => @panic("TODO"),
                };
                @atomicStore(u8, status, @intFromEnum(new), .release);
            }
        },
        else => std.debug.panic("unhandled ClientRequestReply marker '{c}'", .{
            crr.reply_marker,
        }),
    }
}

fn chatMessageNew(core: *Core, host_id: HostId, cmn: awebo.protocol.server.ChatMessageNew) void {
    var locked = lockState(core);
    defer locked.unlock();

    const h = core.hosts.get(host_id).?;
    const c = &h.channels.get(cmn.channel).?.kind.chat;
    const db = h.client.db;
    db.conn.transaction() catch db.fatal(@src());
    c.messages.add(core.gpa, h.client.db, cmn.channel, cmn.msg) catch oom();
    db.conn.commit() catch db.fatal(@src());

    if (cmn.origin != 0) {
        if (h.client.pending_messages.orderedRemove(cmn.origin)) {
            core.refresh(core, @src(), 0);
        }
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
            switch (directional.updateDevices(core.gpa, on_event, &core.string_pool)) {
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
    const gop = try h.client.pending_messages.getOrPut(gpa, cms.origin);
    errdefer _ = h.client.pending_messages.swapRemove(cms.origin);
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
    std.debug.panic("unimplemented", .{});
    try network.command_queue.putOne(io, .{
        .channel_create = .{
            .hc = cmd.host.client.connection orelse return error.NotConnected,
            .cmd = .{
                .origin = cmd.origin,
                .kind = cmd.kind,
                .name = cmd.name,
            },
        },
    });
    try cmd.host.client.pending_requests.put(gpa, cmd.origin, @ptrCast(&cmd.status.impl.raw));
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

pub fn callBeginScreenShare(core: *Core) !void {
    // TODO: network setup will go here
    core.screenshare_intent = true;
}

pub fn callLeave(core: *Core) !void {
    const ac = &(core.active_call orelse return);
    ac.disconnect(core);
}

pub fn now(core: *Core) u64 {
    const n = std.time.Instant.now() catch @panic("need a working clock");
    return n.since(core.start_time);
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
