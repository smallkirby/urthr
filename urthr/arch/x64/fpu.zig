/// Maximum size in bytes of the XSAVE region.
const size_state = 4096;
/// Required alignment of the XSAVE region.
const align_state = 64;

/// Mask indicating which state components of XSAVE are enabled.
const xsave_mask = std.mem.zeroInit(StateBitmap, .{
    .x87 = true,
    .sse = true,
    .avx = true,
});

/// Reset value of MXCSR register. See SDM Vol.1, 11.6.4.
const mxcsr_reset_intel: u32 = 0x1F80;

/// XSAVE state components bitmap.
const StateBitmap = packed struct(u64) {
    /// x87 state.
    x87: bool,
    /// SSE state.
    sse: bool,
    /// AVX state.
    avx: bool,
    /// MPX BNDREGS state.
    mpx_bnd: bool,
    /// MPX BNDCSR state.
    mpx_bndcsr: bool,
    /// AVX-512 opmask state.
    avx512_opmask: bool,
    /// AVX-512 ZMM_Hi256 state.
    avx512_zmm_hi256: bool,
    /// AVX-512 Hi16_ZMM state.
    avx512_hi16_zmm: bool,
    /// PT state.
    pt: bool,
    /// PKRU state.
    pkru: bool,
    /// Not used.
    _10: u54 = 0,
};

/// Type-erased representation of the XSAVE region.
const OpaqueXsaveRegion = [size_state]u8;

/// Initialize the FPU state and return a pointer to it.
///
/// First call of this function clobbers all of current FPU state.
pub fn initState(allocator: Allocator) Allocator.Error!*anyopaque {
    const state = try allocator.alloc(u8, size_state);
    rtt.expectEqual(0, @intFromPtr(state.ptr) % align_state);

    const clean = try getCleanXsaveRegion(allocator);
    @memcpy(state[0..size_state], clean[0..size_state]);

    return @ptrCast(state.ptr);
}

/// De-initialize the FPU state.
///
/// Releases the region allocated for the FPU state.
pub fn deinitState(state: *anyopaque, allocator: Allocator) void {
    const ptr: [*]const u8 = @ptrCast(state);
    const slice: []const u8 = ptr[0..size_state];
    allocator.free(slice);
}

/// Save the current FPU state into the given region.
pub fn saveState(state: *anyopaque) void {
    const mask: u64 = @bitCast(xsave_mask);
    asm volatile (
        \\xsave (%[ptr])
        :
        : [ptr] "r" (state),
          [masklo] "{eax}" (@as(u32, @truncate(mask >> 0))),
          [maskhi] "{edx}" (@as(u32, @truncate(mask >> 32))),
        : .{ .memory = true, .eax = true, .edx = true });
}

/// Restore the FPU state from the given region.
pub fn restoreState(state: *anyopaque) void {
    const mask: u64 = @bitCast(xsave_mask);
    asm volatile (
        \\xrstor (%[ptr])
        :
        : [ptr] "r" (state),
          [masklo] "{eax}" (@as(u32, @truncate(mask >> 0))),
          [maskhi] "{edx}" (@as(u32, @truncate(mask >> 32))),
        : .{ .memory = true, .eax = true, .edx = true });
}

/// Get the size in bytes of the XSAVE region.
fn getXsaveRegionSize() usize {
    const S = struct {
        var cached: ?usize = null;
    };

    if (S.cached) |ret| {
        return ret;
    } else {
        const size = cpuid.Leaf.query(.ext_enumeration, 0).ebx;
        S.cached = size;
        return size;
    }
}

/// Create a clean XSAVE region.
///
/// Newly created thread can use this region as its initial FPU state.
///
/// This function clobbers all of current FPU state on the first call.
fn getCleanXsaveRegion(allocator: Allocator) Allocator.Error!*align(align_state) OpaqueXsaveRegion {
    const S = struct {
        var cached: ?*align(align_state) OpaqueXsaveRegion = null;
    };

    if (S.cached) |ret| {
        return ret;
    } else {
        const region = try allocator.alloc(u8, size_state);
        rtt.expectEqual(0, @intFromPtr(region.ptr) % align_state);
        @memset(region, 0);

        const xsavep: usize = @intFromPtr(region.ptr);
        const mask: u64 = @bitCast(xsave_mask);
        asm volatile (
            \\
            // Initialize x87 state.
            \\fninit
            // Clear XMM, YMM, and ZMM.
            \\vzeroall
            // Reset MXCSR.
            \\ldmxcsr (%[mxcsr])
            // Save current clean state.
            \\xsave (%[ptr])
            :
            : [ptr] "r" (xsavep),
              [mxcsr] "r" (&mxcsr_reset_intel),
              [masklo] "{eax}" (@as(u32, @truncate(mask >> 0))),
              [maskhi] "{edx}" (@as(u32, @truncate(mask >> 32))),
            : .{ .memory = true, .eax = true, .edx = true });
        S.cached = @ptrFromInt(xsavep);

        return @ptrFromInt(xsavep);
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const Allocator = std.mem.Allocator;
const common = @import("common");
const rtt = common.rtt;
const am = @import("asm.zig");
const cpuid = @import("cpuid.zig");
const regs = @import("register.zig");
