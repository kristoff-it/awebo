const ChannelList = @This();

const builtin = @import("builtin");
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const Channel = awebo.Channel;
const Gui = @import("../../Gui.zig");
const Core = @import("../../Core.zig");
const ScreenshareBox = @import("ScreenshareBox.zig");
const widgets = @import("../widgets.zig");

show_new_chat: bool = false,
pending_new_chat: ?*Core.ui.ChannelCreate = null,
show_deny_popup: bool = false,
show_requesting_popup: bool = false,
debug: Debug = if (builtin.mode != .Debug) {} else .{},

const Debug = if (builtin.mode != .Debug) void else struct {
    window: bool = false,
    playback: bool = false,
    screen: bool = false,
    webcam: bool = false,
    screen_box: ScreenshareBox = .{},
    webcam_box: ScreenshareBox = .{},
};

pub fn draw(cl: *ChannelList, core: *Core, active_scene: *Gui.ActiveScene) !void {
    const h = core.hosts.get(core.active_host).?;
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
    });
    defer box.deinit();

    if (cl.show_new_chat or cl.pending_new_chat != null) {
        try cl.newChatFloatingWindow(core, h);
    }

    cl.hostName(core, h);
    try cl.channelList(core, h);
    try cl.joinedVoice(core);
    try cl.userbox(active_scene, h);
    if (cl.show_deny_popup) cl.denyPopup();
    if (cl.show_requesting_popup) cl.requestingPopup();
}

pub fn hostName(cl: *ChannelList, core: *Core, h: *awebo.Host) void {
    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer hbox.deinit();

        var m = dvui.menu(@src(), .horizontal, .{
            .background = true,
            .expand = .horizontal,
        });
        defer m.deinit();

        if (Debug != void) {
            if (dvui.menuItemLabel(
                @src(),
                "Debug",
                .{ .submenu = true },
                .{ .expand = .none },
            )) |r| {
                var fw = dvui.floatingMenu(@src(), .{
                    .from = dvui.Rect.Natural.fromPoint(dvui.Point.Natural{
                        .x = r.x,
                        .y = r.y + r.h,
                    }),
                }, .{});
                defer fw.deinit();

                if (dvui.menuItemLabel(@src(), "New Chat", .{}, .{}) != null) {
                    cl.show_new_chat = true;
                    m.close();
                }
                if (dvui.menuItemLabel(@src(), "Awebo A/V Debug Window", .{}, .{}) != null) {
                    cl.debug.window = !cl.debug.window;
                    m.close();
                }
                if (dvui.menuItemLabel(@src(), "DVUI Debug Window", .{}, .{}) != null) {
                    dvui.toggleDebugWindow();
                    m.close();
                }
            }

            if (cl.debug.window) cl.renderAVDebugWindow(core);
        }

        dvui.labelNoFmt(@src(), h.name, .{}, .{
            .gravity_x = 0.5,
            .font = dvui.Font.theme(.title).larger(2),
        });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
}

pub fn newChatFloatingWindow(cl: *ChannelList, core: *Core, h: *awebo.Host) !void {
    const gpa = core.gpa;
    const fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .padding = dvui.Rect.all(10),
    });
    defer fw.deinit();

    {
        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
        });
        defer box.deinit();
        if (dvui.button(@src(), "X", .{}, .{
            .expand = .vertical,
        })) {
            cl.show_new_chat = false;
        }
        dvui.labelNoFmt(@src(), "Create new Chat", .{}, .{
            .gravity_x = 0.5,
            .font = dvui.Font.theme(.title).larger(2),
            .expand = .horizontal,
        });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    dvui.labelNoFmt(@src(), "Choose a name for the new chat channel.", .{}, .{
        .gravity_x = 0.5,
        .expand = .horizontal,
    });

    if (cl.pending_new_chat) |nc| blk: {
        const msg = switch (nc.status.get()) {
            .pending => "pending...",
            .connection_failure => "connection failure",
            .name_taken => "name already taken",
            .rate_limit => "rate limit error",
            .no_permission => "no permission",
            .ok => {
                cl.pending_new_chat = null;
                cl.show_new_chat = false;
                break :blk;
            },
            // .fail => "missing permissions",
        };
        dvui.labelNoFmt(@src(), msg, .{}, .{
            .gravity_x = 0.5,
            .expand = .horizontal,
        });
    } else {
        // _ = dvui.spacer(@src(), dvui.Size.all(30), .{});
        _ = dvui.spacer(@src(), .{});
    }

    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 1,
        .expand = .horizontal,
    });
    defer box.deinit();

    const clicked = dvui.button(@src(), "Create", .{}, .{
        .gravity_x = 1,
        .margin = .{ .x = 0, .y = 4, .w = 4, .h = 4 },
        .corner_radius = .{ .x = 0, .y = 5, .w = 5, .h = 0 },
        .background = true,
        .border = dvui.Rect.all(1),
        .expand = .vertical,
    });

    var in = dvui.textEntry(@src(), .{}, .{
        .expand = .horizontal,
        .margin = .{ .x = 4, .y = 4, .w = 0, .h = 4 },
        .corner_radius = .{ .x = 5, .y = 0, .w = 0, .h = 5 },
        // .color_fill = .{ .name = .fill_window },
    });
    defer in.deinit();

    var enter_pressed = false;
    for (dvui.events()) |*e| {
        if (!in.matchEvent(e))
            continue;

        if (e.evt == .key and e.evt.key.code == .enter and e.evt.key.action == .down) {
            e.handled = true;
            enter_pressed = true;
        }

        if (!e.handled) {
            in.processEvent(e);
        }
    }

    if (clicked or enter_pressed) blk: {
        const raw = std.mem.trim(u8, in.getText(), " \t\n\r");
        if (cl.pending_new_chat) |p| {
            if (p.status.get() == .ok) {
                p.destroy(gpa);
            } else break :blk;
        }
        if (raw.len > 0) {
            cl.show_new_chat = false;
            const name = try gpa.dupe(u8, raw);
            const cmd = try gpa.create(Core.ui.ChannelCreate);
            cmd.* = .{
                .origin = 0, //@intCast(std.time.timestamp()),
                .host = h,
                .kind = .chat,
                .name = name,
            };
            cl.pending_new_chat = cmd;
            try core.channelCreate(cmd);

            in.len = 0;
        }
    }
}

pub fn channelList(cl: *ChannelList, core: *Core, h: *awebo.Host) !void {
    var list_scroll = dvui.scrollArea(
        @src(),
        .{},
        .{
            .expand = .vertical,
            // .color_fill = .{ .name = .fill_window },
        },
    );
    defer list_scroll.deinit();

    var menu = dvui.menu(
        @src(),
        .vertical,
        .{
            .expand = .vertical,
            .min_size_content = .{ .w = 250 },
            .background = true,
            .margin = .{ .x = 8, .w = 8 },
            // .color_fill = .{ .name = .fill },
        },
    );
    defer menu.deinit();
    for (h.channels.items.values(), 0..) |*channel, idx| {
        switch (channel.kind) {
            .chat => |*chat| {
                const item = dvui.menuItem(@src(), .{}, .{
                    .gravity_x = 0,
                    .id_extra = idx,
                    .expand = .horizontal,
                });
                defer item.deinit();

                if (item.activated) {
                    // Save newest loaded message
                    if (h.client.active_channel) |old_chat_id| {
                        const old_chat = h.channels.get(old_chat_id).?;
                        if (old_chat.kind == .chat) {
                            old_chat.kind.chat.client.last_newest = if (core.message_window.latest()) |l|
                                l.id + 1
                            else
                                std.math.maxInt(i64);
                        }
                    }

                    // Reset message window and set new channel
                    h.client.active_channel = channel.id;
                    core.message_window.reset(core.gpa);

                    // Replace messages in the message window
                    var rs = h.client.qs.select_chat_history.run(@src(), h.client.db, .{
                        .below_uid = chat.client.last_newest,
                        .channel = channel.id,
                        .limit = 64,
                    });
                    std.log.debug("loadig from last newest {}", .{chat.client.last_newest});

                    while (rs.next()) |r| {
                        std.log.debug("loading message {}", .{r.get(.uid)});
                        const kind = r.get(.kind);
                        switch (kind) {
                            .missing_messages_older, .missing_messages_newer => break,
                            else => {},
                        }
                        std.log.debug("continuinig {}", .{r.get(.uid)});
                        core.message_window.backfill(core.gpa, .{
                            .id = r.get(.uid),
                            .origin = r.get(.origin),
                            .created = r.get(.created),
                            .update_uid = r.get(.update_uid),
                            .kind = kind,
                            .author = r.get(.author),
                            .text = try r.text(core.gpa, .body),
                        }) catch @panic("oom");
                    }
                }

                const active = if (h.client.active_channel) |ac|
                    ac == channel.id
                else
                    false;

                if (active) {
                    // item.wd.options.color_fill = .{ .name = .fill_press };
                    item.wd.options.background = true;
                    // try item.drawBackground(.{});
                }

                dvui.labelNoFmt(@src(), channel.name, .{}, .{
                    .font = dvui.Font.theme(.title).larger(4),
                    .id_extra = idx,
                });
            },
            .voice => try cl.renderVoiceChannel(core, h, channel, idx),
        }
    }
}

fn renderVoiceChannel(cl: *ChannelList, core: *Core, h: *awebo.Host, v: *const Channel, idx: usize) !void {
    {
        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx,
            .expand = .horizontal,
        });
        defer box.deinit();

        const maybe_call = core.active_call;
        if (maybe_call == null or maybe_call.?.voice_id != v.id) {
            const enabled: widgets.Enabled = if (h.client.status == .synced) .on else .{
                .off = "disconnected from the host",
            };

            if (widgets.button(@src(), enabled, "Join", .{}, .{
                .id_extra = idx,
                .expand = .vertical,
                .gravity_x = 1,
                .margin = dvui.Rect.all(4),
            })) {
                switch (try core.callJoin(h.client.host_id, v.id)) {
                    .granted, .unknown => {},
                    .denied => cl.show_deny_popup = true,
                    .requesting => cl.show_requesting_popup = true,
                }
            }
        }

        {
            const item = dvui.menuItem(@src(), .{}, .{
                .gravity_x = 0,
                .id_extra = idx,
                .expand = .horizontal,
            });
            defer item.deinit();

            if (item.activated) {
                h.client.active_channel = v.id;
            }

            if (core.active_call) |call| {
                const active = call.voice_id == v.id;
                if (active) {
                    // item.wd.options.color_fill = .{ .name = .fill };
                    item.wd.options.background = true;
                    // try item.drawBackground(.{});
                }
            }
            dvui.labelNoFmt(@src(), v.name, .{}, .{
                .font = dvui.Font.theme(.title).larger(4),
                .id_extra = idx,
            });
        }
    }

    const members_menu = dvui.menu(@src(), .vertical, .{
        .id_extra = idx,
    });
    defer members_menu.deinit();

    const callers = h.client.callers.getVoiceRoom(v.id) orelse &.{};
    for (callers) |cid| {
        const caller = h.client.callers.get(cid).?;

        if (caller.id == h.client.id and
            core.active_call == null) continue;

        const m = h.users.get(caller.id.user_id).?;
        const item = dvui.menuItem(@src(), .{}, .{
            .margin = .{ .x = 8, .w = 8 },
            .gravity_x = 0,
            .id_extra = caller.id.toInt(),
            .expand = .horizontal,
        });
        defer item.deinit();

        // const ctext = dvui.context(@src(), .{}, .{ .expand = .horizontal });
        // defer ctext.deinit();

        const box = dvui.box(@src(), .{ .dir = .horizontal }, .{});
        defer box.deinit();

        // if (ctext.activePoint()) |cp| {
        //     var fw2 = try dvui.floatingMenu(
        //         @src(),
        //         dvui.Rect.fromPoint(cp),
        //         .{
        //             .id_extra = idx,
        //         },
        //     );
        //     defer fw2.deinit();

        //     if (dvui.menuItemLabel(@src(), "Kick", .{}, .{
        //         .id_extra = idx,
        //         .expand = .horizontal,
        //     })) |_| blk: {
        //         dvui.menuGet().?.close();
        //         break :blk;
        //         //if (mid == h.client.user_id) {
        //         //    app.command(.{ .ui = .call_leave });
        //         //} else {
        //         //    const vc_idx = for (
        //         //        v.members.slice(),
        //         //        0..,
        //         //    ) |vm, vc_idx| {
        //         //        if (vm == mid) break vc_idx;
        //         //    } else break :blk;

        //         //    _ = v.members.orderedRemove(vc_idx);
        //         //}
        //     }
        // }

        //  dvui.image(@src(), "zig favicon", m.avatar, .{
        //     .gravity_y = 0.5,
        //     .min_size_content = .{ .w = 20, .h = 20 },
        //     .id_extra = idx,
        // });

        const pending = if (core.active_call) |ac| switch (ac.status.get()) {
            .intent, .connecting => true,
            else => false,
        } else false;

        const text_color: dvui.Color = if (caller.id == h.client.id and pending) .gray else .white;

        var speaking = false;
        if (core.active_call) |*ac| {
            if (ac.callers.get(caller.id)) |c| {
                speaking = c.audio.speaking_last_ns + (250 * std.time.ns_per_ms) >= core.now();
            }
        }

        if (dvui.timerDoneOrNone(box.data().id)) {
            const millis_per_frame = 300;
            const millis = @divFloor(dvui.frameTimeNS(), 1_000_000);
            const left = @as(i32, @intCast(@rem(millis, millis_per_frame)));
            const wait = 1000 * (millis_per_frame - left);
            dvui.timer(box.data().id, wait);
        }

        const bg_color: ?dvui.Color = if (speaking) .yellow else null;

        dvui.label(@src(), "{s}{s}", .{
            m.display_name,
            if (caller.state.muted) " [M]" else "",
        }, .{
            .font = .theme(.title),
            .id_extra = caller.id.toInt(),
            .color_text = text_color,
            .background = true,
            .color_border = bg_color,
            .border = .all(2),
        });
    }
}

fn joinedVoice(cl: *ChannelList, core: *Core) !void {
    _ = cl;
    if (core.active_call) |call| {
        const hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .expand = .horizontal,
            .margin = .{ .x = 8, .w = 8 },
        });
        defer hbox.deinit();

        {
            const vbox = dvui.box(@src(), .{ .dir = .vertical }, .{
                .expand = .horizontal,
            });
            defer vbox.deinit();

            dvui.labelNoFmt(@src(), "Voice Connected", .{}, .{
                .font = dvui.Font.theme(.heading).larger(-2),
            });

            const h = core.hosts.get(call.host_id).?;
            const v = h.channels.get(call.voice_id).?;

            dvui.label(@src(), "{s} / {s}", .{ v.name, h.name }, .{
                .font = dvui.Font.theme(.body).larger(-2),
            });
        }

        const mute_label = switch (call.muted) {
            .muted => "Unmute",
            .unmuted => "Mute",
        };

        if (dvui.button(@src(), mute_label, .{}, .{ .expand = .vertical })) {
            core.callSetMute(call.muted.not());
        }

        if (dvui.button(@src(), "Leave", .{}, .{ .expand = .vertical })) {
            try core.callLeave();
        }
    }
}

fn userbox(cl: *ChannelList, active_scene: *Gui.ActiveScene, h: *awebo.Host) !void {
    _ = cl;

    var user_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        // x left, y top, w right, h bottom
        .padding = dvui.Rect.all(8),
        // .border = dvui.Rect.all(1),
        // .color_border = .{ .name = .text_press },
        // .color_fill = .{ .name = .fill_control },
    });
    defer user_box.deinit();

    const user = h.users.get(h.client.id.user_id) orelse return;
    // try dvui.image(@src(), "avatar", user.avatar, .{
    //     .gravity_y = 0,
    //     .gravity_x = 0.5,
    //     .min_size_content = .{ .w = 30, .h = 30 },
    //     .border = dvui.Rect.all(1),
    //     .background = true,
    //     .corner_radius = dvui.Rect.all(100),
    //     .color_border = .{ .name = .accent },
    // });

    {
        var text_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            // .color_fill = .{ .name = .fill_control },
        });
        defer text_box.deinit();

        dvui.labelNoFmt(@src(), user.display_name, .{}, .{
            .font = dvui.Font.theme(.heading).larger(-2),
            // x left, y top, w right, h bottom
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
        });

        dvui.labelNoFmt(@src(), "Online", .{}, .{
            // x left, y top, w right, h bottom
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
        });
    }

    if (dvui.button(@src(), "Settings", .{}, .{})) {
        active_scene.* = .user_settings;
    }
}

fn renderAVDebugWindow(cl: *ChannelList, core: *Core) void {
    const fw = dvui.floatingWindow(@src(), .{ .modal = false }, .{
        .padding = dvui.Rect.all(10),
    });
    defer fw.deinit();

    fw.dragAreaSet(dvui.windowHeader("Awebo A/V Debug", "", &cl.debug.window));

    const webcam_label = if (cl.debug.webcam) "Camera OFF" else "Camera ON";
    if (dvui.button(@src(), webcam_label, .{}, .{})) {
        if (cl.debug.webcam) {
            cl.debug.webcam = false;
            _ = core.webcam_capture.stopCapture();
        } else {
            cl.debug.webcam = true;
            _ = core.webcam_capture.startCapture();
        }
    }

    const screen_label = if (cl.debug.screen) "Screenshare OFF" else "Screenshare ON";
    if (dvui.button(@src(), screen_label, .{}, .{})) {
        if (cl.debug.screen) {
            cl.debug.screen = false;
            _ = core.screen_capture.stopCapture();
        } else {
            cl.debug.screen = true;
            _ = core.screen_capture.showOsPicker();
        }
    }

    if (dvui.button(@src(), "Drop next incoming media packet", .{}, .{})) {
        @import("../../Core/network.zig").debug.drop_next_media_packets.store(1, .release);
    }

    if (dvui.button(@src(), "Drop next incoming 3 media packets", .{}, .{})) {
        @import("../../Core/network.zig").debug.drop_next_media_packets.store(3, .release);
    }

    if (dvui.button(@src(), "Send bad capture packet", .{}, .{})) {
        @import("../../Core/network.zig").debug.send_bad_capture_packet.store(true, .release);
    }

    if (cl.debug.webcam) cl.debug.webcam_box.draw(core, .webcam) catch unreachable;
    if (cl.debug.screen) cl.debug.screen_box.draw(core, .screen) catch unreachable;
}

fn denyPopup(cl: *ChannelList) void {
    var fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{});
    defer fw.deinit();

    dvui.labelNoFmt(@src(),
        \\Awebo has no permission to access the microphone.
        \\Go to your OS settings and grant permission to be able to join a call.
    , .{}, .{});

    if (dvui.button(@src(), "OK", .{}, .{ .gravity_x = 0.5 })) {
        cl.show_deny_popup = false;
    }
}

fn requestingPopup(cl: *ChannelList) void {
    var fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{});
    defer fw.deinit();

    dvui.labelNoFmt(@src(),
        \\There is an open OS window to grant Awebo access to your microphone.
        \\Grant permission before attempting to join a call.
    , .{}, .{});

    if (dvui.button(@src(), "OK", .{}, .{ .gravity_x = 0.5 })) {
        cl.show_requesting_popup = false;
    }
}
