# The Mojo port of tests/fixtures/kotlin-owners `Text.kt` (`tests/loop.rs`
# `kotlin_top_level_and_companion_replay`): a top-level function, a companion object's
# `@JvmStatic` member and a nested object's.


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


def _kotlin_space(cp: Int) -> Bool:
    """Kotlin's `Char.isWhitespace()`: `Character.isWhitespace` or `Character.isSpaceChar`.
    """
    return (
        (cp >= 9 and cp <= 13)
        or (cp >= 0x1C and cp <= 0x20)
        or cp == 0xA0
        or cp == 0x1680
        or (cp >= 0x2000 and cp <= 0x200A)
        or cp == 0x2028
        or cp == 0x2029
        or cp == 0x202F
        or cp == 0x205F
        or cp == 0x3000
    )


def _utf8_length(cp: Int) -> Int:
    """The number of UTF-8 bytes of the code point `cp`."""
    if cp < 0x80:
        return 1
    if cp < 0x800:
        return 2
    if cp < 0x10000:
        return 3
    return 4


def _digit(cp: Int) -> Int:
    """`Character.digit(cp, 10)` for the decimal digit blocks the inputs use; -1 otherwise.
    """
    for zero in [0x30, 0x660, 0x6F0, 0x966, 0xFF10]:
        if cp >= zero and cp <= zero + 9:
            return cp - zero
    return -1


# Port of `Shapes.Sign.sign`.
def sign(n: Int64) raises -> Int64:
    if n < 0:
        return -1
    if n > 0:
        return 1
    return 0


# Port of `slug`.
def slug(s: String) raises -> String:
    return s.replace(" ", "-")


# Port of `parse`: `s.trim().toLong()`, which is `java.lang.Long.parseLong`.
def parse(s: String) raises -> Int64:
    var b = s.as_bytes()
    var cps = _decode(s)
    # Byte offsets of the trimmed text: every Kotlin space is one code point.
    var start = 0
    var end = len(b)
    var first = 0
    var last = len(cps)
    while first < last and _kotlin_space(cps[first]):
        start += _utf8_length(cps[first])
        first += 1
    while last > first and _kotlin_space(cps[last - 1]):
        end -= _utf8_length(cps[last - 1])
        last -= 1
    var bad = (
        'NumberFormatException: For input string: "'
        + String(s[byte=start:end])
        + '"'
    )
    if first == last:
        raise Error(bad)
    var i = first
    var negative = False
    # Accumulated negatively, as `parseLong` does, so `Long.MIN_VALUE` fits.
    var limit = -Int64.MAX
    if cps[i] < 0x30:
        if cps[i] == 45:
            negative = True
            limit = Int64.MIN
        elif cps[i] != 43:
            raise Error(bad)
        i += 1
        if i == last:
            raise Error(bad)
    var multmin: Int64 = -922337203685477580
    var result: Int64 = 0
    while i < last:
        var d = _digit(cps[i])
        if d < 0 or result < multmin:
            raise Error(bad)
        result *= 10
        if result < limit + Int64(d):
            raise Error(bad)
        result -= Int64(d)
        i += 1
    return result if negative else -result
