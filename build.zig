const std = @import("std");
const zon = @import("build.zig.zon");

const Context = enum { client, server };

const Audio = enum {
    portaudio,
    wasapi,
    dummy,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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

    const server = setupServer(b, target, optimize, slow, echo, server_version);
    b.installArtifact(server);

    const gui = setupGui(b, target, optimize);
    b.installArtifact(gui);

    const tui = setupTui(b, target, optimize, client_version);
    b.installArtifact(tui);

    const server_step = b.step("server", "Launch the server executable");
    runArtifact(b, server_step, server);

    const gui_step = b.step("gui", "Launch the GUI client");
    runArtifact(b, gui_step, gui);

    const tui_step = b.step("tui", "Launch the TUI client");
    runArtifact(b, tui_step, tui);

    const test_step = b.step("test", "run tests");
    // setupTest(b, target, optimize, check, zqlite, known_folders);

    const ci_step = b.step("ci", "build for all platforms and then run all tests");
    setupCi(b, ci_step);
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
    slow: bool,
    echo: bool,
    version: []const u8,
) *std.Build.Step.Compile {
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
        .optimize = optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(Context, "context", .server);
    options.addOption(bool, "slow", slow);
    options.addOption(bool, "echo", echo);
    options.addOption([]const u8, "version", version);

    server.root_module.addOptions("options", options);
    server.root_module.addImport("folders", folders.module("known-folders"));
    addSqlite(server, zqlite, .server);

    return server;
}

pub fn setupGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const dvui = b.dependency("dvui", .{
        .target = target,
        .optimize = optimize,
        .backend = .sdl3,
    });

    const client = b.addExecutable(.{
        .name = "awebo-gui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_client_gui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const opus = b.dependency("opus", .{
        .target = target,
        .optimize = optimize,
    });

    const opus_tools = b.dependency("opus_tools", .{
        .target = target,
        .optimize = optimize,
    });

    const folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(Context, "context", .client);
    client.root_module.addOptions("options", options);
    client.root_module.addImport("dvui", dvui.module("dvui_sdl3"));
    client.root_module.addImport("folders", folders.module("known-folders"));
    client.root_module.linkLibrary(opus.artifact("opus"));
    client.root_module.linkLibrary(opus_tools.artifact("opus-tools"));
    addSqlite(client, zqlite, .client);

    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |win32_dep| {
            client.root_module.addImport("win32", win32_dep.module("win32"));
        }
    }

    return client;
}

pub fn setupTui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    version: []const u8,
) *std.Build.Step.Compile {
    const vaxis = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });

    const client = b.addExecutable(.{
        .name = "awebo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_client_tui.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const opus = b.dependency("opus", .{
        .target = target,
        .optimize = optimize,
    });

    const opus_tools = b.dependency("opus_tools", .{
        .target = target,
        .optimize = optimize,
    });

    const folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    const options = b.addOptions();
    options.addOption(Context, "context", .client);
    options.addOption([]const u8, "version", version);
    client.root_module.addOptions("options", options);
    client.root_module.addImport("vaxis", vaxis.module("vaxis"));
    client.root_module.addImport("folders", folders.module("known-folders"));
    client.root_module.linkLibrary(opus.artifact("opus"));
    client.root_module.linkLibrary(opus_tools.artifact("opus-tools"));
    addSqlite(client, zqlite, .client);
    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |win32_dep| {
            client.root_module.addImport("win32", win32_dep.module("win32"));
        }
    }

    return client;
}

pub fn setupCi(b: *std.Build, step: *std.Build.Step) void {
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

        const server = setupServer(b, target, optimize, false, false, zon.version);
        const gui = setupGui(b, target, optimize);
        const tui = setupTui(b, target, optimize, zon.version);

        step.dependOn(&server.step);
        step.dependOn(&gui.step);
        step.dependOn(&tui.step);
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
