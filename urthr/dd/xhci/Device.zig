const Self = @This();

/// Device state.
state: State,

/// Port index (1-origin).
pi: usize,
/// Port register.
pr: regs.Port,

/// Device state.
const State = enum {
    /// Port is connected.
    initialized,
    /// Waiting for the Slot ID to be assigned.
    waiting_slot,
    /// Waiting for the address to be assigned.
    waiting_address,
    /// Address has been assigned and device is waiting for the device descriptor.
    waiting_device_desc,
    /// Waiting for the configuration descriptor.
    waiting_config_desc,
    /// Waiting for the configuration to be set.
    waiting_config_set,
    /// Initialization complete.
    complete,
};

pub fn new(pi: usize, pr: regs.Port) mem.Error!*Self {
    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);

    self.* = .{
        .state = .initialized,
        .pi = pi,
        .pr = pr,
    };

    return self;
}

/// Reset the port.
///
/// Blocks until the request is completed.
/// Generates a Port Reset Change event when completed.
pub fn resetPort(self: *Self) void {
    rtt.expectEqual(.initialized, self.state);

    self.pr.modify(regs.PortSc, .{
        .pr = true,
    });
    self.pr.waitFor(regs.PortSc, .{
        .pr = false,
    }, null);

    self.state = .waiting_slot;
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const mem = urd.mem;

const regs = @import("registers.zig");
const trbs = @import("trb.zig");
