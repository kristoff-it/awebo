//! Customized DVUI widgets
const std = @import("std");
const dvui = @import("dvui");

pub const Enabled = union(enum) {
    on,
    off: []const u8, // the reason why the widget is disabled
};

/// Same as a DVUI button but can also be disabled
pub fn button(
    src: std.builtin.SourceLocation,
    enabled: Enabled,
    label: []const u8,
    bo: dvui.ButtonWidget.InitOptions,
    opt: dvui.Options,
) bool {
    if (enabled == .on) return dvui.button(src, label, bo, opt);

    var bw: dvui.ButtonWidget = undefined;

    const control_opts: dvui.Options = .{};
    var ttout: dvui.WidgetData = undefined;
    var disabled_opt = opt;
    disabled_opt.tab_index = 0;
    disabled_opt.color_text = dvui.Color.average(control_opts.color(.text), control_opts.color(.fill));
    disabled_opt.data_out = &ttout;

    bw.init(src, bo, disabled_opt);
    defer bw.deinit();

    dvui.tooltip(@src(), .{ .active_rect = ttout.borderRectScale().r }, "{s}", .{enabled.off}, .{});

    bw.drawBackground();
    bw.drawFocus();
    dvui.labelNoFmt(@src(), label, .{}, .{ .color_text = disabled_opt.color_text });
    return false;
}
