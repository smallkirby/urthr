//! Legacy Intel 8259 Programmable Interrupt Controller (PIC) driver.

/// Vector offset the PIC's IRQ lines are remapped to.
const vector_offset: u8 = 0x20;

var primary = pio.Module(&.{
    .{ 0x00, Icw1 },
    .{ 0x01, Icw2 },
    .{ 0x01, Icw3 },
    .{ 0x01, Icw4 },
    .{ 0x01, Ocw1 },
}){ .base = 0x20 };

var secondary = pio.Module(&.{
    .{ 0x00, Icw1 },
    .{ 0x01, Icw2 },
    .{ 0x01, Icw3 },
    .{ 0x01, Icw4 },
    .{ 0x01, Ocw1 },
}){ .base = 0xA0 };

// =============================================================

/// Remap the PIC's IRQ vectors, then mask all of its lines.
pub fn disable() void {
    // Start init sequence.
    primary.writez(Icw1, .{});
    secondary.writez(Icw1, .{});

    // Set the vector offsets.
    primary.writez(Icw2, .{ .offset = vector_offset });
    secondary.writez(Icw2, .{ .offset = vector_offset + 8 });

    // Tell primary PIC that there is a slave PIC at IRQ2.
    primary.writez(Icw3, .{ .cascade = 0b100 });
    // Tell secondary PIC its cascade identity.
    secondary.writez(Icw3, .{ .cascade = 2 });

    // Set the mode.
    primary.writez(Icw4, .{});
    secondary.writez(Icw4, .{});

    // Mask all IRQ lines.
    primary.writez(Ocw1, .{ .mask = 0xFF });
    secondary.writez(Ocw1, .{ .mask = 0xFF });
}

// =============================================================
// Registers
// =============================================================

/// Initialization Command Word 1.
const Icw1 = packed struct(u8) {
    /// ICW4 is needed.
    icw4: bool = true,
    /// Single or cascade mode.
    single: bool = false,
    /// CALL address interval 4 or 8.
    interval4: bool = false,
    /// Level or edge triggered.
    level: bool = false,
    /// Initialization command.
    _4: u1 = 1,
    /// Unused in 8086/8088 mode.
    _5: u3 = 0,
};

/// Initialization Command Word 2.
const Icw2 = packed struct(u8) {
    /// Vector offset.
    offset: u8,
};

/// Initialization Command Word 3.
const Icw3 = packed struct(u8) {
    /// For the primary PIC, the cascaded IRQ line. For the secondary PIC, its cascade identity.
    cascade: u8,
};

/// Initialization Command Word 4.
const Icw4 = packed struct(u8) {
    /// 8086/8088 mode or MCS-80/85 mode.
    mode_8086: bool = true,
    /// Auto EOI or normal EOI.
    auto_eoi: bool = false,
    /// Buffered mode.
    buffered: u2 = 0,
    /// Special fully nested mode.
    full_nested: bool = false,
    /// Reserved.
    _5: u3 = 0,
};

/// Operation Command Word 1: interrupt mask register.
const Ocw1 = packed struct(u8) {
    /// Interrupt mask.
    mask: u8,
};

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const pio = common.pio;
