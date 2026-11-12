const builtin = @import("builtin");
const std = @import("std");
const zon = @import("build.zig.zon");

const Context = enum { client, server };

pub fn build(b: *std.Build) void {
    const target_query = b.standardTargetOptionsQueryOnly(.{});
    const target = b.resolveTargetQuery(target_query);
    const optimize = b.standardOptimizeOption(.{});

    // const target_tui = if (builtin.os.tag == .linux and target_query.abi == null) blk: {
    //     var query = target_query;
    //     query.abi = .musl;
    //     break :blk b.resolveTargetQuery(query);
    // } else target;

    const incremental = b.option(
        bool,
        "incremental",
        "Use incremental compilation for the server and clients",
    ) orelse false;

    const dep_optimize = b.option(
        std.builtin.OptimizeMode,
        "dep-optimize",
        "optimization mode of most dependencies",
    ) orelse .fast;

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

    // const client_version = b.option(
    //     []const u8,
    //     "override-client-version",
    //     "Overrides the client version of awebo",
    // ) orelse zon.version;

    const client_local_cache = b.option(
        bool,
        "local-cache",
        "store client's .cache and .config dirs in cwd, useful for testing",
    ) orelse false;

    const client_dummy = b.option(
        bool,
        "dummy",
        "Use dummy OS interfaces for A/V in client",
    ) orelse false;

    const server, const server_test = setupServer(b, target, optimize, dep_optimize, slow, echo, server_version, incremental);
    b.installArtifact(server);

    const gui, const gui_test = setupGui(b, target, optimize, dep_optimize, client_local_cache, client_dummy, incremental);
    b.installArtifact(gui);

    _ = server_test;
    _ = gui_test;

    // const mac_os_bundle = b.step("macos-bundle", "create a mac os bundle");
    // setupMacOsBundle(b, mac_os_bundle, gui);

    // const tui, const tui_test = setupTui(b, target_tui, optimize, dep_optimize, client_version, client_local_cache, client_dummy);
    // b.installArtifact(tui);

    const server_step = b.step("server", "Launch the server executable");
    runArtifact(b, target, server_step, server);

    const gui_step = b.step("gui", "Launch the GUI client");
    runArtifact(b, target, gui_step, gui);

    // const tui_step = b.step("tui", "Launch the TUI client");
    // runArtifact(b, target, tui_step, tui);

    // const test_step = b.step("test", "run tests");
    // runArtifact(b, target, test_step, server_test);
    // runArtifact(b, target, test_step, gui_test);
    // runArtifact(b, target, test_step, tui_test);

    // const ci_step = b.step("ci", "build for all platforms and then run all tests");
    // setupCi(b, ci_step, dep_optimize);
    // ci_step.dependOn(test_step);

    // const check = b.step("check", "check everything");
    // check.dependOn(&server.step);
    // check.dependOn(&gui.step);
    // check.dependOn(&tui.step);
}

pub fn setupServer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep_optimize: std.builtin.OptimizeMode,
    slow: bool,
    echo: bool,
    version: []const u8,
    incremental: bool,
) struct { *std.Build.Step.Compile, *std.Build.Step.Compile } {
    const server = b.addExecutable(.{
        .name = "awebo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (incremental) server.incremental = true;

    const folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = dep_optimize,
        .sqlite3 = sqlite_flags_server,
    });

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const translate_c = b.dependency("translate_c", .{});
    const Translator = @import("translate_c").Translator;
    const t: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/server/c.h"),
        .target = target,
        .optimize = optimize,
    });
    t.addIncludePath(b.path("src"));

    const options = b.addOptions();
    options.addOption(Context, "context", .server);
    options.addOption(bool, "slow", slow);
    options.addOption(bool, "echo", echo);
    options.addOption([]const u8, "version", version);

    server.root_module.addOptions("options", options);
    server.root_module.addImport("folders", folders.module("known-folders"));
    server.root_module.addImport("zqlite", zqlite.module("zqlite"));
    server.root_module.addImport("zeit", zeit.module("zeit"));
    server.root_module.addImport("c", t.mod);

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
    dummy: bool,
    incremental: bool,
) struct { *std.Build.Step.Compile, *std.Build.Step.Compile } {
    const appicon = b.createModule(.{
        .root_source_file = b.path("src/client/assets/AppIcon.png"),
    });

    const gui = b.addExecutable(.{
        .name = "awebo-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_client_gui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (incremental) gui.incremental = true;

    const opus = b.dependency("opus", .{
        .target = target,
        .optimize = dep_optimize,
        .dred = true,
        .@"deep-plc" = true,
        .osce = true,
        .@"osce-bwe" = true,
        .@"float-approx" = true,
        .rtcd = !target.query.isNativeCpu(),
    });

    const opus_tools = b.dependency("opus_tools", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const rnnoise = b.dependency("rnnoise", .{
        .target = target,
        .optimize = dep_optimize,
        .rtcd = !target.query.isNativeCpu(),
    });

    const folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = dep_optimize,
        .sqlite3 = sqlite_flags_client,
    });

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const miniaudio = b.dependency("miniaudio", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const translate_c = b.dependency("translate_c", .{});
    const Translator = @import("translate_c").Translator;
    const t: Translator = .init(translate_c, .{
        .c_source_file = b.path("src/client/c.h"),
        .target = target,
        .optimize = optimize,
        .link_system_libs = switch (target.result.os.tag) {
            .linux => &.{
                // .{
                //     .name = "va",
                //     .options = .{
                //         .needed = true,
                //         .preferred_link_mode = .static,
                //     },
                // },
                // .{
                //     .name = "va-wayland",
                //     .options = .{
                //         .needed = true,
                //         .preferred_link_mode = .static,
                //     },
                // },
            },
            else => &.{},
            // .{
            //     .name = "avutil",
            //     .options = .{
            //         .needed = true,
            //         .preferred_link_mode = .static,
            //     },
            // },
            // .{
            //     .name = "avcodec",
            //     .options = .{
            //         .needed = true,
            //         .preferred_link_mode = .static,
            //     },
            // },
        },
    });
    t.addIncludePath(b.path("src"));
    t.linkLibrary(opus.artifact("opus"));
    t.linkLibrary(opus_tools.artifact("opus-tools"));
    // t.linkSystemLibrary("va");

    const options = b.addOptions();
    options.addOption(Context, "context", .client);
    options.addOption(bool, "local_cache", local_cache);
    options.addOption(bool, "dummy", dummy);
    gui.root_module.addOptions("options", options);
    gui.root_module.addImport("appicon", appicon);
    gui.root_module.addImport("folders", folders.module("known-folders"));
    gui.root_module.addImport("zeit", zeit.module("zeit"));
    gui.root_module.addImport("zqlite", zqlite.module("zqlite"));
    // gui.root_module.addImport("opus", opus.module("opus"));
    gui.root_module.addImport("rnnoise", rnnoise.module("rnnoise"));
    gui.root_module.addImport("miniaudio", miniaudio.module("miniaudio"));
    gui.root_module.addImport("c", t.mod);

    if (b.systemIntegrationOption("ffmpeg", .{ .default = true })) {
        gui.root_module.linkSystemLibrary("avutil", .{
            .needed = true,
        });
        gui.root_module.linkSystemLibrary("avcodec", .{
            .needed = true,
        });
        if (target.result.os.tag == .linux) {
            gui.root_module.linkSystemLibrary("swscale", .{
                .needed = true,
            });
        }
    } else {
        const ffmpeg = b.dependency("ffmpeg", .{
            .target = target,
            .optimize = dep_optimize,
        });
        t.addIncludePath(ffmpeg.path("."));
        gui.root_module.linkLibrary(ffmpeg.artifact("ffmpeg"));
    }

    switch (target.result.os.tag) {
        .macos => {
            const frameworks = b.dependency("xcode_frameworks", .{});
            t.addIncludePath(frameworks.path("include"));
            t.addFrameworkPath(frameworks.path("Frameworks"));

            const dvui = b.dependency("dvui", .{
                .target = target,
                .optimize = optimize,
                .backend = .sdl3,
                .system_include_path = frameworks.path("include"),
                .system_framework_path = frameworks.path("Frameworks"),
                .library_path = frameworks.path("lib"),
            });

            gui.root_module.addImport("dvui", dvui.module("dvui_sdl3"));
            gui.root_module.addFrameworkPath(frameworks.path("Frameworks"));
            gui.root_module.addSystemIncludePath(frameworks.path("include"));
            gui.root_module.addLibraryPath(frameworks.path("lib"));
            gui.root_module.linkFramework("AVFoundation", .{});
            gui.root_module.linkFramework("VideoToolbox", .{});
            gui.root_module.linkFramework("ScreenCaptureKit", .{});
            gui.root_module.linkFramework("CoreMedia", .{});
            gui.root_module.linkFramework("CoreAudio", .{});
            gui.root_module.linkFramework("Security", .{});
            gui.root_module.addCSourceFiles(.{
                .files = &.{
                    // "src/client/media/macos/audio.m",
                    // "src/client/media/macos/video.m",
                    // "src/client/media/macos/video-format.m",
                    "src/client/media/Screen/macos/screen-capture.m",
                    "src/client/media/Webcam/macos/webcam-capture.m",
                },
                .flags = &[_][]const u8{
                    "-pthread",
                    "-fobjc-arc",
                    "-Wno-undef",
                    "-Wno-deprecated-declarations",
                    "-Wno-availability",
                    "-Wno-unguarded-availability-new",
                    if (optimize == .debug) "-DDEBUG" else "-DNDEBUG",
                },
            });
        },
        .windows => {
            const dvui = b.dependency("dvui", .{
                .target = target,
                .optimize = optimize,
                .backend = .sdl3,
            });
            gui.root_module.addImport("dvui", dvui.module("dvui_sdl3"));
            if (b.lazyDependency("zigwin32", .{})) |win32_dep| {
                gui.root_module.addImport("win32", win32_dep.module("win32"));
            }
        },
        .linux => blk: {
            const dvui = b.dependency("dvui", .{
                .target = target,
                .optimize = optimize,
                .backend = .sdl3,
            });
            gui.root_module.addImport("dvui", dvui.module("dvui_sdl3"));

            const wayland = b.lazyImport(@This(), "wayland") orelse break :blk;
            const Scanner = wayland.Scanner;

            const scanner = Scanner.create(b, .{
                .wayland_xml = b.path("src/client/media/Screen/Wayland/wayland.xml"),
                .wayland_protocols = b.path("src/client/media/Screen/Wayland/protocols"),
            });
            // I'm currently being naughty and using system files for the Wayland protocol definitions.
            // To avoid this, you should be able to just vendor the required XML files.
            scanner.addSystemProtocol("staging/ext-image-capture-source/ext-image-capture-source-v1.xml");
            scanner.addSystemProtocol("staging/ext-image-copy-capture/ext-image-copy-capture-v1.xml");
            scanner.addSystemProtocol("stable/linux-dmabuf/linux-dmabuf-v1.xml");
            scanner.generate("wl_output", 4);
            scanner.generate("wl_shm", 2);
            scanner.generate("ext_output_image_capture_source_manager_v1", 1);
            scanner.generate("ext_image_copy_capture_manager_v1", 1);
            scanner.generate("zwp_linux_dmabuf_v1", 1);
            const wayland_mod = b.createModule(.{ .root_source_file = scanner.result });
            gui.root_module.addImport("wayland", wayland_mod);
            gui.root_module.link_libc = true;
            gui.root_module.linkSystemLibrary("wayland-client", .{});
            // gui.root_module.linkSystemLibrary("va", .{});
            // gui.root_module.linkSystemLibrary("va-wayland", .{});
        },
        else => {},
    }

    const gui_test = b.addTest(.{
        .name = "gui-test",
        .root_module = gui.root_module,
    });

    return .{ gui, gui_test };
}

pub fn setupTui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep_optimize: std.builtin.OptimizeMode,
    version: []const u8,
    local_cache: bool,
    dummy: bool,
    incremental: bool,
) struct { *std.Build.Step.Compile, *std.Build.Step.Compile } {
    const tui = b.addExecutable(.{
        .name = "awebo-tui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_client_tui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    if (incremental) tui.incremental = true;

    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const opus = b.dependency("opus", .{
        .target = target,
        .optimize = dep_optimize,
        .dred = true,
        .@"deep-plc" = true,
        .osce = true,
        .@"osce-bwe" = true,
        .@"float-approx" = true,
        .rtcd = !target.query.isNativeCpu(),
    });

    const miniaudio = b.dependency("miniaudio", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const rnnoise = b.dependency("rnnoise", .{
        .target = target,
        .optimize = dep_optimize,
        .rtcd = !target.query.isNativeCpu(),
    });

    const folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = dep_optimize,
        .sqlite3 = sqlite_flags_client,
    });

    const zeit = b.dependency("zeit", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const ffmpeg = b.dependency("ffmpeg", .{
        .target = target,
        .optimize = dep_optimize,
    });

    const options = b.addOptions();
    options.addOption(Context, "context", .client);
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "local_cache", local_cache);
    options.addOption(bool, "dummy", dummy);
    tui.root_module.addOptions("options", options);
    tui.root_module.addImport("vaxis", vaxis.module("vaxis"));
    tui.root_module.addImport("folders", folders.module("known-folders"));
    tui.root_module.addImport("zqlite", zqlite.module("zqlite"));
    tui.root_module.addImport("zeit", zeit.module("zeit"));
    tui.root_module.addImport("opus", opus.module("opus"));
    tui.root_module.addImport("rnnoise", rnnoise.module("rnnoise"));
    tui.root_module.addImport("miniaudio", miniaudio.module("miniaudio"));

    tui.root_module.linkLibrary(ffmpeg.artifact("ffmpeg"));
    // tui.root_module.linkSystemLibrary("avutil", .{ .needed = true });
    // tui.root_module.linkSystemLibrary("avcodec", .{ .needed = true });

    switch (target.result.os.tag) {
        .macos => {
            const xcode_frameworks = b.dependency("xcode_frameworks", .{});
            tui.root_module.addFrameworkPath(xcode_frameworks.path("Frameworks"));
            tui.root_module.addSystemIncludePath(xcode_frameworks.path("include"));
            tui.root_module.addLibraryPath(xcode_frameworks.path("lib"));
            tui.root_module.linkFramework("AVFoundation", .{});
            tui.root_module.linkFramework("AudioToolbox", .{});
            tui.root_module.linkFramework("VideoToolbox", .{});
            tui.root_module.linkFramework("CoreAudio", .{});
            tui.root_module.linkFramework("CoreMedia", .{});
            tui.root_module.linkFramework("CoreVideo", .{});
            tui.root_module.linkFramework("Foundation", .{});
            tui.root_module.linkFramework("ScreenCaptureKit", .{});
            tui.root_module.linkFramework("Security", .{});
            tui.root_module.addCSourceFiles(.{
                .files = &.{
                    "src/client/media/macos/audio.m",
                    // "src/client/media/macos/video.m",
                    // "src/client/media/macos/video-format.m",
                    "src/client/media/macos/screen-capture.m",
                    "src/client/media/macos/webcam-capture.m",
                },
                .flags = &[_][]const u8{
                    "-pthread",
                    "-fobjc-arc",
                    "-Wno-undef",
                    "-Wno-deprecated-declarations",
                    "-Wno-availability",
                    "-Wno-unguarded-availability-new",
                    if (optimize == .debug) "-DDEBUG" else "-DNODEBUG",
                },
            });
        },
        .windows => {
            if (b.lazyDependency("zigwin32", .{})) |win32_dep| {
                tui.root_module.addImport("win32", win32_dep.module("win32"));
            }
        },
        .linux => {},
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
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        // .{ .cpu_arch = .aarch64, .os_tag = .linux },
        // .{ .cpu_arch = .x86_64, .os_tag = .linux },
        // .{ .cpu_arch = .x86_64, .os_tag = .windows },
        // .{ .cpu_arch = .aarch64, .os_tag = .windows },
    };

    for (targets) |t| {
        const target = b.resolveTargetQuery(t);
        const optimize = .debug;

        const server, const server_test = setupServer(b, target, optimize, dep_optimize, false, false, zon.version, false);
        const gui, const gui_test = setupGui(b, target, optimize, dep_optimize, false, false, false);
        // const tui, const tui_test = setupTui(b, target, optimize, dep_optimize, zon.version, false, false);
        const dummy_gui, const dummy_gui_test = setupGui(b, target, optimize, dep_optimize, false, true, false);
        // const dummy_tui, const dummy_tui_test = setupTui(b, target, optimize, dep_optimize, zon.version, false, true);

        step.dependOn(&b.addInstallArtifact(server, .{}).step);
        step.dependOn(&b.addInstallArtifact(gui, .{}).step);
        // step.dependOn(&b.addInstallArtifact(tui, .{}).step);
        step.dependOn(&b.addInstallArtifact(dummy_gui, .{ .dest_sub_path = "dummy" }).step);
        // step.dependOn(&b.addInstallArtifact(dummy_tui, .{ .dest_sub_path = "dummy" }).step);

        step.dependOn(&server_test.step);
        step.dependOn(&gui_test.step);
        // step.dependOn(&tui_test.step);
        step.dependOn(&dummy_gui_test.step);
        // step.dependOn(&dummy_tui_test.step);
    }
}

fn runArtifact(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    step: *std.Build.Step,
    artifact: *std.Build.Step.Compile,
) void {
    step.dependOn(&b.addInstallArtifact(artifact, .{}).step);
    if (!target.query.isNative()) return;

    const run_cmd = b.addRunArtifact(artifact);
    run_cmd.addPassthruArgs();

    step.dependOn(&run_cmd.step);
}
pub fn setupMacOsBundle(b: *std.Build, bundle_step: *std.Build.Step, exe: *std.Build.Step.Compile) void {
    bundle_step.dependOn(&exe.step);
    const png_path = b.path("src/client/assets/AppIcon.png");
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
    const install_plist = b.addInstallFile(b.path("src/client/assets/macOSBundle/Info.plist"), b.fmt("{s}.app/Contents/Info.plist", .{exe.name}));
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
    codesign.addFileArg(b.path("src/client/assets/macOSBundle/entitlements.plist"));
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

const sqlite_flags_client: []const []const u8 = &.{
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
};

const sqlite_flags_server: []const []const u8 = sqlite_flags_client ++ @as([]const []const u8, &.{
    "-DSQLITE_ENABLE_FTS5=1",
});
