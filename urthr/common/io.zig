//! Register access utility shared by memory-mapped I/O and port-mapped I/O.
//!

pub const mmio = @import("io/mmio.zig");
pub const pio = @import("io/pio.zig");

/// Alignment requirement for registers in a module.
pub const Align = union(enum) {
    /// Automatic alignment based on the register width with check of maximum alignment size.
    natural: type,
    /// Mandatory alignment size in bytes.
    size: type,
};

/// Register descriptor kind.
const Kind = enum {
    /// Normal single register.
    reg,
    /// Array of identical registers.
    reg_array,
    /// Marker naming an offset in the module.
    marker,
    /// Array of sub-modules.
    sub,
};

/// Define a register at `off` whose value type is `T`.
pub fn Reg(comptime off: usize, comptime T: type) type {
    _ = IntRepr(T);
    return Descriptor(.reg, off, "", T, 1, 0);
}

/// Define an array of `n` identical registers starting at `off`.
pub fn Arr(comptime off: usize, comptime T: type, comptime n: usize, comptime step: usize) type {
    _ = IntRepr(T);
    return Descriptor(.reg_array, off, "", T, n, step);
}

/// Define a marker that just names the offset `off` within a module.
pub fn Mrk(comptime off: usize, comptime nm: @EnumLiteral()) type {
    return Descriptor(.marker, off, @tagName(nm), void, 1, 0);
}

/// Define an array of `n` identical sub-modules of type `M` starting at `off`.
pub fn Sub(comptime off: usize, comptime M: type, comptime n: usize, comptime step: usize) type {
    return Descriptor(.sub, off, "", M, n, step);
}

/// Defines a module of registers accessed through `Bus`.
pub fn ModuleOn(comptime Bus: type, Width: Align, comptime entries: anytype) type {
    // Validate module entries.
    comptime {
        @setEvalBranchQuota(entries.len * entries.len * 10 + 1000);

        for (entries, 0..) |E, i| {
            // Check if the entry is seemingly a valid register definition.
            if (@TypeOf(E) != type or @typeInfo(E) != .@"struct" or !@hasDecl(E, "kind")) {
                @compileError("Module entry must be valid register definition.");
            }
            // Validate duplicate types and names.
            for (entries, 0..) |F, j| {
                if (i < j and E.name.len == 0 and F.name.len == 0 and E.Type == F.Type) {
                    @compileError("Duplicate type without explicit name: " ++ @typeName(E.Type));
                }
                if (i < j and E.name.len != 0 and std.mem.eql(u8, E.name, F.name)) {
                    @compileError("Duplicate name: " ++ E.name);
                }
            }
            // Validate register alignment.
            switch (E.kind) {
                .reg, .reg_array => {
                    const bytes = @bitSizeOf(IntBus(Width, E.Type)) / @bitSizeOf(u8);
                    if (E.offset % bytes != 0 or (E.len > 1 and E.stride % bytes != 0)) {
                        @compileError("Entry '" ++ entryName(E) ++ "' is not aligned.");
                    }
                },
                else => {},
            }
        }
    }

    return struct {
        const Self = @This();

        /// Base address of this module.
        base: usize = 0,
        /// Timer implementation for wait operations.
        _timer: ?Timer = null,

        /// Create a new module instance.
        pub fn new(base: usize) Self {
            return .{ .base = base };
        }

        /// Set the base address of this module.
        pub fn setBase(self: *Self, base: usize) void {
            self.base = base;
        }

        /// Set the timer implementation for wait operations.
        ///
        /// You MUST call this function before using wait operations.
        pub fn provideTimer(self: *Self, timer: Timer) void {
            self._timer = timer;
        }

        /// Get the offset of the field.
        pub fn offsetOf(_: Self, comptime key: anytype) usize {
            return entry(key).offset;
        }

        /// Get the address of the field.
        pub fn addressOf(self: Self, comptime key: anytype) usize {
            return self.addr(key, 0);
        }

        /// Read the register.
        pub fn read(self: Self, comptime key: anytype) RegType(key, .reg) {
            const T = RegType(key, .reg);
            return fromInt(T, rawRead(T, self.addr(key, 0)));
        }

        /// Read the register as an integer.
        pub fn readi(self: Self, comptime key: anytype) IntRepr(RegType(key, .reg)) {
            const T = RegType(key, .reg);
            return rawRead(T, self.addr(key, 0));
        }

        /// Read the indexed register.
        pub fn readIndexed(self: Self, comptime key: anytype, index: usize) RegType(key, .reg_array) {
            const T = RegType(key, .reg_array);
            return fromInt(T, rawRead(T, self.addr(key, index)));
        }

        /// Write the value to the register.
        pub fn write(self: Self, comptime key: anytype, value: RegType(key, .reg)) void {
            const T = RegType(key, .reg);
            rawWrite(T, self.addr(key, 0), toInt(T, value));
        }

        /// Write the integer to the register.
        pub fn writei(self: Self, comptime key: anytype, value: IntRepr(RegType(key, .reg))) void {
            const T = RegType(key, .reg);
            rawWrite(T, self.addr(key, 0), value);
        }

        /// Write the value to the register.
        ///
        /// The value must be a partial struct of the register type.
        /// The unspecified fields are initialized with zero values.
        pub fn writez(self: Self, comptime key: anytype, value: anytype) void {
            const T = RegType(key, .reg);
            rawWrite(T, self.addr(key, 0), toInt(T, std.mem.zeroInit(T, value)));
        }

        /// Write the value to the indexed register.
        pub fn writeIndexed(self: Self, comptime key: anytype, index: usize, value: RegType(key, .reg_array)) void {
            const T = RegType(key, .reg_array);
            rawWrite(T, self.addr(key, index), toInt(T, value));
        }

        /// Write the integer to the indexed register.
        pub fn writeiIndexed(self: Self, comptime key: anytype, index: usize, value: IntRepr(RegType(key, .reg_array))) void {
            const T = RegType(key, .reg_array);
            rawWrite(T, self.addr(key, index), value);
        }

        /// Write the value to the indexed register.
        ///
        /// The value must be a partial struct of the register type.
        /// The unspecified fields are initialized with zero values.
        pub fn writezIndexed(self: Self, comptime key: anytype, index: usize, value: anytype) void {
            const T = RegType(key, .reg_array);
            rawWrite(T, self.addr(key, index), toInt(T, std.mem.zeroInit(T, value)));
        }

        /// Read modify write the register with the value.
        pub fn modify(self: Self, comptime key: anytype, value: anytype) void {
            const T = RegType(key, .reg);
            const address = self.addr(key, 0);
            const now = rawRead(T, address);
            rawWrite(T, address, modified(T, now, value));
        }

        /// Read modify write the indexed register with the value.
        pub fn modifyIndexed(self: Self, comptime key: anytype, index: usize, value: anytype) void {
            const T = RegType(key, .reg_array);
            const address = self.addr(key, index);
            const now = rawRead(T, address);
            rawWrite(T, address, modified(T, now, value));
        }

        /// Returns the value with the specified fields replaced by `value`.
        fn modified(comptime T: type, raw: IntRepr(T), value: anytype) IntRepr(T) {
            if (@typeInfo(T) != .@"struct") {
                @compileError("Invalid type for modify: " ++ @typeName(T));
            }
            var now = fromInt(T, raw);
            inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |f| {
                @field(now, f) = @field(value, f);
            }
            return toInt(T, now);
        }

        /// Get the sub-module at the given index of the array.
        ///
        /// The sub-module inherits the timer of this module.
        pub fn sub(self: Self, comptime key: anytype, index: usize) RegType(key, .sub) {
            var m = RegType(key, .sub).new(self.addr(key, index));
            m._timer = self._timer;
            return m;
        }

        /// Wait for the register to match the given value.
        ///
        /// When `value` is a struct, only the specified fields are compared.
        /// Otherwise, the whole value is compared.
        ///
        /// If the duration is not specified, this function waits indefinitely.
        /// When the duration expires while the condition is not met, this function returns `false`.
        /// Otherwise, it returns `true`.
        ///
        /// Caller MUST ensure that a timer implementation is provided via `provideTimer()` beforehand.
        pub fn tryWaitFor(self: *Self, comptime key: anytype, value: anytype, duration: ?TimeSlice) bool {
            const use_timer = duration != null;
            if (duration) |d| {
                if (self._timer) |*timer|
                    timer.start(d)
                else
                    @panic("tryWaitFor: timer is not provided");
            }

            while (true) {
                if (self.matches(key, value)) {
                    return true;
                }
                if (use_timer and self._timer.?.expired()) {
                    return false;
                }
                std.atomic.spinLoopHint();
            }
        }

        /// Wait for the register to match the given value.
        ///
        /// When `value` is a struct, only the specified fields are compared.
        /// Otherwise, the whole value is compared.
        ///
        /// If the duration is not specified, this function waits indefinitely.
        /// When the duration expires while the condition is not met, this function panics.
        ///
        /// Caller MUST ensure that a timer implementation is provided via `provideTimer()` beforehand.
        pub fn waitFor(self: *Self, comptime key: anytype, value: anytype, duration: ?TimeSlice) void {
            if (!self.tryWaitFor(key, value, duration)) {
                @panic("waitFor: timeout expired");
            }
        }

        /// Check if the register matches the given value.
        fn matches(self: Self, comptime key: anytype, value: anytype) bool {
            const T = RegType(key, .reg);
            const v = self.read(key);

            if (@typeInfo(@TypeOf(value)) == .@"struct") {
                inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
                    if (@field(v, name) != @field(value, name)) {
                        return false;
                    }
                } else return true;
            } else {
                return toInt(T, v) == encode(T, value);
            }
        }

        /// Get the definition of the entry.
        fn entry(comptime key: anytype) type {
            @setEvalBranchQuota(entries.len * 100 + 1000);
            inline for (entries) |E| {
                const hit = if (@TypeOf(key) == type)
                    E.name.len == 0 and E.Type == key
                else
                    std.mem.eql(u8, E.name, @tagName(key));

                if (hit) return E;
            }
            @compileError("Entry definition not found: " ++ keyName(key));
        }

        /// Get the value type of the register entry of the given kind.
        fn RegType(comptime key: anytype, comptime kind: Kind) type {
            const E = entry(key);
            if (E.kind != kind) @compileError(keyName(key) ++ " is not " ++ @tagName(kind));
            return E.Type;
        }

        /// Get the address of the entry at the given index.
        fn addr(self: Self, comptime key: anytype, index: usize) usize {
            const E = entry(key);
            rtt.expect(index < E.len);
            return self.base + E.offset + index * E.stride;
        }

        /// Read integer value at the given address through the bus.
        fn rawRead(comptime T: type, address: usize) IntRepr(T) {
            return @truncate(Bus.read(IntBus(Width, T), address));
        }

        /// Write integer value at the given address through the bus.
        fn rawWrite(comptime T: type, address: usize, value: IntRepr(T)) void {
            Bus.write(IntBus(Width, T), address, value);
        }
    };
}

/// Create a register descriptor.
fn Descriptor(
    comptime k: Kind,
    comptime off: usize,
    comptime nm: []const u8,
    comptime T: type,
    comptime n: usize,
    comptime step: usize,
) type {
    return struct {
        /// Type of the register entry.
        pub const Type = T;
        /// Kind of the register entry.
        pub const kind = k;
        /// Offset of the entry within the module.
        pub const offset = off;
        /// Name of the entry.
        ///
        /// Empty if the entry can be looked up only by its type.
        pub const name = nm;
        /// Length of the register array or sub-module array.
        pub const len = n;
        /// Stride.
        pub const stride = step;

        /// Name the entry so that it can be looked up by its name.
        pub fn as(comptime new: @EnumLiteral()) type {
            if (name.len != 0) {
                @compileError("io: entry is already named: " ++ name);
            }
            return Descriptor(kind, offset, @tagName(new), Type, len, stride);
        }
    };
}

/// Integer type that has the same bit width as `T`.
fn IntRepr(comptime T: type) type {
    switch (@typeInfo(T)) {
        .int, .bool, .@"enum" => {},
        .@"struct" => |s| if (s.layout != .@"packed") {
            @compileError("io: register type must be a packed struct: " ++ @typeName(T));
        },
        else => {
            @compileError("io: unsupported register type: " ++ @typeName(T));
        },
    }
    return @Int(.unsigned, @bitSizeOf(T));
}

/// Integer type used to access a register of type `T`.
fn IntBus(comptime Width: Align, comptime T: type) type {
    const bits = @bitSizeOf(T);
    return switch (Width) {
        .natural => |Max| mod: {
            if (bits > @bitSizeOf(Max)) {
                @compileError(fmt.comptimePrint(
                    "{s} is larger than the maximum access width: {d} vs {d} bits",
                    .{ @typeName(T), bits, @bitSizeOf(Max) },
                ));
            }
            const w = @max(8, std.math.ceilPowerOfTwo(usize, bits) catch unreachable);
            break :mod @Int(.unsigned, @min(@bitSizeOf(Max), w));
        },

        .size => |Size| mod: {
            if (!std.math.isPowerOfTwo(@bitSizeOf(Size)) or bits > @bitSizeOf(Size)) {
                @compileError(fmt.comptimePrint(
                    "invalid access width: {s} ({d} bits), {s} ({d} bits)",
                    .{ @typeName(T), bits, @typeName(Size), @bitSizeOf(Size) },
                ));
            }
            break :mod Size;
        },
    };
}

/// Convert the value to its integer representation.
fn toInt(comptime T: type, v: T) IntRepr(T) {
    return switch (@typeInfo(T)) {
        .bool => @intFromBool(v),
        .@"enum" => @bitCast(@backingInt(v)),
        else => @bitCast(v),
    };
}

/// Convert the integer representation to `T`.
fn fromInt(comptime T: type, r: IntRepr(T)) T {
    return switch (@typeInfo(T)) {
        .bool => r != 0,
        .@"enum" => |e| @fromBackingInt(@as(e.tag_type, @bitCast(r))),
        else => @bitCast(r),
    };
}

/// Convert a value to the integer representation of `T`.
fn encode(comptime T: type, value: anytype) IntRepr(T) {
    const is_int = switch (@typeInfo(@TypeOf(value))) {
        .comptime_int, .int => true,
        else => false,
    };
    if (is_int and @typeInfo(T) != .int) {
        return @as(IntRepr(T), value);
    } else {
        return toInt(T, @as(T, value));
    }
}

/// String representation of the key.
fn keyName(comptime key: anytype) []const u8 {
    return if (@TypeOf(key) == type) @typeName(key) else @tagName(key);
}

/// String representation of the entry.
fn entryName(comptime E: type) []const u8 {
    return if (E.name.len != 0) E.name else @typeName(E.Type);
}

// =============================================================
// Tests
// =============================================================

const testing = std.testing;

const MemBus = struct {
    fn read(comptime W: type, address: usize) W {
        const ptr: *const volatile W = @ptrFromInt(address);
        return ptr.*;
    }

    fn write(comptime W: type, address: usize, value: W) void {
        const ptr: *volatile W = @ptrFromInt(address);
        ptr.* = value;
    }
};

fn MemModule(comptime Width: Align, comptime entries: anytype) type {
    return ModuleOn(MemBus, Width, entries);
}

test "integer, enum, bool and packed struct" {
    const Packed = packed struct {
        a: u8,
        b: bool,
        c: u7,
    };
    const Enum = enum(u32) {
        off = 0,
        on = 1,
        super = 0xFFFF_FFFE,
        _,
    };
    const Regs = .{
        Reg(0x00, u32).as(.plain),
        Reg(0x04, Enum).as(.mode),
        Reg(0x08, Packed).as(.flags),
        Reg(0x0C, u6).as(.small),
        Reg(0x10, bool).as(.on),
    };

    var raw: [8]u32 align(8) = @splat(0xFFFF_FFFF);
    var mod = MemModule(
        .{ .size = u32 },
        Regs,
    ).new(@intFromPtr(&raw));

    // Integer.
    mod.write(.plain, 0x1234_5678);
    try testing.expectEqual(0x1234_5678, raw[0]);
    try testing.expectEqual(0x1234_5678, mod.read(.plain));
    try testing.expectEqual(0x1234_5678, mod.readi(.plain));

    // Enum.
    mod.write(.mode, .super);
    try testing.expectEqual(0xFFFF_FFFE, raw[1]);
    try testing.expectEqual(.super, mod.read(.mode));
    mod.writei(.mode, 1);
    try testing.expectEqual(.on, mod.read(.mode));
    mod.write(.mode, .off);
    try testing.expectEqual(0, raw[1]);

    // Packed struct.
    mod.write(.flags, .{ .a = 0xAB, .b = true, .c = 0x11 });
    try testing.expectEqual(Packed{
        .a = 0xAB,
        .b = true,
        .c = 0x11,
    }, mod.read(.flags));
    mod.modify(.flags, .{ .b = false });
    try testing.expectEqual(Packed{
        .a = 0xAB,
        .b = false,
        .c = 0x11,
    }, mod.read(.flags));
    mod.writez(.flags, .{ .a = 1 });
    try testing.expectEqual(Packed{
        .a = 1,
        .b = false,
        .c = 0,
    }, mod.read(.flags));
    mod.writei(.flags, 0xFFFF);
    try testing.expectEqual(0xFFFF, raw[2]);

    // Narrow integer is widened to the access width.
    mod.write(.small, 0x2A);
    try testing.expectEqual(0x2A, raw[3]);
    try testing.expectEqual(0x2A, mod.read(.small));

    // Bool.
    mod.write(.on, true);
    try testing.expectEqual(1, raw[4]);
    try testing.expect(mod.read(.on));
}

test "lookup by type" {
    const Packed = packed struct {
        en: bool,
        mode: u3,
        _pad: u12 = 0,
    };
    const Enum = enum(u32) {
        a,
        b,
        _,
    };
    const Regs = .{
        Reg(0x00, Packed),
        Reg(0x04, Enum),
        Reg(0x08, u16).as(.div),
    };

    var raw: [3]u32 align(8) = @splat(0);
    const mod = MemModule(.{ .size = u32 }, Regs).new(@intFromPtr(&raw));

    mod.write(Packed, .{ .en = true, .mode = 5 });
    try testing.expectEqual(0b1011, raw[0]);
    mod.modify(Packed, .{ .en = false });
    try testing.expectEqual(Packed{
        .en = false,
        .mode = 5,
    }, mod.read(Packed));

    mod.write(Enum, .b);
    try testing.expectEqual(1, raw[1]);
    try testing.expectEqual(.b, mod.read(Enum));

    mod.write(.div, 0x1234);
    try testing.expectEqual(0x1234, raw[2]);
    try testing.expectEqual(0x1234, mod.read(.div));
    try testing.expectEqual(0x08, mod.offsetOf(.div));
}

test "same type for multiple registers" {
    const Regs = .{
        Reg(0x00, u32).as(.a),
        Reg(0x04, u32).as(.b),
    };

    var raw: [2]u32 align(8) = .{ 0, 0 };
    const mod = MemModule(.{ .size = u32 }, Regs).new(@intFromPtr(&raw));

    mod.write(.a, 1);
    mod.write(.b, 2);
    try testing.expectEqual(1, raw[0]);
    try testing.expectEqual(2, raw[1]);
}

test "natural access width" {
    const Regs = .{
        Reg(0x00, u8).as(.byte),
        Reg(0x02, u16).as(.half),
        Reg(0x04, u32).as(.word),
    };

    var raw: [8]u8 align(8) = @splat(0);
    const mod = MemModule(.{ .natural = u32 }, Regs).new(@intFromPtr(&raw));

    mod.write(.byte, 0xAA);
    mod.write(.half, 0xBBCC);
    mod.write(.word, 0x1122_3344);
    try testing.expectEqualSlices(u8, &.{
        0xAA, 0x00, 0xCC, 0xBB,
        0x44, 0x33, 0x22, 0x11,
    }, &raw);
}

test "indexed register" {
    const Entry = packed struct {
        lo: u16,
        hi: u16,
    };
    const Regs = .{
        Arr(0x08, Entry, 3, 0x10),
    };

    var raw: [16]u32 align(8) = @splat(0);
    const mod = MemModule(.{ .size = u32 }, Regs).new(@intFromPtr(&raw));

    mod.writeIndexed(Entry, 2, .{ .lo = 0x1111, .hi = 0x2222 });
    try testing.expectEqual(0x2222_1111, raw[(0x08 + 2 * 0x10) / 4]);

    mod.modifyIndexed(Entry, 2, .{ .hi = 0x3333 });
    try testing.expectEqual(Entry{
        .lo = 0x1111,
        .hi = 0x3333,
    }, mod.readIndexed(Entry, 2));
    try testing.expectEqual(Entry{
        .lo = 0,
        .hi = 0,
    }, mod.readIndexed(Entry, 1));
}

test "sub-module array and marker" {
    const Sub1 = MemModule(.{ .size = u32 }, .{
        Reg(0x00, u32).as(.a),
        Reg(0x04, u32).as(.b),
    });
    const Regs = .{
        Reg(0x00, u32).as(.head),
        Sub(0x08, Sub1, 3, 0x10),
        Mrk(0x40, .tail),
    };

    var raw: [32]u32 align(8) = @splat(0);
    const mod = MemModule(.{ .size = u32 }, Regs).new(@intFromPtr(&raw));

    mod.sub(Sub1, 1).write(.a, 0x1111);
    mod.sub(Sub1, 2).write(.b, 0x2222);
    try testing.expectEqual(0x1111, raw[0x18 / 4]);
    try testing.expectEqual(0x2222, raw[0x2C / 4]);
    try testing.expectEqual(0x2222, mod.sub(Sub1, 2).read(.b));

    try testing.expectEqual(0x40, mod.offsetOf(.tail));
    try testing.expectEqual(@intFromPtr(&raw) + 0x40, mod.addressOf(.tail));
}

// =============================================================
// Imports
// =============================================================

const std = @import("std");
const fmt = std.fmt;
const rtt = @import("rtt.zig");
const Timer = @import("Timer.zig");
const TimeSlice = Timer.TimeSlice;
