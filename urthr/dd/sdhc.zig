//! SD Host Controller.
//!
//! ref. SD Specifications Part A2 SD Host Controller Simplified Specification Version 4.20

// =============================================================
// Module Definition
// =============================================================

/// The Host Controller shall support byte, word, and double word accesses.
/// Should align register access on address boundaries matching the number of bytes in the access:
/// e.g. word accesses should be aligned on 2-byte boundaries.
var sdhc = mmio.Module(.{ .natural = u32 }, &.{
    // =========================================================
    //  Host Controller Interface Register
    .{ 0x00, Bcount32 },
    .{ 0x04, Bsize },
    .{ 0x06, Bcount16 },
    .{ 0x08, Argument },
    .{ 0x0E, Command },
    .{ 0x10, Response0 },
    .{ 0x14, Response1 },
    .{ 0x18, Response2 },
    .{ 0x1C, Response3 },
    .{ 0x24, PresentState },
    .{ 0x28, HostControl1 },
    .{ 0x29, PowerControl },
    .{ 0x2C, ClockControl },
    .{ 0x2F, SwReset },
    .{ 0x30, NormalInterruptStatus },
    .{ 0x32, ErrorInterruptStatus },
    .{ 0x34, NormalInterruptStatusEnable },
    .{ 0x36, ErrorInterruptStatusEnable },
    .{ 0x40, Capability1 },
    .{ 0x44, Capability2 },

    // =========================================================
    // Common Area Registers
    .{ 0xFC, InterruptStatus },
    .{ 0xFE, Version },
}){};

// =============================================================
// API
// =============================================================

/// Set the base address of the SD Host Controller.
pub fn setBase(base: usize) void {
    sdhc.setBase(base);
}

/// Initialize the SD Host Controller.
///
/// This function requires that the SD card is already inserted.
pub fn init() void {
    // Reset entire HC and wait until it completes.
    reset();

    // Check version.
    if (sdhc.read(Version).spec != .v3_00) {
        @panic("SDHC driver supports only Version 3.00.");
    }

    // Detect card.
    if (!sdhc.read(PresentState).card_inserted) {
        @panic("No SD card inserted.");
    }

    // Setup clock.
    initClock();

    // Setup power control.
    initPower();

    // Setup bus.
    initBus();

    // Initialize card.
    const card_info = initCard();
    log.debug("SD card detected: {t}, RCA={X:0>4}", .{ card_info.spec, card_info.rca });
}

/// Reset entire Host Controller.
pub fn reset() void {
    sdhc.write(SwReset, SwReset{
        .all = true,
        .cmd = false,
        .data = false,
    });

    // Wait for reset to complete.
    while (sdhc.read(SwReset).all) {
        std.atomic.spinLoopHint();
    }

    // Enable all interrupt status.
    sdhc.write(NormalInterruptStatusEnable, 0xFFFF);
    sdhc.write(ErrorInterruptStatusEnable, 0xFFFF);
}

/// Get the SD Host Controller version.
pub fn version() u8 {
    return @intFromEnum(sdhc.read(Version).spec);
}

// =============================================================
// Internals
// =============================================================

/// Setup SD card clock.
fn initClock() void {
    const cap1 = sdhc.read(Capability1);
    const cap2 = sdhc.read(Capability2);

    if (cap1.base_freq == 0) {
        @panic("SDHC base clock frequency is 0.");
    }
    if (cap2.clock_mult != 0) {
        @panic("SDHC clock multiplier is not supported.");
    }

    // Set Divided Clock Mode.
    const sdclk = 400 * 1000; // ~ 400 KHz
    const base = @as(u64, cap1.base_freq) * 1_000_000;
    const divisor = base / (sdclk * 2);
    sdhc.modify(ClockControl, .{
        .clk_gen_sel = .div,
        .sdclk_freq_sel = @as(u10, @intCast(divisor)),
    });

    // Enable internal clock.
    sdhc.modify(ClockControl, .{
        .int_clk_en = true,
    });

    // Wait until internal clock is stable.
    while (!sdhc.read(ClockControl).int_clk_stable) {
        std.atomic.spinLoopHint();
    }

    // Enable PLL.
    sdhc.modify(ClockControl, .{
        .pll_clk_en = true,
    });

    // Enable SD clock.
    sdhc.modify(ClockControl, .{
        .sd_clk_en = true,
    });
}

/// Initialize power control.
fn initPower() void {
    const cap1 = sdhc.read(Capability1);
    const voltage: @FieldType(PowerControl, "sd_voltage") = if (cap1.v1_8)
        .v1_8
    else if (cap1.v3_0)
        .v3_0
    else if (cap1.v3_3)
        .v3_3
    else
        @panic("No supported voltage found in SDHC.");

    // Select voltage.
    sdhc.modify(PowerControl, .{
        .sd_voltage = voltage,
    });

    // Enable power.
    sdhc.modify(PowerControl, .{
        .sd_power = .on,
    });
}

/// Initialize bus settings.
fn initBus() void {
    sdhc.modify(HostControl1, .{
        .data_width = .b1,
        .highspeed = false,
        .dma_select = .none,
    });
}

/// Initialize SD card and identification.
fn initCard() CardInfo {
    var f8 = true;
    var ccs = false;

    // CMD0: GO_IDLE_STATE
    {
        issueCmd(0, false, 0).unwrap();
    }

    // CMD8: SEND_IF_COND
    {
        const res = issueCmd(8, false, 0x1AA);

        if (res.err.cmd_timeout) {
            f8 = false;
        } else res.unwrap();
    }

    // ACMD41: SEND_OP_COND
    {
        const Acmd41 = packed struct(u32) {
            /// Voltage Window.
            volt_window: u24,
            /// S18R.
            s18r: bool = false,
            /// Reserved.
            _rsvd0: u3 = 0,
            /// XPC.
            xpc: bool = false,
            /// Reserved.
            _rsvd1: u1 = 0,
            /// Card Capacity Status.
            ccs: bool,
            /// Busy.
            busy: bool = false,
        };

        var ocr: u32 = undefined;
        while (true) {
            const acmd_bit_pos = 5;
            const res55 = issueCmd(55, false, 0).unwrapValue();
            if (!bits.isset(res55, acmd_bit_pos)) {
                @panic("CMD55 has succeeded but ACMD not supported.");
            }

            const res = issueCmd(41, true, @bitCast(Acmd41{
                .volt_window = 0x00FF80,
                .ccs = true,
            }));
            res.unwrap();

            ocr = @truncate(res.value);
            const busy_bit_pos = 31;
            if (bits.isset(ocr, busy_bit_pos)) {
                break;
            }
        }

        const ccs_bit_pos = 30;
        ccs = bits.isset(ocr, ccs_bit_pos);
    }

    // CMD2: ALL_SEND_CID
    {
        const Cid = extern struct {
            // CRC is consumed internally and not included here.
            /// Manufacturing date.
            date: u16,
            /// Product serial number.
            psn: u32 align(1),
            /// Product revision.
            rev: u8,
            /// Product name.
            name: [5]u8,
            /// OEM / Application ID.
            oem_id: [2]u8,
            /// Manufacturer ID.
            mid: u8,
        };
        comptime if (@bitSizeOf(Cid) != 128) @compileError("Invalid CID size.");

        const res = issueCmd(2, false, 0).unwrapValue();
        const cid: Cid = @bitCast(@as(u128, @truncate(res >> 0)));

        log.debug(
            "CID: PSN={X:0>8}, REV={d}, NAME={s}, MID={d}",
            .{ cid.psn, cid.rev, cid.name, cid.mid },
        );
    }

    // CMD3: SEND_RELATIVE_ADDR
    const rca = blk: {
        const res = issueCmd(3, false, 0).unwrapValue();
        break :blk @as(u16, @truncate(res >> 16));
    };

    return CardInfo{
        .spec = if (!f8) .sdsc1 else if (!ccs) .sdsc2 else .sdhc,
        .rca = rca,
    };
}

/// Response and error value for SDHC command.
const CommandResponse = struct {
    /// Command.
    cmd: struct {
        /// Command index.
        idx: u6,
        /// Is an application-specific command.
        acmd: bool,
    },
    /// Command response value.
    value: u136,
    /// Error value.
    err: ErrorInterruptStatus,

    pub fn unwrap(self: CommandResponse) void {
        if (!self.err.isNoError()) {
            log.err("{s}CMD{d} error: {}", .{
                if (self.cmd.acmd) "S" else "", self.cmd.idx, self.err,
            });
            @panic("Unrecoverable SDHC command error.");
        }
    }

    pub fn unwrapValue(self: CommandResponse) u136 {
        self.unwrap();
        return self.value;
    }
};

/// Issue a command to the SD card.
fn issueCmd(idx: u6, acmd: bool, arg: u32) CommandResponse {
    // Wait until command and data lines are free.
    while (sdhc.read(PresentState).cmd or sdhc.read(PresentState).dat) {
        std.atomic.spinLoopHint();
    }

    // Clear interrupt status.
    sdhc.write(NormalInterruptStatus, 0xFFFF);

    // Set argument.
    sdhc.write(Argument, Argument{ .value = arg });

    // Response type.
    const res_type: u3 = if (!acmd) switch (idx) {
        // R0
        0 => 0,
        // R1
        55 => 1,
        // R2
        2 => 2,
        // R6
        3 => 6,
        // R7
        8 => 7,
        else => unreachable,
    } else switch (idx) {
        // R1
        41 => 1,
        else => unreachable,
    };

    // Set command.
    const res_length: @FieldType(Command, "response") = switch (res_type) {
        0 => .no,
        2 => .l136,
        1 => .l48,
        6 => .l48,
        7 => .l48,
        else => unreachable,
    };
    const idx_check = switch (res_type) {
        0 => false,
        1 => true,
        2 => false,
        6 => true,
        7 => true,
        else => unreachable,
    };
    const crc_check = switch (res_type) {
        0 => false,
        1 => true,
        2 => false,
        6 => true,
        7 => true,
        else => unreachable,
    };
    sdhc.write(Command, Command{
        .response = res_length,
        .sub = false,
        .crc = crc_check,
        .idx = idx_check,
        .data = false,
        .ctype = .normal,
        .command = idx,
    });

    // Wait for command complete.
    while (!sdhc.read(NormalInterruptStatus).cmd_complete) {
        std.atomic.spinLoopHint();
    }

    // Check error status.
    const err_status = sdhc.read(ErrorInterruptStatus);

    // Read response if needed.
    const res0 = sdhc.read(Response0).value;
    const res1 = sdhc.read(Response1).value;
    const res2 = sdhc.read(Response2).value;
    const res3 = sdhc.read(Response3).value;

    return CommandResponse{
        .cmd = .{ .idx = idx, .acmd = acmd },
        .value = bits.concatMany(u128, .{ res3, res2, res1, res0 }),
        .err = err_status,
    };
}

const CardInfo = struct {
    /// Capacity of the card.
    spec: CardSpec,
    /// Relative card address.
    rca: u16,
};

const CardSpec = enum {
    /// SD Standard Capacity v1.01 or v1.10.
    sdsc1,
    /// SD Standard Capacity v2.00 or v3.00.
    sdsc2,
    /// SD High Capacity or SD Extended Capacity.
    sdhc,
};

// =============================================================
// Registers
// =============================================================

// =============================================================
//  Host Controller Interface Register

/// 32-bit Block Count Register (SDMA System Address Register).
const Bcount32 = packed struct(u32) {
    /// When Host Version 4 Enable = 0, SDMA System Address.
    /// When Host Version 4 Enable = 1, 32-bit Block Count.
    value: u32,
};

/// Block Size Register.
const Bsize = packed struct(u16) {
    /// Transfer Block Size.
    bsize: u12,
    /// SDMA Buffer Boundary.
    boundary: enum(u3) {
        /// 4K bytes.
        k4 = 0b000,
        /// 8K bytes.
        k8 = 0b001,
        /// 16K bytes.
        k16 = 0b010,
        /// 32K bytes.
        k32 = 0b011,
        /// 64K bytes.
        k64 = 0b100,
        /// 128K bytes.
        k128 = 0b101,
        /// 256K bytes.
        k256 = 0b110,
        /// 512K bytes.
        k512 = 0b111,
    },
    /// Reserved.
    _rsvd: u1 = 0,
};

/// 16-bit Block Count Register.
const Bcount16 = packed struct(u16) {
    /// 16-bit Block Count.
    value: u16,
};

/// Argument Register.
const Argument = packed struct(u32) {
    /// Command Argument.
    value: u32,
};

/// Command Register.
const Command = packed struct(u16) {
    /// Response Type Select.
    response: enum(u2) {
        /// No response.
        no = 0b00,
        /// R2: Response Length 136.
        l136 = 0b01,
        /// R1, R3, R6, R7, R8: Response Length 48.
        l48 = 0b10,
        /// Response Length 48 check Busy after response.
        l48_busy = 0b11,
    },
    /// Sub Command Flag.
    sub: bool,
    /// Command CRC Check Enable.
    crc: bool,
    /// Command Index Check Enable.
    idx: bool,
    /// Data Present Select.
    data: bool,
    /// Command Type.
    ctype: enum(u2) {
        /// Normal Command.
        normal = 0b00,
        /// Suspend Command.
        @"suspend" = 0b01,
        /// Resume Command.
        @"resume" = 0b10,
        /// Abort Command.
        abort = 0b11,
    },
    /// Command Index.
    command: u6,
    /// Reserved.
    _rsvd: u2 = 0,
};

/// Response Register 0.
const Response0 = packed struct(u32) {
    /// Response bits [31:0].
    value: u32,
};

/// Response Register 1.
const Response1 = packed struct(u32) {
    /// Response bits [63:32].
    value: u32,
};

/// Response Register 2.
const Response2 = packed struct(u32) {
    /// Response bits [95:64].
    value: u32,
};

/// Response Register 3.
const Response3 = packed struct(u32) {
    /// Response bits [127:96].
    value: u32,
};

/// Present State Register.
const PresentState = packed struct(u32) {
    /// Command Inhibit (CMD).
    cmd: bool,
    /// Command Inhibit (DAT).
    dat: bool,
    /// DAT Line Active.
    dat_active: bool,
    /// Re-Tuning Request.
    retune: bool,
    /// DAT[7:4] Line Signal Level.
    dat_level_high: u4,

    /// Write Transfer Active.
    write_active: bool,
    /// Read Transfer Active.
    read_active: bool,
    /// Buffer Write Enable.
    buf_write_en: bool,
    /// Buffer Read Enable.
    buf_read_en: bool,
    /// Reserved.
    _rsvd0: u4 = 0,

    /// Card Inserted.
    card_inserted: bool,
    /// Card State Stable.
    card_stable: bool,
    /// Card Detect Pin Level.
    card_detect_level: enum(u1) {
        /// No card present (SDCD#=0).
        not_present = 0,
        /// Card present (SDCD#=1).
        present = 1,
    },
    /// Write Protect Switch Pin Level.
    wp_switch_pin: bool,
    /// DAT[3:0] Line Signal Level.
    dat_level_low: u4,

    /// CMD Line Signal Level.
    cmd_level: bool,
    /// Host Regulator Voltage Stable.
    voltage_stable: bool,
    /// Reserved.
    _rsvd1: u1 = 0,
    /// Command Not Issued by Error.
    nocmd_error: bool,
    /// Sub Command Status.
    subcmd: bool,
    /// In Dormant State.
    indormant: bool,
    /// Lane Synchronization.
    lane_sync: bool,
    /// UHS-II Interface Detect.
    uhs2if_detect: bool,
};

/// Host Control 1 Register.
const HostControl1 = packed struct(u8) {
    /// LED Control.
    led_control: bool,
    /// Data Trafsfer Width.
    data_width: enum(u1) {
        /// 1-bit.
        b1 = 0,
        /// 4-bit.
        b4 = 1,
    },
    /// High Speed Enable.
    highspeed: bool,
    /// DMA Select.
    dma_select: enum(u2) {
        /// SDMA.
        none = 0b00,
        /// 32-bit Address ADMA2.
        adma2b32 = 0b10,
        /// 64-bit Address ADMA2.
        adma2b64 = 0b11,

        _,
    },
    /// Extended Data Transfer Width.
    ext_width: enum(u1) {
        /// Selected by Data Transfer Width.
        match = 0,
        /// 8-bit.
        b8 = 1,
    },
    /// Card Detect Test Level.
    card_detect: bool,
    /// Card Detect Signal Selection.
    card_detect_sel: enum(u1) {
        /// SDCD# is selected.
        sdcd = 0,
        /// The Card Detect Test Level is selected.
        test_level = 1,
    },
};

/// Power Control Register.
const PowerControl = packed struct(u8) {
    /// SD Bus Power for VDD1.
    sd_power: enum(u1) {
        /// Power Off.
        off = 0,
        /// Power On.
        on = 1,
    },
    /// SD Bus Voltage Select for VDD1.
    sd_voltage: enum(u3) {
        /// 1.8V.
        v1_8 = 0b101,
        /// 3.0V.
        v3_0 = 0b110,
        /// 3.3V.
        v3_3 = 0b111,
        _,
    },
    /// SD Bus Power for VDD2.
    sd_power_vdd2: enum(u1) {
        /// Power Off.
        off = 0,
        /// Power On.
        on = 1,
    },
    /// SD Bus Voltage Select for VDD2.
    sd_voltage_vdd2: enum(u3) {
        /// VDD2 Not Supported.
        not_supported = 0b000,
        /// 1.8V.
        v1_8 = 0b101,
        _,
    },
};

/// Clock Control Register.
const ClockControl = packed struct(u16) {
    /// Internal Clock Enable.
    int_clk_en: bool,
    /// Internal Clock Stable.
    int_clk_stable: bool,
    /// SD Clock Enable.
    sd_clk_en: bool,
    /// PLL Enable.
    pll_clk_en: bool,
    /// Reserved.
    _rsvd0: u1 = 0,
    /// Clock Generator Select.
    clk_gen_sel: enum(u1) {
        /// Programmable Clock Mode.
        prog = 0,
        /// Divided Clock Mode.
        div = 1,
    },
    /// SDCLK / RCLK Frequency Select.
    sdclk_freq_sel: u10,
};

/// Software Reset Register.
const SwReset = packed struct(u8) {
    /// Reset for All.
    ///
    /// Affects entire HC except for the card detection circuit.
    all: bool,
    /// Reset for CMD Line.
    cmd: bool,
    /// Reset for DAT Line.
    data: bool,
    /// Reserved.
    _rsvd: u5 = 0,
};

/// Error Interrupt Status Register.
const ErrorInterruptStatus = packed struct(u16) {
    /// Command Timeout Error.
    cmd_timeout: bool,
    /// Command CRC Error.
    cmd_crc: bool,
    /// Command End Bit Error.
    cmd_endbit: bool,
    /// Command Index Error.
    cmd_index: bool,
    /// Data Timeout Error.
    data_timeout: bool,
    /// Data CRC Error.
    data_crc: bool,
    /// Data End Bit Error.
    data_endbit: bool,
    /// Current Limit Error.
    curr_limit: bool,

    /// Auto CMD Error.
    auto_cmd: bool,
    /// ADMA Error.
    adma: bool,
    /// Tuning Error.
    tuning: bool,
    /// Response Error.
    response: bool,
    /// Reserved.
    _rsvd: u4 = 0,

    /// No errors.
    pub fn isNoError(self: ErrorInterruptStatus) bool {
        return std.mem.zeroInit(ErrorInterruptStatus, .{}) == self;
    }
};

/// Normal Interrupt Status Enable Register.
const NormalInterruptStatusEnable = packed struct(u16) {
    /// Command Complete Enable.
    cmd_complete: bool,
    /// Transfer Complete Enable.
    transfer_complete: bool,
    /// Block Gap Event Enable.
    block_gap_event: bool,
    /// DMA Interrupt Enable.
    dma_interrupt: bool,
    /// Buffer Write Ready Enable.
    buf_write_ready: bool,
    /// Buffer Read Ready Enable.
    buf_read_ready: bool,
    /// Card Insertion Enable.
    card_insertion: bool,
    /// Card Removal Enable.
    card_removal: bool,

    /// Card Interrupt Enable.
    card_interrupt: bool,
    /// INT_A Enable.
    int_a: bool,
    /// INT_B Enable.
    int_b: bool,
    /// INT_C Enable.
    int_c: bool,
    /// Re-Tuning Event Enable.
    retune_event: bool,
    /// FX Event Enable.
    fx_event: bool,
    /// Reserved.
    _rsvd: u1 = 0,
    /// Error Interrupt Enable.
    error_interrupt: bool,
};

/// Normal Interrupt Status Register.
const NormalInterruptStatus = packed struct(u16) {
    /// Command Complete.
    cmd_complete: bool,
    /// Transfer Complete.
    transfer_complete: bool,
    /// Block Gap Event.
    block_gap_event: bool,
    /// DMA Interrupt.
    dma_interrupt: bool,
    /// Buffer Write Ready.
    buf_write_ready: bool,
    /// Buffer Read Ready.
    buf_read_ready: bool,
    /// Card Insertion.
    card_insertion: bool,
    /// Card Removal.
    card_removal: bool,

    /// Card Interrupt.
    card_interrupt: bool,
    /// INT_A.
    int_a: bool,
    /// INT_B.
    int_b: bool,
    /// INT_C.
    int_c: bool,
    /// Re-Tuning Event.
    retune_event: bool,
    /// FX Event.
    fx_event: bool,
    /// Reserved.
    _rsvd: u1 = 0,
    /// Error Interrupt.
    error_interrupt: bool,
};

/// Error Interrupt Status Enable Register.
const ErrorInterruptStatusEnable = packed struct(u16) {
    /// Command Timeout Error Enable.
    cmd_timeout: bool,
    /// Command CRC Error Enable.
    cmd_crc: bool,
    /// Command End Bit Error Enable.
    cmd_endbit: bool,
    /// Command Index Error Enable.
    cmd_index: bool,
    /// Data Timeout Error Enable.
    data_timeout: bool,
    /// Data CRC Error Enable.
    data_crc: bool,
    /// Data End Bit Error Enable.
    data_endbit: bool,
    /// Current Limit Error Enable.
    curr_limit: bool,

    /// Auto CMD Error Enable.
    auto_cmd: bool,
    /// ADMA Error Enable.
    adma: bool,
    /// Tuning Error Enable.
    tuning: bool,
    /// Response Error Enable.
    response: bool,
    /// Reserved.
    _rsvd: u4 = 0,
};

/// Capabilities Register 1.
const Capability1 = packed struct(u32) {
    /// Timeout Clock Frequency.
    timeout_freq: u6,
    /// Reserved.
    _rsvd0: u1 = 0,
    /// Timeout Clock Unit.
    timeout_unit: enum(u1) {
        /// KHz
        khz = 0,
        /// MHz
        mhz = 1,
    },
    /// Base Clock Frequency For SD Clock.
    base_freq: u8,

    /// Max Block Length,
    max_block_len: enum(u2) {
        /// 512 bytes.
        b512 = 0b00,
        /// 1024 bytes.
        b1024 = 0b01,
        /// 2048 bytes.
        b2048 = 0b10,
        _,
    },
    /// 8-bit Support for Embedded Device.
    support8bit: bool,
    /// ADMA2 Support.
    adma2: bool,
    /// Reserved.
    _rsvd1: u1 = 0,
    /// High Speed Support.
    highspeed: bool,
    /// SDMA Support.
    sdma: bool,
    /// Suspend/Resume Support.
    suspend_resume: bool,
    /// Voltage Support 3.3V.
    v3_3: bool,
    /// Voltage Support 3.0V.
    v3_0: bool,
    /// Voltage Support 1.8V.
    v1_8: bool,
    /// 64-bit System Address Support for V4.
    sysaddr64_v4: bool,
    /// 64-bit System Address Support for V3.
    sysaddr64_v3: bool,
    /// Asynchronous Interrupt Support.
    async_interrupt: bool,
    /// Slot Type.
    slot_type: enum(u2) {
        /// Removable Slot.
        removable = 0b00,
        /// Embedded Slot for One Device.
        embedded = 0b01,
        /// Embedded Bus Slot (SD Mode).
        shared_bus = 0b10,
        /// UHS-II Multiple Embedded Devices.
        uhs2_multi = 0b11,
    },
};

/// Capabilities Register 2.
const Capability2 = packed struct(u32) {
    /// SDR50 Support.
    sdr50: bool,
    /// SDR104 Support.
    sdr104: bool,
    /// DDR50 Support.
    ddr50: bool,
    /// UHS-II Support.
    uhs2: bool,
    /// Driver Type A Support.
    driver_type_a: bool,
    /// Driver Type C Support.
    driver_type_c: bool,
    /// Driver Type D Support.
    driver_type_d: bool,
    /// Reserved.
    _rsvd2: u1 = 0,
    /// Timer Count for Re-Tuning.
    timer_retune: u4,
    /// Reserved.
    _rsvd3: u1 = 0,
    /// Use Tuning for SDR50.
    use_tune_sdr50: bool,
    /// Re-Tuning Modes.
    retune_mode: u2,
    /// Clock Multiplier.
    ///
    /// 0 means the clock multiplier is not supported.
    clock_mult: u8,
    /// Reserved.
    _rsvd4: u3 = 0,
    /// ADMA3 Support.
    adma3: bool,
    /// 1.8V VDD2 Support.
    vdd2_1_8v: bool,
    /// Reserved.
    _rsvd5: u3 = 0,
};

// =============================================================
// Common Area Registers

/// Slot Interrupt Status Register.
const InterruptStatus = packed struct(u16) {
    /// Interrupt Signal For Each Slot.
    signals: u8,
    /// Reserved.
    _rsvd: u8 = 0,
};

/// Host Controller Version Register.
const Version = packed struct(u16) {
    /// Specification Version Number.
    spec: enum(u8) {
        v1_00 = 0x00,
        v2_00 = 0x01,
        v3_00 = 0x02,
        v4_00 = 0x03,
        v4_10 = 0x04,
        v4_20 = 0x05,
        _,
    },
    /// Vendor Version Number.
    vendor: u8,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const log = std.log.scoped(.sdhc);
const common = @import("common");
const bits = common.bits;
const mmio = common.mmio;
