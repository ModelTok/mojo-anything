# The Mojo port of Ruby's `shellwords.rb`.
# Translated from Ruby 3.3 `lib/shellwords.rb` (BSD-2-Clause or the Ruby license).

from emberjson import Array
from json import JsonValue
from std.utils.numerics import isinf, isnan

comptime BACKSLASH = UInt8(92)
comptime SQUOTE = UInt8(39)
comptime DQUOTE = UInt8(34)


# Ruby's `\s`: ASCII whitespace.
def _is_space(c: UInt8) -> Bool:
    return c == 32 or (c >= 9 and c <= 13)


def _in(c: UInt8, chars: StaticString) -> Bool:
    return c in chars.as_bytes()


# An ASCII letter or digit.
def _alnum(c: UInt8) -> Bool:
    return ((c | 32) >= 97 and (c | 32) <= 122) or (c >= 48 and c <= 57)


# The length of the UTF-8 sequence a lead byte starts (JSON strings are valid UTF-8).
def _char_len(b: UInt8) -> Int:
    return 1 if b < 0x80 else (2 if b < 0xE0 else (3 if b < 0xF0 else 4))


# Ruby's `NoMethodError`, whose message names the receiver's class.
def _no_method(name: String, v: JsonValue) raises -> Error:
    var cls = String("Hash")
    if v.is_float():
        cls = "Float"
    elif v.is_int() or v.is_uint():
        cls = "Integer"
    elif v.is_string():
        cls = "String"
    elif v.is_array():
        cls = "Array"
    elif _symbol(v):
        cls = "Symbol"
    var who = "an instance of " + cls
    if v.is_null() or v.is_bool():
        who = _inspect(v)
    return Error("NoMethodError: undefined method `" + name + "' for " + who)


# Ruby's `Float#to_s`: shortest round-trip digits, exponent form below 1e-4 and from 1e15.
def _float_to_s(x: Float64) raises -> String:
    if isnan(x):
        return "NaN"
    if isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    # Mojo prints the shortest digits that round-trip: take them and where the point goes.
    var s = String(x)
    var negative = s.startswith("-")
    var sign = "-" if negative else ""
    var e_at = s.find("e")
    var exp = atol(s[byte = e_at + 1 :].lstrip("+")) if e_at >= 0 else 0
    var body = String(
        s[byte = 1 if negative else 0 : e_at if e_at >= 0 else s.byte_length()]
    )
    var point = body.find(".")
    var decpt = (point if point >= 0 else body.byte_length()) + exp
    var digits = body.replace(".", "")
    # Leading zeros move the point; trailing zeros are not digits.
    var lead = String(digits.lstrip("0"))
    decpt -= digits.byte_length() - lead.byte_length()
    var ds = String(lead.rstrip("0"))
    var n = ds.byte_length()
    if n == 0:
        return sign + "0.0"
    if decpt < -3 or decpt > 15:
        var e = decpt - 1
        var rest = String(ds[byte=1:]) if n > 1 else "0"
        var e_text = ("0" if abs(e) < 10 else "") + String(abs(e))
        var mantissa = String(ds[byte=0:1]) + "." + rest
        return sign + mantissa + "e" + ("-" if e < 0 else "+") + e_text
    if decpt <= 0:
        return sign + "0." + "0" * (-decpt) + ds
    if n <= decpt:
        return sign + ds + "0" * (decpt - n) + ".0"
    return sign + String(ds[byte=0:decpt]) + "." + String(ds[byte=decpt:])


# Ruby's `String#inspect` for the characters these inputs hold.
def _inspect_str(s: String) -> String:
    # The letters of the named escapes, by code: `\a` (7) to `\r` (13), and `\e` (27).
    comptime NAMED = "       abtnvfr             e"
    comptime HEX = "0123456789ABCDEF"
    var out = String('"')
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        var n = 1
        if c == DQUOTE or c == BACKSLASH:
            out += "\\" + chr(Int(c))
        elif c < 28 and NAMED.as_bytes()[Int(c)] != 32:
            out += "\\" + NAMED[byte=Int(c)]
        elif c == 35 and i + 1 < len(b) and _in(b[i + 1], "{$@"):
            # `#{`, `#$` and `#@` would interpolate: Ruby escapes the `#`.
            out += "\\#"
        elif c < 0x20 or c == 0x7F:
            out += "\\x" + HEX[byte=Int(c >> 4)] + HEX[byte=Int(c & 15)]
        else:
            n = _char_len(c)
            out += String(s[byte = i : i + n])
        i += n
    return out + '"'


# Whether `v` is a Ruby Symbol, which crosses as `{"$sym": name}`.
def _symbol(v: JsonValue) raises -> Bool:
    if not v.is_object() or len(v.object()) != 1 or "$sym" not in v.object():
        return False
    return v.object()["$sym"].is_string()


# Whether `:name` prints without quotes. Ruby takes any non-ASCII character as part of an
# identifier, and a name may end in `?`, `!` or `=`.
def _plain_symbol(name: String) -> Bool:
    var b = name.as_bytes()
    var end = len(b)
    while end > 1 and _in(b[end - 1], "?!="):
        end -= 1
    for i in range(end):
        var c = b[i]
        if not (c >= 0x80 or c == 95 or (_alnum(c) and (i > 0 or c > 57))):
            return False
    return len(b) > 0


def _inspect(v: JsonValue) raises -> String:
    if _symbol(v):
        var name = v.object()["$sym"].string()
        return ":" + (name if _plain_symbol(name) else _inspect_str(name))
    if v.is_string():
        return _inspect_str(v.string())
    var parts = List[String]()
    if v.is_array():
        for item in v.array():
            parts.append(_inspect(item))
        return "[" + String(", ").join(parts) + "]"
    if v.is_object():
        for kv in v.object().items():
            parts.append(_inspect_str(kv.key) + "=>" + _inspect(kv.value))
        return "{" + String(", ").join(parts) + "}"
    return "nil" if v.is_null() else _to_s(v)


# Ruby's `to_s`.
def _to_s(v: JsonValue) raises -> String:
    if _symbol(v):
        return v.object()["$sym"].string()
    if v.is_null():
        return ""
    if v.is_bool() or v.is_int() or v.is_uint():
        return String(v)  # as JSON writes them
    if v.is_float():
        return _float_to_s(v.float())
    if v.is_string():
        return v.string()
    return _inspect(v)


# Port of `shellsplit` (`shellwords.rb:91`): the scan regex, by hand. Every character the
# regex looks at is ASCII, so the bytes of other characters are copied as they are.
def shellsplit(line: JsonValue) raises -> JsonValue:
    comptime UNMATCHED = "ArgumentError: Unmatched quote: "
    if not line.is_string():
        var e = _no_method("scan", line)
        raise e^
    var text = line.string()
    var b = text.as_bytes()
    var words = Array()
    var field = String()
    var i = 0
    while True:
        while i < len(b) and _is_space(b[i]):
            i += 1
        if i >= len(b):
            break
        var c = b[i]
        if not _in(c, "\\'\""):
            var j = i
            while j < len(b) and not (_is_space(b[j]) or _in(b[j], "\\'\"")):
                j += 1
            field += String(text[byte=i:j])
            i = j
        elif c == SQUOTE:
            var end = text.find("'", i + 1)
            if end < 0:
                raise Error(UNMATCHED + _inspect_str(text))
            field += String(text[byte = i + 1 : end])
            i = end + 1
        elif c == DQUOTE:
            # `"((?:[^\"\\]|\\.)*)"`, then `gsub(/\\([$`"\\\n])/, '\1')`: any other escape
            # stays, backslash and all.
            var j = i + 1
            var from_ = j
            while j < len(b) and b[j] != DQUOTE:
                var pair = b[j] == BACKSLASH and j + 1 < len(b)
                if pair and _in(b[j + 1], '$`"\\\n'):
                    field += String(text[byte=from_:j])
                    from_ = j + 1
                j += 2 if pair else 1
            if j >= len(b):
                raise Error(UNMATCHED + _inspect_str(text))
            field += String(text[byte=from_:j])
            i = j + 1
        else:
            # A backslash: `\\.?` with /m, then `gsub(/\\(.)/, '\1')`, whose `.` skips
            # newlines.
            var n = _char_len(b[i + 1]) if i + 1 < len(b) else 0
            var keep = 1 if n == 0 or b[i + 1] == 10 else 0
            field += String(text[byte = i + 1 - keep : i + 1 + n])
            i += 1 + n
        # `(\s|\z)?`: one separator, or the end, closes the field.
        if i >= len(b) or _is_space(b[i]):
            i += 1
            words.append(JsonValue(field))
            field = String()
    return JsonValue(words^)


def _escape(text: String) -> String:
    if text.byte_length() == 0:
        return "''"
    var out = String()
    var b = text.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        var n = _char_len(c)
        if c == 10:
            out += "'\n'"
        elif _alnum(c) or _in(c, "_-.,:+/@"):
            out += String(text[byte = i : i + n])
        else:
            out += "\\" + String(text[byte = i : i + n])
        i += n
    return out


# Port of `shellescape` (`shellwords.rb:135`).
def shellescape(str: JsonValue) raises -> JsonValue:
    return JsonValue(_escape(_to_s(str)))


# Port of `shelljoin` (`shellwords.rb:167`).
def shelljoin(array: JsonValue) raises -> JsonValue:
    var parts = List[String]()
    if array.is_array():
        for item in array.array():
            parts.append(_escape(_to_s(item)))
    elif array.is_object() and not _symbol(array):
        # `Hash#map` yields `[key, value]` pairs, whose `to_s` is their `inspect`.
        for kv in array.object().items():
            var key = _inspect_str(kv.key)
            parts.append(_escape("[" + key + ", " + _inspect(kv.value) + "]"))
    else:
        var e = _no_method("map", array)
        raise e^
    return JsonValue(String(" ").join(parts))
