//! Minimal compiler-rt implementation.
//!
//! BUG: Zig 0.17.0: Cannot build Zig's compiler-rt with soft_float enabled.
//!   ref. https://codeberg.org/ziglang/zig/issues/37006

export fn memcpy(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    asm volatile ("rep movsb"
        :
        : [_] "{rdi}" (dest),
          [_] "{rsi}" (src),
          [_] "{rcx}" (n),
        : .{ .rdi = true, .rsi = true, .rcx = true, .memory = true });
    return dest;
}

export fn memmove(dest: [*]u8, src: [*]const u8, n: usize) callconv(.c) [*]u8 {
    const d = @intFromPtr(dest);
    const s = @intFromPtr(src);

    if (d <= s or d >= s + n) {
        _ = memcpy(dest, src, n);
    } else {
        asm volatile (
            \\std
            \\rep movsb
            \\cld
            :
            : [_] "{rdi}" (d + n - 1),
              [_] "{rsi}" (s + n - 1),
              [_] "{rcx}" (n),
            : .{ .rdi = true, .rsi = true, .rcx = true, .memory = true });
    }
    return dest;
}

export fn memset(dest: [*]u8, c: c_int, n: usize) callconv(.c) [*]u8 {
    asm volatile ("rep stosb"
        :
        : [_] "{rdi}" (dest),
          [_] "{al}" (@as(u8, @truncate(@as(c_uint, @bitCast(c))))),
          [_] "{rcx}" (n),
        : .{ .rdi = true, .rcx = true, .memory = true });
    return dest;
}

fn udivmod(a: u128, b: u128, rem: *u128) u128 {
    const av: [2]u64 = @bitCast(a);
    var qv: [2]u64 = .{ 0, 0 };
    var r: u128 = 0;

    var i: u8 = 128;
    while (i > 0) {
        i -= 1;
        const word = i / 64;
        const shift: u6 = @intCast(i % 64);

        r = (r +% r) | ((av[word] >> shift) & 1);
        if (r >= b) {
            r -= b;
            qv[word] |= @as(u64, 1) << shift;
        }
    }

    rem.* = r;
    return @bitCast(qv);
}

export fn __udivti3(a: u128, b: u128) callconv(.c) u128 {
    var r: u128 = undefined;
    return udivmod(a, b, &r);
}

export fn __umodti3(a: u128, b: u128) callconv(.c) u128 {
    var r: u128 = undefined;
    _ = udivmod(a, b, &r);
    return r;
}

const F80Abi = extern struct { mantissa: u64, exponent: u16 };
const F128Abi = extern struct { lo: u64, hi: u64 };

export fn __extenddftf2(a: u64) callconv(.c) F128Abi {
    const sign = a >> 63;
    const exp: u64 = (a >> 52) & 0x7FF;
    var mant = a & ((1 << 52) - 1);

    var out_exp: u64 = undefined;
    if (exp == 0x7FF) {
        out_exp = 0x7FFF;
    } else if (exp != 0) {
        out_exp = exp + (16383 - 1023);
    } else if (mant == 0) {
        out_exp = 0;
    } else {
        const shift: u6 = @intCast(@clz(mant) - 11);
        mant = (mant << shift) & ((1 << 52) - 1);
        out_exp = 16383 - 1022 - @as(u64, shift);
    }

    return .{
        .hi = (sign << 63) | (out_exp << 48) | (mant >> 4),
        .lo = mant << 60,
    };
}

export fn __extendxftf2(a: F80Abi) callconv(.c) F128Abi {
    const sign = (@as(u64, a.exponent) >> 15) & 1;
    const exp = @as(u64, a.exponent) & 0x7FFF;
    const frac = a.mantissa & ((1 << 63) - 1);

    return .{
        .hi = (sign << 63) | (exp << 48) | (frac >> 15),
        .lo = frac << 49,
    };
}
