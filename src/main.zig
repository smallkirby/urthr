export fn kinit() callconv(.c) void {
    const dd = urd.dd;

    dd.gpio.setBase(0xFE200000);
    dd.pl011.setBase(0xFE201000);

    dd.pl011.init();

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
const urd = @import("urthr");
