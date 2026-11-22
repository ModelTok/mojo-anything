# The Mojo port of tests/fixtures/mini's `packages/a/src/util.ts` (`tests/loop.rs`): JS string
# offsets count UTF-16 code units, so the text is read as code units.

from emberjson import Array, Object
from json import JsonValue


def _units(s: String) -> List[UInt16]:
    """`s` as JS sees it: UTF-16 code units."""
    var out = List[UInt16]()
    for cp in s.codepoints():
        var c = Int(cp.to_u32())
        if c >= 0x10000:
            c -= 0x10000
            out.append(UInt16(0xD800 + (c >> 10)))
            out.append(UInt16(0xDC00 + (c & 0x3FF)))
        else:
            out.append(UInt16(c))
    return out^


def _index_of(hay: List[UInt16], needle: List[UInt16]) -> Int:
    """JS `indexOf`: the first offset of `needle` in `hay`, or -1."""
    var n = len(needle)
    for i in range(len(hay) - n + 1):
        var same = True
        for k in range(n):
            if hay[i + k] != needle[k]:
                same = False
                break
        if same:
            return i
    return -1


def _string_value(u: List[UInt16], start: Int, end: Int) -> JsonValue:
    """`u[start:end]` as a JSON string, or a `$utf16` marker when it holds a lone surrogate."""
    var text = String()
    var i = start
    while i < end:
        var c = Int(u[i])
        if c >= 0xD800 and c <= 0xDBFF and i + 1 < end:
            var low = Int(u[i + 1])
            if low >= 0xDC00 and low <= 0xDFFF:
                text += chr(0x10000 + ((c - 0xD800) << 10) + (low - 0xDC00))
                i += 2
                continue
        if c >= 0xD800 and c <= 0xDFFF:
            var marker = Array()
            for k in range(start, end):
                marker.append(JsonValue(Int(u[k])))
            var o = Object()
            o["$utf16"] = JsonValue(marker^)
            return JsonValue(o^)
        text += chr(c)
        i += 1
    return JsonValue(text)


# Port of `rangeOf` (`packages/a/src/util.ts:3`).
def range_of(text: String, word: String) raises -> JsonValue:
    var t = _units(text)
    var start = _index_of(t, _units(word))
    # JS `slice` counts a negative start from the end.
    var from_ = len(t) + start if start < 0 else start
    if from_ < 0:
        from_ = 0
    var o = Object()
    o["start"] = JsonValue(start)
    o["end"] = JsonValue(start + len(_units(word)))
    o["rest"] = _string_value(t, from_, len(t))
    return JsonValue(o^)


def _word_byte(c: UInt8) -> Bool:
    """JS `\\w` without the `u` flag: ASCII letters, digits and `_`."""
    return (
        (c >= 48 and c <= 57)
        or (c >= 65 and c <= 90)
        or (c >= 97 and c <= 122)
        or c == 95
    )


# Port of `words` (`packages/a/src/util.ts:8`): every `\w+` run right after a `$`.
def words(text: String) raises -> List[String]:
    var b = text.as_bytes()
    var out = List[String]()
    var i = 1
    while i < len(b):
        if b[i - 1] == 36 and _word_byte(b[i]):
            var j = i
            while j < len(b) and _word_byte(b[j]):
                j += 1
            out.append(String(text[byte=i:j]))
            i = j
        else:
            i += 1
    return out^


# Port of `count` (`packages/a/src/util.ts:15`).
def count(text: String) raises -> Float64:
    var n = 0
    for c in text.as_bytes():
        if c == 32:
            n += 1
    return Float64(n)
