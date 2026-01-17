const builtin = @import("builtin");
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const folders = @import("folders");
const dvui = @import("dvui");
const awebo = @import("awebo.zig");
const gui = @import("client/gui.zig");
pub const core = @import("client/core.zig");
const ui = @import("client/core/ui.zig");
const global = @import("client/global.zig");
pub const PoolString = @import("client/PoolString.zig");
const Host = awebo.Host;
const Voice = awebo.VoiceChannel;

const log = std.log.scoped(.client);

const window_icon_png = @embedFile("client/data/zig-favicon.png");
const vsync = true;

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
            .gpa = core.gpa,
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

pub var state: struct {
    active_screen: union(enum) {
        loading,
        main,
        user_settings,
        server_settings,
    } = .main,
} = .{};

var window: *dvui.Window = undefined;
fn refresh(src: std.builtin.SourceLocation, id: ?u64) void {
    dvui.refresh(window, src, if (id) |i| @enumFromInt(i) else null);
}

var core_future: Io.Future(void) = undefined;
fn init(win: *dvui.Window) !void {
    core.init(refresh);
    window = win;
    global.main_thread_id = std.Thread.getCurrentId();

    core_future = win.io.concurrent(core.run, .{}) catch |err| {
        std.process.fatal("unable to start awebo client core: {t}", .{err});
    };
}

fn frame() !dvui.App.Result {
    if (checkClosing()) return .close;

    var locked = core.lockState();
    defer locked.unlock();
    const core_state = locked.state;

    if (core_state.failure != null) return .close;
    if (!core_state.loaded) return loadingFrame();
    try guiFrame(core_state);
    return .ok;
}

fn checkClosing() bool {
    const win = dvui.currentWindow();
    const wd = win.data();
    for (dvui.events()) |*e| {
        if (!dvui.eventMatchSimple(e, wd)) continue;
        if ((e.evt == .window and e.evt.window.action == .close) or (e.evt == .app and e.evt.app.action == .quit)) {
            e.handle(@src(), wd);
            log.debug("shutting down core from ui", .{});
            core_future.cancel(win.io);
            return true;
        }
    }

    return false;
}

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

fn guiFrame(core_state: *core.State) !void {
    var main_box = dvui.box(
        @src(),
        .{ .dir = .horizontal },
        .{
            .expand = .both,
            .background = true,
        },
    );
    defer main_box.deinit();

    if (core_state.hosts.last_id == 0) {
        try gui.empty.draw(core_state);
        return;
    }

    switch (state.active_screen) {
        .loading => gui.loading.draw(),
        .main => try gui.main.draw(core_state),
        .user_settings => gui.user.draw(core_state),
        else => @panic("TODO"),
    }
}

fn deinit() void {}
