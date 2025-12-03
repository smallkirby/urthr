//! PrimeCell UART (PL011) driver.
//!
//! ref. PrimeCell UART (PL011) Technical Reference Manual revision: r1p5

// =============================================================
// Module Definition
// =============================================================

var pl011 = Module{};

const Module = mmio.Module(u32, &.{
    .{ 0x00, Dr },
    .{ 0x04, RsrEcr },
    .{ 0x18, Fr },
    .{ 0x24, Ibrd },
    .{ 0x28, Fbrd },
    .{ 0x2C, Lcrh },
    .{ 0x30, Cr },
    .{ 0x38, Imsc },
    .{ 0x44, Icr },
});

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
    /// Reserved.
    _rsvd: u4 = 0,
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
    /// Reserved.
    _rsvd: u6 = 0,
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
    wlen: u2,
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
    /// Reserved.
    _rsvd: u5 = 0,
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
    /// Reserved.
    _rsvd: u5 = 0,
};

// =============================================================

/// Target baud rate.
const baudrate = 115_200;

/// Set the base address of the PL011 UART.
pub fn setBase(base: usize) void {
    pl011.setBase(base);
}

/// Initialize the PL011 UART.
///
/// Caller must ensure that the PL011 base addresses are set correctly beforehand.
pub fn init(clk: anytype) void {
    // Integer part of the baud rate divisor.
    const ibrd = clk / (16 * baudrate);
    // Fractional part of the baud rate divisor.
    const fbrd = blk: {
        const f = (clk - (16 * baudrate * ibrd)) * 64;
        break :blk util.roundup(f, 16 * baudrate) / (16 * baudrate);
    };

    // Wait until PL011 is not busy.
    flush();

    // Disable first.
    pl011.write(Cr, 0);

    // Set baud rate.
    pl011.write(Ibrd, ibrd);
    pl011.write(Fbrd, fbrd);

    // Enable FIFO, set 8n1.
    pl011.write(Lcrh, std.mem.zeroInit(Lcrh, .{
        .fen = true,
        .wlen = 0b11,
        .pen = false,
        .stp2 = false,
    }));

    // Enable UART, TX and RX.
    pl011.modify(Cr, .{
        .uarten = true,
        .txe = true,
        .rxe = true,
    });

    // Disable receive interrupt.
    pl011.write(Imsc, std.mem.zeroInit(Imsc, .{
        .rxim = true,
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
// Imports
// =============================================================

const std = @import("std");
const atomic = std.atomic;
const fmt = std.fmt;
const arch = @import("arch");
const common = @import("common");
const mmio = common.mmio;
const util = common.util;
