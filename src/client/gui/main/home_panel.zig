const dvui = @import("dvui");
const core = @import("../../core.zig");

pub fn draw(state: *core.State) void {
    _ = state;
    dvui.labelNoFmt(@src(), "home", .{}, .{});
}
