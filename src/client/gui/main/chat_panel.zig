const std = @import("std");
const Allocator = std.mem.Allocator;
const dvui = @import("dvui");
const awebo = @import("../../../awebo.zig");
const Channel = awebo.Channel;
const Chat = Channel.Chat;
const Core = @import("../../Core.zig");
const App = @import("../../../main_client_gui.zig").App;
const Host = awebo.Host;

const zig_logo = @embedFile("../../data/zig-favicon.png");

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

    var idx: usize = 0;
    var last_author: awebo.User.Id = undefined;
    var mit: MessageIterator = .init(c.client.history, c.messages.slices());
    while (mit.next()) |m| : (idx += 1) {
        drawMessage(h, m.author, m.created.fmt(tz, h.epoch), m.text, idx);

        last_author = m.author;
        while (mit.peek()) |maybe_continue| {
            if (m.author != maybe_continue.author) break;

            const message_continuation = mit.next().?;
            idx += 1;

            drawMessage(
                h,
                null,
                message_continuation.created.fmt(tz, h.epoch),
                message_continuation.text,
                idx,
            );
        }

        if (mit.peek() == null) {
            if (h.client.pending_messages.count() > 0) {
                var id = if (last_author != h.client.user_id) h.client.user_id else null;
                for (h.client.pending_messages.values(), 0..) |pm, pmidx| {
                    drawMessage(
                        h,
                        id,
                        null,
                        pm.cms.text,
                        idx + pmidx + 1,
                    );
                    // after we print the first one, all others are guaranteed
                    // to be continuations
                    id = null;
                }
            }
        }
    }
}

const MessageIterator = struct {
    rb_slices: [2][]const awebo.Message,

    idx: usize = 0,
    state: union(enum) {
        history: std.Deque(awebo.Message).Iterator,
        ringbuf: struct { slice_idx: u1 = 0, idx: usize = 0 },
    },

    pub fn init(
        history: std.Deque(awebo.Message),
        rb_slices: [2][]const awebo.Message,
    ) MessageIterator {
        return .{
            .state = .{ .history = history.iterator() },
            .rb_slices = rb_slices,
        };
    }

    pub fn next(mi: *MessageIterator) ?awebo.Message {
        state: switch (mi.state) {
            .history => |*hit| return hit.next() orelse {
                mi.state = .{ .ringbuf = .{} };
                continue :state mi.state;
            },
            .ringbuf => |*rb| {
                while (rb.idx >= mi.rb_slices[rb.slice_idx].len) {
                    if (rb.slice_idx == mi.rb_slices.len - 1) return null;
                    rb.slice_idx += 1;
                    rb.idx = 0;
                }

                const msg = mi.rb_slices[rb.slice_idx][rb.idx];
                rb.idx += 1;
                return msg;
            },
        }
    }

    pub fn peek(mi: *MessageIterator) ?awebo.Message {
        var temp = mi.*;
        return temp.next();
    }
};

fn drawMessage(
    h: *awebo.Host,
    // null means this message is a continuation of a previous message
    // from the same author
    author_id: ?awebo.User.Id,
    date_fmt: ?awebo.Date.Formatter,
    text: []const u8,
    idx: usize,
) void {
    const msg_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .id_extra = idx,
        // x left, y top, w right, h bottom
        .padding = .all(5),
        // .border = dvui.Rect.all(1),
        // .color_border = .{ .name = .text_press },
        // .color_fill = .{ .name = .fill_control },
    });
    defer msg_box.deinit();

    // light up on mouseover
    const hover = blk: {
        var hover = false;
        const evts = dvui.events();
        for (evts) |*e| {
            if (!dvui.eventMatchSimple(e, msg_box.data())) {
                continue;
            }

            if (e.evt == .mouse and e.evt.mouse.action == .position) {
                msg_box.data().options.background = true;
                msg_box.data().options.color_fill = dvui.themeGet().color(.content, .fill_hover);
                hover = true;
                e.handle(@src(), msg_box.data());
            }
        }
        msg_box.drawBackground();
        break :blk hover;
    };

    // No author id means that this message is a "continuation"
    // from a previous message.
    const main_box = if (author_id) |aid| blk: {
        _ = dvui.image(@src(), .{
            .source = .{
                .imageFile = .{
                    .bytes = zig_logo,
                    .name = "avatar",
                },
            },
        }, .{
            .min_size_content = .{ .w = 35, .h = 35 },
            .id_extra = idx,
            .background = true,
            .border = dvui.Rect.all(1),
            .corner_radius = dvui.Rect.all(100),
            // x left, y top, w right, h bottom
            .margin = .rect(0, 0, 10, 0),
            .gravity_y = 0.5,
            // .color_border = .{ .name = .accent },
        });

        const main_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .horizontal,
            // .color_fill = .{ .name = .fill_control },
            .id_extra = idx,
        });

        {
            const author = h.users.get(aid).?;
            const author_date_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
                .id_extra = idx,
                // x left, y top, w right, h bottom
                .margin = .{ .h = 5 },
            });
            defer author_date_box.deinit();

            dvui.labelNoFmt(@src(), author.display_name, .{}, .{
                // .font_style = dvui.Font.theme(.heading).larger(-2),
                .id_extra = idx,
                // x left, y top, w right, h bottom
                .padding = dvui.Rect.all(0),
                .margin = dvui.Rect.all(0),
                .font = dvui.Font.theme(.heading).larger(3),
            });

            if (date_fmt) |fmt| {
                dvui.label(@src(), "  {f}", .{fmt}, .{
                    // .font_style = dvui.Font.theme(.heading).larger(-2),
                    .id_extra = idx,
                    .gravity_y = 0.5,
                    // x left, y top, w right, h bottom
                    .padding = dvui.Rect.all(0),
                    .margin = dvui.Rect.all(0),
                    .font = .theme(.body),
                    .color_text = .gray,
                });
            }
        }

        break :blk main_box;
    } else blk: {
        const left_box = dvui.box(@src(), .{}, .{
            .min_size_content = .{ .w = 35, .h = 10 },
            // x left, y top, w right, h bottom
            .margin = .rect(0, 0, 11, 0),
        });

        defer left_box.deinit();

        if (date_fmt) |fmt| {
            const hour_fmt: awebo.Date.Formatter = .{
                .server_epoch = fmt.server_epoch,
                .date = fmt.date,
                .tz = fmt.tz,
                .gofmt = "15:04",
            };

            dvui.label(@src(), "{f}", .{hour_fmt}, .{
                // .font_style = dvui.Font.theme(.heading).larger(-2),
                .id_extra = idx,
                // x left, y top, w right, h bottom
                .padding = dvui.Rect.all(0),
                .margin = dvui.Rect.all(0),
                .font = dvui.Font.theme(.mono),
                .color_text = if (hover) dvui.Color.gray.lighten(5) else .transparent,
            });
        }

        break :blk null;
    };
    defer if (main_box) |mb| mb.deinit();

    var tl = dvui.textLayout(@src(), .{}, .{
        .expand = .horizontal,
        .id_extra = idx,
        .margin = .all(0),
        .padding = .all(0),
        .background = false,
        .color_text = if (date_fmt == null) .gray else null,
    });

    defer tl.deinit();
    tl.addText(text, .{});
}
