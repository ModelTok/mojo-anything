# The Mojo port of tests/fixtures/java `src/main/java/com/example/text/` (`tests/loop.rs`
# `java_mojo_*`): Java's semantics over UTF-16 code units, 32-bit `int` wrapping and truncating
# division.
#
# `_letter_ranges` and `_java_lower` cover the scripts the recorded inputs use (Latin, Greek,
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
    # SAFETY: `out` holds the UTF-8 form of each code point above; a lone surrogate the
    # dispatcher handed in goes back in the same three-byte form, as Java's text holds it.
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


def _letter_ranges() raises -> List[Int]:
    """`Character.isLetterOrDigit(char)` as (first, last) UTF-16 unit pairs."""
    var text = String(
        "48-57 65-90 97-122 170-170 181-181 186-186 192-214 216-246 "
        + "248-705 710-721 736-740 748-748 750-750 880-884 886-887 "
        + "890-893 895-895 902-902 904-906 908-908 910-929 931-1013 "
        + "1015-1153 1162-1327 1329-1366 1369-1369 1376-1416 1488-1514 "
        + "1519-1522 1568-1610 1632-1641 1646-1647 1649-1747 1749-1749 "
        + "1776-1788 2308-2361 2365-2365 2384-2384 2392-2401 2406-2415 "
        + "2417-2431 7680-7935 12353-12438 12445-12447 12449-12538 "
        + "12540-12543 13312-19903 19968-40959 44032-55203 63744-64255 "
        + "65296-65305 65313-65338 65345-65370 65382-65500"
    )
    var out = List[Int]()
    for pair in text.split(" "):
        var ends = String(pair).split("-")
        out.append(Int(String(ends[0])))
        out.append(Int(String(ends[1])))
    return out^


def _in_ranges(u: Int, ranges: List[Int]) -> Bool:
    for i in range(0, len(ranges), 2):
        if u >= ranges[i] and u <= ranges[i + 1]:
            return True
    return False


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
    # A supplementary character is two surrogates, neither a letter: on code points it is one
    # separator, and every kept character is one UTF-16 unit, so `max` counts code points.
    var cps = _java_lower(_decode(text))
    var letters = _letter_ranges()
    var out = List[Int]()
    var dash = False
    for i in range(len(cps)):
        var u = cps[i]
        if _in_ranges(u, letters):
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
    return _encode(kept)


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
