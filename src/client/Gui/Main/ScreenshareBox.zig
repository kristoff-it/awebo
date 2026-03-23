const ScreenshareBox = @This();

const builtin = @import("builtin");
const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("SDLBackend");
const Core = @import("../../Core.zig");

texture: ?dvui.Texture = null,

pub fn draw(sb: *ScreenshareBox, core: *Core, source: enum { webcam, screen }) !void {
    const extra = @intFromEnum(source);

    const id = dvui.Id.extendId(null, @src(), extra);
    const millis_per_frame = std.time.ms_per_s / 60;

    if (dvui.timerDoneOrNone(id)) {
        const maybe_frame = switch (source) {
            .screen => core.screen_capture.framePull(),
            .webcam => core.webcam_capture.swapFrame(null),
        };

        if (maybe_frame) |new| {
            defer new.deinit();
            const img = new.getImage();
            const width, const height, const planes = blk: switch (img) {
                .videotoolbox => unreachable,
                .yuv => |yuv| {
                    const ww: usize = @intCast(yuv.width);
                    const hh: usize = @intCast(yuv.height);
                    const half: usize = ((hh + 1) / 2) * ((ww + 1) / 2);
                    var planes = dvui.currentWindow().arena().alloc(u8, ww * hh + 2 * half) catch @panic("OOM");
                    @memcpy(planes[0 .. ww * hh], yuv.y);
                    @memcpy(planes[ww * hh ..][0..half], yuv.cr);
                    @memcpy(planes[ww * hh + half ..][0..half], yuv.cb);
                    break :blk .{ ww, hh, planes.ptr };
                },
                .nv12 => |nv12| {
                    const ww: usize = @intCast(nv12.width);
                    const hh: usize = @intCast(nv12.height);
                    const half: usize = ((hh + 1) / 2) * ((ww + 1) / 2);
                    var planes = dvui.currentWindow().arena().alloc(u8, ww * hh + 2 * half) catch @panic("OOM");
                    @memcpy(planes[0 .. ww * hh], nv12.y);
                    @memcpy(planes[ww * hh ..], nv12.cbcr);
                    for (0..half) |idx| {
                        planes[ww * hh ..][idx] = nv12.cbcr[idx * 2];
                        planes[ww * hh ..][idx * 2] = nv12.cbcr[idx * 2 + 1];
                    }
                    break :blk .{ ww, hh, planes.ptr };
                },
                .bgra => |bgra| {
                    break :blk .{ bgra.width, bgra.height, bgra.pixels };
                },
            };

            var backend = dvui.currentWindow().backend;
            if (sb.texture) |tex| {
                try backend.textureUpdate(tex, @ptrCast(planes));
            } else {
                sb.texture = try backend.textureCreate(
                    @ptrCast(planes),
                    @intCast(width),
                    @intCast(height),
                    .nearest,
                    if (img == .bgra) .bgra_32 else .fourcc_yv12,
                );
            }
        }
        const millis = @divFloor(dvui.frameTimeNS(), 1_000_000);
        const left = @as(i32, @intCast(@rem(millis, millis_per_frame)));
        const wait = 1000 * (millis_per_frame - left);
        dvui.timer(id, wait);
    }

    const tex = sb.texture orelse return;

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

    dvui.label(@src(), "{t} preview", .{source}, .{
        .gravity_x = 1,
        .gravity_y = 1,
    });
}
