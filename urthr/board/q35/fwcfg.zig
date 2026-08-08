//! Driver for QEMU fw_cfg device.

var dev = pio.Module(&.{
    .{ 0x00, Selector },
    .{ 0x01, Data },
}){};

/// Get the fw_cfg interface.
pub fn interface() dd.FwCfg {
    dev.setBase(0x510);
    return .{ .vtable = vtable };
}

const vtable = dd.FwCfg.Vtable{
    .select = select,
    .readByte = read,
};

fn select(selector: u16) void {
    dev.write(Selector, .{ .value = selector });
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
const pio = common.pio;
const dd = @import("dd");
