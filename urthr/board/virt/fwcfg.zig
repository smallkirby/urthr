//! Driver for QEMU fw_cfg device.

var dev = mmio.Module(.{ .natural = u16 }, &.{
    .{ 0x00, Data },
    .{ 0x08, Selector },
}){};

/// fw_cfg instance.
var instance: dd.FwCfg = undefined;

/// Set the base address of fw_cfg device.
pub fn setBase(base: usize) void {
    dev.setBase(base);
    instance = .{ .vtable = vtable };
}

/// Get the fw_cfg interface.
pub fn interface() *dd.FwCfg {
    return &instance;
}

const vtable = dd.FwCfg.Vtable{
    .select = select,
    .readByte = read,
};

fn select(selector: u16) void {
    dev.write(Selector, .{ .value = @byteSwap(selector) });
}

fn read() u8 {
    return dev.read(Data).value;
}

/// Data register.
const Data = packed struct(u8) { value: u8 };
const Selector = packed struct(u16) { value: u16 };

// =============================================================
// Imports
// =============================================================

const common = @import("common");
const mmio = common.mmio;
const dd = @import("dd");
