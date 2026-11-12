const MiniaudioInterface = @This();

const std = @import("std");
const assert = std.debug.assert;
const Io = std.Io;
const Audio = @import("../Audio.zig");
const Core = @import("../../Core.zig");
const ma = @import("miniaudio");
const log = std.log.scoped(.miniaudio);

fn ma_error_check(result: ma.ma_result) !void {
    if (result != ma.MA_SUCCESS) {
        std.log.err("Miniaudio error: {}", .{result});
        return error.MiniAudioError;
    }
}

fn ma_panic() noreturn {
    @panic("miniaudio error");
}

pub const OsCaller = struct {
    pub fn init(caller: *Audio.Caller, audio: *Audio) OsCaller {
        audio.os.callSourceAdd(caller, .mono);
        return .{};
    }

    pub fn deinit(mac: *OsCaller) void {
        _ = mac;
    }

    pub fn detatchAndDestroy(mac: *OsCaller, audio: *Audio) void {
        audio.os.callSourceRemove(mac);
    }

    pub fn get_caller(self: *OsCaller) *Audio.Caller {
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
callers: std.ArrayList(*Audio.Caller),
requests: Audio.CallJoinLeaveRing = .empty,

pub fn init(ac: *Audio) MiniaudioInterface {
    const core: *Core = @alignCast(@fieldParentPtr("audio", ac));

    return .{
        .callers = std.ArrayList(*Audio.Caller).initCapacity(core.gpa, 256) catch @panic("TODO"),
    };
}

pub fn deinit(mai: *MiniaudioInterface, ac: *Audio) void {
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

pub fn discoverCapturePermissionState(mai: *MiniaudioInterface) Audio.CapturePermission {
    _ = mai;
    return .granted;
}

pub fn requestCapturePermission(mai: *MiniaudioInterface, ac: *Audio) void {
    _ = mai;
    _ = ac;
    @panic("TODO");
}

pub fn setDevices(mai: *MiniaudioInterface, input: ?*Audio.Device, output: ?*Audio.Device, voice: bool) void {
    _ = voice;
    mai.capture_device_id = if (input) |d| d.os.id else null;
    mai.playback_device_id = if (output) |d| d.os.id else null;
}

pub fn callBegin(mai: *MiniaudioInterface, ac: *Audio) bool {
    mai.callers.clearRetainingCapacity();
    mai.captureStart(ac);
    mai.playbackStart();
    return true;
}

pub fn callEnd(mai: *MiniaudioInterface) void {
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

pub fn discoverDevicesAndListen(mai: *MiniaudioInterface, ac: *Audio) void {
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
    const mai: *MiniaudioInterface = @ptrCast(@alignCast(p_device.*.pUserData));
    const output_m: [*]f32 = @ptrCast(@alignCast(p_output));
    const output = output_m[0..(frame_count * Audio.playback_channels)];

    var temp: [4096]f32 = undefined;
    assert(frame_count < temp.len); // if this fails, we need to make temp bigger
    for (mai.callers.items) |caller| {
        caller.playbackSourceMonoFill(&temp, frame_count);
        for (0..frame_count) |i| {
            // repeat the same sample for each channel since the source is mono
            for (0..Audio.playback_channels) |j| {
                output[i * Audio.playback_channels + j] += temp[i];
            }
        }
    }

    // TODO: compute our time budget and only process part of the requests
    const slices = mai.requests.slices();
    for (slices.array()) |slice| for (slice) |req| switch (req.action) {
        .join => mai.callers.appendAssumeCapacity(req.caller),
        .leave => if (std.mem.findScalar(
            *Audio.Caller,
            mai.callers.items,
            req.caller,
        )) |index| {
            _ = mai.callers.swapRemove(index);
            // TODO: Not optimal to have the audio thread perform the destroy.
            req.caller.destroy();
        },
    };

    mai.requests.commitRead(slices.read_index + slices.len());
}

fn playbackStart(mai: *MiniaudioInterface) void {
    assert(mai.context_init);
    assert(!mai.playback_device_init);
    mai.playback_device_init = true;

    var device_config = ma.ma_device_config_init(ma.ma_device_type_playback);
    device_config.playback.pDeviceID = if (mai.playback_device_id) |*d| d else null;
    device_config.playback.format = ma.ma_format_f32;
    device_config.playback.channels = Audio.playback_channels;
    device_config.sampleRate = Audio.playback_rate;
    device_config.dataCallback = playbackCb;
    device_config.pUserData = mai;

    ma_error_check(ma.ma_device_init(&mai.context, &device_config, &mai.playback_device)) catch ma_panic();
    ma_error_check(ma.ma_device_start(&mai.playback_device)) catch ma_panic();
}

fn playbackStop(mai: *MiniaudioInterface) void {
    if (mai.playback_device_init) {
        ma.ma_device_uninit(&mai.playback_device);
        log.debug("--- end of call playback ---", .{});
        mai.playback_device_init = false;
    }
}

pub fn callSourceAdd(mai: *MiniaudioInterface, caller: *Audio.Caller, kind: Audio.SourceKind) void {
    _ = kind;
    mai.requests.write(.{ .caller = caller, .action = .join }) catch @panic("TODO");
}

pub fn callSourceRemove(mai: *MiniaudioInterface, caller: *OsCaller) void {
    mai.requests.write(.{ .caller = caller.get_caller(), .action = .leave }) catch @panic("TODO");
}

fn initContext(mai: *MiniaudioInterface) void {
    if (!mai.context_init) {
        ma_error_check(ma.ma_context_init(null, 0, null, &mai.context)) catch ma_panic();
        mai.context_init = true;
    }
}

fn deinitContext(mai: *MiniaudioInterface) void {
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

fn captureStart(mai: *MiniaudioInterface, ac: *Audio) void {
    assert(mai.context_init);
    assert(!mai.capture_device_init);

    var device_config = ma.ma_device_config_init(ma.ma_device_type_capture);
    device_config.capture.pDeviceID = if (mai.capture_device_id) |*d| d else null;
    device_config.capture.format = ma.ma_format_f32;
    device_config.capture.channels = Audio.capture_channels;
    device_config.sampleRate = @intFromFloat(Audio.capture_rate);
    device_config.dataCallback = captureCb;
    device_config.pUserData = ac;

    ma_error_check(ma.ma_device_init(&mai.context, &device_config, &mai.capture_device)) catch ma_panic();
    ma_error_check(ma.ma_device_start(&mai.capture_device)) catch ma_panic();

    mai.capture_device_init = true;
}

fn captureStop(mai: *MiniaudioInterface) void {
    if (mai.capture_device_init) {
        ma.ma_device_uninit(&mai.capture_device);
        mai.capture_device_init = false;
    }
}

pub fn setCaptureMute(mai: *MiniaudioInterface, state: Audio.DeviceMuteState) error{Failed}!void {
    assert(mai.capture_device_init);
    switch (state) {
        .muted => ma_error_check(ma.ma_device_stop(&mai.capture_device)) catch return error.Failed,
        .unmuted => ma_error_check(ma.ma_device_start(&mai.capture_device)) catch return error.Failed,
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
    power.store(Audio.computePower(input), .release);
}

pub fn captureTestStart(mai: *MiniaudioInterface, power: *std.atomic.Value(f32)) void {
    assert(mai.context_init);

    const capture_device_id = if (mai.capture_device_id) |*id| id else null;
    const playback_device_id = if (mai.playback_device_id) |*id| id else null;
    var device_config = ma.ma_device_config_init(ma.ma_device_type_duplex);
    device_config.capture.pDeviceID = capture_device_id;
    device_config.capture.format = ma.ma_format_f32;
    device_config.capture.channels = Audio.playback_channels; // we need the same number of channels as playback, then miniaudio will do the conversion if needed
    device_config.capture.shareMode = ma.ma_share_mode_shared;
    device_config.playback.pDeviceID = playback_device_id;
    device_config.playback.format = ma.ma_format_f32;
    device_config.playback.channels = Audio.playback_channels;
    device_config.playback.shareMode = ma.ma_share_mode_shared;
    device_config.sampleRate = Audio.playback_rate;
    device_config.dataCallback = captureTestCb;
    device_config.pUserData = power;
    device_config.noPreSilencedOutputBuffer = @intFromBool(true);
    ma_error_check(ma.ma_device_init(null, &device_config, &mai.capture_test_device)) catch ma_panic();
    mai.capture_test_device_init = true;
    ma_error_check(ma.ma_device_start(&mai.capture_test_device)) catch ma_panic();
}

pub fn captureTestStop(mai: *MiniaudioInterface) void {
    if (mai.capture_test_device_init) {
        ma.ma_device_uninit(&mai.capture_test_device);
        mai.capture_test_device_init = false;
        std.log.debug("deinited capture_test_device", .{});
    }
}

pub const OsDevice = struct {
    id: ma.ma_device_id,
    pub fn format(self: OsDevice, w: *Io.Writer) !void {
        _ = self;
        try w.print("MiniAudioDevice()", .{});
    }
};
