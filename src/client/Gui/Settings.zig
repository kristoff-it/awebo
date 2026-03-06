const Settings = @This();

const std = @import("std");
const dvui = @import("dvui");
const Av = @import("Settings/Av.zig");
const Gui = @import("../Gui.zig");
const Core = @import("../Core.zig");

active_page: std.meta.FieldEnum(Pages) = .av,
pages: Pages = .{},

const Pages = struct {
    av: Av = .{},
};

pub fn draw(s: *Settings, core: *Core, active_scene: *Gui.ActiveScene) void {
    s.sidebar();
    s.page(core, active_scene);
}

pub fn sidebar(s: *Settings) void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
    });
    defer vbox.deinit();

    dvui.labelNoFmt(@src(), "Settings", .{}, .{
        .gravity_x = 0.5,
        .font = dvui.Font.theme(.title).larger(4),
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

    inline for (comptime std.meta.fields(Pages), 0..) |p, idx| {
        const item = dvui.menuItem(@src(), .{}, .{
            .gravity_x = 0,
            .id_extra = idx,
            .expand = .horizontal,
        });
        defer item.deinit();

        const pp: std.meta.FieldEnum(Pages) = @enumFromInt(idx);

        if (item.activated) {
            if (s.active_page != pp) {
                s.active_page = pp;
                s.core.audio.captureTestStop();
            }
        }

        if (s.active_page == pp) {
            // item.wd.options.color_fill = .{ .name = .fill_press };
            item.wd.options.background = true;
            // try item.drawBackground(.{});
        }

        dvui.labelNoFmt(@src(), @FieldType(Pages, p.name).menu_name, .{}, .{
            .font = dvui.Font.theme(.title).larger(2),
            .id_extra = idx,
        });
    }
}

fn page(s: *Settings, core: *Core, active_scene: *Gui.ActiveScene) void {
    switch (s.active_page) {
        inline else => |tag| {
            const p = &@field(s.pages, @tagName(tag));

            var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .background = true,
                .border = .{ .x = 1 },
            });
            defer vbox.deinit();

            {
                var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .expand = .horizontal,
                    .background = true,
                    .border = .{ .x = 1 },
                });
                defer hbox.deinit();
                dvui.labelNoFmt(@src(), @FieldType(Pages, @tagName(tag)).tab_name, .{}, .{
                    .gravity_x = 0.5,
                    .font = dvui.Font.theme(.title).larger(4),
                });

                if (dvui.button(@src(), "Exit", .{}, .{
                    .gravity_x = 1,
                    .gravity_y = 0.5,
                })) {
                    core.audio.captureTestStop();
                    active_scene.* = .main;
                }
            }
            _ = dvui.separator(@src(), .{ .expand = .horizontal });
            _ = dvui.spacer(@src(), .{});

            try p.draw(core);
        },
    }
}
