//! 16550 UART driver.
//!
//! Supports only Port I/O.

// =============================================================
// Module Definition
// =============================================================

var uart = pio.Module(&.{
    .{ 0x00, Rbr },
    .{ 0x00, Thr },
    .{ 0x00, Dll },
    .{ 0x01, Ier },
    .{ 0x01, Dlm },
    .{ 0x02, Iir },
    .{ 0x02, Fcr },
    .{ 0x03, Lcr },
    .{ 0x04, Mcr },
    .{ 0x05, Lsr },
    .{ 0x06, Msr },
    .{ 0x07, Scr },
}){};

// =============================================================

/// Set the base I/O port of the 16550 UART.
pub fn setBase(base: u16) void {
    uart.setBase(base);
}

/// Initialize the 16550 UART for the given AXI clock.
///
/// Caller must ensure that the 16550 base I/O port is set correctly beforehand.
pub fn init(clk: anytype, baudrate: u64) void {
    // Divisor for the baud rate generator.
    const divisor = clk / (16 * baudrate);

    // Disable interrupts.
    uart.writez(Ier, .{});

    // Set the baud rate divisor.
    uart.modify(Lcr, .{ .dlab = true });
    uart.writez(Dll, .{ .value = @as(u8, @truncate(divisor)) });
    uart.writez(Dlm, .{ .value = @as(u8, @truncate(divisor >> 8)) });

    // Clear the divisor latch, set 8n1.
    uart.writez(Lcr, .{
        .wls = .bits8,
        .dlab = false,
    });

    // Enable FIFO, clear RX/TX FIFOs.
    uart.writez(Fcr, .{
        .fifoen = true,
        .rxrst = true,
        .txrst = true,
    });

    // Assert DTR/RTS.
    uart.writez(Mcr, .{
        .dtr = true,
        .rts = true,
    });
}

/// Check if the transmitter holding register is empty.
fn isTxReady() bool {
    return uart.read(Lsr).thre;
}

/// Check if the receiver has data available.
fn isRxReady() bool {
    return uart.read(Lsr).dr;
}

/// Put a character to the 16550 UART.
pub fn putc(c: u8) void {
    // Wait until the transmitter holding register is empty.
    while (!isTxReady()) {
        atomic.spinLoopHint();
    }

    // Write data.
    uart.writez(Thr, .{ .data = c });
}

/// Get a character from the 16550 UART.
///
/// This function blocks until a character is received.
pub fn getc() u8 {
    while (!isRxReady()) {
        atomic.spinLoopHint();
    }

    return uart.read(Rbr).data;
}

/// Get a character from the 16550 UART if available.
///
/// This function returns `null` if no character is available.
pub fn tryGetc() ?u8 {
    if (!isRxReady()) {
        return null;
    }

    return uart.read(Rbr).data;
}

/// Wait until the 16550 UART completes transmitting the current data.
pub fn flush() void {
    while (!uart.read(Lsr).temt) {
        atomic.spinLoopHint();
    }
}

// =============================================================
// Registers
// =============================================================

/// Receiver Buffer Register (DLAB=0, read-only).
const Rbr = packed struct {
    /// Received data character.
    data: u8,
};

/// Transmitter Holding Register (DLAB=0, write-only).
const Thr = packed struct {
    /// Transmit data character.
    data: u8,
};

/// Divisor Latch LSB (DLAB=1).
const Dll = packed struct {
    /// Low byte of the baud rate divisor.
    value: u8,
};

/// Divisor Latch MSB (DLAB=1).
const Dlm = packed struct {
    /// High byte of the baud rate divisor.
    value: u8,
};

/// Interrupt Enable Register (DLAB=0).
const Ier = packed struct {
    /// Enable received data available interrupt.
    erbfi: bool = false,
    /// Enable transmitter holding register empty interrupt.
    etbei: bool = false,
    /// Enable receiver line status interrupt.
    elsi: bool = false,
    /// Enable modem status interrupt.
    edssi: bool = false,
    /// Reserved.
    _4: u4 = 0,
};

/// Interrupt Identification Register (read-only).
const Iir = packed struct {
    /// Interrupt pending.
    intpend: enum(u1) { pending = 0, none = 1 },
    /// Interrupt ID.
    intid: u3,
    /// Reserved.
    _4: u2 = 0,
    /// FIFOs enabled.
    fifoen: enum(u2) { mode16450 = 0, mode16550 = 1 },
};

/// FIFO Control Register (write-only).
const Fcr = packed struct {
    /// FIFO enable.
    fifoen: bool = false,
    /// Receive FIFO reset.
    rxrst: bool = false,
    /// Reset transmit FIFO.
    txrst: bool = false,
    /// DMA mode select.
    dma: u1 = 0,
    /// Reserved.
    _4: u2 = 0,
    /// Receive FIFO trigger level.
    rxtrig: enum(u2) {
        byte1 = 0b00,
        byte4 = 0b01,
        byte8 = 0b10,
        byte14 = 0b11,
    },
};

/// Line Control Register.
const Lcr = packed struct {
    /// Word length select.
    wls: enum(u2) {
        bits5 = 0b00,
        bits6 = 0b01,
        bits7 = 0b10,
        bits8 = 0b11,
    },
    /// Number of stop bits.
    stb: bool = false,
    /// Parity enable.
    pen: bool = false,
    /// Even parity select.
    eps: enum(u1) { odd = 0, even = 1 } = .odd,
    /// Stick parity.
    stick: bool = false,
    /// Set break.
    brk: bool = false,
    /// Divisor latch access bit.
    dlab: bool = false,
};

/// Modem Control Register.
const Mcr = packed struct {
    /// Data terminal ready.
    dtr: bool = false,
    /// Request to send.
    rts: bool = false,
    /// Auxiliary output 1.
    out1: enum(u1) { low = 0, high = 1 } = .low,
    /// Auxiliary output 2.
    out2: enum(u1) { low = 0, high = 1 } = .low,
    /// Loopback mode.
    loop: bool = false,
    /// Reserved.
    _5: u3 = 0,
};

/// Line Status Register (read-only).
const Lsr = packed struct {
    /// Data ready.
    dr: bool,
    /// Overrun error.
    oe: bool,
    /// Parity error.
    pe: bool,
    /// Framing error.
    fe: bool,
    /// Break interrupt.
    bi: bool,
    /// Transmitter holding register empty.
    thre: bool,
    /// Transmitter empty.
    temt: bool,
    /// Error in receive FIFO.
    fifoerr: bool,
};

/// Modem Status Register (read-only).
const Msr = packed struct {
    /// Delta clear to send.
    dcts: bool,
    /// Delta data set ready.
    ddsr: bool,
    /// Trailing edge ring indicator.
    teri: bool,
    /// Delta data carrier detect.
    ddcd: bool,
    /// Clear to send.
    cts: bool,
    /// Data set ready.
    dsr: bool,
    /// Ring indicator.
    ri: bool,
    /// Data carrier detect.
    dcd: bool,
};

/// Scratch Register.
const Scr = packed struct {
    /// Scratch value.
    value: u8,
};

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const atomic = std.atomic;
const common = @import("common");
const pio = common.pio;
