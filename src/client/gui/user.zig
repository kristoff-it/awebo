const std = @import("std");
const dvui = @import("dvui");
const client = @import("../../main_client_gui.zig");
const core = @import("../core.zig");

const Pages = struct {
    pub const av = @import("user/av.zig");
};

pub var state: struct {
    active_page: std.meta.DeclEnum(Pages) = .av,
} = .{};

pub fn draw(core_state: *core.State) void {
    sidebar();
    settings_page(core_state);
    if (dvui.button(@src(), "Exit", .{}, .{})) {
        client.state.active_screen = .main;
    }
}

pub fn sidebar() void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
    });
    defer vbox.deinit();

    dvui.labelNoFmt(@src(), "Settings", .{}, .{
        .gravity_x = 0.5,
        .font = .theme(.title).larger(4),
    });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var list_scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .vertical });
    defer list_scroll.deinit();

    var menu = dvui.menu(
        @src(),
        .vertical,
        .{
            .expand = .vertical,
            .min_size_content = .{ .w = 250 },
            .background = true,
            .margin = .{ .x = 8, .y = 8, .w = 8 },
            // .color_fill = .{ .name = .fill },
        },
    );
    defer menu.deinit();

    inline for (comptime std.meta.declarations(Pages), 0..) |p, idx| {
        const item = dvui.menuItem(@src(), .{}, .{
            .gravity_x = 0,
            .id_extra = idx,
            .expand = .horizontal,
        });
        defer item.deinit();

        const pp: std.meta.DeclEnum(Pages) = @enumFromInt(idx);

        if (item.activated) {
            state.active_page = pp;
        }

        if (state.active_page == pp) {
            // item.wd.options.color_fill = .{ .name = .fill_press };
            item.wd.options.background = true;
            // try item.drawBackground(.{});
        }

        const page = @field(Pages, p.name);
        dvui.labelNoFmt(@src(), page.menu_name, .{}, .{
            .font = .theme(.title).larger(2),
            .id_extra = idx,
        });
    }
}

fn settings_page(app_state: *core.State) void {
    switch (state.active_page) {
        inline else => |tag| {
            const page = @field(Pages, @tagName(tag));
            try page.draw(app_state);
        },
    }
}
