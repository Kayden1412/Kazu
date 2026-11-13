// rapidhash V3, Copyright (C) 2025 Nicolas De Carli, MIT (notice below).
// Ported from Nicoshev/rapidhash rapidhash.h, tag rapidhash_v3 (bc4b4ba).
// The algorithm and constants are transcribed verbatim; the structure is
// adapted to Zig (readInt reads, u128 mum, case-folded short keys).
//
// MIT License
//
// Copyright (c) 2025 Nicolas De Carli
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

//! Rapidhash V3, reduced to the case-folded hash the language table needs.
//! `hashFold` folds ASCII case into every loaded word (`| 0x20`), so keys
//! that compare equal under `std.ascii.eqlIgnoreCase` hash identically. The
//! open-addressed map still finishes each probe with `eqlIgnoreCase`, so the
//! fold only picks the bucket and never decides equality.
//!
//! Every read is unaligned little-endian, so the output is independent of
//! the host. Keys here are short (at most 23 bytes), so the `len <= 16` path
//! and the `len > 16` tail reads are enough; the multi-lane bulk loop was
//! dropped along with the unused variants.

const std = @import("std");
const testing = std.testing;
const mem = std.mem;

/// The V3 secret schedule, upstream's values verbatim. `secret[7]` feeds
/// only the final avalanche.
const secret = [8]u64{
    0x2d358dccaa6c78a5,
    0x8bb84b93962eacc9,
    0x4b33a62ed433d4a3,
    0x4d5a2da51de1aa47,
    0xa0761d6478bd642f,
    0xe7037ed1a0b428db,
    0x90ed1765281c388c,
    0xaaaaaaaaaaaaaaaa,
};

/// The halves of a 64x64 widening multiply.
const Mums = struct {
    low: u64,
    high: u64,
};

/// 64x64 -> 128 multiply, split into halves. A u64 x u64 product always
/// fits u128, so no wrapping operators are needed.
inline fn mum(a: u64, b: u64) Mums {
    const r = @as(u128, a) * @as(u128, b);
    return .{ .low = @truncate(r), .high = @truncate(r >> 64) };
}

/// Upstream's `rapid_mix`: multiply, then fold the halves together.
inline fn mix(a: u64, b: u64) u64 {
    const m = mum(a, b);
    return m.low ^ m.high;
}

/// Unaligned little-endian read. `readInt` handles the alignment; the
/// explicit endianness keeps the output host-independent.
inline fn read64(p: [*]const u8, offset: usize) u64 {
    return mem.readInt(u64, p[offset..][0..8], .little);
}

inline fn read32(p: [*]const u8, offset: usize) u32 {
    return mem.readInt(u32, p[offset..][0..4], .little);
}

/// The seed premix.
inline fn premix(seed_in: u64) u64 {
    return seed_in ^ mix(seed_in ^ secret[2], secret[1]);
}

/// The closing avalanche. `i` is the length threaded into the high half.
inline fn finalize(seed: u64, a: u64, b: u64, i: usize) u64 {
    const m = mum(a ^ secret[1], b ^ seed);
    return mix(m.low ^ secret[7], m.high ^ secret[1] ^ @as(u64, i));
}

/// Case-insensitive variant of the short-key hash: every loaded byte is
/// folded with `| 0x20`. Strings that differ only in ASCII case therefore
/// hash identically, which is what a case-insensitive map needs; the map
/// still resolves fold collisions with `eqlIgnoreCase`.
inline fn fold64(w: u64) u64 {
    return w | 0x2020_2020_2020_2020;
}

inline fn fold32(w: u32) u32 {
    return w | 0x2020_2020;
}

pub inline fn hashFold(input: []const u8) u64 {
    const len = input.len;
    const p = input.ptr;
    var seed = premix(0);
    var a: u64 = undefined;
    var b: u64 = undefined;
    if (len <= 16) {
        if (len >= 4) {
            seed ^= @as(u64, len);
            if (len >= 8) {
                a = fold64(read64(p, 0));
                b = fold64(read64(p, len - 8));
            } else {
                a = fold32(read32(p, 0));
                b = fold32(read32(p, len - 4));
            }
        } else if (len > 0) {
            a = (@as(u64, p[0] | 0x20) << 45) | (p[len - 1] | 0x20);
            b = p[len >> 1] | 0x20;
        } else {
            a = 0;
            b = 0;
        }
    } else {
        seed = mix(fold64(read64(p, 0)) ^ secret[2], fold64(read64(p, 8)) ^ seed);
        const tail = p + len - 16;
        a = fold64(read64(tail, 0)) ^ @as(u64, len);
        b = fold64(read64(tail, 8));
    }
    return finalize(seed, a, b, len);
}

test "hashFold ignores ascii case" {
    try testing.expectEqual(hashFold("main.zig"), hashFold("MAIN.ZIG"));
    try testing.expectEqual(hashFold("Makefile"), hashFold("makefile"));
    try testing.expect(hashFold("main.zig") != hashFold("main.ziq"));
}
