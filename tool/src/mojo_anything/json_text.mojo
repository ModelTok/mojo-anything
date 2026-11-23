# JSON text as the Rust tool writes it (serde_json 1.0.154): compact and
# pretty layouts, its float digits and string escapes, and serde_json's value
# equality. Values are the JSON module's (`json.mojo`, EmberJson): object keys
# keep their order.

from emberjson import Value
from std.python import Python, PythonObject

from mojo_anything.js_number import json_number_to_string, js_number_to_string

comptime _HEX = "0123456789abcdef"


def write_string(s: String) -> String:
    """A JSON string literal, escaped as serde_json escapes."""
    var out = String('"')
    var bytes = s.as_bytes()
    var start = 0
    for i in range(len(bytes)):
        var b = bytes[i]
        var esc: String
        if b == 34:
            esc = '\\"'
        elif b == 92:
            esc = "\\\\"
        elif b == 8:
            esc = "\\b"
        elif b == 9:
            esc = "\\t"
        elif b == 10:
            esc = "\\n"
        elif b == 12:
            esc = "\\f"
        elif b == 13:
            esc = "\\r"
        elif b < 32:
            var hex = _HEX.as_bytes()
            esc = "\\u00"
            esc += String(chr(Int(hex[Int(b >> 4)])))
            esc += String(chr(Int(hex[Int(b & 15)])))
        else:
            continue
        out += String(s[byte=start:i]) + esc
        start = i + 1
    out += String(s[byte=start:]) + '"'
    return out


comptime SERDE = 0
"""serde_json's `to_string`: what the Rust tool writes itself."""
comptime PYTHON = 1
"""`json.dumps(v, ensure_ascii=False)`: the Python drivers' case files."""
comptime JS = 2
"""`JSON.stringify(v)`: the Node drivers' case files."""


def _float(x: Float64, layout: Int) -> String:
    if layout == PYTHON:
        try:
            return String(
                py=Python.import_module("builtins").repr(PythonObject(x))
            )
        except:
            pass
    if layout == JS:
        return js_number_to_string(x)
    return json_number_to_string(x)


def _scalar(v: Value, layout: Int = SERDE) -> String:
    if v.is_null():
        return "null"
    if v.is_bool():
        return "true" if v.bool() else "false"
    if v.is_int():
        return String(v.int())
    if v.is_uint():
        return String(v.uint())
    if v.is_float():
        return _float(v.float(), layout)
    return write_string(v.string())


def write_compact(v: Value, layout: Int = SERDE) -> String:
    """One line of JSON in `layout`: `SERDE` (`serde_json::to_string`),
    `PYTHON` (`, ` and `: ` between items, `repr` floats) or `JS`."""
    var item_sep = ", " if layout == PYTHON else ","
    var key_sep = ": " if layout == PYTHON else ":"
    if v.is_array():
        var out = String("[")
        var first = True
        for item in v.array():
            if not first:
                out += item_sep
            first = False
            out += write_compact(item, layout)
        return out + "]"
    if v.is_object():
        var out = String("{")
        var first = True
        for kv in v.object().items():
            if not first:
                out += item_sep
            first = False
            out += (
                write_string(kv.key) + key_sep + write_compact(kv.value, layout)
            )
        return out + "}"
    return _scalar(v, layout)


def _pretty(v: Value, indent: String) -> String:
    var inner = indent + "  "
    if v.is_array():
        if len(v.array()) == 0:
            return "[]"
        var out = String("[\n")
        var first = True
        for item in v.array():
            if not first:
                out += ",\n"
            first = False
            out += inner + _pretty(item, inner)
        return out + "\n" + indent + "]"
    if v.is_object():
        if len(v.object()) == 0:
            return "{}"
        var out = String("{\n")
        var first = True
        for kv in v.object().items():
            if not first:
                out += ",\n"
            first = False
            out += (
                inner + write_string(kv.key) + ": " + _pretty(kv.value, inner)
            )
        return out + "\n" + indent + "}"
    return _scalar(v)


def write_pretty(v: Value) -> String:
    """`serde_json::to_string_pretty`: two spaces, `"key": value`."""
    return _pretty(v, "")


def _number_kind(v: Value) -> Int:
    """serde_json's number kinds: 1 positive int, 2 negative int, 3 float."""
    if v.is_uint():
        return 1
    if v.is_int():
        return 2 if v.int() < 0 else 1
    return 3


def is_number(v: Value) -> Bool:
    return v.is_int() or v.is_uint() or v.is_float()


def number_value(v: Value) -> Float64:
    if v.is_int():
        return Float64(v.int())
    if v.is_uint():
        return Float64(v.uint())
    return v.float()


def _same_number(a: Value, b: Value) -> Bool:
    var ka = _number_kind(a)
    if ka != _number_kind(b):
        return False
    if ka == 3:
        return a.float() == b.float()
    return _scalar(a) == _scalar(b)


def json_equal(a: Value, b: Value) -> Bool:
    """serde_json's `Value` equality: numbers by kind and value (`3` is not
    `3.0`), objects as maps (key order does not matter)."""
    if is_number(a) or is_number(b):
        return is_number(a) and is_number(b) and _same_number(a, b)
    if a.is_array() or b.is_array():
        if not (a.is_array() and b.is_array()):
            return False
        ref x = a.array()
        ref y = b.array()
        if len(x) != len(y):
            return False
        for i in range(len(x)):
            if not json_equal(x[i], y[i]):
                return False
        return True
    if a.is_object() or b.is_object():
        if not (a.is_object() and b.is_object()):
            return False
        ref x = a.object()
        ref y = b.object()
        if len(x) != len(y):
            return False
        for kv in x.items():
            if kv.key not in y:
                return False
            try:
                if not json_equal(kv.value, y[kv.key]):
                    return False
            except:
                return False
        return True
    return _scalar(a) == _scalar(b)
