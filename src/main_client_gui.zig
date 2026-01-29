const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const folders = @import("folders");
const dvui = @import("dvui");
const awebo = @import("awebo.zig");
const gui = @import("client/gui.zig");
const Host = awebo.Host;
const Voice = awebo.VoiceChannel;
const cli = @import("cli.zig");

const log = std.log.scoped(.client);

const window_icon_png = @embedFile("client/data/zig-favicon.png");
const vsync = true;

pub const Core = @import("client/Core.zig");
pub const StringPool = @import("client/StringPool.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 800.0, .h = 600.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "Awebo",
            .icon = window_icon_png,
            .window_init_options = .{
                // Could set a default theme here
                // .theme = dvui.Theme.builtin.dracula,
            },
        },
    },
    .frameFn = frame,
    .initFn = init,
    .deinitFn = deinit,
};
pub const main = dvui.App.main;
pub const panic = dvui.App.panic;
pub const std_options: std.Options = .{
    .logFn = dvui.App.logFn,
};

var global_app_singleton: App = undefined;

fn frame() !dvui.App.Result {
    return global_app_singleton.frame();
}

fn init(window: *dvui.Window) !void {
    return global_app_singleton.init(window);
}

fn deinit() void {}

pub const App = struct {
    active_screen: union(enum) {
        loading,
        main,
        user_settings,
        server_settings,
    },
    window: *dvui.Window,
    core_future: Io.Future(void),
    core: Core,
    command_queue_buffer: [1024]Core.NetworkCommand,

    // main
    active_host: Host.ClientOnly.Id = 0,
    show_new_chat: bool = false,
    pending_new_chat: ?*Core.ui.ChannelCreate = null,

    // empty
    in_progress_host_join: ?Core.ui.FirstConnectionStatus = null,
    show_add_host: bool = false,
    err_msg: ?[]const u8 = null,
    environ: *std.process.Environ.Map,

    fn init(app: *App, window: *dvui.Window) void {
        const io = window.io;
        const gpa = window.gpa;

        var empty_environ: std.process.Environ.Map = .init(gpa);
        var environ = &empty_environ;
        if (dvui.App.main_init) |mi| {
            environ = mi.environ_map;

            var it = std.process.Args.Iterator.initAllocator(mi.minimal.args, gpa) catch {
                cli.fatal("unable to allocate cli arguments", .{});
            };

            while (it.next()) |arg| {
                log.debug("arg: {s}", .{arg});
            }
        }

        app.* = .{
            .active_screen = .main,
            .window = window,
            .command_queue_buffer = undefined,
            .environ = environ, // TODO: get from dvui
            .core = .init(gpa, io, environ, refresh, &app.command_queue_buffer),
            .core_future = io.concurrent(Core.run, .{&app.core}) catch |err| {
                cli.fatal("unable to start awebo client core: {t}", .{err});
            },
        };
    }

    fn frame(app: *App) !dvui.App.Result {
        if (checkClosing(app)) return .close;

        var locked = app.core.lockState();
        defer locked.unlock();

        const core = &app.core;

        if (core.failure != .none) return .close;
        if (!core.loaded) return loadingFrame();
        try guiFrame(app);
        return .ok;
    }

    fn guiFrame(app: *App) !void {
        const core = &app.core;
        var main_box = dvui.box(
            @src(),
            .{ .dir = .horizontal },
            .{
                .expand = .both,
                .background = true,
            },
        );
        defer main_box.deinit();

        if (core.hosts.last_id == 0) {
            try gui.empty.draw(app);
            return;
        }

        switch (app.active_screen) {
            .loading => gui.loading.draw(),
            .main => try gui.main.draw(app),
            .user_settings => gui.user.draw(app),
            else => @panic("TODO"),
        }
    }

    fn checkClosing(app: *App) bool {
        const win = dvui.currentWindow();
        const wd = win.data();
        for (dvui.events()) |*e| {
            if (!dvui.eventMatchSimple(e, wd)) continue;
            if ((e.evt == .window and e.evt.window.action == .close) or (e.evt == .app and e.evt.app.action == .quit)) {
                e.handle(@src(), wd);
                log.debug("shutting down core from ui", .{});
                app.core_future.cancel(win.io);
                return true;
            }
        }

        return false;
    }

    fn refresh(core: *Core, src: std.builtin.SourceLocation, id: ?u64) void {
        const app: *App = @fieldParentPtr("core", core);
        dvui.refresh(app.window, src, if (id) |i| @enumFromInt(i) else null);
    }
};

fn loadingFrame() !dvui.App.Result {
    var main_box = dvui.box(
        @src(),
        .{ .dir = .vertical },
        .{ .expand = .both, .background = true },
    );
    defer main_box.deinit();

    // While performing the initial load, we display a spinner.
    // Synchronization for the initial load happens via an atomic enum
    // because locking the entire state right now would either hang or
    // slow down the initial setup process.
    dvui.spinner(@src(), .{
        .gravity_x = 0.5,
        .gravity_y = 0.5,
        .expand = .both,
    });
    dvui.labelNoFmt(@src(), "LOADING>>>", .{}, .{
        .gravity_x = 0.5,
        .expand = .both,
        .font = .theme(.title),
    });
    return .ok;
}

test {
    _ = Core;
}
