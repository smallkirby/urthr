pub const exception = @import("kernel/exception.zig");
pub const klog = @import("kernel/klog.zig");
pub const mem = @import("kernel/mem.zig");

/// APIs for early boot stage.
pub const boot = struct {
    const BootAllocator = @import("kernel/BootAllocator.zig");

    /// Early page allocator instance.
    var allocator: BootAllocator = undefined;

    /// Initialize the early page allocator.
    ///
    /// The buffer is reserved for early boot use only.
    ///
    /// This region should not overlap with the region reserved by Wyrd.
    pub fn initAllocator(start: usize, size: usize) void {
        const ptr: [*]u8 = @ptrFromInt(start);
        allocator.init(ptr[0..size]);
    }

    /// Get the early page allocator.
    pub fn getAllocator() *BootAllocator {
        return &allocator;
    }
};
