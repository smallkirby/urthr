//! Port I/O register accessor.

/// Defines a module of port I/O registers.
pub fn Module(Width: io.Align, comptime entries: anytype) type {
    return io.ModuleOn(Bus, Width, entries);
}

/// Port I/O bus.
pub const Bus = struct {
    /// Type of the address of the registers.
    pub const Address = u16;

    /// Read a value from the given I/O port.
    pub fn read(comptime W: type, address: usize) W {
        const port: u16 = @intCast(address);
        return switch (W) {
            u8 => pio.inb(port),
            u16 => pio.inw(port),
            else => @compileError("Port I/O does not support the access width: " ++ @typeName(W)),
        };
    }

    /// Write a value to the given I/O port.
    pub fn write(comptime W: type, address: usize, value: W) void {
        const port: u16 = @intCast(address);
        switch (W) {
            u8 => pio.outb(port, value),
            u16 => pio.outw(port, value),
            else => @compileError("Port I/O does not support the access width: " ++ @typeName(W)),
        }
    }
};

// =============================================================
// Internals
// =============================================================

/// Port I/O operations.
const pio = switch (builtin.cpu.arch) {
    .x86_64 => struct {
        /// Read a single byte from the given I/O port.
        fn inb(port: u16) u8 {
            return asm volatile ("inb %[port], %[ret]"
                : [ret] "={al}" (-> u8),
                : [port] "N{dx}" (port),
            );
        }

        /// Read a single word from the given I/O port.
        fn inw(port: u16) u16 {
            return asm volatile ("inw %[port], %[ret]"
                : [ret] "={ax}" (-> u16),
                : [port] "N{dx}" (port),
            );
        }

        /// Write a single byte to the given I/O port.
        fn outb(port: u16, value: u8) void {
            asm volatile ("outb %[value], %[port]"
                :
                : [value] "{al}" (value),
                  [port] "N{dx}" (port),
            );
        }

        /// Write a single word to the given I/O port.
        fn outw(port: u16, value: u16) void {
            asm volatile ("outw %[value], %[port]"
                :
                : [value] "{ax}" (value),
                  [port] "N{dx}" (port),
            );
        }
    },
    else => @compileError("Port I/O is not supported on this architecture"),
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const io = @import("common").io;
