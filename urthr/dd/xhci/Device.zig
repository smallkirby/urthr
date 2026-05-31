const Self = @This();

/// xHC controller.
xhc: *Xhc,
/// Transfer Ring for Endpoint 0.
tr: rings.Ring = undefined,

/// Device state.
state: State,

/// Port index (1-origin).
pi: usize,
/// Port register.
pr: regs.Port,
/// Slot ID assigned to the device.
slot: u8 = undefined,
/// Device descriptor provided by the device.
desc: DeviceDesc = undefined,

/// Pending TRB that waits for completion of the current operation.
pending_trb: ?*const volatile trbs.Trb = null,
/// Pending Data TRB that's waiting for a Transfer Event.
pending_data: ?PendingData = null,

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

pub fn new(xhc: *Xhc, pi: usize, pr: regs.Port) mem.Error!*Self {
    const self = try mem.bin.create(Self);
    errdefer mem.bin.destroy(self);

    self.* = .{
        .xhc = xhc,
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

/// Request to assign the address to the device.
pub fn assignAddress(self: *Self, slot: u8) Error!void {
    rtt.expectEqual(.waiting_slot, self.state);
    rtt.expect(slot != 0);

    self.slot = slot;

    // Allocate a Device Context region.
    const dc = try mem.page.allocPagesV(1);
    errdefer mem.page.freePagesV(dc);
    @memset(dc, 0);
    self.xhc.setDeviceContext(slot, dc);

    // Create Input Context.
    const ic = try mem.page.create(InputContext);
    errdefer mem.page.destroy(ic);
    @memset(std.mem.asBytes(ic), 0);

    // Configure Input Control Context (enable Slot Context and Endpoint 0)
    {
        const control = &ic.control;
        control.ac.a0 = true;
        control.ac.a1 = true;
    }
    // Configure Slot Context.
    {
        const slot_ctx = &ic.slot;
        slot_ctx.* = .{
            .root_hub_port = @intCast(self.pi),
            .context_entries = 1,
            .max_exit_latency = 0,
            .addr = 0,
            .intr_target = 0,
        };
    }
    // Configure EP0 (Default Control Pipe) Context.
    {
        const tr = try rings.Ring.new(rings.trbs_per_page, mem.page);
        errdefer tr.deinit(urd.page);
        self.tr = tr;

        const speed = self.pr.read(regs.PortSc).speed;
        ic.getEp0Ctx().* = .{
            .ep_type = .control,
            .max_packet_size = speed.maxPacketSize(),
            .interval = 0,
            .cerr = 0,
            .trdp = @intCast(mem.page.translateIntP(&self.tr.trbs[0]) >> 4),
            .dcs = tr.pcs,
        };
    }

    // Request to assign the address.
    self.state = .waiting_address;
    var cmd = trbs.AddressDeviceTrb.from(slot, ic);
    self.pending_trb = self.xhc.cring.push(.from(&cmd));
    self.xhc.dbs.notifyCommand();
}

/// Called when the address has been successfully assigned to the device.
pub fn onAddressAssigned(self: *Self) Error!void {
    rtt.expectEqual(.waiting_address, self.state);

    self.state = .waiting_device_desc;

    // Setup GET_DESCRIPTOR request for device descriptor
    const Value = packed struct(u16) {
        /// Descriptor number.
        desc_index: u8,
        /// Type of descriptor.
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
    try self.controlTransferIn(setup_data);
}

// =============================================================
// Transfer event handlers
// =============================================================

/// Callback for Transfer Event TRB.
pub fn onTransferEvent(self: *Self, event: *const volatile trbs.TransferEventTrb) Error!void {
    const issuer: *const trbs.Trb =
        @ptrFromInt(mem.page.translateV(event.trb));

    switch (issuer.type) {
        .status => try self.onStatusTransfer(event, @ptrCast(issuer)),
        else => log.err(
            "Unexpected TRB type in Transfer Event: {d}",
            .{@intFromEnum(issuer.type)},
        ),
    }
}

/// Called when a Transfer Event TRB is received for a Status Stage TRB.
fn onStatusTransfer(self: *Self, event: *const volatile trbs.TransferEventTrb, issuer: *const trbs.StatusTrb) Error!void {
    const code = event.code;

    switch (self.state) {
        // Device descriptor is provided.
        .waiting_device_desc => {
            if (code != .success) {
                log.err("Failed to get device descriptor: {d}", .{code});
                return;
            }
            const pending = self.popPendingData();
            self.pending_trb = null;
            rtt.expectEqual(pending.status, issuer);

            const dtrb = pending.data;
            const desc: *const volatile DeviceDesc = @ptrFromInt(mem.page.translateV(dtrb.data_buffer));
            self.desc = desc.*;
            rtt.expectEqual(.device, desc.type);

            // TODO: free the DMA buffer associated with the Data TRB.

            self.state = .waiting_config_desc;
            // TODO: request configuration descriptor.
        },

        // Unexpected state.
        else => log.warn("Unexpected transfer event for control transfer while state is {t}", .{self.state}),
    }
}

// =============================================================
// Utility
// =============================================================

/// Perform a control transfer in the device-to-host direction on endpoint 0 (Default Control Pipe).
///
/// TODO: support transfer to other than control endpoint.
pub fn controlTransferIn(self: *Self, data: SetupData) Error!void {
    // TODO: Free the allocated memory on event completion.
    const buf = try mem.page.allocBytesP(data.length);
    errdefer mem.page.freeBytesP(buf);

    // Setup Stage
    var setup_trb = trbs.SetupTrb{
        .request_type = @bitCast(data.request_type),
        .request = @intFromEnum(data.request),
        .value = data.value,
        .index = data.index,
        .length = data.length,
        .cycle = undefined,
        .ioc = false,
        .trt = .in,
        .idt = true,
        .intr_target = 0,
    };
    _ = self.tr.push(.from(&setup_trb));

    // Data Stage
    var data_trb = trbs.DataTrb{
        .data_buffer = @intFromPtr(buf.ptr),
        .transfer_length = data.length,
        .td_size = 0,
        .cycle = undefined,
        .ent = false,
        .isp = false,
        .ns = false,
        .chain = true,
        .ioc = false,
        .idt = false,
        .direction = .in,
        .intr_target = 0,
    };
    const dtrb = self.tr.push(.from(&data_trb));

    // Status Stage
    // Generates an event when complete.
    var status_trb = trbs.StatusTrb{
        .cycle = undefined,
        .ent = false,
        .chain = false,
        .ioc = true,
        .direction = .out,
        .intr_target = 0,
    };
    const strb = self.tr.push(.from(&status_trb));
    self.pending_trb = strb;

    // Push the Data TRB.
    if (data.length > 0) {
        self.pushPendingData(strb, dtrb);
    }

    // Ring the doorbell for this slot
    const ep0_dci = calcDci(0, .in);
    self.xhc.dbs.notifyEndpoint(self.slot, ep0_dci);
}

/// Calculate the Device Context Index (DCI).
fn calcDci(ep: u4, direction: RequestDirection) u5 {
    return (@as(u5, ep) << 1) + @as(u5, @intFromEnum(direction));
}

/// Pending Data TRB that waits for completion of a transfer operation.
const PendingData = struct {
    /// Pointer to Status TRB that will be triggered when the transfer is complete.
    status: *const volatile trbs.StatusTrb,
    /// Pointer to Data TRB that describes the transfer.
    data: *const volatile trbs.DataTrb,
};

/// Records the pending data transfer operations.
fn pushPendingData(self: *Self, status: *const Trb, data: *const Trb) void {
    rtt.expectEqual(null, self.pending_data);

    self.pending_data = .{
        .status = @ptrCast(status),
        .data = @ptrCast(data),
    };
}

/// Pop the pending data transfer operation.
fn popPendingData(self: *Self) PendingData {
    rtt.expect(self.pending_data != null);

    const ret = self.pending_data.?;
    self.pending_data = null;
    return ret;
}

// =============================================================
// Data structures
// =============================================================

/// Defines device configuration and state information that is passed to the xHC.
const InputContext = packed struct {
    control: InputControlContext,
    slot: SlotContext,
    ep0: EndpointContext,
    ep1out: EndpointContext,
    ep1in: EndpointContext,
    ep2out: EndpointContext,
    ep2in: EndpointContext,
    ep3out: EndpointContext,
    ep3in: EndpointContext,
    ep4out: EndpointContext,
    ep4in: EndpointContext,
    ep5out: EndpointContext,
    ep5in: EndpointContext,
    ep6out: EndpointContext,
    ep6in: EndpointContext,
    ep7out: EndpointContext,
    ep7in: EndpointContext,
    ep8out: EndpointContext,
    ep8in: EndpointContext,
    ep9out: EndpointContext,
    ep9in: EndpointContext,
    ep10out: EndpointContext,
    ep10in: EndpointContext,
    ep11out: EndpointContext,
    ep11in: EndpointContext,
    ep12out: EndpointContext,
    ep12in: EndpointContext,
    ep13out: EndpointContext,
    ep13in: EndpointContext,
    ep14out: EndpointContext,
    ep14in: EndpointContext,
    ep15out: EndpointContext,
    ep15in: EndpointContext,

    comptime {
        urd.comptimeAssert(
            @sizeOf(InputContext) == 0x420,
            "Invalid Input Context size: 0x{X}, expected 0x420",
            .{@sizeOf(InputContext)},
        );
    }

    inline fn getEp0Ctx(self: *InputContext) *EndpointContext {
        return @ptrFromInt(@intFromPtr(self) + @offsetOf(InputContext, "ep0"));
    }

    inline fn at(self: *InputContext, dci: u5) *EndpointContext {
        return switch (dci) {
            0 => unreachable,
            1 => &self.ep0,
            2 => &self.ep1out,
            3 => &self.ep1in,
            4 => &self.ep2out,
            5 => &self.ep2in,
            6 => &self.ep3out,
            7 => &self.ep3in,
            8 => &self.ep4out,
            9 => &self.ep4in,
            10 => &self.ep5out,
            11 => &self.ep5in,
            12 => &self.ep6out,
            13 => &self.ep6in,
            14 => &self.ep7out,
            15 => &self.ep7in,
            16 => &self.ep8out,
            17 => &self.ep8in,
            18 => &self.ep9out,
            19 => &self.ep9in,
            20 => &self.ep10out,
            21 => &self.ep10in,
            22 => &self.ep11out,
            23 => &self.ep11in,
            24 => &self.ep12out,
            25 => &self.ep12in,
            26 => &self.ep13out,
            27 => &self.ep13in,
            28 => &self.ep14out,
            29 => &self.ep14in,
            30 => &self.ep15out,
            31 => &self.ep15in,
        };
    }
};

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
    /// Reserved.
    ///
    /// Previously used for Speed.
    _20: u4 = 0,
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
    ep_state: EndpointState = undefined,
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

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.xhc);
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const mem = urd.mem;

const Xhc = @import("Xhc.zig");
const regs = @import("registers.zig");
const rings = @import("ring.zig");
const trbs = @import("trb.zig");
const Error = @import("Xhc.zig").Error;
const Trb = trbs.Trb;
