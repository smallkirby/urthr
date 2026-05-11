//! ELF loader.

pub const Error = error{
    /// The file is not a valid ELF binary.
    InvalidElf,
    /// The ELF binary requires dynamic linking, which is not supported.
    NotSupported,
} ||
    urd.fs.Error ||
    urd.task.Vmm.Error;

/// Information about the loaded executable.
pub const LoadInfo = struct {
    /// Entry point address.
    entry: usize,
    /// Program break.
    brk: usize,
    /// Virtual address of program header table (AT_PHDR).
    phdr_addr: usize,
    /// Size of one program header entry (AT_PHENT).
    phdr_entsize: usize,
    /// Number of program header entries (AT_PHNUM).
    phdr_num: usize,
};

/// Load an ELF executable from the filesystem.
///
/// Returns the entry point address of the loaded executable.
///
/// TODO: support dynamic linking.
pub fn load(th: *Thread, filename: []const u8) Error!LoadInfo {
    const allocator = urd.mem.getGeneralAllocator();

    const file = try fs.open(filename, allocator);
    defer file.unref();
    if (file.size() < @sizeOf(Elf64_Ehdr)) return Error.InvalidElf;

    // Create a ELF file reader.
    var rbuf: [1024]u8 = undefined;
    var reader = Reader.init(file, &rbuf);

    // Validate ELF header.
    const ehdr = std.elf.Header.read(&reader.interface) catch return error.InvalidElf;
    if (ehdr.type != .EXEC) return Error.InvalidElf;
    if (!ehdr.is_64) return Error.InvalidElf;
    if (ehdr.endian != builtin.cpu.arch.endian()) return Error.InvalidElf;
    if (ehdr.phentsize != @sizeOf(Elf64_Phdr)) return Error.InvalidElf;

    // Scan program headers.
    var brk: usize = 0;
    var phdr_addr: usize = 0;
    var iter = PhdrIterator.init(&reader, ehdr);
    while (try iter.next()) |phdr| {
        if (phdr.p_type == std.elf.PT_INTERP) return Error.NotSupported;

        // Find which PT_LOAD segment contains the phdr table.
        if (phdr.p_type == std.elf.PT_LOAD and phdr_addr == 0) {
            if (phdr.p_offset <= ehdr.phoff and ehdr.phoff < phdr.p_offset + phdr.p_filesz) {
                phdr_addr = phdr.p_vaddr + (ehdr.phoff - phdr.p_offset);
            }
        }

        if (phdr.p_type != std.elf.PT_LOAD) continue;

        const va_start_aligned = std.mem.alignBackward(usize, phdr.p_vaddr, urd.mem.page_size);
        const va_end_aligned = std.mem.alignForward(usize, phdr.p_vaddr + phdr.p_memsz, urd.mem.page_size);
        const size_aligned = va_end_aligned - va_start_aligned;

        // Validate the program header.
        if (phdr.p_filesz > phdr.p_memsz) return Error.InvalidElf;
        if (!urd.mem.isUserAddress(va_start_aligned)) return Error.InvalidElf;

        // Map the segment (as temporary attributes) and copy file data.
        const memory = try th.vmm.map(
            va_start_aligned,
            size_aligned,
            .rw,
        );

        // Read segment data into mapped memory.
        const offset_in_memory = phdr.p_vaddr - va_start_aligned;
        const segment = memory[offset_in_memory..][0..phdr.p_memsz];
        reader.seekTo(phdr.p_offset);
        reader.interface.readSliceAll(segment[0..phdr.p_filesz]) catch return error.InvalidElf;

        // Zero clear the remaining memory.
        @memset(memory[0..offset_in_memory], 0);
        @memset(segment[phdr.p_filesz..], 0);

        // Update attributes.
        try th.vmm.remap(
            va_start_aligned,
            size_aligned,
            getAttribute(phdr),
        );

        // Update program break.
        brk = @max(brk, va_end_aligned);
    }

    return .{
        .entry = ehdr.entry,
        .brk = brk,
        .phdr_addr = phdr_addr,
        .phdr_entsize = ehdr.phentsize,
        .phdr_num = ehdr.phnum,
    };
}

/// Implements std.Io.Reader interface for reading ELF files.
const Reader = struct {
    /// File to read from.
    file: *fs.File,
    /// Current logical position.
    pos: usize,
    /// Reader interface.
    interface: std.Io.Reader,

    const vtable = std.Io.Reader.VTable{
        .stream = stream,
    };

    pub fn init(file: *fs.File, buf: []u8) Reader {
        return .{
            .file = file,
            .pos = 0,
            .interface = .{
                .vtable = &vtable,
                .buffer = buf,
                .seek = 0,
                .end = 0,
            },
        };
    }

    /// Seek to the given offset in the file.
    pub fn seekTo(self: *Reader, offset: usize) void {
        // Discard the buffer and update the position.
        self.interface.tossBuffered();
        self.pos = offset;
    }

    fn stream(reader: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *Reader = @alignCast(@fieldParentPtr("interface", reader));
        const dest = limit.slice(w.writableSliceGreedy(1) catch return error.WriteFailed);
        const n = self.file.ops.read(
            self.file,
            dest,
            self.pos,
        ) catch return error.ReadFailed;

        self.pos += n;
        w.advance(n);

        return if (n != 0) n else error.EndOfStream;
    }
};

/// ELF program header iterator.
const PhdrIterator = struct {
    /// Current index.
    index: usize = 0,
    /// Reader for ELF binary.
    reader: *Reader,
    /// ELF header.
    ehdr: std.elf.Header,

    /// Create a new program header iterator.
    pub fn init(reader: *Reader, ehdr: std.elf.Header) PhdrIterator {
        return .{
            .reader = reader,
            .ehdr = ehdr,
        };
    }

    /// Get a next program header.
    ///
    /// Returns null if there is no more program header.
    pub fn next(self: *PhdrIterator) Error!?std.elf.Elf64_Phdr {
        if (self.index >= self.ehdr.phnum) return null;

        const phdr_offset: usize = self.ehdr.phoff + self.index * self.ehdr.phentsize;
        self.reader.seekTo(phdr_offset);
        const phdr = self.reader.interface.takeStruct(
            Elf64_Phdr,
            self.ehdr.endian,
        ) catch return Error.InvalidElf;

        self.index += 1;
        return phdr;
    }
};

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
