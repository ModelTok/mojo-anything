# Written files of raw floats, compared value by value (port of
# `float_width`, `floats` and `compare_floats` in src/app.rs), with Rust's
# `{}` and `{:e}` of f64 for the detail the report shows. The bytes are read
# into floats by Python's `struct` (exact for f32 and f64); the comparison and
# every text are here.

from std.python import PythonObject
from std.utils.numerics import isinf, isnan

from mojo_anything.app.py import py_len
from mojo_anything.js_number import shortest, _zeros
from mojo_anything.tolerance import near

comptime _MIN_POSITIVE = 2.2250738585072014e-308
"""`f64::MIN_POSITIVE`."""


def float_width(format: String) raises -> Int:
    """Bytes per value of a float file format, or the Rust tool's error."""
    if format == "f32le":
        return 4
    if format == "f64le":
        return 8
    raise Error("float file format `" + format + "`: use f32le or f64le")


def rust_display(x: Float64) -> String:
    """`format!("{x}")`: the shortest digits that read back, never an
    exponent (`1e21` is `1000000000000000000000`), `-0`, `NaN`, `inf`."""
    if isnan(x):
        return "NaN"
    if isinf(x):
        return "inf" if x > 0 else "-inf"
    var d = shortest(x)
    var out = String("-") if d.negative else String("")
    if d.digits == "0":
        return out + "0"
    var k = d.digits.byte_length()
    var n = d.point
    if n >= k:
        return out + d.digits + _zeros(n - k)
    if n > 0:
        return (
            out + String(d.digits[byte=0:n]) + "." + String(d.digits[byte=n:])
        )
    return out + "0." + _zeros(-n) + d.digits


def rust_lower_exp(x: Float64) -> String:
    """`format!("{x:e}")`: `1.5e-7`, `1e0`, `0e0`, `NaN`, `inf`."""
    if isnan(x):
        return "NaN"
    if isinf(x):
        return "inf" if x > 0 else "-inf"
    var d = shortest(x)
    var out = String("-") if d.negative else String("")
    if d.digits == "0":
        return out + "0e0"
    out += String(d.digits[byte=0:1])
    if d.digits.byte_length() > 1:
        out += "." + String(d.digits[byte=1:])
    return out + "e" + String(d.point - 1)


def _rust_max(a: Float64, b: Float64) -> Float64:
    """`f64::max`: a NaN gives the other value."""
    if isnan(a):
        return b
    if isnan(b):
        return a
    return a if a >= b else b


def compare_floats(
    h: PythonObject,
    expected: PythonObject,
    actual: PythonObject,
    width: Int,
    tol: Optional[Float64],
) raises -> Optional[String]:
    """None when every value matches (equal, both NaN or within `tol`), else
    the detail the report shows."""
    var el = Int(py=h["length"](expected))
    var al = Int(py=h["length"](actual))
    if el % width != 0 or el != al:
        return String(
            el // width,
            " values expected, ",
            al,
            " bytes got (",
            width,
            " bytes per value)\n",
        )
    # The same bytes give the same values: equal, or both NaN.
    if Bool(py=h["same_bytes"](expected, actual)):
        return None
    var e = h["unpack_floats"](expected, width)
    var a = h["unpack_floats"](actual, width)
    var t = tol.value() if tol else 0.0
    var n = py_len(e)
    var off = 0
    var first = -1
    var first_e = 0.0
    var first_a = 0.0
    var max_abs = 0.0
    var max_rel = 0.0
    for i in range(n):
        var x = Float64(py=e[i])
        var y = Float64(py=a[i])
        if x == y or (isnan(x) and isnan(y)) or near(x, y, t):
            continue
        off += 1
        if first < 0:
            first = i
            first_e = x
            first_a = y
        var d = abs(x - y)
        max_abs = _rust_max(max_abs, d)
        max_rel = _rust_max(
            max_rel, d / _rust_max(_rust_max(abs(x), abs(y)), _MIN_POSITIVE)
        )
    if first < 0:
        return None
    return String(
        off,
        " of ",
        n,
        " values differ beyond the tolerance (",
        rust_display(t),
        "); first at index ",
        first,
        ": ",
        rust_display(first_e),
        " expected, ",
        rust_display(first_a),
        " got; max abs diff ",
        rust_lower_exp(max_abs),
        ", max rel diff ",
        rust_lower_exp(max_rel),
        "\n",
    )
