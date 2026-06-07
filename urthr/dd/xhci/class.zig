/// Instantiates a class driver for the specified interface.
///
/// Returns null if no suitable driver is found.
pub fn from(iface: *const Device.Interface) Error!?Driver {
    const code: Class = @enumFromInt(iface.desc.class);

    return switch (code) {
        .hid => try @import("class/Hid.zig").init(iface),

        // No suitable driver found.
        else => null,
    };
}

/// USB device class driver.
///
/// One class is instantiated for one interface of a USB device.
pub const Driver = struct {
    const Self = @This();

    /// Type-erased pointer.
    ptr: *anyopaque,
    /// Operations that the class driver implements.
    vtable: VTable,

    pub const VTable = struct {
        /// Name of the driver.
        name: *const fn () []const u8,
        /// Callback for transfer event on the endpoint.
        onTransferEvent: *const fn (ctx: *anyopaque, event: *const trbs.TransferEventTrb, ep: *Endpoint) Error!void,
    };

    /// Get the name of the class driver.
    pub fn getName(self: Self) []const u8 {
        return self.vtable.name();
    }
};

/// USB Class codes.
///
/// ref. https://www.usb.org/defined-class-codes
pub const Class = enum(u8) {
    /// Class code should be determined from the Interface Descriptor.
    per_interface = 0x00,
    /// Audio.
    audio = 0x01,
    /// Communications and CDC Control..
    cdc = 0x02,
    /// HID.
    hid = 0x03,
    /// Physical.
    physical = 0x05,
    /// Image.
    image = 0x06,
    /// Printer.
    printer = 0x07,
    /// Mass Storage.
    mass_storage = 0x08,
    /// Hub.
    hub = 0x09,
    /// CDC-Data.
    cdc_data = 0x0A,
    /// Smart Card.
    smart_card = 0x0B,
    /// Content Security.
    content_security = 0x0D,
    /// Video.
    video = 0x0E,
    /// Personal Healthcare.
    personal_healthcare = 0x0F,
    /// Audio/Video Devices.
    audio_video = 0x10,
    /// Billboard Device Class.
    billboard = 0x11,
    /// USB Type-C Bridge Class.
    usb_c_bridge = 0x12,

    _,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const urd = @import("urthr");

const Xhc = @import("Xhc.zig");
const regs = @import("registers.zig");
const rings = @import("ring.zig");
const trbs = @import("trb.zig");
const Error = Xhc.Error;
const Device = @import("Device.zig");
const Endpoint = Device.Endpoint;
const Trb = trbs.Trb;
