const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const core = @import("root").core;
const win32 = @import("win32").everything;

pub const c = @cImport(@cInclude("portaudio.h"));

const log = std.log.scoped(.portaudio);

pub const kind: core.audio.Kind = .legacy_portaudio;

pub fn processInit() error{PortAudio}!void {
    // on windows we MUST initialize COM before portaudio otherwise it will
    // initialize it and will do so with different options
    if (builtin.os.tag == .windows) {
        const hr = win32.CoInitializeEx(null, .{});
        if (hr != 0) std.debug.panic("CoInitializeEx failed, hresult=0x{x}", .{u32FromHr(hr)});
    }
    defer if (builtin.os.tag == .windows) win32.CoUninitialize();

    try must(c.Pa_Initialize());
}
pub fn threadInit() void {
    if (builtin.os.tag == .windows) {
        const hr = win32.CoInitializeEx(null, .{});
        if (hr != 0) std.debug.panic("CoInitializeEx failed, hresult=0x{x}", .{u32FromHr(hr)});
    }
}
pub fn threadDeinit() void {
    if (builtin.os.tag == .windows) {
        win32.CoUninitialize();
    }
}

fn u32FromHr(hr: i32) u32 {
    return @bitCast(hr);
}

fn must(err: c_int) error{PortAudio}!void {
    if (err == c.paNoError) return;
    log.err("{s}", .{c.Pa_GetErrorText(err)});
    return error.PortAudio;
}

pub const DeviceIteratorError = union(enum) {
    out_of_memory: void,
    get_device_count: c_int,
    pub fn set(self: *DeviceIteratorError, value: DeviceIteratorError) error{DeviceIterator} {
        self.* = value;
        return error.DeviceIterator;
    }
    pub fn format(self: DeviceIteratorError, writer: anytype) !void {
        switch (self) {
            .out_of_memory => try writer.writeAll("out of memory"),
            .get_device_count => |err| try writer.print(
                "get device count failed, error={} ({s})",
                .{ err, c.Pa_GetErrorText(err) },
            ),
        }
    }
};

pub const DeviceIterator = struct {
    direction: core.audio.Direction,
    count: usize,
    next_index: usize = 0,
    pub fn init(direction: core.audio.Direction, err: *DeviceIteratorError) error{DeviceIterator}!DeviceIterator {
        const count = c.Pa_GetDeviceCount();
        if (count < 0) return err.set(.{ .get_device_count = count });
        return .{ .direction = direction, .count = @intCast(count) };
    }
    pub fn deinit(self: *DeviceIterator) void {
        _ = self;
    }
    pub fn next(self: *DeviceIterator, gpa: Allocator, err: *DeviceIteratorError) error{DeviceIterator}!?core.Device {
        while (self.next_index < self.count) {
            const info = c.Pa_GetDeviceInfo(@intCast(self.next_index)).*;
            self.next_index += 1;
            const maxChannels = switch (self.direction) {
                .capture => info.maxInputChannels,
                .playout => info.maxOutputChannels,
            };
            if (maxChannels > 0) {
                const name = core.PoolString.getOrCreate(gpa, std.mem.span(info.name)) catch
                    return err.set(.out_of_memory);

                // TODO: this isn't right since multiple devices could have
                //       the same name but we'll just use it for now
                //       note we also can't use the index as that won't persist
                //       across reboots when devices are added/removed
                const token = name;
                token.addReference();

                return core.Device{ .name = name, .token = token };
            }
        }
        return null;
    }
};

pub const StreamCallbackFlags = c.PaStreamCallbackFlags;
pub const StreamCallbackTimeInfo = c.PaStreamCallbackTimeInfo;

fn findDeviceIndex(
    direction: core.audio.Direction,
    token: []const u8,
) ?c_int {
    const count = c.Pa_GetDeviceCount();
    if (count < 0) {
        log.err("{s}", .{c.Pa_GetErrorText(count)});
        return null;
    }
    var index: c_int = 0;
    while (index < count) : (index += 1) {
        const info = c.Pa_GetDeviceInfo(index).*;
        const maxChannels = switch (direction) {
            .capture => info.maxInputChannels,
            .playout => info.maxOutputChannels,
        };
        if (maxChannels > 0) {
            if (std.mem.eql(u8, token, std.mem.span(info.name))) {
                return index;
            }
        }
    }
    return null;
}

fn callback(
    input: ?*const anyopaque,
    output: ?*anyopaque,
    frame_count: c_ulong,
    time_info: [*c]const StreamCallbackTimeInfo,
    status_flags: StreamCallbackFlags,
    user_data: ?*anyopaque,
) callconv(.c) c_int {
    _ = time_info;
    _ = status_flags;
    const stream: *Stream = @ptrCast(@alignCast(user_data));
    switch (stream.direction) {
        .capture => {
            std.debug.assert(output == null);
            stream.callback_fn(stream, @alignCast(@constCast(input.?)), frame_count);
        },
        .playout => {
            std.debug.assert(input == null);
            stream.callback_fn(stream, @alignCast(output.?), frame_count);
        },
    }
    return 0;
}

const playout_format: core.audio.Format = .{
    .sample_type = .f32,
    .channel_count = 2,
    .sample_rate = 48_000,
};

pub const Stream = struct {
    // public fields
    direction: core.audio.Direction,
    callback_data: *anyopaque,
    format: core.audio.Format,
    max_buffer_frame_count: usize,

    device_index: c_int,
    stream: *c.PaStream = undefined,
    callback_fn: *const core.audio.CallbackFn,

    pub const Error = union(enum) {
        bad_device: void,
        generic: struct {
            error_code: c_int,
            what: [:0]const u8,
        },
        pub fn set(self: *Error, value: Error) error{Stream} {
            self.* = value;
            return error.Stream;
        }
        pub fn setGeneric(self: *Error, error_code: c_int, what: [:0]const u8) error{Stream} {
            self.* = .{ .generic = .{ .error_code = error_code, .what = what } };
            return error.Stream;
        }
        pub fn format(self: Error, writer: anytype) !void {
            switch (self) {
                .bad_device => try writer.writeAll("invalid or stale audio device"),
                .generic => |e| try writer.print(
                    "{s} failed, error={} ({s})",
                    .{ e.what, e.error_code, c.Pa_GetErrorText(e.error_code) },
                ),
            }
        }
    };

    pub fn open(
        out_stream: *Stream,
        direction: core.audio.Direction,
        err: *Error,
        device: ?core.Device,
        callback_fn: *const core.audio.CallbackFn,
        callback_data: *anyopaque,
    ) error{Stream}!void {
        const device_index: c_int = blk: {
            if (device) |d| {
                if (findDeviceIndex(direction, d.token.slice)) |index| break :blk index;
                return err.set(.bad_device);
            }
            break :blk switch (direction) {
                .capture => c.Pa_GetDefaultInputDevice(),
                .playout => c.Pa_GetDefaultOutputDevice(),
            };
        };
        const format = blk: {
            switch (direction) {
                .capture => {
                    const info = c.Pa_GetDeviceInfo(device_index).*;
                    break :blk core.audio.Format{
                        .sample_type = .f32,
                        .channel_count = 1,
                        .sample_rate = @intFromFloat(info.defaultSampleRate),
                    };
                },
                .playout => break :blk playout_format,
            }
        };
        const params: c.PaStreamParameters = .{
            .device = device_index,
            .channelCount = format.channel_count,
            .sampleFormat = switch (format.sample_type) {
                .i16 => c.paInt16,
                .i32 => c.paInt32,
                .f32 => c.paFloat32,
            },
            .suggestedLatency = 0,
            .hostApiSpecificStreamInfo = null,
        };

        // TODO: make this a buffer equivalent to 10ms@48k even at other sample rates
        const max_buffer_frame_count: usize = 480;
        const stream: *c.PaStream = blk: {
            var stream: *c.PaStream = undefined;
            const e = c.Pa_OpenStream(
                @ptrCast(&stream),
                switch (direction) {
                    .capture => &params,
                    .playout => null,
                },
                switch (direction) {
                    .capture => null,
                    .playout => &params,
                },
                @floatFromInt(format.sample_rate),
                @intCast(max_buffer_frame_count),
                0,
                callback,
                out_stream,
            );
            if (e != c.paNoError) return err.setGeneric(e, "OpenStream");
            break :blk stream;
        };
        errdefer {
            const e = c.Pa_CloseStream(stream);
            if (e != c.paNoError) std.debug.panic(
                "Pa_CloseStream failed with {} ({s})",
                .{ e, c.Pa_GetErrorText(e) },
            );
        }

        out_stream.* = .{
            .direction = direction,
            .callback_data = callback_data,
            .format = format,
            .max_buffer_frame_count = max_buffer_frame_count,
            .device_index = device_index,
            .stream = stream,
            .callback_fn = callback_fn,
        };

        log.debug("portaudio open stream: {any}", .{out_stream});
    }
    pub fn close(self: *Stream, gpa: Allocator) void {
        _ = gpa;
        const e = c.Pa_CloseStream(self.stream);
        if (e != c.paNoError) std.debug.panic(
            "Pa_CloseStream failed with {} ({s})",
            .{ e, c.Pa_GetErrorText(e) },
        );
    }
    pub fn start(self: *Stream, err: *Error) error{Stream}!void {
        const e = c.Pa_StartStream(self.stream);
        if (e != c.paNoError) return err.setGeneric(e, "StartStream");
    }
    pub fn stop(self: *Stream) void {
        const e = c.Pa_StopStream(self.stream);
        if (e != c.paNoError) std.debug.panic(
            "Pa_StopStream failed with {} ({s})",
            .{ e, c.Pa_GetErrorText(e) },
        );
    }
};
