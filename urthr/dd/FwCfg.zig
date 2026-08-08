//! QEMU firmware configuration (fw_cfg) device.
//!
//! Transport (I/O ports on x86, MMIO on AArch64 `virt`) is abstracted.
//! This file implements the transport-independent protocol on top of it.
//! All multi-byte fields in the fw_cfg wire format are big-endian,
//! independent of the transport's own endianness.

const Self = @This();

/// Vtable operations.
vtable: Vtable,

pub const Vtable = struct {
    /// Select the fw_cfg entry to operate on.
    ///
    /// Resets the read offset to zero.
    select: *const fn (selector: u16) void,
    /// Read the next byte of the currently selected entry.
    readByte: *const fn () u8,
};

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
pub fn lookupFile(self: Self, name: []const u8) ?File {
    // Select file directory.
    self.vtable.select(file_dir_selector);

    // Iterate over the directory entries and look for a matching name.
    const count = self.readBe(u32);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const size = self.readBe(u32);
        const selector = self.readBe(u16);
        _ = self.readBe(u16); // Reserved.

        var name_buf: [max_file_path]u8 = undefined;
        self.readBytes(&name_buf);

        if (std.mem.eql(u8, std.mem.sliceTo(&name_buf, 0), name)) {
            return .{ .selector = selector, .size = size };
        }
    } else return null;
}

/// Read `file`'s content into a newly allocated buffer.
pub fn readFile(self: Self, file: File, allocator: Allocator) Allocator.Error![]u8 {
    const buf = try allocator.alloc(u8, file.size);
    self.vtable.select(file.selector);
    self.readBytes(buf);
    return buf;
}

/// Read the given size of bytes and parse it as a big-endian integer of type `T`.
fn readBe(self: Self, T: type) T {
    var buf: [@sizeOf(T)]u8 = undefined;
    self.readBytes(&buf);
    return std.mem.readInt(T, &buf, .big);
}

/// Read bytes without any interpretation.
fn readBytes(self: Self, buf: []u8) void {
    for (buf) |*b| b.* = self.vtable.readByte();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
