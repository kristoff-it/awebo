const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const folders = @import("folders");
const dvui = @import("dvui");
const zeit = @import("zeit");
const awebo = @import("awebo.zig");
const Gui = @import("client/Gui.zig");
const Host = awebo.Host;
const Voice = awebo.VoiceChannel;
const cli = @import("cli.zig");

const log = std.log.scoped(.client);

pub const Core = @import("client/Core.zig");
pub const StringPool = @import("client/StringPool.zig");

pub const dvui_app: dvui.App = .{
    .config = .{
        .options = .{
            .size = .{ .w = 1240.0, .h = 720.0 },
            .min_size = .{ .w = 250.0, .h = 350.0 },
            .title = "Awebo",
            .icon = @embedFile("appicon"),
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

fn init(window: *dvui.Window) !void {
    return global_app_singleton.init(window);
}

fn deinit() void {}

/// Contains references to Core, Gui and other resources needed to
/// start the application. Adding more state to this struct is most
/// likely a mistake. Gui state belongs to Gui or one of its views.
pub const App = struct {
    gui: Gui = .{},
    core: Core,
    core_future: Io.Future(void),
    command_queue_buffer: [1024]Core.Event = undefined,
    environ: *std.process.Environ.Map,
    window: *dvui.Window,

    fn init(app: *App, window: *dvui.Window) void {
        const io = dvui.io;
        const gpa = window.gpa;
        const environ = dvui.App.main_init.?.environ_map;

        app.* = .{
            .window = window,
            .environ = environ,
            .core = Core.init(
                gpa,
                io,
                environ,
                refresh,
                &app.command_queue_buffer,
            ) catch |err| {
                std.process.fatal("unable to init core: {t}", .{err});
            },
            .core_future = undefined,
        };

        app.core_future = io.concurrent(Core.run, .{&app.core}) catch |err| {
            cli.fatal("unable to start awebo client core: {t}", .{err});
        };
    }
};

fn frame() !dvui.App.Result {
    const app = &global_app_singleton;
    const core = &app.core;

    if (checkClosing(app)) return .close;
    if (!core.loaded.load(.unordered)) return initialLoadingFrame();

    var locked = app.core.lockState();
    defer locked.unlock();

    if (core.failure != .none) return .close;
    try app.gui.draw(core);
    return .ok;
}

fn checkClosing(app: *App) bool {
    const io = dvui.io;
    const win = dvui.currentWindow();
    const wd = win.data();
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, wd)) continue;
        if ((e.evt == .window and e.evt.window.action == .close) or (e.evt == .app and e.evt.app.action == .quit)) {
            e.handle(@src(), wd);
            log.debug("shutting down core from ui", .{});
            app.core_future.cancel(io);
            return true;
        }
    }

    return false;
}

fn refresh(core: *Core, src: std.builtin.SourceLocation, id: ?u64) void {
    const app: *App = @alignCast(@fieldParentPtr("core", core));
    dvui.refresh(app.window, src, if (id) |i| @enumFromInt(i) else null);
}

fn initialLoadingFrame() !dvui.App.Result {
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
    return .ok;
}

test {
    _ = Core;
}

fn oom() noreturn {
    std.process.fatal("oom", .{});
}
