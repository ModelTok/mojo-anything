# The `key-order` normalizer (port of `sort_value` and `sort_json_text` in
# src/app.rs) and `str::trim` as Rust's `char::is_whitespace` reads it. A
# text that is JSON as a whole becomes serde_json's pretty print of it with
# every object's keys sorted; otherwise each line that is JSON becomes its
# compact print. Python's json reads the text in serde_json's place
# (`canon_json` in py.mojo); a text it might read otherwise is declined.

from std.python import PythonObject

from mojo_anything.app.cases import decline
from mojo_anything.app.py import py_len
from mojo_anything.js_number import json_number_to_string
from mojo_anything.json_text import write_string


def _ws_len(b: Span[UInt8, _], i: Int) -> Int:
    """The length of the White_Space character (`char::is_whitespace`) that
    starts at byte `i`, or 0."""
    var n = len(b)
    var c = Int(b[i])
    if c == 9 or c == 10 or c == 11 or c == 12 or c == 13 or c == 32:
        return 1
    if c == 0xC2 and i + 1 < n:
        var c1 = Int(b[i + 1])
        if c1 == 0x85 or c1 == 0xA0:
            return 2
    if i + 2 < n:
        var c1 = Int(b[i + 1])
        var c2 = Int(b[i + 2])
        if c == 0xE1 and c1 == 0x9A and c2 == 0x80:
            return 3
        if c == 0xE2 and c1 == 0x80:
            if (c2 >= 0x80 and c2 <= 0x8A) or c2 == 0xA8 or c2 == 0xA9:
                return 3
            if c2 == 0xAF:
                return 3
        if c == 0xE2 and c1 == 0x81 and c2 == 0x9F:
            return 3
        if c == 0xE3 and c1 == 0x80 and c2 == 0x80:
            return 3
    return 0


def _char_len(c: UInt8) -> Int:
    if c < 0x80:
        return 1
    if c < 0xE0:
        return 2
    if c < 0xF0:
        return 3
    return 4


def _trim(s: String) -> String:
    """`str::trim`."""
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    var start = -1
    var end = 0
    while i < n:
        var w = _ws_len(b, i)
        if w > 0:
            i += w
            continue
        if start < 0:
            start = i
        i += _char_len(b[i])
        end = i
    if start < 0:
        return ""
    return String(s[byte=start:end])


def _emit(node: PythonObject, pretty: Bool, indent: String) raises -> String:
    """serde_json's `to_string_pretty` (two spaces, `"key": value`) or
    `to_string` of a `canon_json` tree."""
    var kind = String(py=node[0])
    if kind == "o" or kind == "a":
        var items = node[1]
        var n = py_len(items)
        var open = String("{") if kind == "o" else String("[")
        var close = String("}") if kind == "o" else String("]")
        if n == 0:
            return open + close
        var inner = indent + "  "
        var out = open
        if pretty:
            out += "\n"
        for i in range(n):
            if i > 0:
                out += String(",\n") if pretty else String(",")
            if pretty:
                out += inner
            if kind == "o":
                out += write_string(String(py=items[i][0]))
                out += String(": ") if pretty else String(":")
                out += _emit(items[i][1], pretty, inner)
            else:
                out += _emit(items[i], pretty, inner)
        if pretty:
            out += "\n" + indent
        return out + close
    if kind == "s":
        return write_string(String(py=node[1]))
    if kind == "i":
        return String(py=node[1])
    if kind == "f":
        return json_number_to_string(Float64(py=node[1]))
    if kind == "t":
        return "true"
    if kind == "F":
        return "false"
    return "null"


def _sorted_json(
    h: PythonObject, text: String, pretty: Bool
) raises -> Optional[String]:
    var r = h["canon_json"](PythonObject(text))
    var kind = String(py=r[0])
    if kind == "odd":
        raise decline()
    if kind != "ok":
        return None
    return _emit(r[1], pretty, "")


def _opens_json(t: String) -> Bool:
    return t.startswith("{") or t.startswith("[")


def sort_json_text(h: PythonObject, text: String) raises -> String:
    """`sort_json_text`: the whole text as sorted pretty JSON, else each JSON
    line as sorted compact JSON."""
    var trimmed = _trim(text)
    if _opens_json(trimmed):
        var whole = _sorted_json(h, trimmed, True)
        if whole:
            return whole.value() + "\n"
    var out = String("")
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i < len(b) and b[i] != 10:
            continue
        var line = String(text[byte=start:i])
        if start > 0:
            out += "\n"
        var t = _trim(line)
        var done = False
        if _opens_json(t):
            var one = _sorted_json(h, t, False)
            if one:
                out += one.value()
                done = True
        if not done:
            out += line
        start = i + 1
    return out
