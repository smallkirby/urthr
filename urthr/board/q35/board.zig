pub const memmap = @import("memmap.zig");
pub const sync = @import("sync.zig");

/// Function signature of exception handler.
///
/// Returns null if the exception cannot be handled.
pub const ExceptionHandler = *const fn (u64) ?void;

/// Number of CPU cores in the system.
pub const num_cpus = 4;

/// Exception handler called when an IRQ occurs.
var exception_handler: ?ExceptionHandler = null;

/// Boot info handed over by the bootloader.
var boot_info: BootInfo = undefined;

/// PCIe ECAM.
var ecam: ?dd.pci.EcamHost = null;

/// Virtio block device instance.
var virtio_blk_dev: ?dd.VirtioBlk = null;

/// GOP framebuffer console instance.
var fb_console: FbConsole = undefined;

/// xHC device.
var xhc: ?*dd.usb.Xhc = null;

/// IDT vector assigned to the xHC interrupt.
const xhci_vector: u8 = 0x40;
/// IDT vector assigned to the virtio-net interrupt.
const virtio_net_vector: u8 = 0x41;
/// IDT vector assigned to the TLB shootdown IPI.
pub const tlb_shootdown_vector: u8 = 0x42;

/// Stash the loader-provided boot info for later use.
pub fn setBoardInfo(binfo_ptr: usize) void {
    const info: *const BootInfo = @ptrFromInt(binfo_ptr);
    boot_info = info.*;
}

/// Get available memory region that we can use for booting the kernel.
pub fn getBootRegion(comptime size: usize) common.Range {
    const map = boot_info.memory_map;

    const MemoryDescriptorIterator = BootInfo.MemoryDescriptorIterator;
    const efi_page_size = 4096;
    var desc_iter = MemoryDescriptorIterator.new(map);
    var desc = desc_iter.next();
    while (desc) |d| : (desc = desc_iter.next()) {
        if (d.type != .conventional_memory) {
            continue;
        }
        if (d.number_of_pages * efi_page_size < size) {
            continue;
        }

        return .{
            .start = d.physical_start,
            .end = d.physical_start + size,
        };
    }

    @panic("No available memory region found.");
}

/// Get the physical address kernel was loaded at.
pub fn getKernelPaddr() usize {
    return boot_info.kphys;
}

var dram_region: [64]common.Range = undefined;

/// Get the list of usable DRAM regions.
pub fn getDramRegion() []const common.Range {
    const map = boot_info.memory_map;

    const MemoryDescriptorIterator = BootInfo.MemoryDescriptorIterator;
    const efi_page_size = 4096;

    // Find all usable DRAM regions.
    var count: usize = 0;
    var desc_iter = MemoryDescriptorIterator.new(map);
    var desc = desc_iter.next();
    while (desc) |d| : (desc = desc_iter.next()) {
        switch (d.type) {
            .loader_code,
            .loader_data,
            .boot_services_code,
            .boot_services_data,
            .conventional_memory,
            => {},
            else => continue,
        }

        const start = d.physical_start;
        const end = start + d.number_of_pages * efi_page_size;

        // Merge adjacent regions.
        if (count > 0 and dram_region[count - 1].end == start) {
            dram_region[count - 1].end = end;
            continue;
        }

        dram_region[count] = .{ .start = start, .end = end };
        count += 1;

        // Discard any remaining regions if we exceed the maximum count.
        if (count == dram_region.len) {
            log.warn("Too many usable DRAM regions.", .{});
            break;
        }
    }

    // Find and reserve a low-memory for SMP trampoline blob.
    count = reserveLowMemory(
        &dram_region,
        count,
        util.roundup(arch.smp.trampolineSize(), urd.mem.page_size),
    );

    return dram_region[0..count];
}

/// Find and reserve a free, page-aligned physical page below 1MiB.
///
/// The number of usable DRAM regions are updated to reflect the reserved page.
///
/// Returns the updated region count.
fn reserveLowMemory(regions: []common.Range, count: usize, size: usize) usize {
    const lowmem_limit = 1 * units.mib;
    const page_size = urd.mem.page_size;

    rtt.expect(size % page_size == 0);

    for (regions[0..count], 0..) |*r, i| {
        const start = util.roundup(r.start, page_size);
        if (start + size > @min(r.end, lowmem_limit)) {
            continue;
        }

        // Reserve this region for the SMP trampoline.
        arch.smp.trampoline_phys = start;

        // Remove the reserved page from the list of usable DRAM regions.
        const hole_end = start + size;
        if (start == r.start and hole_end == r.end) {
            // The whole region is exactly the reserved page.
            var j = i;
            while (j + 1 < count) : (j += 1) regions[j] = regions[j + 1];
            return count - 1;
        } else if (start == r.start) {
            // At the beginning of the region.
            r.start = hole_end;
            return count;
        } else if (hole_end == r.end) {
            // At the end of the region.
            r.end = start;
            return count;
        } else {
            if (count == regions.len) {
                @panic("Cannot split a DRAM region.");
            }

            const tail: common.Range = .{ .start = hole_end, .end = r.end };
            r.end = start;

            var j = count;
            while (j > i + 1) : (j -= 1) regions[j] = regions[j - 1];
            regions[i + 1] = tail;
            return count + 1;
        }
    }

    @panic("No free page in low memory.");
}

/// Get the I/O regions that must be identity-mapped during boot.
pub inline fn getIoTempMaps() []const common.Range {
    return &.{};
}

/// Get the normal-memory regions that must be identity-mapped during boot.
pub inline fn getNormalTempMaps() []const common.Range {
    const base = @intFromPtr(boot_info.memory_map.descriptors);
    const end = base + boot_info.memory_map.buffer_size;
    return &[_]common.Range{.{
        .start = util.rounddown(base, PageAllocator.page_size),
        .end = util.roundup(end, PageAllocator.page_size),
    }};
}

/// Early board initialization.
///
/// Sets up essential peripherals like UART.
///
/// Expects all virtual address range is identity-mapped.
pub fn boot() void {
    dd.uart16550.setBase(0x3F8);
    dd.uart16550.init(1_843_200, 115_200); // 1.8432 MHz, 115200 bps
}

/// Map new I/O memory regions.
pub fn remapIo(_: IoAllocator) IoAllocator.Error!void {}

/// Move the memory map provided by EFI, out of its identity mapping.
pub fn remapNormal(old: PageAllocator, new: PageAllocator) common.mem.Error!void {
    const range = getNormalTempMaps()[0];
    const page_size = PageAllocator.page_size;
    const map_size = range.size();
    const npages = util.roundup(map_size, page_size) / page_size;

    // Copy the descriptors out of the temporary identity mapping.
    const buf = try new.allocPagesV(npages);
    const src: [*]const u8 = @ptrFromInt(old.translateV(range.start));
    @memcpy(buf[0..map_size], src[0..map_size]);
    boot_info.memory_map.descriptors = @ptrCast(buf.ptr);

    // Tear down the temporary identity mapping and reclaim the physical pages.
    const as = mem.getInitAddressSpace();
    try arch.mmu.unmap4kb(
        as,
        range.start,
        npages * page_size,
        .{},
        new,
    );
    for (0..npages) |i| {
        const page_ptr: [*]u8 = @ptrFromInt(range.start + i * page_size);
        new.freePagesP(page_ptr[0..page_size]);
    }
}

/// De-initialize loader resources.
pub fn deinitLoader() void {
    arch.gdt.globalInit();
}

/// Initialize peripherals.
///
/// This function is called before exceptions are enabled.
pub fn initPeripherals1() common.mem.Error!void {
    // Parse ACPI structures.
    {
        const allocator = urd.mem.page;

        // Find XSDT table.
        const rsdp = acpi.rsdp.parse(allocator.translateV(boot_info.rsdp)) orelse {
            @panic("Invalid RSDP structure.");
        };
        const xsdt = try acpi.xsdt.parse(
            rsdp.xsdt_address,
            allocator,
        ) orelse {
            @panic("Invalid XSDT structure.");
        };

        // Find MCFG table.
        const mcfgp = xsdt.find(.mcfg) orelse {
            @panic("MCFG table not found.");
        };
        log.debug("MCFG table @ 0x{X}", .{mcfgp});
        const mcfg = try acpi.mcfg.parse(mcfgp, allocator) orelse {
            @panic("Invalid MCFG structure.");
        };

        // Find PCIe ECAM region.
        if (mcfg.entries.len == 0) {
            @panic("No PCIe ECAM region found.");
        }
        {
            const ent = &mcfg.entries[0];
            const unit = 0x10_0000;
            const pci = try urd.mem.phys.reserveAndRemap(
                "PCIe ECAM",
                ent.base + unit * @as(u64, ent.start_bus),
                (@as(u64, ent.end_bus - ent.start_bus) + 1) * unit,
                null,
                .device,
            );
            ecam = dd.pci.EcamHost.init(pci);
        }
    }

    // APIC.
    {
        const lapic = try urd.mem.phys.reserveAndRemap(
            "LAPIC",
            arch.lapic.getBase(),
            0x1000,
            null,
            .device,
        );
        arch.lapic.setBase(lapic);
    }

    // Framebuffer.
    if (boot_info.fb) |fb| {
        const base = try urd.mem.phys.reserveAndRemap(
            "GOP framebuffer",
            fb.base,
            fb.size,
            null,
            .wc,
        );

        fb_console = .init(
            base,
            fb.base,
            fb.pitch,
            fb.width,
            fb.height,
            switch (fb.format) {
                .rgbx => .rgbx8888,
                .bgrx => .bgrx8888,
            },
            .{ .memcpy = null },
        );
        urd.console.addBackend(fb_console.interface()) catch |err| {
            log.warn("failed to add console backend: {t}", .{err});
        };
    } else {
        log.warn("No GOP framebuffer available.", .{});
    }
}

/// Result of bringing up a virtio-pci device's transport.
const VirtioScanResult = struct {
    /// Initialized virtio-pci transport.
    dev: *dd.virtio.pci,
    /// PCI address of the device.
    addr: dd.pci.DevAddr,
    /// Virtual base addresses of the BARs referenced by the capabilities.
    barmap: dd.virtio.pci.BarMap,
    /// MSI-X configuration.
    msix: dd.pci.MsixConfig,
};

/// Scan for a virtio-pci device by device ID and bring up its transport.
fn bringUpVirtioPci(
    /// PCI host controller.
    hc: dd.pci.Host,
    /// Requested device IDs.
    ids: []const u16,
) urd.mem.Error!?VirtioScanResult {
    // Scan for a virtio-blk device.
    var scan_buf: [16]dd.pci.ScanResult = undefined;
    const results = hc.scan(0, &scan_buf);
    const vdev = blk: for (results) |res| {
        if (res.vendor_id == dd.virtio.pci.vendor_id) {
            for (ids) |id| if (res.device_id == id) break :blk res;
        }
    } else {
        log.warn("No requested virtio PCI device found.", .{});
        return null;
    };

    // Parse BARs of the virtio-blk device.
    const io = hc.getTypedIo(vdev.addr, dd.pci.HeaderType0);
    var barbuf: [6]dd.pci.BarInfo = undefined;
    const bars = io.parseBars(&barbuf);
    log.info(
        "virtio PCI device#{X}:{X}:{X}, ID=0x{X:0>4}, {d} BARs",
        .{ vdev.addr.bus, vdev.addr.device, vdev.addr.function, vdev.device_id, bars.len },
    );

    // Locate the virtio-pci configuration structures via the capability list.
    const caps = dd.virtio.pci.findCaps(hc, vdev.addr);
    const region_ccfg = caps.common orelse {
        log.warn("common config capability not found.", .{});
        return null;
    };
    const region_notify = caps.notify orelse {
        log.warn("notify config capability not found.", .{});
        return null;
    };
    const region_dcfg = caps.device orelse {
        log.warn("device config capability not found.", .{});
        return null;
    };
    const msix = dd.pci.parseMsixConfig(hc, vdev.addr) orelse {
        log.warn("MSI-X capability not found.", .{});
        return null;
    };

    // Map every distinct BAR referenced by the capabilities.
    const bar_indices: [4]usize = .{
        region_ccfg.bar,
        region_notify.region.bar,
        region_dcfg.bar,
        msix.table_bar,
    };

    var barmap: dd.virtio.pci.BarMap = .{};
    for (bar_indices) |idx| {
        if (barmap.virt[idx] != 0) continue;

        const bar_info = for (bars) |b| {
            if (b.index == idx) break b;
        } else {
            log.warn("BAR#{d} not found.", .{idx});
            return null;
        };

        barmap.virt[idx] = try urd.mem.phys.reserveAndRemap(
            "virtio-pci BAR",
            bar_info.address,
            bar_info.size(),
            null,
            .device,
        );
    }

    // Bring up the transport and initialize virtio device.
    const dev = (dd.virtio.pci.init(
        hc,
        vdev.addr,
        caps,
        barmap,
        urd.mem.page,
        urd.mem.bin,
    ) catch |err| {
        log.warn("Failed to initialize virtio-pci device: {t}", .{err});
        return null;
    }) orelse {
        log.warn("Failed to initialize virtio-pci device.", .{});
        return null;
    };

    return .{
        .dev = dev,
        .addr = vdev.addr,
        .barmap = barmap,
        .msix = msix,
    };
}

/// Initialize peripherals phase 2.
///
/// This function is called after exceptions are enabled.
pub fn initPeripherals2() (urd.mem.Error || net.Error)!void {
    // virtio-blk
    if (ecam) |*e| outer: {
        // Scan for a virtio-blk device.
        const hc = e.interface();
        const result = (try bringUpVirtioPci(
            hc,
            &.{ dd.VirtioBlk.pci_device_id_legacy, dd.VirtioBlk.pci_device_id_modern },
        )) orelse break :outer;

        // Initialize virtio-blk device.
        virtio_blk_dev = dd.VirtioBlk.init(
            result.dev.interface(),
            mem.dma.interface(0),
            urd.mem.bin,
        ) catch |err| {
            log.warn("Failed to initialize virtio-blk: {t}", .{err});
            break :outer;
        };
    }

    // virtio-net
    if (ecam) |*e| outer: {
        // Scan for a virtio-net device.
        const hc = e.interface();
        const bringup = (try bringUpVirtioPci(
            hc,
            &.{ dd.net.VirtioNet.pci_device_id_legacy, dd.net.VirtioNet.pci_device_id_modern },
        )) orelse break :outer;

        // Initialize virtio-net device.
        const msix = bringup.msix;
        const netdev = dd.net.VirtioNet.new(
            bringup.dev.interface(),
            urd.mem.page,
            urd.mem.bin,
        ) catch |err| {
            log.warn("Failed to initialize virtio-net: {t}", .{err});
            break :outer;
        };
        urd.net.registerDevice(netdev);

        // Register MSI-X.
        const msg = arch.msi.buildMessage(
            virtio_net_vector,
            arch.lapic.getId(),
        );
        const table = dd.pci.MsixTable{
            .base = bringup.barmap.get(msix.table_bar) + msix.table_offset,
        };
        table.setEntry(0, msg.addr, msg.data);
        table.maskEntry(0, false);
        dd.pci.enableMsix(hc, bringup.addr, msix.cap_offset);

        // Bind the RX queue to MSI-X table entry #0.
        bringup.dev.setQueueVector(dd.net.VirtioNet.rxq_idx, 0) catch |err| {
            log.warn("Failed to bind virtio-net RX queue to MSI-X: {t}", .{err});
            break :outer;
        };
        try net.registerIrq(netdev, virtio_net_vector);

        // TODO: should we create an interface here?
        const iface = try urd.net.ip.Interface.create(
            .comptimeParse("0.0.0.0"),
            .comptimeParse("0.0.0.0"),
            urd.mem.bin,
        );
        try netdev.appendInterface(iface);
    }
}

/// Initialize peripherals.
///
/// This function is called after initial task is spawned.
/// This function can spawn new threads.
pub fn initPeripherals3() common.mem.Error!void {
    // xHC
    if (ecam) |*e| outer: {
        const hc = e.interface();

        // Scan for xHC device.
        var scan_buf: [16]dd.pci.ScanResult = undefined;
        const results = hc.scan(0, &scan_buf);
        const xhcdev: dd.pci.ScanResult = for (results) |res| {
            if (std.meta.eql(dd.usb.Xhc.class, res.class)) {
                break res;
            }
        } else break :outer;

        // Configure device command register.
        const io = hc.getTypedIo(xhcdev.addr, dd.pci.HeaderType0);
        io.modifyReg(dd.pci.HeaderCommandStatus, .{
            .memory_space_enable = true,
            .bus_master_enable = true,
        });

        // Check if BAR is valid.
        var barbuf: [1]dd.pci.BarInfo = undefined;
        const bar = blk: {
            const bars = io.parseBars(&barbuf);
            if (bars.len != barbuf.len) {
                break :outer;
            }
            if (bars[0].index != 0) {
                break :outer;
            }
            if (bars[0].type != .mem64) {
                break :outer;
            }

            break :blk bars[0];
        };

        // Configure BAR.
        const base, const phys = blk: {
            const phys_base = bar.address & bar.address_mask;
            const base = try mem.phys.reserveAndRemap(
                "xhc",
                phys_base,
                bar.size(),
                null,
                .device,
            );
            io.setBarAddress(bar, phys_base);

            break :blk .{ base, phys_base };
        };
        log.debug("xHC: BAR#{}: 0x{X} (size=0x{X}) -> 0x{X}", .{ bar.index, phys, bar.size(), base });

        // Initialize xHC driver.
        xhc = dd.usb.Xhc.init(base, xhci_vector, mem.dma.interface(0)) catch |err| {
            log.err("xHC initialization failed: {t}", .{err});
            break :outer;
        };

        // Register MSI-X.
        const msg = arch.msi.buildMessage(xhci_vector, arch.lapic.getId());
        const msix = dd.pci.parseMsixConfig(hc, xhcdev.addr) orelse {
            log.err("Failed to parse MSI-X configuration for xHC.", .{});
            break :outer;
        };
        const table = dd.pci.MsixTable{
            .base = base + msix.table_offset,
        };
        table.setEntry(0, msg.addr, msg.data);
        table.maskEntry(0, false);
        dd.pci.enableMsix(hc, xhcdev.addr, msix.cap_offset);
    }
    if (xhc) |x| outer: {
        x.reset() catch |err| {
            log.err("xHC reset failed: {t}", .{err});
            break :outer;
        };
        x.setup() catch |err| {
            log.err("xHC setup failed: {t}", .{err});
            break :outer;
        };

        x.run();

        x.scan() catch |err| {
            log.err("xHC scan failed: {t}", .{err});
            break :outer;
        };
    }
}

/// Prepare for waking up secondary cores.
///
/// Identity-maps a low-memory trampoline page.
pub fn prepareSubcoreWakeup() urd.mem.Error!void {
    // Map the trampoline page into kernel linear space.
    const va = try urd.mem.phys.reserveAndRemap(
        "SMP",
        arch.smp.trampoline_phys,
        urd.mem.page_size,
        null,
        .normal,
    );

    // Install the trampoline blob into the mapped page.
    const blob: [*]u8 = @ptrFromInt(va);
    arch.smp.installTrampoline(blob[0..urd.mem.page_size]);

    // Identity-map the trampoline page.
    try arch.mmu.map4kb(
        urd.mem.getInitAddressSpace(),
        .{
            .va = arch.smp.trampoline_phys,
            .pa = arch.smp.trampoline_phys,
            .size = urd.mem.page_size,
            .perm = .kernel_rwx,
            .attr = .normal,
        },
        .{},
        urd.mem.page,
    );
}

/// De-initialize resources used for waking up secondary cores.
///
/// Removes the identity mapping of the trampoline page.
pub fn deinitSubcoreWakeup() void {
    arch.mmu.unmap4kb(
        urd.mem.getInitAddressSpace(),
        arch.smp.trampoline_phys,
        urd.mem.page_size,
        .{},
        urd.mem.page,
    ) catch {};
}

/// Wakeup a secondary core.
///
/// This function returns before the core is actually awake.
/// The caller should wait for the core to be awake.
///
/// - core: Core number to wake up.
/// - entry: Virtual address of the entry point.
/// - stack: Virtual address of the stack pointer.
pub fn wakeSubcore(core: usize, entry: usize, stack: usize) urd.mem.Error!void {
    arch.smp.wakeSubcore(core, entry, stack);
}

/// Fill the given buffer with random data.
pub fn getRandom(buf: []u8) void {
    if (!arch.rng.isSupported()) {
        @panic("CPU does not support RNG");
    }

    for (buf) |*byte| {
        if (arch.rng.getRandom()) |val| {
            byte.* = @truncate(val);
            break;
        }
    }
}

/// Set the exception handler for IRQs.
pub fn initIrqGlobal(f: ExceptionHandler) void {
    // Set exception handler stub.
    exception_handler = f;

    // Set exception handler.
    arch.intr.setHandler(handleIrq);

    // Disable the legacy PIC in favor of the local/IO APIC.
    arch.pic.disable();
}

/// Vector delivered by the local APIC for spurious interrupts.
const spurious_vector: u8 = 0xFF;

/// Initialize interrupts for the calling AP.
pub fn initIrqLocal() PageAllocator.Error!void {
    arch.exception.initLocal();
    arch.lapic.enable(spurious_vector);

    // Unmask all maskable interrupts.
    arch.intr.unmaskAll();
}

/// Enable an interrupt by ID.
///
/// TODO: supports I/O APIC.
pub fn enableIrq(_: usize) void {}

/// Send an IPI to all cores except the caller.
pub fn sendIpiAll(vector: u64) void {
    arch.lapic.sendIpiAllExclSelf(@intCast(vector));
}

/// IRQ handler function.
fn handleIrq(vector: u64) ?void {
    if (exception_handler) |f| {
        const ret = f(vector);

        arch.lapic.eoi();

        if (urd.sched.shouldReschedule()) {
            urd.sched.reschedule();
        }

        return ret;
    } else {
        arch.lapic.eoi();
        return null;
    }
}

/// Get the block device interface.
pub fn getBlockDevice() ?common.block.Device {
    return if (virtio_blk_dev) |*dev|
        dev.interface()
    else
        null;
}

/// Get console instance.
///
/// This is a zero cost operation with no runtime overhead.
pub fn getConsole() Console {
    return .{
        .vtable = .{
            .putc = console.putc,
            .flush = console.flush,
        },
        .ctx = &.{},
    };
}

/// Trigger a system cold reset.
///
/// QEMU exit code becomes `status << 1 | 1`.
pub fn reset(status: u8) void {
    asm volatile (
        \\outb %[value], %[port]
        :
        : [value] "{al}" (status),
          [port] "N{d}" (0xF4),
        : .{ .memory = true });

    while (true) {
        arch.halt();
    }
}

/// Power off the system.
pub fn powerOff() noreturn {
    reset(0);

    while (true) {
        arch.halt();
    }
}

/// Get the command line passed by the host via a fw_cfg.
///
/// Callers are responsible for freeing the returned array and its contents.
pub fn getCmdline() !?[]const []const u8 {
    const fw = fwcfg.interface();
    const file = fw.lookupFile(urd.fwcfg_filename) orelse return null;
    if (file.size == 0) return null;

    const content = try fw.readFile(file, mem.bin);
    errdefer mem.bin.free(content);

    var it = common.util.ShellWordIterator.init(content);
    var argv: std.array_list.Aligned([]const u8, null) = .empty;
    while (it.next()) |word| {
        argv.append(mem.bin, word) catch break;
    }
    return argv.items;
}

/// Wrapper functions for console API.
const console = struct {
    fn putc(_: *anyopaque, c: u8) void {
        return dd.uart16550.putc(c);
    }

    fn flush(_: *anyopaque) void {
        return dd.uart16550.flush();
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.q35);
const arch = @import("arch").impl;
const BootInfo = @import("boot").BootInfo;
const common = @import("common");
const rtt = common.rtt;
const units = common.units;
const util = common.util;
const Console = common.Console;
const FbConsole = common.FbConsole;
const IoAllocator = common.mem.IoAllocator;
const PageAllocator = common.mem.PageAllocator;
const Pair = common.Pair;
const urd = @import("urthr");
const mem = urd.mem;
const net = urd.net;
const dd = @import("dd");

const acpi = @import("acpi.zig");
const fwcfg = @import("fwcfg.zig");
