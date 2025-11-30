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
/// Memory size in bytes.
const workbuf_size = wyrd_reserved.size();
/// Memory start address.
const workbuf_start = if (wyrd_reserved.start == 0) wyrd_reserved.start + 0x1000 else wyrd_reserved;
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
    _, const l0_1 = blk: {
        // Init L0 page table.
        const l0_0, const l0_1 = arch.mmu.init(allocator.interface()) catch {
            @panic("Failed to initialize MMU.");
        };

        // Identity mapping for DRAM.
        const dram = board.memmap.dram;
        arch.mmu.map1gb(
            l0_0,
            dram.start,
            dram.start,
            dram.size(),
            allocator.interface(),
        ) catch {
            @panic("Failed to map DRAM for Wyrd.");
        };
        log.info("Identity-mapped (DRAM): 0x{X:0>8} - 0x{X:0>8}", .{ dram.start, dram.end });

        // Identity mapping for UART.
        const uart = board.memmap.pl011;
        arch.mmu.map1gb(
            l0_0,
            uart.start,
            uart.start,
            uart.size(),
            allocator.interface(),
        ) catch {
            @panic("Failed to map UART for Wyrd.");
        };
        log.info("Identity-mapped (UART): 0x{X:0>8} - 0x{X:0>8}", .{ uart.start, uart.end });

        // Enable MMU.
        arch.mmu.enable(l0_0, l0_1);
        log.info("MMU enabled.", .{});

        break :blk .{ l0_0, l0_1 };
    };

    // Parse Urthr header and load the kernel.
    const kentry = blk: {
        const header: *const UrthrHeader = @ptrFromInt(@intFromPtr(&__end) + 0x10); // TODO: why +0x10
        if (!header.valid()) {
            @panic("Invalid Urthr header.");
        }

        // Print Urthr header info.
        log.info("Urthr header at 0x{X:0>8}", .{@intFromPtr(header)});
        log.info("  Magic    : {s}", .{header.magic});
        log.info("  Size     : 0x{X} bytes", .{header.size});
        log.info("  Load At  : 0x{X:0>16}", .{header.load_at});
        log.info("  Entry    : 0x{X:0>16}", .{header.entry});
        log.info("  Checksum : {s}", .{std.fmt.bytesToHex(header.checksum[0..], .upper)});

        // Validate checksum.
        const imgp: [*]const u8 = @ptrFromInt(@intFromPtr(header) + @sizeOf(UrthrHeader));
        if (std.mem.eql(u8, header.checksum[0..], &calculateChecksum(imgp[0..header.size]))) {
            log.info("Checksum valid.", .{});
        } else {
            log.info("Checksum invalid. Expected {s}", .{
                std.fmt.bytesToHex(calculateChecksum(imgp[0..header.size]), .upper),
            });
            @panic("Urthr checksum mismatch.");
        }

        // Load the kernel.
        break :blk loadKernel(header, l0_1);
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

/// Calculate the checksum of the given image.
fn calculateChecksum(img: []const u8) [boot.UrthrHeader.hash_size]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(img);

    var hash: [boot.UrthrHeader.hash_size]u8 = undefined;
    hasher.final(&hash);

    return hash;
}

/// Load kernel to the given physical memory and map the region.
fn loadKernel(header: *const UrthrHeader, l0: usize) *KernelEntry {

    // Copy kernel to the load address.
    {
        const size = header.size;
        const imgp: [*]const u8 = @ptrFromInt(@intFromPtr(header) + @sizeOf(UrthrHeader));
        const loadp: [*]u8 = @ptrFromInt(board.memmap.kernel_phys);

        @memcpy(loadp[0..size], imgp[0..size]);
        log.info("Copied Urthr kernel to 0x{X:0>16}", .{@intFromPtr(loadp)});
    }

    // Map kernel region.
    {
        const va = util.rounddown(header.load_at, units.gib);
        const pa = util.rounddown(board.memmap.kernel_phys, units.gib);
        const size = (board.memmap.kernel_phys + header.size) - pa;
        const aligned_size = util.roundup(size, units.gib);
        arch.mmu.map1gb(
            l0,
            pa,
            va,
            aligned_size,
            allocator.interface(),
        ) catch {
            @panic("Failed to map Urthr kernel region.");
        };
        log.info("Mapped Urthr kernel region: 0x{X:0>16} -> 0x{X:0>16}", .{ va, pa });
    }

    return @ptrFromInt(header.entry);
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
