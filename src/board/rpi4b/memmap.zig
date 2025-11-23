//! Memory map of Raspberry Pi 4B.

/// Base address of peripheral registers.
pub const peri_base = 0xFE00_0000;

/// GPIO
pub const gpio = peri_base + 0x0020_0000;
/// PL011 UART
pub const pl011 = peri_base + 0x0020_1000;
