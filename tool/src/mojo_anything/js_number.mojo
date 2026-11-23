# Numbers as JavaScript and serde_json print them (port of src/js_number.rs).
#
# Both print the shortest digits that read back as the same double, the closest
# of them on a tie. Those digits come from Python's `repr`, which is exactly
# that (David Gay's shortest round trip); Mojo's own `String(Float64)` picks
# other digits for some values (docs/mojo-notes.md). Only the layout differs
# between JS and serde_json, and it is written here.

from std.math import floor, trunc
from std.python import Python, PythonObject
from std.utils.numerics import isinf, isnan


@fieldwise_init
struct Digits(Copyable, Movable):
    """`x` = sign `0.digits` x 10^`point`, with `digits` free of leading and
    trailing zeros (`"0"` for zero)."""

    var negative: Bool
    var digits: String
    var point: Int


def shortest(x: Float64) -> Digits:
    """The shortest round-trip digits of a finite `x`."""
    var text = String("0")
    try:
        text = String(py=Python.import_module("builtins").repr(PythonObject(x)))
    except:
        pass
    var negative = text.startswith("-")
    if negative:
        var unsigned = String(text[byte=1:])
        text = unsigned^
    var exponent = 0
    var e = text.find("e")
    var mantissa = text
    if e >= 0:
        mantissa = String(text[byte=0:e])
        try:
            exponent = Int(String(text[byte = e + 1 :]).replace("+", ""))
        except:
            exponent = 0
    var dot = mantissa.find(".")
    var int_part = mantissa
    var frac = String("")
    if dot >= 0:
        int_part = String(mantissa[byte=0:dot])
        frac = String(mantissa[byte = dot + 1 :])
    var all = int_part + frac
    var bytes = all.as_bytes()
    var lead = 0
    while lead < len(bytes) and bytes[lead] == 48:
        lead += 1
    var end = len(bytes)
    while end > lead and bytes[end - 1] == 48:
        end -= 1
    if lead == end:
        return Digits(negative=negative, digits="0", point=1)
    var digits = String(all[byte=lead:end])
    var point = int_part.byte_length() - lead + exponent
    return Digits(negative=negative, digits=digits, point=point)


def _zeros(n: Int) -> String:
    var out = String("")
    for _ in range(n):
        out += "0"
    return out


def _exponent_form(d: Digits, plus: String) -> String:
    var k = d.digits.byte_length()
    var out = String(d.digits[byte=0:1])
    if k > 1:
        out += "." + String(d.digits[byte=1:])
    var e = d.point - 1
    out += "e"
    if e < 0:
        out += "-" + String(-e)
    else:
        out += plus + String(e)
    return out


def js_number_to_string(x: Float64) -> String:
    """JS `Number.prototype.toString()`: `1e+21`, `5e-324`, `0` for `-0`,
    `NaN`, `Infinity`."""
    if isnan(x):
        return "NaN"
    if isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    if x == 0.0:
        return "0"
    if x == trunc(x) and abs(x) < 9007199254740992.0:
        return String(Int(x))
    var d = shortest(x)
    var k = d.digits.byte_length()
    var n = d.point
    var out = String("-") if d.negative else String("")
    if k <= n and n <= 21:
        out += d.digits + _zeros(n - k)
    elif 0 < n and n <= 21:
        out += String(d.digits[byte=0:n]) + "." + String(d.digits[byte=n:])
    elif -6 < n and n <= 0:
        out += "0." + _zeros(-n) + d.digits
    else:
        out += _exponent_form(d, "+")
    return out


def json_number_to_string(x: Float64) -> String:
    """A float as serde_json 1.0.154 writes it: `100.0`, `1e+16`, `0.00001`,
    `1e-6`, `-0.0`; `null` for NaN and the infinities."""
    if isnan(x) or isinf(x):
        return "null"
    var d = shortest(x)
    var k = d.digits.byte_length()
    var n = d.point
    var out = String("-") if d.negative else String("")
    if d.digits == "0":
        return out + "0.0"
    if k <= n and n <= 16:
        out += d.digits + _zeros(n - k) + ".0"
    elif 0 < n and n <= 16:
        out += String(d.digits[byte=0:n]) + "." + String(d.digits[byte=n:])
    elif -5 < n and n <= 0:
        out += "0." + _zeros(-n) + d.digits
    else:
        out += _exponent_form(d, "+")
    return out


def math_round(x: Float64) -> Float64:
    """JS `Math.round`: halves toward positive infinity, `-0` for negatives
    that round to zero."""
    if isnan(x) or isinf(x) or x == trunc(x):
        return x
    var f = floor(x)
    var r = f + 1.0 if x - f >= 0.5 else f
    if r == 0.0 and x < 0.0:
        return -0.0
    return r
