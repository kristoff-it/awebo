const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const dvui = @import("dvui");
const awebo = @import("../../awebo.zig");
const Host = awebo.Host;
const Core = @import("../Core.zig");
const main = @import("main.zig");
const App = @import("../../main_client_gui.zig").App;

const log = std.log.scoped(.@"gui/empty");

pub fn draw(app: *App) !void {
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

    if (app.in_progress_host_join) |*status| {
        if (status.get() == .success) {
            app.show_new_chat = false;
            app.show_add_host = false;
            app.in_progress_host_join = null;
        }
    }

    {
        var hbox = dvui.box(@src(), .{ .dir = .horizontal }, .{
            .gravity_x = 0.5,
            // .gravity_y = 0.5,
        });
        defer hbox.deinit();

        if (dvui.button(@src(), "Join Existing", .{}, .{})) {
            app.show_add_host = true;
        }
        if (dvui.button(@src(), "Invite Sign-up", .{}, .{})) {
            app.show_invite_signup = true;
        }
    }

    if (app.show_add_host) {
        try newHostFloatingWindow(app);
    } else if (app.show_invite_signup) {
        try inviteSignUpFloatingWindow(app);
    }
}

fn newHostFloatingWindow(app: *App) !void {
    const core = &app.core;
    const gpa = core.gpa;

    const fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .padding = dvui.Rect.all(10),
    });
    defer fw.deinit();

    fw.dragAreaSet(dvui.windowHeader("Add new server", "", &app.show_add_host));

    _ = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(10) });

    // TODO: This should probably just be a `frame_arena` field on `App` that is cleared before every frame
    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var enter_pressed = false;

    var address: []const u8 = undefined;
    var address_input = dvui.textEntry(@src(), .{
        .placeholder = "Server IP Address",
    }, .{
        .expand = .horizontal,
    });
    enter_pressed = enter_pressed or address_input.enter_pressed;
    address = try arena.dupe(u8, address_input.getText());
    if (address.len == 0) address = "127.0.0.1";
    address_input.deinit();

    var username: []const u8 = undefined;
    var username_input = dvui.textEntry(@src(), .{
        .placeholder = "Username",
    }, .{
        .expand = .horizontal,
    });
    enter_pressed = enter_pressed or username_input.enter_pressed;
    username = try arena.dupe(u8, username_input.getText());
    username_input.deinit();

    var password: []const u8 = undefined;
    var password_input = dvui.textEntry(@src(), .{
        .placeholder = "Password",
        .password_char = "*",
    }, .{
        .expand = .horizontal,
    });
    enter_pressed = enter_pressed or password_input.enter_pressed;
    password = try arena.dupe(u8, password_input.getText());
    password_input.deinit();

    if (app.in_progress_host_join) |*status| {
        const msg = switch (status.get()) {
            else => |v| @tagName(v),
        };

        app.err_msg = msg;
    }

    dvui.labelNoFmt(@src(), app.err_msg orelse "", .{}, .{
        .gravity_x = 0.5,
        .expand = .horizontal,
    });

    const clicked = dvui.button(@src(), "Join", .{}, .{
        .gravity_x = 1,
        .background = true,
        .border = dvui.Rect.all(1),
        .expand = .horizontal,
    });

    if (clicked or enter_pressed) blk: {
        std.debug.print("address: '{s}', username: '{s}', password: '{s}'\n", .{ address, username, password });
        if (app.pending_new_chat) |p| {
            if (p.status.get() == .ok) {
                p.destroy(gpa);
            } else break :blk;
        }

        const address_trimmed = std.mem.trim(u8, address, " \t\n\r");
        if (address_trimmed.len == 0) {
            app.err_msg = "Missing IP Address!";
            return;
        }

        const username_trimmed = std.mem.trim(u8, username, " \t\n\r");
        if (username_trimmed.len == 0) {
            app.err_msg = "Missing Username!";
            return;
        }

        app.err_msg = null;
        _ = Io.net.IpAddress.parse(address_trimmed, 1991) catch |err| {
            app.err_msg = @errorName(err);
            break :blk;
        };

        // TODO: we should not be discarding this.
        app.in_progress_host_join = .{};
        _ = try core.hostJoin(address_trimmed, username_trimmed, password, &app.in_progress_host_join.?);
    }
}

fn inviteSignUpFloatingWindow(app: *App) !void {
    const core = &app.core;
    const gpa = core.gpa;

    const fw = dvui.floatingWindow(@src(), .{ .modal = true }, .{
        .padding = dvui.Rect.all(10),
    });
    defer fw.deinit();

    fw.dragAreaSet(dvui.windowHeader("Invite Sign-up", "", &app.show_invite_signup));

    _ = dvui.spacer(@src(), .{ .min_size_content = dvui.Size.all(10) });

    // TODO: This should probably just be a `frame_arena` field on `App` that is cleared before every frame
    var arena_allocator: std.heap.ArenaAllocator = .init(gpa);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();

    var enter_pressed = false;

    var invite: []const u8 = undefined;
    var invite_input = dvui.textEntry(@src(), .{
        .placeholder = "Invite",
    }, .{
        .expand = .horizontal,
    });
    enter_pressed = enter_pressed or invite_input.enter_pressed;
    invite = try arena.dupe(u8, invite_input.getText());
    invite_input.deinit();

    var username: []const u8 = undefined;
    var username_input = dvui.textEntry(@src(), .{
        .placeholder = "Username",
    }, .{
        .expand = .horizontal,
    });
    enter_pressed = enter_pressed or username_input.enter_pressed;
    username = try arena.dupe(u8, username_input.getText());
    username_input.deinit();

    var password: []const u8 = undefined;
    var password_input = dvui.textEntry(@src(), .{
        .placeholder = "Password",
        .password_char = "*",
    }, .{
        .expand = .horizontal,
    });
    enter_pressed = enter_pressed or password_input.enter_pressed;
    password = try arena.dupe(u8, password_input.getText());
    password_input.deinit();

    var password_confirm: []const u8 = undefined;
    var password_confirm_input = dvui.textEntry(@src(), .{
        .placeholder = "Confirm Password",
        .password_char = "*",
    }, .{
        .expand = .horizontal,
    });
    enter_pressed = enter_pressed or password_confirm_input.enter_pressed;
    password_confirm = try arena.dupe(u8, password_confirm_input.getText());
    password_confirm_input.deinit();

    if (app.in_progress_host_join) |*status| {
        const msg = switch (status.get()) {
            else => |v| @tagName(v),
        };

        app.err_msg = msg;
    }

    dvui.labelNoFmt(@src(), app.err_msg orelse "", .{}, .{
        .gravity_x = 0.5,
        .expand = .horizontal,
    });

    const clicked = dvui.button(@src(), "Sign-up", .{}, .{
        .gravity_x = 1,
        .background = true,
        .border = dvui.Rect.all(1),
        .expand = .horizontal,
    });

    if (clicked or enter_pressed) blk: {
        if (app.pending_new_chat) |p| {
            if (p.status.get() == .ok) {
                p.destroy(gpa);
            } else break :blk;
        }

        const invite_trimmed = std.mem.trim(u8, invite, " \t\n\r");
        if (invite_trimmed.len == 0) {
            app.err_msg = "Missing invite!";
            return;
        }

        const username_trimmed = std.mem.trim(u8, username, " \t\n\r");
        if (username_trimmed.len == 0) {
            app.err_msg = "Missing Username!";
            return;
        }

        if (password.len == 0) {
            app.err_msg = "Missing Password!";
            return;
        }

        if (!std.mem.eql(u8, password, password_confirm)) {
            app.err_msg = "Passwords do not match!";
            return;
        }

        if (!std.mem.eql(u8, password, password_confirm)) {
            app.err_msg = "Passwords do not match!";
            return;
        }

        const invite_parsed = awebo.Invite.parse(gpa, invite_trimmed) catch {
            app.err_msg = "Invalid invite format!";
            break :blk;
        };
        log.debug("Parsed invite: Invite(address: {f}, port: {d}, slug: \"{s}\")", .{
            invite_parsed.address,
            invite_parsed.port,
            invite_parsed.slug,
        });
        defer invite_parsed.deinit(gpa);

        app.err_msg = null;

        // TODO: core.inviteSignup(invite_parsed, username_trimmed, password, &app.in_progress_host_join.?);
    }
}
