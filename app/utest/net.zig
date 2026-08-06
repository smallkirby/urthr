comptime {
    _ = @import("net/socket.zig");
    _ = @import("net/connect.zig");
    _ = @import("net/sendrecv.zig");
}

/// Default gateway address for QEMU SLIRP networking.
pub const gateway_addr = std.mem.nativeToBig(u32, 0x0A000202);
/// String representation of the default gateway address for QEMU SLIRP networking.
pub const gateway_addr_str = "10.0.2.2";
/// Default gateway port for QEMU SLIRP networking.
pub const gateway_port: u16 = 18080;

// =============================================================
// Imports
// =============================================================

const std = @import("std");
