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
    .lock = .{},
    .waitq = .{},
};

/// Push a character.
pub fn push(c: u8) void {
    const ie = state.lock.lockDisableIrq();
    defer state.lock.unlockRestoreIrq(ie);

    switch (c) {
        // Newline
        '\r', '\n' => {
            flushLine('\n');
            _ = state.waitq.wake();
        },
        // BS or DEL
        0x08, 0x7F => {
            if (state.line_len > 0) {
                state.line_len -= 1;
            }
        },
        // ETX
        0x03 => {
            state.line_len = 0;
        },
        // EDT
        0x04 => {
            flushLine(0);
            _ = state.waitq.wake();
        },
        // Normal character
        else => {
            if (c >= 0x20 and state.line_len < size_line_buf - 1) {
                state.line[state.line_len] = c;
                state.line_len += 1;
            }
        },
    }
}

/// Read up to `buf.len` bytes, blocking until at least one byte is available.
///
/// Returns the number of bytes read.
pub fn read(buf: []u8) usize {
    const ie = state.lock.lockDisableIrq();
    defer state.lock.unlockRestoreIrq(ie);

    while (ringLen() == 0) {
        state.waitq.wait(&state.lock);
    }

    var n: usize = 0;
    while (n < buf.len and ringLen() > 0) {
        buf[n] = state.ring[state.r_head % size_ring];
        state.r_head += 1;
        n += 1;
    }

    return n;
}

/// Flush the line buffer into the ring buffer, appending `terminator`.
///
/// Caller must hold `state.lock`.
fn flushLine(terminator: u8) void {
    for (state.line[0..state.line_len]) |c| {
        ringPush(c);
    }
    ringPush(terminator);
    state.line_len = 0;
}

/// Get a length of the data in the ring buffer.
fn ringLen() usize {
    return state.r_tail - state.r_head;
}

/// Push a character into the ring buffer if there is space.
fn ringPush(c: u8) void {
    if (ringLen() < size_ring) {
        state.ring[state.r_tail % size_ring] = c;
        state.r_tail += 1;
    }
}

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const rtt = common.rtt;
const urd = @import("urthr");
const SpinLock = urd.SpinLock;
const WaitQueue = urd.WaitQueue;
