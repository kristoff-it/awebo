const VoicePanel = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const Channel = awebo.Channel;
const Core = @import("../../Core.zig");
const VideoPreviewBox = @import("ScreenshareBox.zig");
const UiData = Core.VideoStream.UiData;

textureBin: std.ArrayList(*dvui.Texture) = .empty,
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

    const screenshare_label = if (ac.screenshare) "Screenshare OFF" else "Screenshare ON";
    if (dvui.button(@src(), screenshare_label, .{}, .{})) {
        if (ac.screenshare) {
            ac.screenshareEnd(core);
        } else {
            ac.screenshareBegin(core);
        }
    }

    var any_stream = false;

    for (ac.callers.values()) |*caller| {
        const screen = caller.screen orelse continue;
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
                    .bgra => |bgra| {
                        tex.* = try backend.textureCreate(
                            bgra.pixels.?,
                            @intCast(bgra.width),
                            @intCast(bgra.height),
                            .nearest,
                            .bgra_32,
                        );
                    },
                    .yuv => |yuv| {
                        const ww: usize = @intCast(yuv.width);
                        const hh: usize = @intCast(yuv.height);
                        const half: usize = ((hh + 1) / 2) * ((ww + 1) / 2);
                        var planes = dvui.currentWindow().arena().alloc(u8, ww * hh + 2 * half) catch @panic("OOM");
                        @memcpy(planes[0 .. ww * hh], yuv.planes[0]);
                        @memcpy(planes[ww * hh ..][0..half], yuv.planes[2]);
                        @memcpy(planes[ww * hh + half ..][0..half], yuv.planes[1]);
                        tex.* = try backend.textureCreate(
                            @ptrCast(planes),
                            @intCast(yuv.width),
                            @intCast(yuv.height),
                            .nearest,
                            .fourcc_yv12,
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
                    .bgra => |bgra| try backend.textureUpdate(tex.*, bgra.pixels.?),
                    .yuv => |yuv| {
                        const ww: usize = @intCast(yuv.width);
                        const hh: usize = @intCast(yuv.height);
                        const half: usize = ((hh + 1) / 2) * ((ww + 1) / 2);
                        var planes = dvui.currentWindow().arena().alloc(u8, ww * hh + 2 * half) catch @panic("OOM");
                        @memcpy(planes[0 .. ww * hh], yuv.planes[0]);
                        @memcpy(planes[ww * hh ..][0..half], yuv.planes[2]);
                        @memcpy(planes[ww * hh + half ..][0..half], yuv.planes[1]);
                        try backend.textureUpdate(tex.*, @ptrCast(planes));
                    },
                }
            }
        }
    }

    if (ac.screenshare) {
        std.log.debug("rendering screenshare preview", .{});
        try vp.subviews.screen_preview.draw(core, .screen);
    }

    if (!any_stream) return;

    for (ac.callers.values(), 0..) |*caller, idx| {
        const screen = caller.screen orelse continue;
        const tex: *dvui.Texture = @ptrCast(@alignCast(if (screen.ui_data) |ui| ui.data.? else {
            std.log.debug("no texture", .{});
            continue;
        }));
        const preview_width_pixels = 160 * 3;
        const width_ratio = tex.width / preview_width_pixels;
        const preview_height_pixels = tex.height / width_ratio;

        const extraf: f32 = @floatFromInt(idx);
        const w = dvui.floatingWindow(@src(), .{ .window_avoid = .nudge_once }, .{
            .id_extra = idx,
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
            screen.destroy(core.gpa);
            caller.screen = null;
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
