comptime {
    _ = @import("net/socket.zig");
    _ = @import("net/bind.zig");
    _ = @import("net/connect.zig");
    _ = @import("net/sendrecv.zig");
    _ = @import("net/sockopt.zig");
    _ = @import("net/dns.zig");
}

/// Default gateway address for QEMU SLIRP networking.
pub const gateway_addr = std.mem.nativeToBig(u32, 0x0A000202);
/// String representation of the default gateway address for QEMU SLIRP networking.
pub const gateway_addr_str = "10.0.2.2";
/// Default gateway port for QEMU SLIRP networking.
pub const gateway_port: u16 = 18080;

/// Address of the fake DNS server started by the test harness.
pub const dns_addr = gateway_addr;
/// Port of the fake DNS server started by the test harness.
pub const dns_port: u16 = 5553;
/// Fixed IPv4 answer that the fake DNS server always returns.
pub const dns_answer_ip = [4]u8{ 93, 184, 216, 34 };

// =============================================================
// Imports
// =============================================================

const std = @import("std");
