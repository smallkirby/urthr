//! Fake random number generator.
//!
//! This driver is intended to be used for environments without a real RNG device.

/// Read (not) random data into the given buffer.
pub fn read(buf: []u8) []u8 {
    rtt.expect(buf.len % 8 == 0);

    const buf64 = @as([*]align(1) u64, @ptrCast(buf.ptr))[0 .. buf.len / 8];
    for (buf64) |*p| {
        p.* = getRandom64();
    }

    return buf;
}

fn getRandom64() u64 {
    // Get entropy from tick counter.
    var acc: u64 = 0;
    for (0..128) |i| {
        const t1 = arch.timer.getCount();
        for (0..t1 % 0xFF) |j| arch.timer.spinWaitNano(j);
        const t2 = arch.timer.getCount();

        acc ^= ((t2 - t1) & 1) << @as(u6, @intCast((i % 64)));
    }

    // Mix with stack pointer.
    acc ^= arch.timer.getCount();
    acc ^= @intFromPtr(&acc);
    acc ^= @returnAddress();

    // Finalize with MurmurHash3's finalizer.
    acc ^= acc >> 33;
    acc *%= 0xFF51AFD7ED558CCD;
    acc ^= acc >> 33;
    acc *%= 0xC4CEB9FE1A85EC53;
    acc ^= acc >> 33;

    return acc;
}

// =============================================================
// Imports
// =============================================================

const arch = @import("arch").impl;
const common = @import("common");
const rtt = common.rtt;
