/// Execute a single NOP instruction.
pub fn nop() void {
    asm volatile ("nop");
}
