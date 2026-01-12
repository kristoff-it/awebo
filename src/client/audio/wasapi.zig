const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const win32 = @import("win32").everything;
const core = @import("root").core;
const audio = core.audio;
const PoolString = core.PoolString;
const gpa = core.gpa;

fn u32FromHr(hr: i32) u32 {
    return @bitCast(hr);
}

pub fn processInit() !void {
    (try std.Thread.spawn(.{}, audioWarmup, .{})).detach();
}
pub fn threadInit() void {
    const hr = win32.CoInitializeEx(null, .{});
    // this isn't an error worth handling, if this fails which I've never seen happen
    // we might as well crash, something is probably horribly wrong
    if (hr < 0) std.debug.panic("CoInitializeEx failed, hresult=0x{x}", .{u32FromHr(hr)});
}
pub fn threadDeinit() void {
    win32.CoUninitialize();
}

// prevents the creation of IMMDeviceEnumerator from blocking for a long period
// of time on future calls
fn audioWarmup() void {
    threadInit();
    defer threadDeinit();

    const start = win32.GetTickCount();
    const enumerator: *win32.IMMDeviceEnumerator = blk: {
        var enumerator: *win32.IMMDeviceEnumerator = undefined;
        const hr = win32.CoCreateInstance(
            win32.CLSID_MMDeviceEnumerator,
            null,
            win32.CLSCTX_ALL,
            win32.IID_IMMDeviceEnumerator,
            @ptrCast(&enumerator),
        );
        if (hr < 0) return std.debug.panic(
            "CoCreateInstance MMDeviceEnumerator failed, hresult=0x{x}",
            .{u32FromHr(hr)},
        );
        break :blk enumerator;
    };
    const duration = win32.GetTickCount() - start;
    std.log.info("audio warmup took {} ms", .{duration});
    errdefer _ = enumerator.IUnknown.Release();
}

const HResultError = struct {
    hresult: i32,
    what: [:0]const u8,
    pub fn deviceIterator(self: *HResultError, hresult: i32, what: [:0]const u8) error{DeviceIterator} {
        self.* = .{ .hresult = hresult, .what = what };
        return error.DeviceIterator;
    }
    pub fn stream(self: *HResultError, hresult: i32, what: [:0]const u8) error{Stream} {
        self.* = .{ .hresult = hresult, .what = what };
        return error.Stream;
    }
    pub fn format(self: HResultError, writer: *Io.Writer) !void {
        try writer.print(
            "{s} failed, hresult=0x{x}",
            .{ self.what, @as(u32, @bitCast(self.hresult)) },
        );
    }
};

pub const DeviceIteratorError = HResultError;
pub const DeviceIterator = struct {
    enumerator: *win32.IMMDeviceEnumerator,
    collection: *win32.IMMDeviceCollection,
    count: u32,
    next_index: u32 = 0,

    pub fn init(direction: audio.Direction, err: *HResultError) error{DeviceIterator}!DeviceIterator {
        const enumerator: *win32.IMMDeviceEnumerator = blk: {
            var enumerator: *win32.IMMDeviceEnumerator = undefined;
            const hr = win32.CoCreateInstance(
                win32.CLSID_MMDeviceEnumerator,
                null,
                win32.CLSCTX_ALL,
                win32.IID_IMMDeviceEnumerator,
                @ptrCast(&enumerator),
            );
            if (hr < 0) return err.deviceIterator(hr, "CoCreateInstance MMDeviceEnumerator");
            break :blk enumerator;
        };
        errdefer _ = enumerator.IUnknown.Release();

        const collection: *win32.IMMDeviceCollection = blk: {
            var collection: *win32.IMMDeviceCollection = undefined;
            const hr = enumerator.EnumAudioEndpoints(
                switch (direction) {
                    .capture => .eCapture,
                    .playout => .eRender,
                },
                win32.DEVICE_STATE_ACTIVE,
                @ptrCast(&collection),
            );
            if (hr < 0) return err.deviceIterator(hr, "EnumAudioEndpoints");
            break :blk collection;
        };
        errdefer _ = collection.IUnknown.Release();

        const count: u32 = blk: {
            var count: u32 = undefined;
            const hr = collection.GetCount(&count);
            if (hr < 0) return err.deviceIterator(hr, "GetCount");
            break :blk count;
        };
        return .{
            .enumerator = enumerator,
            .collection = collection,
            .count = count,
        };
    }
    pub fn deinit(self: *DeviceIterator) void {
        _ = self.collection.IUnknown.Release();
        _ = self.enumerator.IUnknown.Release();
        self.* = undefined;
    }

    pub fn next(self: *DeviceIterator, _: Allocator, err: *HResultError) error{DeviceIterator}!?core.Device {
        if (self.next_index == self.count)
            return null;
        const index = self.next_index;
        self.next_index += 1;
        return try nextDevice(self.collection, index, err);
    }
};

const max_device_token_bytes = 400;

fn nextDevice(
    collection: *win32.IMMDeviceCollection,
    device_index: u32,
    err: *HResultError,
) error{DeviceIterator}!core.Device {
    const device: *win32.IMMDevice = blk: {
        var device: *win32.IMMDevice = undefined;
        const hr = collection.Item(device_index, @ptrCast(&device));
        if (hr < 0) return err.deviceIterator(hr, "GetDevice");
        break :blk device;
    };
    defer _ = device.IUnknown.Release();

    const endpoint: *win32.IMMEndpoint = blk: {
        var endpoint: *win32.IMMEndpoint = undefined;
        const hr = device.IUnknown.QueryInterface(win32.IID_IMMEndpoint, @ptrCast(&endpoint));
        if (hr < 0) return err.deviceIterator(hr, "GetDeviceEndPoint");
        break :blk endpoint;
    };
    defer _ = endpoint.IUnknown.Release();

    // The ID uniquely identifies the device among all audio endpoint devices
    const token: PoolString = blk: {
        var id: [*:0]u16 = undefined;
        const hr = device.GetId(@ptrCast(&id));
        if (hr < 0) return err.deviceIterator(hr, "GetDeviceId");
        defer win32.CoTaskMemFree(id);
        break :blk PoolString.getOrCreateWtf16Le(
            gpa,
            max_device_token_bytes,
            std.mem.span(id),
        ) catch |e| switch (e) {
            error.TooBig => return err.deviceIterator(win32.STATUS_NAME_TOO_LONG, "GetDeviceIdPoolString"),
            error.OutOfMemory => return err.deviceIterator(win32.E_OUTOFMEMORY, "GetDeviceIdPoolString"),
        };
    };
    errdefer token.removeReference();

    const props: *win32.IPropertyStore = blk: {
        var props: *win32.IPropertyStore = undefined;
        const hr = device.OpenPropertyStore(win32.STGM_READ, @ptrCast(&props));
        if (hr < 0) return err.deviceIterator(hr, "GetDeviceProps");
        break :blk props;
    };
    defer _ = props.IUnknown.Release();

    var friendly_name = std.mem.zeroes(win32.PROPVARIANT);
    defer {
        const hr = win32.PropVariantClear(&friendly_name);
        if (hr < 0) std.debug.panic("PropVariantClear failed, hresult=0x{x}", .{u32FromHr(hr)});
    }

    {
        const hr = props.GetValue(&win32.PKEY_Device_FriendlyName, &friendly_name);
        if (hr < 0) return err.deviceIterator(hr, "GetDeviceName");
    }

    return core.Device{
        .name = PoolString.getOrCreateWtf16Le(max_device_token_bytes, std.mem.span(friendly_name.Anonymous.Anonymous.Anonymous.pwszVal.?)) catch |e| switch (e) {
            error.TooBig => return err.deviceIterator(win32.STATUS_NAME_TOO_LONG, "GetDeviceIdPoolString"),
            error.OutOfMemory => return err.deviceIterator(win32.E_OUTOFMEMORY, "GetNamePoolString"),
        },
        .token = token,
    };
}

const facility_win32 = 7;
fn hresultFromWin32(c: win32.WIN32_ERROR) i32 {
    return @bitCast(@as(u32, 0x80000000) |
        (@as(u32, facility_win32) << 16) |
        (@intFromEnum(c) & 0xffff));
}

fn closeHandle(handle: win32.HANDLE) void {
    if (0 == win32.CloseHandle(handle)) std.debug.panic("CloseHandle failed, error={}", .{@intFromEnum(win32.GetLastError())});
}

fn getBitsPerSample(sample_type: audio.SampleType) u16 {
    return switch (sample_type) {
        .i16 => 16,
        .f32 => 32,
    };
}

const ext_format_map = std.StaticStringMap(audio.SampleType).initComptime(.{
    .{ &win32.MFAudioFormat_Float.Bytes, .f32 },
});

fn formatFromWin32(w: *const win32.WAVEFORMATEX) ?audio.Format {
    switch (w.wFormatTag) {
        win32.WAVE_FORMAT_EXTENSIBLE => {
            const ext: *const win32.WAVEFORMATEXTENSIBLE = @ptrCast(w);
            const sample_type = ext_format_map.get(&ext.SubFormat.Bytes) orelse return null;
            return .{
                .sample_type = sample_type,
                .channel_count = w.nChannels,
                .sample_rate = w.nSamplesPerSec,
            };
        },
        else => return null,
    }
}

const StreamClient = union {
    capture: *win32.IAudioCaptureClient,
    render: *win32.IAudioRenderClient,
    pub fn release(self: StreamClient, direction: audio.Direction) void {
        switch (direction) {
            .capture => _ = self.capture.IUnknown.Release(),
            .playout => _ = self.render.IUnknown.Release(),
        }
    }
};

pub const Stream = struct {
    // public fields
    direction: audio.Direction,
    callback_data: *anyopaque,
    format: audio.Format,
    max_buffer_frame_count: u32,

    device: ?core.Device,
    callback_fn: *const audio.CallbackFn,
    event: win32.HANDLE,
    enumerator: *win32.IMMDeviceEnumerator,
    mm_device: *win32.IMMDevice,
    audio_client: *win32.IAudioClient,
    stream_client: StreamClient,
    thread: ?win32.HANDLE = null,
    thread_data: ThreadData = undefined,

    pub const Error = union(enum) {
        hresult: HResultError,
        win32: struct {
            err: win32.WIN32_ERROR,
            what: [:0]const u8,
        },
        bad_device: void,
        pub fn set(self: *Error, e: Error) error{Stream} {
            self.* = e;
            return error.Stream;
        }
        pub fn setHr(self: *Error, c: i32, what: [:0]const u8) error{Stream} {
            self.* = .{ .hresult = .{ .hresult = c, .what = what } };
            return error.Stream;
        }
        pub fn setWin32(self: *Error, err: win32.WIN32_ERROR, what: [:0]const u8) error{Stream} {
            self.* = .{ .win32 = .{ .err = err, .what = what } };
            return error.Stream;
        }
        pub fn format(self: Error, writer: anytype) !void {
            switch (self) {
                .hresult => |e| try e.format(writer),
                .win32 => |e| try writer.print("{s} failed with {f}", .{ e.what, e.err }),
                .bad_device => try writer.writeAll("invalid device"),
            }
        }
    };

    pub fn open(
        out_stream: *Stream,
        direction: audio.Direction,
        err: *Error,
        device: ?core.Device,
        callback_fn: *const audio.CallbackFn,
        callback_data: *anyopaque,
    ) error{Stream}!void {
        const event = win32.CreateEventW(null, 0, 0, null) orelse return err.setHr(hresultFromWin32(win32.GetLastError()), "CreateEvent");
        errdefer closeHandle(event);

        const enumerator: *win32.IMMDeviceEnumerator = blk: {
            var enumerator: *win32.IMMDeviceEnumerator = undefined;
            const hr = win32.CoCreateInstance(
                win32.CLSID_MMDeviceEnumerator,
                null,
                win32.CLSCTX_ALL,
                win32.IID_IMMDeviceEnumerator,
                @ptrCast(&enumerator),
            );
            if (hr < 0) return err.setHr(hr, "CoCreateInstance MMDeviceEnumerator");
            break :blk enumerator;
        };
        errdefer _ = enumerator.IUnknown.Release();

        // TODO: call RegisterEndpointNotificationCallback
        //       to get notifications when the system default device changes

        const mm_device: *win32.IMMDevice = blk: {
            if (device) |non_default| {
                var token_buf: [max_device_token_bytes]u8 align(@alignOf(u16)) = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&token_buf);
                var al = std.array_list.Managed(u16).init(fba.allocator());
                std.unicode.wtf8ToWtf16LeArrayList(&al, non_default.token.slice) catch |e| switch (e) {
                    error.OutOfMemory => return err.set(.bad_device),
                    error.InvalidWtf8 => return err.set(.bad_device),
                };
                al.append(0) catch return err.set(.bad_device);

                var mm_device: *win32.IMMDevice = undefined;
                const hr = enumerator.GetDevice(@ptrCast(&token_buf), @ptrCast(&mm_device));
                if (hr < 0) return err.setHr(hr, "GetDevice");
                break :blk mm_device;
            }

            var mm_device: *win32.IMMDevice = undefined;
            const hr = enumerator.GetDefaultAudioEndpoint(
                switch (direction) {
                    .playout => win32.eRender,
                    .capture => win32.eCapture,
                },
                win32.eConsole,
                @ptrCast(&mm_device),
            );
            if (hr < 0) return err.setHr(hr, "GetSystemDefaultDevice");
            break :blk mm_device;
        };
        errdefer _ = mm_device.IUnknown.Release();

        const audio_client: *win32.IAudioClient = blk: {
            var audio_client: *win32.IAudioClient = undefined;
            const hr = mm_device.Activate(win32.IID_IAudioClient, win32.CLSCTX_ALL, null, @ptrCast(&audio_client));
            if (hr < 0) return err.setHr(hr, "ActivateDevice");
            break :blk audio_client;
        };
        errdefer _ = audio_client.IUnknown.Release();

        var format_win32: *win32.WAVEFORMATEX = undefined;
        {
            const hr = audio_client.GetMixFormat(@ptrCast(&format_win32));
            if (hr < 0) return err.setHr(hr, "GetMixFormat");
        }
        defer win32.CoTaskMemFree(format_win32);
        const format = formatFromWin32(format_win32) orelse return err.setHr(win32.AUDCLNT_E_UNSUPPORTED_FORMAT, "ParseMixFormat");

        {
            const hr = audio_client.Initialize(
                win32.AUDCLNT_SHAREMODE_SHARED,
                win32.AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
                0, // BufferDuration (I guess 0 is required for event-driven shared mode?)
                0, // Periodicity (0 required for shared mode)
                format_win32,
                null, // SessionGuid
            );
            if (hr < 0) return err.setHr(hr, "AudioClientInitiailize");
        }

        {
            const hr = audio_client.SetEventHandle(event);
            if (hr < 0) return err.setHr(hr, "SetEventHandle");
        }

        const max_buffer_frame_count: u32 = blk: {
            var max_buffer_frame_count: u32 = undefined;
            const hr = audio_client.GetBufferSize(&max_buffer_frame_count);
            if (hr < 0) return err.setHr(hr, "GetBufferSize");
            break :blk max_buffer_frame_count;
        };

        const stream_client: StreamClient = blk: {
            switch (direction) {
                .capture => {
                    var capture_client: *win32.IAudioCaptureClient = undefined;
                    const hr = audio_client.GetService(win32.IID_IAudioCaptureClient, @ptrCast(&capture_client));
                    if (hr < 0) return err.setHr(hr, "GetAudioCaptureClient");
                    break :blk .{ .capture = capture_client };
                },
                .playout => {
                    var render_client: *win32.IAudioRenderClient = undefined;
                    const hr = audio_client.GetService(win32.IID_IAudioRenderClient, @ptrCast(&render_client));
                    if (hr < 0) return err.setHr(hr, "GetAudioRenderClient");
                    break :blk .{ .render = render_client };
                },
            }
        };
        errdefer stream_client.release(direction);

        out_stream.* = .{
            .direction = direction,
            .callback_data = callback_data,
            .format = format,
            .max_buffer_frame_count = max_buffer_frame_count,

            .device = device,
            .callback_fn = callback_fn,
            .event = event,

            .enumerator = enumerator,
            .mm_device = mm_device,
            .audio_client = audio_client,
            .stream_client = stream_client,
        };
        if (device) |d| d.addReference();
    }
    pub fn close(self: *Stream) void {
        std.debug.assert(self.thread == null);
        if (self.device) |d| d.removeReference(gpa);
        _ = self.stream_client.release(self.direction);
        _ = self.audio_client.IUnknown.Release();
        _ = self.mm_device.IUnknown.Release();
        _ = self.enumerator.IUnknown.Release();
        closeHandle(self.event);
    }
    pub fn start(self: *Stream, err: *Error) error{Stream}!void {
        std.debug.assert(self.thread == null);
        self.thread_data = ThreadData{ .stream = self };
        self.thread = win32.CreateThread(
            null,
            0,
            &threadEntry,
            &self.thread_data,
            .{},
            null,
        ) orelse return err.setHr(
            hresultFromWin32(win32.GetLastError()),
            "CreateThread",
        );
    }

    pub fn stop(self: *Stream) void {
        const thread = self.thread orelse unreachable;
        self.thread_data.stop.store(true, .unordered);
        if (0 == win32.SetEvent(self.event)) std.debug.panic(
            "SetEvent failed with {f}",
            .{win32.GetLastError()},
        );
        const infinite: u32 = 0xffffffff;
        switch (win32.WaitForSingleObject(self.thread, infinite)) {
            @intFromEnum(win32.WAIT_OBJECT_0) => {},
            else => |result| std.debug.panic(
                "unexpected wait result {} (error={f})",
                .{ result, win32.GetLastError() },
            ),
        }
        std.debug.assert(self.thread_data.exited.load(.seq_cst));
        closeHandle(thread);
        self.thread_data = undefined;
        self.thread = null;
    }
};

const ThreadData = struct {
    stream: *Stream,
    stop: std.atomic.Value(bool) = .{ .raw = false },
    exited: std.atomic.Value(bool) = .{ .raw = false },
    err: ?Stream.Error = null,

    pub fn onThreadExit(self: *ThreadData) void {
        self.exited.store(true, .seq_cst);
    }
    pub fn setError(self: *ThreadData, err: Stream.Error) void {
        self.err = self.err orelse err;
    }
};

fn threadEntry(context: ?*anyopaque) callconv(.winapi) u32 {
    const thread_data: *ThreadData = @ptrCast(@alignCast(context));
    defer thread_data.onThreadExit();

    {
        const hr = win32.SetThreadDescription(
            win32.GetCurrentThread(),
            @import("win32").zig.L("awebo-audio-stream"),
        );
        if (hr < 0) {
            std.log.warn("SetThreadDescription failed with 0x{x}", .{u32FromHr(hr)});
        }
    }

    threadInit();
    defer threadDeinit();

    var err: Stream.Error = undefined;
    @call(.always_inline, threadEntry2, .{ &err, thread_data.stream, &thread_data.stop }) catch {
        std.log.err("TODO: report this error to the application: {f}", .{err});
        thread_data.setError(err);
        return 0xff;
    };
    return 0;
}
fn threadEntry2(
    err: *Stream.Error,
    stream: *Stream,
    stop: *std.atomic.Value(bool),
) error{Stream}!void {
    if (0 == win32.SetThreadPriority(win32.GetCurrentThread(), win32.THREAD_PRIORITY_TIME_CRITICAL))
        return err.setWin32(win32.GetLastError(), "SetThreadPriority");

    if (stream.direction == .playout) {
        try getPlayout(err, stream);
    }

    {
        const hr = stream.audio_client.Start();
        if (hr < 0) return err.setHr(hr, "StartAudioClient");
    }
    defer {
        const hr = stream.audio_client.Stop();
        if (hr < 0) std.debug.panic("Stop IAudioClient failed, hresult=0x{x}", .{hr});
    }

    while (true) {
        switch (stream.direction) {
            .capture => try giveCapture(err, stream),
            .playout => try getPlayout(err, stream),
        }

        {
            const result = win32.WaitForSingleObject(stream.event, win32.INFINITE);
            if (result != @intFromEnum(win32.WAIT_OBJECT_0)) std.debug.panic(
                "WaitForSingleObject returned {}",
                .{result},
            );
        }
        if (stop.load(.unordered))
            return;
    }
}

fn getPlayout(
    err: *Stream.Error,
    stream: *Stream,
) error{Stream}!void {
    const padding = blk: {
        var padding: u32 = undefined;
        const hr = stream.audio_client.GetCurrentPadding(&padding);
        if (hr < 0) return err.setHr(hr, "GetCurrentPadding");
        break :blk padding;
    };

    std.debug.assert(padding <= stream.max_buffer_frame_count);
    const available = stream.max_buffer_frame_count - padding;
    if (available > 0) {
        const buffer = blk: {
            var buffer: [*]u8 = undefined;
            const hr = stream.stream_client.render.GetBuffer(available, @ptrCast(&buffer));
            if (hr < 0) return err.setHr(hr, "GetBuffer");
            break :blk buffer;
        };

        stream.callback_fn(stream, @ptrCast(@alignCast(buffer)), available);

        {
            const hr = stream.stream_client.render.ReleaseBuffer(available, 0);
            if (hr < 0) return err.setHr(hr, "ReleaseBuffer");
        }
    }
}

fn giveCapture(
    err: *Stream.Error,
    stream: *Stream,
) error{Stream}!void {
    while (true) {
        var buffer: [*]u8 = undefined;
        var frame_count: u32 = undefined;
        var flags: u32 = undefined;

        switch (stream.stream_client.capture.GetBuffer(@ptrCast(&buffer), &frame_count, &flags, null, null)) {
            win32.S_OK => {
                // TODO: handle flag DATA_DISCONTINUITY
                // TODO: handle flag SILENT
                // TODO: handle flag TIMESTAMP_ERROR
                std.debug.assert(frame_count != 0);
                std.debug.assert(frame_count <= stream.max_buffer_frame_count);

                stream.callback_fn(stream, @ptrCast(@alignCast(buffer)), frame_count);

                {
                    const hr = stream.stream_client.capture.ReleaseBuffer(frame_count);
                    if (hr < 0) return err.setHr(hr, "ReleaseBuffer");
                }
            },
            win32.AUDCLNT_S_BUFFER_EMPTY => return,
            else => |hr| return err.setHr(hr, "GetBuffer"),
        }
    }
}
