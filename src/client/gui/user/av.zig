const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const dvui = @import("dvui");
const Core = @import("../../Core.zig");
const App = @import("../../../main_client_gui.zig").App;

pub const menu_name = "Audio / Video";
pub const tab_name = "Audio / Video";

var capture = false;
var power: std.atomic.Value(f32) = .init(0);

pub fn draw(app: *App) !void {
    const core = &app.core;
    var vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .border = .{ .x = 1 },
    });
    defer vbox.deinit();
    dvui.labelNoFmt(@src(), tab_name, .{}, .{
        .gravity_x = 0.5,
        .font = dvui.Font.theme(.title).larger(4),
    });
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    _ = dvui.spacer(@src(), .{});

    if (builtin.target.os.tag == .macos) {
        dvui.labelNoFmt(@src(),
            \\Sorry audio is a bit janky on macOS.
            \\Changing the audio input / output dropdown menus will
            \\  change your OS-wide default device,
            \\  and sometimes the audio engine will break during the transition.
            \\If you don't hear anything after switching settings, restart Awebo.
        , .{ .ellipsize = false }, .{});
        _ = dvui.spacer(@src(), .{});
    }

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
                .font = dvui.Font.theme(.title).larger(2),
                .expand = .horizontal,
            });
            if (try audioDeviceDropdown(@src(), &core.audio, .capture, .{
                .gravity_x = 0.5,
                .font = dvui.Font.theme(.title),
                .expand = .horizontal,
            })) {}

            dvui.labelNoFmt(@src(), "Input Volume", .{}, .{});
            const in_volume = &core.audio.capture_volume;
            _ = dvui.slider(@src(), .{
                .dir = .horizontal,
                .fraction = in_volume,
            }, .{
                .expand = .horizontal,
            });

            dvui.labelNoFmt(@src(), "Activation Threshold", .{}, .{});
            const in_treshold = &core.audio.capture_threshold;
            _ = dvui.slider(@src(), .{
                .dir = .horizontal,
                .fraction = in_treshold,
            }, .{
                .expand = .horizontal,
            });

            const preview = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .border = .all(1),
                .margin = .{ .x = 10, .w = 10 },
                .min_size_content = .{ .h = 3 },
            });

            var br = preview.data().contentRectScale().r;
            br.w *= power.load(.acquire);
            br.fill(.all(0), .{ .color = .yellow });

            preview.deinit();

            const test_label = if (capture) "Stop" else "Start Capture Test";
            if (dvui.button(@src(), test_label, .{}, .{ .gravity_x = 0.5 })) {
                if (capture) {
                    capture = false;
                    power.store(0, .release);
                    core.audio.captureTestStop();
                } else {
                    capture = true;
                    core.audio.captureTestStart(&power);
                }
            }

            if (capture) dvui.refresh(null, @src(), null);
        }
        {
            var box = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
                .margin = dvui.Rect.all(8),
            });
            defer box.deinit();

            dvui.labelNoFmt(@src(), "Audio Output", .{}, .{
                .gravity_x = 0.5,
                .font = dvui.Font.theme(.title).larger(2),
                .expand = .horizontal,
            });

            if (try audioDeviceDropdown(@src(), &core.audio, .playback, .{
                .gravity_x = 0.5,
                .font = dvui.Font.theme(.title),
                .expand = .horizontal,
            })) {}

            const out_volume = &core.audio.playback_volume;
            _ = dvui.slider(@src(), .{
                .dir = .horizontal,
                .fraction = out_volume,
            }, .{
                .expand = .horizontal,
            });

            if (dvui.checkbox(
                @src(),
                &core.audio.playback_voice_processing,
                "Enable Echo Removal",
                .{},
            )) {
                core.audio.setDevices();
            }
        }
    }

    {
        var box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            .margin = dvui.Rect.all(8),
        });
        defer box.deinit();

        dvui.labelNoFmt(@src(), "Camera", .{}, .{
            .gravity_x = 0.5,
            .font = dvui.Font.theme(.title).larger(2),
            .expand = .horizontal,
        });

        if (try webcamDeviceDropdown(@src(), &core.webcam_capture, .{
            .gravity_x = 0.5,
            .font = dvui.Font.theme(.title),
            .expand = .horizontal,
        })) {}
    }
}

pub fn audioDeviceDropdown(
    src: std.builtin.SourceLocation,
    audio: *Core.Audio,
    kind: enum { playback, capture },
    opts: dvui.Options,
) !bool {
    const selected = switch (kind) {
        .capture => &audio.capture_selected,
        .playback => &audio.playback_selected,
    };

    var dd: dvui.DropdownWidget = undefined;
    dd.init(
        src,
        .{
            .label = if (selected.*) |id| audio.devices.values()[id].name else "(system default)",
        },
        opts,
    );
    // try dd.install();

    var changed = false;
    if (dd.dropped()) {
        if (selected.* == null) dd.init_options.selected_index = 0;
        if (dd.addChoiceLabel("(system default)")) {
            selected.* = null;
            changed = true;
        }

        for (audio.devices.values(), 0..) |device, i| {
            switch (kind) {
                .capture => if (device.channels_in_count == 0) continue,
                .playback => if (device.channels_out_count == 0) continue,
            }

            var marker: []const u8 = "  ";
            if (selected.*) |selected_id| if (selected_id == i) {
                dd.init_options.selected_index = i;
                marker = "x";
            };

            var mi = dd.addChoice();
            defer mi.deinit();

            var style = mi.data().options.strip().override(mi.style());
            if (!device.connected) {
                style.color_text = .red;
                style.font.?.weight = .bold;
            }
            dvui.label(@src(), "[{s}] {s}", .{ marker, device.name }, style);

            if (mi.activeRect()) |_| {
                dd.close();
                selected.* = i;
                changed = true;
            }
        }
    }
    dd.deinit();
    if (changed) audio.setDevices();

    return changed;
}

pub fn webcamDeviceDropdown(
    src: std.builtin.SourceLocation,
    wc: *Core.WebcamCapture,
    opts: dvui.Options,
) !bool {
    var dd: dvui.DropdownWidget = undefined;
    dd.init(
        src,
        .{
            .label = if (wc.selected) |id| wc.devices.get(id).?.name else "(system default)",
        },
        opts,
    );
    // try dd.install();

    var changed = false;
    if (dd.dropped()) {
        if (wc.selected == null) dd.init_options.selected_index = 0;
        if (dd.addChoiceLabel("(system default)")) {
            wc.selected = null;
            changed = true;
        }

        for (wc.devices.values(), 0..) |cam, i| {
            var marker: []const u8 = "  ";
            if (wc.selected) |selected_id| if (selected_id.ptr == cam.id.ptr) {
                dd.init_options.selected_index = i;
                marker = "x";
            };

            var mi = dd.addChoice();
            defer mi.deinit();

            var style = mi.data().options.strip().override(mi.style());
            if (!cam.connected) {
                style.color_text = .red;
                style.font.?.weight = .bold;
            }
            dvui.label(@src(), "[{s}] {s}", .{ marker, cam.name }, style);

            if (mi.activeRect()) |_| {
                dd.close();
                wc.selected = cam.id;
                changed = true;
            }
        }
    }

    dd.deinit();
    return changed;
}
