const std = @import("std");
const Allocator = std.mem.Allocator;
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const Channel = awebo.Channel;
const Chat = Channel.Chat;
const Core = @import("../../Core.zig");
const App = @import("../../../main_client_gui.zig").App;
const Host = awebo.Host;

const log = std.log.scoped(.chat_panel);

pub fn draw(app: *App, frozen: bool) !void {
    const core = &app.core;
    const h = core.hosts.get(app.active_host).?;
    const c = h.channels.get(h.client.active_channel.?).?;

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

    try sendBar(core, h, c, frozen);
    try messageList(app, h, c.id, &c.kind.chat);
}

fn sendBar(core: *Core, h: *awebo.Host, c: *Channel, frozen: bool) !void {
    const gpa = core.gpa;

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

    if (clicked or (in.enter_pressed and !frozen)) {
        const raw = std.mem.trim(u8, in.textGet(), " \t\n\r");
        if (raw.len > 0) {
            const text = try gpa.dupe(u8, raw);
            try core.messageSend(h, c, text);
            in.textSet("", false);
        }
    }
}

var channel_infos: std.AutoHashMapUnmanaged(packed struct {
    host_id: awebo.Host.ClientOnly.Id,
    channel_id: awebo.Channel.Id,
}, struct {
    waiting_history: ?awebo.Message.Id = null,
    scroll_info: dvui.ScrollInfo = .{},
}) = .empty;

fn messageList(app: *App, h: *awebo.Host, channel_id: awebo.Channel.Id, c: *Chat) !void {
    const core = &app.core;
    const gpa = core.gpa;
    const tz = &app.tz;

    const gop = try channel_infos.getOrPut(gpa, .{
        .host_id = h.client.host_id,
        .channel_id = channel_id,
    });

    const channel_info = gop.value_ptr;
    const scroll_info = &channel_info.scroll_info;

    if (!gop.found_existing) {
        channel_info.* = .{};
        scroll_info.scrollToOffset(.vertical, std.math.floatMax(f32));
    }

    const oldest_uid = if (c.client.history.front()) |old|
        old.id
    else if (c.messages.oldest()) |old|
        old.id
    else
        1;

    if (channel_info.waiting_history) |wh| {
        if (oldest_uid <= wh) channel_info.waiting_history = null;
    }

    if (dvui.button(@src(), "request more history", .{}, .{})) {
        log.debug("button press!", .{});
        if (channel_info.waiting_history == null) {
            log.debug("sending chat history request!", .{});
            core.chatHistoryGet(h, channel_id, oldest_uid);
            channel_info.waiting_history = oldest_uid - 1;
        }
    }

    if (channel_info.waiting_history != null) {
        dvui.spinner(@src(), .{});
    }

    var scroll = dvui.scrollArea(@src(), .{ .scroll_info = scroll_info }, .{
        .expand = .both,
        // .color_fill = .{ .name = .fill_control },
    });
    defer scroll.deinit();

    // render history crappily
    {
        var it = c.client.history.iterator();
        var i: usize = 1000;
        while (it.next()) |msg| : (i += 1) {
            const mfr = messageFrame(h, msg.author, i);
            defer mfr.deinit();

            dvui.label(@src(), "{f}", .{msg.created.fmt(tz, h.epoch)}, .{
                .id_extra = i,
            });

            var tl = dvui.textLayout(@src(), .{}, .{
                .expand = .horizontal,
                .id_extra = i,
                .margin = dvui.Rect.all(0),
            });
            defer tl.deinit();
            tl.addText(msg.text, .{});
        }
    }

    const messages_len = c.messages.len;

    var idx: usize = 0;
    var last_author: awebo.User.Id = undefined;
    while (idx < messages_len) {
        var showing_pending = false;
        const m = c.messages.at(idx);
        const mfr = messageFrame(h, m.author, idx);
        defer if (!showing_pending) {
            mfr.deinit();
        };
        last_author = mfr.author;

        while (idx < messages_len) : (idx += 1) {
            const next_m = c.messages.at(idx);
            if (m.author != next_m.author) break;

            dvui.label(@src(), "{f}", .{m.created.fmt(tz, h.epoch)}, .{
                .id_extra = idx,
            });

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

        if (idx >= messages_len) {
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
        // .font_style = dvui.Font.theme(.heading).larger(-2),
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
