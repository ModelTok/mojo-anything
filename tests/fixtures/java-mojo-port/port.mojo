# The Mojo port of tests/fixtures/java `src/main/java/com/example/text/` (`tests/loop.rs`
# `java_mojo_*`): Java's semantics over UTF-16 code units, 32-bit `int` wrapping and truncating
# division.
#
# `_letter_or_digit` and `_java_lower` cover the scripts the recorded inputs use (Latin, Greek,
# Cyrillic, Armenian, Hebrew, Arabic, Devanagari, kana, CJK, Hangul, the full-width forms); they
# are not complete copies of Java's Unicode tables.

from emberjson import Object
from json import JsonValue
from std.utils.numerics import nan


def _decode(s: String) -> List[Int]:
    """The code points of `s`."""
    var b = s.as_bytes()
    var n = len(b)
    var out = List[Int]()
    var i = 0
    while i < n:
        var c = Int(b[i])
        if c < 0x80:
            out.append(c)
            i += 1
        elif c < 0xE0:
            out.append(((c & 0x1F) << 6) | (Int(b[i + 1]) & 0x3F))
            i += 2
        elif c < 0xF0:
            out.append(
                ((c & 0x0F) << 12)
                | ((Int(b[i + 1]) & 0x3F) << 6)
                | (Int(b[i + 2]) & 0x3F)
            )
            i += 3
        else:
            out.append(
                ((c & 0x07) << 18)
                | ((Int(b[i + 1]) & 0x3F) << 12)
                | ((Int(b[i + 2]) & 0x3F) << 6)
                | (Int(b[i + 3]) & 0x3F)
            )
            i += 4
    return out^


def _encode(cps: List[Int]) -> String:
    """The UTF-8 text of the code points `cps`."""
    var out = List[UInt8]()
    for i in range(len(cps)):
        var cp = cps[i]
        if cp < 0x80:
            out.append(UInt8(cp))
        elif cp < 0x800:
            out.append(UInt8(0xC0 | (cp >> 6)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
        elif cp < 0x10000:
            out.append(UInt8(0xE0 | (cp >> 12)))
            out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
        else:
            out.append(UInt8(0xF0 | (cp >> 18)))
            out.append(UInt8(0x80 | ((cp >> 12) & 0x3F)))
            out.append(UInt8(0x80 | ((cp >> 6) & 0x3F)))
            out.append(UInt8(0x80 | (cp & 0x3F)))
    return String(unsafe_from_utf8=Span(out))


def _one(cp: Int) -> String:
    var cps = List[Int]()
    cps.append(cp)
    return _encode(cps)


def _utf16(cps: List[Int]) -> List[Int]:
    """The UTF-16 code units of the code points `cps`, as Java's `String` holds them.
    """
    var out = List[Int]()
    for i in range(len(cps)):
        var cp = cps[i]
        if cp >= 0x10000:
            out.append(0xD800 + ((cp - 0x10000) >> 10))
            out.append(0xDC00 + ((cp - 0x10000) & 0x3FF))
        else:
            out.append(cp)
    return out^


def _from_utf16(units: List[Int]) -> List[Int]:
    """The code points of the UTF-16 code units `units`."""
    var out = List[Int]()
    var i = 0
    while i < len(units):
        var u = units[i]
        if u >= 0xD800 and u < 0xDC00 and i + 1 < len(units):
            out.append(0x10000 + ((u - 0xD800) << 10) + (units[i + 1] - 0xDC00))
            i += 2
        else:
            out.append(u)
            i += 1
    return out^


def _cased(cp: Int) -> Bool:
    var s = _one(cp)
    return s.lower() != s or s.upper() != s


def _case_ignorable(cp: Int) -> Bool:
    return (
        (cp >= 0x300 and cp <= 0x36F)
        or cp == 0x27
        or cp == 0xAD
        or cp == 0xB7
        or cp == 0x2019
        or (cp >= 0x200B and cp <= 0x200F)
    )


def _final_sigma(cps: List[Int], i: Int) -> Bool:
    """Unicode's Final_Sigma condition, as `String.toLowerCase` applies it."""
    var j = i - 1
    while j >= 0 and _case_ignorable(cps[j]):
        j -= 1
    if j < 0 or not _cased(cps[j]):
        return False
    var k = i + 1
    while k < len(cps) and _case_ignorable(cps[k]):
        k += 1
    return k >= len(cps) or not _cased(cps[k])


def _java_lower(cps: List[Int]) -> List[Int]:
    """`String.toLowerCase(Locale.ROOT)`."""
    var out = List[Int]()
    for i in range(len(cps)):
        var cp = cps[i]
        if cp < 0x80:
            out.append(cp + 32 if cp >= 65 and cp <= 90 else cp)
        elif cp == 0x130:
            # İ lowers to i and a combining dot above.
            out.append(0x69)
            out.append(0x307)
        elif cp == 0x3A3:
            out.append(0x3C2 if _final_sigma(cps, i) else 0x3C3)
        else:
            var lowered = _decode(_one(cp).lower())
            for j in range(len(lowered)):
                out.append(lowered[j])
    return out^


def _letter_or_digit(u: Int) -> Bool:
    """`Character.isLetterOrDigit(char)` for one UTF-16 code unit."""
    if u < 0x80:
        return (
            (u >= 48 and u <= 57)
            or (u >= 65 and u <= 90)
            or (u >= 97 and u <= 122)
        )
    if u == 0xAA or u == 0xB5 or u == 0xBA:
        return True
    if u < 0x2C2:
        return u >= 0xC0 and u != 0xD7 and u != 0xF7
    if u < 0x370:
        return (
            (u >= 0x2C6 and u <= 0x2D1)
            or (u >= 0x2E0 and u <= 0x2E4)
            or u == 0x2EC
            or u == 0x2EE
        )
    if u < 0x530:
        return (
            (u >= 0x370 and u <= 0x374)
            or u == 0x376
            or u == 0x377
            or (u >= 0x37A and u <= 0x37D)
            or u == 0x37F
            or u == 0x386
            or (u >= 0x388 and u <= 0x38A)
            or u == 0x38C
            or (u >= 0x38E and u <= 0x3A1)
            or (u >= 0x3A3 and u <= 0x3F5)
            or (u >= 0x3F7 and u <= 0x481)
            or (u >= 0x48A and u <= 0x52F)
        )
    if u < 0x600:
        return (
            (u >= 0x531 and u <= 0x556)
            or u == 0x559
            or (u >= 0x560 and u <= 0x588)
            or (u >= 0x5D0 and u <= 0x5EA)
            or (u >= 0x5EF and u <= 0x5F2)
        )
    if u < 0x900:
        return (
            (u >= 0x620 and u <= 0x64A)
            or (u >= 0x660 and u <= 0x669)
            or (u >= 0x66E and u <= 0x66F)
            or (u >= 0x671 and u <= 0x6D3)
            or u == 0x6D5
            or (u >= 0x6F0 and u <= 0x6FC)
        )
    if u < 0x980:
        return (
            (u >= 0x904 and u <= 0x939)
            or u == 0x93D
            or u == 0x950
            or (u >= 0x958 and u <= 0x961)
            or (u >= 0x966 and u <= 0x96F)
            or (u >= 0x971 and u <= 0x97F)
        )
    if u >= 0x1E00 and u <= 0x1EFF:
        return True
    if u >= 0x3041 and u <= 0x3096:
        return True
    if u >= 0x309D and u <= 0x309F:
        return True
    if u >= 0x30A1 and u <= 0x30FA:
        return True
    if u >= 0x30FC and u <= 0x30FF:
        return True
    if u >= 0x3400 and u <= 0x4DBF:
        return True
    if u >= 0x4E00 and u <= 0x9FFF:
        return True
    if u >= 0xAC00 and u <= 0xD7A3:
        return True
    if u >= 0xF900 and u <= 0xFAFF:
        return True
    return (
        (u >= 0xFF10 and u <= 0xFF19)
        or (u >= 0xFF21 and u <= 0xFF3A)
        or (u >= 0xFF41 and u <= 0xFF5A)
        or (u >= 0xFF66 and u <= 0xFFDC)
    )


def _digit(cp: Int) -> Int:
    """`Character.digit(cp, 10)` for the decimal digit blocks the inputs use; -1 otherwise.
    """
    for zero in [0x30, 0x660, 0x6F0, 0x966, 0xFF10]:
        if cp >= zero and cp <= zero + 9:
            return cp - zero
    return -1


def _wrap32(x: Int64) -> Int64:
    """`x` wrapped to Java's 32-bit `int`."""
    var y = x & 0xFFFFFFFF
    if y >= 0x80000000:
        y -= 0x100000000
    return y


def _rem(a: Int64, b: Int64) -> Int64:
    """Java's `a % b`: the sign of `a`, and `Long.MIN_VALUE % -1` is 0."""
    if b == -1:
        return 0
    var r = a % b
    if r != 0 and ((r < 0) != (a < 0)):
        r -= b
    return r


def _abs(a: Int64) -> Int64:
    """`Math.abs(long)`: `Long.MIN_VALUE` stays negative."""
    if a < 0 and a != Int64.MIN:
        return -a
    return a


def _words(text: String) -> List[String]:
    """`text.trim().split("\\s+")` without empty words."""
    var b = text.as_bytes()
    var start = 0
    var end = len(b)
    while start < end and b[start] <= 32:
        start += 1
    while end > start and b[end - 1] <= 32:
        end -= 1
    var out = List[String]()
    var i = start
    while i < end:
        var c = b[i]
        if c == 32 or (c >= 9 and c <= 13):
            i += 1
            continue
        var j = i
        while j < end and not (b[j] == 32 or (b[j] >= 9 and b[j] <= 13)):
            j += 1
        out.append(String(text[byte=i:j]))
        i = j
    return out^


# Port of `slugify`.
def slugify(text: String, max: Int32) raises -> String:
    var units = _utf16(_java_lower(_decode(text)))
    var out = List[Int]()
    var dash = False
    for i in range(len(units)):
        var u = units[i]
        if _letter_or_digit(u):
            out.append(u)
            dash = False
        elif not dash and len(out) > 0:
            out.append(45)
            dash = True
    var n = len(out)
    if n > 0 and out[n - 1] == 45:
        n -= 1
    var limit = Int(max)
    if limit > 0 and n > limit:
        n = limit
    var kept = List[Int]()
    for i in range(n):
        kept.append(out[i])
    return _encode(_from_utf16(kept))


# Port of `words`.
def words(text: String) raises -> List[String]:
    return _words(text)


# Port of `frequencies`.
def frequencies(text: String) raises -> JsonValue:
    var keys = List[String]()
    var counts = List[Int]()
    var ws = _words(text)
    for i in range(len(ws)):
        var key = _encode(_java_lower(_decode(ws[i])))
        var found = -1
        for j in range(len(keys)):
            if keys[j] == key:
                found = j
                break
        if found < 0:
            keys.append(key)
            counts.append(1)
        else:
            counts[found] += 1
    var o = Object()
    for j in range(len(keys)):
        o[keys[j]] = JsonValue(Int64(counts[j]))
    return JsonValue(o^)


# Port of `parsePort`.
def parse_port(text: String) raises -> Int32:
    var cps = _decode(text)
    var start = 0
    var end = len(cps)
    while start < end and cps[start] <= 32:
        start += 1
    while end > start and cps[end - 1] <= 32:
        end -= 1
    var trimmed = List[Int]()
    for i in range(start, end):
        trimmed.append(cps[i])
    var bad = (
        'NumberFormatException: For input string: "' + _encode(trimmed) + '"'
    )
    if len(trimmed) == 0:
        raise Error(bad)
    var i = 0
    var negative = False
    if trimmed[0] == 45 or trimmed[0] == 43:
        negative = trimmed[0] == 45
        i = 1
        if len(trimmed) == 1:
            raise Error(bad)
    var value: Int64 = 0
    while i < len(trimmed):
        var d = _digit(trimmed[i])
        if d < 0:
            raise Error(bad)
        value = value * 10 + Int64(d)
        if value > 2147483648:
            raise Error(bad)
        i += 1
    if negative:
        value = -value
    if value > 2147483647:
        raise Error(bad)
    if value < 1 or value > 65535:
        raise Error(
            "IllegalArgumentException: port out of range: " + String(value)
        )
    return Int32(value)


# Port of `hash`.
def hash(text: String) raises -> Int32:
    var units = _utf16(_decode(text))
    var h: Int64 = 0
    for i in range(len(units)):
        h = (h * 31 + Int64(units[i])) & 0xFFFFFFFF
    return Int32(_wrap32(h))


# Port of `gcd`.
def gcd(a: Int64, b: Int64) raises -> Int64:
    var x = _abs(a)
    var y = _abs(b)
    while y != 0:
        var t = _rem(x, y)
        x = y
        y = t
    return x


# Port of `mean`.
def mean(values: List[Float64]) raises -> Float64:
    if len(values) == 0:
        return nan[DType.float64]()
    var sum: Float64 = 0
    for i in range(len(values)):
        sum += values[i]
    return sum / Float64(len(values))


# Port of `pages`.
def pages(total: Int32, per_page: Int32) raises -> Int32:
    var p = Int64(per_page)
    if p == 0:
        raise Error("ArithmeticException: / by zero")
    var s = _wrap32(Int64(total) + p - 1)
    var a = s if s >= 0 else -s
    var d = p if p >= 0 else -p
    var q = a // d
    if (s < 0) != (p < 0):
        q = -q
    return Int32(_wrap32(q))
