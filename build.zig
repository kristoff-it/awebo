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

    const check = b.step("check", "check everything");

    const known_folders = b.dependency("known_folders", .{
        .target = target,
        .optimize = optimize,
    });

    const zqlite = b.dependency("zqlite", .{
        .target = target,
        .optimize = optimize,
    });

    setupServer(b, target, optimize, check, zqlite, known_folders);
    setupClientGui(b, target, optimize, check, known_folders);
    setupClientTui(b, target, optimize, check, known_folders);

    // Here for CI, add dependencies on tests later
    _ = b.step("test", "");
}

pub fn setupServer(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    check: *std.Build.Step,
    zqlite: *std.Build.Dependency,
    folders: *std.Build.Dependency,
) void {
    const server = b.addExecutable(.{
        .name = "awebo-server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main_server.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const options = b.addOptions();
    options.addOption(Context, "context", .server);
    options.addOption(bool, "slow", b.option(
        bool,
        "slow",
        "(server option) add 1s delay to most operations",
    ) orelse false);
    options.addOption(bool, "echo", b.option(
        bool,
        "echo",
        "(server option) echo a client's audio back to them",
    ) orelse false);
    options.addOption([]const u8, "version", b.option(
        []const u8,
        "override-version",
        "Overrides the version of awebo",
    ) orelse zon.version);

    server.root_module.addOptions("options", options);
    server.root_module.addImport("folders", folders.module("known-folders"));
    server.root_module.addImport("zqlite", zqlite.module("zqlite"));

    server.root_module.addCSourceFile(.{
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
            "-DSQLITE_ENABLE_FTS5=1",
        },
    });
    server.root_module.link_libc = true;

    const install = b.addInstallArtifact(server, .{});
    b.getInstallStep().dependOn(&install.step);

    const serve_cmd = b.addRunArtifact(server);

    serve_cmd.step.dependOn(&install.step);

    if (b.args) |args| {
        serve_cmd.addArgs(args);
    }

    const serve_step = b.step("server", "Launch the server executable");
    serve_step.dependOn(&serve_cmd.step);

    check.dependOn(&server.step);
}

pub fn setupClientGui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    check: *std.Build.Step,
    folders: *std.Build.Dependency,
) void {
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

    const options = b.addOptions();
    options.addOption(Context, "context", .client);
    client.root_module.addOptions("options", options);
    client.root_module.addImport("dvui", dvui.module("dvui_sdl3"));
    client.root_module.addImport("folders", folders.module("known-folders"));
    client.root_module.linkLibrary(opus.artifact("opus"));
    client.root_module.linkLibrary(opus_tools.artifact("opus-tools"));
    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |win32_dep| {
            client.root_module.addImport("win32", win32_dep.module("win32"));
        }
    }

    const install = b.addInstallArtifact(client, .{});
    b.getInstallStep().dependOn(&install.step);

    const run_cmd = b.addRunArtifact(client);
    run_cmd.step.dependOn(&install.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("gui", "Launch the GUI client");
    run_step.dependOn(&run_cmd.step);

    check.dependOn(&client.step);
}

pub fn setupClientTui(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    check: *std.Build.Step,
    folders: *std.Build.Dependency,
) void {
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

    const options = b.addOptions();
    options.addOption(Context, "context", .client);
    options.addOption([]const u8, "version", b.option(
        []const u8,
        "override-client-version",
        "Overrides the client version of awebo",
    ) orelse zon.version);
    client.root_module.addOptions("options", options);
    client.root_module.addImport("vaxis", vaxis.module("vaxis"));
    client.root_module.addImport("folders", folders.module("known-folders"));
    client.root_module.linkLibrary(opus.artifact("opus"));
    client.root_module.linkLibrary(opus_tools.artifact("opus-tools"));
    if (target.result.os.tag == .windows) {
        if (b.lazyDependency("zigwin32", .{})) |win32_dep| {
            client.root_module.addImport("win32", win32_dep.module("win32"));
        }
    }

    const install = b.addInstallArtifact(client, .{});
    b.getInstallStep().dependOn(&install.step);

    const run_cmd = b.addRunArtifact(client);
    run_cmd.step.dependOn(&install.step);

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("tui", "Launch the TUI client");
    run_step.dependOn(&run_cmd.step);

    check.dependOn(&client.step);
}
