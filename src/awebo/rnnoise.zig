const std = @import("std");
const assert = std.debug.assert;
const r = @import("rnnoise");

pub const FRAME_SIZE = 480;

pub const Denoiser = opaque {
    pub fn create() !*Denoiser {
        assert(r.rnnoise_get_frame_size() == FRAME_SIZE);
        const d = r.rnnoise_create(null) orelse return error.OutOfMemory;
        return @ptrCast(d);
    }

    pub fn destroy(d: *const Denoiser) void {
        r.rnnoise_destroy(d);
    }

    /// Returns the probability that the processed frame contains speech.
    pub fn processFrame(d: *Denoiser, out: *[FRAME_SIZE]f32, in: *const [FRAME_SIZE]f32) f32 {
        return r.rnnoise_process_frame(@ptrCast(d), out, in);
    }
};
