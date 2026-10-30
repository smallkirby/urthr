//! Input event handler.
//!
//! A handler consumes the events reported by input devices.

const Self = @This();

pub const Error = error{
    /// Too many handlers registered.
    TooManyHandlers,
};

/// Handle a key event of the device.
///
/// Can be called from IRQ context.
onKey: *const fn (dev: *Device, key: Key, state: Device.KeyState) void,
/// Handle the end of a packet of events reported by the device.
///
/// Can be called from IRQ context.
onSync: ?*const fn (dev: *Device) void = null,
/// Called when a device is registered.
connect: ?*const fn (dev: *Device) fs.Error!void = null,

/// The number of handlers that can be registered.
const max_handlers = 4;

/// Registered handlers.
var handlers: [max_handlers]Self = undefined;
/// The number of registered handlers.
var count: std.atomic.Value(usize) = .init(0);
/// Lock to serialize registrations.
var lock: SpinLock = .{};

/// Register a handler.
///
/// Registered handlers receive the events of all devices.
pub fn register(handler: Self) Error!void {
    const ie = lock.lockDisableIrq();
    defer lock.unlockRestoreIrq(ie);

    const n = count.load(.monotonic);
    if (n == max_handlers) return Error.TooManyHandlers;

    handlers[n] = handler;
    count.store(n + 1, .release);
}

/// Dispatch a key event to the registered handlers.
pub fn dispatchKey(dev: *Device, key: Key, state: Device.KeyState) void {
    for (handlers[0..count.load(.acquire)]) |handler| {
        handler.onKey(dev, key, state);
    }
}

/// Dispatch the end of a packet to the registered handlers.
pub fn dispatchSync(dev: *Device) void {
    for (handlers[0..count.load(.acquire)]) |handler| {
        if (handler.onSync) |onSync| onSync(dev);
    }
}

/// Notify the registered handlers of a new device.
pub fn connectDevice(dev: *Device) fs.Error!void {
    for (handlers[0..count.load(.acquire)]) |handler| {
        if (handler.connect) |connect| try connect(dev);
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const Key = common.input_codes.Key;
const urd = @import("urthr");
const fs = urd.fs;
const SpinLock = urd.sync.SpinLock;
const Device = @import("Device.zig");
