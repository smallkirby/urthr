//! Kernel input subsystem.
//!
//! Collects inputs and exposes them to user processes via line discipline.

/// Size of the line buffer (current incomplete line).
const size_line_buf = 256;
/// Size of the ring buffer (completed lines ready to be read).
const size_ring = 4096;

/// Input state.
var state: struct {
    /// Current line (incomplete input until newline).
    line: [size_line_buf]u8,
    /// Length in bytes of the current line.
    line_len: usize,

    /// Completed lines ready to be consumed by readers.
    ring: [size_ring]u8,
    /// Read position.
    r_head: usize,
    /// Write position.
    r_tail: usize,

    /// Terminal settings.
    termios: Termios,

    /// Spinlock to protect the state.
    lock: SpinLock,
    /// Wait queue for readers waiting for input.
    waitq: WaitQueue,
} = .{
    .line = undefined,
    .line_len = 0,
    .ring = undefined,
    .r_head = 0,
    .r_tail = 0,
    .termios = .default(),
    .lock = .{},
    .waitq = .{},
};

/// Get the current termios settings.
pub fn getTermios() Termios {
    const ie = state.lock.lockDisableIrq();
    defer state.lock.unlockRestoreIrq(ie);
    return state.termios;
}

/// Update the termios settings.
pub fn setTermios(t: Termios) void {
    const ie = state.lock.lockDisableIrq();
    defer state.lock.unlockRestoreIrq(ie);
    state.termios = t;
}

/// Push a character.
pub fn push(c: u8) void {
    const ie = state.lock.lockDisableIrq();
    defer state.lock.unlockRestoreIrq(ie);

    // Translate CR to NL if ICRNL is set.
    const ch: u8 = if (c == '\r' and state.termios.iflag.icrnl) '\n' else c;

    if (state.termios.lflag.icanon) {
        // If canonical mode, push to the line buffer.
        pushCanonical(ch);
    } else {
        // If raw mode, push directly to the ring buffer.
        ringPush(ch);
        _ = state.waitq.wake();
    }
}

/// Read up to `buf.len` bytes, blocking until data is available.
///
/// Returns the number of bytes read.
pub fn read(buf: []u8) usize {
    const ie = state.lock.lockDisableIrq();
    defer state.lock.unlockRestoreIrq(ie);

    const min: usize = if (state.termios.lflag.icanon) 1 else @max(1, state.termios.cc[cc.vmin]);

    while (ringLen() < min) {
        state.waitq.wait(&state.lock);
    }

    var n: usize = 0;
    while (n < buf.len and ringLen() > 0) {
        buf[n] = state.ring[state.r_head % size_ring];
        state.r_head += 1;
        n += 1;
        // In raw mode, respect VMIN: stop once we've read enough.
        if (!state.termios.lflag.icanon and n >= state.termios.cc[cc.vmin]) break;
    }

    return n;
}

/// Line discipline in canonical mode.
fn pushCanonical(c: u8) void {
    rtt.expect(state.lock.isLocked());

    const echo = state.termios.lflag.echo;
    const echoe = state.termios.lflag.echoe;

    switch (c) {
        // Newline.
        '\n' => {
            flushLine('\n');
            if (echo) console.writeUnsafe("\r\n");
            _ = state.waitq.wake();
        },
        // Backspace or DEL.
        0x08, 0x7F => {
            if (state.line_len > 0) {
                state.line_len -= 1;
                if (echoe) console.writeUnsafe("\x08 \x08");
            }
        },
        // Ctrl+C
        0x03 => {
            state.line_len = 0;
            if (echo) console.writeUnsafe("^C\r\n");
        },
        // Ctrl+D
        0x04 => {
            flushLine(0);
            _ = state.waitq.wake();
        },
        // Normal character.
        else => {
            if (c >= 0x20 and state.line_len < size_line_buf - 1) {
                state.line[state.line_len] = c;
                state.line_len += 1;
                if (echo) console.writeUnsafe(state.line[state.line_len - 1 .. state.line_len]);
            }
        },
    }
}

/// Flush the line buffer into the ring buffer, appending `terminator`.
fn flushLine(terminator: u8) void {
    rtt.expect(state.lock.isLocked());

    for (state.line[0..state.line_len]) |c| {
        ringPush(c);
    }
    ringPush(terminator);
    state.line_len = 0;
}

/// Get the number of bytes currently in the ring buffer.
fn ringLen() usize {
    return state.r_tail - state.r_head;
}

/// Push a character into the ring buffer, if there is space.
fn ringPush(c: u8) void {
    if (ringLen() < size_ring) {
        state.ring[state.r_tail % size_ring] = c;
        state.r_tail += 1;
    }
}

// =============================================================
// termios
// =============================================================

/// POSIX-compliant terminal I/O settings.
pub const Termios = if (builtin.cpu.arch.isAARCH64()) extern struct {
    /// Input modes.
    iflag: Iflag,
    /// Output modes.
    oflag: Oflag,
    /// Control modes.
    cflag: Cflag,
    /// Local modes.
    lflag: Lflag,
    /// Line dediscipline special characters.
    line: u8,
    /// Control characters.
    cc: [32]u8,

    fn default() Termios {
        var t = std.mem.zeroes(Termios);
        t.iflag.icrnl = true;
        t.oflag.opost = true;
        t.oflag.onlcr = true;
        t.cflag.cread = true;
        t.cflag.csize = 0b11; // CS8
        t.lflag.isig = true;
        t.lflag.icanon = true;
        t.lflag.echo = true;
        t.lflag.echoe = true;
        t.cc[cc.vintr] = 3; // Ctrl+C
        t.cc[cc.verase] = 127; // DEL
        t.cc[cc.veof] = 4; // Ctrl+D
        t.cc[cc.vmin] = 1;
        t.cc[cc.vtime] = 0;
        return t;
    }
} else extern struct {};

/// Input modes.
const Iflag = if (builtin.cpu.arch.isAARCH64()) packed struct(u32) {
    /// Ignore BREAK condition on input.
    ignbrk: bool = false,
    /// Ignore a BREAK.
    brkint: bool = false,
    /// Ignore framing errors and parity errors.
    ignpar: bool = false,
    /// Mark parity and framing errors.
    parmrk: bool = false,
    /// Enable input parity checking.
    inpck: bool = false,
    /// Strip off eighth bit.
    istrip: bool = false,
    /// Translate NL to CR on input.
    inlcr: bool = false,
    /// Ignore CR on input.
    igncr: bool = false,
    /// Translate CR to NL on input.
    icrnl: bool = false,
    /// Enable XON/XOFF flow control on output.
    ixon: bool = false,
    /// Enable XON/XOFF flow control on input.
    ixoff: bool = false,
    /// Typing any character will restart stopped output.
    ixany: bool = false,
    /// Ring bell when input queue is full.
    imaxbel: bool = false,
    /// Input is UTF-8.
    iutf8: bool = false,
    /// Reserved.
    _15: u18 = 0,
} else struct {};

/// Output modes.
const Oflag = if (builtin.cpu.arch.isAARCH64()) packed struct(u32) {
    /// Enable implementation-defined output processing.
    opost: bool = false,
    /// Map lowercase characters to uppercase.
    olcuc: bool = false,
    /// Map NL to CR-NL on output.
    onlcr: bool = false,
    /// Map CR to NL on output.
    ocrnl: bool = false,
    /// Don't output CR at column 0.
    onocr: bool = false,
    /// NL is assumed to do the CR function.
    onlret: bool = false,
    /// Send fill characters for a delay, rather than using a timer.
    ofill: bool = false,
    /// Fill character is DEL.
    ofdel: bool = false,
    /// Newline delay mask.
    nldly: u1 = 0,
    /// CR delay mask.
    crdly: u2 = 0,
    /// Horizontal tab delay mask.
    tabdly: u2 = 0,
    /// Backspace delay mask.
    bsdly: u1 = 0,
    /// Vertical tab delay mask.
    vtdly: u1 = 0,
    /// Form feed delay mask.
    ffdly: u1 = 0,
    /// Reserved.
    _16: u16 = 0,
} else struct {};

/// Control modes.
const Cflag = if (builtin.cpu.arch.isAARCH64()) packed struct(u32) {
    /// Reserved.
    _0: u4 = 0,
    /// Character size mask.
    csize: u2 = 0,
    /// Set 2 stop bits, rather than 1.
    cstopb: bool = false,
    /// Enable receiver.
    cread: bool = false,
    /// Enable parity generation on output and parity checking for input.
    parenb: bool = false,
    /// Parity for input and output is odd.
    parodd: bool = false,
    /// Lower modem control lines after last process closes the device.
    hupcl: bool = false,
    /// Ignore modem control lines.
    clocal: bool = false,
    /// Reserved.
    _12: u17 = 0,
    ///
    addrb: bool = false,
    /// Use stick parity.
    cmspar: bool = false,
    /// Enable RTS/CTS HW flow control.
    crtscts: bool = false,
} else struct {};

/// Local modes.
const Lflag = if (builtin.cpu.arch.isAARCH64()) packed struct(u32) {
    /// When any of INTR, QUIT, SUSP, or DSUSP are received, generate a signal.
    isig: bool = false,
    /// Enable canonical mode.
    icanon: bool = false,
    /// When ICANON is set, terminal is uppercase only.
    xcase: bool = false,
    /// Echo input characters.
    echo: bool = false,
    /// If ICANON is set, ERASE erases the preceding input character, WERASE erases the preceding word, and KILL erases the entire line.
    echoe: bool = false,
    /// If ICANON is set, KILL erases the current line.
    echok: bool = false,
    /// If ICANON is set, echo NL even if ECHO is not set.
    echonl: bool = false,
    /// Disable flushing the input and output queues when generating signals.
    noflsh: bool = false,
    /// Send SIGTTOU to the process group of a background process which tries to write to its controlling terminal.
    tostop: bool = false,
    /// If ECHO is set, terminal special characters other than TAB, NL, START, and STOP are echoed as ^X.
    echoctl: bool = false,
    /// If ICANON and ECHO are set, characters are printed as they are being erased.
    echoprt: bool = false,
    /// If ICANON is set, KILL is echoed by erasing each character on the line.
    echoke: bool = false,
    /// Output is being flushed.
    flusho: bool = false,
    /// Reserved.
    _13: u1 = 0,
    /// All characters in the input queue are reprinted when the next character is read.
    pendin: bool = false,
    /// Enable implementation-defined input processing.
    iexten: bool = false,
    ///
    extproc: bool = false,
    /// Reserved.
    _17: u15 = 0,
} else struct {};

// Control character indices.
const cc = struct {
    /// Interrupt character.
    const vintr = 0;
    /// ERASE character.
    const verase = 2;
    /// EOF character.
    const veof = 4;
    /// Timeout in deciseconds for noncanonical read.
    const vtime = 5;
    /// Minimum number of bytes for noncanonical read.
    const vmin = 6;
};

// =============================================================
// Imports
// =============================================================

const builtin = @import("builtin");
const std = @import("std");
const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const console = urd.console;
const SpinLock = urd.SpinLock;
const WaitQueue = urd.WaitQueue;
