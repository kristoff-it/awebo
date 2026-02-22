const Audio = @This();

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const awebo = @import("../../awebo.zig");
const Core = @import("../Core.zig");
const RingBuffer = @import("../RingBuffer.zig").RingBuffer;
const log = std.log.scoped(.audio);

const SourceKind = enum(u32) { mono = 1, stereo = 2 };

const playback_rate: f64 = 48000.0;
const playback_channels: u32 = 2;

const capture_rate: f64 = 48000.0;
const capture_channels: u32 = 1;

/// Keyed by the device unique ID.
devices: std.StringArrayHashMapUnmanaged(Device),

/// Index of the selected input device in awebo.
/// Null means system default, the device might not be connected.
capture_selected: ?usize = null,
/// Index of the concrete input device used by default by the OS.
/// Null means that we haven't discovered this information yet.
capture_default: ?usize = null,
/// Volume from awebo user settings
capture_volume: f32 = 1.0,
capture_stream: Stream(f32, 1),
capture_encoder: *awebo.opus.Encoder,

/// Same as input, but for the playback device
playback_selected: ?usize = null,
playback_default: ?usize = null,
playback_volume: f32 = 1.0,
playback_stream: Stream(f32, 2),
playback_decoder: *awebo.opus.Decoder,

/// Os interface
os: switch (builtin.target.os.tag) {
    .macos => MacOsInterface,
    else => DummyInterface,
},

pub const Device = struct {
    id: [:0]const u8,
    name: [:0]const u8,
    channels_in_count: u32,
    channels_out_count: u32,
    default_in: bool,
    default_out: bool,
    connected: bool,
    // OS specific device information
    os: switch (builtin.target.os.tag) {
        .macos => MacOsInterface.MacOsDevice,
        else => DummyInterface.DummyDevice,
    },

    pub fn format(d: Device, w: *Io.Writer) !void {
        try w.print("AudioDevice(id: '{s}', name: '{s}', in: {}, out: {}, connected: {} os: {f})", .{
            d.id, d.name, d.channels_in_count, d.channels_out_count, d.connected, d.os,
        });
    }
};

/// This type is kept by Core.ActiveCall in a hashmap where
/// each entry represents a different caller.
/// Heap allocation ensures a stable pointer for the OS audio callback.
pub const Caller = struct {
    core: *Core,
    speaking_last_ns: u64 = 0,
    decoder: *awebo.opus.Decoder,
    packets: JitterBuffer,
    voice: Stream(f32, 1),
    os: switch (builtin.target.os.tag) {
        .macos => MacOsInterface.MacOsCaller,
        else => DummyInterface.DummyCaller,
    },

    pub fn create(gpa: Allocator, core: *Core) !*Caller {
        const caller = try gpa.create(Caller);
        log.debug("caller create = {*}", .{caller});
        caller.* = .{
            .core = core,
            .decoder = try .create(),
            .packets = .init(try gpa.alloc(*JitterBuffer.Packet, 16)),
            .voice = .init(.{try gpa.alloc(f32, 4096)}),
            .os = .init(caller, &core.audio),
        };
        return caller;
    }

    pub fn destroy(c: *Caller, gpa: Allocator, audio: *Audio) void {
        c.decoder.destroy();
        c.voice.deinit(gpa);
        c.os.deinit(audio);
        gpa.destroy(c);
    }

    /// Called by the OS audio thread to get new audio data
    fn playbackSourceMonoFill(caller: *Caller, samples: [*]f32, frame_count: u32) callconv(.c) void {
        const voice = &caller.voice.channels[0];
        const playback_count = voice.len();
        const s = samples[0..@min(frame_count, playback_count)];
        caller.voice.channels[0].readFirstAssumeCount(s, s.len);

        if (frame_count > playback_count) {
            assert(voice.len() == 0); // invariant
            switch (caller.packets.nextPacket()) {
                .starting => {
                    log.debug("starting", .{});
                    @memset(samples[playback_count..frame_count], 0);
                },
                .buffering => {
                    log.debug("buffering", .{});
                    // TODO: we should inderact with opus. maybe.
                    @memset(samples[playback_count..frame_count], 0);
                },
                .playing => |maybe_packet| {
                    const written = if (maybe_packet) |p| caller.decoder.decodeFloat(
                        p.opus_data,
                        voice.data,
                        false,
                    ) catch |err| {
                        log.debug("error parsing opus data: {t}", .{err});
                        @memset(samples[playback_count..frame_count], 0);
                        return;
                    } else caller.decoder.decodeMissing(voice.data, false);

                    const remaining = frame_count - playback_count;
                    assert(written > remaining);

                    @memcpy(samples[playback_count..frame_count], voice.data.ptr);
                    voice.write_index = written;
                    voice.read_index = remaining;

                    return;
                },
            }
        }
    }
};

/// Must call discoverDevicesAndListen() next to subscribe to device update notifications.
/// AudioCapture must be kept stored in Core as it uses fieldParentPtr to access it.
pub fn init(capture_buf: []f32, playback_bufs: [2][]f32) !Audio {
    assert(playback_bufs[0].len == playback_bufs[1].len);
    const capture_encoder = try awebo.opus.Encoder.create();
    const playback_decoder = try awebo.opus.Decoder.create();
    return .{
        .capture_encoder = capture_encoder,
        .capture_stream = .init(.{capture_buf}),
        .playback_stream = .init(playback_bufs),
        .playback_decoder = playback_decoder,
        .devices = .empty,
        .os = .init(),
    };
}

pub fn deinit(audio: *Audio) void {
    if (builtin.mode != .Debug) return;

    audio.os.deinit(audio);

    const core: *Core = @alignCast(@fieldParentPtr("audio", audio));
    for (audio.devices.values()) |dev| {
        core.gpa.free(dev.id);
        core.gpa.free(dev.name);
    }

    audio.devices.deinit(core.gpa);
}

pub fn discoverDevicesAndListen(audio: *Audio) void {
    audio.os.discoverDevicesAndListen(audio);
}

pub fn playbackStart(audio: *Audio) void {
    const device = if (audio.playback_selected) |idx| &audio.devices.values()[idx] else null;
    _ = audio.os.playbackStart(audio, device);
}

pub fn playbackStop(audio: *Audio) void {
    audio.os.playbackStop();
}

pub fn captureStart(audio: *Audio) void {
    log.debug("captureStart", .{});

    const device = if (audio.capture_selected) |idx| &audio.devices.values()[idx] else null;
    _ = audio.os.captureStart(audio, device);
}

pub fn captureStop(audio: *Audio) void {
    log.debug("captureStop", .{});
    audio.os.captureStop();
}

/// Called by OS APIs to fill the playback buffer from our audio data.
fn playbackFill(audio: *Audio, left: [*]f32, right: [*]f32, frame_count: u32) callconv(.c) void {
    // const capture_count = audio.capture_stream.channels[0].len();
    // const l = left[0..@min(frame_count, capture_count)];
    // audio.capture_stream.channels[0].readFirst(l, l.len) catch unreachable;
    // @memcpy(right, l);

    const core: *Core = @alignCast(@fieldParentPtr("audio", audio));
    audio.playback_stream.mutex.lockUncancelable(core.io);
    defer {
        // cb.condition.signal(io);
        audio.playback_stream.mutex.unlock(core.io);
    }

    const playback_count = audio.playback_stream.channels[0].len();
    const l = left[0..@min(frame_count, playback_count)];
    const r = right[0..@min(frame_count, playback_count)];

    audio.playback_stream.channels[0].readFirstAssumeCount(l, l.len);
    audio.playback_stream.channels[1].readFirstAssumeCount(r, r.len);

    if (frame_count > playback_count) {
        @memset(left[playback_count..frame_count], 0);
        @memset(right[playback_count..frame_count], 0);
    }
}

fn playbackSourceStereoFill(audio: *Audio, source_id: u32, left: [*]f32, right: [*]f32, frame_count: u32) callconv(.c) void {
    _ = audio;
    _ = source_id;
    _ = left;
    _ = right;
    _ = frame_count;
}

/// Called by OS APIs to let us take audio data from the capture buffer.
fn capturePush(audio: *Audio, frames: [*]f32, frame_count: u32) callconv(.c) void {
    const core: *Core = @alignCast(@fieldParentPtr("audio", audio));
    audio.capture_stream.mutex.lockUncancelable(core.io);
    defer {
        audio.capture_stream.condition.signal(core.io);
        audio.capture_stream.mutex.unlock(core.io);
    }

    audio.capture_stream.channels[0].writeSliceAssumeCapacity(frames[0..frame_count]);
}

/// Called by the OS interface whenever a device is added, removed, or its
/// default status changes.  `raw_id` and `raw_name` are duped on first insert.
fn upsertDevice(audio: *Audio, device: *const Device) void {
    const core: *Core = @alignCast(@fieldParentPtr("audio", audio));
    var locked = Core.lockState(core);
    defer locked.unlock();

    const gop = audio.devices.getOrPut(core.gpa, device.id) catch oom();

    log.debug("upserting {f}", .{device});

    if (!gop.found_existing) {
        const key = core.gpa.dupeSentinel(u8, device.id, 0) catch oom();
        gop.key_ptr.* = key;
        gop.value_ptr.* = device.*;

        // Dupe strings
        gop.value_ptr.id = key;
        gop.value_ptr.name = core.gpa.dupeSentinel(u8, device.name, 0) catch oom();
    } else {

        // Some audio devices can change name, for example in the case
        // of the system microphone that will gain or lose 'built-in' in
        // the name depending on wether the audio jack is connected to
        // headphones with an integrated microphone or not.
        const old_name = gop.value_ptr.name;
        const name = if (!std.mem.eql(u8, old_name, device.name)) blk: {
            core.gpa.free(old_name);
            break :blk core.gpa.dupeSentinel(u8, device.name, 0) catch oom();
        } else old_name;
        const id = gop.value_ptr.id;

        gop.value_ptr.* = device.*;

        gop.value_ptr.id = id;
        gop.value_ptr.name = name;
    }

    if (device.default_in) audio.capture_default = gop.index;
    if (device.default_out) audio.playback_default = gop.index;
}

const MacOsInterface = struct {
    comptime {
        @export(&capturePush, .{ .linkage = .strong, .name = "aweboAudioCapturePush" });
        @export(&playbackFill, .{ .linkage = .strong, .name = "aweboAudioPlaybackFill" });
        @export(&playbackSourceStereoFill, .{
            .linkage = .strong,
            .name = "aweboAudioPlaybackSourceStereoFill",
        });
    }

    /// A reference to an AVAudioSourceNode, used by objc code to know
    /// which node to disconnect from the graph.
    const AVAudioSourceNode = opaque {};

    // Temporarily replaces cimport because of 0.16 translate-c regressions.
    const ca = @import("macos/CoreAudio.h.zig");
    // const c = @cImport({
    //     @cInclude("CoreAudio/CoreAudio.h");
    // });

    engine: *AudioEngineManager,

    pub const MacOsDevice = struct {
        device_id: ca.AudioDeviceID,
        pub fn format(md: MacOsDevice, w: *Io.Writer) !void {
            try w.print("MacOsDevice({})", .{md.device_id});
        }
    };

    pub const MacOsCaller = struct {
        source_node: *AVAudioSourceNode,
        comptime {
            @export(&Caller.playbackSourceMonoFill, .{
                .linkage = .strong,
                .name = "aweboAudioPlaybackSourceMonoFill",
            });
        }

        pub fn init(caller: *Caller, audio: *Audio) MacOsCaller {
            return .{
                .source_node = audio.os.playbackSourceAdd(caller, .mono),
            };
        }

        pub fn deinit(mc: MacOsCaller, audio: *Audio) void {
            audio.os.playbackSourceRemove(mc.source_node);
        }
    };

    pub fn init() MacOsInterface {
        return .{ .engine = .init() };
    }

    pub fn deinit(mi: *MacOsInterface, ac: *Audio) void {
        removeHardwareListener(ac);
        mi.engine.deinit();
    }

    pub fn discoverDevicesAndListen(mi: *MacOsInterface, ac: *Audio) void {
        _ = mi;

        // Initial enumeration
        discoverDevices(ac);

        // Register for add/remove/default-change notifications
        installHardwareListener(ac);
    }

    pub fn playbackStart(mi: *MacOsInterface, audio: *Audio, device: ?*Device) bool {
        const id = if (device) |d| d.os.device_id else 0;
        return mi.engine.playbackStart(audio, id);
    }

    pub fn playbackSourceAdd(mi: *MacOsInterface, caller: *Caller, kind: SourceKind) *AVAudioSourceNode {
        return mi.engine.playbackSourceAdd(caller, kind);
    }

    pub fn playbackSourceRemove(mi: *MacOsInterface, source_node: *AVAudioSourceNode) void {
        mi.engine.playbackSourceRemove(source_node);
    }

    pub fn playbackStop(mi: *MacOsInterface) void {
        mi.engine.playbackStop();
    }

    pub fn captureStart(mi: *MacOsInterface, audio: *Audio, device: ?*Device) bool {
        const id = if (device) |d| d.os.device_id else 0;
        return mi.engine.captureStart(audio, id);
    }

    pub fn captureStop(mi: *MacOsInterface) void {
        mi.engine.captureStop();
    }

    fn discoverDevices(ac: *Audio) void {
        const gpa = blk: {
            const core: *Core = @alignCast(@fieldParentPtr("audio", ac));
            break :blk core.gpa;
        };

        const addr: ca.AudioObjectPropertyAddress = .{
            .mSelector = ca.kAudioHardwarePropertyDevices,
            .mScope = ca.kAudioObjectPropertyScopeGlobal,
            .mElement = ca.kAudioObjectPropertyElementMain,
        };

        var data_size: u32 = 0;
        if (ca.AudioObjectGetPropertyDataSize(
            ca.kAudioObjectSystemObject,
            &addr,
            0,
            null,
            &data_size,
        ) != ca.noErr) return;

        const count = data_size / @sizeOf(ca.AudioDeviceID);

        const ids = gpa.alloc(ca.AudioDeviceID, count) catch oom();

        var actual_size = data_size;
        if (ca.AudioObjectGetPropertyData(ca.kAudioObjectSystemObject, &addr, 0, null, &actual_size, ids.ptr) != ca.noErr) return;

        const default_input = defaultDeviceID(ca.kAudioHardwarePropertyDefaultInputDevice);
        const default_output = defaultDeviceID(ca.kAudioHardwarePropertyDefaultOutputDevice);

        for (ids) |device_id| {
            reportDevice(ac, device_id, default_input, default_output);
        }
    }

    fn reportDevice(
        ac: *Audio,
        device_id: ca.AudioDeviceID,
        default_input: ca.AudioDeviceID,
        default_output: ca.AudioDeviceID,
    ) void {
        var uid_buf: [512:0]u8 = undefined;
        var name_buf: [512:0]u8 = undefined;

        const uid = getStringProperty(device_id, ca.kAudioDevicePropertyDeviceUID, &uid_buf) orelse return;
        const name = getStringProperty(device_id, ca.kAudioDevicePropertyDeviceNameCFString, &name_buf) orelse return;

        ac.upsertDevice(&.{
            .id = uid,
            .name = name,
            .channels_in_count = countChannels(device_id, ca.kAudioDevicePropertyScopeInput),
            .channels_out_count = countChannels(device_id, ca.kAudioDevicePropertyScopeOutput),
            .default_in = device_id == default_input,
            .default_out = device_id == default_output,
            .connected = true,
            .os = .{ .device_id = device_id },
        });
    }

    fn defaultDeviceID(selector: ca.AudioObjectPropertySelector) ca.AudioDeviceID {
        const addr = ca.AudioObjectPropertyAddress{
            .mSelector = selector,
            .mScope = ca.kAudioObjectPropertyScopeGlobal,
            .mElement = ca.kAudioObjectPropertyElementMain,
        };
        var id: ca.AudioDeviceID = ca.kAudioDeviceUnknown;
        var size: u32 = @sizeOf(ca.AudioDeviceID);
        _ = ca.AudioObjectGetPropertyData(ca.kAudioObjectSystemObject, &addr, 0, null, &size, &id);
        return id;
    }

    fn getStringProperty(
        device_id: ca.AudioDeviceID,
        selector: ca.AudioObjectPropertySelector,
        out: [:0]u8,
    ) ?[:0]const u8 {
        const addr = ca.AudioObjectPropertyAddress{
            .mSelector = selector,
            .mScope = ca.kAudioObjectPropertyScopeGlobal,
            .mElement = ca.kAudioObjectPropertyElementMain,
        };
        var cf_str: ca.CFStringRef = null;
        var size: u32 = @sizeOf(ca.CFStringRef);
        if (ca.AudioObjectGetPropertyData(device_id, &addr, 0, null, &size, @ptrCast(&cf_str)) != ca.noErr) return null;
        if (cf_str == null) return null;
        defer ca.CFRelease(cf_str);

        if (ca.CFStringGetCString(cf_str, out.ptr, @intCast(out.len), ca.kCFStringEncodingUTF8) == 0) return null;
        return std.mem.span(out.ptr);
    }

    fn countChannels(device_id: ca.AudioDeviceID, scope: ca.AudioObjectPropertyScope) u32 {
        const addr = ca.AudioObjectPropertyAddress{
            .mSelector = ca.kAudioDevicePropertyStreamConfiguration,
            .mScope = scope,
            .mElement = ca.kAudioObjectPropertyElementMain,
        };
        var size: u32 = 0;
        if (ca.AudioObjectGetPropertyDataSize(device_id, &addr, 0, null, &size) != ca.noErr or size == 0) return 0;

        // AudioBufferList is variable-length; use a fixed-size stack buffer
        var raw: [4096]u8 align(@alignOf(ca.AudioBufferList)) = undefined;
        if (size > raw.len) return 0;
        if (ca.AudioObjectGetPropertyData(device_id, &addr, 0, null, &size, &raw) != ca.noErr) return 0;

        const bl: *const ca.AudioBufferList = @ptrCast(&raw);
        var total: u32 = 0;
        for (bl.mBuffers[0..bl.mNumberBuffers]) |b| total += b.mNumberChannels;
        return total;
    }

    const kHardwareSelectors = [_]ca.AudioObjectPropertySelector{
        ca.kAudioHardwarePropertyDevices,
        ca.kAudioHardwarePropertyDefaultInputDevice,
        ca.kAudioHardwarePropertyDefaultOutputDevice,
    };

    fn installHardwareListener(ac: *Audio) void {
        for (kHardwareSelectors) |sel| {
            const addr = ca.AudioObjectPropertyAddress{
                .mSelector = sel,
                .mScope = ca.kAudioObjectPropertyScopeGlobal,
                .mElement = ca.kAudioObjectPropertyElementMain,
            };
            _ = addr;
            _ = ac;
            // _ = ca.AudioObjectAddPropertyListener(
            //     ca.kAudioObjectSystemObject,
            //     &addr,
            //     hardwareListenerProc,
            //     ac,
            // );
        }
    }

    fn removeHardwareListener(ac: *Audio) void {
        for (kHardwareSelectors) |sel| {
            const addr = ca.AudioObjectPropertyAddress{
                .mSelector = sel,
                .mScope = ca.kAudioObjectPropertyScopeGlobal,
                .mElement = ca.kAudioObjectPropertyElementMain,
            };
            _ = ca.AudioObjectRemovePropertyListener(
                ca.kAudioObjectSystemObject,
                &addr,
                hardwareListenerProc,
                ac,
            );
        }
    }

    fn hardwareListenerProc(
        _: ca.AudioObjectID,
        _: c_uint,
        _: ?[*]const ca.AudioObjectPropertyAddress,
        client_data: ?*anyopaque,
    ) callconv(.c) ca.OSStatus {
        const ac: *Audio = @ptrCast(@alignCast(client_data orelse return ca.noErr));
        // Re-enumerate all devices so connected/default flags stay consistent
        discoverDevices(ac);
        return ca.noErr;
    }

    const AudioEngineManager = opaque {
        extern fn audioEngineManagerInit() *AudioEngineManager;
        pub fn init() *AudioEngineManager {
            return audioEngineManagerInit();
        }

        extern fn audioEngineManagerDeinit(*AudioEngineManager) void;
        pub fn deinit(ae: *AudioEngineManager) void {
            audioEngineManagerDeinit(ae);
        }

        extern fn audioPlaybackStart(*AudioEngineManager, *Audio, ca.AudioDeviceID) bool;
        pub fn playbackStart(ae: *AudioEngineManager, audio: *Audio, aid: ca.AudioDeviceID) bool {
            return audioPlaybackStart(ae, audio, aid);
        }

        extern fn audioPlaybackSourceAdd(*AudioEngineManager, *Caller, SourceKind) *AVAudioSourceNode;
        pub fn playbackSourceAdd(ae: *AudioEngineManager, caller: *Caller, kind: SourceKind) *AVAudioSourceNode {
            return audioPlaybackSourceAdd(ae, caller, kind);
        }

        extern fn audioPlaybackSourceRemove(*AudioEngineManager, *AVAudioSourceNode) void;
        pub fn playbackSourceRemove(ae: *AudioEngineManager, source_node: *AVAudioSourceNode) void {
            audioPlaybackSourceRemove(ae, source_node);
        }

        extern fn audioPlaybackStop(*AudioEngineManager) void;
        pub fn playbackStop(ae: *AudioEngineManager) void {
            audioPlaybackStop(ae);
        }

        extern fn audioCaptureStart(*AudioEngineManager, *Audio, ca.AudioDeviceID) bool;
        pub fn captureStart(ae: *AudioEngineManager, audio: *Audio, aid: ca.AudioDeviceID) bool {
            return audioCaptureStart(ae, audio, aid);
        }

        extern fn audioCaptureStop(*AudioEngineManager) void;
        pub fn captureStop(ae: *AudioEngineManager) void {
            audioCaptureStop(ae);
        }
    };
};

const DummyInterface = struct {
    pub const DummyCaller = struct {
        pub fn init(caller: *Caller, audio: *Audio) DummyCaller {
            _ = caller;
            _ = audio;
            unreachable;
        }

        pub fn deinit(dc: DummyCaller, audio: *Audio) void {
            _ = dc;
            _ = audio;
        }
    };

    pub fn init() DummyInterface {
        return .{};
    }

    pub fn deinit(_: *DummyInterface, _: *Audio) void {}

    pub fn discoverDevicesAndListen(_: *DummyInterface, ac: *Audio) void {
        var buf: [256]u8 = undefined;
        for (0..5) |i| {
            const id = std.fmt.bufPrintZ(&buf, "ID DummyAudioDevice #{}", .{i}) catch unreachable;
            ac.upsertDevice(&.{
                .id = id,
                .name = id[3..],
                .channels_in_count = 2,
                .channels_out_count = 2,
                .default_in = i == 0,
                .default_out = i == 0,
                .connected = i != 3,
                .os = .{},
            });
        }
    }

    pub fn playbackStart(_: *DummyInterface, _: *Audio, _: ?*Device) void {}
    pub fn playbackSourceAdd(_: *DummyInterface) void {}
    pub fn playbackSourceRemove(_: *DummyInterface, _: *anyopaque) void {}
    pub fn playbackStop(_: *DummyInterface) void {}

    pub fn captureStart(_: *DummyInterface, _: *Audio, _: ?*Device) void {}
    pub fn captureStop(_: *DummyInterface) void {}

    pub const DummyDevice = struct {
        pub fn format(_: DummyDevice, w: *Io.Writer) !void {
            try w.print("DummyDevice()", .{});
        }
    };
};

fn oom() noreturn {
    std.process.fatal("out of memory", .{});
}

fn Stream(SampleType: type, channels: u32) type {
    return struct {
        channels: [channels]RingBuffer(SampleType, false),

        // used to wake up the thread that writes to the network
        condition: Io.Condition = .init,
        mutex: Io.Mutex = .init,

        const Self = @This();

        pub fn init(buffers: [channels][]f32) Self {
            var self: Self = .{ .channels = undefined };
            for (0..channels) |idx| {
                self.channels[idx] = .init(buffers[idx]);
            }
            return self;
        }

        pub fn deinit(cb: *const Self, allocator: std.mem.Allocator) void {
            for (0..channels) |idx| {
                allocator.free(cb.channels[idx].data);
            }
        }

        pub fn writeBoth(cb: *Self, io: Io, data: []const f32) error{Canceled}!void {
            try cb.mutex.lock(io);
            defer {
                // cb.condition.signal(io);
                cb.mutex.unlock(io);
            }

            for (0..channels) |idx| {
                cb.channels[idx].writeSliceAssumeCapacity(data);
            }

            return;
        }
    };
}

pub const JitterBuffer = struct {
    state: enum {
        /// Waiting for the buffer to fill up for the first time
        starting,
        /// Playing audio normally
        playing,
        /// After we started playing, we emptied our buffer and
        /// are now waiting for the buffer to fill up again
        buffering,
    } = .starting,

    /// Current sequence number.
    /// Assumes that network packets start at 1.
    current_seq: u32 = 0,

    buffer: RingBuffer(*Packet, true),

    pub const Packet = struct {
        seq: u32,
        opus_data: []const u8,
    };

    /// Number of packets that must be present in the buffer
    /// before we start playing.
    const buffer_count = 5; // 5 packets @ 20ms = 100ms jitter

    pub fn init(buffer: []*Packet) JitterBuffer {
        assert(buffer.len > buffer_count); // should have a bit of space for extra packets
        return .{ .buffer = .init(buffer) };
    }

    /// This function is meant to be called by the network thread.
    pub fn writePacket(jb: *JitterBuffer, packet: *Packet) void {
        jb.buffer.write(packet) catch {
            log.warn("dropping audio packet, audio thread is too slow!", .{});
        };
    }

    const NextPacket = union(enum) {
        /// When starting we should play silence.
        starting,
        /// We started playing but we ran out of data and are now buffering.
        buffering,
        /// If payload is null it means that the packet was lost.
        playing: ?*Packet,
    };

    /// This function is meant to be called by the audio thread.
    pub fn nextPacket(jb: *JitterBuffer) NextPacket {
        const r, const l = jb.buffer.readIndices();
        const available_packets = jb.buffer.sliceAt(r, l);
        switch (available_packets.len()) {
            0 => if (jb.state == .playing) {
                jb.state = .buffering;
            },
            1...buffer_count - 1 => {},
            else => jb.state = .playing,
        }

        switch (jb.state) {
            .starting => return .starting,
            .buffering => return .buffering,
            .playing => {},
        }

        assert(available_packets.len() > 0); // invariant

        const slices = [2][]*Packet{
            available_packets.first,
            available_packets.second,
        };

        log.debug("buffer size: {}", .{available_packets.len()});

        // sort packets in case any has arrived out of order
        for (slices) |slice| {
            std.sort.pdq(*Packet, slice, {}, struct {
                fn lt(_: void, lhs: *Packet, rhs: *Packet) bool {
                    return lhs.seq < rhs.seq;
                }
            }.lt);
        }

        var idx: usize = 0;
        for (slices) |slice| for (slice) |next| {
            idx += 1;
            if (next.seq <= jb.current_seq) {
                continue;
            }

            jb.current_seq += 1;
            if (next.seq == jb.current_seq) {
                jb.buffer.read_index.store(jb.buffer.mask2(r + idx), .release);
                return .{ .playing = next };
            }

            assert(next.seq > jb.current_seq);
            if (idx > 1) {
                jb.buffer.read_index.store(jb.buffer.mask2(r + idx - 1), .release);
            }
            return .{ .playing = null };
        };

        // We looked through the full buffer and only found old data
        // which means we're back to buffering mode.
        jb.buffer.read_index.store(jb.buffer.mask2(r + idx), .release);
        jb.state = .buffering;
        return .buffering;
    }
};
