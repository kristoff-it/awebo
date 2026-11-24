const VoicePanel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const Channel = awebo.Channel;
const Core = @import("../../Core.zig");
const VideoPreviewBox = @import("ScreenshareBox.zig");
const UiData = Core.VideoStream.UiData;

const Resolution = enum { @"1440p", @"1080p", @"720p" };
const Fps = enum { @"30", @"60" };

textureBin: std.ArrayList(*dvui.Texture) = .empty,
show_screenshare_window: bool = false,
screen_config: struct {
    resolution: Resolution = .@"1080p",
    lossless: bool = false,
    fps: Fps = .@"30",
    display_idx: usize = 0,
} = .{},
subviews: struct {
    screen_preview: VideoPreviewBox = .{},
    camera_preview: VideoPreviewBox = .{},
} = .{},

pub fn draw(vp: *VoicePanel, core: *Core, frozen: bool) !void {
    _ = frozen;

    while (vp.textureBin.pop()) |t| t.destroyLater();

    var box = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .expand = .both,
            .min_size_content = .{ .h = 40 },
            .background = true,
        },
    );
    defer box.deinit();

    const h = core.hosts.get(core.active_host).?;
    const c = h.channels.get(h.client.active_channel.?).?;
    const ac = &(core.active_call orelse {
        dvui.labelNoFmt(@src(), "Join this voice channel to see video controls.", .{}, .{});
        return;
    });

    if (ac.voice_id != c.id) {
        dvui.labelNoFmt(@src(), "Join this voice channel to see video controls.", .{}, .{});
        return;
    }

    const webcam_label = if (ac.camera == .off) "Webcam ON" else "Webcam OFF";
    if (dvui.button(@src(), webcam_label, .{}, .{})) {
        switch (ac.camera) {
            .off => try ac.cameraShareBegin(core),
            .requesting_permission, .sharing => try ac.cameraShareEnd(core),
        }
    }

    const screenshare_label = if (ac.screen == .off) "Screenshare ON" else "Screenshare OFF";
    if (dvui.button(@src(), screenshare_label, .{}, .{})) {
        switch (ac.screen) {
            .off => {
                vp.show_screenshare_window = true;
            },
            .requesting_permission, .sharing => try ac.screenshareEnd(core),
        }
    }

    if (vp.show_screenshare_window) {
        vp.configureScreensharePopup(ac, core);
    }

    var any_stream = false;

    for (ac.callers.keys(), ac.callers.values()) |id, *caller| {
        if (ac.caller_id) |self_cid| if (self_cid.eql(id)) continue;
        const caller_meta = h.client.callers.get(id).?;

        for (
            [2]?*Core.VideoStream{ caller.screen, caller.camera },
            [2]awebo.protocol.media.StreamKind{ .screen, .camera },
        ) |maybe_stream, kind| {
            const stream = maybe_stream orelse {
                // render caller with sessions that we are not watching
                const stream_format = switch (kind) {
                    else => unreachable,
                    .screen => if (caller_meta.state.share.screen) |s| s.format else continue,
                    .camera => caller_meta.state.share.camera orelse continue,
                };

                var session_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .border = .all(1),
                    .id_extra = (id.toInt() << 1) + @backingInt(kind),
                });
                defer session_box.deinit();

                const u = h.users.get(id.user_id).?;
                switch (kind) {
                    else => unreachable,
                    .screen => {
                        dvui.label(@src(), "{s} screenshare ({}x{}@{}, {t})", .{
                            u.display_name,
                            stream_format.config.width,
                            stream_format.config.height,
                            stream_format.config.fps,
                            stream_format.codec,
                        }, .{
                            .id_extra = (id.toInt() << 1) + @backingInt(kind),
                            .style = .window,
                        });
                    },
                    .camera => {
                        dvui.label(@src(), "{s} camera", .{u.display_name}, .{
                            .id_extra = (id.toInt() << 1) + @backingInt(kind),
                            .style = .window,
                        });
                    },
                }

                if (dvui.button(@src(), "Watch", .{}, .{ .id_extra = (id.toInt() << 1) + @backingInt(kind) })) {
                    try ac.shareSessionJoin(core, id, kind, stream_format);
                }

                continue;
            };

            any_stream = true;

            const maybe_frame = stream.swapFrontFrame(null);

            if (maybe_frame) |new| {
                defer new.deinit();
                const img = new.getImage();

                // std.log.debug("swap!", .{});

                var backend = dvui.currentWindow().backend;

                if (stream.ui_data == null) {
                    const tex: *dvui.Texture = try core.gpa.create(dvui.Texture);
                    switch (img) {
                        .videotoolbox, .vaapi => unreachable,
                        .yuv => |yuv| {
                            const ww: usize = @intCast(yuv.width);
                            const hh: usize = @intCast(yuv.height);
                            const half: usize = ((hh + 1) / 2) * ((ww + 1) / 2);
                            var planes = dvui.currentWindow().arena().alloc(u8, ww * hh + 2 * half) catch @panic("OOM");
                            @memcpy(planes[0 .. ww * hh], yuv.y);
                            @memcpy(planes[ww * hh ..][0..half], yuv.cr);
                            @memcpy(planes[ww * hh + half ..][0..half], yuv.cb);
                            tex.* = try backend.textureCreate(
                                @ptrCast(planes),
                                .{
                                    .width = @intCast(yuv.width),
                                    .height = @intCast(yuv.height),
                                    .interpolation = .nearest,
                                    .format = .fourcc_yv12,
                                },
                            );
                        },
                        .nv12 => |nv12| {
                            const ww: usize = @intCast(nv12.width);
                            const hh: usize = @intCast(nv12.height);
                            const half: usize = ((hh + 1) / 2) * ((ww + 1) / 2);
                            var planes = dvui.currentWindow().arena().alloc(u8, ww * hh + 2 * half) catch @panic("OOM");
                            @memcpy(planes[0 .. ww * hh], nv12.y);
                            @memcpy(planes[ww * hh ..], nv12.cbcr);
                            tex.* = try backend.textureCreate(
                                @ptrCast(planes),
                                .{
                                    .width = @intCast(nv12.width),
                                    .height = @intCast(nv12.height),
                                    .interpolation = .nearest,
                                    .format = .fourcc_yv12,
                                },
                            );
                        },
                        .bgra => |bgra| {
                            tex.* = try backend.textureCreate(
                                @ptrCast(bgra.pixels),
                                .{
                                    .width = @intCast(bgra.width),
                                    .height = @intCast(bgra.height),
                                    .interpolation = .nearest,
                                    .format = .bgra_32,
                                },
                            );
                        },
                    }

                    stream.ui_data = .{
                        .context = stream,
                        .data = tex,
                        .deinit = deinitTexture,
                    };
                } else {
                    const tex: *dvui.Texture = @ptrCast(@alignCast(stream.ui_data.?.data.?));
                    switch (img) {
                        .videotoolbox, .vaapi => unreachable,
                        .yuv => |yuv| {
                            const ww: usize = @intCast(yuv.width);
                            const hh: usize = @intCast(yuv.height);
                            const half: usize = ((hh + 1) / 2) * ((ww + 1) / 2);
                            var planes = dvui.currentWindow().arena().alloc(u8, ww * hh + 2 * half) catch @panic("OOM");
                            @memcpy(planes[0 .. ww * hh], yuv.y);
                            @memcpy(planes[ww * hh ..][0..half], yuv.cr);
                            @memcpy(planes[ww * hh + half ..][0..half], yuv.cb);
                            try backend.textureUpdate(tex.*, @ptrCast(planes));
                        },
                        .nv12 => |nv12| {
                            const ww: usize = @intCast(nv12.width);
                            const hh: usize = @intCast(nv12.height);
                            const half: usize = ((hh + 1) / 2) * ((ww + 1) / 2);
                            var planes = dvui.currentWindow().arena().alloc(u8, ww * hh + 2 * half) catch @panic("OOM");
                            @memcpy(planes[0 .. ww * hh], nv12.y);
                            @memcpy(planes[ww * hh ..], nv12.cbcr);
                            try backend.textureUpdate(tex.*, @ptrCast(planes));
                        },
                        .bgra => |bgra| {
                            try backend.textureUpdate(tex.*, @ptrCast(bgra.pixels));
                        },
                    }
                }
            }
        }
    }

    if (ac.screen != .off) {
        try vp.subviews.screen_preview.draw(core, .screen);
    }

    if (ac.camera != .off) {
        try vp.subviews.camera_preview.draw(core, .camera);
    }

    if (!any_stream) return;

    const timer_id = dvui.Id.extendId(null, @src(), 0);
    const millis_per_frame = std.time.ms_per_s / 60;
    const millis = @divFloor(dvui.frameTimeNS(), 1_000_000);
    const left = @as(i32, @intCast(@rem(millis, millis_per_frame)));
    const wait = 1000 * (millis_per_frame - left);
    dvui.timer(timer_id, wait);

    for (ac.callers.keys(), ac.callers.values(), 0..) |id, *caller, idx| {
        const extraf: f32 = @floatFromInt(idx);

        for (
            [2]?*Core.VideoStream{ caller.screen, caller.camera },
            [2]awebo.protocol.media.StreamKind{ .screen, .camera },
        ) |maybe_stream, kind| {
            const stream = maybe_stream orelse continue;

            if (stream.decoder == null) {
                const preview_width_pixels = 160 * 3;
                const width_ratio = 1920 / preview_width_pixels;
                const preview_height_pixels = 1080 / width_ratio;
                const w = dvui.floatingWindow(@src(), .{}, .{
                    .id_extra = (id.toInt() << 1) + @backingInt(kind),
                    .gravity_x = 1.0 - 0.5 * extraf,
                    .gravity_y = 1.0 - 0.5 * extraf,
                    // .background = false,
                    .border = null,
                    .padding = .all(0),
                    .margin = .all(0),
                    .expand = .ratio,
                    .min_size_content = .{
                        .w = @floatFromInt(preview_width_pixels),
                        .h = @floatFromInt(preview_height_pixels),
                    },
                });
                defer w.deinit();

                dvui.labelNoFmt(@src(), "LOADING", .{}, .{
                    .font = dvui.Font.theme(.title).larger(8),
                    .id_extra = (id.toInt() << 1) + @backingInt(kind),
                    .gravity_x = 0.5,
                    .gravity_y = 0.5,
                });

                if (dvui.button(@src(), "Close", .{}, .{
                    .id_extra = (id.toInt() << 1) + @backingInt(kind),
                    .gravity_x = 1,
                    .gravity_y = 1,
                })) {
                    try ac.shareSessionLeave(core, caller, id, kind);
                }

                continue;
            }

            const tex: *dvui.Texture = @ptrCast(@alignCast(if (stream.ui_data) |ui| ui.data.? else {
                std.log.debug("no texture", .{});
                continue;
            }));
            const preview_width_pixels = 160 * 3;
            const width_ratio = tex.width / preview_width_pixels;
            const preview_height_pixels = tex.height / width_ratio;

            const w = dvui.floatingWindow(@src(), .{}, .{
                .id_extra = (id.toInt() << 1) + @backingInt(kind),
                .gravity_x = 1.0 - 0.5 * extraf,
                .gravity_y = 1.0 - 0.5 * extraf,
                // .background = false,
                .border = null,
                .padding = .all(0),
                .margin = .all(0),
                .expand = .ratio,
                .min_size_content = .{
                    .w = @floatFromInt(preview_width_pixels),
                    .h = @floatFromInt(preview_height_pixels),
                },
            });
            defer w.deinit();

            try dvui.renderTexture(tex.*, w.wd.contentRectScale(), .{});

            if (dvui.button(@src(), "Close", .{}, .{
                .id_extra = (id.toInt() << 1) + @backingInt(kind),
                .gravity_x = 1,
                .gravity_y = 1,
            })) {
                try ac.shareSessionLeave(core, caller, id, kind);
            }
        }
    }
}

fn deinitTexture(gpa: Allocator, vp: ?*anyopaque, tex: ?*anyopaque) void {
    const voice: *VoicePanel = @ptrCast(@alignCast(vp.?));
    const texture: *dvui.Texture = @ptrCast(@alignCast(tex.?));

    voice.textureBin.append(gpa, texture) catch {
        std.log.warn("unable to collect texture for cleanup, leaking it!", .{});
        gpa.destroy(texture);
    };
}

fn configureScreensharePopup(vp: *VoicePanel, ac: *Core.ActiveCall, core: *Core) void {
    var fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{});
    defer fw.deinit();

    fw.dragAreaSet(dvui.windowHeader("Screenshare", "", &vp.show_screenshare_window));

    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{});
    defer vbox.deinit();

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        dvui.labelNoFmt(@src(), "Resolution:", .{}, .{});
        const choice: dvui.DropdownChoice(Resolution) = .{ .choice = &vp.screen_config.resolution };
        if (dvui.dropdownEnum(@src(), Resolution, choice, .{}, .{})) {}
    }
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        dvui.labelNoFmt(@src(), "FPS:", .{}, .{});
        const choice: dvui.DropdownChoice(Fps) = .{ .choice = &vp.screen_config.fps };
        if (dvui.dropdownEnum(@src(), Fps, choice, .{}, .{})) {}
    }
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        dvui.labelNoFmt(@src(), "Lossless compression:", .{}, .{});
        if (dvui.checkbox(@src(), &vp.screen_config.lossless, "", .{})) {}
    }

    const display: ?usize = if (!Core.ScreenCapture.supports_os_picker) blk: {
        core.screen_capture.os.mutex.lock(core.io) catch |err| switch (err) {
            error.Canceled => return,
        };
        defer core.screen_capture.os.mutex.unlock(core.io);

        const entries = core.screen_capture.os.outputs.values();
        {
            var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
            defer hbox.deinit();

            dvui.labelNoFmt(@src(), "Display:", .{}, .{});
            const choice: dvui.DropdownChoice(usize) = .{ .choice = &vp.screen_config.display_idx };
            const selected_index = vp.screen_config.display_idx;

            if (entries.len != 0) {
                var dd: dvui.DropdownWidget = undefined;
                dd.init(@src(), .{
                    .selected_index = selected_index,
                    .label = entries[selected_index].name orelse "loading...",
                }, .{});

                if (dd.dropped()) {
                    for (entries, 0..) |e, i| {
                        if (dd.addChoiceLabel(e.name orelse "loading...")) {
                            switch (choice) {
                                inline else => |ch| ch.* = i,
                            }
                        }
                    }
                }

                dd.deinit();
            } else {
                dvui.labelNoFmt(@src(), "LOADING", .{}, .{});
            }
        }

        if (entries.len >= vp.screen_config.display_idx) {
            const desc = entries[vp.screen_config.display_idx].description orelse "loading...";
            dvui.labelNoFmt(@src(), desc, .{}, .{});
        }

        break :blk vp.screen_config.display_idx;
    } else null;

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        if (dvui.button(@src(), "Cancel", .{}, .{})) vp.show_screenshare_window = false;

        const confirm_text = if (Core.ScreenCapture.supports_os_picker)
            "Select Display or Window"
        else
            "Start Sharing";

        if (dvui.button(@src(), confirm_text, .{}, .{})) {
            vp.show_screenshare_window = false;

            const width: u16, const height: u16 = switch (vp.screen_config.resolution) {
                .@"1440p" => .{ 2560, 1440 },
                .@"1080p" => .{ 1920, 1080 },
                .@"720p" => .{ 1280, 720 },
            };

            const fps: u8 = switch (vp.screen_config.fps) {
                .@"30" => 30,
                .@"60" => 60,
            };

            ac.screenshareBegin(core, vp.screen_config.lossless, .{
                .width = width,
                .height = height,
                .fps = fps,
            }, display) catch @panic("TODO");
        }
    }
}
