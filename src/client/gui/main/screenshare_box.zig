const std = @import("std");
const dvui = @import("dvui");
const Backend = @import("SDLBackend");

pub fn draw() !void {
    const w = dvui.floatingWindow(@src(), .{}, .{
        .gravity_x = 1,
        .gravity_y = 1,
        .background = false,
        .border = null,
        .padding = .{ .x = 160 * 3, .y = 90 * 3 },
        .margin = dvui.Rect.all(5),
    });
    defer w.deinit();

    dvui.labelNoFmt(@src(), "test", .{}, .{});

    var backend = dvui.currentWindow().backend;
    var pixels: [4]u32 = .{ 0x000000FF, 0x202020FF, 0x808080FF, 0xFFFFFF00 };
    const tex = try backend.textureCreate(std.mem.sliceAsBytes(&pixels).ptr, 2, 2, .nearest);
    try dvui.renderTexture(tex, w.wd.contentRectScale(), .{});
}
