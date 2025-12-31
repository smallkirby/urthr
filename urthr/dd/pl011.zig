//! PrimeCell UART (PL011) driver.
//!
//! ref. PrimeCell UART (PL011) Technical Reference Manual revision: r1p5

// =============================================================
// Module Definition
// =============================================================

var pl011 = mmio.Module(.{ .size = u32 }, &.{
    .{ 0x00, Dr },
    .{ 0x04, RsrEcr },
    .{ 0x18, Fr },
    .{ 0x24, Ibrd },
    .{ 0x28, Fbrd },
    .{ 0x2C, Lcrh },
    .{ 0x30, Cr },
    .{ 0x38, Imsc },
    .{ 0x3C, Ris },
    .{ 0x44, Icr },
}){};

// =============================================================

/// Set the base address of the PL011 UART.
pub fn setBase(base: usize) void {
    pl011.setBase(base);
}

/// Initialize the PL011 UART.
///
/// Caller must ensure that the PL011 base addresses are set correctly beforehand.
pub fn init(clk: anytype, baudrate: u64) void {
    // Integer part of the baud rate divisor.
    const ibrd = clk / (16 * baudrate);
    // Fractional part of the baud rate divisor.
    const fbrd = blk: {
        const f = (clk - (16 * baudrate * ibrd)) * 64;
        break :blk util.roundup(f, 16 * baudrate) / (16 * baudrate);
    };

    // Disable first.
    pl011.modify(Cr, .{ .uarten = false });

    // Wait until PL011 is not busy.
    flush();

    // Flush the transmit FIFO.
    pl011.modify(Lcrh, .{ .fen = false });

    // Clear interrupts.
    pl011.write(Icr, Icr.mask());

    // Set baud rate.
    pl011.write(Ibrd, @as(u16, @intCast(ibrd)));
    pl011.write(Fbrd, @as(u6, @intCast(fbrd)));

    // Enable FIFO, set 8n1.
    pl011.write(Lcrh, std.mem.zeroInit(Lcrh, .{
        .fen = true,
        .wlen = .bits8,
    }));

    // Enable UART, TX and RX.
    pl011.write(Cr, std.mem.zeroInit(Cr, .{
        .uarten = true,
        .txe = true,
        .rxe = true,
    }));
}

/// Check if the transmit FIFO is full.
fn isTxFull() bool {
    return pl011.read(Fr).txff;
}

/// Check if the receive FIFO is empty.
fn isRxEmpty() bool {
    return pl011.read(Fr).rxfe;
}

/// Put a character to the PL011 UART.
pub fn putc(c: u8) void {
    // Wait until transmit FIFO is not full.
    while (isTxFull()) {
        atomic.spinLoopHint();
    }

    // Write data.
    pl011.write(Dr, std.mem.zeroInit(Dr, .{ .data = c }));

    // Wait until transmission is complete.
    flush();
}

/// Get a character from the PL011 UART.
///
/// This function blocks until a character is received.
pub fn getc() u8 {
    while (isRxEmpty()) {
        atomic.spinLoopHint();
    }

    return pl011.read(Dr).data;
}

/// Get a character from the PL011 UART if available.
///
/// This function returns `null` if no character is available.
pub fn tryGetc() ?u8 {
    if (isRxEmpty()) {
        return null;
    }

    return pl011.read(Dr).data;
}

/// Wait until PL011 completes transmitting the current data.
pub fn flush() void {
    while (pl011.read(Fr).busy) {
        atomic.spinLoopHint();
    }
}

// =============================================================
// Registers
// =============================================================

/// UARTDR: Data Register.
const Dr = packed struct {
    /// Receive data character / Transmit data character
    data: u8,
    /// Framing error.
    fe: bool,
    /// Parity error.
    pe: bool,
    /// Break error.
    be: bool,
    /// Overrun error.
    oe: bool,
    /// Reserved.
    _rsvd: u4 = 0,
};

/// UARTRSR / UARTECR: Receive Status / Error Clear Register.
const RsrEcr = packed struct {
    /// Framing error.
    fe: bool,
    /// Parity error.
    pe: bool,
    /// Break error.
    be: bool,
    /// Overrun error.
    oe: bool,
};

/// UARTFR: Flag Register.
const Fr = packed struct {
    /// Clear to send.
    cts: bool,
    /// Data set ready.
    dsr: bool,
    /// Data carrier detect.
    dcd: bool,
    /// UART busy.
    busy: bool,
    /// Receive FIFO empty.
    rxfe: bool,
    /// Transmit FIFO full.
    txff: bool,
    /// Receive FIFO full.
    rxff: bool,
    /// Transmit FIFO empty.
    txfe: bool,
    /// Ring indicator.
    ri: bool,
};

/// UARTIBRD: Integer Baud Rate Register.
const Ibrd = packed struct {
    /// Baud rate divisor.
    divint: u16,
};

/// UARTFBRD: Fractional Baud Rate Register.
const Fbrd = packed struct {
    /// Fractional baud rate divisor.
    divfrac: u6,
};

/// UARTLCR_H: Line Control Register.
const Lcrh = packed struct {
    /// Send break.
    brk: bool,
    /// Parity enable.
    pen: bool,
    /// Even parity select.
    eps: bool,
    /// Two stop bits select.
    stp2: bool,
    /// FIFO enable.
    fen: bool,
    /// Word length.
    wlen: enum(u2) {
        bits8 = 0b11,
        bits7 = 0b10,
        bits6 = 0b01,
        bits5 = 0b00,
    },
    /// Stick parity select.
    sps: bool,
};

/// UARTCR: Control Register.
const Cr = packed struct {
    /// UART enable.
    uarten: bool,
    /// SIR enable.
    sieren: bool,
    /// SIR low power IrDA mode.
    sirlp: bool,
    /// Reserved.
    _rsvd: u4 = 0,
    /// Loopback enable.
    lbe: bool,
    /// Transmit enable.
    txe: bool,
    /// Receive enable.
    rxe: bool,
    /// Data transmit ready.
    dtr: bool,
    /// Request to send.
    rts: bool,
    /// Complement of the UART Out1 modem status output.
    out1: bool,
    /// Complement of the UART Out2 modem status output.
    out2: bool,
    /// RTS hardware flow control enable.
    rtsen: bool,
    /// CTS hardware flow control enable.
    ctsen: bool,
};

/// UARTIMSC: Interrupt Mask Set/Clear Register.
const Imsc = packed struct {
    /// nUARTRI modem interrupt mask.
    rimm: bool,
    /// nUARTCTS modem interrupt mask.
    ctsmm: bool,
    /// nUARTDCD modem interrupt mask.
    dcdmm: bool,
    /// nUARTDSR modem interrupt mask.
    dsrmm: bool,
    /// Receive interrupt mask.
    rxim: bool,
    /// Transmit interrupt mask.
    txim: bool,
    /// Receive timeout interrupt mask.
    rtim: bool,
    /// Framing error interrupt mask.
    feim: bool,
    /// Parity error interrupt mask.
    peim: bool,
    /// Break error interrupt mask.
    beim: bool,
    /// Overrun error interrupt mask.
    oeim: bool,
};

/// UARTRIS: Raw Interrupt Status Register.
const Ris = packed struct {
    /// nUARTRI modem interrupt status.
    rirmis: bool,
    /// nUARTCTS modem interrupt status.
    ctsmmis: bool,
    /// nUARTDCD modem interrupt status.
    dcdmmis: bool,
    /// nUARTDSR modem interrupt status.
    dsrmmis: bool,
    /// Receive interrupt status.
    rxris: bool,
    /// Transmit interrupt status.
    txris: bool,
    /// Receive timeout interrupt status.
    rtris: bool,
    /// Framing error interrupt status.
    feris: bool,
    /// Parity error interrupt status.
    peris: bool,
    /// Break error interrupt status.
    beris: bool,
    /// Overrun error interrupt status.
    oeris: bool,
};

/// UARTICR: Interrupt Clear Register.
const Icr = packed struct {
    /// nUARTRI modem interrupt clear.
    rimic: bool,
    /// nUARTCTS modem interrupt clear.
    ctsmic: bool,
    /// nUARTDCD modem interrupt clear.
    dcdmic: bool,
    /// nUARTDSR modem interrupt clear.
    dsrmic: bool,
    /// Receive interrupt clear.
    rxic: bool,
    /// Transmit interrupt clear.
    txic: bool,
    /// Receive timeout interrupt clear.
    rtic: bool,
    /// Framing error interrupt clear.
    feic: bool,
    /// Parity error interrupt clear.
    peic: bool,
    /// Break error interrupt clear.
    beic: bool,
    /// Overrun error interrupt clear.
    oeic: bool,

    /// Get the mask for all bits.
    pub fn mask() std.meta.Int(.unsigned, @bitSizeOf(Icr)) {
        return 0x7FF;
    }
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const atomic = std.atomic;
const fmt = std.fmt;
const arch = @import("arch");
const common = @import("common");
const mmio = common.mmio;
const util = common.util;
