/// Length of the seed for RNG.
const seed_length: usize = std.Random.Ascon.secret_seed_length;

/// RNG instance.
var rng: std.Random.Ascon = undefined;

/// Number of bytes generated so far, used for reseeding.
var feed_counter: usize = 0;

/// Reseed the RNG if the feed counter exceeds the threshold.
const reseed_threshold: usize = 1024;

/// Initialize RNG subsystem.
pub fn init() void {
    var seed: [seed_length]u8 = undefined;
    board.getRandom(&seed);

    rng = std.Random.Ascon.init(seed);
}

/// Fill the given buffer with random data.
pub fn getRandom(buf: []u8) void {
    feed_counter += buf.len;
    rng.fill(buf);

    if (feed_counter >= reseed_threshold) {
        reseed();
        feed_counter = 0;
    }
}

fn reseed() void {
    var seed: [seed_length]u8 = undefined;
    board.getRandom(&seed);

    rng.addEntropy(&seed);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const board = @import("board").impl;
