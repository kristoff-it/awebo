const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Allocator = std.mem.Allocator;
const awebo = @import("../awebo.zig");
const Host = awebo.Host;
const HostId = awebo.Host.ClientOnly.Id;
const Chat = awebo.channels.Chat;
const Voice = awebo.channels.Voice;
const media = @import("media.zig");
const network = @import("core/network.zig");
const persistence = @import("core/persistence.zig");

pub const global = @import("global.zig");
pub const audio = @import("audio.zig");
pub const ui = @import("core/ui.zig");
pub const Device = @import("Device.zig");
pub const PoolString = @import("PoolString.zig");

const log = std.log.scoped(.core);

pub const State = @TypeOf(___state);
pub const RefreshFn = fn (src: std.builtin.SourceLocation, id: ?u64) void;

pub const gpa = std.heap.smp_allocator;
var threaded: Io.Threaded = undefined;
pub const io = threaded.io();

pub var refresh: *const RefreshFn = undefined;
var start_time: std.time.Instant = undefined;

pub fn init(_refresh: *const RefreshFn) void {
    threaded = .init(gpa);
    refresh = _refresh;
    start_time = std.time.Instant.now() catch @panic("need clock");
}

pub fn run() void {
    log.debug("started", .{});
    defer log.debug("goodbye", .{});

    log.debug("starting audio support", .{});
    audio.processInit() catch {
        var locked = lockState();
        defer locked.unlock();
        const state = locked.state;

        state.failure = "error starting audio";
        return;
    };

    log.debug("load state and begin connecting to hosts", .{});
    var first_connect_group: Io.Group = .init;
    defer first_connect_group.cancel(io);
    {
        var locked = lockState();
        defer locked.unlock();
        const state = locked.state;
        persistence.load(io, gpa, state) catch return;
        const hosts = state.hosts.items.values();
        for (hosts) |h| first_connect_group.async(io, network.runHostManager, .{
            .{ .connect = h.client.host_id }, h.client.identity, h.client.username, h.client.password,
        });
    }

    while (true) {
        const msg = command_queue.getOne(io) catch return;
        log.debug("from host {} got {any}", .{ msg.host_id, msg.cmd });
        switch (msg.cmd) {
            .host_connection_update => |hcu| hostConnectionUpdate(msg.host_id, hcu),
            .caller_speaking => |cs| {
                var locked = lockState();
                defer locked.unlock();
                const state = locked.state;

                const host = state.hosts.get(msg.host_id).?;
                const caller = host.client.callers.get(cs.caller) orelse continue;
                caller.client.speaking_last_ms = cs.time_ms;
            },

            .host_sync => |hs| hostSync(msg.host_id, hs),
            .chat_message_new => |cms| chatMessageNew(msg.host_id, cms),
            .media_connection_details => |mcd| mediaConnectionDetails(msg.host_id, mcd),
            .callers_update => |cu| callersUpdate(msg.host_id, cu),
            // .msg => |msg| switch (msg.bytes[0]) {
            //     else => std.debug.panic("unexpected marker: '{c}'", .{
            //         msg.bytes[0],
            //     }),
            //     awebo.protocol.server.ChannelsUpdate.marker => {
            //         try channelsUpdate(msg);
            //     },
            //     awebo.protocol.server.ClientRequestReply.marker => {
            //         try handleRequestReply(msg);
            //     },
            // },

        }

        refresh(@src(), null);
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

fn hostConnectionUpdate(id: HostId, hcu: awebo.Host.ClientOnly.ConnectionStatus) void {
    var locked = lockState();
    defer locked.unlock();
    const host = locked.state.hosts.get(id).?;

    host.client.connection_status = hcu;
    switch (hcu) {
        .connected => |hc| host.client.connection = hc,
        else => {},
    }

    refresh(@src(), 0);
}

fn hostSync(id: HostId, hs: awebo.protocol.server.HostSync) void {
    var locked = lockState();
    defer locked.unlock();
    locked.state.hosts.sync(id, hs);
}

fn channelsUpdate(msg: NetworkCommand.Msg) !void {
    var fbs = std.io.fixedBufferStream(msg.bytes[1..]);
    const crr = try awebo.protocol.server.ChannelsUpdate.parseAlloc(gpa, fbs.reader());
    log.debug("CU: {any}", .{crr});

    std.debug.assert(crr.kind == .delta);

    var locked = lockState();
    defer locked.unlock();
    const state = locked.state;

    const h = state.hosts.get(1).?;
    for (crr.channels) |chat| {
        try h.chats.set(gpa, chat);
    }
}
fn handleRequestReply(msg: NetworkCommand.Msg) !void {
    var fbs = std.io.fixedBufferStream(msg.bytes[1..]);
    const crr = try awebo.protocol.server.ClientRequestReply.parseAlloc(gpa, fbs.reader());
    log.debug("CRR: {any}", .{crr});

    var locked = lockState();
    defer locked.unlock();
    const state = locked.state;

    switch (crr.reply_marker) {
        awebo.protocol.client.ChannelCreate.marker => {
            const h = state.hosts.get(1).?;

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

fn chatMessageNew(host_id: HostId, cmn: awebo.protocol.server.ChatMessageNew) void {
    var locked = lockState();
    defer locked.unlock();
    const state = locked.state;

    const h = state.hosts.get(host_id).?;
    const c = h.chats.get(cmn.chat).?;
    c.client.messages.add(gpa, cmn.msg) catch oom();

    if (cmn.origin != 0) {
        if (h.client.pending_messages.orderedRemove(cmn.origin)) {
            refresh(@src(), 0);
        }
    }
}

fn callersUpdate(host_id: HostId, cu: awebo.protocol.server.CallersUpdate) void {
    var locked = lockState();
    defer locked.unlock();
    const state = locked.state;

    const h = state.hosts.get(host_id).?;

    if (cu.action == .join and cu.caller.user == h.client.user_id) {
        if (state.active_call) |*ac| {
            _ = ac.status.updateCompare(@src(), .connecting, .connected);
        }
    }

    switch (cu.action) {
        .join, .update => h.client.callers.set(gpa, cu.caller) catch oom(),
        .leave => h.client.callers.remove(cu.caller.id) catch oom(),
    }
}

fn mediaConnectionDetails(host_id: HostId, mcd: awebo.protocol.server.MediaConnectionDetails) void {
    var locked = lockState();
    defer locked.unlock();
    const state = locked.state;

    if (state.active_call) |*ac| {
        if (ac.host_id == host_id and ac.voice_id == mcd.voice) {
            if (ac.status.updateCompare(@src(), .intent, .connecting) == .intent) {
                errdefer {
                    ac.deinit();
                    state.active_call = null;
                }

                // Activates audio streams
                media.activate(io, state) catch |err| std.debug.panic("err staring audio: {t}", .{err});

                // Asks to the network layer to start the UDP data transfer
                // for this call.
                const host = state.hosts.get(host_id).?;
                _ = io.concurrent(network.runHostMediaManager, .{
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
    state: *State,

    pub fn unlock(l: *Locked) void {
        mutex.unlock(io);
        if (std.debug.runtime_safety) {
            l.state = undefined;
        }
    }
};

pub var command_queue = Io.Queue(NetworkCommand).init(&qbuf);
pub fn lockState() Locked {
    mutex.lockUncancelable(io);
    return .{ .state = &___state };
}
pub const DeviceSelection = struct {
    device: ?Device,
};
pub const UpdateDevicesEvent = union(enum) {
    device_removed: Device,
    device_added: Device,
    device_name_changed: struct {
        old_name: PoolString,
        new_name: PoolString,
        token: PoolString,
    },
};

var qbuf: [1024]NetworkCommand = undefined;
var mutex: Io.Mutex = .init;
var ___state: struct { // ___ = no touchy
    /// Set to an error message when the core logic encounters an unrecoverable error.
    /// The application should show an error dialog and shutdown when this happens.
    failure: ?[]const u8 = null,
    /// Set to true once data has been loaded from disk.
    loaded: bool = false,
    hosts: struct {
        last_id: u32 = 0,
        items: std.AutoArrayHashMapUnmanaged(Host.ClientOnly.Id, Host) = .{},
        identities: std.StringHashMapUnmanaged(Host.ClientOnly.Id) = .{},

        pub fn get(hosts: @This(), id: Host.ClientOnly.Id) ?*Host {
            return hosts.items.getPtr(id);
        }

        pub fn add(
            hosts: *@This(),
            identity: []const u8,
            username: []const u8,
            password: []const u8,
        ) error{ DuplicateHost, OutOfMemory }!*Host {
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
            persistence.updateHosts(hosts.items.values()) catch |err| {
                log.err("error while saving config: {t}", .{err});
            };
            return gop.value_ptr;
        }

        pub fn sync(
            hosts: *@This(),
            host_id: HostId,
            hs: awebo.protocol.server.HostSync,
        ) void {
            // const id = hosts.identities.get(identity) orelse {
            //     log.info("ignoring host sync for host we must have deleted: '{s}'", .{identity});
            //     var hsd = hs;
            //     hsd.deinit(gpa);
            //     return;
            // };

            const h = hosts.get(host_id) orelse @panic("host index out of sync!");

            const old_client = h.client;
            const old_identity = h.client.identity;

            h.* = hs.host;
            h.client = old_client;
            h.client.identity = old_identity;
            h.client.user_id = hs.user_id;
            h.client.connection = old_client.connection;
            h.client.connection_status = .synced;

            for ([_][]const awebo.Message{ hs.messages_front, hs.messages_back }) |messages| for (messages) |msg| {
                const ch = h.chats.get(msg.channel) orelse continue;
                ch.client.messages.add(gpa, msg) catch oom();
            };
        }
    } = .{},

    audio: struct {
        user: struct {
            capture: UserAudio = .{ .direction = .capture, .volume = 0.5 },
            playout: UserAudio = .{ .direction = .playout, .volume = 0.5 },
        } = .{},
    } = .{},

    active_call: ?ActiveCall = null,

    // This is temporarily put in the main state scope so that it can be
    // tested locally without needing to enter a voice channel first.
    // Once the lcoal work is done and we decide to start wiring it over
    // the network, it will have to be moved into `active_call` and
    // integrated with the call lifecycle.
    screenshare_intent: bool = false,

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
        pub fn selectInit(self: *UserAudio) []Device {
            if (self.selecting_devices == null) {
                const on_event = switch (self.direction) {
                    .capture => logAudioDeviceEvent(.capture),
                    .playout => logAudioDeviceEvent(.playout),
                };
                const directional = global.directional(self.direction);
                switch (directional.updateDevices(gpa, on_event)) {
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
        pub fn deinitSelect(self: *UserAudio, maybe_selection: ?DeviceSelection) void {
            std.debug.assert(self.selecting_devices != null);
            if (maybe_selection) |selection| {
                const directional = global.directional(self.direction);
                directional.unlockDeviceUpdates();
                self.device = selection.device;
                if (self.device) |d| {
                    d.addReference();
                }
                self.selecting_devices = null;
            }
        }
    };

    pub const ActiveCall = struct {
        host_id: Host.ClientOnly.Id = undefined,
        voice_id: Voice.Id = undefined,
        status: Status = .{},
        push_future: ?Io.Future(error{Canceled}!void) = null,
        manager_future: ?Io.Future(void) = null,

        pub const Status = ui.AtomicEnum(true, .intent, &.{
            .connecting,
            .connected,
            .disconnected,
        }, &.{.quit});

        pub fn getVoice(ac: *const ActiveCall, state: *State) *Voice {
            return state.hosts.get(ac.host_id).?.shared.voices.get(ac.voice_id).?;
        }

        pub fn disconnect(ac: *ActiveCall, state: *State) void {
            _ = ac;
            const call = &(state.active_call orelse return);
            if (call.push_future) |*push_future| push_future.cancel(io) catch {};
            if (call.manager_future) |*manager_future| manager_future.cancel(io);
            media.stop();
            media.deactivate();
            state.active_call = null;
        }
    };

    /// On error return, the message was not scheduled for sending and should be
    /// left untouched in the UI text input element, letting the user know that
    /// more resources must be freed in order to be able to complete the operation.
    pub fn messageSend(state: *State, h: *Host, c: *Chat, text: []const u8) !void {
        const ChatMessageSend = awebo.protocol.client.ChatMessageSend;
        _ = state;
        const cms: ChatMessageSend = .{
            .origin = now(),
            .chat = c.id,
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

    pub fn channelCreate(state: *State, cmd: *ui.ChannelCreate) !void {
        _ = state;
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
        state: *State,
        identity: []const u8,
        username: []const u8,
        password: []const u8,
        fcs: *ui.FirstConnectionStatus,
    ) !Io.Future(void) {
        if (state.hosts.identities.contains(identity)) return error.Duplicate;
        return io.concurrent(network.runHostManager, .{ .{ .join = fcs }, identity, username, password });
    }

    pub fn callJoin(state: *State, host_id: HostId, voice_id: Voice.Id) !void {
        const host = state.hosts.get(host_id).?;
        switch (host.client.connection_status) {
            .connecting, .connected, .disconnected, .reconnecting, .deleting => unreachable, // UI should have prevented this attempt
            .synced => {},
        }
        const conn = host.client.connection.?; // connection must be present if status == .synced

        log.debug("call join: '{}'", .{voice_id});

        const cj: awebo.protocol.client.CallJoin = .{ .voice = voice_id, .origin = now() };
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

        if (state.active_call) |*ac| ac.disconnect(state);
        state.active_call = call;
    }

    pub fn callBeginScreenShare(state: *State) !void {
        // TODO: network setup will go here
        state.screenshare_intent = true;
    }

    pub fn callLeave(state: *State) !void {
        const ac = &(state.active_call orelse return);
        ac.disconnect(state);
    }
} = .{};

pub fn now() u64 {
    const n = std.time.Instant.now() catch @panic("need a working clock");
    return n.since(start_time);
}

fn oom() noreturn {
    @panic("oom");
}
