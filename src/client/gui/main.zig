const std = @import("std");
const dvui = @import("dvui");
const awebo = @import("../../awebo.zig");
const host_bar = @import("main/host_bar.zig");
const channel_list = @import("main/channel_list.zig");
const chat_panel = @import("main/chat_panel.zig");
const home_panel = @import("main/home_panel.zig");
const screenshare_box = @import("main/screenshare_box.zig");
const core = @import("../core.zig");
const Host = awebo.Host;
const Voice = awebo.channels.Voice;

pub var state: struct {
    active_host: Host.ClientOnly.Id = 0,
    show_new_chat: bool = false,
    pending_new_chat: ?*core.ui.ChannelCreate = null,
} = .{};

pub fn draw(core_state: *core.State) !void {
    if (state.active_host == 0) {
        state.active_host = core_state.hosts.items.keys()[0];
    }

    const h = core_state.hosts.get(state.active_host).?;
    const frozen = h.client.connection_status != .synced;

    host_bar.draw(core_state);

    {
        var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .both,
            .background = true,
        });
        defer vbox.deinit();

        if (frozen) {
            var bar = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .background = true,
            });
            defer bar.deinit();

            switch (h.client.connection_status) {
                .synced => unreachable,
                .disconnected => |retry_time| {
                    {
                        const millis = @divFloor(dvui.frameTimeNS(), 1_000_000);
                        const left = @as(i32, @intCast(@rem(millis, 1000)));
                        if (dvui.timerDoneOrNone(bar.data().id)) dvui.timer(bar.data().id, 100 * (1000 - left));
                    }

                    {
                        const left_ns: f32 = @floatFromInt(retry_time -| core.now());
                        const left_s = left_ns / std.time.ns_per_s;
                        dvui.label(@src(), "reconnecting in {:.0}s", .{left_s}, .{
                            .gravity_x = 0.5,
                            .color_text = .yellow,
                        });
                    }
                },
                else => {
                    dvui.labelNoFmt(@src(), @tagName(h.client.connection_status), .{}, .{ .gravity_x = 0.5 });
                },
            }
        }

        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .both,
            .background = true,
        });
        defer hbox.deinit();
        try channel_list.draw(core_state);
        switch (h.client.active_channel) {
            .home => home_panel.draw(core_state),
            .chat => try chat_panel.draw(core_state, frozen),
            .voice => @panic("TODO"),
        }
    }

    if (core_state.screenshare_intent) {
        try screenshare_box.draw(core_state);
    }
}
