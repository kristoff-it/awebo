const std = @import("std");
const assert = std.debug.assert;
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

    try header(core, h, c);
    try sendBar(core, h, c, frozen);
    try typingActivity(core, h, c);

    const content_and_sidebar_box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .both,
    });
    defer content_and_sidebar_box.deinit();

    try messageList(app, h, c.id, &c.kind.chat);
    sidebar(app, h);
}

var search: struct {
    state: enum { none, waiting, present } = .none,
    origin: u64 = undefined,
    query: awebo.protocol.client.SearchMessages = undefined,
    reply: awebo.protocol.server.SearchMessagesReply = undefined,
} = .{};

fn header(core: *Core, host: *Host, channel: *Channel) !void {
    const box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .expand = .horizontal,
        .background = true,
        .style = .app2,
        .gravity_y = 0,
    });
    defer box.deinit();

    {
        const channel_name_layout = dvui.textLayout(@src(), .{}, .{
            .font = dvui.themeGet().font_title,
            .gravity_x = 0,
        });
        defer channel_name_layout.deinit();

        channel_name_layout.addText("# ", .{});
        channel_name_layout.addText(channel.name, .{});
    }

    {
        var search_placeholder_buf: [128]u8 = undefined;
        const search_placeholder = std.fmt.bufPrint(&search_placeholder_buf, "Search {s}", .{host.name}) catch return error.OutOfMemory;

        const search_bar = dvui.textEntry(@src(), .{
            .placeholder = search_placeholder,
        }, .{
            .gravity_x = 1,
        });
        defer search_bar.deinit();

        if (search_bar.enter_pressed) submit: {
            sidebar_state.show_search = true;
            if (search.state != .none) {
                search.query.deinit(core.gpa);
                if (search.state == .present) {
                    search.reply.deinit(core.gpa);
                }
                search.state = .none;
            }

            const search_bar_text = search_bar.textGet();
            if (search_bar_text.len == 0) {
                sidebar_state.show_search = false;
                break :submit;
            }

            const origin = core.now();

            const query = try core.gpa.dupe(u8, search_bar_text);
            errdefer core.gpa.free(query);

            search.query = .{ .origin = origin, .query = query };
            const bytes = try search.query.serializeAlloc(core.gpa);
            errdefer core.gpa.free(bytes);

            const conn = host.client.connection.?;
            if (conn.tcp.queue.putOne(core.io, bytes)) {
                search_bar.enter_pressed = false;
                search.state = .waiting;
                search.origin = origin;
            } else |err| {
                // log and try again on the next render - don't stop rendering
                log.warn("unable to queue SearchMessages: {t}", .{err});
            }
        }

        if (core.search_messages_reply) |smr| {
            log.debug("received {d} search results", .{smr.results.len});
            core.search_messages_reply = null;
            if (search.state != .none and search.origin == smr.origin) {
                search.reply = smr;
                search.state = .present;
            } else {
                smr.deinit(core.gpa);
            }
        }
    }
}

fn typingActivity(core: *Core, h: *awebo.Host, c: *Channel) !void {
    const now = core.now();

    var box = dvui.box(@src(), .{ .dir = .horizontal }, .{
        .gravity_y = 1,
        .expand = .horizontal,
    });
    defer box.deinit();

    var label = dvui.textLayout(@src(), .{}, .{});
    defer label.deinit();

    var users: [3]?*awebo.User = @splat(null);
    var len: usize = 0;
    var min_timeout: u64 = std.math.maxInt(u64);

    {
        var i: usize = 0;
        while (i < c.kind.chat.client.typing.count()) {
            const uid = c.kind.chat.client.typing.keys()[i];
            const timestamp = c.kind.chat.client.typing.values()[i];
            const diff = now - timestamp;

            // Remove expired typing indicators (older than 3 seconds)
            if (diff > 3 * std.time.ns_per_s) {
                c.kind.chat.client.typing.orderedRemoveAt(i);
                continue;
            }

            i += 1;

            if (uid == h.client.user_id) continue;

            min_timeout = @min(min_timeout, diff);

            users[len] = h.users.get(uid).?;
            len += 1;
            if (len > 3) break;
        }
    }

    if (len == 0) return;

    // Force a re-render when the typing indicator should expire
    dvui.timer(label.data().id, @intCast(min_timeout / std.time.ns_per_us));

    if (len > 3) {
        label.format("{d} people are typing", .{len}, .{});
    } else {
        for (users[0..len], 0..) |user, i| {
            if (i > 0) {
                if (i == len - 1) {
                    label.addText(if (len == 2) " and " else ", and ", .{});
                } else {
                    label.addText(", ", .{});
                }
            }
            label.addText(user.?.display_name, .{});
        }
        label.addText(if (len == 1) " is typing" else " are typing", .{});
    }
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
    } else if (in.text_changed_added > 0) {
        try core.chatTypingNotify(h, c);
    }
}

var channel_infos: std.AutoHashMapUnmanaged(packed struct {
    host_id: awebo.Host.ClientOnly.Id,
    channel_id: awebo.Channel.Id,
}, struct {
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
    if (!gop.found_existing) gop.value_ptr.* = .{};

    const channel_info = gop.value_ptr;
    const scroll_info = &channel_info.scroll_info;

    const stick_to_bottom = scroll_info.offsetFromMax(.vertical) <= 0;
    var scroll_lock_visible = false;

    // are we close enough to the top to load new messages?
    const oldest_uid = if (c.messages.oldest()) |old| old.id else 1;
    const want_more_history = gop.found_existing and scroll_info.offset(.vertical) <= 100;
    if (!c.client.waiting_old_messages and want_more_history and !c.client.loaded_all_old_messages) {
        log.debug("query: {} {}", .{ oldest_uid, channel_id });
        var rs = h.client.qs.select_channel_history.run(@src(), h.client.db, .{
            .below_uid = oldest_uid,
            .channel = channel_id,
            .limit = 16,
        });

        var count: usize = 0;
        while (rs.next()) |r| : (count += 1) {
            log.debug("chat panel: pushing history message {}", .{r.get(.uid)});
            c.messages.pushOld(gpa, .{
                .id = r.get(.uid),
                .origin = r.get(.origin),
                .created = r.get(.created),
                .update_uid = r.get(.update_uid),
                .author = r.get(.author),
                .text = try r.text(gpa, .body),
            }) catch @panic("oom");
        }

        log.debug("loaded {} history messages from db oldest_uid = {}", .{ count, oldest_uid });

        if (count == 0) {
            log.debug("fetching history from server", .{});
            if (c.client.fetched_all_old_messages) {
                c.client.loaded_all_old_messages = true;
            } else {
                core.chatHistoryGet(h, channel_id, c, oldest_uid);
            }
        } else {
            c.client.loaded_all_new_messages = false;
            scroll_lock_visible = true;
        }
    }

    // are we close enough to the bottom to want to load newer messages?
    const want_more_present = scroll_info.offset(.vertical) > scroll_info.scrollMax(.vertical) - 150;
    const newest_uid = if (c.messages.latest()) |new| new.id else 1;
    if (!c.client.waiting_new_messages and
        want_more_present and !c.client.loaded_all_new_messages)
    {
        var rs = h.client.qs.select_channel_present.run(@src(), h.client.db, .{
            .above_uid = newest_uid,
            .channel = channel_id,
            .limit = 16,
        });

        var count: usize = 0;
        while (rs.next()) |r| : (count += 1) {
            log.debug("chat panel: pushing new message {}", .{r.get(.uid)});
            c.messages.pushNew(gpa, .{
                .id = r.get(.uid),
                .origin = r.get(.origin),
                .created = r.get(.created),
                .update_uid = r.get(.update_uid),
                .author = r.get(.author),
                .text = try r.text(gpa, .body),
            }) catch @panic("oom");
        }

        if (count == 0) {
            log.debug("fetching present from server", .{});
            c.client.loaded_all_new_messages = true;
            c.client.fetched_all_new_messages = true;
            // if (c.client.fetched_all_history) {
            //     c.client.loaded_all_history = true;
            // } else {
            //     core.chatHistoryGet(h, channel_id, c, oldest_uid);
            // }
        } else {
            c.client.loaded_all_old_messages = false;
            scroll_lock_visible = true;
        }
    }

    // if (c.client.waiting_history) {
    //     dvui.spinner(@src(), .{});
    // }

    var scroll = dvui.scrollArea(@src(), .{
        .scroll_info = scroll_info,
        .lock_visible = scroll_lock_visible,
    }, .{
        // .data_out = scroll_info,
        .min_size_content = .{ .h = 250 },

        .expand = .both,
        // .color_fill = .{ .name = .fill_control },
    });

    var last_author: awebo.User.Id = undefined;
    var mit: MessageIterator = .init(c.messages.slices());
    while (mit.next()) |m| {
        drawMessage(h, m.author, m.created.fmt(tz, h.epoch), .raw, m.text, m.id);

        last_author = m.author;
        while (mit.peek()) |maybe_continue| {
            if (m.author != maybe_continue.author) break;

            const message_continuation = mit.next().?;

            drawMessage(
                h,
                null,
                message_continuation.created.fmt(tz, h.epoch),
                .raw,
                message_continuation.text,
                message_continuation.id,
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
                        .raw,
                        pm.cms.text,
                        pmidx + 1,
                    );
                    // after we print the first one, all others are guaranteed
                    // to be continuations
                    id = null;
                }
            }
        }
    }

    scroll.deinit();

    if (!gop.found_existing or (c.client.new_messages and stick_to_bottom)) {
        c.client.new_messages = false;
        // do this after scrollArea has given scroll_info the new size
        scroll_info.scrollToOffset(.vertical, std.math.floatMax(f32));
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
        rb_slices: [2][]const awebo.Message,
    ) MessageIterator {
        return .{
            .state = .{ .ringbuf = .{} },
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
    /// null means this message is a continuation of a previous message
    /// from the same author
    author_id: ?awebo.User.Id,
    /// null means that this is a pending message that we wrote
    date_fmt: ?awebo.Date.Formatter,
    text_fmt: enum { highlighted, raw },
    text: []const u8,
    idx: usize,
) void {
    if (date_fmt == null) if (author_id) |aid| assert(aid == h.client.user_id);

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
        {
            const image_box = dvui.box(@src(), .{}, .{
                .id_extra = idx,
                .min_size_content = .{ .w = 40, .h = 35 },
                // x left, y top, w right, h bottom
                .margin = .rect(0, 0, 10, 0),
            });
            defer image_box.deinit();

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
                .gravity_y = 0.5,
                .gravity_x = 1,
                // .color_border = .{ .name = .accent },
            });
        }
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
            .min_size_content = .{ .w = 40, .h = 10 },
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
                .padding = .all(0),
                .margin = .all(0),
                .font = .theme(.mono),
                .color_text = if (hover) dvui.Color.gray.lighten(8) else .transparent,
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

    switch (text_fmt) {
        .raw => tl.addText(text, .{}),
        .highlighted => {
            var rest = text;
            while (std.mem.cut(u8, rest, &.{ 0x20, 0x0B })) |cut| {
                const unhighlighted, const highlight_start = cut;
                tl.addText(unhighlighted, .{});
                const highlighted, rest = std.mem.cut(u8, highlight_start, &.{ 0x20, 0x0B }).?;
                tl.addText(highlighted, .{
                    .background = true,
                    .color_fill = dvui.themeGet().highlight.fill,
                });
            }

            tl.addText(rest, .{});
        },
    }
}

var sidebar_state: struct {
    show_search: bool = false,
} = .{};

fn sidebar(app: *App, host: *Host) void {
    if (!sidebar_state.show_search) return;

    if (sidebar_state.show_search) {
        const static_width = dvui.themeGet().font_body.size * 25;
        const box = dvui.box(@src(), .{}, .{
            .background = true,
            .style = .app2,
            .padding = .all(5),
            .min_size_content = .width(static_width),
            .max_size_content = .width(static_width),
        });
        defer box.deinit();

        {
            const search_header = dvui.box(@src(), .{ .dir = .horizontal }, .{
                .expand = .horizontal,
            });
            defer search_header.deinit();

            if (search.state != .none) {
                const font = dvui.themeGet().font_heading.withStyle(.normal).withWeight(.normal);
                const search_header_search_text = dvui.textLayout(@src(), .{
                    .show_touch_draggables = false,
                    .touch_edit_just_focused = false,
                }, .{
                    .font = font,
                });
                defer search_header_search_text.deinit();

                if (search.state == .waiting) {
                    search_header_search_text.addText("Searching ", .{});
                    search_header_search_text.addText(host.name, .{
                        .font = font.withStyle(.italic).withWeight(.bold),
                    });
                } else {
                    var buffer: [32]u8 = undefined;
                    const length = std.fmt.bufPrint(&buffer, "{d}", .{search.reply.results.len}) catch unreachable;
                    search_header_search_text.addText(length, .{});
                    search_header_search_text.addText(" results", .{});
                }
                search_header_search_text.addText(" for \"", .{});
                search_header_search_text.addText(search.query.query, .{
                    .font = font.withStyle(.italic).withWeight(.bold),
                });
                search_header_search_text.addText("\"", .{});
                if (search.state == .waiting) search_header_search_text.addText("...", .{});
            }
        }

        const scroll = dvui.scrollArea(@src(), .{}, .{
            .expand = .both,
        });
        defer scroll.deinit();

        if (search.state == .present) {
            var current_channel_id: ?Channel.Id = null;
            for (search.reply.results, 0..) |result, idx| {
                if (current_channel_id != result.channel) {
                    const channel_header = dvui.textLayout(@src(), .{
                        .show_touch_draggables = false,
                        .touch_edit_just_focused = false,
                    }, .{
                        .id_extra = idx,
                        .expand = .horizontal,
                        .font = dvui.themeGet().font_title,
                        .padding = .{
                            .x = 5,
                            .y = 10,
                            .w = 5,
                            .h = 0, // bottom padding is guaranteed by card_box
                        },
                    });
                    defer channel_header.deinit();

                    channel_header.addText("# ", .{});
                    const current_channel = host.channels.get(result.channel).?;
                    channel_header.addText(current_channel.name, .{});
                    current_channel_id = result.channel;
                }

                const card_box = dvui.box(@src(), .{}, .{
                    .id_extra = idx,
                    .expand = .horizontal,
                    .background = true,
                    .border = .all(2),
                    .style = .app3,
                    .padding = .all(5),
                });
                defer card_box.deinit();

                drawMessage(host, result.preview.author, result.preview.created.fmt(&app.tz, host.epoch), .highlighted, result.preview.text, idx);
            }
        }
    }
}
