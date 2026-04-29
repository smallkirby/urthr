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

// =============================================================
// Imports
// =============================================================

const arch = @import("arch").impl;
const CacheInfo = arch.sync.CacheInfo;
