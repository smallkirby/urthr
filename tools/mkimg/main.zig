//! mkimg: Make a kernel image file.

pub fn main() !void {
    if (os.argv.len != 4 + 1) {
        log.err("Usage: {s} <wyrd> <urthr> <urthr.elf> <output>", .{os.argv[0]});
        return error.InvalidArgs;
    }

    const wyrd_path = std.mem.span(os.argv[1]);
    const urthr_path = std.mem.span(os.argv[2]);
    const urthr_elf_path = std.mem.span(os.argv[3]);
    const output_path = std.mem.span(os.argv[4]);

    // Open files.
    const wyrd = try fs.cwd().openFile(wyrd_path, .{});
    const urthr = try fs.cwd().openFile(urthr_path, .{});
    const urthr_elf = try fs.cwd().openFile(urthr_elf_path, .{});
    const kernel = try fs.cwd().createFile(output_path, .{});
    defer urthr.close();
    defer wyrd.close();
    defer urthr_elf.close();
    defer kernel.close();
    errdefer {
        fs.cwd().deleteFile(output_path) catch {
            log.err("Failed to delete output file: {s}", .{output_path});
        };
    }

    var rbuffer: [4096]u8 = undefined;
    var wbuffer: [4096]u8 = undefined;
    var kernel_writer = kernel.writer(wbuffer[0..]);
    const writer_if = &kernel_writer.interface;

    // Parse Urthr kernel.
    const load_addr, const entry = blk: {
        var urthr_elf_reader = urthr_elf.reader(&rbuffer);
        const header = try std.elf.Header.read(&urthr_elf_reader.interface);

        if (!header.is_64) {
            @panic("mkimg: Urthr ELF is not 64-bit.");
        }

        var piter = header.iterateProgramHeaders(&urthr_elf_reader);
        var min_seg_addr: u64 = std.math.maxInt(u64);
        while (try piter.next()) |ph| {
            if (ph.p_type != std.elf.PT_LOAD) continue;

            if (ph.p_vaddr < min_seg_addr) {
                min_seg_addr = ph.p_vaddr;
            }
        }

        break :blk .{ min_seg_addr, header.entry };
    };

    // Write Wyrd binary.
    {
        var wyrd_reader = wyrd.reader(&rbuffer);
        _ = try wyrd_reader.interface.streamRemaining(writer_if);

        try kernel_writer.interface.flush();
    }

    // Write Urthr header.
    {
        const urthr_size = (try urthr.stat()).size;
        var header = boot.UrthrHeader{
            .size = urthr_size,
            .load_at = load_addr,
            .checksum = undefined,
            .entry = entry,
        };
        try calculateChecksum(urthr, &header);

        _ = try writer_if.writeStruct(header, .little);

        try kernel_writer.interface.flush();
    }

    // Write Urthr binary.
    {
        var urthr_reader = urthr.reader(&rbuffer);
        _ = try urthr_reader.interface.streamRemaining(writer_if);

        try kernel_writer.interface.flush();
    }
}

/// Parse kernel ELF file and find load address.
fn findLoadAddress(elf: fs.File) !u64 {
    var rbuffer: [4096]u8 = undefined;
    var min_seg_addr = std.math.maxInt(u64);

    var elf_reader = elf.reader(&rbuffer);
    const header = try std.elf.Header.read(&elf_reader.interface);

    if (!header.is_64) {
        @panic("mkimg: Urthr ELF is not 64-bit.");
    }

    const piter = header.iterateProgramHeaders(elf_reader);
    while (try piter.next()) |ph| {
        if (ph.p_type != std.elf.PT_LOAD) continue;

        if (ph.p_vaddr < min_seg_addr) {
            min_seg_addr = ph.p_vaddr;
        }
    }

    return min_seg_addr;
}

/// Calculate checksum of the given image file.
fn calculateChecksum(img: fs.File, out: *boot.UrthrHeader) !void {
    var rbuffer: [4096]u8 = undefined;
    var input: [4096]u8 = undefined;

    var hasher = std.crypto.hash.Blake3.init(.{});
    var reader = img.reader(&rbuffer);

    while (true) {
        const n = try reader.interface.readSliceShort(input[0..]);
        hasher.update(input[0..n]);

        if (n < input.len) {
            break;
        }
    }

    hasher.final(out.checksum[0..]);
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.mkimg);
const fs = std.fs;
const os = std.os;
const boot = @import("boot");
