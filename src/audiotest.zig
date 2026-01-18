const builtin = @import("builtin");

const std = @import("std");
const Io = std.Io;
const core = @import("client/core.zig");
const audio = core.audio;

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    std.log.err(fmt, args);
    std.process.exit(0xff);
}

const Context = struct {
    play_sin: bool = false,
    capture_format: audio.Format,
    captured_frame_count: usize = 0,
    captured_samples: std.ArrayListAligned(u8, .fromByteUnits(audio.buffer_align)) = .empty,
    mutex: std.Thread.Mutex = .{},
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = init.minimal.args.toSlice(arena);
    const cmd_args = args[1..];

    var opt: struct {
        list: bool = false,
        playout_device_str: ?[]const u8 = null,
        capture_device_str: ?[]const u8 = null,
        play_sin: bool = false,
    } = .{};

    {
        var i: usize = 0;
        while (i < cmd_args.len) : (i += 1) {
            const arg = cmd_args[i];
            if (std.mem.eql(u8, arg, "-h")) {
                std.debug.print(
                    "Usage: audiotest [--list] [--sin] [--input DEVICE] [--output DEVICE]\n",
                    .{},
                );
                std.process.exit(0xff);
            } else if (std.mem.eql(u8, arg, "--list")) {
                opt.list = true;
            } else if (std.mem.eql(u8, arg, "--sin")) {
                opt.play_sin = true;
            } else if (std.mem.eql(u8, arg, "--input")) {
                i += 1;
                if (i >= cmd_args.len) fatal("--input requires an argument", .{});
                opt.capture_device_str = cmd_args[i];
            } else if (std.mem.eql(u8, arg, "--output")) {
                i += 1;
                if (i >= cmd_args.len) fatal("--output requires an argument", .{});
                opt.playout_device_str = cmd_args[i];
            } else fatal("unknown cmdline argument '{s}'", .{arg});
        }
    }

    try audio.processInit();

    audio.threadInit();
    defer audio.threadDeinit();

    if (opt.list) {
        switch (core.global.audio_playout.updateDevices(arena, onUpdateDeviceEvent)) {
            .locked => unreachable,
            .result => |maybe_err| if (maybe_err) |err| fatal("failed to update output devices with {f}", .{err}),
        }
        switch (core.global.audio_capture.updateDevices(arena, onUpdateDeviceEvent)) {
            .locked => unreachable,
            .result => |maybe_err| if (maybe_err) |err| fatal("failed to update input devices with {f}", .{err}),
        }

        std.debug.print("----------------------------------------\n", .{});
        std.debug.print("{} Outputs:\n", .{core.global.audio_playout.devices.items.len});
        std.debug.print("----------------------------------------\n", .{});
        try printDevices(core.global.audio_playout.devices.items);
        std.debug.print("----------------------------------------\n", .{});
        std.debug.print("{} Inputs:\n", .{core.global.audio_capture.devices.items.len});
        std.debug.print("----------------------------------------\n", .{});
        try printDevices(core.global.audio_capture.devices.items);
        std.process.exit(0);
    }

    const playout_device: ?core.Device = if (opt.playout_device_str) |s| try findDevice(.playout, s) else null;
    if (playout_device) |d| {
        std.log.info("Output: '{f}'", .{d.name});
    } else {
        std.log.info("Output: System Default", .{});
    }
    const capture_device: ?core.Device = if (opt.capture_device_str) |s| try findDevice(.capture, s) else null;
    if (capture_device) |d| {
        std.log.info("Input: '{f}'", .{d.name});
    } else {
        std.log.info("Input: System Default", .{});
    }

    var stream_err: audio.Stream.Error = undefined;
    var capture: audio.Stream = undefined;
    audio.Stream.open(
        &capture,
        .capture,
        &stream_err,
        null, // device
        streamCallback,
        @constCast(&{}), // callback data
    ) catch std.debug.panic("open capture failed: {f}", .{stream_err});
    defer capture.close(gpa);
    std.log.info("Input Format: {}", .{capture.format});

    var renderer: Renderer = .{};
    var playout: audio.Stream = undefined;
    audio.Stream.open(
        &playout,
        .playout,
        &stream_err,
        playout_device,
        streamCallback,
        &renderer,
    ) catch std.debug.panic("open playout failed: {f}", .{stream_err});
    defer playout.close(gpa);
    std.log.info("Output Format: {}", .{playout.format});

    if (!opt.play_sin) {
        capture_format = capture.format;
        if (capture.format.sample_rate != playout.format.sample_rate) {
            std.log.err("todo: implement sample conversion", .{});
            std.log.err("   input : {}", .{capture.format.sample_rate});
            std.log.err("   output: {}", .{playout.format.sample_rate});
            std.process.exit(0xff);
        }
        if (playout.format.sample_type != .f32) fatal(
            "todo: implement playout sample type {s}",
            .{@tagName(playout.format.sample_type)},
        );
        if (capture.format.sample_type != .f32) fatal(
            "todo: implement capture sample type {s}",
            .{@tagName(capture.format.sample_type)},
        );
    }

    capture.start(&stream_err) catch std.debug.panic(
        "start capture failed: {f}",
        .{stream_err},
    );
    defer capture.stop();
    playout.start(&stream_err) catch std.debug.panic(
        "start playout failed: {f}",
        .{stream_err},
    );
    defer playout.stop();

    std.log.info("press enter to stop...", .{});
    var buf: [10]u8 = undefined;
    _ = try std.Io.File.stdin().readStreaming(init.io, &.{&buf});
    std.log.info("stopping...", .{});
}

fn printDevices(devices: []const core.Device) !void {
    for (devices, 0..) |device, i| {
        std.debug.print("{}. {f}\n", .{ i, device.name });
    }
}

fn findDevice(direction: audio.Direction, device_str: []const u8) !core.Device {
    switch (global.directional(direction).updateDevices(global.arena, onUpdateDeviceEvent)) {
        .locked => unreachable,
        .result => |maybe_err| if (maybe_err) |err| fatal("failed to update output devices with {f}", .{err}),
    }

    const devices = core.global.directional(direction).devices.items;

    if (std.fmt.parseInt(usize, device_str, 10) catch null) |device_index| {
        if (device_index >= devices.len) fatal("device index {} is too big (only have {} devices)", .{ device_index, devices.len });
        return devices[device_index];
    }

    var match: ?struct {
        index: usize,
        device: core.Device,
    } = null;
    for (devices, 0..) |device, i| {
        if (std.mem.indexOf(u8, device.name.slice, device_str) == null)
            continue;
        if (match) |m| {
            std.debug.print("multiple devices match string '{s}'\n", .{device_str});
            std.debug.print("{}: {f}\n", .{ m.index, m.device.name });
            std.debug.print("{}: {f}\n", .{ i, device.name });
            std.process.exit(0xff);
        }
        match = .{ .index = i, .device = device };
    }
    return (match orelse {
        std.debug.print("string '{s}' does not match any devices of these {} devices:\n", .{ device_str, devices.len });
        try printDevices(devices);
        std.process.exit(0xff);
    }).device;
}

const Renderer = struct {
    state: f32 = 0,

    fn render(self: *Renderer, format: audio.Format, buffer: audio.Buffer) void {
        var next: [*]u8 = @ptrCast(buffer.ptr);
        for (0..buffer.frame_count) |_| {
            switch (format.sample_type) {
                inline else => |sample_type| writeSamplesT(
                    next,
                    format.sample_rate,
                    format.channel_count,
                    &self.state,
                    sample_type,
                ),
            }
            next += format.channel_count * format.sample_type.getByteLen();
        }
    }
};

fn writeSamplesT(
    out_ptr_void: *anyopaque,
    sample_rate: u32,
    channel_count: usize,
    state: *f32,
    comptime sample_type: audio.SampleType,
) void {
    const inc_ratio = 9.6 / @as(f32, @floatFromInt(sample_rate));
    const limit_ratio = 0.02;

    const out_ptr: [*]align(1) sample_type.Native() = @ptrCast(out_ptr_void);
    const sample = sample_type.fromF32(state.*);
    for (0..channel_count) |channel| {
        out_ptr[channel] = sample;
    }
    state.* += sample_type.asF32(sample_type.max()) * inc_ratio;
    const limit = sample_type.asF32(sample_type.max()) * limit_ratio;
    if (state.* >= limit) {
        state.* = -limit;
    }
}

const AudioCallbackData = struct {
    renderer: *Renderer,
};
fn streamCallback(
    userdata: *anyopaque,
    buffer: *anyopaque,
    frame_count: usize,
) void {
    const stream: *audio.Stream = @ptrCast(@alignCast(userdata));
    switch (stream.direction) {
        .capture => {
            if (global.play_sin) {
                //std.log.info("ignoring {} frames from capture", .{frame_count});
            } else {
                global.mutex.lock();
                defer global.mutex.unlock();
                const len = stream.format.getFrameLen() * frame_count;
                const buffer_u8: [*]u8 = @ptrCast(buffer);
                global.captured_samples.appendSlice(global.arena, buffer_u8[0..len]) catch @panic("OOM");
                global.captured_frame_count += frame_count;
                if (false) {
                    std.log.info(
                        "capture {} frames ({} total frames {} bytes buffered)",
                        .{ frame_count, global.captured_frame_count, global.captured_samples.items.len },
                    );
                }
            }
        },
        .playout => {
            const renderer: *Renderer = @ptrCast(@alignCast(stream.callback_data));
            if (global.play_sin) {
                renderer.render(
                    stream.format,
                    .{ .frame_count = frame_count, .ptr = buffer },
                );
            } else {
                global.mutex.lock();
                defer global.mutex.unlock();

                const copy_frame_count = @min(frame_count, global.captured_frame_count);
                const silence_frame_count = frame_count - copy_frame_count;
                const leftover_frame_count = global.captured_frame_count - copy_frame_count;
                copyAudioF32(
                    @ptrCast(@alignCast(buffer)),
                    stream.format.channel_count,
                    @ptrCast(@alignCast(global.captured_samples.items.ptr)),
                    global.capture_format.channel_count,
                    copy_frame_count,
                );

                const playout_buffer_u8: [*]u8 = @ptrCast(buffer);
                const playout_len_u8 = frame_count * stream.format.getFrameLen();
                const playout_copy_len_u8 = copy_frame_count * stream.format.getFrameLen();
                @memset(playout_buffer_u8[playout_copy_len_u8..playout_len_u8], 0);

                const leftover_u8 = leftover_frame_count * global.capture_format.getFrameLen();
                if (leftover_u8 > 0) {
                    const capture_copy_len_u8 = copy_frame_count * global.capture_format.getFrameLen();
                    std.mem.copyForwards(
                        u8,
                        global.captured_samples.items[0..leftover_u8],
                        global.captured_samples.items[capture_copy_len_u8..][0..leftover_u8],
                    );
                }
                global.captured_samples.items.len = leftover_u8;
                global.captured_frame_count = leftover_frame_count;
                if (false) {
                    std.log.debug(
                        "playout {} frames ({} silence, {} leftover)",
                        .{ copy_frame_count, silence_frame_count, leftover_frame_count },
                    );
                }
            }
        },
    }
}

fn copyAudioF32(
    dst: [*]f32,
    dst_channel_count: usize,
    src: [*]const f32,
    src_channel_count: usize,
    frame_count: usize,
) void {
    var dst_offset: usize = 0;
    var src_offset: usize = 0;
    for (0..frame_count) |_| {
        for (0..dst_channel_count) |channel| {
            dst[dst_offset] = src[src_offset + (channel % src_channel_count)];
            dst_offset += 1;
        }
        src_offset += src_channel_count;
    }
}

fn onUpdateDeviceEvent(event: core.UpdateDevicesEvent) void {
    switch (event) {
        .device_added => {},
        .device_removed => {},
        .device_name_changed => {},
    }
}
