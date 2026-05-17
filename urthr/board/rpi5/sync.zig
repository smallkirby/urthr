/// L1 d-cache.
const l1_dcache = CacheInfo{
    .size = 64 * 1024,
    .line_size = 64,
    .ways = 4,
};
/// L1 i-cache.
const l1_icache = CacheInfo{
    .size = 64 * 1024,
    .line_size = 64,
    .ways = 4,
};
/// L2 cache.
const l2_cache = CacheInfo{
    .size = 512 * 1024,
    .line_size = 64,
    .ways = 8,
};
/// L3 cache.
const l3_cache = CacheInfo{
    .size = 2048 * 1024,
    .line_size = 64,
    .ways = 16,
};

/// Clean all data cache lines to PoC.
pub fn cleanAllDataCache() void {
    arch.sync.cleanAllDataCacheByLevel(l1_dcache, 0);
    arch.sync.cleanAllDataCacheByLevel(l2_cache, 1);
    arch.sync.cleanAllDataCacheByLevel(l3_cache, 2);
}

/// Clean the data to POC.
pub fn cleanData(buf: []const u8) void {
    const line_size = 64;
    const start = @intFromPtr(buf.ptr);
    const end = start + buf.len;

    var addr = std.mem.alignBackward(usize, start, line_size);
    while (addr < end) : (addr += line_size) {
        arch.sync.cleanDataCacheLine(addr);
    }
}

/// Invalidate the data from PoC.
pub fn invalidateData(buf: []const u8) void {
    const line_size = 64;
    const start = @intFromPtr(buf.ptr);
    const end = start + buf.len;

    var addr = std.mem.alignBackward(usize, start, line_size);
    while (addr < end) : (addr += line_size) {
        arch.sync.invalidateDataCacheLine(addr);
    }
}

/// Clean and invalidate the data to/from PoC.
pub fn cleanAndInvalidateData(buf: []const u8) void {
    const line_size = 64;
    const start = @intFromPtr(buf.ptr);
    const end = start + buf.len;

    var addr = std.mem.alignBackward(usize, start, line_size);
    while (addr < end) : (addr += line_size) {
        arch.sync.cleanAndInvalidateDataCacheLine(addr);
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const arch = @import("arch").impl;
const CacheInfo = arch.sync.CacheInfo;
