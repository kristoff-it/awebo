const HomePanel = @This();

const dvui = @import("dvui");

pub fn draw(hp: *HomePanel) void {
    _ = hp;
    dvui.labelNoFmt(@src(), "home", .{}, .{});
}
