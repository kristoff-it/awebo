const Gui = @This();

const dvui = @import("dvui");
const Core = @import("Core.zig");

active_screen: ActiveScreen = .main,
scenes: struct {
    empty: @import("Gui/Empty.zig") = .{},
    main: @import("Gui/Main.zig") = .{},
    settings: @import("Gui/Settings.zig") = .{},
} = .{},

pub const ActiveScreen = enum {
    loading,
    main,
    user_settings,
    server_settings,
};

pub fn draw(gui: *Gui, core: *Core) !void {
    var main_box = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{
            .expand = .both,
            .background = true,
        },
    );
    defer main_box.deinit();

    if (core.hosts.last_id == 0) {
        try gui.scenes.empty.draw(core);
        return;
    }

    switch (gui.active_screen) {
        .main => try gui.scenes.main.draw(core, &gui.active_screen),
        .user_settings => gui.scenes.settings.draw(core, &gui.active_screen),
        else => @panic("TODO"),
    }
}
