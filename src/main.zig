export fn kinit() callconv(.c) void {
    board.boot();

    for ("Hello, Urthr!\n") |c| {
        dd.pl011.putc(c);
    }

    while (true) {
        asm volatile ("wfe");
    }
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const board = @import("board").impl;
const dd = @import("dd");
