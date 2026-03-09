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
    var btout: dvui.WidgetData = undefined;
    var disabled_opt = opt;
    // disabled_opt.tab_index = 0;
    disabled_opt.color_text = dvui.Color.average(control_opts.color(.text), control_opts.color(.fill));
    disabled_opt.data_out = &btout;

    bw.init(src, bo, disabled_opt);
    defer bw.deinit();

    bw.processEvents();
    bw.drawBackground();
    bw.drawFocus();

    dvui.labelNoFmt(@src(), label, .{}, .{ .color_text = disabled_opt.color_text });

    var tt: dvui.FloatingTooltipWidget = undefined;
    tt.init(@src(), .{ .active_rect = btout.borderRectScale().r }, .{ .background = false, .border = .{} });
    defer tt.deinit();

    if (tt.shown()) {
        var vbox: dvui.BoxWidget = undefined;
        vbox.init(@src(), .{}, dvui.FloatingTooltipWidget.defaults.override(.{ .expand = .both }));
        defer vbox.deinit();

        if (dvui.animationGet(tt.data().id, "xoffset")) |a| {
            var r = vbox.data().rect;
            r.x += 20 * (1.0 - a.value()) * (1.0 - a.value()) * @sin(a.value() * std.math.pi * 50);
            vbox.data().rectSet(r);
        }
        vbox.drawBackground();

        dvui.label(@src(), "{s}", .{enabled.off}, .{});
    }

    if (bw.clicked()) {
        dvui.animation(tt.data().id, "xoffset", .{
            .start_val = 0,
            .end_val = 1.0,
            .start_time = 0,
            .end_time = 500_000,
        });
    }

    return false;
}

fn tooltip(
    src: std.builtin.SourceLocation,
    init_opts: dvui.FloatingTooltipWidget.InitOptions,
    comptime fmt: []const u8,
    fmt_args: anytype,
    opts: dvui.Options,
) *dvui.FloatingTooltipWidget {
    var tt = dvui.widgetAlloc(dvui.FloatingTooltipWidget);
    tt.init(src, init_opts, opts.override(.{ .role = .tooltip }));
    if (tt.shown()) {
        var tl2 = dvui.textLayout(@src(), .{}, .{ .background = false });
        tl2.format(fmt, fmt_args, .{});
        tl2.deinit();
        if (tt.data().accesskit_node()) |ak_node| {
            var str_builder: std.Io.Writer.Allocating = .init(dvui.currentWindow().arena());
            str_builder.writer.print(fmt, fmt_args) catch {};
            dvui.AccessKit.nodeSetLabel(ak_node, str_builder.toOwnedSliceSentinel(0) catch "");
        }
    }
    return tt;
}
