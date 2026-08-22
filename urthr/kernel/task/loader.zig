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
    /// Interpreter path.
    interp: ?[]const u8 = null,
    /// Load bias.
    bias: usize,
    /// Entry point address.
    entry: usize,
    /// Entry point address of the main executable.
    ///
    /// Specified when the main executable is loaded by an interpreter.
    entry2: ?usize = null,
    /// Program break.
    brk: usize,
    /// Virtual address of program header table (AT_PHDR).
    phdr_addr: usize,
    /// Size of one program header entry (AT_PHENT).
    phdr_entsize: usize,
    /// Number of program header entries (AT_PHNUM).
    phdr_num: usize,
    /// Thread pointer value.
    tp: usize,
    /// Effective UID if set.
    setuid: ?u32 = null,
    /// Effective GID if set.
    setgid: ?u32 = null,

    /// Release resources allocated for the load information.
    pub fn deinit(self: *const LoadInfo) void {
        if (self.interp) |interp| {
            urd.mem.bin.free(interp);
        }
    }
};

/// Maximum number of bytes inspected while looking for a shebang line.
const shebang_buf_size = 128;

/// A parsed shebang directive.
pub const Shebang = struct {
    /// Interpreter path.
    interp: []u8,
    /// Optional argument to the interpreter.
    arg: ?[]u8,
};

/// Checks whether `filename` starts with a shebang directive and parses it.
///
/// Returns null if the file does not start with shebang.
/// Caller is responsible for freeing the returned resource.
pub fn parseShebang(filename: []const u8, allocator: Allocator) Error!?Shebang {
    const file = try fs.open(
        filename,
        .read_only,
        allocator,
    );
    defer file.unref();

    // Check if the first line has a shebang directive.
    var buf: [shebang_buf_size]u8 = undefined;
    const data = try file.read(&buf);
    if (data.len < 2 or data[0] != '#' or data[1] != '!') return null;

    // Trim to get the first line.
    const line_end = std.mem.indexOfScalar(u8, data, '\n') orelse data.len;
    const trimmed = std.mem.trim(u8, data[2..line_end], " \t\r");
    if (trimmed.len == 0) return Error.InvalidElf;

    // Split the line into interpreter and optional argument.
    const sep = std.mem.indexOfAny(u8, trimmed, " \t");
    const interp_str = if (sep) |s| trimmed[0..s] else trimmed;
    const arg_str = if (sep) |s| std.mem.trim(u8, trimmed[s..], " \t") else "";

    const interp = try allocator.dupe(u8, interp_str);
    errdefer allocator.free(interp);
    const arg = if (arg_str.len != 0) try allocator.dupe(u8, arg_str) else null;
    errdefer if (arg) |a| allocator.free(a);

    return .{ .interp = interp, .arg = arg };
}

/// Load an ELF executable from the filesystem.
pub fn load(th: *Thread, filename: []const u8) Error!LoadInfo {
    const main_hint = 0x0100_0000;
    const dyn_hint = 0x2_0000_0000;

    // Load main executable image.
    const main_info = try loadImage(th, filename, main_hint);
    defer main_info.deinit();
    var info = main_info;

    // Load interpreter if specified.
    if (main_info.interp) |interp| {
        const interp_info = try loadImage(th, interp, dyn_hint);
        defer interp_info.deinit();

        info.bias = interp_info.bias;
        info.entry = interp_info.entry;
        info.entry2 = main_info.entry;
        info.interp = null;
    }

    return info;
}

/// Load an ELF image.
///
/// The load address is chosen based on the given hint from the free virtual address space.
fn loadImage(th: *Thread, filename: []const u8, hint: usize) Error!LoadInfo {
    const file = try fs.open(filename, .read_only, urd.mem.bin);
    defer file.unref();
    if (file.size() < @sizeOf(Elf64_Ehdr)) return Error.InvalidElf;

    // Create a ELF file reader.
    var rbuf: [1024]u8 = undefined;
    var reader = Reader.init(file, &rbuf);

    // Validate ELF header.
    const ehdr = std.elf.Header.read(&reader.interface) catch return Error.InvalidElf;
    if (!ehdr.is_64) return Error.InvalidElf;
    if (ehdr.endian != builtin.cpu.arch.endian()) return Error.InvalidElf;
    if (ehdr.phentsize != @sizeOf(Elf64_Phdr)) return Error.InvalidElf;

    switch (ehdr.type) {
        .EXEC, .DYN => {},
        else => return Error.InvalidElf,
    }

    // Decide the load bias.
    const bias = switch (ehdr.type) {
        // Always load at the specified address.
        .EXEC => 0,
        // Find a free region to load the binary.
        .DYN => blk: {
            var iter = PhdrIterator.init(&reader, ehdr);
            const pt_range = try calcLoadRange(&iter);
            const base = th.vmm.findFreeRegion(hint, pt_range.size());
            break :blk base - pt_range.start;
        },
        else => unreachable,
    };

    // Initialize load information.
    const mode = file.getMode();
    var info = std.mem.zeroInit(LoadInfo, .{
        .interp = null,
        .bias = bias,
        .entry = ehdr.entry + bias,
        .phdr_entsize = ehdr.phentsize,
        .phdr_num = ehdr.phnum,
        .setuid = if (mode.flags.suid) file.getUid() else null,
        .setgid = if (mode.flags.sgid) file.getGid() else null,
    });

    // Scan program headers.
    var iter = PhdrIterator.init(&reader, ehdr);
    while (try iter.next()) |phdr| {
        // Find which PT_LOAD segment contains the phdr table.
        if (phdr.p_type == std.elf.PT_LOAD and info.phdr_addr == 0) {
            if (phdr.p_offset <= ehdr.phoff and ehdr.phoff < phdr.p_offset + phdr.p_filesz) {
                info.phdr_addr = phdr.p_vaddr + bias + (ehdr.phoff - phdr.p_offset);
            }
        }

        // Map each segment into memory.
        switch (phdr.p_type) {
            std.elf.PT_LOAD => {
                const end = try mapLoadSegment(phdr, th, bias, &reader);
                info.brk = @max(info.brk, end);
            },

            std.elf.PT_TLS => {
                rtt.expectEqual(0, info.tp);
                info.tp = try mapTlsSegment(phdr, th, bias);
            },

            std.elf.PT_INTERP => {
                if (phdr.p_filesz == 0) return Error.InvalidElf;
                var buf: [128]u8 = undefined;
                reader.seekTo(phdr.p_offset);
                reader.interface.readSliceAll(buf[0..phdr.p_filesz]) catch return Error.InvalidElf;
                info.interp = try urd.mem.bin.dupe(u8, buf[0 .. phdr.p_filesz - 1]);
            },

            else => continue,
        }
    }

    return info;
}

/// Maps a PT_LOAD segment of ELF.
///
/// Returns the program break after loading the segment.
fn mapLoadSegment(phdr: Elf64_Phdr, th: *Thread, bias: usize, reader: *Reader) Error!usize {
    const p_vaddr = phdr.p_vaddr + bias;
    const va_start_aligned = std.mem.alignBackward(usize, p_vaddr, urd.mem.page_size);
    const va_end_aligned = std.mem.alignForward(usize, p_vaddr + phdr.p_memsz, urd.mem.page_size);
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
    const offset_in_memory = p_vaddr - va_start_aligned;
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

    return va_end_aligned;
}

/// Maps a PT_TLS segment of ELF to the thread's TLS area.
///
/// Returns the thread pointer value.
fn mapTlsSegment(phdr: Elf64_Phdr, th: *Thread, bias: usize) Error!usize {
    const tcp_size = 16;

    const alignment = @max(phdr.p_align, 1);
    const data_size = std.mem.alignForward(usize, phdr.p_memsz, alignment);
    const total_size = std.mem.alignForward(usize, tcp_size + data_size, urd.mem.page_size);

    // Allocate TLS region.
    const tp_addr = try th.vmm.mapAnon(total_size, .rw);
    const tp = @as([*]u8, @ptrFromInt(tp_addr))[0..total_size];

    // Copy TLS initialization image from the loaded segment.
    const src = @as([*]const u8, @ptrFromInt(phdr.p_vaddr + bias))[0..phdr.p_filesz];
    @memcpy(tp[tcp_size..][0..phdr.p_filesz], src);

    // Zero-clear the remaining memory.
    @memset(tp[0..tcp_size], 0);
    @memset(tp[tcp_size + phdr.p_filesz ..], 0);

    return tp_addr;
}

/// Scan the program headers to find the range of PT_LOAD segments.
fn calcLoadRange(iter: *PhdrIterator) Error!common.Range {
    var start: usize = std.math.maxInt(usize);
    var end: usize = 0;
    while (try iter.next()) |phdr| {
        if (phdr.p_type != std.elf.PT_LOAD) continue;

        const pstart = std.mem.alignBackward(
            usize,
            phdr.p_vaddr,
            page_size,
        );
        const pend = std.mem.alignForward(
            usize,
            phdr.p_vaddr + phdr.p_memsz,
            page_size,
        );

        start = @min(start, pstart);
        end = @max(end, pend);
    }

    return .{ .start = start, .end = end };
}

// =============================================================
// Helpers
// =============================================================

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
const Allocator = std.mem.Allocator;
const Elf64_Ehdr = std.elf.Elf64_Ehdr;
const Elf64_Phdr = std.elf.Elf64_Phdr;
const log = std.log.scoped(.loader);
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const fs = urd.fs;
const page_size = urd.mem.page_size;
const Thread = urd.task.thread.Thread;
