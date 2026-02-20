const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const Channel = awebo.Channel;
const App = @import("../../../main_client_gui.zig").App;
const Core = @import("../../Core.zig");

const debug = struct {
    var window = false;
    var playback = false;
    var capture = false;
    var capture_pump: Io.Future(void) = undefined;
    var screen = false;
    var webcam = false;
};

pub fn draw(app: *App) !void {
    const core = &app.core;
    const h = core.hosts.get(core.active_host).?;
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
    });
    defer box.deinit();

    if (app.show_new_chat or app.pending_new_chat != null) {
        try newChatFloatingWindow(app, h);
    }

    hostName(app, h);
    try channelList(h, core);
    try joinedVoice(core);
    try userbox(app, h);
}

pub fn hostName(app: *App, h: *awebo.Host) void {
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

        if (dvui.menuItemLabel(
            @src(),
            "Settings",
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
                app.show_new_chat = true;
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "Awebo A/V Debug Window", .{}, .{}) != null) {
                debug.window = !debug.window;
                m.close();
            }
            if (dvui.menuItemLabel(@src(), "DVUI Debug Window", .{}, .{}) != null) {
                dvui.toggleDebugWindow();
                m.close();
            }
        }

        if (debug.window) renderAVDebugWindow(&app.core);

        dvui.labelNoFmt(@src(), h.name, .{}, .{
            .gravity_x = 0.5,
            .font = dvui.Font.theme(.title).larger(2),
        });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
}

pub fn newChatFloatingWindow(app: *App, h: *awebo.Host) !void {
    const core = &app.core;
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
            app.show_new_chat = false;
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

    if (app.pending_new_chat) |nc| blk: {
        const msg = switch (nc.status.get()) {
            .pending => "pending...",
            .connection_failure => "connection failure",
            .name_taken => "name already taken",
            .rate_limit => "rate limit error",
            .no_permission => "no permission",
            .ok => {
                app.pending_new_chat = null;
                app.show_new_chat = false;
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
        if (app.pending_new_chat) |p| {
            if (p.status.get() == .ok) {
                p.destroy(gpa);
            } else break :blk;
        }
        if (raw.len > 0) {
            app.show_new_chat = false;
            const name = try gpa.dupe(u8, raw);
            const cmd = try gpa.create(Core.ui.ChannelCreate);
            cmd.* = .{
                .origin = 0, //@intCast(std.time.timestamp()),
                .host = h,
                .kind = .chat,
                .name = name,
            };
            app.pending_new_chat = cmd;
            try core.channelCreate(cmd);

            in.len = 0;
        }
    }
}

pub fn channelList(h: *awebo.Host, core: *Core) !void {
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
            .voice => try renderVoiceChannel(h, core, channel, idx),
        }
    }
}

fn renderVoiceChannel(h: *awebo.Host, core: *Core, v: *const Channel, idx: usize) !void {
    {
        var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .id_extra = idx,
            .expand = .horizontal,
        });
        defer box.deinit();

        const maybe_call = core.active_call;
        if (maybe_call == null or maybe_call.?.voice_id != v.id) {
            if (dvui.button(@src(), "Join", .{}, .{
                .id_extra = idx,
                .expand = .vertical,
                .gravity_x = 1,
                .margin = dvui.Rect.all(4),
            })) {
                try core.callJoin(h.client.host_id, v.id);
            }
        }

        {
            const item = dvui.menuItem(@src(), .{}, .{
                .gravity_x = 0,
                .id_extra = idx,
                .expand = .horizontal,
            });
            defer item.deinit();

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

        if (caller.user == h.client.user_id and
            core.active_call == null) continue;

        const m = h.users.get(caller.user).?;
        const item = dvui.menuItem(@src(), .{}, .{
            .margin = .{ .x = 8, .w = 8 },
            .gravity_x = 0,
            .id_extra = caller.id,
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

        const text_color: dvui.Color = if (caller.user == h.client.user_id and pending) .gray else .white;

        var speaking = false;
        if (core.active_call) |*ac| {
            if (ac.callers.get(caller.id)) |c| {
                speaking = c.speaking_last_ns + (250 * std.time.ns_per_ms) >= core.now();
            }
        }

        if (dvui.timerDoneOrNone(box.data().id)) {
            const millis_per_frame = std.time.ms_per_s / 60;
            const millis = @divFloor(dvui.frameTimeNS(), 1_000_000);
            const left = @as(i32, @intCast(@rem(millis, millis_per_frame)));
            const wait = 260 * (millis_per_frame - left);
            dvui.timer(box.data().id, wait);
        }

        const bg_color: ?dvui.Color = if (speaking) .yellow else null;

        dvui.labelNoFmt(@src(), m.display_name, .{}, .{
            .font = .theme(.title),
            .id_extra = caller.id,
            .color_text = text_color,
            .background = true,
            .color_border = bg_color,
            .border = .all(2),
        });
    }
}

fn joinedVoice(core: *Core) !void {
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

        if (dvui.button(@src(), "Leave", .{}, .{ .expand = .vertical })) {
            try core.callLeave();
        }
    }
}

fn userbox(app: *App, h: *awebo.Host) !void {
    var user_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        // x left, y top, w right, h bottom
        .padding = dvui.Rect.all(8),
        // .border = dvui.Rect.all(1),
        // .color_border = .{ .name = .text_press },
        // .color_fill = .{ .name = .fill_control },
    });
    defer user_box.deinit();

    const user = h.users.get(h.client.user_id) orelse return;
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
        app.active_screen = .user_settings;
    }
}

fn renderAVDebugWindow(core: *Core) void {
    const fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .padding = dvui.Rect.all(10),
    });
    defer fw.deinit();

    fw.dragAreaSet(dvui.windowHeader("Awebo A/V Debug", "", &debug.window));

    const capture_label = if (debug.capture) "Microphone OFF" else "Microphone ON";
    if (dvui.button(@src(), capture_label, .{}, .{})) {
        if (debug.capture) {
            debug.capture = false;
            debug.capture_pump.cancel(core.io);
            core.audio.captureStop();
        } else {
            debug.capture = true;
            debug.capture_pump = core.io.concurrent(opusDance, .{core}) catch unreachable;
            core.audio.captureStart();
        }
    }

    const webcam_label = if (debug.webcam) "Camera OFF" else "Camera ON";
    if (dvui.button(@src(), webcam_label, .{}, .{})) {
        if (debug.webcam) {
            debug.webcam = false;
            _ = core.webcam_capture.stopCapture();
        } else {
            debug.webcam = true;
            _ = core.webcam_capture.startCapture();
        }
    }

    const screen_label = if (debug.screen) "Screenshare OFF" else "Screenshare ON";
    if (dvui.button(@src(), screen_label, .{}, .{})) {
        if (debug.screen) {
            debug.screen = false;
            _ = core.screen_capture.stopCapture();
        } else {
            debug.screen = true;
            _ = core.screen_capture.showOsPicker();
        }
    }

    const screenshare_box = @import("screenshare_box.zig");
    if (debug.webcam) screenshare_box.drawSource(core, .webcam) catch unreachable;
    if (debug.screen) screenshare_box.drawSource(core, .screen) catch unreachable;
}

fn opusDance(core: *Core) void {
    std.log.debug("dancing!", .{});

    const io = core.io;
    const audio = &core.audio;

    while (true) {
        core.audio.capture_stream.mutex.lockUncancelable(io);
        defer core.audio.capture_stream.mutex.unlock(io);
        core.audio.capture_stream.condition.wait(io, &core.audio.capture_stream.mutex) catch return;

        var data_buf: [1280]u8 = undefined;

        if (audio.capture_stream.channels[0].len() < awebo.opus.PACKET_SIZE) {
            continue;
        }

        var sample_buf: [awebo.opus.PACKET_SIZE]f32 = undefined;
        audio.capture_stream.channels[0].readFirstAssumeCount(
            &sample_buf,
            awebo.opus.PACKET_SIZE,
        );

        core.audio.playback_stream.writeBoth(io, &sample_buf) catch return;
        if (true) continue;

        const len = audio.capture_encoder.encodeFloat(&sample_buf, &data_buf) catch |err| {
            std.log.debug("opus encoder error: {t}", .{err});
            return error.EncodingFailure;
        };

        const encoded_data = data_buf[0..len];

        var pcm: [awebo.opus.PACKET_SIZE]f32 = undefined;
        const written = core.audio.playback_decoder.decodeFloat(
            encoded_data,
            &pcm,
            false,
        ) catch unreachable;

        core.audio.playback_stream.writeBoth(io, pcm[0..written]);
    }
}
