const HostBar = @This();

const dvui = @import("dvui");
const awebo = @import("awebo");
const Host = awebo.Host;
const Core = @import("../../Core.zig");
const awebby = @embedFile("appicon");

pub fn draw(hb: *HostBar, core: *Core) void {
    _ = hb;

    var bar = dvui.scrollArea(
        @src(),
        .{},
        .{
            .expand = .vertical,
            // .color_fill = .{ .name = .fill_window },
        },
    );
    defer bar.deinit();

    var box = dvui.menu(
        @src(),
        .vertical,
        .{
            .expand = .vertical,
            .min_size_content = .{ .w = 40 },
            .background = true,
            .margin = .{ .x = 8, .w = 8 },
            .padding = .{ .y = 5, .h = 5 },
        },
    );
    defer box.deinit();

    for (core.hosts.items.values(), 0..) |h, idx| {
        var item = dvui.menuItem(@src(), .{}, .{
            .expand = .horizontal,
            .min_size_content = .{ .w = 40, .h = 40 },
            .id_extra = idx,
            .margin = .{ .y = 5 },
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(100),
            .background = true,
        });
        defer item.deinit();

        if (item.activated) {
            core.active_host = h.client.host_id;
        }

        if (core.active_host == h.client.host_id) {
            item.wd.options.corner_radius = dvui.Rect.all(10);
            // item.wd.options.color_border = .{ .name = .text_press };
            item.wd.borderAndBackground(.{});
        }

        _ = dvui.image(@src(), .{
            .source = .{
                .imageFile = .{
                    .bytes = awebby,
                    .name = "server-logo",
                },
            },
        }, .{
            .min_size_content = .{ .w = 35, .h = 35 },
            .id_extra = idx,
            .background = true,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(100),
            .gravity_y = 0.5,
            .gravity_x = 1,
            // .color_border = .{ .name = .accent },
        });
    }
}
