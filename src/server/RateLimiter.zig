//! Token bucket rate limiter.
const RateLimiter = @This();

const std = @import("std");
const Io = std.Io;

tokens: f32,
last_refill_timestamp: Io.Timestamp,

pub const Config = struct {
    capacity: f32,
    refill_rate_per_second: f32,

    pub const connect: Config = .{ .capacity = 5, .refill_rate_per_second = 0.2 };
    pub const tcp_message: Config = .{ .capacity = 5, .refill_rate_per_second = 1 };
    pub const user_action: Config = .{ .capacity = 3, .refill_rate_per_second = 1 };
};

pub fn init(io: Io, cfg: Config) RateLimiter {
    return .{
        .tokens = cfg.capacity,
        .last_refill_timestamp = Io.Clock.real.now(io),
    };
}

pub fn takeToken(rl: *RateLimiter, io: Io, cfg: Config) error{RateLimit}!void {
    const now = Io.Clock.real.now(io);
    const elapsed = rl.last_refill_timestamp.durationTo(now);
    rl.last_refill_timestamp = now;

    const elapsed_sec: f32 = @floatFromInt(elapsed.toSeconds());
    rl.tokens += elapsed_sec * cfg.refill_rate_per_second;

    if (rl.tokens > cfg.capacity) rl.tokens = cfg.capacity;

    // Succeed if we have at least one full token available
    if (rl.tokens >= 1.0) {
        rl.tokens -= 1.0;
        return;
    }

    return error.RateLimit;
}

test {
    const io = std.testing.io;

    // The capacity is 5 tokens, refill rate is 2 tokens/sec
    const test_cfg: Config = .{ .capacity = 5, .refill_rate_per_second = 2 };

    var bucket = RateLimiter.init(io, test_cfg);

    // Consume the first 5 tokens immediately
    for (0..5) |_| try bucket.takeToken(io, test_cfg);

    // The 6th token should be denied
    try std.testing.expectError(error.RateLimit, bucket.takeToken(io, test_cfg));

    // Wait a second, allowing 2 tokens to refill
    try Io.Clock.Duration.sleep(.{ .clock = .awake, .raw = .fromSeconds(1) }, io);

    // Consume 2 more tokens
    for (0..2) |_| try bucket.takeToken(io, test_cfg);

    // The next token should be denied
    try std.testing.expectError(error.RateLimit, bucket.takeToken(io, test_cfg));
}
