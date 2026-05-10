//! ELF loader.

pub const Error = error{
    /// The file is not a valid ELF binary.
    InvalidElf,
    /// The ELF binary requires dynamic linking, which is not supported.
    NotSupported,
} ||
    urd.fs.Error ||
    urd.task.Vmm.Error;

/// Load an ELF executable from the filesystem.
///
/// Returns the entry point address of the loaded executable.
///
/// TODO: support dynamic linking.
pub fn load(th: *Thread, filename: []const u8) Error!usize {
    const allocator = urd.mem.getGeneralAllocator();

    const file = try fs.open(filename, allocator);
    defer file.unref();

    const size = file.path.dentry.inode.size;
    if (size < @sizeOf(Elf64_Ehdr)) return Error.InvalidElf;

    // Read entire file.
    // TODO: should read only headers and loadable segments.
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

    // Scan program headers.
    var piter = ehdr.iterateProgramHeadersBuffer(buf);
    while (piter.next() catch return Error.InvalidElf) |phdr| {
        if (phdr.p_type == std.elf.PT_INTERP) return Error.NotSupported;
        if (phdr.p_type != std.elf.PT_LOAD) continue;

        const va_start_aligned = std.mem.alignBackward(usize, phdr.p_vaddr, urd.mem.page_size);
        const va_end_aligned = std.mem.alignForward(usize, phdr.p_vaddr + phdr.p_memsz, urd.mem.page_size);
        const size_aligned = va_end_aligned - va_start_aligned;

        // Map the segment and copy file data.
        const memory = try th.vmm.map(
            va_start_aligned,
            size_aligned,
            getAttribute(phdr),
        );
        const offset_in_memory = phdr.p_vaddr - va_start_aligned;
        const segment = memory[offset_in_memory..][0..phdr.p_memsz];
        @memcpy(segment[0..phdr.p_filesz], buf[phdr.p_offset..][0..phdr.p_filesz]);

        // Zero clear the remaining memory.
        @memset(memory[0..offset_in_memory], 0);
        @memset(segment[phdr.p_filesz..], 0);
    }

    return ehdr.entry;
}

/// Get the memory permission from the ELF program header.
fn getAttribute(phdr: std.elf.Elf64_Phdr) common.mem.Permission {
    const flags = phdr.p_flags;
    var perm: common.mem.Permission = .none;

    if (flags & std.elf.PF_R != 0) {
        perm.ur = true;
        perm.kr = true;
    }
    if (flags & std.elf.PF_W != 0) {
        perm.uw = true;
        perm.kw = true;
    }
    if (flags & std.elf.PF_X != 0) {
        perm.ux = true;
    }

    return perm;
}

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const Elf64_Ehdr = std.elf.Elf64_Ehdr;
const Elf64_Phdr = std.elf.Elf64_Phdr;
const log = std.log.scoped(.loader);
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
const Thread = urd.task.thread.Thread;
