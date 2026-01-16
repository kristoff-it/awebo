const std = @import("std");
const dvui = @import("dvui");
const audio = @import("audio");
const core = @import("../../core.zig");

pub const menu_name = "Audio / Video";
pub const tab_name = "Audio / Video";

pub fn draw(state: *core.State) !void {
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .border = .{ .x = 1 },
    });
    defer vbox.deinit();
    dvui.labelNoFmt(@src(), tab_name, .{}, .{
        .gravity_x = 0.5,
        .font = .theme(.title).larger(4),
    });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    // _ = dvui.spacer(@src(), dvui.Size.all(5), .{});
    _ = dvui.spacer(@src(), .{});

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer hbox.deinit();

        {
            var box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .margin = dvui.Rect.all(8),
            });
            defer box.deinit();

            dvui.labelNoFmt(@src(), "Audio Input", .{}, .{
                .gravity_x = 0.5,
                .font = .theme(.title).larger(2),
                .expand = .horizontal,
            });
            if (try deviceDropdown(@src(), &state.audio.user.capture, .{
                .gravity_x = 0.5,
                .font = .theme(.title),
                .expand = .horizontal,
            })) {}

            const in_volume = &state.audio.user.capture.volume;
            _ = dvui.slider(@src(), .{
                .dir = .horizontal,
                .fraction = in_volume,
            }, .{
                .expand = .horizontal,
            });
        }

        {
            var box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .margin = dvui.Rect.all(8),
            });
            defer box.deinit();

            dvui.labelNoFmt(@src(), "Audio Output", .{}, .{
                .gravity_x = 0.5,
                .font = .theme(.title).larger(2),
                .expand = .horizontal,
            });

            if (try deviceDropdown(@src(), &state.audio.user.playout, .{
                .gravity_x = 0.5,
                .font = .theme(.title),
                .expand = .horizontal,
            })) {}

            const out_volume = &state.audio.user.playout.volume;
            _ = dvui.slider(@src(), .{
                .dir = .horizontal,
                .fraction = out_volume,
            }, .{
                .expand = .horizontal,
            });
        }
    }
}

pub fn deviceDropdown(
    src: std.builtin.SourceLocation,
    audio_state: *core.State.UserAudio,
    opts: dvui.Options,
) !bool {
    var dd: dvui.DropdownWidget = undefined;
    dd.init(
        src,
        .{
            .label = if (audio_state.device) |device| device.name.slice else "(system default)",
        },
        opts,
    );
    // try dd.install();

    var new_selection: ?core.DeviceSelection = null;
    if (dd.dropped()) {
        const devices = audio_state.selectInit();
        defer audio_state.deinitSelect(new_selection);

        if (audio_state.device) |selected_device| {
            for (devices, 1..) |d, i| {
                if (d.token.slice.ptr == selected_device.token.slice.ptr) {
                    dd.init_options.selected_index = i;
                }
            }
        } else {
            dd.init_options.selected_index = 0;
        }

        if (dd.addChoiceLabel("(system default)")) {
            new_selection = .{ .device = null };
        }
        for (devices) |d| {
            if (dd.addChoiceLabel(d.name.slice)) {
                new_selection = .{ .device = d };
            }
        }
    }

    dd.deinit();
    return if (new_selection) |_| true else false;
}
