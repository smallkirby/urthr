//! ELF loader.

pub const Error = error{
    /// The file is not a valid ELF binary.
    InvalidElf,
    /// The ELF binary requires dynamic linking, which is not supported.
    NotSupported,
} ||
    urd.fs.Error;

/// Load an ELF executable from the filesystem.
///
/// TODO: support dynamic linking.
pub fn load(filename: []const u8) Error!void {
    const allocator = urd.mem.getGeneralAllocator();

    const file = try fs.open(filename, allocator);
    defer file.unref();

    const size = file.path.dentry.inode.size;
    if (size < @sizeOf(Elf64_Ehdr)) return Error.InvalidElf;

    // Read entire file.
    const buf = try allocator.alloc(u8, size);
    defer allocator.free(buf);
    _ = try file.read(buf);

    // Read ELF header.
    var ehdr_reader = std.Io.Reader.fixed(buf[0..]);
    const ehdr = std.elf.Header.read(&ehdr_reader) catch {
        return error.InvalidElf;
    };

    // Validate ELF header.
    if (ehdr.type != .EXEC) return Error.InvalidElf;
    if (!ehdr.is_64) return Error.InvalidElf;
    if (ehdr.endian != builtin.cpu.arch.endian()) return Error.InvalidElf;
    if (ehdr.os_abi != .NONE) return Error.InvalidElf;

    // Scan program headers.
    var ereader = std.Io.Reader.fixed(buf[0..]);
    var piter = ehdr.iterateProgramHeaders(&ereader);
    while (piter.next() catch return Error.InvalidElf) |phdr| {
        if (phdr.p_type == std.elf.PT_INTERP) return Error.NotSupported;
        if (phdr.p_type != std.elf.PT_LOAD) continue;

        // TODO
    }
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const Elf64_Ehdr = std.elf.Elf64_Ehdr;
const Elf64_Phdr = std.elf.Elf64_Phdr;
const log = std.log.scoped(.loader);
const urd = @import("urthr");
const fs = urd.fs;
