const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const dvui = @import("dvui");
const awebo = @import("../../awebo.zig");
const Host = awebo.Host;
const core = @import("../core.zig");
const main = @import("main.zig");
const client = @import("../../main_client_gui.zig");

pub var state: struct {
    in_progress_host_join: ?core.ui.FirstConnectionStatus = null,
    show_add_host: bool = false,
    err_msg: ?[]const u8 = null,
} = .{};

pub fn draw(core_state: *core.State) !void {
    var box = dvui.box(@src(), .{ .dir = .vertical }, .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .horizontal,
    });
    defer box.deinit();

    dvui.labelNoFmt(@src(), "Welcome", .{}, .{
        .gravity_x = 0.5,
        // .expand = .horizontal,
        .font = .theme(.title),
    });

    if (state.in_progress_host_join) |*status| {
        if (status.get() == .success) {
            main.state.show_new_chat = false;
            state.show_add_host = false;
            state.in_progress_host_join = null;
        }
    }

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 0.5,
            // .gravity_y = 0.5,
        });
        defer hbox.deinit();

        if (dvui.button(@src(), "Join Existing", .{}, .{})) {
            state.show_add_host = true;
        }
        if (dvui.button(@src(), "Create Server", .{}, .{})) {
            dvui.toggleDebugWindow();
        }
    }

    if (state.show_add_host) {
        try new_host_floating_window(core_state);
    }
}

fn new_host_floating_window(app_state: *core.State) !void {
    const gpa = dvui.currentWindow().gpa;

    const fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .padding = dvui.Rect.all(10),
    });
    defer fw.deinit();

    fw.dragAreaSet(dvui.windowHeader("Add new server", "", &state.show_add_host));

    _ = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(10) });

    var address: []const u8 = undefined;
    var address_input = dvui.textEntry(@src(), .{
        .placeholder = "Server IP Address",
    }, .{
        .expand = .horizontal,
    });
    address = try gpa.dupe(u8, address_input.getText());
    if (address.len == 0) address = "127.0.0.1";
    address_input.deinit();

    var username: []const u8 = undefined;
    var username_input = dvui.textEntry(@src(), .{
        .placeholder = "Username",
    }, .{
        .expand = .horizontal,
    });
    username = try gpa.dupe(u8, username_input.getText());
    username_input.deinit();

    var password: []const u8 = undefined;
    var password_input = dvui.textEntry(@src(), .{
        .placeholder = "Password",
        .password_char = "*",
    }, .{
        .expand = .horizontal,
    });
    password = try gpa.dupe(u8, password_input.getText());
    password_input.deinit();

    if (state.in_progress_host_join) |*status| {
        const msg = switch (status.get()) {
            else => |v| @tagName(v),
        };

        state.err_msg = msg;
    }

    dvui.labelNoFmt(@src(), state.err_msg orelse "", .{}, .{
        .gravity_x = 0.5,
        .expand = .horizontal,
    });

    const clicked = dvui.button(@src(), "Join", .{}, .{
        .gravity_x = 1,
        .background = true,
        .border = dvui.Rect.all(1),
        .expand = .horizontal,
    });

    if (clicked) blk: {
        if (main.state.pending_new_chat) |p| {
            if (p.status.get() == .ok) {
                p.destroy(gpa);
            } else break :blk;
        }

        const address_trimmed = std.mem.trim(u8, address, " \t\n\r");
        if (address_trimmed.len == 0) {
            state.err_msg = "Missing IP Address!";
            return;
        }

        const username_trimmed = std.mem.trim(u8, username, " \t\n\r");
        if (username_trimmed.len == 0) {
            state.err_msg = "Missing Username!";
            return;
        }

        state.err_msg = null;
        _ = Io.net.IpAddress.parse(address_trimmed, 1991) catch |err| {
            state.err_msg = @errorName(err);
            break :blk;
        };

        // TODO: we should not be discarding this.
        state.in_progress_host_join = .{};
        _ = try app_state.hostJoin(address_trimmed, username_trimmed, password, &state.in_progress_host_join.?);
    }
}
