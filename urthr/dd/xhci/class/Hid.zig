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
/// Interface instance.
instance: Instance,

/// Type of HID device.
const DeviceType = enum {
    /// Keyboard.
    keyboard,
    /// Mouse.
    mouse,
    /// Other HID device.
    other,
};

/// Interface instance.
const Instance = union(DeviceType) {
    keyboard: Keyboard,
    mouse: void,
    other: void,
};

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

    // Instantiate the interface instance.
    const instance = switch (detectDeviceType(iface)) {
        .keyboard => Instance{ .keyboard = Keyboard{} },
        .mouse => Instance{ .mouse = {} },
        .other => Instance{ .other = {} },
    };

    self.* = .{
        .device = device,
        .iface = iface,
        .ep_in = ep_in,
        .buf = buf,
        .instance = instance,
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
fn onTransferEvent(ctx: *anyopaque, event: *const trbs.XferEventTrb, _: *Endpoint) Error!void {
    const self: *Self = @ptrCast(@alignCast(ctx));
    defer self.arm();

    if (event.code != .success and event.code != .short_packet) {
        log.warn("Transfer error: {t}", .{event.code});
        return;
    }

    self.device.dma.syncForCpu(self.buf.cpu, self.buf.size);

    switch (self.instance) {
        .keyboard => self.handleKbdInput(self.buf),
        .mouse => {},
        .other => {},
    }
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

/// Detect what type of HID device this is based on interface descriptor
fn detectDeviceType(interface: *const Device.Interface) DeviceType {
    // Check if this is a boot interface device
    if (interface.desc.subclass == 1) {
        return switch (interface.desc.protocol) {
            1 => .keyboard,
            2 => .mouse,
            else => .other,
        };
    }

    // For non-boot devices, we'd need to parse HID descriptors.
    // For now, assume it's a generic HID device.
    return .other;
}

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
// Keyboard
// =============================================================

/// Keyboard with boot protocol.
const Keyboard = struct {
    /// Last received input report
    last_report: BootReport = std.mem.zeroes(BootReport),

    /// Boot keyboard input report format.
    const BootReport = packed struct(u64) {
        /// Modifier keys.
        modifiers: Modifiers,
        /// Reserved.
        reserved: u8,
        // Up to 6 simultaneously pressed keys
        key0: u8,
        key1: u8,
        key2: u8,
        key3: u8,
        key4: u8,
        key5: u8,

        const Modifiers = packed struct(u8) {
            left_ctrl: bool,
            left_shift: bool,
            left_alt: bool,
            left_gui: bool,
            right_ctrl: bool,
            right_shift: bool,
            right_alt: bool,
            right_gui: bool,
        };

        /// Create a BootReport from raw data.
        fn from(data: []const u8) ?*const BootReport {
            if (data.len < @sizeOf(BootReport)) return null;
            return @ptrCast(@alignCast(data.ptr));
        }

        /// Get keys as an array for easier iteration
        fn keys(self: *const BootReport) [6]u8 {
            return .{ self.key0, self.key1, self.key2, self.key3, self.key4, self.key5 };
        }

        /// Check if a key is in the report.
        fn contains(self: BootReport, key: u8) bool {
            for (self.keys()) |k| {
                if (k == key) return true;
            } else {
                return false;
            }
        }
    };

    /// Convert USB HID key code to ASCII character.
    fn codeToChars(key_code: u8, shifted: bool) []const u8 {
        return switch (key_code) {
            0x04...0x1D => if (shifted) &.{key_code - 0x04 + 'A'} else &.{key_code - 0x04 + 'a'},
            0x1E => if (shifted) "!" else "1",
            0x1F => if (shifted) "@" else "2",
            0x20 => if (shifted) "#" else "3",
            0x21 => if (shifted) "$" else "4",
            0x22 => if (shifted) "%" else "5",
            0x23 => if (shifted) "^" else "6",
            0x24 => if (shifted) "&" else "7",
            0x25 => if (shifted) "*" else "8",
            0x26 => if (shifted) "(" else "9",
            0x27 => if (shifted) ")" else "0",
            0x28 => "\n",
            0x29 => &.{0x1B},
            0x2A => &.{0x7F}, // Backspace to DEL
            0x2B => "\t",
            0x2C => " ",
            0x2D => if (shifted) "_" else "-",
            0x2E => if (shifted) "+" else "=",
            0x2F => if (shifted) "{" else "[",
            0x30 => if (shifted) "}" else "]",
            0x31 => if (shifted) "|" else "\\",
            0x33 => if (shifted) ":" else ";",
            0x34 => if (shifted) "\"" else "'",
            0x35 => if (shifted) "~" else "`",
            0x36 => if (shifted) "<" else ",",
            0x37 => if (shifted) ">" else ".",
            0x38 => if (shifted) "?" else "/",
            0x4F => "\x1B[C", // Right arrow
            0x50 => "\x1B[D", // Left arrow
            0x51 => "\x1B[B", // Down arrow
            0x52 => "\x1B[A", // Up arrow
            else => &.{},
        };
    }
};

/// Handle a received keyboard input report.
fn handleKbdInput(self: *Self, buf: DmaMemory) void {
    const report = Keyboard.BootReport.from(buf.slice(u8)) orelse {
        log.err("Received invalid keyboard report", .{});
        return;
    };
    const kbd = &self.instance.keyboard;
    const last = kbd.last_report;
    const mods = report.modifiers;
    const shifted = mods.left_shift or mods.right_shift;
    const ctrled = mods.left_ctrl or mods.right_ctrl;

    for (report.keys()) |key| {
        if (key == 0 or last.contains(key)) continue;

        if (ctrled) {
            // Ctrl + <letter> -> control character (0x01–0x1A)
            if (key >= 0x04 and key <= 0x1D) {
                urd.input.push(key - 0x04 + 1);
            }
            continue;
        }

        for (Keyboard.codeToChars(key, shifted)) |c| {
            urd.input.push(c);
        }
    }

    kbd.last_report = report.*;
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
