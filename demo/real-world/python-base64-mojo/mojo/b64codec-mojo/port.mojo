# Mojo port of what CPython 3.12's `python3 -m base64` runs: `encode` and
# `decode` from Lib/base64.py, and the binascii functions they call,
# `b2a_base64` (newline=True) and `a2b_base64` (strict_mode=False) from
# Modules/binascii.c. Bytes in, bytes out: nothing here assumes UTF-8.

comptime MAXLINESIZE = 76
comptime MAXBINSIZE = (MAXLINESIZE // 4) * 3
comptime _PAD = UInt8(61)
comptime _NEWLINE = UInt8(10)
comptime _NOT_BASE64 = UInt8(255)


def _to_char(value: UInt8) -> UInt8:
    """The base64 alphabet: A-Z, a-z, 0-9, `+`, `/`."""
    if value < 26:
        return 65 + value
    if value < 52:
        return 97 + (value - 26)
    if value < 62:
        return 48 + (value - 52)
    if value == 62:
        return 43
    return 47


def _from_char(char: UInt8) -> UInt8:
    """`table_a2b_base64`: the value of a base64 character, 255 for any other
    byte."""
    if char >= 65 and char <= 90:
        return char - 65
    if char >= 97 and char <= 122:
        return char - 97 + 26
    if char >= 48 and char <= 57:
        return char - 48 + 52
    if char == 43:
        return 62
    if char == 47:
        return 63
    return _NOT_BASE64


def b2a_base64(data: List[UInt8], start: Int, end: Int, mut out: List[UInt8]):
    """`binascii.b2a_base64(data[start:end])`: appends the encoding and a
    newline to `out`."""
    var i = start
    while i + 3 <= end:
        var a = data[i]
        var b = data[i + 1]
        var c = data[i + 2]
        out.append(_to_char(a >> 2))
        out.append(_to_char(((a & 0x03) << 4) | (b >> 4)))
        out.append(_to_char(((b & 0x0F) << 2) | (c >> 6)))
        out.append(_to_char(c & 0x3F))
        i += 3
    var left = end - i
    if left == 1:
        var a = data[i]
        out.append(_to_char(a >> 2))
        out.append(_to_char((a & 0x03) << 4))
        out.append(_PAD)
        out.append(_PAD)
    elif left == 2:
        var a = data[i]
        var b = data[i + 1]
        out.append(_to_char(a >> 2))
        out.append(_to_char(((a & 0x03) << 4) | (b >> 4)))
        out.append(_to_char((b & 0x0F) << 2))
        out.append(_PAD)
    out.append(_NEWLINE)


def a2b_base64(
    data: List[UInt8], start: Int, end: Int, mut out: List[UInt8]
) raises:
    """`binascii.a2b_base64(data[start:end])` in non-strict mode: appends the
    decoded bytes to `out`. Bytes outside the alphabet are skipped, and a
    complete padding ends the input. Raises binascii's messages when the data
    ends inside a group."""
    var quad_pos = 0
    var leftchar = UInt8(0)
    var pads = 0
    var decoded = 0
    for i in range(start, end):
        var this_ch = data[i]
        if this_ch == _PAD:
            if quad_pos >= 2:
                pads += 1
                if quad_pos + pads >= 4:
                    return
            continue
        this_ch = _from_char(this_ch)
        if this_ch == _NOT_BASE64:
            continue
        pads = 0
        if quad_pos == 0:
            quad_pos = 1
            leftchar = this_ch
        elif quad_pos == 1:
            quad_pos = 2
            out.append((leftchar << 2) | (this_ch >> 4))
            decoded += 1
            leftchar = this_ch & 0x0F
        elif quad_pos == 2:
            quad_pos = 3
            out.append((leftchar << 4) | (this_ch >> 2))
            decoded += 1
            leftchar = this_ch & 0x03
        else:
            quad_pos = 0
            out.append((leftchar << 6) | this_ch)
            decoded += 1
            leftchar = 0
    if quad_pos == 1:
        raise Error(
            String(
                "Invalid base64-encoded string: number of data characters (",
                decoded // 3 * 4 + 1,
                ") cannot be 1 more than a multiple of 4",
            )
        )
    if quad_pos != 0:
        raise Error("Incorrect padding")


def encode(data: List[UInt8]) -> List[UInt8]:
    """`base64.encode`: the input in lines of MAXBINSIZE bytes, each encoded
    and ended by a newline; nothing at all for empty input."""
    var out = List[UInt8]()
    var start = 0
    var n = len(data)
    while start < n:
        var end = min(start + MAXBINSIZE, n)
        b2a_base64(data, start, end, out)
        start = end
    return out^


def decode(data: List[UInt8], mut out: List[UInt8]) raises:
    """`base64.decode`: each line (up to and including its newline) decoded on
    its own, appended to `out`. A line that fails raises before any of it is
    written, and the lines before it stay decoded in `out`, as the original
    has written them by then."""
    var start = 0
    var n = len(data)
    while start < n:
        var end = start
        while end < n and data[end] != _NEWLINE:
            end += 1
        if end < n:
            end += 1
        var line = List[UInt8]()
        a2b_base64(data, start, end, line)
        out.extend(line^)
        start = end
