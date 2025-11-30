/// Initialize exception handling for this CPU.
pub fn initLocal() void {
    arch.exception.setConsole(board.getConsole());
    arch.exception.initLocal();
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const board = @import("board").impl;
const arch = @import("arch").impl;
