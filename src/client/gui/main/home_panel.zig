const dvui = @import("dvui");

pub fn draw() void {
    dvui.labelNoFmt(@src(), "home", .{}, .{});
}
