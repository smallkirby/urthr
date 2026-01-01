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

/// Initialize, identify, and select the SD card.
fn initCard() CardInfo {
    var f8 = true;
    var ccs = false;

    // CMD0: GO_IDLE_STATE
    {
        _ = issueCmd(0, false, 0).unwrap();
    }

    // CMD8: SEND_IF_COND
    {
        const res = issueCmd(8, false, 0x1AA);

        if (res.err.cmd_timeout) {
            f8 = false;
        } else _ = res.unwrap();
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

        ccs = while (true) {
            declareAcmd(null);

            const ocr = issueCmd(41, true, @bitCast(Acmd41{
                .volt_window = 0x00FF80,
                .ccs = true,
            })).unwrap().as(Ocr);

            if (ocr.not_busy) {
                break ocr.ccs;
            }
        };
    }

    // CMD2: ALL_SEND_CID
    {
        const cid = issueCmd(2, false, 0).unwrap().as(Cid);

        log.debug(
            "CID: PSN={X:0>8}, REV={d}, NAME={s}, MID={d}",
            .{ cid.psn, cid.rev, cid.name, cid.mid },
        );
    }

    // CMD3: SEND_RELATIVE_ADDR
    const rca = blk: {
        const res = issueCmd(3, false, 0).unwrap().as(u32);
        break :blk @as(u16, @truncate(res >> 16));
    };

    // CMD9: SEND_CSD
    const csd = blk: {
        const res = issueCmd(9, false, @as(u32, rca) << 16).unwrap().as(u128);
        break :blk Csd.from(res);
    };

    // Check consistency between ACMD41 and CSD.
    switch (csd) {
        .v1 => if (f8 and ccs) @panic("Inconsistent F8/CCS and CSD v1."),
        .v2 => if (!f8 or !ccs) @panic("Inconsistent F8/CCS and CSD v2."),
    }

    // CMD7: SELECT_CARD
    {
        _ = issueCmd(7, false, @as(u32, rca) << 16).unwrap();
    }

    // ACMD51: SEND_SCR
    const scr: Scr = blk: {
        // TODO

        break :blk undefined;
    };

    return CardInfo{
        .spec = if (!f8) .sdsc1 else if (!ccs) .sdsc2 else .sdhc,
        .rca = rca,
        .csd = csd,
        .scr = scr,
    };
}

/// SD card information.
const CardInfo = struct {
    /// Capacity of the card.
    spec: Spec,
    /// Relative card address.
    rca: u16,
    /// Card Specific Data.
    csd: Csd,
    /// SD Configuration Register.
    scr: Scr,

    const Spec = enum {
        /// SD Standard Capacity v1.01 or v1.10.
        sdsc1,
        /// SD Standard Capacity v2.00 or v3.00.
        sdsc2,
        /// SD High Capacity or SD Extended Capacity.
        sdhc,
    };
};

// =============================================================
// Commands
// =============================================================

/// Send CMD55 to declare next command as application-specific.
fn declareAcmd(rca: ?u16) void {
    const arg = if (rca) |v| @as(u32, v) << 16 else 0;
    const status = issueCmd(55, false, arg).unwrap().as(CardStatus);

    if (!status.app_cmd) {
        @panic("CMD55 has succeeded but ACMD not supported.");
    }
}

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

    // Set command.
    const res_type = ResponseType.of(idx, acmd);
    sdhc.write(Command, Command{
        .response = res_type.length(),
        .sub = false,
        .crc = res_type.crccheck(),
        .idx = res_type.idxcheck(),
        .data = false,
        .ctype = .normal,
        .command = idx,
    });

    // Wait for command complete.
    while (!sdhc.read(NormalInterruptStatus).cmd_complete) {
        std.atomic.spinLoopHint();
    }

    // Wait until data line is free.
    if (res_type.busy()) while (sdhc.read(PresentState).dat) {
        std.atomic.spinLoopHint();
    };

    // Check error status.
    const err_status = sdhc.read(ErrorInterruptStatus);

    // Read response if needed.
    const res0 = sdhc.read(Response0).value;
    const res1 = sdhc.read(Response1).value;
    const res2 = sdhc.read(Response2).value;
    const res3 = sdhc.read(Response3).value;

    return CommandResponse{
        .cmd = .{ .idx = idx, .acmd = acmd },
        .value = .{ ._data = bits.concatMany(u128, .{ res3, res2, res1, res0 }) },
        .err = err_status,
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
    value: Value,
    /// Error value.
    err: ErrorInterruptStatus,

    const Value = struct {
        /// 128-bit full response data.
        _data: u128,
    };

    /// Unwrap the command response, panicking on error.
    pub fn unwrap(self: CommandResponse) CommandResponse {
        if (!self.err.isNoError()) {
            log.err("{s}CMD{d} error: {}", .{
                if (self.cmd.acmd) "S" else "", self.cmd.idx, self.err,
            });
            @panic("Unrecoverable SDHC command error.");
        }

        return self;
    }

    /// Convert the response value to the specified type.
    pub fn as(self: CommandResponse, T: type) T {
        const size = @bitSizeOf(T);
        const truncated: std.meta.Int(.unsigned, size) = @truncate(self.value._data);

        return @bitCast(truncated);
    }

    /// Get the raw response value.
    pub fn raw(self: CommandResponse) u128 {
        return self.value._data;
    }
};

/// Response type of SD command.
const ResponseType = enum(u3) {
    r0,
    /// R1 (normal response command).
    r1,
    /// R1b
    r1b,
    /// R2 (CID, CSD register).
    r2,
    /// R3 (OCR register).
    r3,
    /// R6 (RCA response).
    r6,
    /// R7 (Card interface condition).
    r7,

    /// Get the response type for the given command.
    pub fn of(cmd_idx: u6, acmd: bool) ResponseType {
        return if (!acmd) switch (cmd_idx) {
            // CMD
            0 => .r0,
            55 => .r1,
            7 => .r1b,
            2, 9 => .r2,
            3 => .r6,
            8 => .r7,
            else => unreachable,
        } else switch (cmd_idx) {
            // ACMD
            51 => .r1,
            41 => .r3,
            else => unreachable,
        };
    }

    /// The response needs to wait until the card is not busy.
    pub fn busy(self: ResponseType) bool {
        return switch (self) {
            .r1b => true,
            else => false,
        };
    }

    /// Length of the response.
    pub fn length(self: ResponseType) @FieldType(Command, "response") {
        return switch (self) {
            .r0 => .no,
            .r1 => .l48,
            .r1b => .l48,
            .r2 => .l136,
            .r3 => .l48,
            .r6 => .l48,
            .r7 => .l48,
        };
    }

    /// The response needs index check.
    pub fn idxcheck(self: ResponseType) bool {
        return switch (self) {
            .r0 => false,
            .r1 => true,
            .r1b => true,
            .r2 => false,
            .r3 => false,
            .r6 => true,
            .r7 => true,
        };
    }

    /// The response needs CRC check.
    pub fn crccheck(self: ResponseType) bool {
        return switch (self) {
            .r0 => false,
            .r1 => true,
            .r1b => true,
            .r2 => false,
            .r3 => false,
            .r6 => true,
            .r7 => true,
        };
    }
};

// =============================================================
// SD Registers
// =============================================================

/// Card Status Register.
const CardStatus = packed struct(u32) {
    /// Reserved.
    _rsvd0: u3 = 0,
    /// AKE_SEQ_ERROR.
    ake_seq_error: bool,
    /// Reserved.
    _rsvd1: u1 = 0,
    /// APP_CMD
    app_cmd: bool,
    /// FX_EVENT
    fx_event: bool,
    /// Reserved.
    _rsvd2: u1 = 0,
    /// READY_FOR_DATA
    read_for_data: bool,
    /// CURRENT_STATE
    current_state: enum(u4) {
        idle = 0,
        ready = 1,
        ident = 2,
        stby = 3,
        tran = 4,
        data = 5,
        rcv = 6,
        prg = 7,
        dis = 8,
        _,
    },
    /// ERASE_RESET
    erase_reset: bool,
    /// CARD_ECC_DISABLED
    card_ecc_disabled: bool,
    /// WP_ERASE_SKIP
    wp_erase_skip: bool,
    /// CSD_OVERWRITE
    csd_overwrite: bool,
    /// Reserved.
    _rsvd3: u2 = 0,
    /// ERROR
    err: bool,
    /// CC_ERROR
    cc_error: bool,
    /// CARD_ECC_FAILED
    card_ecc_failed: bool,
    /// ILLEGAL_COMMAND
    illegal_command: bool,
    /// COM_CRC_ERROR
    com_crc_error: bool,
    /// LOCK_UNLOCK_FAILED
    lock_unlock_failed: bool,
    /// CARD_IS_LOCKED
    card_is_locked: bool,
    /// WP_VIOLATION
    wp_violation: bool,
    /// ERASE_PARAM
    erase_param: bool,
    /// ERASE_SEQ_ERROR
    erase_seq_error: bool,
    /// BLOCK_LEN_ERROR
    block_len_error: bool,
    /// ADDRESS_ERROR
    address_error: bool,
    /// OUT_OF_RANGE
    out_of_range: bool,
};

/// Operation Conditions Register.
const Ocr = packed struct(u32) {
    /// Reserved.
    _rsvd0: u15 = 0,
    /// 2.7-2.8
    v2_7_to_v2_8: bool,
    /// 2.8-2.9
    v2_8_to_v2_9: bool,
    /// 2.9-3.0
    v2_9_to_v3_0: bool,
    /// 3.0-3.1
    v3_0_to_v3_1: bool,
    /// 3.1-3.2
    v3_1_to_v3_2: bool,
    /// 3.2-3.3
    v3_2_to_v3_3: bool,
    /// 3.3-3.4
    v3_3_to_v3_4: bool,
    /// 3.4-3.5
    v3_4_to_v3_5: bool,
    /// 3.5-3.6
    v3_5_to_v3_6: bool,
    /// Switching to 1.8V Accepted
    s18a: bool,
    /// Reserved.
    _rsvd1: u2 = 0,
    /// Over 2TB support Status
    co2t: bool,
    /// Reserved.
    _rsvd2: u1 = 0,
    /// UHS-II Card Status
    uhs2status: bool,
    /// Card Capacity Status
    ccs: bool,
    /// Card power up status bit
    not_busy: bool,
};

/// Card Identification Register.
const Cid = extern struct {
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

/// Card Specific Data.
const Csd = union(CsdStructure) {
    v1: CsdV1,
    v2: CsdV2,

    pub fn from(value: u128) Csd {
        const typ: CsdStructure = @enumFromInt(bits.extract(u2, value, 126));
        const raw: u120 = @truncate(value);
        return switch (typ) {
            .v1 => .{ .v1 = @bitCast(raw) },
            .v2 => .{ .v2 = @bitCast(raw) },
            _ => @panic("Unrecognized CSD structure."),
        };
    }

    /// Version of CSD structure.
    const CsdStructure = enum(u2) {
        /// Version 1.0 (SDCD)
        v1 = 0,
        /// Version 2.0 (SDHC/SDXC)
        v2 = 1,
        _,
    };

    /// CSD Version 1.0
    const CsdV1 = packed struct(u120) {
        /// Reserved.
        _rsvd0: u1 = 0,
        /// Write protection until power cycle.
        wp_upc: bool,
        /// File format.
        format: u2,
        /// Temporary write protection.
        tpm_wp: bool,
        /// Permanent write protection.
        perm_wp: bool,
        /// Copy flag.
        copy: bool,
        /// File format group.
        format_grp: bool,
        /// Reserved.
        _rsvd1: u5 = 0,
        /// Partial blocks for write allowed.
        write_bl_partial: bool,
        /// Max write data block length.
        write_bl_len: u4,
        /// Write speed factor.
        r2w_factor: u3,
        /// Reserved.
        _rsvd2: u2 = 0,
        /// Write protect group enable.
        wp_grp_enable: bool,
        /// Write protect group size.
        wp_grp_size: u7,
        /// Erase sector size.
        sector_size: u7,
        /// Erase single block enable.
        erase_blk_en: bool,
        /// Device size multiplier.
        c_size_mult: u3,
        /// Max write current @VDD max.
        vdd_w_curr_max: u3,
        /// Max write current @VDD min.
        vdd_w_curr_min: u3,
        /// Max read current @VDD max.
        vdd_r_curr_max: u3,
        /// Max read current @VDD min.
        vdd_r_curr_min: u3,
        /// Device size.
        c_size: u12,
        /// Reserved.
        _rsvd4: u2 = 0,
        /// DSR implemented.
        dsr_imp: bool,
        /// Read block misalignment.
        read_blk_misalign: bool,
        /// Write block misalignment.
        write_blk_misalign: bool,
        /// Partial blocks for read allowed.
        read_bl_partial: bool,
        /// Max read data block length.
        read_bl_len: u4,
        /// Card command classes.
        ccc: u12,
        /// Max data transfer rate.
        tran_speed: u8,
        /// Data read access time 2.
        nsac: u8,
        /// Data read access time 1.
        taac: u8,
        /// Reserved.
        _rsvd5: u6 = 0,
        /// CSD structure.
        csd_structure: Csd.CsdStructure,
    };

    /// CSD Version 2.0
    const CsdV2 = packed struct(u120) {
        /// Reserved.
        _rsvd0: u2 = 0,
        /// File format.
        format: u2,
        /// Temporary write protection.
        tpm_wp: bool,
        /// Permanent write protection.
        perm_wp: bool,
        /// Copy flag.
        copy: bool,
        /// File format group.
        format_grp: bool,
        /// Reserved.
        _rsvd1: u5 = 0,
        /// Partial blocks for write allowed.
        write_bl_partial: bool,
        /// Max write data block length.
        write_bl_len: u4,
        /// Write speed factor.
        r2w_factor: u3,
        /// Reserved.
        _rsvd2: u2 = 0,
        /// Write protect group enable.
        wp_grp_enable: bool,
        /// Write protect group size.
        wp_grp_size: u7,
        /// Erase sector size.
        sector_size: u7,
        /// Erase single block enable.
        erase_blk_en: bool,
        /// Reserved.
        _rsvd3: u1 = 0,
        /// Device size.
        c_size: u22,
        /// Reserved.
        _rsvd4: u6 = 0,
        /// DSR implemented.
        dsr_imp: bool,
        /// Read block misalignment.
        read_blk_misalign: bool,
        /// Write block misalignment.
        write_blk_misalign: bool,
        /// Partial blocks for read allowed.
        read_bl_partial: bool,
        /// Max read data block length.
        read_bl_len: u4,
        /// Card command classes.
        ccc: u12,
        /// Max data transfer rate.
        tran_speed: u8,
        /// Data read access time 2.
        nsac: u8,
        /// Data read access time 1.
        taac: u8,
        /// Reserved.
        _rsvd5: u6 = 0,
        /// CSD structure.
        csd_structure: Csd.CsdStructure,
    };
};

/// SD Configuration Register.
///
/// Supports only SCR version 1.0.
const Scr = packed struct(u64) {
    /// Reserved for manufacturer usage.
    _rsvd0: u32 = 0,
    /// Command Support bits.
    cmd_support: u5,
    /// Reserved.
    _rsvd1: u1 = 0,
    /// Spec. Version 5.00 or higher.
    sd_specx: u4,
    /// Spec. Version 4.00 or higher.
    sd_spec4: bool,
    /// Extended Security Support.
    ex_security: u4,
    /// Spec. Version 3.00 or higher.
    sd_spec3: bool,
    /// DAT Bus widths supported.
    sd_bus_widths: u4,
    /// CPRM Security Support.
    sd_security: u3,
    /// data_status_after erases
    data_stat_after_erase: bool,
    /// SD Memory Card - Spec. Version.
    sd_spec: u4,
    /// SCR Structure.
    scr_structure: u4,
};

// =============================================================
// I/O Registers
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
