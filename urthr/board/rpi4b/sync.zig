/// L1 d-cache.
const l1_dcache = CacheInfo{
    .size = 32 * 1024,
    .line_size = 64,
    .ways = 2,
};
/// L1 i-cache.
const l1_icache = CacheInfo{
    .size = 48 * 1024,
    .line_size = 64,
    .ways = 3,
};
/// L2 cache.
const l2_cache = CacheInfo{
    .size = 1024 * 1024,
    .line_size = 64,
    .ways = 16,
};

/// Clean all data cache lines to PoC.
pub fn cleanAllDataCache() void {
    arch.sync.cleanAllDataCacheByLevel(l1_dcache, 0);
    arch.sync.cleanAllDataCacheByLevel(l2_cache, 1);
}

// =============================================================
// Imports
// =============================================================

const arch = @import("arch").impl;
const CacheInfo = arch.sync.CacheInfo;
