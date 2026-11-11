/// Clean all data cache lines to PoC.
pub fn cleanAllDataCache() void {
    // no-op
}

/// Clean the data to POC.
pub fn cleanData(buf: []const u8) void {
    // no-op
    _ = buf;
}

/// Invalidate the data from PoC.
pub fn invalidateData(buf: []const u8) void {
    // no-op
    _ = buf;
}

/// Clean and invalidate the data to/from PoC.
pub fn cleanAndInvalidateData(buf: []const u8) void {
    // no-op
    _ = buf;
}
