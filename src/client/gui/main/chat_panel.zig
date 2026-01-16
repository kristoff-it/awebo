const std = @import("std");
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const core = @import("../../core.zig");
const main = @import("../../gui.zig").main;
const Host = awebo.Host;
const Chat = awebo.channels.Chat;

pub fn draw(state: *core.State, frozen: bool) !void {
    const h = state.hosts.get(main.state.active_host).?;
    const c = h.chats.get(h.client.active_channel.chat).?;

    var box = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{
            .expand = .both,
            .min_size_content = .{ .h = 40 },
            .background = true,
        },
    );
    defer box.deinit();

    try sendBar(state, h, c, frozen);
    try messageList(h, c);
}

fn sendBar(state: *core.State, h: *awebo.Host, c: *Chat, frozen: bool) !void {
    const gpa = dvui.currentWindow().gpa;

    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 1,
        .expand = .horizontal,
    });
    defer box.deinit();

    const clicked = dvui.button(@src(), "send", .{}, .{
        .gravity_x = 1,
        .margin = .{ .x = 0, .y = 4, .w = 4, .h = 4 },
        .corner_radius = .{ .x = 0, .y = 5, .w = 5, .h = 0 },
        .background = true,
        .border = dvui.Rect.all(1),
        .expand = .vertical,
    }) and !frozen;

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

    if (clicked or enter_pressed) {
        const raw = std.mem.trim(u8, in.textGet(), " \t\n\r");
        if (raw.len > 0) {
            const text = try gpa.dupe(u8, raw);
            try state.messageSend(h, c, text);
            in.textSet("", false);
        }
    }
}
fn messageList(h: *awebo.Host, c: *Chat) !void {
    var scroll = dvui.scrollArea(@src(), .{}, .{
        .expand = .both,
        // .color_fill = .{ .name = .fill_control },
    });
    defer scroll.deinit();

    const messages = c.client.messages.items.values();

    var idx: usize = 0;
    var last_author: awebo.User.Id = undefined;
    while (idx < messages.len) {
        var showing_pending = false;
        const m = &messages[idx];
        const mfr = messageFrame(h, m.author, idx);
        defer if (!showing_pending) mfr.deinit();
        last_author = mfr.author;

        while (idx < messages.len) : (idx += 1) {
            const next_m = messages[idx];
            if (m.author != next_m.author) break;

            var tl = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .id_extra = idx,
                .margin = dvui.Rect.all(0),
            });
            defer tl.deinit();
            tl.addText(next_m.text, .{});
        } else {
            idx += 1;
        }

        if (idx >= messages.len) {
            if (h.client.pending_messages.count() > 0) {
                var maybe_mfr: ?MsgFrameResult = null;
                defer if (maybe_mfr) |mfr1| mfr1.deinit();

                if (last_author != h.client.user_id) {
                    showing_pending = true;
                    mfr.deinit();
                    maybe_mfr = messageFrame(h, h.client.user_id, idx + 1);
                }

                for (h.client.pending_messages.values(), 0..) |pm, pmidx| {
                    var tl = dvui.textLayout(@src(), .{}, .{
                        .expand = .horizontal,
                        .id_extra = pmidx,
                        .margin = dvui.Rect.all(0),
                        .color_text = .gray,
                    });
                    defer tl.deinit();
                    tl.addText(pm.cms.text, .{});
                }
            }
        }
    }
}

const MsgFrameResult = struct {
    author: awebo.User.Id,
    text_box: *dvui.BoxWidget,
    msg_box: *dvui.BoxWidget,

    pub fn deinit(mfr: MsgFrameResult) void {
        mfr.text_box.deinit();
        mfr.msg_box.deinit();
    }
};
fn messageFrame(h: *awebo.Host, author_id: awebo.User.Id, idx: usize) MsgFrameResult {
    const author = h.users.get(author_id).?;

    const msg_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .id_extra = idx,
        // x left, y top, w right, h bottom
        .margin = .{ .y = 10 },
        // .border = dvui.Rect.all(1),
        // .color_border = .{ .name = .text_press },
        // .color_fill = .{ .name = .fill_control },
    });

    // dvui.image(@src(), "avatar", author.avatar, .{
    //     .gravity_y = 0,
    //     .gravity_x = 0.5,
    //     .min_size_content = .{ .w = 30, .h = 30 },
    //     .id_extra = idx,
    //     .background = true,
    //     .border = dvui.Rect.all(1),
    //     .corner_radius = dvui.Rect.all(100),
    //     .color_border = .{ .name = .accent },
    // });

    const text_box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .horizontal,
        // .color_fill = .{ .name = .fill_control },
        .id_extra = idx,
    });

    dvui.labelNoFmt(@src(), author.display_name, .{}, .{
        .font_style = dvui.Font.theme(.heading).larger(-2),
        .id_extra = idx,
        // x left, y top, w right, h bottom
        .padding = dvui.Rect.all(0),
        .margin = dvui.Rect.all(0),
    });

    return .{
        .author = author.id,
        .text_box = text_box,
        .msg_box = msg_box,
    };
}
