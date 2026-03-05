const dvui = @import("dvui");

pub fn draw() void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .horizontal,
    });
    defer box.deinit();

    dvui.spinner(@src(), .{
        .expand = .horizontal,
    });

    dvui.labelNoFmt(@src(), "Loading...", .{}, .{
        .gravity_x = 0.5,
        .expand = .horizontal,
    });
}
