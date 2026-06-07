const Self = @This();

/// xHC controller.
xhc: *Xhc,
/// DMA allocator.
dma: DmaAllocator,
/// Transfer Ring for Endpoint 0.
tr: rings.Ring = undefined,
/// Device Context for this device.
dctx: DmaMemory = undefined,

/// Port index (1-origin).
pi: usize,
/// Port register.
pr: regs.Port,
/// Slot ID assigned to the device.
slot: u8 = undefined,
/// Device descriptor provided by the device.
desc: DeviceDesc = undefined,
/// List of interfaces provided by the device.
ifaces: Interface.List = .{},

/// Device state.
state: State,
/// Pending Control Transfer completion.
///
/// Control transfers are processed sequentially on EP0,
/// so we can only have one pending control transfer at a time.
pending_ep0: ?Ep0Completion = null,

/// Device state.
const State = enum {
    /// Waiting for the Slot ID to be assigned.
    waiting_slot,
    /// Waiting for the address to be assigned.
    waiting_address,
    /// Address has been assigned and device is waiting for the device descriptor.
    waiting_device_desc,
    /// Waiting for the configuration descriptor.
    waiting_config_desc,
    /// Waiting for the configuration to be set.
    waiting_config_set,
    /// Initialization complete.
    complete,
};

/// Endpoint belonging to an interface.
pub const Endpoint = struct {
    /// Endpoint descriptor.
    desc: EpDesc,
    /// Transfer Ring for this endpoint.
    tr: rings.Ring = undefined,

    /// List head.
    _head: List.Head = .{},

    /// List type of endpoints.
    const List = common.typing.InlineDoublyLinkedList(Endpoint, "_head");
};

/// Interface belonging to the device.
///
/// One interface may have multiple endpoints.
pub const Interface = struct {
    /// Interface descriptor.
    desc: IfaceDesc,
    /// Type-erased class descriptor. null if the interface has no class descriptor.
    class: ?*const DescriptorHeader,
    /// Endpoints belonging to the interface.
    endpoints: Endpoint.List = .{},
    /// Driver bound to this interface.
    driver: ?class.Driver = null,

    /// List head.
    _head: List.Head = .{},

    /// List type of interfaces.
    const List = common.typing.InlineDoublyLinkedList(Interface, "_head");
};

/// Initializes USB device belonging to the given port of the xHC controller.
pub fn new(xhc: *Xhc, pi: usize, pr: regs.Port) mem.Error!*Self {
    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);

    self.* = .{
        .xhc = xhc,
        .dma = xhc.dma,
        .state = .waiting_slot,
        .pi = pi,
        .pr = pr,
    };

    return self;
}

/// Reset the port.
///
/// Blocks until the request is completed.
/// Generates a Port Reset Change event when completed.
pub fn resetPort(self: *Self) void {
    rtt.expectEqual(.waiting_slot, self.state);

    self.pr.modify(regs.PortSc, .{
        .pr = true,
    });
    self.pr.waitFor(regs.PortSc, .{
        .pr = false,
    }, null);
}

// =============================================================
// Callbacks for command completion events
// =============================================================

/// Push an Enable Slot command to the command ring.
pub fn onPortReset(self: *Self) Error!void {
    rtt.expectEqual(.waiting_slot, self.state);

    var enable_slot = trbs.EnableSlotTrb{ .cycle = undefined };
    try self.xhc.pushCommand(
        self,
        .from(&enable_slot),
        onSlotEnabled,
    );
}

/// Called when the Enable Slot command completes.
///
/// Allocate a Device Context and request to assign an address to the device.
fn onSlotEnabled(self: *Self, event: *const trbs.CommandCompletionTrb) Error!void {
    rtt.expectEqual(.waiting_slot, self.state);
    if (event.code != .success) {
        log.err("Port#{d}: Enable Slot failed: {t}", .{ self.pi, event.code });
        return Error.InvalidState;
    }

    const slot = event.slot_id;
    log.debug("Port#{d}:Slot#{d}: Slot enabled.", .{ self.pi, slot });
    rtt.expect(slot != 0);
    self.slot = slot;

    // Allocate a Device Context region.
    const dc = try self.dma.allocBytes(mem.page_size, .normal);
    errdefer self.dma.freeBytes(dc);
    @memset(dc.slice(u8), 0);
    self.dma.syncForDevice(dc.cpu, dc.size);
    self.xhc.setDeviceContext(slot, dc.bus);
    self.dctx = dc;

    // Create Input Context.
    const ctx_size: usize = switch (self.xhc.csz) {
        .@"32" => 32,
        .@"64" => 64,
    };
    const icm = try self.dma.allocBytes(ctx_size * 3, .normal);
    errdefer self.dma.freeBytes(icm);
    @memset(icm.slice(u8), 0);
    const base = icm.cpu;

    // Configure Input Control Context (enable Slot Context and Endpoint 0)
    {
        const control: *InputControlContext = @ptrFromInt(base + ctx_size * 0);
        control.ac.a0 = true;
        control.ac.a1 = true;
    }
    // Configure Slot Context.
    {
        const slot_ctx: *SlotContext = @ptrFromInt(base + ctx_size * 1);
        slot_ctx.* = .{
            .speed = self.pr.read(regs.PortSc).speed,
            .root_hub_port = @intCast(self.pi),
            .context_entries = 1,
            .max_exit_latency = 0,
            .addr = 0,
            .intr_target = 0,
        };
    }
    // Configure EP0 (Default Control Pipe) Context.
    {
        const tr = try rings.Ring.new(rings.trbs_per_page, self.dma);
        errdefer tr.deinit();
        self.tr = tr;

        const speed = self.pr.read(regs.PortSc).speed;
        const ep0: *EndpointContext = @ptrFromInt(base + ctx_size * 2);
        ep0.* = .{
            .ep_type = .control,
            .max_packet_size = speed.maxPacketSize(),
            .interval = 0,
            .cerr = 3,
            .trdp = @intCast(self.tr.memory.bus >> 4),
            .dcs = tr.pcs,
        };
    }
    self.dma.syncForDevice(icm.cpu, icm.size);

    // Request to assign the address.
    self.state = .waiting_address;
    var cmd = trbs.AddressDeviceTrb.from(slot, icm.bus);
    try self.xhc.pushCommand(
        self,
        .from(&cmd),
        onDeviceAddressed,
    );
}

/// Called when the Address Device command completes.
///
/// Start GET_DESCRIPTOR for the device descriptor.
fn onDeviceAddressed(self: *Self, event: *const trbs.CommandCompletionTrb) Error!void {
    rtt.expectEqual(.waiting_address, self.state);
    if (event.code != .success) {
        log.err("Port#{d}:Slot#{d}: Failed to assign address: {t}", .{ self.pi, self.slot, event.code });
        return Error.InvalidState;
    }

    log.debug("Port#{d}:Slot#{d}: Device addressed.", .{ self.pi, self.slot });
    self.state = .waiting_device_desc;

    // Request to get the device descriptor.
    const Value = packed struct(u16) {
        /// Configuration index.
        desc_index: u8,
        /// Descriptor type.
        desc_type: DescriptorType,
    };
    const request_type = SetupData.RequestType{
        .recipient = .device,
        .type = .standard,
        .direction = .in,
    };
    const setup_data = SetupData{
        .request_type = request_type,
        .request = .get_descriptor,
        .value = @bitCast(Value{
            .desc_index = 0,
            .desc_type = .device,
        }),
        .index = 0,
        .length = 18,
    };
    try self.ctrlXfer(setup_data, null, onDeviceDescReceived);
}

/// Called when the Configure Endpoint command completes.
///
/// Bind class drivers to interfaces and mark the device as ready for use.
fn onEpConfigured(self: *Self, event: *const trbs.CommandCompletionTrb) Error!void {
    rtt.expectEqual(.waiting_config_set, self.state);
    if (event.code != .success) {
        log.err("Port#{d}:Slot#{d}: Failed to configure endpoints: {t}", .{ self.pi, self.slot, event.code });
        return Error.InvalidState;
    }

    log.debug("Port#{d}:Slot#{d}: EP configured.", .{ self.pi, self.slot });
    self.state = .complete;

    // Bind drivers to interfaces.
    var iter = self.ifaces.iter();
    while (iter.next()) |iface| {
        if (try class.from(self, iface)) |driver| {
            iface.driver = driver;
            log.info("Driver {s} bound to interface#{d}", .{ driver.getName(), iface.desc.interface_number });
        } else {
            log.warn("No suitable driver found for interface#{d}", .{iface.desc.interface_number});
        }
    }
}

// =============================================================
// Callbacks for transfer events
// =============================================================

/// Callback for Transfer Event TRB.
pub fn onTransferEvent(self: *Self, event: *const trbs.TransferEventTrb) Error!void {
    // EP0 (Default Control Pipe, DCI=1)
    if (event.endpoint == calcDci(0, .in)) {
        const comp = self.popPendingEp0Xfer() orelse {
            log.warn("Transfer event for EP0 with no pending completion.", .{});
            return;
        };
        if (event.code != .success and event.code != .short_packet) {
            log.err("EP0 transfer failed: {t}", .{event.code});
            if (comp.buf) |b| self.dma.freeBytes(b);
            return;
        }

        return comp.cb(comp.ctx, self, comp.buf);
    }

    // Other endpoints: find by DCI and dispatch to the class driver.
    var iface_iter = self.ifaces.iter();
    while (iface_iter.next()) |iface| {
        var ep_iter = iface.endpoints.iter();
        while (ep_iter.next()) |ep| {
            if (ep.desc.address.dci() == event.endpoint) {
                if (iface.driver) |drv| {
                    try drv.vtable.onTransferEvent(drv.ptr, event, ep);
                } else {
                    log.warn("Transfer event for endpoint DCI#{d} with no bound driver", .{event.endpoint});
                }
                return;
            }
        }
    }
    log.warn("Transfer event for unknown endpoint DCI#{d}", .{event.endpoint});
}

/// Callback function for transfer events on EP0 (Default Control Pipe).
///
/// Callee is responsible for freeing the buffer.
const XferCb = *const fn (ctx: ?*anyopaque, device: *Self, buf: ?DmaMemory) Error!void;

/// Pending completion for an EP0 control transfer.
const Ep0Completion = struct {
    /// Opaque context passed to the callback.
    ctx: ?*anyopaque,
    /// Called when the status stage transfer event arrives.
    cb: XferCb,
    /// DMA buffer for the data stage.
    ///
    /// `null` if the transfer has no data stage.
    buf: ?DmaMemory,
};

/// Called when GET_DESCRIPTOR for the device descriptor completes.
///
/// Store the descriptor and then request a configuration descriptor.
fn onDeviceDescReceived(_: ?*anyopaque, self: *Self, buf: ?DmaMemory) Error!void {
    rtt.expectEqual(.waiting_device_desc, self.state);

    const memory = buf.?;
    const desc: *const volatile DeviceDesc = @ptrFromInt(memory.cpu);
    self.dma.syncForCpu(@intFromPtr(desc), @sizeOf(DeviceDesc));
    defer self.dma.freeBytes(memory);

    rtt.expectEqual(.device, desc.type);
    self.desc = desc.*;

    self.state = .waiting_config_desc;

    // Request to get a Configuration Descriptor.
    const config_index = 0;
    const Value = packed struct(u16) {
        /// Configuration index.
        desc_index: u8,
        /// Descriptor type.
        desc_type: DescriptorType,
    };
    const request_type = SetupData.RequestType{
        .recipient = .device,
        .type = .standard,
        .direction = .in,
    };
    const setup_data = SetupData{
        .request_type = request_type,
        .request = .get_descriptor,
        .value = @bitCast(Value{
            .desc_index = config_index,
            .desc_type = .configuration,
        }),
        .index = 0,
        .length = mem.page_size,
    };
    try self.ctrlXfer(
        setup_data,
        null,
        onConfigDescReceived,
    );
}

/// Called when GET_DESCRIPTOR for the configuration descriptor completes.
///
/// Parse the configuration descriptor and then request to set the configuration to xHC.
fn onConfigDescReceived(_: ?*anyopaque, self: *Self, buf: ?DmaMemory) Error!void {
    rtt.expectEqual(.waiting_config_desc, self.state);

    const memory = buf.?;
    const desc: *const volatile ConfigDesc = @ptrFromInt(memory.cpu);
    self.dma.syncForCpu(@intFromPtr(desc), mem.page_size);
    defer self.dma.freeBytes(memory);

    const config_value = desc.config_value;
    rtt.expectEqual(.configuration, desc.type);
    rtt.expect(config_value != 0);

    try self.parseConfigDesc(desc);
    log.debug("{d} interfaces found.", .{self.ifaces.len});

    self.state = .waiting_config_set;

    // Request to set the configuration.
    const request_type = SetupData.RequestType{
        .recipient = .device,
        .type = .standard,
        .direction = .out,
    };
    const setup_data = SetupData{
        .request_type = request_type,
        .request = .set_configuration,
        .value = config_value,
        .index = 0,
        .length = 0,
    };
    try self.ctrlXfer(
        setup_data,
        null,
        onConfigSet,
    );
}

/// Called when SET_CONFIGURATION completes.
///
/// Issues Configure Endpoint command to notify the xHC of the endpoint configuration.
///
/// xHC does not know which configuration has been selected for the device.
/// So we have to notify the selected setting to the xHC by this function.
fn onConfigSet(_: ?*anyopaque, self: *Self, _: ?DmaMemory) Error!void {
    rtt.expectEqual(.waiting_config_set, self.state);

    // Create and clear the Input Context.
    const ctx_size: usize = switch (self.xhc.csz) {
        .@"32" => 32,
        .@"64" => 64,
    };
    const icm = try self.dma.allocBytes(ctx_size * 32, .normal);
    const base = icm.cpu;
    errdefer self.dma.freeBytes(icm);
    @memset(icm.slice(u8), 0);

    // Configure Input Control Context.
    const control: *InputControlContext = @ptrFromInt(base + ctx_size * 0);
    control.ac.a0 = true; // Slot Context

    // Set Add Context Flags and configure all endpoints.
    const speed = self.pr.read(regs.PortSc).speed;
    var ac = control.ac;
    var max_dci: u5 = 0;
    var iface_iter = self.ifaces.iter();
    while (iface_iter.next()) |iface| {
        var ep_iter = iface.endpoints.iter();

        while (ep_iter.next()) |ep| {
            const dci = ep.desc.address.dci();
            max_dci = @max(max_dci, dci);
            ac.set(dci);

            // Init a Transfer Ring for this endpoint.
            ep.tr = try rings.Ring.new(rings.trbs_per_page, self.dma);
            errdefer ep.tr.deinit();

            const ep_type: EndpointType = switch (ep.desc.address.direction) {
                .out => switch (ep.desc.attributes.transfer_type) {
                    .control => .control,
                    .isochronous => .isoch_out,
                    .bulk => .bulk_out,
                    .interrupt => .intr_out,
                },
                .in => switch (ep.desc.attributes.transfer_type) {
                    .control => .control,
                    .isochronous => .isoch_in,
                    .bulk => .bulk_in,
                    .interrupt => .intr_in,
                },
            };

            // Configure endpoint context.
            // Input Context layout: [Input Control][Slot][EP@DCI=1][EP@DCI=2]...
            const ectx: *EndpointContext = @ptrFromInt(base + ctx_size * (1 + dci));
            ectx.* = .{
                .max_packet_size = ep.desc.max_packet_size,
                .max_burst_size = 0,
                .dcs = ep.tr.pcs,
                .interval = toXhciInterval(
                    ep.desc.interval,
                    speed,
                    ep.desc.attributes.transfer_type,
                ),
                .max_pstream = 0,
                .mult = 0,
                .cerr = 3,
                .ep_type = ep_type,
                .trdp = @intCast(ep.tr.memory.bus >> 4),
            };
        }
    }
    control.ac = ac;

    // Copy and update slot context.
    {
        const slot_ctx: *SlotContext = @ptrFromInt(base + ctx_size * 1);
        const current: *volatile SlotContext = @ptrFromInt(self.dctx.cpu);
        slot_ctx.* = current.*;
        slot_ctx.context_entries = max_dci;
    }

    // Sync the Input Context for the device.
    self.dma.syncForDevice(icm.cpu, icm.size);

    // Issue Configure Endpoint command.
    var cmd = trbs.ConfigureEndpointTrb.from(
        self.slot,
        icm.bus,
    );
    try self.xhc.pushCommand(
        self,
        Trb.from(&cmd),
        onEpConfigured,
    );
}

// =============================================================
// Utility
// =============================================================

/// Queue an Interrupt IN transfer on the given endpoint.
pub fn transferIn(self: *Self, ep: *Endpoint, buf: DmaMemory) void {
    var trb = trbs.NormalTrb{
        .data = buf.bus,
        .length = @intCast(buf.size),
        .isp = true,
        .ioc = true,
        .cycle = undefined,
    };
    _ = ep.tr.push(Trb.from(&trb));
    self.xhc.dbs.notifyEndpoint(self.slot, ep.desc.address.dci());
}

/// Perform a control transfer on EP 0 (Default Control Pipe).
///
/// Direction is determined by the given SetupData.
pub fn ctrlXfer(self: *Self, data: SetupData, ctx: ?*anyopaque, cb: XferCb) Error!void {
    const dir = data.request_type.direction;
    if (dir == .out) rtt.expectEqual(0, data.length);

    const buf = if (data.length != 0) blk: {
        const memory = try self.dma.allocBytes(data.length, .normal);
        errdefer self.dma.freeBytes(memory);
        @memset(memory.slice(u8), 0);
        self.dma.syncForDevice(memory.cpu, data.length);
        break :blk memory;
    } else null;

    // Setup stage.
    var setup_trb = trbs.SetupTrb{
        .request_type = @bitCast(data.request_type),
        .request = @intFromEnum(data.request),
        .value = data.value,
        .index = data.index,
        .length = data.length,
        .cycle = undefined,
        .ioc = false,
        .trt = if (dir == .in) .in else .no_data,
        .idt = true,
        .intr_target = 0,
    };
    _ = self.tr.push(.from(&setup_trb));

    // Data stage if any.
    if (buf) |b| {
        var data_trb = trbs.DataTrb{
            .data_buffer = b.bus,
            .transfer_length = data.length,
            .td_size = 0,
            .cycle = undefined,
            .ent = false,
            .isp = false,
            .ns = false,
            .chain = false,
            .ioc = false,
            .idt = false,
            .direction = if (dir == .in) .in else .out,
            .intr_target = 0,
        };
        _ = self.tr.push(.from(&data_trb));
    }

    // Status stage.
    var status_trb = trbs.StatusTrb{
        .cycle = undefined,
        .ent = false,
        .chain = false,
        .ioc = true,
        .direction = if (dir == .in) .out else .in,
        .intr_target = 0,
    };
    _ = self.tr.push(.from(&status_trb));

    // Register the pending completion and ring the doorbell.
    self.pushPendingEp0Xfer(.{
        .ctx = ctx,
        .cb = cb,
        .buf = buf,
    });
    self.xhc.dbs.notifyEndpoint(
        self.slot,
        calcDci(0, .in),
    );
}

/// Push a pending EP0 control transfer completion.
fn pushPendingEp0Xfer(self: *Self, completion: Ep0Completion) void {
    rtt.expectEqual(null, self.pending_ep0);
    self.pending_ep0 = completion;
}

/// Pop to return the pending EP0 control transfer completion.
fn popPendingEp0Xfer(self: *Self) ?Ep0Completion {
    const ret = self.pending_ep0;
    self.pending_ep0 = null;
    return ret;
}

/// Calculate the Device Context Index (DCI).
fn calcDci(ep: u4, direction: RequestDirection) u5 {
    return (@as(u5, ep) << 1) + @as(u5, @intFromEnum(direction));
}

/// Convert USB endpoint descriptor bInterval to xHCI Endpoint Context Interval.
fn toXhciInterval(binterval: u8, speed: regs.PortSpeed, transfer_type: EpDesc.TransferType) u8 {
    switch (transfer_type) {
        .bulk, .control => return 0,
        else => {},
    }
    switch (speed) {
        .full, .low => {
            // ceil (log2(bInterval * 8))
            if (binterval == 0) return 3;
            const log2 = std.math.log2_int_ceil(u8, binterval);
            return @min(18, log2 + 3);
        },
        .high, .super => {
            // bInterval - 1
            if (binterval == 0) return 0;
            return @min(15, binterval - 1);
        },
        else => return 0,
    }
}

/// Parse the given configuration descriptor.
fn parseConfigDesc(self: *Self, cdesc: *const volatile ConfigDesc) Error!void {
    const ParseState = enum {
        between_ifaces,
        in_iface,
    };

    var left = cdesc.total_length - cdesc.length;
    var cur: *align(1) const volatile DescriptorHeader = @ptrFromInt(@intFromPtr(cdesc) + cdesc.length);
    var state: ParseState = .between_ifaces;
    var iface: Interface = undefined;

    const finalizeIface = struct {
        fn call(s: *Self, i: *Interface) Error!void {
            const entry = try mem.bin.create(Interface);
            entry.* = i.*;
            s.ifaces.append(entry);
        }
    }.call;

    while (left > 0) {
        rtt.expect(cur.length != 0);

        switch (cur.type) {
            // Interface descriptor.
            .interface => {
                if (state == .in_iface) {
                    try finalizeIface(self, &iface);
                }
                const desc: *align(1) const volatile IfaceDesc = @ptrCast(@alignCast(cur));
                iface = .{ .desc = desc.*, .class = null };
                state = .in_iface;
            },

            // Class-specific descriptor.
            .hid => {
                rtt.expectEqual(.in_iface, state);

                const desc_buf = try mem.bin.alloc(u8, cur.length);
                errdefer mem.bin.free(desc_buf);
                @memcpy(desc_buf, @as([*]const volatile u8, @ptrCast(cur))[0..cur.length]);
                iface.class = @ptrCast(@alignCast(desc_buf.ptr));
            },

            // Endpoint descriptor.
            .endpoint => {
                rtt.expectEqual(.in_iface, state);

                const desc: *align(1) const volatile EpDesc = @ptrCast(@alignCast(cur));
                const ep = try mem.bin.create(Endpoint);
                errdefer mem.bin.destroy(ep);
                ep.* = .{ .desc = desc.* };
                iface.endpoints.append(ep);
            },

            else => log.warn(
                "Unexpected descriptor type {d} in configuration descriptor (length={d}).",
                .{ @intFromEnum(cur.type), cur.length },
            ),
        }

        left -= cur.length;
        cur = @ptrFromInt(@intFromPtr(cur) + cur.length);
    }

    if (state == .in_iface) {
        try finalizeIface(self, &iface);
    }
}

// =============================================================
// Data structures
// =============================================================
/// Consists of two groups of flags.
///
/// Interpretation depends on the command.
const InputControlContext = packed struct(u256) {
    /// Reserved.
    _0: u2 = 0,
    /// Drop Context Flags.
    ///
    /// Identifies which Device Context data should be disabled by the command.
    dc: DropContext,
    /// Add Context Flags.
    ///
    /// Identifies which Device Context data shall be evaluated and/or enabled by the command.
    ac: AddContext,
    /// Reserved.
    _64: u32 = 0,
    /// Reserved.
    _96: u32 = 0,
    /// Reserved.
    _128: u32 = 0,
    /// Reserved.
    _160: u32 = 0,
    /// Reserved.
    _192: u32 = 0,
    /// Configuration Value.
    config: u8 = 0,
    /// Interface Number.
    interface: u8 = 0,
    /// Alternate Setting.
    alternate: u8 = 0,
    /// Reserved.
    _248: u8 = 0,

    const DropContext = packed struct(u30) {
        d2: bool,
        d3: bool,
        d4: bool,
        d5: bool,
        d6: bool,
        d7: bool,
        d8: bool,
        d9: bool,
        d10: bool,
        d11: bool,
        d12: bool,
        d13: bool,
        d14: bool,
        d15: bool,
        d16: bool,
        d17: bool,
        d18: bool,
        d19: bool,
        d20: bool,
        d21: bool,
        d22: bool,
        d23: bool,
        d24: bool,
        d25: bool,
        d26: bool,
        d27: bool,
        d28: bool,
        d29: bool,
        d30: bool,
        d31: bool,
    };

    const AddContext = packed struct(u32) {
        a0: bool,
        a1: bool,
        a2: bool,
        a3: bool,
        a4: bool,
        a5: bool,
        a6: bool,
        a7: bool,
        a8: bool,
        a9: bool,
        a10: bool,
        a11: bool,
        a12: bool,
        a13: bool,
        a14: bool,
        a15: bool,
        a16: bool,
        a17: bool,
        a18: bool,
        a19: bool,
        a20: bool,
        a21: bool,
        a22: bool,
        a23: bool,
        a24: bool,
        a25: bool,
        a26: bool,
        a27: bool,
        a28: bool,
        a29: bool,
        a30: bool,
        a31: bool,

        inline fn set(self: *AddContext, n: u5) void {
            switch (n) {
                0 => self.a0 = true,
                1 => self.a1 = true,
                2 => self.a2 = true,
                3 => self.a3 = true,
                4 => self.a4 = true,
                5 => self.a5 = true,
                6 => self.a6 = true,
                7 => self.a7 = true,
                8 => self.a8 = true,
                9 => self.a9 = true,
                10 => self.a10 = true,
                11 => self.a11 = true,
                12 => self.a12 = true,
                13 => self.a13 = true,
                14 => self.a14 = true,
                15 => self.a15 = true,
                16 => self.a16 = true,
                17 => self.a17 = true,
                18 => self.a18 = true,
                19 => self.a19 = true,
                20 => self.a20 = true,
                21 => self.a21 = true,
                22 => self.a22 = true,
                23 => self.a23 = true,
                24 => self.a24 = true,
                25 => self.a25 = true,
                26 => self.a26 = true,
                27 => self.a27 = true,
                28 => self.a28 = true,
                29 => self.a29 = true,
                30 => self.a30 = true,
                31 => self.a31 = true,
            }
        }
    };
};

/// Defines information applied to a device as a whole.
const SlotContext = packed struct(u256) {
    /// Route String.
    ///
    /// Used by hubs to route packets to the correct downstream port.
    route: u20 = 0,
    /// Speed.
    ///
    /// Deprecated in xHCI 1.2.
    speed: regs.PortSpeed,
    /// Reserved.
    _24: u1 = 0,
    /// Multi-TT.
    ///
    /// Set to true if this is a High-speed hub that supports MTT and its interface has been enabled by the software.
    mtt: bool = false,
    /// Hub.
    ///
    /// Set to true if this is a USB hub.
    hub: bool = false,
    /// Context Entries.
    ///
    /// Identifies the index of the last valid Endpoint Context within this Slot Context.
    context_entries: u5,

    /// Max Exit Latency in microseconds.
    max_exit_latency: u16,
    /// Root Hub Port Number.
    ///
    /// Identifies the Root Hub Port Number used to access the device.
    root_hub_port: u8,
    /// Number of Ports.
    ///
    /// If `.hub` is true, indicates the number of downstream ports.
    num_ports: u8 = 0,

    /// Parent Hub Slot ID.
    ///
    /// Configured iff this device is Low-/Full-speed and connected through a High-speed hub.
    parent_slot: u8 = 0,
    /// Parent Port Number.
    ///
    /// Configured iff this device is Low-/Full-speed and connected through a High-speed hub.
    parent_port: u8 = 0,
    /// Configured iff this device is a High-speed hub.
    ttt: u2 = 0,
    /// Reserved.
    _82: u4 = 0,
    /// Interrupt Target.
    ///
    /// Index of the interrupter that will receive Bandwidth Request Events and Device Notification Events generated by this slot.
    intr_target: u10 = 0,

    /// USB Device Address assigned by the xHC.
    addr: u8,
    /// Reserved.
    _104: u19 = 0,
    /// Slot State. Updated by the xHC when a Device Slot transitions to a new state.
    slot_state: u5 = 0,

    /// Reserved.
    _128: u32 = 0,
    /// Reserved.
    _160: u32 = 0,
    /// Reserved.
    _192: u32 = 0,
    /// Reserved.
    _224: u32 = 0,
};

/// Defines information applied to a specific endpoint of a device.
const EndpointContext = packed struct(u256) {
    /// Endpoint State.
    ep_state: EndpointState = .disabled,
    /// Reserved.
    _3: u5 = 0,
    /// Mult.
    mult: u2 = 0,
    /// Max Primary Streams.
    max_pstream: u5 = 0,
    /// Linear Stream Array.
    lsa: u1 = 0,
    /// The period between consecutive requests to an endpoint in 125us increments.
    interval: u8 = 0,
    /// Max Endpoint Service Time Interval Payload High.
    max_esit_payload_hi: u8 = 0,

    /// Reserved.
    _32: u1 = 0,
    /// Error Count.
    ///
    /// The number of consecutive USB Bus Errors allowed while executing a TD.
    cerr: u2 = 0,
    /// Endpoint Type.
    ep_type: EndpointType,
    /// Reserved.
    _38: u1 = 0,
    /// Host Initiate Disable.
    hid: bool = false,
    /// Max Burst Size.
    max_burst_size: u8 = 0,
    /// Max Packet Size.
    ///
    /// Indicates the maximum packet size in bytes that this endpoint is capable of sending or receiving.
    max_packet_size: u16,

    /// Dequeue Cycle State.
    dcs: u1,
    /// Reserved.
    _65: u3 = 0,
    /// High 60 bits of the Transfer Ring Dequeue Pointer.
    trdp: u60,

    /// Average TRB Length.
    ave_trb_len: u16 = 0,
    /// Max Endpoint Service Time Interval Payload Low.
    max_esit_payload_lo: u16 = 0,

    /// Reserved.
    _160: u32 = 0,
    /// Reserved.
    _192: u32 = 0,
    /// Reserved.
    _224: u32 = 0,

    const EndpointState = enum(u3) {
        disabled = 0,
        running = 1,
        halted = 2,
        stopped = 3,
        err = 4,

        _,
    };
};

const EndpointType = enum(u3) {
    invalid = 0,
    isoch_out = 1,
    bulk_out = 2,
    intr_out = 3,
    control = 4,
    isoch_in = 5,
    bulk_in = 6,
    intr_in = 7,
};

/// Contents of the Setup Stage TRB.
pub const SetupData = packed struct(u64) {
    /// bmRequestType.
    ///
    /// Identifies the characteristics of the request.
    request_type: RequestType,
    /// bRequest.
    ///
    /// Specifies the particular request.
    request: Request,
    /// wValue.
    ///
    /// Varying by request type.
    value: u16,
    /// wIndex.
    ///
    /// Varying by request type.
    index: u16,
    /// wLength.
    ///
    /// Specifies the length of the data transferred during the second stage of the control transfer.
    length: u16,

    pub const RequestType = packed struct(u8) {
        recipient: Recipient,
        type: Type,
        direction: RequestDirection,
    };

    pub const Recipient = enum(u5) {
        /// Device
        device = 0,
        /// Interface
        interface = 1,
        /// Endpoint
        endpoint = 2,
        /// Other
        other = 3,
        /// Vendor specific
        vendor = 31,
        /// Reserved.
        _,
    };

    pub const Type = enum(u2) {
        /// Standard
        standard = 0,
        /// Class
        class = 1,
        /// Vendor
        vendor = 2,
        /// Reserved
        reserved = 3,
    };

    const Request = enum(u8) {
        get_status = 0,
        clear_feature = 1,
        set_feature = 3,
        set_address = 5,
        get_descriptor = 6,
        set_descriptor = 7,
        get_configuration = 8,
        set_configuration = 9,
        get_interface = 10,
        set_interface = 11,
        synch_frame = 12,
        _,
    };
};

/// Direction of a USB request.
pub const RequestDirection = enum(u1) {
    /// Host-to-device.
    out = 0,
    /// Device-to-host.
    in = 1,
};

// =============================================================
// Descriptor definitions
// =============================================================

/// Common header for all USB descriptors.
const DescriptorHeader = packed struct(u16) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType,
};

/// List of Descriptor Types.
const DescriptorType = enum(u8) {
    /// Standard descriptor types.
    device = 1,
    ///
    configuration = 2,
    ///
    string = 3,
    ///
    interface = 4,
    ///
    endpoint = 5,
    ///
    interface_power = 8,
    ///
    otg = 9,
    ///
    debug = 10,
    ///
    interface_association = 11,
    ///
    bos = 15,
    ///
    device_cap = 16,
    // Class-specific descriptor types.
    hid = 33,
    ///
    hid_report = 34,

    _,
};

/// General information about a device.
const DeviceDesc = packed struct(u144) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .device,
    /// USB Specification Release Number in Binary-Coded Decimal (BCD) format.
    usb_spec: u16,
    /// Class code.
    class: u8,
    /// Subclass code.
    subclass: u8,
    /// Protocol code.
    protocol: u8,
    /// Maximum packet size for endpoint 0 (default control pipe).
    max_packet_size: u8,
    /// Vendor ID.
    vendor: u16,
    /// Product ID.
    product: u16,
    /// Device release number in BCD format.
    device: u16,
    /// Index of string descriptor describing the manufacturer.
    manufacture_index: u8,
    /// Index of string descriptor describing the product.
    product_index: u8,
    /// Index of string descriptor describing the serial number.
    serial_index: u8,
    /// Number of possible configurations.
    num_configs: u8,
};

/// Describes a specific device configuration.
const ConfigDesc = packed struct(u72) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .configuration,
    /// Total length of this configuration including all interfaces, endpoints, and class descriptors.
    total_length: u16,
    /// Number of interfaces supported by this configuration.
    num_interfaces: u8,
    /// Value used by the Set Configuration request to select this configuration.
    config_value: u8,
    /// Index of string descriptor describing this configuration.
    config_index: u8,
    /// Configuration characteristics.
    attributes: u8,
    /// Maximum power consumption from the bus (in 2mA units).
    max_power: u8,
};

/// Describes a specific interface within a configuration.
///
/// Endpoint descriptors for this interface follow the interface descriptor.
/// Always part of a configuration descriptor.
const IfaceDesc = packed struct(u72) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .interface,
    /// Interface number.
    interface_number: u8,
    /// Value used to select this alternate setting for this interface.
    alternate_setting: u8,
    /// Number of endpoints used by this interface (excluding endpoint 0).
    num_endpoints: u8,
    /// Class code.
    class: u8,
    /// Subclass code.
    subclass: u8,
    /// Protocol code.
    protocol: u8,
    /// Index of string descriptor describing this interface.
    interface_index: u8,
};

/// Information required by the host to determine the bandwidth requirements of an endpoint.
///
/// Always part of a configuration descriptor.
const EpDesc = packed struct(u56) {
    /// Size of this descriptor in bytes.
    length: u8,
    /// Descriptor type.
    type: DescriptorType = .endpoint,
    /// Endpoint address.
    address: Address,
    /// Attributes of the endpoint.
    attributes: Attribute,
    /// Maximum packet size for this endpoint.
    max_packet_size: u16,
    /// Interval for polling the endpoint (in milliseconds).
    interval: u8,

    const Attribute = packed struct(u8) {
        /// Transfer type.
        transfer_type: TransferType,
        /// Reserved.
        _2: u2 = 0,
        /// Usage type.
        usage_type: UsageType,
        /// Reserved.
        _6: u2 = 0,
    };

    const TransferType = enum(u2) {
        /// Control transfer.
        control = 0,
        /// Isochronous transfer.
        isochronous = 1,
        /// Bulk transfer.
        bulk = 2,
        /// Interrupt transfer.
        interrupt = 3,
    };

    const UsageType = enum(u2) {
        /// Periodic
        periodic = 0,
        /// Notification
        notification = 1,

        _,
    };

    const Address = packed struct(u8) {
        /// Endpoint number.
        ep: u4,
        /// Reserved.
        _4: u3 = 0,
        /// Direction. Ignored for control endpoints.
        direction: RequestDirection,

        pub inline fn dci(self: Address) u5 {
            return (@as(u5, self.ep) << 1) + @as(u5, @intFromEnum(self.direction));
        }
    };
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.xhc);
const common = @import("common");
const DmaAllocator = common.mem.DmaAllocator;
const DmaMemory = DmaAllocator.DmaMemory;
const rtt = common.rtt;
const urd = @import("urthr");
const mem = urd.mem;

const Xhc = @import("Xhc.zig");
const regs = @import("registers.zig");
const rings = @import("ring.zig");
const trbs = @import("trb.zig");
const Error = @import("Xhc.zig").Error;
const Trb = trbs.Trb;
const class = @import("class.zig");
