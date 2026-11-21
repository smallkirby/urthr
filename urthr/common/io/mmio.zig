//! Memory-mapped I/O register accessor.

/// Defines a module of MMIO registers.
pub fn Module(Width: io.Align, comptime entries: anytype) type {
    return io.ModuleOn(Bus, Width, entries);
}

/// Memory-mapped I/O bus.
pub const Bus = struct {
    /// Type of the address of the registers.
    pub const Address = usize;

    /// Read a value at the given memory address.
    pub fn read(comptime W: type, address: usize) W {
        const ptr: *const volatile W = @ptrFromInt(address);
        return ptr.*;
    }

    /// Write a value at the given memory address.
    pub fn write(comptime W: type, address: usize, value: W) void {
        const ptr: *volatile W = @ptrFromInt(address);
        ptr.* = value;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const io = @import("common").io;
