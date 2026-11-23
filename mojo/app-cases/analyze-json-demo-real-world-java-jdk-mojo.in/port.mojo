# The Mojo port of the JDK behaviour behind `com.example.jdk.Jdk` (OpenJDK 25).
#
# `parse_radix` reads code points where Java reads UTF-16 units: a supplementary character is
# two surrogates to Java, which `Character.digit` rejects, so both refuse it.

from std.base64 import b64encode
from std.bit import bit_reverse
from std.memory import bitcast


def _unsigned(v: UInt64, radix: UInt64) -> String:
    # The digits of `v` in `radix`, lower-case, as `Long.toString` writes them.
    var out = String()
    var n = v
    while True:
        var d = Int(n % radix)
        out = chr(d + 48 if d < 10 else d + 87) + out
        n //= radix
        if n == 0:
            return out


# Port of `Integer.toString(int, int)`: a radix outside 2..36 means 10.
def to_radix(value: Int32, radix: Int32) raises -> String:
    var r = UInt64(Int(radix)) if radix >= 2 and radix <= 36 else 10
    var text = _unsigned(UInt64(abs(Int(value))), r)
    return "-" + text if value < 0 else text


# Port of `Integer.parseInt(String, int)`, with JDK 25's messages.
def parse_radix(text: String, radix: Int32) raises -> Int32:
    var nfe = "NumberFormatException: "
    var low = " less than Character.MIN_RADIX"
    var high = " greater than Character.MAX_RADIX"
    if radix < 2 or radix > 36:
        raise Error(
            nfe + "radix " + String(radix) + (low if radix < 2 else high)
        )
    var bad = nfe + 'For input string: "' + text + '"'
    if radix != 10:
        bad += " under radix " + String(radix)
    # The zero of every run of decimal digits (`Nd`) in the BMP that `Character.digit` reads
    # (all 37 in Java 25), then `A`, `a` and their full-width forms, read as 10 to 35.
    var table = (
        "30 660 6f0 7c0 966 9e6 a66 ae6 b66 be6 c66 ce6 d66 de6 e50 ed0 f20"
        " 1040 1090 17e0 1810 1946 19d0 1a80 1a90 1b50 1bb0 1c40 1c50 a620 a8d0"
        " a900 a9d0 a9f0 aa50 abf0 ff10 41 61 ff21 ff41"
    )
    var runs = List[Int]()
    for z in table.split(" "):
        runs.append(Int(atol(z, base=16)))
    var negative = text.startswith("-")
    var skip = 1 if negative or text.startswith("+") else 0
    var body = String(text[byte=skip:])
    if body.byte_length() == 0:
        raise Error(bad)
    var result = 0
    for ch in body.codepoints():
        var c = Int(ch.to_u32())
        var d = 99
        for i in range(len(runs)):
            if c >= runs[i] and c < runs[i] + (10 if i < 37 else 26):
                d = c - runs[i] + (0 if i < 37 else 10)
        result = result * Int(radix) + d
        if d >= Int(radix) or result > 2147483647 + Int(negative):
            raise Error(bad)
    return Int32(-result if negative else result)


# Port of `Integer.toBinaryString(int)`.
def to_binary(value: Int32) raises -> String:
    return _unsigned(UInt64(value.cast[DType.uint32]()), 2)


# Port of `Long.toHexString(long)`.
def to_hex(value: Int64) raises -> String:
    return _unsigned(value.cast[DType.uint64](), 16)


# Port of `Integer.reverse(int)`.
def reverse_bits(value: Int32) raises -> Int32:
    return bit_reverse(value)


# Port of `Math.floorMod(int, int)`: Mojo's `%` on `Int` floors, as Java's floorMod does.
def floor_mod(a: Int32, b: Int32) raises -> Int32:
    if b == 0:
        raise Error("ArithmeticException: / by zero")
    return Int32(Int(a) % Int(b))


# Port of `Math.addExact(int, int)`.
def add_exact(a: Int32, b: Int32) raises -> Int32:
    var s = Int(a) + Int(b)
    if s > 2147483647 or s < -2147483648:
        raise Error("ArithmeticException: integer overflow")
    return Int32(s)


def _exact(k: UInt64, q: Int) -> Tuple[String, Int]:
    # The digits of k * 2^q (no trailing zeros) and the point P: the value is 0.digits * 10^P.
    # Limbs of nine decimal digits, least significant first; 2^-n is 5^n * 10^-n.
    var base: UInt64 = 1_000_000_000
    var limbs: List[UInt64] = [k % base, k // base]
    var left = abs(q)
    while left > 0:
        var step = min(left, 12)
        var f = UInt64(1 << step) if q > 0 else UInt64(5**step)
        var carry: UInt64 = 0
        for i in range(len(limbs)):
            var t = limbs[i] * f + carry
            limbs[i] = t % base
            carry = t // base
        if carry > 0:
            limbs.append(carry)
        left -= step
    var s = String()
    for i in range(len(limbs) - 1, -1, -1):
        s += String(String(limbs[i] + base)[byte=1:])
    var digits = String(s.lstrip("0"))
    return (String(digits.rstrip("0")), digits.byte_length() + min(q, 0))


def _cmp(a: Tuple[String, Int], b: Tuple[String, Int]) -> Int:
    # -1, 0 or 1 as the non-zero decimal a is below, at or above b. With no trailing zeros, the
    # digits compare as text: a prefix is the smaller decimal.
    if a[1] != b[1]:
        return -1 if a[1] < b[1] else 1
    return -1 if a[0] < b[0] else (1 if a[0] > b[0] else 0)


def _render(sign: String, t: Int, scale: Int) -> String:
    # Java's layout of t * 10^scale: plain for 1e-3 <= |v| < 1e7, else `d.dddE±n`.
    var s = String(String(t).rstrip("0"))
    var n = s.byte_length()
    var point = String(t).byte_length() + scale
    if point < -2 or point > 7:
        var tail = String(s[byte=1:]) if n > 1 else "0"
        return sign + String(s[byte=0:1]) + "." + tail + "E" + String(point - 1)
    if point <= 0:
        return sign + "0." + "0" * -point + s
    if point >= n:
        return sign + s + "0" * (point - n) + ".0"
    return sign + String(s[byte=0:point]) + "." + String(s[byte=point:])


# Port of `Double.toString(double)` (JDK 19+, Raffaello Giulietti's): of the decimals that round
# to the value, those of the shortest length (but 1 or 2 when that is 1), the closest, the even
# one on a tie. Exact arithmetic: the value and the bounds of the decimals that round to it.
def format_double(value: Float64) raises -> String:
    var bits = bitcast[DType.uint64](value)
    var sign = "-" if bits >> 63 == 1 else ""
    var e = Int((bits >> 52) & 0x7FF)
    var m = bits & ((UInt64(1) << 52) - 1)
    if e == 0x7FF:
        return "NaN" if m != 0 else sign + "Infinity"
    if e == 0 and m == 0:
        return sign + "0.0"
    var c = m | (UInt64(1) << 52) if e > 0 else m
    var q = max(e, 1) - 1075
    var b = 1 if m == 0 and e > 1 else 0
    var x = _exact(c, q)
    var lo = _exact((c << UInt64(b + 1)) - 1, q - 1 - b)
    var hi = _exact(2 * c + 1, q - 1)
    var edge = 1 if c % 2 == 0 else 0
    for p in range(2, 18):
        var cut = String(x[0][byte = 0 : min(p, x[0].byte_length())])
        var rest = String(x[0][byte = cut.byte_length() :])
        var t = Int(atol(cut))
        var scale = x[1] - cut.byte_length()
        var up = 1 if rest > "5" or (rest == "5" and t % 2 == 1) else 0
        for k in [up, 1 - up]:
            var s = String(t + k)
            var d = (String(s.rstrip("0")), s.byte_length() + scale)
            if _cmp(lo, d) < edge and _cmp(d, hi) < edge:
                return _render(sign, t + k, scale)
    return _render(sign, Int(atol(x[0])), x[1] - x[0].byte_length())


# Port of `URLEncoder.encode(String, UTF_8)`.
def url_encode(text: String) raises -> String:
    var keep = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-*_"
    var out = String()
    for b in text.as_bytes():
        var c = Int(b)
        if c < 0x80 and keep.find(chr(c).upper()) >= 0:
            out += chr(c)
        elif c == 0x20:
            out += "+"
        else:
            out += "%" + String(hex(c + 256)[byte=3:]).upper()
    return out


# Port of `Base64.getEncoder().encodeToString(text.getBytes(UTF_8))`.
def base64(text: String) raises -> String:
    return b64encode(text)


def _upper_apart(cp: Int) raises -> String:
    # Where Java 25's upper case differs from Mojo's tables (checked on every code point): Greek
    # with ypogegrammeni, which Java spells out with capital iota, and letters new in Unicode 16.
    if cp >= 0x1F80 and cp <= 0x1FAF:
        var base = [0x1F08, 0x1F28, 0x1F68][(cp - 0x1F80) >> 4]
        return chr(base + (cp & 7)) + chr(0x399)
    if cp >= 0x10D70 and cp <= 0x10D85:
        return chr(cp - 0x20)
    if cp < 0x19B or (cp > 0x1FFC and cp < 0xA7CD) or cp > 0xA7DB:
        return ""
    var table = "|19b:a7dc|264:a7cb|1c8a:1c89|a7cd:a7cc|a7db:a7da|1fb2:1fba,399|1fb3:391,399|1fb4:386,399|1fb7:391,342,399|1fbc:391,399|1fc2:1fca,399|1fc3:397,399|1fc4:389,399|1fc7:397,342,399|1fcc:397,399|1ff2:1ffa,399|1ff3:3a9,399|1ff4:38f,399|1ff7:3a9,342,399|1ffc:3a9,399|"
    var at = table.find("|" + String(hex(cp)[byte=2:]) + ":")
    if at < 0:
        return ""
    var start = table.find(":", at) + 1
    var out = String()
    for h in table[byte = start : table.find("|", start)].split(","):
        out += chr(Int(atol(h, base=16)))
    return out


# Port of `String.toUpperCase(Locale.ROOT)`, which maps each code point on its own: Mojo's
# `upper()` (the full case, `ß` to `SS`) but where `_upper_apart` says otherwise.
def upper(text: String) raises -> String:
    var out = String()
    var start = 0
    var pos = 0
    for c in text.codepoints():
        var apart = _upper_apart(Int(c.to_u32()))
        var n = c.utf8_byte_length()
        if apart != "":
            out += String(text[byte=start:pos]).upper() + apart
            start = pos + n
        pos += n
    return out + String(text[byte=start:]).upper()
