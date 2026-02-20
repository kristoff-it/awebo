const builtin = @import("builtin");
const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("SDLBackend");
const Core = @import("../../Core.zig");

var textures: [2]?dvui.Texture = .{ null, null };

pub fn draw(core: *Core) !void {
    if (core.webcam_capture.share_intent) try drawSource(core, .webcam);
    if (core.screen_capture.share_intent) try drawSource(core, .screen);
}

pub fn drawSource(core: *Core, source: enum { webcam, screen }) !void {
    const extra = @intFromEnum(source);

    const id = dvui.Id.extendId(null, @src(), extra);
    const millis_per_frame = 250;

    if (dvui.timerDoneOrNone(id)) {
        const maybe_frame = switch (source) {
            .screen => core.screen_capture.swapFrame(null),
            .webcam => core.webcam_capture.swapFrame(null),
        };

        if (maybe_frame) |new| {
            defer new.deinit();
            const img = new.getPixels();
            const pixels = img.pixels orelse {
                std.log.debug("null pixels", .{});
                return;
            };

            var backend = dvui.currentWindow().backend;
            textures[extra] = try backend.textureCreate(pixels, @intCast(img.width), @intCast(img.height), .nearest);
        }
        const millis = @divFloor(dvui.frameTimeNS(), 1_000_000);
        const left = @as(i32, @intCast(@rem(millis, millis_per_frame)));
        const wait = 1000 * (millis_per_frame - left);
        dvui.timer(id, wait);
    }

    const tex = textures[extra] orelse return;

    const preview_width_pixels = 160 * 3;
    const width_ratio = tex.width / preview_width_pixels;
    const preview_height_pixels = tex.height / width_ratio;

    const extraf: f32 = @floatFromInt(extra);
    const w = dvui.floatingWindow(@src(), .{}, .{
        .id_extra = extra,
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

    try dvui.renderTexture(tex, w.wd.contentRectScale(), .{});
}
