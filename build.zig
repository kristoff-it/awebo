const builtin = @import("builtin");
const std = @import("std");
const zon = @import("build.zig.zon");

const Context = enum { client, server };

pub fn build(b: *std.Build) void {
    const target_query = b.standardTargetOptionsQueryOnly(.{});
    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    const target_tui = if (builtin.os.tag == .linux and target_query.abi == null) blk: {
        var query = target_query;
        query.abi = .musl;
        break :blk b.resolveTargetQuery(query);
    } else target;

    const dep_optimize = b.option(
        std.builtin.OptimizeMode,
        "dep-optimize",
        "optimization mode of most dependencies",
    ) orelse .ReleaseFast;

    const slow = b.option(
        bool,
        "slow",
        "(server option) add 1s delay to most operations",
    ) orelse false;

    const echo = b.option(
        bool,
        "echo",
        "(server option) echo a client's audio back to them",
    ) orelse false;

    const server_version = b.option(
        []const u8,
        "override-version",
        "Overrides the version of awebo",
    ) orelse zon.version;

    const client_version = b.option(
        []const u8,
        "override-client-version",
        "Overrides the client version of awebo",
    ) orelse zon.version;

    const client_local_cache = b.option(
        bool,
        "local-cache",
        "store client's .cache and .config dirs in cwd, useful for testing",
    ) orelse false;

    const server, const server_test = setupServer(b, target, optimize, dep_optimize, slow, echo, server_version);
    b.installArtifact(server);

    const gui, const gui_test = setupGui(b, target, optimize, dep_optimize, client_local_cache);
    b.installArtifact(gui);
    const mac_os_bundle = b.step("mac_os_bundle", "create a mac os bundle");
    setupMacOsBundle(b, mac_os_bundle, gui);

    const tui, const tui_test = setupTui(b, target_tui, optimize, dep_optimize, client_version, client_local_cache);
    b.installArtifact(tui);

    const server_step = b.step("server", "Launch the server executable");
    runArtifact(b, server_step, server);

    const gui_step = b.step("gui", "Launch the GUI client");
    runArtifact(b, gui_step, gui);

    const tui_step = b.step("tui", "Launch the TUI client");
    runArtifact(b, tui_step, tui);

    const test_step = b.step("test", "run tests");
    runArtifact(b, test_step, server_test);
    runArtifact(b, test_step, gui_test);
    runArtifact(b, test_step, tui_test);

    const ci_step = b.step("ci", "build for all platforms and then run all tests");
    setupCi(b, ci_step, dep_optimize);
    ci_step.dependOn(test_step);

    const check = b.step("check", "check everything");
    check.dependOn(&server.step);
    check.dependOn(&gui.step);
    check.dependOn(&tui.step);
}

pub fn setupServer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep_optimize: std.builtin.OptimizeMode,
    slow: bool,
    echo: bool,
    version: []const u8,
) struct { *std.Build.Step.Compile, *std.Build.Step.Compile } {
    const server = b.addExecutable(.{
        .name = "awebo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const options = b.addOptions();
    options.addOption(Context, "context", .server);
    options.addOption(bool, "slow", slow);
    options.addOption(bool, "echo", echo);
    options.addOption([]const u8, "version", version);

    server.root_module.addOptions("options", options);
    server.root_module.addImport("folders", folders.module("known-folders"));
    server.root_module.addImport("zeit", zeit.module("zeit"));
    addSqlite(server, zqlite, .server);

    const server_test = b.addTest(.{
        .name = "server-test",
        .root_module = server.root_module,
    });

    return .{ server, server_test };
}

pub fn setupGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep_optimize: std.builtin.OptimizeMode,
    local_cache: bool,
) struct { *std.Build.Step.Compile, *std.Build.Step.Compile } {
    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const gui = b.addExecutable(.{
        .name = "awebo-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_client_gui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const opus = b.dependency("opus", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const opus_tools = b.dependency("opus_tools", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const options = b.addOptions();
    options.addOption(Context, "context", .client);
    options.addOption(bool, "local_cache", local_cache);
    gui.root_module.addOptions("options", options);
    gui.root_module.addImport("dvui", dvui.module("dvui_sdl3"));
    gui.root_module.addImport("folders", folders.module("known-folders"));
    gui.root_module.addImport("zeit", zeit.module("zeit"));
    gui.root_module.linkLibrary(opus.artifact("opus"));
    gui.root_module.linkLibrary(opus_tools.artifact("opus-tools"));
    addSqlite(gui, zqlite, .client);

    switch (target.result.os.tag) {
        .windows => {
            if (b.lazyDependency("zigwin32", .{})) |win32_dep| {
                gui.root_module.addImport("win32", win32_dep.module("win32"));
            }
        },
        .linux => {
            if (b.lazyDependency("pulseaudio", .{
                .target = target,
                .optimize = dep_optimize,
            })) |dep| {
                gui.root_module.addImport("pulseaudio", dep.module("pulseaudio"));
            }
        },
        else => {},
    }

    const gui_test = b.addTest(.{
        .name = "gui-test",
        .root_module = gui.root_module,
    });

    return .{ gui, gui_test };
}

pub fn setupMacOsBundle(b: *std.Build, bundle_step: *std.Build.Step, exe: *std.Build.Step.Compile) void {
    bundle_step.dependOn(&exe.step);
    const png_path = b.path("assets/AppIcon.png");
    const icon_set = b.addWriteFiles();
    const tmp_dir = b.addWriteFiles();
    for ([_]u32{ 16, 32, 128, 256, 512 }) |s| {
        const sips_1x_out = b.fmt("icon_{d}x{d}.png", .{ s, s });
        const sips_1x_path = try sipsCommand(b, tmp_dir, png_path, sips_1x_out, s, s);
        _ = icon_set.addCopyFile(sips_1x_path, b.pathJoin(&[_][]const u8{ "AppIcon.iconset", sips_1x_out }));
        const sips_2x_out = b.fmt("icon_{d}x{d}@2x.png", .{ s, s });
        const sips_2x_path = try sipsCommand(b, tmp_dir, png_path, sips_2x_out, s * 2, s * 2);
        _ = icon_set.addCopyFile(sips_2x_path, b.pathJoin(&[_][]const u8{ "AppIcon.iconset", sips_2x_out }));
    }
    const iconutil = b.addSystemCommand(&[_][]const u8{
        "iconutil", "-c", "icns",
    });
    iconutil.setCwd(icon_set.getDirectory());
    iconutil.addArg("-o");
    const icns_path = iconutil.addOutputFileArg("AppIcon.icns");
    iconutil.addArg("AppIcon.iconset");
    const app_name = "Awebo";
    const resource_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}.app/Contents/Resources", .{app_name}) };
    const install_icns = b.addInstallFileWithDir(icns_path, resource_dir, "AppIcon.icns");
    bundle_step.dependOn(&install_icns.step);

    const bundle_dir: std.Build.InstallDir = .{ .custom = b.fmt("{s}.app/Contents/MacOS", .{app_name}) };
    const install_exe_in_bundle = b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = bundle_dir },
        .dest_sub_path = app_name,
    });
    bundle_step.dependOn(&install_exe_in_bundle.step);
    const install_plist = b.addInstallFile(b.path("assets/macOSBundle/Info.plist"), b.fmt("{s}.app/Contents/Info.plist", .{exe.name}));
    bundle_step.dependOn(&install_plist.step);
    const codesign = b.addSystemCommand(&.{
        "codesign",
        "-s",
        "-", // Ad-hoc signing
        "-f",
        "--options",
        "runtime",
        "--entitlements",
    });
    codesign.addFileArg(b.path("assets/macOSBundle/entitlements.plist"));
    codesign.addArg(b.getInstallPath(bundle_dir, app_name));
    codesign.step.dependOn(&install_exe_in_bundle.step);
    bundle_step.dependOn(&codesign.step);
}

fn sipsCommand(
    b: *std.Build,
    wf: *std.Build.Step.WriteFile,
    src_png: std.Build.LazyPath,
    out_path: []const u8,
    w: u32,
    h: u32,
) !std.Build.LazyPath {
    const run = b.addSystemCommand(&[_][]const u8{
        "sips",
        "-z",
    });
    run.addArgs(&[_][]const u8{ b.fmt("{d}", .{h}), b.fmt("{d}", .{w}) });
    run.addFileArg(src_png);
    run.addArg("--out");
    run.setCwd(wf.getDirectory());
    return run.addOutputFileArg(out_path);
}

pub fn setupTui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep_optimize: std.builtin.OptimizeMode,
    version: []const u8,
    local_cache: bool,
) struct { *std.Build.Step.Compile, *std.Build.Step.Compile } {
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const tui = b.addExecutable(.{
        .name = "awebo-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_client_tui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const opus = b.dependency("opus", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const opus_tools = b.dependency("opus_tools", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const options = b.addOptions();
    options.addOption(Context, "context", .client);
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "local_cache", local_cache);
    tui.root_module.addOptions("options", options);
    tui.root_module.addImport("vaxis", vaxis.module("vaxis"));
    tui.root_module.addImport("folders", folders.module("known-folders"));
    tui.root_module.addImport("zeit", zeit.module("zeit"));
    tui.root_module.linkLibrary(opus.artifact("opus"));
    tui.root_module.linkLibrary(opus_tools.artifact("opus-tools"));
    addSqlite(tui, zqlite, .client);
    switch (target.result.os.tag) {
        .windows => {
            if (b.lazyDependency("zigwin32", .{})) |win32_dep| {
                tui.root_module.addImport("win32", win32_dep.module("win32"));
            }
        },
        .linux => {
            if (b.lazyDependency("pulseaudio", .{
                .target = target,
                .optimize = dep_optimize,
            })) |dep| {
                tui.root_module.addImport("pulseaudio", dep.module("pulseaudio"));
            }
        },
        else => {},
    }

    const tui_test = b.addTest(.{
        .name = "tui-test",
        .root_module = tui.root_module,
    });

    return .{ tui, tui_test };
}

pub fn setupCi(b: *std.Build, step: *std.Build.Step, dep_optimize: std.builtin.OptimizeMode) void {
    const targets: []const std.Target.Query = &.{
        // .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .linux },
        .{ .cpu_arch = .x86_64, .os_tag = .windows },
        // .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        const optimize = .Debug;

        const server, const server_test = setupServer(b, target, optimize, dep_optimize, false, false, zon.version);
        const gui, const gui_test = setupGui(b, target, optimize, dep_optimize, false);
        const tui, const tui_test = setupTui(b, target, optimize, dep_optimize, zon.version, false);

        step.dependOn(&server.step);
        step.dependOn(&server_test.step);

        step.dependOn(&gui.step);
        step.dependOn(&gui_test.step);

        step.dependOn(&tui.step);
        step.dependOn(&tui_test.step);
    }
}

fn addSqlite(
    exe: *std.Build.Step.Compile,
    zqlite: *std.Build.Dependency,
    comptime context: enum { server, client },
) void {
    exe.root_module.addImport("zqlite", zqlite.module("zqlite"));
    exe.root_module.addCSourceFile(.{
        .file = zqlite.path("lib/sqlite3.c"),
        .flags = &[_][]const u8{
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_USE_ALLOCA=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_ENABLE_API_ARMOR=1",
            "-DSQLITE_ENABLE_UNLOCK_NOTIFY",
            "-DSQLITE_DEFAULT_FILE_PERMISSIONS=0600",
            "-DSQLITE_OMIT_DECLTYPE=1",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_OMIT_PROGRESS_CALLBACK=1",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_OMIT_TRACE=1",
            "-DSQLITE_OMIT_UTF16=1",
            "-DHAVE_USLEEP=0",
        } ++ if (context == .server) .{
            "-DSQLITE_ENABLE_FTS5=1",
        } else .{},
    });
    exe.root_module.link_libc = true;
}

fn runArtifact(b: *std.Build, step: *std.Build.Step, artifact: *std.Build.Step.Compile) void {
    const run_cmd = b.addRunArtifact(artifact);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    step.dependOn(&run_cmd.step);
}
