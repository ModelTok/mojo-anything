# The Mojo port of Ruby's `shellwords.rb`.
# Translated from Ruby 3.3 `lib/shellwords.rb` (BSD-2-Clause or the Ruby license).

from emberjson import Array
from json import JsonValue
from std.utils.numerics import isinf, isnan

comptime BACKSLASH = UInt8(92)
comptime SQUOTE = UInt8(39)
comptime DQUOTE = UInt8(34)


def _is_space(c: UInt8) -> Bool:
    """Ruby's `\\s`: ASCII whitespace."""
    return c == 32 or (c >= 9 and c <= 13)


def _char_len(b: UInt8) -> Int:
    """The length of the UTF-8 sequence a lead byte starts (JSON strings are valid UTF-8).
    """
    if b < 0x80:
        return 1
    if b < 0xE0:
        return 2
    if b < 0xF0:
        return 3
    return 4


def _ruby_class(v: JsonValue) raises -> String:
    """Ruby's class name of a JSON-shaped value, as `NoMethodError` messages print it.
    """
    if v.is_null():
        return "nil"
    if v.is_bool():
        return "true" if v.bool() else "false"
    if v.is_float():
        return "an instance of Float"
    if v.is_int() or v.is_uint():
        return "an instance of Integer"
    if v.is_string():
        return "an instance of String"
    if v.is_array():
        return "an instance of Array"
    if _symbol(v):
        return "an instance of Symbol"
    return "an instance of Hash"


def _no_method(name: String, v: JsonValue) raises -> Error:
    return Error(
        "NoMethodError: undefined method `" + name + "' for " + _ruby_class(v)
    )


def _float_to_s(x: Float64) -> String:
    """Ruby's `Float#to_s`: shortest round-trip digits, exponent form below 1e-4 and from 1e15.
    """
    if isnan(x):
        return "NaN"
    if isinf(x):
        return "Infinity" if x > 0 else "-Infinity"
    # Mojo prints the shortest digits that round-trip; take them and the decimal point.
    var s = String(x)
    var b = s.as_bytes()
    var negative = len(b) > 0 and b[0] == 45
    var digits = String()
    var decpt = 0
    var seen_point = False
    var exp = 0
    var exp_neg = False
    var in_exp = False
    var i = 1 if negative else 0
    while i < len(b):
        var c = b[i]
        if in_exp:
            if c == 45:
                exp_neg = True
            elif c >= 48 and c <= 57:
                exp = exp * 10 + Int(c - 48)
        elif c == 101:
            in_exp = True
        elif c == 46:
            seen_point = True
        else:
            digits += String(s[byte = i : i + 1])
            if not seen_point:
                decpt += 1
        i += 1
    decpt += -exp if exp_neg else exp
    # Leading zeros move the point; trailing zeros are not digits.
    var d = digits.as_bytes()
    var start = 0
    while start < len(d) and d[start] == 48:
        start += 1
        decpt -= 1
    var end = len(d)
    while end > start and d[end - 1] == 48:
        end -= 1
    var sign = "-" if negative else ""
    if start == end:
        return sign + "0.0"
    var ds = String(digits[byte=start:end])
    var n = end - start
    if decpt < -3 or decpt > 15:
        var e = decpt - 1
        var rest = String(ds[byte=1:n]) if n > 1 else "0"
        var e_abs = -e if e < 0 else e
        var e_text = String(e_abs)
        if e_abs < 10:
            e_text = "0" + e_text
        return (
            sign
            + String(ds[byte=0:1])
            + "."
            + rest
            + "e"
            + ("-" if e < 0 else "+")
            + e_text
        )
    if decpt <= 0:
        return sign + "0." + "0" * (-decpt) + ds
    if n <= decpt:
        return sign + ds + "0" * (decpt - n) + ".0"
    return sign + String(ds[byte=0:decpt]) + "." + String(ds[byte=decpt:n])


def _inspect_str(s: String) -> String:
    """Ruby's `String#inspect` for the characters these inputs hold."""
    var out = String('"')
    var b = s.as_bytes()
    var i = 0
    while i < len(b):
        var c = b[i]
        if c == DQUOTE:
            out += '\\"'
        elif c == BACKSLASH:
            out += "\\\\"
        elif c == 10:
            out += "\\n"
        elif c == 9:
            out += "\\t"
        elif c == 13:
            out += "\\r"
        elif c == 12:
            out += "\\f"
        elif c == 11:
            out += "\\v"
        elif c == 7:
            out += "\\a"
        elif c == 8:
            out += "\\b"
        elif c == 27:
            out += "\\e"
        elif (
            c == 35
            and i + 1 < len(b)
            and (b[i + 1] == 123 or b[i + 1] == 36 or b[i + 1] == 64)
        ):
            # `#{`, `#$` and `#@` would interpolate: Ruby escapes the `#`.
            out += "\\#"
        elif c < 0x20 or c == 0x7F:
            comptime HEX = "0123456789ABCDEF"
            out += "\\x" + HEX[byte=Int(c >> 4)] + HEX[byte=Int(c & 15)]
        else:
            var n = _char_len(c)
            out += String(s[byte = i : i + n])
            i += n
            continue
        i += 1
    return out + '"'


def _symbol(v: JsonValue) raises -> Bool:
    """Whether `v` is a Ruby Symbol, which crosses as `{"$sym": name}`."""
    if not v.is_object() or len(v.object()) != 1 or "$sym" not in v.object():
        return False
    return v.object()["$sym"].is_string()


def _plain_symbol(name: String) -> Bool:
    """Whether `:name` prints without quotes."""
    var b = name.as_bytes()
    if len(b) == 0:
        return False
    var end = len(b)
    while end > 1 and (
        b[end - 1] == 63 or b[end - 1] == 33 or b[end - 1] == 61
    ):
        end -= 1
    for i in range(end):
        var c = b[i]
        var letter = (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95
        var digit = c >= 48 and c <= 57
        # Ruby takes any non-ASCII character as part of an identifier.
        if not (letter or c >= 0x80 or (digit and i > 0)):
            return False
    return True


def _inspect(v: JsonValue) raises -> String:
    if _symbol(v):
        var name = v.object()["$sym"].string()
        if _plain_symbol(name):
            return ":" + name
        return ":" + _inspect_str(name)
    if v.is_string():
        return _inspect_str(v.string())
    if v.is_array():
        var out = String("[")
        var first = True
        for item in v.array():
            if not first:
                out += ", "
            first = False
            out += _inspect(item)
        return out + "]"
    if v.is_object():
        if len(v.object()) == 0:
            return "{}"
        var out = String("{")
        var first = True
        for kv in v.object().items():
            if not first:
                out += ", "
            first = False
            out += _inspect_str(kv.key) + "=>" + _inspect(kv.value)
        return out + "}"
    if v.is_null():
        return "nil"
    return _to_s(v)


def _to_s(v: JsonValue) raises -> String:
    """Ruby's `to_s`."""
    if _symbol(v):
        return v.object()["$sym"].string()
    if v.is_null():
        return ""
    if v.is_bool():
        return "true" if v.bool() else "false"
    if v.is_int():
        return String(v.int())
    if v.is_uint():
        return String(v.uint())
    if v.is_float():
        return _float_to_s(v.float())
    if v.is_string():
        return v.string()
    return _inspect(v)


def _closing_quote(b: Span[UInt8, _], start: Int) -> Int:
    """The index of the `"` closing a double-quoted string that starts at `start`, or -1.
    """
    var j = start
    while j < len(b):
        if b[j] == DQUOTE:
            return j
        if b[j] == BACKSLASH:
            if j + 1 >= len(b):
                return -1
            j += 2
        else:
            j += 1
    return -1


def _next_squote(b: Span[UInt8, _], start: Int) -> Int:
    for j in range(start, len(b)):
        if b[j] == SQUOTE:
            return j
    return -1


# Port of `shellsplit` (`shellwords.rb:91`): the scan regex, by hand. Every character the
# regex looks at is ASCII, so the bytes of other characters are copied as they are.
def shellsplit(line: JsonValue) raises -> JsonValue:
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
        if c != BACKSLASH and c != SQUOTE and c != DQUOTE:
            var j = i
            while (
                j < len(b)
                and b[j] != BACKSLASH
                and b[j] != SQUOTE
                and b[j] != DQUOTE
                and not _is_space(b[j])
            ):
                j += 1
            field += String(text[byte=i:j])
            i = j
        elif c == SQUOTE and _next_squote(b, i + 1) >= 0:
            var end = _next_squote(b, i + 1)
            field += String(text[byte = i + 1 : end])
            i = end + 1
        elif c == DQUOTE and _closing_quote(b, i + 1) >= 0:
            var end = _closing_quote(b, i + 1)
            var j = i + 1
            var from_ = j
            while j < end:
                if b[j] == BACKSLASH and j + 1 < end:
                    var n = b[j + 1]
                    if (
                        n == 36
                        or n == 96
                        or n == DQUOTE
                        or n == BACKSLASH
                        or n == 10
                    ):
                        field += String(text[byte=from_:j])
                        from_ = j + 1
                        j += 2
                        continue
                    # Any other escape stays, backslash and all; skip the pair as Ruby does.
                    j += 2
                    continue
                j += 1
            field += String(text[byte=from_:end])
            i = end + 1
        elif c == BACKSLASH:
            # `\\.?` with /m, then `gsub(/\\(.)/, '\1')`, whose `.` skips newlines.
            if i + 1 >= len(b):
                field += "\\"
                i += 1
            elif b[i + 1] == 10:
                field += "\\\n"
                i += 2
            else:
                var n = _char_len(b[i + 1])
                field += String(text[byte = i + 1 : i + 1 + n])
                i += 1 + n
        else:
            raise Error("ArgumentError: Unmatched quote: " + _inspect_str(text))
        # `(\s|\z)?`: one separator, or the end, closes the field.
        if i >= len(b) or _is_space(b[i]):
            if i < len(b):
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
        elif (
            (c >= 48 and c <= 57)
            or (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or c == 95
            or c == 45
            or c == 46
            or c == 44
            or c == 58
            or c == 43
            or c == 47
            or c == 64
        ):
            out += String(text[byte = i : i + 1])
        else:
            out += "\\" + String(text[byte = i : i + n])
        i += n
    return out


# Port of `shellescape` (`shellwords.rb:135`).
def shellescape(str: JsonValue) raises -> JsonValue:
    return JsonValue(_escape(_to_s(str)))


# Port of `shelljoin` (`shellwords.rb:167`).
def shelljoin(array: JsonValue) raises -> JsonValue:
    var out = String()
    var first = True
    if array.is_array():
        for item in array.array():
            if not first:
                out += " "
            first = False
            out += _escape(_to_s(item))
    elif array.is_object() and not _symbol(array):
        # `Hash#map` yields `[key, value]` pairs.
        for kv in array.object().items():
            var pair = Array()
            pair.append(JsonValue(kv.key))
            pair.append(kv.value.copy())
            if not first:
                out += " "
            first = False
            out += _escape(_to_s(JsonValue(pair^)))
    else:
        var e = _no_method("map", array)
        raise e^
    return JsonValue(out)
