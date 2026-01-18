const dvui = @import("dvui");
const awebo = @import("awebo");
const App = @import("../../../main_client_gui.zig").App;
const Host = awebo.Host;

pub fn draw(app: *App) void {
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

    for (app.core.hosts.items.values(), 0..) |h, idx| {
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
            app.active_host = h.client.host_id;
        }

        if (app.active_host == h.client.host_id) {
            item.wd.options.corner_radius = dvui.Rect.all(10);
            // item.wd.options.color_border = .{ .name = .text_press };
            item.wd.borderAndBackground(.{});
        }

        // dvui.image(@src(), .{ .source = h.logo }, .{
        //     .name = "zig favicon",
        //     .gravity_y = 0,
        //     .gravity_x = 0.5,
        //     .min_size_content = .{ .w = 40, .h = 40 },
        //     .id_extra = idx,
        // });
    }
}
