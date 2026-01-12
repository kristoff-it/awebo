//! Each struct represents a different command that the UI
//! can issue to the main application logic.

const builtin = @import("builtin");
const std = @import("std");
const assert = std.debug.assert();
const Allocator = std.mem.Allocator;
const core = @import("../core.zig");
const awebo = @import("../../awebo.zig");
const Host = awebo.Host;
const Chat = awebo.channels.Chat;
const Voice = awebo.channels.Voice;

/// The progress status of a async / long-running task.
/// Uses atomic operations internally for cross-thread
/// synchronization.
/// Before mutating directly, make sure to check if the
/// parent struct has some higher-level functions that
/// help model / check FSM state transitions.
///
/// - The start value will be the default value of this type.
/// - Progress states can be transitioned into multiple times.
/// - Start cannot be transitioned into. If you want to reuse
///   a status value, directly override the whole value.
/// - Done states can be transitioned into only once and are all
///   considered terminal states. It is expected that once a task
///   has reached a terminal state, its resources can be freed
///   or reused by the memory's owner.
pub fn AtomicEnum(
    comptime refresh_window: bool,
    start: @EnumLiteral(),
    progress: []const @EnumLiteral(),
    done: []const @EnumLiteral(),
) type {
    var field_names: [1 + progress.len + done.len][]const u8 = undefined;
    var field_values: [1 + progress.len + done.len]u8 = undefined;

    field_names[0] = @tagName(start);
    field_values[0] = 0;

    for (progress, field_names[1..][0..progress.len], field_values[1..][0..progress.len], 1..) |p, *name, *value, idx| {
        name.* = @tagName(p);
        value.* = idx;
    }

    for (done, field_names[1 + progress.len ..], field_values[1 + progress.len ..], progress.len..) |d, *name, *value, idx| {
        name.* = @tagName(d);
        value.* = idx + 1;
    }

    const const_field_names = field_names;
    const const_field_values = field_values;

    return struct {
        impl: std.atomic.Value(Enum) = .{ .raw = start },

        // std.builtin.Type.Enum.Mode;
        pub const Enum = @Enum(u8, .exhaustive, &const_field_names, &const_field_values);

        const Self = @This();
        pub fn update(s: *Self, src: std.builtin.SourceLocation, new: Enum) void {
            updateSafety(s, new);
            s.impl.store(new, .release);
            if (refresh_window) core.refresh(src, null);
        }

        pub fn get(s: *const Self) Enum {
            return s.impl.load(.acquire);
        }

        pub fn isDone(s: *const Self) bool {
            const current: u8 = @intFromEnum(s.get());
            return current > progress.len;
        }

        /// Updates a status value and returns its previous value.
        pub fn updateSwap(s: *Self, src: std.builtin.SourceLocation, new: Enum) Enum {
            updateSafety(s, new);
            const old = s.impl.swap(new, .acq_rel);
            if (refresh_window and old != new) core.refresh(src, null);
            return old;
        }

        /// Updates a status only if the previous value is the expected one.
        /// Returns the old value.
        pub fn updateCompare(s: *Self, src: std.builtin.SourceLocation, comptime expected: Enum, new: Enum) Enum {
            if (@intFromEnum(expected) > progress.len) {
                @compileError("'expected' cannot be a done state");
            }

            updateSafety(s, new);
            const unexpected = s.impl.cmpxchgStrong(expected, new, .acq_rel, .acquire) orelse {
                if (refresh_window) core.refresh(src, null);
                return expected;
            };
            return unexpected;
        }

        inline fn updateSafety(s: *Self, new: Enum) void {
            if (builtin.mode == .Debug) {
                const val = @intFromEnum(new);
                if (val == 0) @panic("tried to transition to the start value");
                const current = @intFromEnum(s.impl.load(.acquire));
                if (current > progress.len) @panic("tried to update a terminal status");
            }
        }
    };
}

pub const ChannelCreate = struct {
    origin: u64,
    host: *Host,
    kind: awebo.channels.Kind,
    name: []const u8,

    status: Status = .{},

    pub const Status = AtomicEnum(true, .pending, &.{}, &.{
        .connection_failure,
        .name_taken,
        .ok,
    });

    pub fn destroy(cc: *ChannelCreate, gpa: Allocator) void {
        gpa.free(cc.name);
        gpa.destroy(cc);
    }
};

pub const CallJoin = struct {
    host: Host.ClientOnly.Id,
    cmd: awebo.protocol.CallJoin,
};

/// Used to report the status of a frist attempt to connnect
/// to a new host.
pub const FirstConnectionStatus = AtomicEnum(true, .start, &.{
    .connecting,
    .connected,
    .authenticated,
}, &.{
    .success, // host was added, we can switch view
    .duplicate,
    .canceled,
    .authentication_failure,
    .network_error,
});
