//! Message Signaled Interrupts.

/// MSI message consisting of a memory address and a data value.
///
/// Writing `data` to `addr` delivers an interrupt to the local APIC.
pub const Message = struct {
    /// Message address register.
    addr: u64,
    /// Message data register.
    data: u32,
};

/// Build an MSI message that delivers `vector` to the specified local APIC.
pub fn buildMessage(vector: u8, dest_apic_id: u8) Message {
    return .{
        .addr = @bitCast(Address{
            .dest = dest_apic_id,
        }),
        .data = @bitCast(Data{
            .vector = vector,
            .delivery_mode = .fixed,
        }),
    };
}

/// MSI message address register.
const Address = packed struct(u64) {
    /// Reserved.
    _0: u2 = 0,
    /// Destination mode.
    dm: enum(u1) {
        /// Physical mode.
        physical = 0,
        /// Logical mode.
        logical = 1,
    } = .physical,
    /// Redirection hint.
    rh: u1 = 0,
    /// Reserved.
    _4: u8 = 0,
    /// Destination ID.
    dest: u8,
    /// Fixed value for interrupt messages.
    _20: u12 = 0xFEE,
    /// Reserved.
    _32: u32 = 0,
};

/// MSI message data register.
const Data = packed struct(u32) {
    /// The vector number of the interrupt being sent.
    vector: u8,
    /// Delivery mode.
    delivery_mode: lapic.DeliveryMode,
    /// Reserved.
    _11: u3 = 0,
    /// Level.
    level: u1 = 1,
    /// Trigger mode.
    trigger_mode: enum(u1) {
        /// Edge-triggered.
        edge = 0,
        /// Level-triggered.
        level = 1,
    } = .edge,
    /// Reserved.
    _16: u16 = 0,
};

// =============================================================
// Imports
// =============================================================

const lapic = @import("lapic.zig");
