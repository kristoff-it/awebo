const Main = @This();

const std = @import("std");
const dvui = @import("dvui");
const awebo = @import("../../awebo.zig");
const HostBar = @import("main/HostBar.zig");
const ChannelList = @import("main/ChannelList.zig");
const ChatPanel = @import("main/ChatPanel.zig");
const HomePanel = @import("main/HomePanel.zig");
const ScreenshareBox = @import("main/ScreenshareBox.zig");
const Gui = @import("../Gui.zig");
const Core = @import("../Core.zig");
const Host = awebo.Host;
const Voice = awebo.channels.Voice;

subviews: struct {
    host_bar: HostBar = .{},
    channel_list: ChannelList = .{},
    chat_panel: ChatPanel = .{},
    home_panel: HomePanel = .{},
    screenshare_box: ScreenshareBox = .{},
} = .{},

pub fn draw(main: *Main, core: *Core, active_screen: *Gui.ActiveScreen) !void {
    if (core.active_host == 0) {
        core.active_host = core.hosts.items.keys()[0];
    }

    const h = core.hosts.get(core.active_host).?;
    const frozen = h.client.connection_status != .synced;

    main.subviews.host_bar.draw(core);

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
        try main.subviews.channel_list.draw(core, active_screen);
        if (h.client.active_channel) |ac| {
            switch (h.channels.get(ac).?.kind) {
                .chat => try main.subviews.chat_panel.draw(core, frozen),
                .voice => @panic("TODO"),
            }
        }
    }

    if (core.webcam_capture.share_intent or core.screen_capture.share_intent) {
        try main.subviews.screenshare_box.draw(core);
    }
}
