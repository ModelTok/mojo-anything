# The Mojo port of vercel/ms `src/index.ts` (commit 4ff48ce).
#
# Every parameter is a `JsonValue`: the original checks its arguments' types at run time and
# throws its own errors, so the port reads the value the caller passed and does the same.

from std.math import floor

from json import JsonValue, as_float, json_float

comptime S = 1000.0
comptime M = S * 60.0
comptime H = M * 60.0
comptime D = H * 24.0
comptime W = D * 7.0
comptime Y = D * 365.25
comptime MO = Y / 12.0

comptime PARSE_ERROR = (
    "Value provided to ms.parse() must be a string with length between 1 and"
    " 99. value="
)
comptime FORMAT_ERROR = "Value provided to ms.format() must be of type number."


# Port of `ms` (`src/index.ts:50`).
def ms(value: JsonValue, options: Optional[JsonValue]) raises -> JsonValue:
    if value.is_string():
        return json_float(parse(value))
    if _is_number(value):
        return JsonValue(format(value, options))
    var e = Error(
        "Value provided to ms() must be a string or number. value="
        + _stringify(value)
    )
    raise e^


# Port of `parse` (`src/index.ts:71`).
def parse(str: JsonValue) raises -> Float64:
    if not str.is_string():
        var e = Error(PARSE_ERROR + _stringify(str))
        raise e^
    var text = str.string()
    var units = _utf16_length(text)
    if units == 0 or units > 100:
        var e = Error(PARSE_ERROR + _stringify(str))
        raise e^
    return _parse_text(text)


# Port of `parseStrict` (`src/index.ts:156`).
def parse_strict(value: JsonValue) raises -> Float64:
    return parse(value)


# Port of `format` (`src/index.ts:225`).
def format(ms: JsonValue, options: Optional[JsonValue]) raises -> String:
    if not _is_number(ms):
        var e = Error(FORMAT_ERROR)
        raise e^
    var n = as_float(ms)
    if n != n or n - n != 0.0:
        var e = Error(FORMAT_ERROR)
        raise e^
    if _is_long(options):
        return _fmt_long(n)
    return _fmt_short(n)


def _parse_text(text: String) -> Float64:
    """The original's regex: `-?`, digits, `.` digits, spaces, a unit, all ASCII.
    """
    var b = text.as_bytes()
    var size = len(b)
    var i = 0
    if size > 0 and b[0] == 45:
        i = 1
    var whole = 0
    while i + whole < size and _digit(b[i + whole]):
        whole += 1
    i += whole
    if i < size and b[i] == 46:
        var fraction = 0
        while i + 1 + fraction < size and _digit(b[i + 1 + fraction]):
            fraction += 1
        if fraction == 0:
            return _nan()
        i += 1 + fraction
    elif whole == 0:
        return _nan()
    var number = String(text[byte=0:i])
    while i < size and b[i] == 32:
        i += 1
    var unit = String()
    for j in range(i, size):
        var c = b[j]
        if c >= 65 and c <= 90:
            c += 32
        if c < 97 or c > 122:
            return _nan()
        unit += chr(Int(c))
    var n: Float64
    try:
        n = atof(number)
    except:
        return _nan()
    if (
        unit == "years"
        or unit == "year"
        or unit == "yrs"
        or unit == "yr"
        or unit == "y"
    ):
        return n * Y
    if unit == "months" or unit == "month" or unit == "mo":
        return n * MO
    if unit == "weeks" or unit == "week" or unit == "w":
        return n * W
    if unit == "days" or unit == "day" or unit == "d":
        return n * D
    if (
        unit == "hours"
        or unit == "hour"
        or unit == "hrs"
        or unit == "hr"
        or unit == "h"
    ):
        return n * H
    if (
        unit == "minutes"
        or unit == "minute"
        or unit == "mins"
        or unit == "min"
        or unit == "m"
    ):
        return n * M
    if (
        unit == "seconds"
        or unit == "second"
        or unit == "secs"
        or unit == "sec"
        or unit == "s"
    ):
        return n * S
    if (
        unit == ""
        or unit == "milliseconds"
        or unit == "millisecond"
        or unit == "msecs"
        or unit == "msec"
        or unit == "ms"
    ):
        return n
    return _nan()


def _nan() -> Float64:
    return Float64(0.0) / Float64(0.0)


def _digit(c: UInt8) -> Bool:
    return c >= 48 and c <= 57


def _utf16_length(text: String) -> Int:
    var n = 0
    for c in text.codepoints():
        n += 2 if c.to_u32() > 0xFFFF else 1
    return n


def _is_number(v: JsonValue) -> Bool:
    if v.is_int() or v.is_uint() or v.is_float():
        return True
    return v.is_object() and len(v.object()) == 1 and "$num" in v.object()


def _is_marker(v: JsonValue) -> Bool:
    if not v.is_object() or len(v.object()) != 1:
        return False
    for kv in v.object().items():
        return kv.key.startswith("$")
    return False


def _is_long(options: Optional[JsonValue]) raises -> Bool:
    """`options?.long`, truthy as JS sees it."""
    if not options:
        return False
    ref o = options.value()
    if not o.is_object() or _is_marker(o) or "long" not in o.object():
        return False
    return _truthy(o.object()["long"])


def _truthy(v: JsonValue) raises -> Bool:
    if v.is_null():
        return False
    if v.is_bool():
        return v.bool()
    if v.is_string():
        return v.string().byte_length() > 0
    if _is_number(v):
        var n = as_float(v)
        return n == n and n != 0.0
    if v.is_object() and "$undefined" in v.object():
        return False
    return True


def _round(x: Float64) -> Float64:
    """JS `Math.round`: halves go up."""
    var r = floor(x)
    if x - r >= 0.5:
        return r + 1.0
    return r


def _fmt_short(ms: Float64) -> String:
    var a = abs(ms)
    if a >= Y:
        return _js_number(_round(ms / Y)) + "y"
    if a >= MO:
        return _js_number(_round(ms / MO)) + "mo"
    if a >= W:
        return _js_number(_round(ms / W)) + "w"
    if a >= D:
        return _js_number(_round(ms / D)) + "d"
    if a >= H:
        return _js_number(_round(ms / H)) + "h"
    if a >= M:
        return _js_number(_round(ms / M)) + "m"
    if a >= S:
        return _js_number(_round(ms / S)) + "s"
    return _js_number(ms) + "ms"


def _plural(ms: Float64, a: Float64, n: Float64, name: String) -> String:
    var s = "s" if a >= n * 1.5 else ""
    return _js_number(_round(ms / n)) + " " + name + s


def _fmt_long(ms: Float64) -> String:
    var a = abs(ms)
    if a >= Y:
        return _plural(ms, a, Y, "year")
    if a >= MO:
        return _plural(ms, a, MO, "month")
    if a >= W:
        return _plural(ms, a, W, "week")
    if a >= D:
        return _plural(ms, a, D, "day")
    if a >= H:
        return _plural(ms, a, H, "hour")
    if a >= M:
        return _plural(ms, a, M, "minute")
    if a >= S:
        return _plural(ms, a, S, "second")
    return _js_number(ms) + " ms"


def _js_number(x: Float64) -> String:
    """JS `Number.prototype.toString()` of a finite number, from the shortest digits.
    """
    if x == 0.0:
        return "0"
    if x < 0.0:
        return "-" + _js_number(-x)
    var text = String(x)
    var b = text.as_bytes()
    var digits = String()
    var point = -1
    var exponent = 0
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == 101 or c == 69:
            var sign = 1
            var j = i + 1
            if j < len(b) and (b[j] == 43 or b[j] == 45):
                sign = -1 if b[j] == 45 else 1
                j += 1
            var e = 0
            while j < len(b):
                e = e * 10 + Int(b[j]) - 48
                j += 1
            exponent = sign * e
            break
        if c == 46:
            point = digits.byte_length()
        else:
            digits += chr(Int(c))
        i += 1
    if point < 0:
        point = digits.byte_length()
    var n = point + exponent
    # Leading and trailing zeros carry no digits.
    var d = digits.as_bytes()
    var start = 0
    while start < len(d) - 1 and d[start] == 48:
        start += 1
        n -= 1
    var end = len(d)
    while end > start + 1 and d[end - 1] == 48:
        end -= 1
    var s = String(digits[byte=start:end])
    var k = end - start
    if k <= n and n <= 21:
        return s + "0" * (n - k)
    if 0 < n and n <= 21:
        return String(s[byte=0:n]) + "." + String(s[byte=n:k])
    if -6 < n and n <= 0:
        return "0." + "0" * (-n) + s
    var e = n - 1
    var tail = ("e+" if e >= 0 else "e-") + String(abs(e))
    if k == 1:
        return s + tail
    return String(s[byte=0:1]) + "." + String(s[byte=1:k]) + tail


def _quote(s: String) -> String:
    """`JSON.stringify` of a string."""
    var out = String('"')
    for c in s.codepoints():
        var u = c.to_u32()
        if u == 34:
            out += '\\"'
        elif u == 92:
            out += "\\\\"
        elif u == 8:
            out += "\\b"
        elif u == 12:
            out += "\\f"
        elif u == 10:
            out += "\\n"
        elif u == 13:
            out += "\\r"
        elif u == 9:
            out += "\\t"
        elif u < 32:
            out += "\\u00" + ("0" if u < 16 else "1") + _HEX[byte=Int(u % 16)]
        else:
            out += chr(Int(u))
    return out + '"'


comptime _HEX = "0123456789abcdef"


def _stringify(v: JsonValue) raises -> String:
    """`JSON.stringify(v)`, with `undefined` for the `$undefined` marker."""
    if v.is_null():
        return "null"
    if v.is_bool():
        return "true" if v.bool() else "false"
    if v.is_string():
        return _quote(v.string())
    if v.is_int():
        return String(v.int())
    if v.is_uint():
        return String(v.uint())
    if _is_number(v):
        var n = as_float(v)
        if n != n or n - n != 0.0:
            return "null"
        return _js_number(n)
    if v.is_array():
        var out = String("[")
        var first = True
        for item in v.array():
            if not first:
                out += ","
            first = False
            var text = _stringify(item)
            out += "null" if text == "undefined" else text
        return out + "]"
    if "$undefined" in v.object() and len(v.object()) == 1:
        return "undefined"
    var out = String("{")
    var first = True
    for kv in v.object().items():
        var text = _stringify(kv.value)
        if text == "undefined":
            continue
        if not first:
            out += ","
        first = False
        out += _quote(kv.key) + ":" + text
    return out + "}"
