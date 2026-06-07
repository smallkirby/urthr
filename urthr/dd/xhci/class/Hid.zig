//! HID class driver.
//!
//! Implements `class.Driver` interface.

const Self = @This();

/// xHC device this driver is bound to.
device: *Device,
/// USB interface this driver is bound to.
iface: *const Device.Interface,
/// Interrupt IN endpoint for receiving input reports.
ep_in: *Device.Endpoint,
/// Buffer for receiving input reports.
buf: DmaMemory,

// =============================================================
// `class.Driver` implementation
// =============================================================

const vtable = Driver.VTable{
    .name = name,
    .onTransferEvent = onTransferEvent,
};

/// Initialize HID class driver and start Interrupt IN polling.
pub fn init(device: *Device, iface: *const Device.Interface) Error!Driver {
    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);

    // Find the Interrupt IN endpoint.
    const ep_in = blk: {
        var iter = iface.endpoints.iter();
        while (iter.next()) |ep| {
            if (ep.desc.attributes.transfer_type == .interrupt and
                ep.desc.address.direction == .in)
            {
                break :blk ep;
            }
        }
        log.err("No Interrupt IN endpoint found on interface#{d}", .{iface.desc.interface_number});
        return Error.InvalidState;
    };

    // Allocate buffer for receiving input reports.
    const buf = try device.dma.allocBytes(ep_in.desc.max_packet_size, .normal);
    errdefer device.dma.freeBytes(buf);
    @memset(buf.slice(u8), 0);

    self.* = .{
        .device = device,
        .iface = iface,
        .ep_in = ep_in,
        .buf = buf,
    };

    // Switch to Boot Protocol.
    if (iface.desc.subclass == 1) {
        try self.changeProtocol(.boot);
    }

    return .{ .ptr = self, .vtable = vtable };
}

/// Get the name of the class driver.
fn name() []const u8 {
    return "HID";
}

/// Callback for transfer events on the Interrupt IN endpoint.
fn onTransferEvent(ctx: *anyopaque, event: *const volatile trbs.TransferEventTrb, _: *Endpoint) Error!void {
    const self: *Self = @ptrCast(@alignCast(ctx));

    if (event.code == .success or event.code == .short_packet) {
        self.device.dma.syncForCpu(self.buf.cpu, self.buf.size);
        // TODO: do something
    } else {
        log.warn("Transfer error: {t}", .{event.code});
    }

    // Re-arm the endpoint for the next report.
    self.arm();
}

// =============================================================
// Internals
// =============================================================

/// HID protocol types.
const Protocol = enum(u8) {
    /// Boot protocol.
    boot = 0,
    /// Non-boot protocol.
    report = 1,
};

/// Set the HID protocol.
fn changeProtocol(self: *Self, protocol: Protocol) Error!void {
    const request_type = Device.SetupData.RequestType{
        .recipient = .interface,
        .type = .class,
        .direction = .out,
    };
    const setup_data = Device.SetupData{
        .request_type = request_type,
        .request = @enumFromInt(0x0B), // SET_PROTOCOL
        .value = @intFromEnum(protocol),
        .index = self.iface.desc.interface_number,
        .length = 0,
    };
    try self.device.ctrlXfer(
        setup_data,
        @ptrCast(self),
        onSetProtocolComplete,
    );
}

/// Callback invoked when SET_PROTOCOL control transfer completes.
fn onSetProtocolComplete(ctx: ?*anyopaque, _: *Device, _: ?DmaMemory) Error!void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    self.arm();
}

/// Queue the next Interrupt IN transfer.
fn arm(self: *Self) void {
    self.device.transferIn(self.ep_in, self.buf);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.hid);
const urd = @import("urthr");
const mem = urd.mem;
const DmaMemory = @import("common").mem.DmaAllocator.DmaMemory;

const Xhc = @import("../Xhc.zig");
const Error = Xhc.Error;
const Device = @import("../Device.zig");
const Endpoint = Device.Endpoint;
const trbs = @import("../trb.zig");
const class = @import("../class.zig");
const Driver = class.Driver;
