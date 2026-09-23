/// Check and enable CPU features.
///
/// Called by every core during initialization.
export fn setupHead() callconv(.c) void {
    // Enable FSBASE / GSBASE instructions and SSE.
    {
        if (!bits.isset(cpuid.Leaf.query(.ext_feature, null).ebx, 0)) {
            halt();
        }

        var cr4 = am.readCr4();
        cr4.fsgsbase = true;
        am.writeCr4(cr4);
    }

    // Enable SMAP / SMEP.
    {
        if (!bits.isset(cpuid.Leaf.query(.ext_feature, null).ebx, 7)) {
            halt();
        }
        if (!bits.isset(cpuid.Leaf.query(.ext_feature, null).ebx, 20)) {
            halt();
        }

        var cr4 = am.readCr4();
        cr4.smap = true;
        cr4.smep = true;
        am.writeCr4(cr4);
    }

    // Initialize FPU.
    initFpu();
}

/// Initialize use of FPU / SIMD.
fn initFpu() void {
    if (!bits.isset(cpuid.Leaf.query(.version_info, null).ecx, 20)) {
        halt(); // SSE4_2
    }
    if (!bits.isset(cpuid.Leaf.query(.version_info, null).ecx, 26)) {
        halt(); // XSAVE
    }
    if (!bits.isset(cpuid.Leaf.query(.version_info, null).ecx, 28)) {
        halt(); // AVX
    }

    {
        var cr4 = am.readCr4();
        cr4.osfxsr = true;
        cr4.osxmmexcpt = true;
        cr4.osxsave = true;
        am.writeCr4(cr4);
    }
    if (!bits.isset(cpuid.Leaf.query(.version_info, null).ecx, 27)) {
        halt(); // OSXSAVE
    }

    {
        var xcr0 = am.readXcr0();
        xcr0.x87 = true;
        xcr0.sse = true;
        xcr0.avx = true;
        am.writeXcr0(xcr0);
    }
}

inline fn halt() void {
    asm volatile (
        \\1:
        \\hlt
        \\jmp 1b
    );
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const bits = common.bits;
const am = @import("asm.zig");
const cpuid = @import("cpuid.zig");
