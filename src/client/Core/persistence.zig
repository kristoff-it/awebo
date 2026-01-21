const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const folders = @import("folders");
const awebo = @import("../../awebo.zig");
const Core = @import("../Core.zig");

const log = std.log.scoped(.persistence);

var cfg_dir: ?std.Io.Dir = null;
var cache_dir: ?std.Io.Dir = null;

pub fn load(core: *Core) !void {
    log.debug("begin loading state from disk", .{});
    defer log.debug("done loading state from disk", .{});

    loadImpl(core) catch |err| {
        log.debug("encountered a fatal error when loading data from disk: {t}", .{err});
        core.failure = "failed to load data from disk";
        return err;
    };
    core.loaded = true;
}

pub fn loadImpl(core: *Core) error{OutOfMemory}!void {
    const io = core.io;
    const gpa = core.gpa;

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();
    const cfg_path = try std.fs.path.join(allocator, &.{
        folders.getPath(io, allocator, core.environ.*, .local_configuration) catch @panic("oom") orelse blk: {
            log.err("known-folders failed to find the local config dir, defaulting to '.config/'", .{});
            break :blk ".config/";
        },
        "awebo",
    });

    log.debug("config path: '{s}'", .{cfg_path});

    const dir = std.Io.Dir.cwd().createDirPathOpen(io, cfg_path, .{
        .open_options = .{ .iterate = true },
    }) catch |err| {
        log.err("could not open the system's local configuration dir, reverting to using defaults: {s}", .{
            @errorName(err),
        });

        // dvui.toast(@src(), .{
        //     .message =
        //     \\Failed to open the local config directory.
        //     \\Reverting to default settings.
        //     ,
        //     .window = &client.window,
        // }) catch {
        //     log.err("failed to show dvui toast", .{});
        // };

        return;
    };
    cfg_dir = dir;

    var dir_it = dir.iterateAssumeFirstIteration();
    while (dir_it.next(io) catch @panic("unexpected")) |entry| {
        switch (entry.kind) {
            else => continue,
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".awebo")) continue;
                const value = dir.readFileAlloc(io, entry.name, gpa, .limited(1024 * 1024)) catch |err| {
                    log.debug("error accessing cfg file '{s}', ignoring: {s}", .{
                        entry.name, @errorName(err),
                    });
                    continue;
                };

                const key = try gpa.dupe(u8, entry.name[0 .. entry.name.len - ".awebo".len]);
                try core.cfg.putNoClobber(gpa, key, value);
            },
        }
    }

    const cache_path = try std.fs.path.join(allocator, &.{
        folders.getPath(io, allocator, core.environ.*, .cache) catch @panic("oom") orelse blk: {
            log.err("known-folders failed to find the local cache dir, defaulting to '.cache/'", .{});
            break :blk ".cache/";
        },
        "awebo",
    });

    log.debug("cache path: '{s}'", .{cache_path});

    const cache = std.Io.Dir.cwd().createDirPathOpen(io, cache_path, .{
        .open_options = .{ .iterate = true },
    }) catch |err| {
        log.err("could not open the system's cache dir: {s}", .{
            @errorName(err),
        });

        // dvui.toast(@src(), .{
        //     .message =
        //     \\Failed to open the local cache directory.
        //     ,
        //     .window = &client.window,
        // }) catch {
        //     log.err("failed to show dvui toast", .{});
        // };

        return;
    };
    cache_dir = cache;

    const kv = core.cfg.fetchRemove("hosts") orelse return;
    var it = std.mem.tokenizeScalar(u8, kv.value, '\n');
    var idx: u32 = 1;
    blk: while (it.next()) |ident| : (idx += 1) {
        const username = it.next() orelse {
            log.debug("missing username field from host file, abandoning", .{});
            break :blk;
        };
        const password = it.next() orelse {
            log.debug("missing password field from host file, abandoning", .{});
            break :blk;
        };
        const h = core.hosts.add(core, ident, username, password) catch |err| switch (err) {
            // We never write duplicate data into the file, but
            // in case a user did this to themselves by editing the file
            // manually, we can be graceful about it, I guess.
            error.DuplicateHost => continue,
            error.OutOfMemory => return error.OutOfMemory,
        };

        h.* = .{
            .client = .{
                .identity = ident,
                .host_id = idx,
                .username = username,
            },
        };
    }

    for (core.hosts.items.values()) |*h| {
        const data = cache.readFileAlloc(io, h.client.identity, gpa, .limited(10 * 1024 * 1024)) catch |err| {
            log.info("could not load the cache for host '{s}': {s}", .{
                h.client.identity,
                @errorName(err),
            });
            continue;
        };

        const identity = h.client.identity;
        const id = h.client.host_id;

        var fbr = Io.Reader.fixed(data);
        var hs = awebo.protocol.server.HostSync.deserializeAlloc(gpa, &fbr) catch |err| {
            log.info("could not parse the cache for '{s}': {s}", .{
                h.client.identity,
                @errorName(err),
            });
            continue;
        };
        hs.host.client.identity = identity;
        hs.host.client.host_id = id;
        h.* = hs.host;
    }

    //TODO: load messages separately
}

pub fn updateHosts(io: Io, hosts: []const awebo.Host) !void {
    log.debug("updating hosts...", .{});
    const dir = cfg_dir orelse {
        log.debug("no cfg path, giving up", .{});
        return;
    };

    var af = dir.createFileAtomic(io, "hosts.awebo", .{ .replace = true }) catch |err| {
        log.info("failed to create hosts.awebo: {s}", .{
            @errorName(err),
        });
        return;
    };
    defer af.deinit(io);

    var bufw: [4096]u8 = undefined;
    var writer_state = af.file.writer(io, &bufw);
    const w = &writer_state.interface;

    for (hosts) |h| {
        try w.print("{s}\n{s}\n{s}\n", .{ h.client.identity, h.client.username, h.client.password });
    }

    try w.flush();
    af.replace(io) catch |err| {
        log.info("failed to update atomically hosts.awebo: {s}", .{
            @errorName(err),
        });
        return;
    };

    log.debug("updated hosts.awebo", .{});
}
