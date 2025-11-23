const map = struct {
    /// Base address of peripheral registers.
    const peri_base = 0xFE00_0000;

    /// GPIO
    const gpio = peri_base + 0x0020_0000;
    /// PL011 UART
    const pl011 = peri_base + 0x0020_1000;
};

/// Early board initialization.
///
/// Sets up essential peripherals like GPIO and UART.
pub fn boot() void {
    // Setup GPIO.
    dd.gpio.setBase(map.gpio);

    // Setup PL011 UART.
    dd.pl011.setBase(map.pl011);
    dd.gpio.selectAltFn(14, .alt0); // TXD0
    dd.gpio.selectAltFn(15, .alt0); // RXD0
    dd.pl011.init();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const arch = @import("arch");
const common = @import("common");
const dd = @import("dd");
