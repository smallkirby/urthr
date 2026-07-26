/// PCI Express memory-mapped configuration space base address description table.
pub const Mcfg = struct {
    /// SDT header.
    header: SdtHeader,
    /// Configuration space base address allocations, one per PCI segment group.
    entries: []const McfgEntry,

    /// Page allocator.
    allocator: PageAllocator,
};

/// Entry of MCFG table.
///
/// Describes the ECAM region for a single PCI segment group.
const McfgEntry = extern struct {
    /// Physical base address of the ECAM region for this segment group.
    base: u64,
    /// PCI segment group.
    segment_group: u16,
    /// First bus number decoded by this ECAM region.
    start_bus: u8,
    /// Last bus number decoded by this ECAM region.
    end_bus: u8,
    /// Reserved.
    reserved: u32,

    __end: void,

    comptime {
        if (size() != 16) {
            @compileError("Invalid MCFG entry size.");
        }
    }

    /// Get the size of the MCFG entry structure.
    fn size() usize {
        return @offsetOf(McfgEntry, "__end");
    }
};

/// Parse MCFG structure pointed to by the given physical address.
pub fn parse(phys: usize, allocator: PageAllocator) PageAllocator.Error!?Mcfg {
    const virt = allocator.translateV(phys);
    var header: SdtHeader = undefined;
    @memcpy(
        std.mem.asBytes(&header)[0..SdtHeader.size()],
        @as([*]const u8, @ptrFromInt(virt))[0..SdtHeader.size()],
    );

    // Validate SDT header.
    if (!header.is(.mcfg)) {
        log.err("Invalid MCFG signature.", .{});
        return null;
    }
    if (header.calcSum(virt) != 0) {
        log.err("Invalid MCFG checksum.", .{});
        return null;
    }
    if (header.revision != 1) {
        log.err("Unsupported MCFG revision: {d}", .{header.revision});
        return null;
    }

    // Size in bytes of the reserved field right after the SDT header.
    const reserved_size = 8;

    // Copy MCFG entries (skip the reserved field right after the header).
    const entries_offset = SdtHeader.size() + reserved_size;
    const entries_size = header.length - entries_offset;
    const addr = virt + entries_offset;
    const len = entries_size / McfgEntry.size();
    const entries = try allocator.alloc(McfgEntry, len);
    @memcpy(entries, @as([*]align(1) const McfgEntry, @ptrFromInt(addr))[0..len]);

    return .{
        .header = header,
        .entries = entries,
        .allocator = allocator,
    };
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.mcfg);
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;

const sdt = @import("sdt.zig");
const SdtHeader = sdt.SdtHeader;
