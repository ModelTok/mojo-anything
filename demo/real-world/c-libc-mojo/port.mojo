# The Mojo port of the glibc behaviour behind `src/facade.c` ("C" locale): `strtol`, `atoi`,
# `strtod`, `strspn`, `strcmp` and the ctype functions. `exports.mojo` exports each function
# under its C name.

from std.utils.numerics import inf, nan

comptime Bytes = Span[UInt8, ImmutAnyOrigin]
comptime LONG_MAX: Int64 = 9223372036854775807
comptime LONG_MIN: Int64 = -LONG_MAX - 1


def _space(b: UInt8) -> Bool:
    """C's `isspace` in the "C" locale."""
    return b == 32 or (b >= 9 and b <= 13)


def _digit(b: Int) -> Int:
    """The value of `b` as a digit in base 36; 99 for anything else (or past the end).
    """
    if b >= 48 and b <= 57:
        return b - 48
    if b >= 97 and b <= 122:
        return b - 87
    if b >= 65 and b <= 90:
        return b - 55
    return 99


def _at(s: Bytes, i: Int) -> Int:
    """The byte at `i`, or -1 past the end (the C string's NUL)."""
    return Int(s[i]) if i < len(s) else -1


def _lower(b: Int) -> Int:
    return b + 32 if b >= 65 and b <= 90 else b


# Port of `parse_long` (`src/facade.c:6`).
# `strtol(text, NULL, base)`: leading space, a sign, `0x` for base 16 or 0, a leading `0`
# meaning octal for base 0; clamps to `LONG_MIN`/`LONG_MAX`; 0 for a bad base.
def parse_long(text: Optional[Bytes], base: Int32) -> Int64:
    if not text:
        return 0
    var s = text.value()
    if base != 0 and (base < 2 or base > 36):
        return 0
    var i = 0
    while i < len(s) and _space(s[i]):
        i += 1
    var negative = False
    if _at(s, i) == 45:
        i += 1
        negative = True
    elif _at(s, i) == 43:
        i += 1
    var b = Int(base)
    var hex_prefix = (
        _at(s, i) == 48
        and (_at(s, i + 1) == 120 or _at(s, i + 1) == 88)
        and _digit(_at(s, i + 2)) < 16
    )
    if (b == 0 or b == 16) and hex_prefix:
        i += 2
        b = 16
    elif b == 0:
        b = 8 if _at(s, i) == 48 else 10
    # Accumulated up to LONG_MAX + 1, where it stops growing.
    var limit: UInt64 = 1 << 63
    var value: UInt64 = 0
    var overflow = False
    while _digit(_at(s, i)) < b:
        var d = UInt64(_digit(_at(s, i)))
        if value > (limit - d) // UInt64(b):
            overflow = True
            value = limit
        else:
            value = value * UInt64(b) + d
        i += 1
    if negative:
        if overflow or value == limit:
            return LONG_MIN
        return -value.cast[DType.int64]()
    if overflow or value > UInt64(LONG_MAX):
        return LONG_MAX
    return value.cast[DType.int64]()


# Port of `parse_int` (`src/facade.c:7`).
# `atoi`: glibc's `(int) strtol(text, NULL, 10)`, truncating.
def parse_int(text: Optional[Bytes]) -> Int32:
    return parse_long(text, 10).cast[DType.int32]()


def _pow2(n: Int) -> Float64:
    """`2.0` to the power `n` as LLVM's `powi` computes it: by squaring, and as `1 / 2^-n`
    for a negative `n` (so below `2^-1023` it is 0, as the recorded port's `powi` was).
    """
    if n < 0:
        return 1.0 / _pow2(-n)
    var result: Float64 = 1.0
    var base: Float64 = 2.0
    var k = n
    while k > 0:
        if k & 1:
            result *= base
        base *= base
        k >>= 1
    return result


def _hex_float(s: Bytes, start: Int) -> Optional[Float64]:
    """The value of the hex float digits at `start` (after `0x`): `h.hhhp±d`. `None` without
    a hex digit."""
    var mantissa: UInt128 = 0
    var exp = 0
    var any = False
    var i = start
    var frac = False
    while i < len(s):
        var b = Int(s[i])
        if b == 46 and not frac:
            frac = True
        else:
            var d = _digit(b)
            if d >= 16:
                break
            any = True
            if (mantissa >> 120) == 0:
                mantissa = mantissa * 16 + UInt128(d)
                if frac:
                    exp -= 4
            elif not frac:
                exp += 4
        i += 1
    if not any:
        return None
    if _at(s, i) == 112 or _at(s, i) == 80:
        var k = i + 1
        var negative = _at(s, k) == 45
        if _at(s, k) == 43 or _at(s, k) == 45:
            k += 1
        if _digit(_at(s, k)) < 10:
            var e = 0
            while _digit(_at(s, k)) < 10:
                e = min(e * 10 + _digit(_at(s, k)), 100000)
                k += 1
            exp += -e if negative else e
    return mantissa.cast[DType.float64]() * _pow2(max(-2000, min(exp, 2000)))


# Port of `parse_double` (`src/facade.c:8`).
# `strtod(text, NULL)`: the longest prefix that is a decimal or hex float, `inf[inity]` or
# `nan[(...)]`, correctly rounded.
def parse_double(text: Optional[Bytes]) -> Float64:
    if not text:
        return 0.0
    var s = text.value()
    var i = 0
    while i < len(s) and _space(s[i]):
        i += 1
    var sign: Float64 = 1.0
    if _at(s, i) == 45:
        i += 1
        sign = -1.0
    elif _at(s, i) == 43:
        i += 1
    if (
        _lower(_at(s, i)) == 105
        and _lower(_at(s, i + 1)) == 110
        and _lower(_at(s, i + 2)) == 102
    ):
        return sign * inf[DType.float64]()
    if (
        _lower(_at(s, i)) == 110
        and _lower(_at(s, i + 1)) == 97
        and _lower(_at(s, i + 2)) == 110
    ):
        var n = nan[DType.float64]()
        return -n if sign < 0 else n
    if _at(s, i) == 48 and _lower(_at(s, i + 1)) == 120:
        var v = _hex_float(s, i + 2)
        if v:
            return sign * v.value()
        return sign * 0.0
    # Decimal: digits, an optional fraction, an optional exponent with at least one digit.
    var j = i
    var digits = 0
    while _digit(_at(s, j)) < 10:
        j += 1
        digits += 1
    if _at(s, j) == 46:
        j += 1
        while _digit(_at(s, j)) < 10:
            j += 1
            digits += 1
    if digits == 0:
        # Nothing converted: strtod returns +0.0 whatever sign came before.
        return 0.0
    if _lower(_at(s, j)) == 101:
        var k = j + 1
        if _at(s, k) == 43 or _at(s, k) == 45:
            k += 1
        if _digit(_at(s, k)) < 10:
            while _digit(_at(s, k)) < 10:
                k += 1
            j = k
    var number = String()
    if _at(s, i) == 46:
        number += "0"
    for k in range(i, j):
        if not (k == j - 1 and s[k] == 46):
            number += chr(Int(s[k]))
    try:
        return sign * atof(number)
    except:
        return sign * 0.0


# Port of `span` (`src/facade.c:9`).
# `strspn`: the length of the prefix made of bytes in `accept`.
def span(text: Optional[Bytes], accept: Optional[Bytes]) -> UInt:
    if not text or not accept:
        return 0
    var s = text.value()
    var a = accept.value()
    var n = 0
    while n < len(s):
        var found = False
        for k in range(len(a)):
            if a[k] == s[n]:
                found = True
                break
        if not found:
            break
        n += 1
    return UInt(n)


# Port of `compare` (`src/facade.c:10`).
# The sign of `strcmp`: bytes compare as unsigned char.
def compare(a: Optional[Bytes], b: Optional[Bytes]) -> Int32:
    var x = a.value() if a else Bytes()
    var y = b.value() if b else Bytes()
    for k in range(min(len(x), len(y))):
        if x[k] != y[k]:
            return -1 if x[k] < y[k] else 1
    if len(x) == len(y):
        return 0
    return -1 if len(x) < len(y) else 1


def _byte(c: Int32) -> Int:
    """glibc's tables cover -128..=255; a negative `char` reads like its unsigned byte. -1
    outside that range."""
    if c >= 0 and c <= 255:
        return Int(c)
    if c >= -128 and c <= -2:
        return Int(c) + 256
    return -1


def _alpha(b: Int) -> Bool:
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)


# Port of `is_alpha` (`src/facade.c:14`).
# `isalpha` in the "C" locale. Outside -128..=255 C's behaviour is undefined.
def is_alpha(c: Int32) -> Int32:
    return 1 if _alpha(_byte(c)) else 0


# Port of `is_space` (`src/facade.c:15`).
def is_space(c: Int32) -> Int32:
    var b = _byte(c)
    return 1 if b >= 0 and _space(UInt8(b)) else 0


# Port of `is_punct` (`src/facade.c:16`).
# `ispunct` in the "C" locale: printable ASCII that is not a letter, digit or space.
def is_punct(c: Int32) -> Int32:
    var b = _byte(c)
    var punct = (
        (b >= 33 and b <= 47)
        or (b >= 58 and b <= 64)
        or (b >= 91 and b <= 96)
        or (b >= 123 and b <= 126)
    )
    return 1 if punct else 0


# Port of `to_upper` (`src/facade.c:17`).
# `toupper` in the "C" locale: glibc maps a negative `char` to its unsigned byte.
def to_upper(c: Int32) -> Int32:
    var b = _byte(c)
    if b < 0 or c == -1:
        return c
    return Int32(b - 32) if b >= 97 and b <= 122 else Int32(b)
