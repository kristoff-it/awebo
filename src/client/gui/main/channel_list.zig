const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const client = @import("../../../main_client_gui.zig");
const core = @import("../../core.zig");
const main = @import("../../gui.zig").main;

pub fn draw(state: *core.State) !void {
    const h = state.hosts.get(main.state.active_host).?;
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .vertical,
    });
    defer box.deinit();

    if (main.state.show_new_chat or main.state.pending_new_chat != null) {
        try new_chat_floating_window(state, h);
    }
    host_name(h);
    chat_list(h);
    try voice_list(h, state);
    try joined_voice(state);
    try userbox(state, h);
}

pub fn host_name(h: *awebo.Host) void {
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

            // if (dvui.menuItemLabel(@src(), "New Chat", .{}, .{}) != null) {
            //     main.state.show_new_chat = true;
            //     dvui.menuGet().?.close();
            // }
        }

        dvui.labelNoFmt(@src(), h.name, .{}, .{
            .gravity_x = 0.5,
            .font_style = .title_2,
        });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
}

pub fn new_chat_floating_window(state: *core.State, h: *awebo.Host) !void {
    const gpa = dvui.currentWindow().gpa;

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
            main.state.show_new_chat = false;
        }
        dvui.labelNoFmt(@src(), "Create new Chat", .{}, .{
            .gravity_x = 0.5,
            .font_style = .title_2,
            .expand = .horizontal,
        });
    }
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    dvui.labelNoFmt(@src(), "Choose a name for the new chat channel.", .{}, .{
        .gravity_x = 0.5,
        .expand = .horizontal,
    });

    if (main.state.pending_new_chat) |nc| blk: {
        const msg = switch (nc.status.get()) {
            .pending => "pending...",
            .connection_failure => "connection failure",
            .name_taken => "name already taken",
            .ok => {
                main.state.pending_new_chat = null;
                main.state.show_new_chat = false;
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
        if (main.state.pending_new_chat) |p| {
            if (p.status.get() == .ok) {
                p.destroy(gpa);
            } else break :blk;
        }
        if (raw.len > 0) {
            main.state.show_new_chat = false;
            const name = try gpa.dupe(u8, raw);
            const cmd = try gpa.create(core.ui.ChannelCreate);
            cmd.* = .{
                .origin = 0, //@intCast(std.time.timestamp()),
                .host = h,
                .kind = .chat,
                .name = name,
            };
            main.state.pending_new_chat = cmd;
            try state.channelCreate(cmd);

            in.len = 0;
        }
    }
}

pub fn chat_list(h: *awebo.Host) void {
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
    for (h.chats.items.values(), 0..) |c, idx| {
        const item = dvui.menuItem(@src(), .{}, .{
            .gravity_x = 0,
            .id_extra = idx,
            .expand = .horizontal,
        });
        defer item.deinit();

        if (item.activated) {
            h.client.active_channel = .{ .chat = c.id };
        }

        const active = switch (h.client.active_channel) {
            .chat => |ac| ac == c.id,
            else => false,
        };
        if (active) {
            // item.wd.options.color_fill = .{ .name = .fill_press };
            item.wd.options.background = true;
            // try item.drawBackground(.{});
        }

        dvui.labelNoFmt(@src(), c.name, .{}, .{
            .font_style = .title_3,
            .id_extra = idx,
        });
    }
}

fn voice_list(h: *awebo.Host, state: *core.State) !void {
    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    const opts: dvui.Options = .{
        .margin = dvui.Rect.all(8),
        .font_style = .title_2,
        .expand = .horizontal,
        .background = true,
        // .color_fill = .{ .name = .fill },
        .border = dvui.Rect.all(1),
        // .color_border = .{ .name = .text_press },
    };

    const open = dvui.expander(@src(), "Voice Channels", .{}, opts);
    _ = dvui.separator(@src(), .{ .expand = .horizontal });
    if (open) {
        var bar = dvui.scrollArea(
            @src(),
            .{},
            .{
                .expand = .vertical,
                // .color_fill = .{ .name = .fill_window },
            },
        );
        defer bar.deinit();

        var voices_menu = dvui.menu(
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
        defer voices_menu.deinit();

        for (h.voices.items.values(), 0..) |*v, idx| {
            {
                var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                    .id_extra = idx,
                    .expand = .horizontal,
                });
                defer box.deinit();

                const maybe_call = state.active_call;
                if (maybe_call == null or maybe_call.?.voice_id != v.id) {
                    if (dvui.button(@src(), "Join", .{}, .{
                        .id_extra = idx,
                        .expand = .vertical,
                        .gravity_x = 1,
                        .margin = dvui.Rect.all(4),
                    })) {
                        try state.callJoin(h.client.host_id, v.id);
                    }
                }

                {
                    const item = dvui.menuItem(@src(), .{}, .{
                        .gravity_x = 0,
                        .id_extra = idx,
                        .expand = .horizontal,
                    });
                    defer item.deinit();

                    if (state.active_call) |call| {
                        const active = call.voice_id == v.id;
                        if (active) {
                            // item.wd.options.color_fill = .{ .name = .fill };
                            item.wd.options.background = true;
                            // try item.drawBackground(.{});
                        }
                    }
                    dvui.labelNoFmt(@src(), v.name, .{}, .{
                        .font_style = .title_3,
                        .id_extra = idx,
                    });
                }
            }

            const members_menu = dvui.menu(@src(), .vertical, .{
                .id_extra = idx,
            });
            defer members_menu.deinit();

            const callers = h.client.callers.getRoom(v.id) orelse &.{};
            for (callers) |cid| {
                const caller = h.client.callers.get(cid).?;

                if (caller.user == h.client.user_id and
                    state.active_call == null) continue;

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

                const pending = if (state.active_call) |ac| switch (ac.status.get()) {
                    .intent, .connecting => true,
                    else => false,
                } else false;

                const text_color: dvui.Color = if (caller.user == h.client.user_id and pending) .gray else .white;
                const speaking = caller.client.speaking_last_ms + 250 >= core.now();
                const bg_color: ?dvui.Color = if (speaking) .yellow else null;

                dvui.labelNoFmt(@src(), m.display_name, .{}, .{
                    .font_style = .title_4,
                    .id_extra = caller.id,
                    .color_text = text_color,
                    .background = true,
                    .color_fill = bg_color,
                });
            }
        }
    }
}

fn joined_voice(state: *core.State) !void {
    if (state.active_call) |call| {
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
                .font_style = .caption_heading,
            });

            const h = state.hosts.get(call.host_id).?;
            const v = h.voices.get(call.voice_id).?;

            dvui.label(@src(), "{s} / {s}", .{ v.name, h.name }, .{
                .font_style = .caption,
            });
        }

        if (dvui.button(@src(), "Leave", .{}, .{ .expand = .vertical })) {
            try state.callLeave();
        }
    }
}

fn userbox(state: *core.State, h: *awebo.Host) !void {
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
            .font_style = .caption_heading,
            // x left, y top, w right, h bottom
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
        });

        dvui.labelNoFmt(@src(), "Online", .{}, .{
            .font_style = .body,
            // x left, y top, w right, h bottom
            .padding = dvui.Rect.all(0),
            .margin = dvui.Rect.all(0),
        });
    }

    if (dvui.button(@src(), "Share", .{}, .{ .expand = .vertical })) {
        try state.callBeginScreenShare();
    }

    if (dvui.button(@src(), "Settings", .{}, .{})) {
        client.state.active_screen = .user_settings;
    }
}
