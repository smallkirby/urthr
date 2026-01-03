//! RP1 Peripheral Controller.

/// Initialize RP1 controller.
pub fn init() void {
    var confio = pcie.getConfIoType0();
    confio.setAddress(1, 0, 0);

    // Read configuration header.
    const header_vendor_dev = confio.read(dd.pci.HeaderVendorDevice);
    log.info(
        "RP1 Vendor ID: 0x{X:0>4}, Device ID: 0x{X:0>4}",
        .{ header_vendor_dev.vendor_id, header_vendor_dev.device_id },
    );
    rtt.expectEqual(0x1DE4, header_vendor_dev.vendor_id);
    rtt.expectEqual(0x0001, header_vendor_dev.device_id);

    // Not implemented yet.
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.rp1);
const common = @import("common");
const rtt = common.rtt;
const dd = @import("dd");

const pcie = @import("pcie.zig");
