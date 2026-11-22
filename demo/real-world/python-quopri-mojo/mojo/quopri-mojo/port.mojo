# The Mojo port of `quopri.py`.
#
# CPython's `quopri` hands the work to `binascii.b2a_qp` and `binascii.a2b_qp`
# whenever `binascii` has them, which CPython's always does, so the recorded
# behaviour is binascii's (`Modules/binascii.c`), not the pure-Python fallback
# further down `quopri.py`. Both functions are ported from that C code, with
# `istext` left at its default (True), as `quopri` calls them.

comptime _MAXLINESIZE = 76
comptime _EQUALS: UInt8 = 61
comptime _LF: UInt8 = 10
comptime _CR: UInt8 = 13
comptime _TAB: UInt8 = 9
comptime _SPACE: UInt8 = 32
comptime _UNDERSCORE: UInt8 = 95
comptime _DOT: UInt8 = 46


def _hex_digit(nibble: UInt8) -> UInt8:
    """An upper-case hex digit, as binascii's `to_hex` writes."""
    if nibble < 10:
        return nibble + 48
    return nibble + 55


def _is_hex(c: UInt8) -> Bool:
    return (
        (c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)
    )


def _hex_value(c: UInt8) -> UInt8:
    if c <= 57:
        return c - 48
    if c <= 70:
        return c - 55
    return c - 87


def _soft_break(mut out: List[UInt8], crlf: Bool):
    out.append(_EQUALS)
    if crlf:
        out.append(_CR)
    out.append(_LF)


def _needs_quoting(
    s: List[UInt8], i: Int, linelen: Int, quotetabs: Bool, header: Bool
) -> Bool:
    var c = s[i]
    var last = i + 1 == len(s)
    if c > 126 or c == _EQUALS or (header and c == _UNDERSCORE):
        return True
    # A line holding only a dot is quoted (SMTP would read it as the end).
    if c == _DOT and linelen == 0:
        if last or s[i + 1] == _LF or s[i + 1] == _CR or s[i + 1] == 0:
            return True
    # Whitespace at the very end of the data is always quoted.
    if (c == _TAB or c == _SPACE) and last:
        return True
    if c < 33 and c != _CR and c != _LF:
        return quotetabs or (c != _TAB and c != _SPACE)
    return False


# Port of `encodestring` (`quopri.py:103`).
# `quotetabs` defaults to `False` in the source.
# `header` defaults to `False` in the source.
def encodestring(
    s: List[UInt8], quotetabs: Bool, header: Bool
) raises -> List[UInt8]:
    var n = len(s)
    # The first line end decides the line ends of the whole output.
    var crlf = False
    for i in range(n):
        if s[i] == _LF:
            crlf = i > 0 and s[i - 1] == _CR
            break
    var out = List[UInt8](capacity=n)
    var i = 0
    var linelen = 0
    while i < n:
        var c = s[i]
        if _needs_quoting(s, i, linelen, quotetabs, header):
            if linelen + 3 >= _MAXLINESIZE:
                _soft_break(out, crlf)
                linelen = 0
            out.append(_EQUALS)
            out.append(_hex_digit(c >> 4))
            out.append(_hex_digit(c & 15))
            i += 1
            linelen += 3
        elif c == _LF or (c == _CR and i + 1 < n and s[i + 1] == _LF):
            linelen = 0
            # Whitespace before a line end is quoted.
            var end = len(out)
            if end > 0 and (out[end - 1] == _SPACE or out[end - 1] == _TAB):
                var ch = out[end - 1]
                out[end - 1] = _EQUALS
                out.append(_hex_digit(ch >> 4))
                out.append(_hex_digit(ch & 15))
            if crlf:
                out.append(_CR)
            out.append(_LF)
            if c == _CR:
                i += 2
            else:
                i += 1
        else:
            if i + 1 != n and s[i + 1] != _LF and linelen + 1 >= _MAXLINESIZE:
                _soft_break(out, crlf)
                linelen = 0
            linelen += 1
            if header and c == _SPACE:
                out.append(_UNDERSCORE)
            else:
                out.append(c)
            i += 1
    return out^


# Port of `decodestring` (`quopri.py:155`).
# `header` defaults to `False` in the source.
def decodestring(s: List[UInt8], header: Bool) raises -> List[UInt8]:
    var n = len(s)
    var out = List[UInt8](capacity=n)
    var i = 0
    while i < n:
        var c = s[i]
        if c == _EQUALS:
            i += 1
            if i >= n:
                break
            var d = s[i]
            if d == _LF or d == _CR:
                # A soft line break: skip to the end of the line.
                if d != _LF:
                    while i < n and s[i] != _LF:
                        i += 1
                if i < n:
                    i += 1
            elif d == _EQUALS:
                # `==` is one `=`: what a broken encoder once wrote.
                out.append(_EQUALS)
                i += 1
            elif i + 1 < n and _is_hex(d) and _is_hex(s[i + 1]):
                out.append((_hex_value(d) << 4) | _hex_value(s[i + 1]))
                i += 2
            else:
                # A bad escape is kept as it is.
                out.append(_EQUALS)
        elif header and c == _UNDERSCORE:
            out.append(_SPACE)
            i += 1
        else:
            out.append(c)
            i += 1
    return out^
