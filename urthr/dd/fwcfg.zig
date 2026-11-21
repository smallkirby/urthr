//! Driver for QEMU fw_cfg device.
//!
//! All multi-byte fields in the fw_cfg wire format are big-endian,
//! independent of the bus's own endianness.

// =============================================================
// Module Definition
// =============================================================

/// Bus used to access the registers.
const bus = if (builtin.cpu.arch == .x86_64) pio else mmio;

/// Address type of registers.
const Address = bus.Bus.Address;

var dev = if (bus == pio)
    pio.Module(.{ .natural = u16 }, .{
        Reg(0x00, Selector),
        Reg(0x01, Data),
    }){}
else
    mmio.Module(.{ .natural = u16 }, .{
        Reg(0x00, Data),
        Reg(0x08, Selector),
    }){};

/// Set the base address of fw_cfg device.
pub fn setBase(base: Address) void {
    dev.setBase(base);
}

// =============================================================
// Protocol
// =============================================================

/// A file found in the fw_cfg file directory.
pub const File = struct {
    /// Selector key of fw_cfg item.
    selector: u16,
    /// Size of referenced fw_cfg item.
    size: u32,
};

/// Selector of the fw_cfg file directory.
const file_dir_selector: u16 = 0x19;

/// Maximum length of a fw_cfg file name, including the NUL terminator.
const max_file_path = 56;

/// Look up a file by name in the fw_cfg file directory.
///
/// Caller must ensure that the base is set beforehand.
pub fn lookupFile(name: []const u8) ?File {
    // Select file directory.
    select(file_dir_selector);

    // Iterate over the directory entries and look for a matching name.
    const count = readBe(u32);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const size = readBe(u32);
        const selector = readBe(u16);
        _ = readBe(u16); // Reserved.

        var name_buf: [max_file_path]u8 = undefined;
        readBytes(&name_buf);

        if (std.mem.eql(u8, std.mem.sliceTo(&name_buf, 0), name)) {
            return .{ .selector = selector, .size = size };
        }
    } else return null;
}

/// Read `file`'s content into a newly allocated buffer.
pub fn readFile(file: File, allocator: Allocator) Allocator.Error![]u8 {
    const buf = try allocator.alloc(u8, file.size);
    select(file.selector);
    readBytes(buf);
    return buf;
}

/// Read the given size of bytes and parse it as a big-endian integer of type `T`.
fn readBe(T: type) T {
    var buf: [@sizeOf(T)]u8 = undefined;
    readBytes(&buf);
    return std.mem.readInt(T, &buf, .big);
}

/// Read bytes without any interpretation.
fn readBytes(buf: []u8) void {
    for (buf) |*b| b.* = readByte();
}

// =============================================================
// Registers
// =============================================================

/// Select the fw_cfg entry to operate on.
///
/// Resets the read offset to zero.
fn select(selector: u16) void {
    if (bus == pio) {
        dev.write(Selector, .{ .value = selector });
    } else {
        dev.write(Selector, .{ .value = @byteSwap(selector) });
    }
}

/// Read the next byte of the currently selected entry.
fn readByte() u8 {
    return dev.read(Data).value;
}

/// Data register.
const Data = packed struct(u8) { value: u8 };
/// Selector register.
const Selector = packed struct(u16) { value: u16 };

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const common = @import("common");
const mmio = common.io.mmio;
const Reg = common.io.Reg;
const pio = common.io.pio;
