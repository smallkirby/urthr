/// Extended System Description Table.
pub const Xsdt = struct {
    /// SDT header.
    header: SdtHeader,
    /// Physical addresses of other SDTs.
    entries: []const u64,

    allocator: PageAllocator,

    /// Find the physical address of the table of the given kind of table.
    pub fn find(self: *const Xsdt, kind: sdt.Table) ?usize {
        for (self.entries) |entry| {
            const virt = self.allocator.translateV(entry);
            const header: *const SdtHeader = @ptrFromInt(virt);
            if (header.is(kind)) {
                return entry;
            }
        } else return null;
    }
};

/// Parse XSDT structure pointed to by the given physical address.
pub fn parse(phys: usize, allocator: PageAllocator) PageAllocator.Error!?Xsdt {
    const virt = allocator.translateV(phys);
    var header: SdtHeader = undefined;
    @memcpy(
        std.mem.asBytes(&header)[0..SdtHeader.size()],
        @as([*]const u8, @ptrFromInt(virt))[0..SdtHeader.size()],
    );

    // Validate SDT header.
    if (header.calcSum(virt) != 0) {
        log.err("Invalid XSDT checksum.", .{});
        return null;
    }
    if (!std.mem.eql(u8, "XSDT", &header.signature)) {
        log.err("Invalid XSDT signature.", .{});
        return null;
    }
    if (header.revision != 1) {
        log.err("Unsupported XSDT revision: {d}", .{header.revision});
        return null;
    }

    // Copy XSDT entries.
    const size = header.length - SdtHeader.size();
    const addr = virt + SdtHeader.size();
    const len = size / @sizeOf(u64);
    const entries = try allocator.alloc(u64, len);
    @memcpy(entries, @as([*]align(1) const u64, @ptrFromInt(addr))[0..len]);

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
const log = std.log.scoped(.xsdt);
const common = @import("common");
const PageAllocator = common.mem.PageAllocator;

const sdt = @import("sdt.zig");
const SdtHeader = sdt.SdtHeader;
