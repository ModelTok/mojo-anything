# A Mojo port of FFmpeg n7.1 libavutil/rational.c, changed from the C original.
# Copyright (c) 2003 Michael Niedermayer
#
# This library is free software; you can redistribute it and/or modify it under the terms of
# the GNU Lesser General Public License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version. It is distributed WITHOUT
# ANY WARRANTY; see ../LICENSE for the license text.
#
# The Mojo port of `rational.c`; `exports.mojo` exports each function under its C name.
# `av_find_nearest_q_idx` (reads a list through a pointer) and `av_gcd_q` stay in C, as in
# the Rust reference port. Integer
# arithmetic wraps as the C code's does (two's complement); `_div` and `_rem` truncate towards
# zero as C's `/` and `%` do, where Mojo's `//` and `%` floor.

from std.bit import count_leading_zeros, count_trailing_zeros
from std.math import floor
from std.memory import bitcast

from c_structs import AVRational

comptime INT_MAX: Int64 = 2147483647
comptime INT64_MAX: Int64 = 9223372036854775807
comptime INT64_MIN: Int64 = -INT64_MAX - 1
comptime AV_ROUND_DOWN: Int32 = 2
comptime AV_ROUND_UP: Int32 = 3
comptime AV_ROUND_NEAR_INF: Int32 = 5


def _div(a: Int64, b: Int64) -> Int64:
    """C's `a / b` for `int64_t`, wrapping `INT64_MIN / -1` to `INT64_MIN`."""
    if b == -1:
        return 0 - a
    var q = a // b
    if (a % b != 0) and ((a < 0) != (b < 0)):
        q += 1
    return q


def _abs(a: Int64) -> Int64:
    """`llabs` with `INT64_MIN` wrapping to itself."""
    return a if a >= 0 else 0 - a


def _gcd(a: Int64, b: Int64) -> Int64:
    """`av_gcd` of `mathematics.c`."""
    if a == 0:
        return b
    if b == 0:
        return a
    var za = count_trailing_zeros(a)
    var zb = count_trailing_zeros(b)
    var u = _abs(a >> za)
    var v = _abs(b >> zb)
    while u != v:
        if u > v:
            var t = u
            u = v
            v = t
        v -= u
        v >>= count_trailing_zeros(v)
    return (u.cast[DType.uint64]() << min(za, zb).cast[DType.uint64]()).cast[
        DType.int64
    ]()


def _u(x: Int32) -> UInt64:
    """An `int` as C converts it to `uint64_t`."""
    return x.cast[DType.int64]().cast[DType.uint64]()


def _lin(x: UInt64, f: Int32, g: Int32) -> UInt64:
    """`x * f + g` as C computes it with `x` a `uint64_t` and `f`, `g` ints."""
    return x * _u(f) + _u(g)


# Port of `int av_reduce(int *dst_num, int *dst_den, int64_t num, int64_t den, int64_t max)`
# (`rational.c:35`): the closest fraction to `num/den` with both terms at most `max`; 1 when
# exact.
def av_reduce(
    mut dst_num: Optional[Int32],
    mut dst_den: Optional[Int32],
    num: Int64,
    den: Int64,
    max: Int64,
) -> Int32:
    var a0n: Int32 = 0
    var a0d: Int32 = 1
    var a1n: Int32 = 1
    var a1d: Int32 = 0
    var sign = (num < 0) != (den < 0)
    var g = _gcd(_abs(num), _abs(den))
    var n = num
    var d = den
    if g != 0:
        n = _div(_abs(n), g)
        d = _div(_abs(d), g)
    if n <= max and d <= max:
        a1n = n.cast[DType.int32]()
        a1d = d.cast[DType.int32]()
        d = 0
    while d != 0:
        var x = _div(n, d).cast[DType.uint64]()
        var next_den = (
            n.cast[DType.uint64]() - d.cast[DType.uint64]() * x
        ).cast[DType.int64]()
        var a2n = _lin(x, a1n, a0n).cast[DType.int64]()
        var a2d = _lin(x, a1d, a0d).cast[DType.int64]()
        if a2n > max or a2d > max:
            if a1n != 0:
                x = _div(
                    max - a0n.cast[DType.int64](), a1n.cast[DType.int64]()
                ).cast[DType.uint64]()
            if a1d != 0:
                var y = _div(
                    max - a0d.cast[DType.int64](), a1d.cast[DType.int64]()
                ).cast[DType.uint64]()
                if y < x:
                    x = y
            var lhs = d.cast[DType.uint64]() * _lin(x * 2, a1d, a0d)
            var rhs = (n * a1d.cast[DType.int64]()).cast[DType.uint64]()
            if lhs > rhs:
                a1n = _lin(x, a1n, a0n).cast[DType.int32]()
                a1d = _lin(x, a1d, a0d).cast[DType.int32]()
            break
        a0n = a1n
        a0d = a1d
        a1n = a2n.cast[DType.int32]()
        a1d = a2d.cast[DType.int32]()
        n = d
        d = next_den
    if dst_num:
        dst_num = Optional(0 - a1n if sign else a1n)
    if dst_den:
        dst_den = Optional(a1d)
    return Int32(1) if d == 0 else Int32(0)


def _rescale_rnd(a: Int64, b: Int64, c: Int64, rnd: Int32) -> Int64:
    """`av_rescale_rnd` of `mathematics.c` for the rounding modes this file uses (no
    `AV_ROUND_PASS_MINMAX`)."""
    if c <= 0 or b < 0:
        return INT64_MIN
    if a < 0:
        var flipped = rnd ^ ((rnd >> 1) & 1)
        return 0 - _rescale_rnd(0 - max(a, 0 - INT64_MAX), b, c, flipped)
    var r: Int64 = 0
    if rnd == AV_ROUND_NEAR_INF:
        r = c // 2
    elif rnd & 1 != 0:
        r = c - 1
    if b <= INT_MAX and c <= INT_MAX:
        if a <= INT_MAX:
            return (a * b + r) // c
        var ad = a // c
        var a2 = (a % c * b + r) // c
        if ad >= INT_MAX and b != 0 and ad > (INT64_MAX - a2) // b:
            return INT64_MIN
        return ad * b + a2
    var ua = a.cast[DType.uint64]()
    var ub = b.cast[DType.uint64]()
    var uc = c.cast[DType.uint64]()
    var ur = r.cast[DType.uint64]()
    var a0 = ua & 0xFFFFFFFF
    var a1 = ua >> 32
    var b0 = ub & 0xFFFFFFFF
    var b1 = ub >> 32
    var t1 = a0 * b1 + a1 * b0
    var t1a = t1 << 32
    a0 = a0 * b0 + t1a
    a1 = a1 * b1 + (t1 >> 32) + (UInt64(1) if a0 < t1a else UInt64(0))
    a0 = a0 + ur
    a1 = a1 + (UInt64(1) if a0 < ur else UInt64(0))
    for i in range(63, -1, -1):
        a1 = a1 + a1 + ((a0 >> UInt64(i)) & 1)
        t1 = t1 + t1
        if uc <= a1:
            a1 -= uc
            t1 += 1
    if t1 > INT64_MAX.cast[DType.uint64]():
        return INT64_MIN
    return t1.cast[DType.int64]()


def _cmp_q(a: AVRational, b: AVRational) -> Int32:
    """`av_cmp_q` of `rational.h`: -1, 0 or 1, `INT_MIN` when either is 0/0."""
    var tmp = (
        a.num.cast[DType.int64]() * b.den.cast[DType.int64]()
        - b.num.cast[DType.int64]() * a.den.cast[DType.int64]()
    )
    if tmp != 0:
        return (
            (tmp ^ a.den.cast[DType.int64]() ^ b.den.cast[DType.int64]()) >> 63
        ).cast[DType.int32]() | 1
    if b.den != 0 and a.den != 0:
        return 0
    if a.num != 0 and b.num != 0:
        return (a.num >> 31) - (b.num >> 31)
    return -2147483648


def _reduced(num: Int64, den: Int64, max: Int64) -> AVRational:
    """`av_reduce` into an `AVRational`."""
    var n: Optional[Int32] = Optional(Int32(0))
    var d: Optional[Int32] = Optional(Int32(0))
    _ = av_reduce(n, d, num, den, max)
    return AVRational(n.value(), d.value())


# Port of `AVRational av_mul_q(AVRational b, AVRational c)` (`rational.c:80`).
def av_mul_q(b: AVRational, c: AVRational) -> AVRational:
    return _reduced(
        b.num.cast[DType.int64]() * c.num.cast[DType.int64](),
        b.den.cast[DType.int64]() * c.den.cast[DType.int64](),
        INT_MAX,
    )


# Port of `AVRational av_div_q(AVRational b, AVRational c)` (`rational.c:88`).
def av_div_q(b: AVRational, c: AVRational) -> AVRational:
    return av_mul_q(b, AVRational(c.den, c.num))


# Port of `AVRational av_add_q(AVRational b, AVRational c)` (`rational.c:93`).
def av_add_q(b: AVRational, c: AVRational) -> AVRational:
    return _reduced(
        b.num.cast[DType.int64]() * c.den.cast[DType.int64]()
        + c.num.cast[DType.int64]() * b.den.cast[DType.int64](),
        b.den.cast[DType.int64]() * c.den.cast[DType.int64](),
        INT_MAX,
    )


# Port of `AVRational av_sub_q(AVRational b, AVRational c)` (`rational.c:101`).
def av_sub_q(b: AVRational, c: AVRational) -> AVRational:
    return av_add_q(b, AVRational(0 - c.num, c.den))


def _frexp_exponent(d: Float64) -> Int:
    """The exponent `frexp` gives `d` (finite): `d = m * 2^e` with `0.5 <= |m| < 1`, 0 for 0.
    """
    if d == 0.0:
        return 0
    var bits = bitcast[DType.uint64](abs(d))
    var biased = Int(bits >> 52)
    if biased == 0:
        return -1022 - (Int(count_leading_zeros(bits)) - 12)
    return biased - 1022


# Port of `AVRational av_d2q(double d, int max)` (`rational.c:106`): the closest fraction to
# `d` with terms at most `max`; 0/0 for NaN, ±1/0 beyond `INT_MAX`.
def av_d2q(d: Float64, max: Int32) -> AVRational:
    if d != d:
        return AVRational(0, 0)
    if abs(d) > (INT_MAX + 3).cast[DType.float64]():
        return AVRational(Int32(-1) if d < 0.0 else Int32(1), 0)
    var exponent = _frexp_exponent(d) - 1
    if exponent < 0:
        exponent = 0
    var den = Int64(1) << Int64(62 - exponent)
    var num = floor(d * den.cast[DType.float64]() + 0.5).cast[DType.int64]()
    var a = _reduced(num, den, max.cast[DType.int64]())
    if (a.num == 0 or a.den == 0) and d != 0.0 and max > 0 and max < 2147483647:
        return _reduced(num, den, INT_MAX)
    return a


# Port of `int av_nearer_q(AVRational q, AVRational q1, AVRational q2)` (`rational.c:127`): 1
# if `q1` is nearer to `q` than `q2`, -1 if `q2` is, 0 if both are as near.
def av_nearer_q(q: AVRational, q1: AVRational, q2: AVRational) -> Int32:
    var a = (
        q1.num.cast[DType.int64]() * q2.den.cast[DType.int64]()
        + q2.num.cast[DType.int64]() * q1.den.cast[DType.int64]()
    )
    var b = 2 * q1.den.cast[DType.int64]() * q2.den.cast[DType.int64]()
    var x_up = _rescale_rnd(a, q.den.cast[DType.int64](), b, AV_ROUND_UP)
    var x_down = _rescale_rnd(a, q.den.cast[DType.int64](), b, AV_ROUND_DOWN)
    var qn = q.num.cast[DType.int64]()
    var side: Int32 = (Int32(1) if x_up > qn else Int32(0)) - (
        Int32(1) if x_down < qn else Int32(0)
    )
    return side * _cmp_q(q2, q1)


def _log2(v: Int32) -> Int32:
    """`av_log2` of an `unsigned`: the index of the highest set bit, 0 for 0."""
    return (
        31 - count_leading_zeros(v.cast[DType.uint32]() | 1).cast[DType.int32]()
    )


def _scaled(num: Int64, den: Int64, shift: Int32) -> Int64:
    """`av_rescale(num, 1 << shift, den)`, or `av_rescale(num, 1, den << -shift)` for a
    negative `shift`."""
    if shift >= 0:
        return _rescale_rnd(
            num, Int64(1) << shift.cast[DType.int64](), den, AV_ROUND_NEAR_INF
        )
    var by = (0 - shift.cast[DType.int64]()) & 63
    return _rescale_rnd(num, 1, den << by, AV_ROUND_NEAR_INF)


# Port of `uint32_t av_q2intfloat(AVRational q)` (`rational.c:152`): `q` as the bits of the
# nearest IEEE single. Negating `INT_MIN` overflows in C; the recorded build (gcc -O1) wraps it,
# so `INT_MIN` stays negative through the log and the rescales, as here, and drops the sign of
# `x/0` (`num` cannot be negative there without overflow), so every `x/0` is `+inf`.
def av_q2intfloat(q: AVRational) -> UInt32:
    var num = q.num
    var den = q.den
    var sign: Int32 = 0
    if den < 0:
        den = 0 - den
        num = 0 - num
    if num < 0:
        num = 0 - num
        sign = 1
    if num == 0 and den == 0:
        return 0xFFC00000
    if num == 0:
        return 0
    if den == 0:
        return 0x7F800000
    var shift = 23 + _log2(den) - _log2(num)
    var n64 = num.cast[DType.int64]()
    var d64 = den.cast[DType.int64]()
    var n = _scaled(n64, d64, shift)
    shift -= Int32(1) if n >= (1 << 24) else Int32(0)
    shift += Int32(1) if n < (1 << 23) else Int32(0)
    n = _scaled(n64, d64, shift)
    var high = (sign << 31) | ((150 - shift) << 23)
    return (high.cast[DType.int64]() | (n - (1 << 23))).cast[DType.uint32]()
