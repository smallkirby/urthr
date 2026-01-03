//! Wyrd: Bootloader for Urthr OS
//!
//! The purpose of Wyrd is to load Urthr kernel and jump to it.
//! To achieve this, Wyrd performs the following tasks:
//!
//! 1. Initialize the minimum necessary hardware.
//! 2. Set up MMU with identity mapping for DRAM and UART.
//! 3. Load Urthr kernel from either serial connection or the tail of herself.
//! 4. Parse Urthr header and map the kernel to the specified virtual address.
//!
//! All jobs done by Wyrd should be regarded as "temporary",
//! that is, Urthr will take over the system right after Wyrd jumps to it.
//! Urthr should re-initialize the hardware, mapping, and all other things.
//! After the re-initialization, Urthr can use the resources used by Wyrd.

/// Override the standard options.
pub const std_options = std.Options{
    // Logging
    .logFn = klog.log,
    .log_level = klog.log_level,
};

/// Override the standard panic function.
pub const panic = @import("panic.zig").panic_fn;

/// Kernel entry point signature.
const KernelEntry = fn () callconv(.c) noreturn;

/// Reserved DRAM region for Wyrd bootloader.
const wyrd_reserved = board.memmap.loader_reserved;
/// Memory start address.
const workbuf_start = if (wyrd_reserved.start == 0) wyrd_reserved.start + 0x1000 else wyrd_reserved.start;
/// Memory end address.
const workbuf_end = wyrd_reserved.end;
/// Memory size in bytes.
const workbuf_size = workbuf_end - workbuf_start;
/// Pointer to the DRAM reserved for Wyrd bootloader.
const workbuf = @as([*]allowzero u8, @ptrFromInt(workbuf_start))[0..workbuf_size];

/// Page allocator instance.
var allocator: FixedAllocator = undefined;

/// Physical address of the end of the Wyrd binary.
extern const __end: *void;

/// Zig entry point for Wyrd bootloader.
///
/// Called from assembly code in head.S with MMU disabled in EL1.
export fn kmain() callconv(.c) noreturn {
    // Board early initialization.
    board.boot();

    // Set up kernel console.
    klog.set(board.getConsole());

    // Print boot message.
    log.info("Booting Wyrd.", .{});

    // Setup exception handling.
    {
        arch.exception.setConsole(board.getConsole());
        arch.exception.initLocal();
    }

    // Initialize page allocator.
    {
        allocator.init(workbuf);
        log.info(
            "Page allocator reserved 0x{X:0>8} - 0x{X:0>8}",
            .{ workbuf_start, workbuf_start + workbuf_size },
        );
    }

    // Identity map and enable MMU.
    {
        // Init L0 page table.
        arch.mmu.init(allocator.interface()) catch {
            @panic("Failed to initialize MMU.");
        };

        // Identity mapping for DRAM.
        const dram = board.memmap.drams[0];
        arch.mmu.map1gb(
            dram.start,
            dram.start,
            dram.size(),
            .kernel_rwx,
            .normal,
            allocator.interface(),
        ) catch {
            @panic("Failed to map DRAM for Wyrd.");
        };
        log.info("Identity-mapped (DRAM): 0x{X:0>8} - 0x{X:0>8}", .{ dram.start, dram.end });

        // Identity mapping for UART.
        const uart = board.memmap.pl011;
        arch.mmu.map1gb(
            uart.start,
            uart.start,
            uart.size(),
            .kernel_rw,
            .device,
            allocator.interface(),
        ) catch {
            @panic("Failed to map UART for Wyrd.");
        };
        log.info("Identity-mapped (UART): 0x{X:0>8} - 0x{X:0>8}", .{ uart.start, uart.end });

        // Enable MMU.
        arch.mmu.enable(allocator.interface());
        log.info("MMU enabled.", .{});
    }

    // Load Urthr kernel.
    const header = (if (common.options.serial_boot) blk: {
        log.info("Ready to receive Urthr kernel via serial.", .{});
        break :blk SrWyrd.startReceive();
    } else blk: {
        log.info("Loading Urthr kernel appended to Wyrd binary.", .{});
        break :blk MemWyrd.load();
    }) catch |err| {
        log.err("\n{s}", .{@errorName(err)});
        util.hexdump(board.memmap.kernel, 256, log.err);
        @panic("Failed to load Urthr kernel.");
    };

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
        break :blk mapKernel(header);
    };

    // Jump to the kernel entry point.
    {
        log.info("Jumping to Urthr kernel at 0x{X:0>16}", .{@intFromPtr(kentry)});
        kentry();
    }

    // Unreachable.
    log.err("Reached unreachable EOL.", .{});
    while (true) {
        arch.halt();
    }
}

/// Map the Urthr kernel into memory and return the entry point.
fn mapKernel(header: UrthrHeader) *KernelEntry {
    // Map kernel region.
    const page_size = 4 * units.kib;
    const va = util.rounddown(header.load_at, page_size);
    const pa = util.rounddown(board.memmap.kernel, page_size);
    const size = (board.memmap.kernel + header.mem_size) - pa;
    const aligned_size = util.roundup(size, page_size);
    arch.mmu.map4kb(
        pa,
        va,
        aligned_size,
        .kernel_rwx,
        .normal,
        allocator.interface(),
    ) catch {
        @panic("Failed to map Urthr kernel region.");
    };

    return @ptrFromInt(header.entry);
}

/// Load Urthr kernel appended to Wyrd binary.
const MemWyrd = struct {
    pub fn load() !UrthrHeader {
        const header: *const UrthrHeader = @ptrFromInt(getEndAddress());
        if (!header.valid()) {
            return error.InvalidHeader;
        }

        // Copy to the load address while decoding if needed.
        const phys: [*]u8 = @ptrFromInt(getEndAddress() + @sizeOf(UrthrHeader));
        const loadp: [*]u8 = @ptrFromInt(board.memmap.kernel);
        switch (header.encoding) {
            // No encoding. Just copy.
            .none => {
                @memcpy(loadp[0..header.size], phys[0..header.size]);
            },
        }

        // Validate checksum.
        var reader = std.Io.Reader.fixed(loadp[0..header.size]);
        const checksum = try UrthrHeader.calcChecksum(&reader);
        if (!std.mem.eql(u8, header.checksum[0..], &checksum)) {
            return error.InvalidChecksum;
        }

        return header.*;
    }
};

/// Load Urthr kernel via serial connection.
const SrWyrd = struct {
    pub fn startReceive() !UrthrHeader {
        defer {
            dd.pl011.putc('\r');
            dd.pl011.putc('\n');
        }

        // Wait for SYNC request.
        try waitForString("SYNC");
        try ack();

        // Receive Header.
        var header: UrthrHeader = undefined;
        try feed(std.mem.asBytes(&header));

        // Validate Header.
        if (!header.valid()) {
            return error.InvalidHeader;
        }
        try ack();

        // Receive binary at right after the Wyrd binary.
        const phys: [*]u8 = @ptrFromInt(getEndAddress());
        try feed(phys[0..header.encoded_size]);
        try ack();

        // Copy to the load address while decoding if needed.
        const loadp: [*]u8 = @ptrFromInt(board.memmap.kernel);
        switch (header.encoding) {
            // No encoding. Just copy.
            .none => {
                @memcpy(loadp[0..header.size], phys[0..header.size]);
            },
        }

        // Validate checksum.
        var reader = std.Io.Reader.fixed(loadp[0..header.size]);
        const checksum = try UrthrHeader.calcChecksum(&reader);
        if (!std.mem.eql(u8, header.checksum[0..], &checksum)) {
            return error.InvalidChecksum;
        }

        // Send COMPLETE response.
        try ack();

        return header;
    }

    fn waitForString(s: []const u8) !void {
        var match_idx: usize = 0;

        while (true) {
            const c = dd.pl011.getc();
            if (c == s[match_idx]) {
                match_idx += 1;
                if (match_idx == s.len) {
                    return;
                }
            } else {
                match_idx = 0;
            }
        }
    }

    fn feed(box: []u8) !void {
        var len: usize = 0;
        while (len < box.len) {
            box[len] = dd.pl011.getc();
            len += 1;
        }
    }

    fn ack() !void {
        for ("ACK") |c| {
            dd.pl011.putc(c);
        }
    }
};

/// Get the end address of the Wyrd binary.
fn getEndAddress() usize {
    return @intFromPtr(&__end) + 0x10; // TODO: why +0x10
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.wyrd);
const arch = @import("arch").impl;
const board = @import("board").impl;
const boot = @import("boot");
const UrthrHeader = boot.UrthrHeader;
const common = @import("common");
const units = common.units;
const util = common.util;
const dd = @import("dd");

const klog = @import("klog.zig");
const FixedAllocator = @import("FixedAllocator.zig");

// Force evaluate symbols exported but not referenced in Zig.
comptime {
    _ = arch;
}
