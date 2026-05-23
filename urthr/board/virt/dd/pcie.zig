//! PCIe ECAM driver for QEMU virt machine.

/// Base address of PCIe ECAM space.
var ecam_base: usize = 0;

// DMA allocator for PCIe devices.
var dma_allocator: dd.pci.DmaAllocatorImpl = undefined;

/// Set the base address of PCIe ECAM space.
pub fn setBase(base: usize) void {
    ecam_base = base;
}

/// Initialize the PCIe driver.
pub fn init(page_allocator: PageAllocator) void {
    dma_allocator = .new(page_allocator);
}

/// Get the I/O interface for PCIe Type 0 configuration space access.
pub fn getConfIoType0() dd.pci.ConfIo(dd.pci.HeaderType0) {
    return dd.pci.ConfIo(dd.pci.HeaderType0){ .method = .{
        .ecam = .{ .base = ecam_base },
    } };
}

/// Get the I/O interface for PCIe Type 1 configuration space access.
pub fn getConfIoType1() dd.pci.ConfIo(dd.pci.HeaderType1) {
    return dd.pci.ConfIo(dd.pci.HeaderType1){ .method = .{
        .ecam = .{ .base = ecam_base },
    } };
}

/// Get the DMA allocator for PCIe devices.
pub fn getDmaAllocator() DmaAllocator {
    return dma_allocator.interface(0);
}

/// Scan the PCIe devices on the specified bus.
pub fn scan(out: []dd.pci.ScanResult, bus: dd.pci.BusNum) []const dd.pci.ScanResult {
    return dd.pci.scanBus(getConfIoType0(), bus, out);
}

// =============================================================
// Imports
// =============================================================

const DmaAllocator = common.mem.DmaAllocator;
const PageAllocator = common.mem.PageAllocator;
const common = @import("common");
const dd = @import("dd");
