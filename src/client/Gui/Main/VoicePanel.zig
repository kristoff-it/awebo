const VoicePanel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const Channel = awebo.Channel;
const Core = @import("../../Core.zig");
const VideoPreviewBox = @import("ScreenshareBox.zig");
const UiData = Core.VideoStream.UiData;

const Resolution = enum { @"1080p", @"720p" };
const Fps = enum { @"30", @"60" };

textureBin: std.ArrayList(*dvui.Texture) = .empty,
show_screenshare_window: bool = false,
screen_config: struct {
    resolution: Resolution = .@"1080p",
    lossless: bool = false,
    fps: Fps = .@"30",
} = .{},
subviews: struct {
    screen_preview: VideoPreviewBox = .{},
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
        const screen = caller.screen orelse {
            // render caller with sessions that we are not watching
            const caller_meta = h.client.callers.get(id).?;
            const screen = caller_meta.state.share.screen orelse continue;

            var session_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .border = .all(1),
            });
            defer session_box.deinit();

            const u = h.users.get(id.user_id).?;
            dvui.label(@src(), "{s} screenshare ({}x{}@{}, {t})", .{
                u.display_name,
                screen.format.config.width,
                screen.format.config.height,
                screen.format.config.fps,
                screen.format.codec,
            }, .{
                .id_extra = id.toInt(),
                .style = .window,
            });

            if (dvui.button(@src(), "Watch", .{}, .{ .id_extra = id.toInt() })) {
                try ac.shareSessionJoin(core, id, .screen, screen.format);
            }

            continue;
        };
        any_stream = true;

        const maybe_frame = screen.swapFrontFrame(null);

        if (maybe_frame) |new| {
            defer new.deinit();
            const img = new.getImage();

            std.log.debug("swap!", .{});

            var backend = dvui.currentWindow().backend;

            if (screen.ui_data == null) {
                const tex: *dvui.Texture = try core.gpa.create(dvui.Texture);
                switch (img) {
                    .videotoolbox => unreachable,
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
                            @intCast(yuv.width),
                            @intCast(yuv.height),
                            .nearest,
                            .fourcc_yv12,
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
                            @intCast(nv12.width),
                            @intCast(nv12.height),
                            .nearest,
                            .fourcc_yv12,
                        );
                    },
                    .bgra => |bgra| {
                        tex.* = try backend.textureCreate(
                            @ptrCast(bgra.pixels),
                            @intCast(bgra.width),
                            @intCast(bgra.height),
                            .nearest,
                            .bgra_32,
                        );
                    },
                }

                screen.ui_data = .{
                    .context = screen,
                    .data = tex,
                    .deinit = deinitTexture,
                };
            } else {
                const tex: *dvui.Texture = @ptrCast(@alignCast(screen.ui_data.?.data.?));
                switch (img) {
                    .videotoolbox => unreachable,
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

    if (ac.screen != .off) {
        try vp.subviews.screen_preview.draw(core, .screen);
    }

    if (!any_stream) return;

    for (ac.callers.keys(), ac.callers.values()) |id, *caller| {
        const src = @src();
        const extraf: f32 = @floatFromInt(id.toInt());

        const screen = caller.screen orelse continue;

        if (screen.decoder == null) {
            const preview_width_pixels = 160 * 3;
            const width_ratio = 1920 / preview_width_pixels;
            const preview_height_pixels = 1080 / width_ratio;
            const w = dvui.floatingWindow(src, .{}, .{
                .id_extra = id.toInt(),
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
                .id_extra = id.toInt(),
                .gravity_x = 0.5,
                .gravity_y = 0.5,
            });

            if (dvui.button(@src(), "Close", .{}, .{
                .gravity_x = 1,
                .gravity_y = 1,
            })) {
                try ac.shareSessionLeave(core, caller, id, .screen);
            }

            continue;
        }

        const tex: *dvui.Texture = @ptrCast(@alignCast(if (screen.ui_data) |ui| ui.data.? else {
            std.log.debug("no texture", .{});
            continue;
        }));
        const preview_width_pixels = 160 * 3;
        const width_ratio = tex.width / preview_width_pixels;
        const preview_height_pixels = tex.height / width_ratio;

        const w = dvui.floatingWindow(src, .{}, .{
            .id_extra = id.toInt(),
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
            .gravity_x = 1,
            .gravity_y = 1,
        })) {
            try ac.shareSessionLeave(core, caller, id, .screen);
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

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer hbox.deinit();

        if (dvui.button(@src(), "Cancel", .{}, .{})) vp.show_screenshare_window = false;
        if (dvui.button(@src(), "Start Sharing", .{}, .{})) {
            vp.show_screenshare_window = false;

            const width: u16, const height: u16 = switch (vp.screen_config.resolution) {
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
            }) catch @panic("TODO");
        }
    }
}
