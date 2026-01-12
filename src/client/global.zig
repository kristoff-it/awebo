/// Contains global data used by the client.
///
/// This data should only be accessed by the "main thread".
///
/// Since hardware devices (audio devices/webcams/screens) are "global" to
/// the system, we also store entries for them globally within the process.
/// This also allows us to accurately track/log whenever a device is added/removed
/// from the system.
const std = @import("std");
const audio = @import("audio.zig");

pub var main_thread_id: ?std.Thread.Id = null;

pub fn enforceMainThread() void {
    const current_thread_id = std.Thread.getCurrentId();
    if (current_thread_id != main_thread_id) std.debug.panic(
        "expected to be on main thread {?} but on {}",
        .{ main_thread_id, current_thread_id },
    );
}

// The following is the global data for the "string intern pool"
pub var pool_content_map: std.StringHashMapUnmanaged([:0]const u8) = .{};
pub var pool_refcount_map: std.AutoHashMapUnmanaged([*:0]const u8, usize) = .{};

pub var audio_capture: audio.Directional = .{ .direction = .capture };
pub var audio_playout: audio.Directional = .{ .direction = .playout };
pub fn directional(direction: audio.Direction) *audio.Directional {
    return switch (direction) {
        .capture => &audio_capture,
        .playout => &audio_playout,
    };
}
