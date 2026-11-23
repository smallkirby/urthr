//! AMD IOMMU.
//!
//! ref. AMD I/O Virtualization Technology (IOMMU) Specification, 48882-PUB—Rev 3.11—Apr 2026

const Self = @This();

const Vi = mmio.Module(.{ .natural = u64 }, .{
    Reg(0x0000, TableBase),
    Reg(0x0008, CmdBufBase),
    Reg(0x0010, EventLogBase),
    Reg(0x0018, Control),
    Reg(0x0030, Efr),
    Reg(0x2000, CmdHead),
    Reg(0x2008, CmdTail),
    Reg(0x2010, EventLogHead),
    Reg(0x2018, EventLogTail),
    Reg(0x2020, Status),
});

/// Register module.
vi: Vi,

/// Device table.
dt: DeviceTable,
/// Command buffer.
cmdbuf: CmdBuf,
/// Event log.
evlog: EventLog,

/// Managed DMA allocator.
allocator: DmaAllocator,

pub const Error = common.mem.Error || error{
    /// Command buffer's ring buffer is full.
    RingFull,
};

/// Create a new AMD-Vi instance.
pub fn new(base: usize, allocator: DmaAllocator) Self {
    return .{
        .vi = .new(base),
        .dt = undefined,
        .cmdbuf = undefined,
        .evlog = undefined,
        .allocator = allocator,
    };
}

/// Initialize IOMMU with all devices passed through.
pub fn init(self: *Self) Error!void {
    // Allocate device table pages.
    self.dt = try DeviceTable.init(self.allocator);

    // Set the address of cleared device table.
    self.vi.write(TableBase, .init(self.dt.buf.bus, self.dt.buf.size));

    // Initialize command buffer.
    self.cmdbuf = try CmdBuf.init(self.vi, self.allocator);
    self.vi.write(CmdBufBase, .init(self.cmdbuf.buf.bus, CmdBuf.nents));
    self.vi.writei(CmdHead, 0);
    self.vi.writei(CmdTail, 0);

    // Initialize event log.
    self.evlog = try EventLog.init(self.vi, self.allocator);
    self.vi.write(EventLogBase, .init(self.evlog.buf.bus, EventLog.nents));
    self.vi.writei(EventLogHead, 0);
    self.vi.writei(EventLogTail, 0);

    // Enable IOMMU.
    self.vi.modify(Control, .{
        .en = true,
        .cmd_buf_en = true,
        .event_log_en = true,
    });
    self.vi.waitFor(Status, .{
        .cmd_buf_run = true,
        .event_log_run = true,
    }, null);

    if (urd.enable_rtt) {
        // Check if command queue is working.
        {
            try self.cmdbuf.push(.{ .completion_wait = .{
                .s = false,
                .i = false,
                .f = false,
                .store_address = 0,
                .store_data = 0,
            } });
            self.cmdbuf.sync();
            try self.cmdbuf.barrier();
            rtt.expectEqual(@sizeOf(Cmd) * 2, self.vi.read(CmdHead).ptr);
        }

        // Check if event logging is working.
        {
            try self.cmdbuf.push(@bitCast(@as(u128, 0xDEADBEEF)));
            self.cmdbuf.sync();
            try self.cmdbuf.barrier();

            if (self.evlog.pop()) |ev| {
                const code = ev.getCode();
                rtt.expectEqual(.illegal_command_error, code);
            } else {
                rtt.expect(false);
            }
            self.evlog.sync();
            self.restart();
        }
    }
}

/// Invalidate caches of the DeviceID.
///
/// Blocks until the request is processed by IOMMU.
pub fn inv(self: *Self, deviceid: DeviceId) Error!void {
    try self.cmdbuf.push(.{ .invalidate_devtab_entry = .{
        .deviceid = deviceid,
    } });
    self.cmdbuf.sync();
    try self.cmdbuf.barrier();
}

/// Blocks until the request is processed by IOMMU.
/// Invalidate all caches.
pub fn invall(self: *Self) Error!void {
    rtt.expectEqual(true, self.vi.read(Efr).ia_sup);

    try self.cmdbuf.push(.{ .invalidate_iommu_all = .{} });
    self.cmdbuf.sync();
    try self.cmdbuf.barrier();
}

/// Set device table entry.
pub fn setTableEntry(self: *Self, id: DeviceId, dte: DevTableEntry) Error!void {
    self.dt.set(id, dte);
    try self.inv(id);
}

/// Restart the IOMMU command processing after the IOMMU halts it.
///
/// All the commands in the command buffer are discarded.
fn restart(self: *Self) void {
    if (self.vi.read(Status).cmd_buf_run) {
        log.warn("restart() called while command processing is running", .{});
        return;
    }

    self.vi.waitFor(Status, .{
        .cmd_buf_run = false,
    }, null);
    self.vi.modify(Control, .{
        .cmd_buf_en = false,
    });

    // Head pointer position is implementation defined, so discard all commands.
    self.vi.writei(CmdHead, self.vi.readi(CmdTail));

    self.vi.modify(Control, .{
        .cmd_buf_en = true,
    });
    self.vi.waitFor(Status, .{
        .cmd_buf_run = true,
    }, null);
}

// =============================================================
// Device Table
// =============================================================

/// DeviceID derived from Peripheral RequesterID.
pub const DeviceId = u16;

/// The number of device table entries in a table.
const num_dt_ents = std.math.pow(usize, 2, @bitSizeOf(DeviceId));

/// Device table.
const DeviceTable = struct {
    /// Device table buffer.
    buf: DmaMemory,

    /// Managed DMA allocator.
    _dma: DmaAllocator,

    pub fn init(allocator: DmaAllocator) Error!DeviceTable {
        const buf = try allocator.alloc(DevTableEntry, num_dt_ents, .normal);
        @memset(buf.slice(DevTableEntry), std.mem.zeroes(DevTableEntry));
        allocator.syncForDeviceAll(buf);

        return .{
            .buf = buf,
            ._dma = allocator,
        };
    }

    /// Set a device table entry.
    pub fn set(self: *DeviceTable, id: DeviceId, dte: DevTableEntry) void {
        const entry = &self.buf.slice(DevTableEntry)[id];
        entry.* = dte;
        self._dma.syncForDeviceAny(entry);
    }
};

/// Device Table Entry.
const DevTableEntry = packed struct(u256) {
    /// Rest of this entry is valid.
    v: bool,
    /// Translation information valid.
    tv: bool,
    /// Reserved.
    _2: u2 = 0,
    /// CXL IO bits in ATS completions for CXL devices that implement the .cache interface.
    cxl_mem_attr: u3,
    /// Host Access Dirty.
    had: Had,
    /// Paging mode.
    mode: PagingMode,
    /// System physical address of the root page table for the I/O device for GPA-to-SPA translation.
    pgtbl_root: u40,
    /// PPR enable.
    ppr: bool,
    /// Guest PPR response with PASID.
    gprp: bool,
    /// Guest I/O protection valid.
    giov: bool,
    /// Guest translation valid.
    gv: bool,
    /// Guest levels translated.
    glx: u2,
    /// Guest CR3 table root pointer.
    gcr3trp: u3,
    /// I/O read permission.
    ir: bool,
    /// I/O write permission.
    iw: bool,
    /// Reserved.
    _63: u1 = 0,

    /// DomainID.
    /// 16-bit integer chosen by SW that the IOMMU must use to tag its internal translation caches and mark event log entries.
    domainid: u16,
    /// GCR3 Table Root Pointer.
    gcr3tbl_root_lo: u16,
    /// IOTLB enable.
    i: bool,
    /// Suppress I/O page fault events.
    se: bool,
    /// Suppress all I/O page fault events.
    sa: bool,
    /// Port I/O control.
    ioctl: u2,
    /// IOTLB cache hint.
    cache: bool,
    /// Snoop disable.
    sd: bool,
    /// Allow exclusion.
    ex: bool,
    /// System management message enable.
    sysmgt: u2,
    /// Secure ATS.
    sats: bool,
    /// GCR3 Table Root Pointer [51:31].
    gcr3tbl_root_hi: u21,

    /// Interrupt map valid.
    iv: bool,
    /// Interrupt table length.
    int_tab_len: u4,
    /// Ignore unmapped interrupts.
    ig: bool,
    /// Interrupt table root pointer.
    int_tab_root: u46,
    /// Reserved.
    _180: u2 = 0,
    /// Guest paging mode.
    gpmode: u2,
    /// INIT pass-through.
    init_pass: bool,
    /// ExtInt pass-through.
    eint_pass: bool,
    /// NMI pass-through.
    nmi_pass: bool,
    /// Host Page Table Mode Hint.
    hpt_mode: u1,
    /// Interrupt control.
    int_ctl: IntCtl,
    /// LINT0 pass-through.
    lint0pass: bool,
    /// LINT1 pass-through.
    lint1pass: bool,

    /// Reserved.
    _192: u15 = 0,
    /// Virtualize IOMMU enabled.
    vimu_en: bool,
    /// Guest DeviceID.
    gdeviceid: u16,
    /// GuestID.
    guestid: u16,
    /// Reserved.
    _240: u5 = 0,
    /// Reserved.
    _245: u1 = 0,
    /// Attribute override valid.
    attrv: bool,
    ///
    mode0fc: bool,
    ///
    snoop_attr: u8,

    /// Construct a DTE that translates a device address using the given I/O page table.
    pub fn translated(root: usize, mode: PagingMode, domain: u16) DevTableEntry {
        return std.mem.zeroInit(DevTableEntry, .{
            .v = true,
            .tv = true,
            .ir = true,
            .iw = true,
            .mode = mode,
            .pgtbl_root = @as(u40, @intCast(root >> 12)),
            .domainid = domain,
            .int_ctl = .unmapped,
        });
    }
};

/// Host Access Dirty.
const Had = enum(u2) {
    /// IOMMU does not set Access and Dirty bits in the host page table.
    none = 0b00,
    /// IOMMU sets Access bits in the host page table corresponding to peripheral requests.
    access = 0b01,
    /// IOMMU sets Access and Dirty bits in the host page table corresponding to peripheral requests.
    access_dirty = 0b11,
};

/// How IOMMU performs GPA-to-SPA translation.
const PagingMode = enum(u3) {
    /// Translation disabled.
    disable = 0b000,
    /// 1 Level Page Table (21-bit GPA)
    @"1" = 0b001,
    /// 2 Level Page Table (30-bit GPA)
    @"2" = 0b010,
    /// 3 Level Page Table (39-bit GPA)
    @"3" = 0b011,
    /// 4 Level Page Table (48-bit GPA)
    @"4" = 0b100,
    /// 5 Level Page Table (57-bit GPA)
    @"5" = 0b101,
    /// 6 Level Page Table (64-bit GPA)
    @"6" = 0b110,
};

/// Interrupt control.
const IntCtl = enum(u2) {
    /// Fixed and arbitrated interrupts target aborted.
    abort = 0b00,
    /// Fixed and arbitrated interrupts are forwarded unmapped.
    unmapped = 0b01,
    /// Fixed and arbitrated interrupts remapped.
    remap = 0b10,
};

// =============================================================
// Command
// =============================================================

/// IOMMU command buffer.
const CmdBuf = struct {
    /// DMA memory for the command buffer.
    buf: DmaMemory,
    /// Tail offset from the base of the command buffer.
    tail: u19,
    /// Store buffers for completion waits.
    barriers: DmaMemory,

    /// Managed DMA allocator.
    _dma: DmaAllocator,
    /// Module.
    _vi: Vi,

    /// Size in bytes of the command buffer.
    const buf_size = 4096;
    /// Unit size in bytes of a command.
    const unit = @sizeOf(Cmd);
    /// The number of command entries in the command buffer.
    pub const nents = buf_size / unit;

    /// Store data type.
    const Barrier = u64;
    /// Store data value.
    const store_data: Barrier = 0xDEADBEEF_CAFEBABE;

    pub fn init(vi: Vi, allocator: DmaAllocator) Error!CmdBuf {
        const buf = try allocator.allocBytes(buf_size, .normal);
        @memset(buf.slice(u8), 0);
        allocator.syncForDeviceAll(buf);

        const barriers = try allocator.alloc(Barrier, 1, .normal);
        @memset(barriers.slice(Barrier), 0);
        allocator.syncForDeviceAll(barriers);

        return .{
            .buf = buf,
            .tail = 0,
            .barriers = barriers,
            ._dma = allocator,
            ._vi = vi,
        };
    }

    /// Push a command into the command buffer.
    ///
    /// Tail pointer is not advanced until `sync()` is called.
    pub fn push(self: *CmdBuf, cmd: Cmd) Error!void {
        const head = self._vi.read(CmdHead).ptr;
        const next_tail = (self.tail +% unit) % buf_size;
        if (next_tail == head) {
            return Error.RingFull;
        }

        const cmds = self.buf.slice(Cmd);
        cmds[self.tail / unit] = cmd;
        self._dma.syncForDeviceAll(self.buf); // TODO: should not flush all
        self.tail = next_tail;
    }

    /// Synchronize the tail pointer with IOMMU.
    pub fn sync(self: *const CmdBuf) void {
        self._vi.writei(CmdTail, self.tail);
    }

    /// Blocks until all commands in the command buffer have completed.
    pub fn barrier(self: *CmdBuf) Error!void {
        try self.push(.{ .completion_wait = .{
            .s = true,
            .i = false,
            .f = false,
            .store_address = @intCast(self.barriers.bus >> 3),
            .store_data = store_data,
        } });
        self.sync();

        const b: *const volatile Barrier = &self.barriers.slice(Barrier)[0];
        while (b.* != store_data) {
            std.atomic.spinLoopHint();
            self._dma.syncForCpu(self.barriers.cpu, @sizeOf(Barrier));
        }

        self.barriers.slice(Barrier)[0] = 0;
        self._dma.syncForDevice(self.barriers.bus, @sizeOf(Barrier));
    }
};

/// IOMMU commands.
const Cmd = packed union {
    /// Serialize itself with IOMMU command processing.
    completion_wait: packed struct(u128) {
        /// Completion store.
        /// IOMMU writes the specified 64-bit Store Data value to the Store Address.
        s: bool,
        /// Completion interrupt.
        /// IOMMU sets ComWaitInt when the command completes.
        i: bool,
        /// Flush queue.
        /// If set, command queue is strictly executed in order, subsequent commands are not launched and executed until this command finishes.
        f: bool,
        /// Store address.
        /// IOMMU may store the Store Data value at this SPA.
        store_address: u49,
        /// Reserved.
        _52: u8 = 0,
        /// Opcode.
        code: CmdOpcode = .completion_wait,
        /// Store data.
        store_data: u64,
    },
    /// Invalidate Device Table entry of DeviceID from its internal caches.
    ///
    /// This command does not invalidate translation cache entries.
    /// When removing a device from a domain, SW must issue INVALIDATE_IOMMU_PAGES for the associated DomainID.
    invalidate_devtab_entry: packed struct(u128) {
        /// DeviceID.
        deviceid: DeviceId,
        /// Reserved.
        _16: u44 = 0,
        /// Opcode.
        code: CmdOpcode = .invalidate_devtab_entry,
        /// Reserved.
        _64: u64 = 0,
    },
    /// Not implemented yet.
    invalidate_iommu_pages: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    invalidate_iotbl_pages: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    invalidate_interrupt_table: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    prefetch_iommu_pages: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    complete_ppr_request: packed struct(u128) {
        _: u128,
    },
    /// Clear all address translation and interrupt remapping information from its translation caches.
    invalidate_iommu_all: packed struct(u128) {
        /// Reserved.
        _0: u60 = 0,
        /// Opcode.
        code: CmdOpcode = .invalidate_iommu_all,
        /// Reserved.
        _64: u64 = 0,
    },
    /// Not implemented yet.
    insert_guest_event: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    reset_vmmio: packed struct(u128) {
        _: u128,
    },

    comptime {
        std.debug.assert(@sizeOf(Cmd) == @sizeOf(u128));
    }
};

/// Generic Command Buffer Entry Format.
const CmdGeneric = packed struct(u128) {
    /// First opcode dependent operand.
    operand1: u60,
    /// Opcode.
    code: CmdOpcode,
    /// Second opcode dependent operand.
    operand2: u64,
};

const CmdOpcode = enum(u4) {
    /// COMPLETION_WAIT.
    completion_wait = 0x1,
    /// INVALIDATE_DEVTAB_ENTRY.
    invalidate_devtab_entry = 0x2,
    /// INVALIDATE_IOMMU_PAGES.
    invalidate_iommu_pages = 0x3,
    /// INVALIDATE_IOTLB_PAGES.
    invalidate_iotbl_pages = 0x4,
    /// INVALIDATE_INTERRUPT_TABLE.
    invalidate_interrupt_table = 0x5,
    /// PREFETCH_IOMMU_PAGES.
    prefetch_iommu_pages = 0x6,
    /// COMPLETE_PPR_REQUEST.
    complete_ppr_request = 0x7,
    /// INVALIDATE_IOMMU_ALL.
    invalidate_iommu_all = 0x8,
    /// INSERT_GUEST_EVENT.
    insert_guest_event = 0x9,
    /// RESET_VMMIO.
    reset_vmmio = 0xA,
};

// =============================================================
// Event Log
// =============================================================

/// IOMMU event log.
const EventLog = struct {
    /// DMA memory for the event log.
    buf: DmaMemory,
    /// Head offset from the base of the event log.
    head: u19,

    /// Managed DMA allocator.
    _dma: DmaAllocator,
    /// Module.
    _vi: Vi,

    /// Size in bytes of the event log.
    const buf_size = 4096;
    /// Unit size in bytes of a single event log entry.
    const unit = @sizeOf(Event);
    /// The number of log entries in the event log.
    pub const nents = buf_size / @sizeOf(Event);

    pub fn init(vi: Vi, allocator: DmaAllocator) Error!EventLog {
        const buf = try allocator.allocBytes(buf_size, .normal);
        @memset(buf.slice(u8), 0);
        allocator.syncForDeviceAll(buf);

        return .{
            .buf = buf,
            .head = 0,
            ._dma = allocator,
            ._vi = vi,
        };
    }

    /// Pop a single event from the event log.
    ///
    /// Returns null if the event log is empty.
    pub fn pop(self: *EventLog) ?Event {
        const tail = self._vi.read(EventLogTail).ptr;
        if (self.head == tail) return null;

        self._dma.syncForCpuAll(self.buf); // TODO: should not invalidate all
        defer self.head = (self.head +% unit) % buf_size;
        return self.buf.slice(Event)[self.head / unit];
    }

    /// Synchronize the head pointer with IOMMU.
    pub fn sync(self: *EventLog) void {
        self._vi.writei(EventLogHead, self.head);
    }
};

/// IOMMU event log entry.
const Event = packed union {
    /// Not implemented yet.
    illegal_dev_table_entry: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    io_page_fault: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    dev_tab_hardware_error: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    page_tab_hardware_error: packed struct(u128) {
        _: u128,
    },
    /// IOMMU reads an invalid command.
    /// Halts command processing.
    illegal_command_error: packed struct(u128) {
        /// Reserved.
        _0: u60 = 0,
        /// Event code.
        code: EventCode = .illegal_command_error,
        /// SPA of the invalid command.
        address: u64,
    },
    /// Not implemented yet.
    command_hardware_error: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    iotlb_inv_timeout: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    invalid_device_request: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    invalid_ppr_request: packed struct(u128) {
        _: u128,
    },
    /// Not implemented yet.
    event_counter_zero: packed struct(u128) {
        _: u128,
    },

    pub fn getCode(self: Event) EventCode {
        const generic: *const EventGeneric = @ptrCast(&self);
        return generic.code;
    }

    comptime {
        std.debug.assert(@sizeOf(Event) == @sizeOf(u128));
    }
};

/// Generic Event Log Buffer Entry.
const EventGeneric = packed struct(u128) {
    /// First opcode dependent operand.
    operand1: u60,
    /// Event code.
    code: EventCode,
    /// Second opcode dependent operand.
    operand2: u64,
};

const EventCode = enum(u4) {
    /// ILLEGAL_DEV_TABLE_ENTRY.
    illegal_dev_table_entry = 0b0001,
    /// IO_PAGE_FAULT.
    io_page_fault = 0b0010,
    /// DEV_TAB_HARDWARE_ERROR.
    dev_tab_hardware_error = 0b0011,
    /// PAGE_TAB_HARDWARE_ERROR.
    page_tab_hardware_error = 0b0100,
    /// ILLEGAL_COMMAND_ERROR.
    illegal_command_error = 0b0101,
    /// COMMAND_HARDWARE_ERROR.
    command_hardware_error = 0b0110,
    /// IOTLB_INV_TIMEOUT.
    iotlb_inv_timeout = 0b0111,
    /// INVALID_DEVICE_REQUEST.
    invalid_device_request = 0b1000,
    /// INVALID_PPR_REQUEST.
    invalid_ppr_request = 0b1001,
    /// EVENT_COUNTER_ZERO.
    event_counter_zero = 0b1010,
};

// =============================================================
// Registers
// =============================================================

// =============================================================
// Control and Status Registers

/// Device Table Base Address Register.
const TableBase = packed struct(u64) {
    /// Size of the Device Table. The size is `(n + 1) * 4` Kbytes.
    size: u9,
    /// Reserved.
    _9: u3 = 0,
    /// Device Table base address. Bits [51:12] of the 4-Kbyte aligned base address of the first table.
    dev_tab_base: u40,
    /// Reserved.
    _52: u12 = 0,

    /// Create a table base register value.
    ///
    /// `phys` is the bus address of the first table.
    /// `size` is a size in bytes of the device table.
    pub fn init(phys: usize, size: usize) TableBase {
        rtt.expectEqual(0, phys % 4096);
        rtt.expectEqual(0, size % 4096);
        return .{
            .size = @intCast(size / 4096 - 1),
            .dev_tab_base = @truncate(phys >> 12),
        };
    }
};

/// Command Buffer Base Address Register.
const CmdBufBase = packed struct(u64) {
    /// Command buffer base address. Bits [11:0] must be zero.
    base: u52,
    /// Reserved.
    _52: u4 = 0,
    /// Command buffer length.
    len: u4,
    /// Reserved.
    _60: u4 = 0,

    /// Create a command buffer base address register value.
    ///
    /// `phys` is the bus address of the first command buffer.
    /// `len` is the number of command entries.
    pub fn init(phys: usize, len: usize) CmdBufBase {
        const comlen: usize = @ctz(len);
        rtt.expectEqual(0, phys % 4096);
        rtt.expectEqual(0, len % 256);
        rtt.expect(std.math.isPowerOfTwo(len));
        rtt.expect(0b1000 <= comlen and comlen <= 0b1111);
        return .{
            .base = @intCast(phys),
            .len = @intCast(comlen),
        };
    }
};

/// Event Log Base Address Register.
const EventLogBase = packed struct(u64) {
    /// Event log base address. Bits [11:0] must be zero.
    base: u52,
    /// Reserved.
    _52: u4 = 0,
    /// Event log length.
    len: u4,
    /// Reserved.
    _60: u4 = 0,

    /// Create a event log buffer base address register value.
    ///
    /// `phys` is the bus address of the event log buffer.
    /// `len` is the number of event log entries.
    pub fn init(phys: usize, len: usize) EventLogBase {
        rtt.expectEqual(0, phys % 4096);
        rtt.expectEqual(0, len % 256);
        rtt.expect(std.math.isPowerOfTwo(len));
        const comlen: usize = @ctz(len);
        rtt.expect(0b1000 <= comlen and comlen <= 0b1111);
        return .{
            .base = @intCast(phys),
            .len = @intCast(comlen),
        };
    }
};

/// IOMMU Control Register.
const Control = packed struct(u64) {
    /// IOMMU enable.
    en: bool,
    /// HyperTransport tunnel translation enable.
    ht_tun_en: bool,
    /// Event log enable.
    event_log_en: bool,
    /// Event log interrupt enable.
    event_int_en: bool,
    /// Completion wait interrupt enable.
    com_wait_int_en: bool,
    /// Invalidation timeout for IOTLB invalidation requests.
    inv_timeout: InvTimeout,
    /// Pass posted write.
    pass_pw: bool,
    /// Response pass posted write.
    res_pass_pw: bool,
    /// Coherent.
    coherent: bool,
    /// Isochronous.
    isoc: bool,
    /// Command buffer enable.
    cmd_buf_en: bool,
    /// Peripheral page request log enable.
    ppr_log_en: bool,
    /// Peripheral page request interrupt enable.
    ppr_int_en: bool,
    /// Peripheral page request enable.
    ppr_en: bool,
    /// Guest translation enable.
    gt_en: bool,
    /// Guest virtual APIC enable.
    ga_en: bool,
    /// Not used.
    crw: u4,
    /// SMI filter enable.
    smi_fen: enum(u1) { pass = 0, filter = 1 },
    /// Self writeback disable.
    slf_wb_dis: bool,
    /// SMI filter log enable.
    smi_flog_en: bool,
    /// Guest virtual APIC mode enabled.
    gam_en: Gam,
    /// Guest virtual APIC GA Log enable.
    ga_log_en: bool,
    /// Guest virtual APIC interrupt enable.
    ga_int_en: bool,
    /// Dual peripheral page request log enable.
    dual_ppr_log_en: DualLogMode,

    /// Dual event log enable.
    dual_event_log_en: DualLogMode,
    /// Device Table segmentation enable.
    dev_tbl_seg_en: DevTblSeg,
    /// Privilege abort mode.
    priv_abrt_en: u2,
    /// Peripheral Page Request automatic response feature enable.
    ppr_auto_rsp_en: bool,
    /// Memory address routing and control feature enable.
    marc_en: bool,
    /// Block StopMark messages feature enable.
    blk_stop_mrk_en: bool,
    /// PPR auto response Always On feature enable.
    ppr_auto_resp_aon: bool,
    /// Controls remapping behavior for MSI interrupts.
    num_int_remap_mode: IntRemapMode,
    /// Enhanced PPR handling.
    epe_en: bool,
    /// Access and Dirty bit update in host page table.
    had_update: u2,
    /// Disable hardware updating dirty bit in guest page table.
    gd_update_dis: bool,
    /// Reserved.
    _49: u1 = 0,
    /// Enable X2APIC.
    xt_en: bool,
    /// Enable IOMMU x2APIC interrupts generation.
    int_cap_xt_en: bool,
    /// Enable virtualized command buffer processing.
    vcmd_en: bool,
    /// Enable virtualized IOMMU.
    viommu_en: bool,
    /// Disable hardware update access bit in guest page table.
    ga_update_dis: bool,
    /// Guest APIC Physical Processor Interrupt enable.
    ga_ppi_en: bool,
    /// Enable support for Tiered Memory Page Migration Support inside IOMMU.
    tmpm_en: bool,
    /// Reserved.
    _57: u1 = 0,
    /// GCR3TRPMode.
    gcr3trp_mode: bool,
    /// Disable IRTE caching.
    irt_cache_dis: bool,
    /// Controls how IOMMU computes the Base pointer of the vIOMMU accelerated Guest Buffers.
    gst_buffer_trp_mode: bool,
    /// Controls guest virtual APIC mode when the system is SNP-enabled.
    snpavic_en: u3,

    /// Guest virtual APIC mode.
    const Gam = enum(u3) {
        int_remap = 0b000,
        vint_remap = 0b001,
    };
};

/// IOMMU invalidate timeout.
const InvTimeout = enum(u3) {
    no = 0b000,
    @"1ms" = 0b001,
    @"10ms" = 0b010,
    @"100ms" = 0b011,
    @"1sec" = 0b100,
    @"10sec" = 0b101,
    @"100sec" = 0b110,
};

/// Device Table segmentation mode.
const DevTblSeg = enum(u3) {
    none = 0b000,
    @"2" = 0b001,
    @"4" = 0b010,
    @"8" = 0b011,
};

const IntRemapMode = enum(u2) {
    /// Remap up to 512 interrupts per function.
    @"512" = 0b00,
    /// Remap up to 2048 interrupts per function.
    @"2048" = 0b01,
};

const DualLogMode = enum(u2) {
    default = 0b00,
    alternate = 0b01,
    auto = 0b10,
};

/// IOMMU Extended Feature Register.
const Efr = packed struct(u64) {
    /// Prefetch support.
    pre_fsup: bool,
    /// Peripheral page request support.
    ppr_sup: bool,
    /// x2APIC support.
    xt_sup: bool,
    /// EXE (PMR) and PRIV supported.
    nx_sup: bool,
    /// Guest translations supported.
    gt_sup: bool,
    /// Guest APIC Physical Processor Interrupt Support.
    gappi_sup: bool,
    /// INVALIDATE_IOMMU_ALL supported.
    ia_sup: bool,
    /// Guest Virtual APIC Support.
    ga_sup: bool,
    /// Hardware Error registers supported.
    he_sup: bool,
    /// Performance counters supported.
    pc_sup: bool,
    /// Host Address Translation Size.
    hats: AtSize,
    /// Guest Address Translation Size.
    gats: AtSize,
    /// Guest CR3 root table level supported.
    glx_sup: Glx,
    /// SMI filter register supported.
    smif_sup: u2,
    /// SMI filter register count.
    smi_frc: u3,
    /// Guest virtual APIC modes supported.
    gam_sup: u3,
    /// Dual PPR log support.
    dual_ppr_log_sup: DualLogMode,
    /// Reserved.
    _26: u2 = 0,
    /// Dual Event Log Support.
    dual_event_log_sup: DualLogMode,
    /// Reserved.
    _30: u1 = 0,
    /// Secure ATS support.
    sats_sup: bool,

    /// Maximum PASID supported. Bit width - 1.
    pas_max: u5,
    /// User / Supervisor page protection feature supported.
    us_sup: bool,
    /// Segmented Device Table feature support.
    dev_tbl_seg_sup: u2,
    /// PPR Log Overflow Early Warning Support.
    ppr_earlyof_sup: bool,
    /// PPR Automatic Response Support.
    ppr_auto_resp_sup: bool,
    /// Memory Access Routing and Control feature support.
    marc_sup: u2,
    /// Block StopMark messages feature Support.
    blk_stop_mrk_sup: bool,
    /// IOMMU performance optimization feature.
    perf_opt_sup: bool,
    /// MSI Capability Register MMIO access Support.
    msi_cap_mmio_sup: bool,
    /// HW supports returning memory attributes of the guest page to ATS requester along with ATS completion.
    snoop_attrs_sup: bool,
    /// Guest I/O Protection Support.
    gio_sup: bool,
    /// Host Access Support.
    ha_sup: bool,
    /// Enhanced PPR Handling Support.
    eph_sup: bool,
    /// Attribute Forward Support.
    attr_fw_sup: bool,
    /// Host Dirty Support.
    hd_sup: bool,
    /// HW supports disabling v2 Dirty bit updates by HW.
    v2hd_dis_sup: bool,
    /// Invalidate IOTLB Type Support.
    inv_iotlb_type_sup: bool,
    /// Virtualized IOMMU support.
    viommu_sup: bool,
    /// SEV support by HW.
    vm_guard_io_sup: bool,
    /// Reserved.
    _57: u4 = 0,
    /// Disabling v2 access bit updates by HW.
    v2had_dis_sup: bool,
    /// Force Physical Destination Mode for Remapped Interrupt Support.
    force_phy_dest_sup: bool,
    /// Secure Nested Paging support.
    snp_sup: bool,
};

/// Address translation size.
const AtSize = enum(u2) {
    /// 4 levels.
    @"4" = 0b00,
    /// 5 levels.
    @"5" = 0b01,
    /// 6 levels.
    @"6" = 0b10,
};

/// Guest CR3 root table level.
const Glx = enum(u2) {
    single = 0b00,
    two = 0b01,
    three = 0b10,
};

// =============================================================
// Command and Event Log Pointer Registers

/// Command Buffer Head Pointer Register.
const CmdHead = packed struct(u64) {
    /// Command buffer head pointer. Bits [4:0] must be zero.
    ptr: u19,
    /// Reserved.
    _19: u45 = 0,
};

/// Command Buffer Tail Pointer Register.
const CmdTail = packed struct(u64) {
    /// Command buffer tail pointer. Bits [4:0] must be zero.
    ptr: u19,
    /// Reserved.
    _19: u45 = 0,
};

/// Event Log Head Pointer Register.
const EventLogHead = packed struct(u64) {
    /// Event log head pointer. Bits [4:0] must be zero.
    ptr: u19,
    /// Reserved.
    _19: u45 = 0,
};

/// Event Log Tail Pointer Register.
const EventLogTail = packed struct(u64) {
    /// Event log tail pointer. Bits [4:0] must be zero.
    ptr: u19,
    /// Reserved.
    _19: u45 = 0,
};

// =============================================================
// Command and Event Status Register

/// IOMMU Status Register.
const Status = packed struct(u64) {
    /// Event log overflow. RW1C.
    event_overflow: bool,
    /// Event log interrupt. RW1C.
    event_log_int: bool,
    /// Completion wait interrupt. RW1C.
    com_wait_int: bool,
    /// Event logging is running.
    event_log_run: bool,
    /// Command buffer is running.
    cmd_buf_run: bool,
    /// PPR log overflow. RW1C.
    ppr_overflow: bool,
    /// PPR interrupt. RW1C.
    ppr_int: bool,
    /// PPR logging is running.
    ppr_log_run: bool,
    /// Guest virtual APIC logging is running.
    ga_log_run: bool,
    /// Guest virtual APIC log overflow. RW1C.
    gal_overflow: bool,
    /// Guest virtual APIC log interrupt. RW1C.
    ga_int: bool,
    /// PPR Log B has overflowed.
    ppr_overflow_b: bool,
    /// PPR Log A is active.
    ppr_log_active: bool,
    /// Reserved.
    _13: u2 = 0,
    /// Event Log B has overflowed. RW1C.
    event_overflow_b: bool,
    /// Event Log A is active.
    event_log_active: bool,
    /// PPR log B Overflow Early warning. RW1C.
    ppr_overflow_early_b: bool,
    /// PPR log Overflow Early warning. RW1C.
    ppr_overflow_early: bool,
    /// Reserved.
    _19: u45 = 0,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.amdvi);
const common = @import("common");
const rtt = common.rtt;
const mmio = common.io.mmio;
const Reg = common.io.Reg;
const DmaAllocator = common.mem.DmaAllocator;
const DmaMemory = DmaAllocator.DmaMemory;
const urd = @import("urthr");
