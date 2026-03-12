const VoicePanel = @This();

const std = @import("std");
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const Channel = awebo.Channel;
const Core = @import("../../Core.zig");
const VideoPreviewBox = @import("ScreenshareBox.zig");

subviews: struct {
    screen_preview: VideoPreviewBox = .{},
} = .{},

pub fn draw(vp: *VoicePanel, core: *Core, frozen: bool) !void {
    _ = frozen;

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
            const pixels = img.pixels orelse {
                std.log.debug("null pixels", .{});
                return;
            };

            std.log.debug("swap!", .{});

            var backend = dvui.currentWindow().backend;

            if (screen.ui_data == null) {
                const tex: *dvui.Texture = try core.gpa.create(dvui.Texture);
                tex.* = try backend.textureCreate(
                    pixels,
                    @intCast(img.width),
                    @intCast(img.height),
                    .nearest,
                    .bgra_32,
                );

                screen.ui_data = tex;
            } else {
                const tex: *dvui.Texture = @ptrCast(@alignCast(screen.ui_data.?));
                try backend.textureUpdate(tex.*, pixels);
            }
        }
    }

    if (!any_stream) return;

    for (ac.callers.values(), 0..) |*caller, idx| {
        const screen = caller.screen orelse continue;
        const tex: *dvui.Texture = @ptrCast(@alignCast(screen.ui_data orelse {
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

    if (ac.screenshare) {
        try vp.subviews.screen_preview.draw(core, .screen);
    }
}
