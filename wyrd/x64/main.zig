//! Wyrd: UEFI bootloader for x64 Urthr OS.

/// Override the standard options.
pub const std_options = std.Options{
    // Logging
    .logFn = klog.log,
    .log_level = klog.log_level,
};

/// Kernel entry point signature.
const KernelEntry = fn (boot_info: usize) callconv(.{ .x86_64_sysv = .{} }) noreturn;

/// Entry point for Wyrd bootloader.
pub fn main() uefi.Status {
    zmain() catch |e| {
        log.err("Failed to boot: {t}", .{e});
        return .aborted;
    };

    return .success;
}

/// Path to Urthr kernel ELF on the EFI System Partition.
const kernel_path = "efi\\boot\\remote";

fn zmain() !void {
    // Initialize SimpleTextOutput.
    const con_out = uefi.system_table.con_out orelse {
        return error.TextOutput;
    };
    try con_out.clearScreen();

    // Initialize logging.
    klog.init(con_out);
    log.info("Booting Wyrd.", .{});

    // Get boot services.
    log.info("Locating boot services.", .{});
    const bs: *BootServices = uefi.system_table.boot_services orelse {
        return error.BootServices;
    };

    // Locate simple file system protocol.
    log.info("Locating simple file system protocol.", .{});
    const fs = try bs.locateProtocol(
        uefi.protocol.SimpleFileSystem,
        null,
    ) orelse return error.FileSystem;

    // Open volume.
    log.info("Opening filesystem volume.", .{});
    var root_dir = try fs.openVolume();

    // Open kernel file.
    log.info("Opening kernel file.", .{});
    const kernel_file = try root_dir.open(
        &toUcs2(kernel_path),
        .read,
        .{},
    );
    const kernel_size = try getFileSize(kernel_file);

    log.info("Reading kernel image.", .{});
    const kimage = try bs.allocatePool(.loader_data, kernel_size);
    if (kimage.len != kernel_size) {
        return error.OutOfMemory;
    }
    {
        const nread = try kernel_file.read(kimage);
        if (nread != kernel_size) {
            return error.ReadFailed;
        }
    }

    // Load Urthr kernel.
    log.info("Loading Urthr kernel.", .{});
    const linfo = try MemWyrd.load(bs, kimage);
    const header = linfo.header;

    // Parse Urthr header and map the kernel.
    const kentry = blk: {
        // Print Urthr header info.
        log.info("Urthr Header", .{});
        log.info("  Magic    : {s}", .{header.magic});
        log.info("  Size     : 0x{X} bytes", .{header.size});
        log.info("  Mem Size : 0x{X} bytes", .{header.mem_size});
        log.info("  Load At  : 0x{X:0>16}", .{header.load_at});
        log.info("  Entry    : 0x{X:0>16}", .{header.entry});
        log.info("  Checksum : {s}", .{std.fmt.bytesToHex(header.checksum[0..], .upper)});

        // Map the kernel to the specified virtual address.
        break :blk try mapKernel(bs, header, linfo.kphys);
    };

    // Clean up.
    try kernel_file.close();
    try root_dir.close();

    // Get memory map.
    var map = try getMemoryMap(bs);

    // Exit boot services.
    log.info("Exiting boot services.", .{});
    bs.exitBootServices(uefi.handle, map.map_key) catch |e| {
        log.info("Retrying exit boot services: {t}", .{e});
        map = try getMemoryMap(bs);
        try bs.exitBootServices(uefi.handle, map.map_key);
    };

    // Jump to the kernel entry point.
    {
        const info = BootInfo{
            .memory_map = map,
        };
        kentry(@intFromPtr(&info));
    }

    // Unreachable.
    while (true) {
        asm volatile ("hlt");
    }
    unreachable;
}

/// Get a file size.
fn getFileSize(file: *const File) !usize {
    var buf: [256]u8 align(@alignOf(File.Info.File)) = undefined;
    const info_size = try file.getInfoSize(.file);
    if (info_size > buf.len) {
        return error.BufferTooSmall;
    }

    const info = try file.getInfo(.file, buf[0..]);
    return info.file_size;
}

/// Get memory map from UEFI boot services.
fn getMemoryMap(bs: *BootServices) !MemoryMap {
    const buffer_size = 4096 * 4;
    const buffer = try bs.allocatePool(.loader_data, buffer_size);
    const slice = try bs.getMemoryMap(buffer);

    return .{
        .buffer_size = buffer_size,
        .descriptors = @ptrCast(@alignCast(slice.ptr)),
        .map_size = slice.info.len * slice.info.descriptor_size,
        .map_key = slice.info.key,
        .descriptor_size = slice.info.descriptor_size,
        .descriptor_version = slice.info.descriptor_version,
    };
}

/// Convert ASCII string to UCS-2 slice.
fn toUcs2(comptime s: [:0]const u8) [s.len:0]u16 {
    var buf: [s.len:0]u16 = undefined;
    for (s, 0..) |c, i| buf[i] = c;
    buf[s.len] = 0;
    return buf;
}

/// Map the Urthr kernel into memory and return the entry point.
fn mapKernel(bs: *BootServices, header: UrthrHeader, kphys: usize) !*KernelEntry {
    // Set the page table to be writable.
    try mmu.setLv4Writable(bs);

    // Map kernel region.
    const page_size = 4 * units.kib;
    const va = util.rounddown(header.load_at, page_size);
    const pa = util.rounddown(kphys, page_size);
    const size = (kphys + header.mem_size) - pa;
    const aligned_size = util.roundup(size, page_size);

    var mapped: usize = 0;
    while (mapped < aligned_size) : (mapped += 4096) {
        mmu.map4kTo(va + mapped, pa + mapped, .rw, bs) catch |e| {
            log.err("Failed to map kernel: {t}", .{e});
            return error.MapFailed;
        };
    }

    return @ptrFromInt(header.entry);
}

/// Result of loading the Urthr kernel image into physical memory.
const LoadInfo = struct {
    /// Urthr header.
    header: UrthrHeader,
    /// Physical address the kernel was loaded at.
    kphys: usize,
};

/// Urthr kernel loader that loads the image from the given memory.
const MemWyrd = struct {
    pub fn load(bs: *BootServices, image: []const u8) !LoadInfo {
        const header: *const UrthrHeader = @ptrCast(@alignCast(image.ptr));
        if (!header.valid()) {
            return error.InvalidHeader;
        }

        // Find and allocate contiguous physical memory to load the kernel into.
        const kpages = util.roundup(header.mem_size, mmu.page_size_4k) / mmu.page_size_4k;
        const mem = try bs.allocatePages(.any, .loader_data, kpages);
        const kphys = @intFromPtr(mem.ptr);

        // Copy to the load address while decoding if needed.
        const source = image[@sizeOf(UrthrHeader)..];
        const loadp: [*]u8 = @ptrFromInt(kphys);
        switch (header.encoding) {
            // No encoding. Just copy.
            .none => {
                @memcpy(loadp[0..header.size], source[0..header.size]);
            },
            // zlib compression.
            .zlib => {
                var reader = std.Io.Reader.fixed(source[0..header.encoded_size]);
                var flate_buf: [std.compress.flate.max_window_len]u8 = undefined;
                var flate = std.compress.flate.Decompress.init(&reader, .zlib, &flate_buf);
                try flate.reader.readSliceAll(loadp[0..header.size]);
            },
        }

        // Validate checksum.
        var reader = std.Io.Reader.fixed(loadp[0..header.size]);
        const checksum = try UrthrHeader.calcChecksum(&reader);
        if (!std.mem.eql(u8, header.checksum[0..], &checksum)) {
            return error.InvalidChecksum;
        }

        return .{ .header = header.*, .kphys = kphys };
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.wyrd);
const uefi = std.os.uefi;
const BootServices = uefi.tables.BootServices;
const File = uefi.protocol.File;
const boot = @import("boot");
const UrthrHeader = boot.UrthrHeader;
const BootInfo = boot.BootInfo;
const MemoryMap = BootInfo.MemoryMap;
const common = @import("common");
const units = common.units;
const util = common.util;
const klog = @import("klog.zig");
const mmu = @import("mmu.zig");
