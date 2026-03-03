const Audio = @This();

const builtin = @import("builtin");
const options = @import("options");
const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const awebo = @import("../../awebo.zig");
const Core = @import("../Core.zig");
const JitterBuffer = @import("JitterBuffer.zig");
const RingBuffer = @import("../RingBuffer.zig").RingBuffer;
const CapturePacketRing = @import("CapturePacketRing.zig");
const log = std.log.scoped(.audio);

pub const NoiseGate = enum(u8) {
    denoiser,
    threshold,

    pub fn format(ng: NoiseGate, w: *Io.Writer) !void {
        switch (ng) {
            .denoiser => try w.writeAll("Denoiser (default)"),
            .threshold => try w.writeALl("Activation Threshold (advanced)"),
        }
    }
};

pub const DeviceMuteState = enum(u32) {
    muted = 0,
    unmuted = 1,

    pub fn not(dms: DeviceMuteState) DeviceMuteState {
        return switch (dms) {
            .muted => .unmuted,
            .unmuted => .muted,
        };
    }
};
pub const CapturePermission = enum(u32) {
    unknown = 0,
    denied = 1,
    granted = 2,
    requesting = 3,
};
const SourceKind = enum(u32) { mono = 1, stereo = 2 };

const playback_rate: f64 = 48000.0;
const playback_channels: u32 = 2;

const capture_rate: f64 = 48000.0;
const capture_channels: u32 = 1;

/// Keyed by the device unique ID.
devices: std.StringArrayHashMapUnmanaged(Device),

capture_permission: CapturePermission,
/// Index of the selected input device in awebo.
/// Null means system default, the device might not be connected.
capture_selected: ?usize = null,
/// Index of the concrete input device used by default by the OS.
/// Null means that we haven't discovered this information yet.
capture_default: ?usize = null,
/// Volume from awebo user settings
capture_volume: f32 = 1.0,
capture_mute_state: DeviceMuteState = .unmuted,
capture_threshold: std.atomic.Value(f32) = .init(0.2),
capture_denoiser: *awebo.rnnoise.Denoiser,
capture_noise_gate: std.atomic.Value(NoiseGate) = .init(.denoiser),
capture_silence_count: u32 = 10,
capture_stream: Stream(f32, 1),
capture_encoder: *awebo.opus.Encoder,
capture_packets: CapturePacketRing = .empty,

/// Same as input, but for the playback device
playback_selected: ?usize = null,
playback_default: ?usize = null,
playback_volume: f32 = 1.0,
playback_mute_state: DeviceMuteState = .unmuted,
playback_stream: Stream(f32, 2),
playback_decoder: *awebo.opus.Decoder,
playback_voice_processing: bool = false,

/// Os interface
os: switch (builtin.target.os.tag) {
    .macos => if (options.miniaudio) MiniAudioInterface else MacOsInterface,
    else => MiniAudioInterface,
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
        .macos => if (options.miniaudio) MiniAudioInterface.MiniAudioDevice else MacOsInterface.MacOsDevice,
        else => MiniAudioInterface.MiniAudioDevice,
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
        .macos => if (options.miniaudio) MiniAudioInterface.MiniAudioCaller else MacOsInterface.MacOsCaller,
        else => MiniAudioInterface.MiniAudioCaller,
    },

    pub fn create(gpa: Allocator, core: *Core) !*Caller {
        const caller = try gpa.create(Caller);
        log.debug("caller create = {*}", .{caller});
        caller.* = .{
            .core = core,
            .decoder = try .create(),
            .packets = .init(),
            .voice = .init(.{try gpa.alloc(
                f32,
                std.math.ceilPowerOfTwoAssert(
                    usize,
                    awebo.opus.PACKET_SAMPLE_COUNT,
                ),
            )}),
            .os = undefined,
        };
        caller.os = .init(caller, &core.audio);
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
        const voice_read = &caller.voice.channels[0];
        const available_count = voice_read.len();
        const s = samples[0..@min(frame_count, available_count)];
        voice_read.readFirstAssumeCount(s, s.len);

        var remaining = samples[s.len..frame_count];
        while (remaining.len != 0) {
            assert(voice_read.len() == 0); // invariant leveraged below
            switch (caller.packets.nextPacketBegin()) {
                .starting => {
                    @memset(remaining, 0);
                    return;
                },
                .playing => |playing| {
                    if (remaining.len >= awebo.opus.PACKET_SAMPLE_COUNT) {
                        const written = caller.decoder.decodeFloat(
                            playing.data,
                            remaining,
                            playing.fec,
                        ) catch |err| {
                            log.debug("error parsing opus data: {t}", .{err});
                            @memset(remaining, 0);
                            caller.packets.nextPacketCommit(playing);
                            return;
                        };
                        assert(written == awebo.opus.PACKET_SAMPLE_COUNT);
                        caller.packets.nextPacketCommit(playing);
                        remaining = remaining[awebo.opus.PACKET_SAMPLE_COUNT..];
                        continue;
                    } else {
                        assert(voice_read.data.len >= awebo.opus.PACKET_SAMPLE_COUNT);
                        const written = caller.decoder.decodeFloat(
                            playing.data,
                            voice_read.data,
                            playing.fec,
                        ) catch |err| {
                            log.debug("error parsing opus data: {t}", .{err});
                            @memset(remaining, 0);
                            caller.packets.nextPacketCommit(playing);
                            return;
                        };

                        caller.packets.nextPacketCommit(playing);
                        assert(written == awebo.opus.PACKET_SAMPLE_COUNT);
                        assert(written > remaining.len);
                        @memcpy(remaining, voice_read.data.ptr);
                        voice_read.write_index = awebo.opus.PACKET_SAMPLE_COUNT;
                        voice_read.read_index = remaining.len;
                        return;
                    }
                },
                .dred => |dred| {
                    // TODO: implement this :^)
                    // if (remaining.len >= awebo.opus.PACKET_SAMPLE_COUNT) {}
                    // assert(dred.info.available >= dred.distance * awebo.opus.PACKET_SAMPLE_COUNT);
                    // assert(dred.info.end < dred.distance * awebo.opus.PACKET_SAMPLE_COUNT);

                    log.debug("distance = {}", .{dred.distance_samples});
                    const written = caller.decoder.decodeDredFloat(
                        caller.packets.dred_state,
                        dred.distance_samples,
                        voice_read.data[0..awebo.opus.PACKET_SAMPLE_COUNT],
                    ) catch |err| blk: {
                        log.err("error decoding dred samples: {t}", .{err});
                        @memset(voice_read.data[0..awebo.opus.PACKET_SAMPLE_COUNT], 0);
                        break :blk awebo.opus.PACKET_SAMPLE_COUNT;
                    };

                    assert(written == awebo.opus.PACKET_SAMPLE_COUNT);
                    assert(written > remaining.len);
                    @memcpy(remaining, voice_read.data.ptr);
                    voice_read.write_index = awebo.opus.PACKET_SAMPLE_COUNT;
                    voice_read.read_index = remaining.len;
                    return;
                },
                .missing => {
                    if (remaining.len >= awebo.opus.PACKET_SAMPLE_COUNT) {
                        const written = caller.decoder.decodeMissing(remaining, false);
                        assert(written == awebo.opus.PACKET_SAMPLE_COUNT);
                        assert(written > remaining.len);
                        remaining = remaining[awebo.opus.PACKET_SAMPLE_COUNT..];
                        continue;
                    } else {
                        const written = caller.decoder.decodeMissing(voice_read.data, false);
                        assert(written == awebo.opus.PACKET_SAMPLE_COUNT);
                        assert(written > remaining.len);
                        @memcpy(remaining, voice_read.data.ptr);
                        voice_read.write_index = awebo.opus.PACKET_SAMPLE_COUNT;
                        voice_read.read_index = remaining.len;
                        return;
                    }
                },
            }
            comptime unreachable;
        }
    }
};

/// Audio is initialized by the Core logic thread after the rest of core
/// has been initialized.
pub fn init(audio: *Audio, capture_buf: []f32, playback_bufs: [2][]f32) void {
    assert(playback_bufs[0].len == playback_bufs[1].len);
    const capture_encoder = awebo.opus.Encoder.create() catch unreachable;
    const capture_denoiser = awebo.rnnoise.Denoiser.create() catch unreachable;
    const playback_decoder = awebo.opus.Decoder.create() catch unreachable;
    audio.* = .{
        .capture_permission = .unknown,
        .capture_encoder = capture_encoder,
        .capture_denoiser = capture_denoiser,
        .capture_stream = .init(.{capture_buf}),
        .playback_stream = .init(playback_bufs),
        .playback_decoder = playback_decoder,
        .devices = .empty,
        .os = undefined,
    };
    audio.os = .init(audio);
    audio.capture_permission = audio.os.discoverCapturePermissionState();
    audio.os.discoverDevicesAndListen(audio);
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

/// Should be called before committing to join a call.
/// If the return value is:
/// - unknown: the user is being shown an OS window to grant permission,
///            undo the action, the user is expected to retry once done.
/// - denied:  we can't start a call because we can't access the mic,
///            show the user a popup that tells them to grant permission.
/// - granted: proceed.
/// - requesting: the user has not yet dismissed the OS window that
///               requests to grant permission, show an appropriate
///               popup.
pub fn ensureCapturePermission(audio: *Audio) CapturePermission {
    switch (audio.capture_permission) {
        .unknown => {
            audio.capture_permission = .requesting;
            audio.os.requestCapturePermission(audio);
            return .unknown;
        },
        .denied => {
            // Let's query the OS again in case that the user has granted access manually.
            const new = audio.os.discoverCapturePermissionState();
            if (new == .granted) {
                audio.capture_permission = .granted;
            }
        },
        else => {},
    }

    return audio.capture_permission;
}

/// Returns if there was a state transition.
pub fn setCaptureMute(audio: *Audio, state: DeviceMuteState) error{Failed}!bool {
    if (audio.capture_mute_state == state) return false;
    try audio.os.setCaptureMute(state);
    audio.capture_mute_state = state;
    return true;
}

pub fn setDevices(audio: *Audio) void {
    const input = if (audio.capture_selected) |idx|
        &audio.devices.values()[idx]
    else
        null;

    const output = if (audio.playback_selected) |idx|
        &audio.devices.values()[idx]
    else
        null;
    audio.os.setDevices(input, output, audio.playback_voice_processing);
}

pub fn restart(audio: *Audio) void {
    audio.os.restart();
}

pub fn callBegin(audio: *Audio) void {
    assert(audio.capture_permission == .granted); // see ensureCapturePermission()
    log.debug("callBegin", .{});
    _ = audio.os.callBegin(audio);
}

pub fn callEnd(audio: *Audio) void {
    log.debug("callEnd", .{});
    audio.os.callEnd();
}

/// 'power' will be written to atomically by the audio thread
/// to report the power computation of the audio being captured
pub fn captureTestStart(audio: *Audio, power: *std.atomic.Value(f32)) void {
    assert(audio.capture_permission == .granted); // see ensureCapturePermission()
    log.debug("captureTestStart", .{});
    _ = audio.os.captureTestStart(power);
}

pub fn captureTestStop(audio: *Audio) void {
    log.debug("captureTestStop", .{});
    audio.os.captureTestStop();
}

/// Called by OS APIs to let us take audio data from the capture buffer.
fn capturePush(audio: *Audio, frames: [*]const f32, frame_count: u32) callconv(.c) void {
    const capture = &audio.capture_stream.channels[0];
    capture.writeSliceAssumeCapacity(frames[0..frame_count]);
    if (capture.len() < awebo.opus.PACKET_SAMPLE_COUNT) return;

    var pcm: [awebo.opus.PACKET_SAMPLE_COUNT]f32 = undefined;
    capture.readFirstAssumeCount(
        &pcm,
        awebo.opus.PACKET_SAMPLE_COUNT,
    );

    const noise_gate = audio.capture_noise_gate.load(.unordered);

    const silence = switch (noise_gate) {
        .denoiser => blk: {
            for (&pcm) |*s| {
                s.* *= 32768;
            }
            const voice1 = audio.capture_denoiser.processFrame(
                pcm[0..awebo.rnnoise.FRAME_SIZE],
                pcm[0..awebo.rnnoise.FRAME_SIZE],
            );
            const voice2 = audio.capture_denoiser.processFrame(
                pcm[awebo.rnnoise.FRAME_SIZE..],
                pcm[awebo.rnnoise.FRAME_SIZE..],
            );

            for (&pcm) |*s| {
                s.* /= 32768;
            }

            break :blk voice1 < 0.7 and voice2 < 0.7;
        },
        .threshold => blk: {
            const threshold = audio.capture_threshold.load(.unordered);
            const power = computePower(&pcm);

            if (power < threshold) {
                audio.capture_silence_count += 1;
            } else {
                audio.capture_silence_count = 0;
            }

            const silence = audio.capture_silence_count > 10;
            if (silence) {
                @memset(&pcm, 0);
            }

            break :blk silence;
        },
    };

    const write = audio.capture_packets.beginWrite() orelse {
        log.err("capture buffer is full, network thread is lagging behind!", .{});
        return;
    };
    write.data.len = audio.capture_encoder.encodeFloat(&pcm, write.data.writeSlice()) catch |err| {
        log.err("opus encoder error: {t}", .{err});
        capture.read_index = 0;
        capture.write_index = 0;
    };
    write.data.silence = silence;

    audio.capture_packets.commitWrite(write);
}

/// Called by the OS interface whenever a device is added, removed, or its
/// default status changes.  `raw_id` and `raw_name` are duped on first insert.
fn upsertDevice(audio: *Audio, device: *const Device) void {
    const core: *Core = @alignCast(@fieldParentPtr("audio", audio));
    var locked = Core.lockState(core);
    defer locked.unlock();

    const gop = audio.devices.getOrPut(core.gpa, device.id) catch oom();

    // log.debug("upserting {f}", .{device});

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
                .source_node = audio.os.callSourceAdd(caller, .mono),
            };
        }

        pub fn deinit(mc: MacOsCaller, audio: *Audio) void {
            audio.os.callSourceRemove(mc.source_node);
        }
    };

    pub fn init(ac: *Audio) MacOsInterface {
        return .{ .engine = .init(ac) };
    }

    pub fn deinit(mi: *MacOsInterface, ac: *Audio) void {
        removeHardwareListener(ac);
        mi.engine.deinit();
    }

    extern fn audioDiscoverCapturePermissionState() CapturePermission;
    pub fn discoverCapturePermissionState(mi: *MacOsInterface) CapturePermission {
        _ = mi;
        return audioDiscoverCapturePermissionState();
    }
    extern fn audioRequestCapturePermission(*Audio) void;
    pub fn requestCapturePermission(mi: *MacOsInterface, ac: *Audio) void {
        _ = mi;
        audioRequestCapturePermission(ac);
    }
    export fn aweboUpdateCapturePermission(ac: *Audio, cp: CapturePermission) void {
        ac.capture_permission = cp;
    }

    pub fn setCaptureMute(mi: *MacOsInterface, state: DeviceMuteState) error{Failed}!void {
        return mi.engine.setCaptureMute(state);
    }

    pub fn setDevices(mi: *MacOsInterface, input: ?*Device, output: ?*Device, voice: bool) void {
        const input_idx = if (input) |i| i.os.device_id else 0;
        const output_idx = if (output) |o| o.os.device_id else 0;
        mi.engine.setDevices(input_idx, output_idx, voice);
    }

    pub fn discoverDevicesAndListen(mi: *MacOsInterface, ac: *Audio) void {
        _ = mi;

        // Initial enumeration
        discoverDevices(ac);

        // Register for add/remove/default-change notifications
        installHardwareListener(ac);
    }

    pub fn playbackStart(mi: *MacOsInterface, audio: *Audio, device: ?*Device) bool {
        // const id = if (device) |d| d.os.device_id else 0;
        // return mi.engine.playbackStart(audio, id);
        _ = mi;
        _ = audio;
        _ = device;
        return true;
    }

    pub fn callSourceAdd(mi: *MacOsInterface, caller: *Caller, kind: SourceKind) *AVAudioSourceNode {
        return mi.engine.callSourceAdd(caller, kind);
    }

    pub fn callSourceRemove(mi: *MacOsInterface, source_node: *AVAudioSourceNode) void {
        mi.engine.callSourceRemove(source_node);
    }

    pub fn playbackStop(mi: *MacOsInterface) void {
        // mi.engine.playbackStop();
        _ = mi;
    }

    pub fn restart(mi: *MacOsInterface) void {
        mi.engine.restart();
    }

    pub fn callBegin(mi: *MacOsInterface, audio: *Audio) bool {
        return mi.engine.callStart(audio);
    }

    pub fn callEnd(mi: *MacOsInterface) void {
        mi.engine.callStop();
    }

    pub fn captureTestStart(mi: *MacOsInterface, power: *std.atomic.Value(f32)) bool {
        return mi.engine.captureTestStart(power);
    }

    pub fn captureTestStop(mi: *MacOsInterface) void {
        mi.engine.captureTestStop();
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
        for ((&bl.mBuffers).ptr[0..bl.mNumberBuffers]) |b| total += b.mNumberChannels;
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
            _ = ca.AudioObjectAddPropertyListener(
                ca.kAudioObjectSystemObject,
                &addr,
                hardwareListenerProc,
                ac,
            );
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
        ac.restart();
        return ca.noErr;
    }

    const AudioEngineManager = opaque {
        extern fn audioManagerInit(*Audio) *AudioEngineManager;
        pub fn init(ac: *Audio) *AudioEngineManager {
            return audioManagerInit(ac);
        }

        extern fn audioManagerDeinit(*AudioEngineManager) void;
        pub fn deinit(ae: *AudioEngineManager) void {
            audioManagerDeinit(ae);
        }

        extern fn audioSetCaptureMuteState(*AudioEngineManager, DeviceMuteState) bool;
        pub fn setCaptureMute(ae: *AudioEngineManager, state: DeviceMuteState) !void {
            if (!audioSetCaptureMuteState(ae, state)) {
                return error.Failed;
            }
        }

        extern fn audioSetDevices(*AudioEngineManager, ca.AudioDeviceID, ca.AudioDeviceID, bool) void;
        pub fn setDevices(ae: *AudioEngineManager, input: ca.AudioDeviceID, output: ca.AudioDeviceID, voice: bool) void {
            audioSetDevices(ae, input, output, voice);
        }

        extern fn audioCallSourceAdd(*AudioEngineManager, *Caller, SourceKind) *AVAudioSourceNode;
        pub fn callSourceAdd(ae: *AudioEngineManager, caller: *Caller, kind: SourceKind) *AVAudioSourceNode {
            return audioCallSourceAdd(ae, caller, kind);
        }

        extern fn audioCallSourceRemove(*AudioEngineManager, *AVAudioSourceNode) void;
        pub fn callSourceRemove(ae: *AudioEngineManager, source_node: *AVAudioSourceNode) void {
            audioCallSourceRemove(ae, source_node);
        }

        extern fn audioRestart(*AudioEngineManager) void;
        pub fn restart(ae: *AudioEngineManager) void {
            audioRestart(ae);
        }

        extern fn audioCallBegin(*AudioEngineManager, *Audio) bool;
        pub fn callStart(ae: *AudioEngineManager, audio: *Audio) bool {
            return audioCallBegin(ae, audio);
        }

        extern fn audioCallEnd(*AudioEngineManager) void;
        pub fn callStop(ae: *AudioEngineManager) void {
            audioCallEnd(ae);
        }

        extern fn audioTestBegin(*AudioEngineManager, *anyopaque) bool;
        pub fn captureTestStart(ae: *AudioEngineManager, power: *std.atomic.Value(f32)) bool {
            return audioTestBegin(ae, power);
        }

        extern fn audioTestEnd(*AudioEngineManager) void;
        pub fn captureTestStop(ae: *AudioEngineManager) void {
            audioTestEnd(ae);
        }
    };
};

const MiniAudioInterface = struct {
    const ma = @cImport(@cInclude("miniaudio.h"));

    fn ma_error_check(result: ma.ma_result) !void {
        if (result != ma.MA_SUCCESS) {
            std.log.err("Miniaudio error: {}", .{result});
            return error.MiniAudioError;
        }
    }

    fn ma_panic() noreturn {
        @panic("miniaudio error");
    }

    pub const MiniAudioCaller = struct {
        pub fn init(caller: *Caller, audio: *Audio) MiniAudioCaller {
            audio.os.callSourceAdd(caller, .mono);
            return .{};
        }

        pub fn deinit(mac: *MiniAudioCaller, audio: *Audio) void {
            audio.os.callSourceRemove(mac);
        }

        pub fn get_caller(self: *MiniAudioCaller) *Caller {
            return @alignCast(@fieldParentPtr("os", self));
        }
    };

    context: ma.ma_context = undefined,
    context_init: bool = false,

    capture_device_id: ?ma.ma_device_id = null,
    playback_device_id: ?ma.ma_device_id = null,

    capture_test_device: ma.ma_device = undefined,
    capture_test_device_init: bool = false,
    playback_device: ma.ma_device = undefined,
    playback_device_init: bool = false,
    capture_device: ma.ma_device = undefined,
    capture_device_init: bool = false,

    // this should be behind a mutex
    callers: std.ArrayList(*Caller) = .empty,

    pub fn init(ac: *Audio) MiniAudioInterface {
        _ = ac;
        return .{};
    }

    pub fn deinit(mai: *MiniAudioInterface, ac: *Audio) void {
        if (mai.capture_device_init) {
            ma.ma_device_uninit(&mai.capture_device);
        }
        if (mai.playback_device_init) {
            ma.ma_device_uninit(&mai.playback_device);
        }
        const core: *Core = @alignCast(@fieldParentPtr("audio", ac));
        mai.callers.deinit(core.gpa);
        mai.deinitContext();
    }

    pub fn discoverCapturePermissionState(mai: *MiniAudioInterface) CapturePermission {
        _ = mai;
        return .granted;
    }

    pub fn requestCapturePermission(mai: *MiniAudioInterface, ac: *Audio) void {
        _ = mai;
        _ = ac;
        @panic("TODO");
    }

    pub fn setDevices(mai: *MiniAudioInterface, input: ?*Device, output: ?*Device, voice: bool) void {
        _ = voice;
        mai.capture_device_id = if (input) |d| d.os.id else null;
        mai.playback_device_id = if (output) |d| d.os.id else null;
    }

    pub fn callBegin(mai: *MiniAudioInterface, ac: *Audio) bool {
        const core: *Core = @alignCast(@fieldParentPtr("audio", ac));
        mai.callers.clearAndFree(core.gpa);
        mai.captureStart(ac);
        mai.playbackStart();
        return true;
    }

    pub fn callEnd(mai: *MiniAudioInterface) void {
        mai.captureStop();
        mai.playbackStop();
    }

    fn enumerateDevicesCb(pContext: [*c]ma.ma_context, deviceType: ma.ma_device_type, pInfo: [*c]const ma.ma_device_info, pUserData: ?*anyopaque) callconv(.c) ma.ma_bool32 {
        _ = pContext;
        const ac: *Audio = @ptrCast(@alignCast(pUserData));
        const device_info: *const ma.ma_device_info = @ptrCast(pInfo);

        const name = std.mem.span(@as([*c]const u8, &device_info.name));

        ac.upsertDevice(&.{
            .id = name,
            .name = name,
            .channels_in_count = if (deviceType == ma.ma_device_type_capture) 2 else 0,
            .channels_out_count = if (deviceType == ma.ma_device_type_playback) 2 else 0,
            .default_in = deviceType == ma.ma_device_type_capture and device_info.isDefault != 0,
            .default_out = deviceType == ma.ma_device_type_playback and device_info.isDefault != 0,
            .connected = true,
            .os = .{ .id = device_info.id },
        });

        return 1;
    }

    pub fn discoverDevicesAndListen(mai: *MiniAudioInterface, ac: *Audio) void {
        mai.initContext();
        ma_error_check(ma.ma_context_enumerate_devices(&mai.context, enumerateDevicesCb, ac)) catch ma_panic();
    }

    fn playbackCb(
        p_device: [*c]ma.ma_device,
        p_output: ?*anyopaque,
        p_input: ?*const anyopaque,
        frame_count: ma.ma_uint32,
    ) callconv(.c) void {
        _ = p_input;
        const callers: *std.ArrayList(*Caller) = @ptrCast(@alignCast(p_device.*.pUserData));
        const output_m: [*]f32 = @ptrCast(@alignCast(p_output));
        const output = output_m[0..(frame_count * playback_channels)];

        var temp: [4096]f32 = undefined;
        assert(frame_count < temp.len); // if this fails, we need to make temp bigger
        for (callers.items) |caller| {
            // I NEED TO SUM THE CALLERS SAMPLES, NOT OVERRIDE
            caller.playbackSourceMonoFill(&temp, frame_count);
            for (0..frame_count) |i| {
                // repeat the same sample for each channel since the source is mono
                for (0..playback_channels) |j| {
                    output[i * playback_channels + j] += temp[i];
                }
            }
        }
    }

    fn playbackStart(mai: *MiniAudioInterface) void {
        assert(mai.context_init);
        assert(!mai.playback_device_init);

        var device_config = ma.ma_device_config_init(ma.ma_device_type_playback);
        device_config.playback.pDeviceID = if (mai.playback_device_id) |*d| d else null;
        device_config.playback.format = ma.ma_format_f32;
        device_config.playback.channels = playback_channels;
        device_config.sampleRate = playback_rate;
        device_config.dataCallback = playbackCb;
        device_config.pUserData = &mai.callers;

        ma_error_check(ma.ma_device_init(&mai.context, &device_config, &mai.playback_device)) catch ma_panic();
        ma_error_check(ma.ma_device_start(&mai.playback_device)) catch ma_panic();
    }

    fn playbackStop(mai: *MiniAudioInterface) void {
        if (mai.playback_device_init) {
            ma.ma_device_uninit(&mai.playback_device);
            mai.playback_device_init = false;
        }
    }

    pub fn callSourceAdd(mai: *MiniAudioInterface, caller: *Caller, kind: SourceKind) void {
        _ = kind;
        mai.callers.append(caller.core.gpa, caller) catch oom();
    }

    pub fn callSourceRemove(mai: *MiniAudioInterface, caller: *MiniAudioCaller) void {
        if (std.mem.findScalar(*Caller, mai.callers.items, caller.get_caller())) |index| {
            _ = mai.callers.swapRemove(index);
        }
    }

    fn initContext(mai: *MiniAudioInterface) void {
        if (!mai.context_init) {
            ma_error_check(ma.ma_context_init(null, 0, null, &mai.context)) catch ma_panic();
            mai.context_init = true;
        }
    }

    fn deinitContext(mai: *MiniAudioInterface) void {
        if (mai.context_init) {
            ma_error_check(ma.ma_context_uninit(&mai.context)) catch ma_panic();
            mai.context_init = false;
        }
    }

    export fn captureCb(
        p_device: [*c]ma.ma_device,
        p_output: ?*anyopaque,
        p_input: ?*const anyopaque,
        frame_count: ma.ma_uint32,
    ) callconv(.c) void {
        _ = p_output;
        const audio: *Audio = @ptrCast(@alignCast(p_device.*.pUserData));
        const count = frame_count * p_device.*.capture.channels;
        const input: [*]const f32 = @ptrCast(@alignCast(p_input));
        // const input = input_m[0..count];
        audio.capturePush(input, count);
    }

    fn captureStart(mai: *MiniAudioInterface, ac: *Audio) void {
        assert(mai.context_init);
        assert(!mai.capture_device_init);

        var device_config = ma.ma_device_config_init(ma.ma_device_type_capture);
        device_config.capture.pDeviceID = if (mai.capture_device_id) |*d| d else null;
        device_config.capture.format = ma.ma_format_f32;
        device_config.capture.channels = capture_channels;
        device_config.sampleRate = @intFromFloat(capture_rate);
        device_config.dataCallback = captureCb;
        device_config.pUserData = ac;

        ma_error_check(ma.ma_device_init(&mai.context, &device_config, &mai.capture_device)) catch ma_panic();
        ma_error_check(ma.ma_device_start(&mai.capture_device)) catch ma_panic();

        mai.capture_device_init = true;
    }

    fn captureStop(mai: *MiniAudioInterface) void {
        if (mai.capture_device_init) {
            ma.ma_device_uninit(&mai.capture_device);
            mai.capture_device_init = false;
        }
    }

    pub fn setCaptureMute(mai: *MiniAudioInterface, state: DeviceMuteState) error{Failed}!void {
        assert(mai.capture_device_init);
        switch (state) {
            .muted => ma_error_check(ma.ma_device_start(&mai.capture_device)) catch return error.Failed,
            .unmuted => ma_error_check(ma.ma_device_stop(&mai.capture_device)) catch return error.Failed,
        }
    }

    fn captureTestCb(
        p_device: [*c]ma.ma_device,
        p_output: ?*anyopaque,
        p_input: ?*const anyopaque,
        frame_count: ma.ma_uint32,
    ) callconv(.c) void {
        const count = frame_count * p_device.*.capture.channels;
        const output: [*]f32 = @ptrCast(@alignCast(p_output));
        const input_m: [*]const f32 = @ptrCast(@alignCast(p_input));
        const input = input_m[0..count];
        @memcpy(output, input);
        const power: *std.atomic.Value(f32) = @ptrCast(@alignCast(p_device.*.pUserData));
        power.store(computePower(input), .release);
    }

    pub fn captureTestStart(mai: *MiniAudioInterface, power: *std.atomic.Value(f32)) void {
        assert(mai.context_init);

        const capture_device_id = if (mai.capture_device_id) |*id| id else null;
        const playback_device_id = if (mai.playback_device_id) |*id| id else null;
        var device_config = ma.ma_device_config_init(ma.ma_device_type_duplex);
        device_config.capture.pDeviceID = capture_device_id;
        device_config.capture.format = ma.ma_format_f32;
        device_config.capture.channels = playback_channels; // we need the same number of channels as playback, then miniaudio will do the conversion if needed
        device_config.capture.shareMode = ma.ma_share_mode_shared;
        device_config.playback.pDeviceID = playback_device_id;
        device_config.playback.format = ma.ma_format_f32;
        device_config.playback.channels = playback_channels;
        device_config.playback.shareMode = ma.ma_share_mode_shared;
        device_config.sampleRate = playback_rate;
        device_config.dataCallback = captureTestCb;
        device_config.pUserData = power;
        device_config.noPreSilencedOutputBuffer = @intFromBool(true);
        ma_error_check(ma.ma_device_init(null, &device_config, &mai.capture_test_device)) catch ma_panic();
        mai.capture_test_device_init = true;
        ma_error_check(ma.ma_device_start(&mai.capture_test_device)) catch ma_panic();
    }

    pub fn captureTestStop(mai: *MiniAudioInterface) void {
        if (mai.capture_test_device_init) {
            ma.ma_device_uninit(&mai.capture_test_device);
            mai.capture_test_device_init = false;
            std.log.debug("deinited capture_test_device", .{});
        }
    }

    pub const MiniAudioDevice = struct {
        id: ma.ma_device_id,
        pub fn format(self: MiniAudioDevice, w: *Io.Writer) !void {
            _ = self;
            try w.print("MiniAudioDevice()", .{});
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

    pub fn init(_: *Audio) DummyInterface {
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

    pub fn discoverCapturePermissionState(_: *DummyInterface) CapturePermission {
        return .granted;
    }
    pub fn requestCapturePermission(_: *DummyInterface, _: *Audio) void {}
    pub fn setCaptureMute(_: *DummyInterface, _: DeviceMuteState) error{Failed}!void {}
    pub fn setDevices(_: *DummyInterface, _: ?*Device, _: ?*Device, _: bool) void {}
    pub fn callBegin(_: *DummyInterface, _: *Audio) void {}
    pub fn playbackSourceAdd(_: *DummyInterface) void {}
    pub fn playbackSourceRemove(_: *DummyInterface, _: *anyopaque) void {}
    pub fn callEnd(_: *DummyInterface) void {}
    pub fn restart(_: *DummyInterface) void {}
    pub fn captureTestStart(_: *DummyInterface, _: *std.atomic.Value(f32)) void {}
    pub fn captureTestStop(_: *DummyInterface) void {}

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
        channels: [channels]RingBuffer(SampleType),

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

test {
    _ = JitterBuffer;
    _ = CapturePacketRing;
}

/// Called by OS code to perform the power computation on samples
export fn aweboComputePower(power: *std.atomic.Value(f32), sample_buf: [*]const f32, sample_count: u32) void {
    const samples = sample_buf[0..sample_count];
    power.store(computePower(samples), .release);
}

fn computePower(samples: []const f32) f32 {
    var rms: f32 = 0;
    for (samples) |s| rms += s * s;
    rms /= @floatFromInt(samples.len);
    rms = std.math.sqrt(rms);
    const value = rms * 20;
    if (value > 1.0) return 1.0;
    return value;
}
