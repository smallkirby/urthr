//! Input device.
//!
//! Tracks the state of a device and dispatches its events to the handlers.

const Self = @This();

/// State of a key.
pub const KeyState = enum(i32) {
    /// The key is released.
    release = 0,
    /// The key is pressed.
    press = 1,
    /// The key is held down and repeated.
    repeat = 2,
};

/// Bus type of the device, compatible with Linux.
pub const Bus = enum(u16) {
    /// Unknown input device
    unknown = 0x00,
    /// USB
    usb = 0x03,
    /// Virtual input
    virtual = 0x06,

    _,
};

/// Identifier of the device.
pub const Id = struct {
    /// Bus the device is connected to.
    bustype: Bus = .unknown,
    /// Vendor ID.
    vendor: u16 = 0,
    /// Product ID.
    product: u16 = 0,
    /// Product version.
    version: u16 = 0,
};

/// Exclusive receiver of the events of a device.
pub const Grab = struct {
    /// Handler that receives the events.
    handler: *const Handler,
    /// Owner of the grab.
    owner: *anyopaque,
};

/// Set of key codes.
pub const KeySet = std.bit_set.Static(key_capacity);

/// Name of the device.
name: []const u8 = "",
/// Identifier of the device.
id: Id = .{},
/// Keys that the device can report.
keybit: KeySet = .empty,
/// Keys that are currently pressed.
keys: KeySet = .empty,
/// Handler that exclusively receives the events of the device.
grabber: ?Grab = null,
/// Whether events have been reported since the last sync.
dirty: bool = false,
/// Lock protecting the device state.
lock: SpinLock = .{},

/// The number of key codes tracked by the device.
const key_capacity = 256;

/// Register the device.
///
/// Handlers are notified of the device.
pub fn register(self: *Self) fs.Error!void {
    try Handler.connectDevice(self);
}

/// Report a key event.
///
/// Can be called from IRQ context.
pub fn reportKey(self: *Self, key: Key, state: KeyState) void {
    const index = @backingInt(key);
    if (index >= key_capacity) return;

    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    const pressed = self.keys.isSet(index);
    switch (state) {
        .press => {
            if (pressed) return;
            self.keys.set(index);
        },
        .release => {
            if (!pressed) return;
            self.keys.unset(index);
        },
        .repeat => if (!pressed) return,
    }

    self.dirty = true;
    Handler.dispatchKey(self, key, state);
}

/// Report the end of a packet of events.
///
/// Does nothing if no events have been reported since the last call.
pub fn sync(self: *Self) void {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    if (!self.dirty) return;
    self.dirty = false;
    Handler.dispatchSync(self);
}

/// Get the keys that are currently pressed.
pub fn getKeys(self: *Self) KeySet {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    return self.keys;
}

/// Grab the device.
///
/// While the device is grabbed, only the handler receives its events.
pub fn grab(self: *Self, handler: *const Handler, owner: *anyopaque) fs.Error!void {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    if (self.grabber != null) return fs.Error.Busy;
    self.grabber = .{ .handler = handler, .owner = owner };
}

/// Release the grab of the device.
///
/// Returns error if the device is not grabbed by the handler and the owner.
pub fn ungrab(self: *Self, handler: *const Handler, owner: *anyopaque) fs.Error!void {
    const ie = self.lock.lockDisableIrq();
    defer self.lock.unlockRestoreIrq(ie);

    const grabber = self.grabber orelse return fs.Error.InvalidArgument;
    if (grabber.handler != handler or grabber.owner != owner) {
        return fs.Error.InvalidArgument;
    }

    self.grabber = null;
}

/// Check if the key is pressed.
///
/// The caller must hold the lock.
pub fn isPressed(self: *const Self, key: Key) bool {
    rtt.expect(self.lock.isLocked());

    const index = @backingInt(key);
    return index < key_capacity and self.keys.isSet(index);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const Key = common.input_codes.Key;
const urd = @import("urthr");
const fs = urd.fs;
const SpinLock = urd.sync.SpinLock;
const Handler = @import("Handler.zig");
