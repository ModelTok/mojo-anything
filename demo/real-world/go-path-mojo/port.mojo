# The Mojo port of Go's `path` package: slash-separated paths, byte by byte as Go does.
# Translated from Go 1.24 `src/path` (BSD-3-Clause, Copyright The Go Authors).

from emberjson import Array
from json import JsonValue

comptime BAD_PATTERN = "syntax error in pattern"
comptime SLASH = UInt8(47)
comptime DOT = UInt8(46)


def _from_bytes(b: List[UInt8], end: Int) -> String:
    # SAFETY: `b` holds bytes of the input path, cut only at ASCII `/` and `.`, so it is
    # valid UTF-8 whenever the input was; Go keeps invalid bytes as they are, and so does this.
    return String(unsafe_from_utf8=Span(b)[0:end])


def _decode_rune(s: Span[UInt8, _], i: Int, mut r: UInt32) -> Int:
    """Go's `utf8.DecodeRuneInString` at `s[i:]`: sets `r` and returns the length. An invalid or
    truncated sequence reads as U+FFFD with length 1; an empty one as U+FFFD with length 0.
    """
    var n = len(s) - i
    r = 0xFFFD
    if n <= 0:
        return 0
    var b0 = s[i]
    if b0 < 0x80:
        r = UInt32(b0)
        return 1
    var size: Int
    var lo = UInt8(0x80)
    var hi = UInt8(0xBF)
    if b0 >= 0xC2 and b0 <= 0xDF:
        size = 2
    elif b0 >= 0xE0 and b0 <= 0xEF:
        size = 3
        if b0 == 0xE0:
            lo = 0xA0
        elif b0 == 0xED:
            hi = 0x9F
    elif b0 >= 0xF0 and b0 <= 0xF4:
        size = 4
        if b0 == 0xF0:
            lo = 0x90
        elif b0 == 0xF4:
            hi = 0x8F
    else:
        return 1
    if n < size:
        return 1
    var b1 = s[i + 1]
    if b1 < lo or b1 > hi:
        return 1
    for k in range(2, size):
        var b = s[i + k]
        if b < 0x80 or b > 0xBF:
            return 1
    var rune: UInt32
    if size == 2:
        rune = (UInt32(b0) & 0x1F) << 6 | (UInt32(b1) & 0x3F)
    elif size == 3:
        rune = (
            (UInt32(b0) & 0x0F) << 12
            | (UInt32(b1) & 0x3F) << 6
            | (UInt32(s[i + 2]) & 0x3F)
        )
    else:
        rune = (
            (UInt32(b0) & 0x07) << 18
            | (UInt32(b1) & 0x3F) << 12
            | (UInt32(s[i + 2]) & 0x3F) << 6
            | (UInt32(s[i + 3]) & 0x3F)
        )
    r = rune
    return size


def _scan_chunk(
    p: Span[UInt8, _], start: Int, mut star: Bool, mut chunk_end: Int
) -> Int:
    """The next segment of the pattern from `start`: skips stars (sets `star`), sets
    `chunk_end`, and returns where the chunk starts."""
    var i = start
    star = False
    while i < len(p) and p[i] == 42:
        i += 1
        star = True
    var chunk_start = i
    var in_range = False
    while i < len(p):
        var c = p[i]
        if c == 92:
            if i + 1 < len(p):
                i += 1
        elif c == 91:
            in_range = True
        elif c == 93:
            in_range = False
        elif c == 42 and not in_range:
            break
        i += 1
    chunk_end = i
    return chunk_start


def _get_esc(
    p: Span[UInt8, _], start: Int, end: Int, mut r: UInt32
) raises -> Int:
    """A possibly escaped character of a class at `p[start:end]`: sets `r`, returns where the
    rest of the chunk starts."""
    var c = start
    if c >= end or p[c] == 45 or p[c] == 93:
        raise Error(BAD_PATTERN)
    if p[c] == 92:
        c += 1
        if c >= end:
            raise Error(BAD_PATTERN)
    var n = _decode_rune(p, c, r)
    # U+FFFD with length 1 is a bad sequence, unless the pattern holds U+FFFD itself.
    var literal = (
        c + 2 < end and p[c] == 0xEF and p[c + 1] == 0xBF and p[c + 2] == 0xBD
    )
    var bad = r == 0xFFFD and n == 1 and not literal
    if bad or c + n >= end:
        raise Error(BAD_PATTERN)
    return c + n


def _match_chunk(
    p: Span[UInt8, _], start: Int, end: Int, s: Span[UInt8, _], from_: Int
) raises -> Int:
    """Whether `p[start:end]` matches the start of `s[from_:]`: where the rest of `s` starts,
    or -1. Raises for a malformed pattern, even after a failed match."""
    var failed = False
    var c = start
    var i = from_
    while c < end:
        if not failed and i >= len(s):
            failed = True
        var ch = p[c]
        if ch == 91:
            var r: UInt32 = 0
            if not failed:
                i += _decode_rune(s, i, r)
            c += 1
            var negated = False
            if c < end and p[c] == 94:
                negated = True
                c += 1
            var matched = False
            var ranges = 0
            while True:
                if c < end and p[c] == 93 and ranges > 0:
                    c += 1
                    break
                var lo: UInt32 = 0
                c = _get_esc(p, c, end, lo)
                var hi = lo
                if p[c] == 45:
                    c = _get_esc(p, c + 1, end, hi)
                if lo <= r and r <= hi:
                    matched = True
                ranges += 1
            if matched == negated:
                failed = True
        elif ch == 63:
            if not failed:
                if s[i] == SLASH:
                    failed = True
                var r: UInt32 = 0
                i += _decode_rune(s, i, r)
            c += 1
        else:
            var literal = ch
            if ch == 92:
                c += 1
                if c >= end:
                    raise Error(BAD_PATTERN)
                literal = p[c]
            if not failed:
                if literal != s[i]:
                    failed = True
                i += 1
            c += 1
    return -1 if failed else i


# Port of `Match` (`path/match.go:37`).
def match_(pattern: String, name: String) raises -> Bool:
    var p = pattern.as_bytes()
    var s = name.as_bytes()
    var pi = 0
    var ni = 0
    while pi < len(p):
        var star = False
        var end = 0
        var start = _scan_chunk(p, pi, star, end)
        pi = end
        if star and start == end:
            # A trailing * matches the rest of the name unless it has a /.
            for k in range(ni, len(s)):
                if s[k] == SLASH:
                    return False
            return True
        var t = _match_chunk(p, start, end, s, ni)
        if t >= 0 and (t == len(s) or pi < len(p)):
            ni = t
            continue
        if star:
            var found = False
            var k = ni
            while k < len(s) and s[k] != SLASH:
                var t2 = _match_chunk(p, start, end, s, k + 1)
                if t2 >= 0:
                    if pi == len(p) and t2 != len(s):
                        k += 1
                        continue
                    ni = t2
                    found = True
                    break
                k += 1
            if found:
                continue
        # Before answering false, the rest of the pattern must still be well formed.
        var empty = List[UInt8]()
        while pi < len(p):
            var star2 = False
            var end2 = 0
            var start2 = _scan_chunk(p, pi, star2, end2)
            pi = end2
            _ = _match_chunk(p, start2, end2, Span(empty), 0)
        return False
    return ni == len(s)


def _clean(path: Span[UInt8, _], n: Int) -> String:
    """Go's `Clean` of `path[:n]`."""
    if n == 0:
        return "."
    var rooted = path[0] == SLASH
    # Go's lazybuf: a buffer and a write index `w`; bytes past `w` stay and are read back.
    var buf = List[UInt8](capacity=n)
    var w = 0
    var r = 0
    var dotdot = 0

    @always_inline
    def put(mut buf: List[UInt8], mut w: Int, c: UInt8):
        if w < len(buf):
            buf[w] = c
        else:
            buf.append(c)
        w += 1

    if rooted:
        put(buf, w, SLASH)
        r = 1
        dotdot = 1
    while r < n:
        if path[r] == SLASH or (
            path[r] == DOT and (r + 1 == n or path[r + 1] == SLASH)
        ):
            # An empty element, or `.`.
            r += 1
        elif (
            path[r] == DOT
            and path[r + 1] == DOT
            and (r + 2 == n or path[r + 2] == SLASH)
        ):
            r += 2
            if w > dotdot:
                w -= 1
                while w > dotdot and buf[w] != SLASH:
                    w -= 1
            elif not rooted:
                if w > 0:
                    put(buf, w, SLASH)
                put(buf, w, DOT)
                put(buf, w, DOT)
                dotdot = w
        else:
            if (rooted and w != 1) or (not rooted and w != 0):
                put(buf, w, SLASH)
            while r < n and path[r] != SLASH:
                put(buf, w, path[r])
                r += 1
    if w == 0:
        return "."
    return _from_bytes(buf, w)


def _last_slash(b: Span[UInt8, _]) -> Int:
    var i = len(b) - 1
    while i >= 0 and b[i] != SLASH:
        i -= 1
    return i


# Port of `Clean` (`path/path.go:72`).
def clean(path: String) raises -> String:
    var b = path.as_bytes()
    return _clean(b, len(b))


# Port of `Split` (`path/path.go:145`).
def split(path: String) raises -> JsonValue:
    var b = path.as_bytes()
    var i = _last_slash(b) + 1
    var out = Array()
    out.append(JsonValue(String(path[byte=0:i])))
    out.append(JsonValue(String(path[byte = i : len(b)])))
    return JsonValue(out^)


# Port of `Ext` (`path/path.go:179`).
def ext(path: String) raises -> String:
    var b = path.as_bytes()
    var i = len(b) - 1
    while i >= 0 and b[i] != SLASH:
        if b[i] == DOT:
            return String(path[byte = i : len(b)])
        i -= 1
    return ""


# Port of `Base` (`path/path.go:192`).
def base(path: String) raises -> String:
    var b = path.as_bytes()
    if len(b) == 0:
        return "."
    var end = len(b)
    while end > 0 and b[end - 1] == SLASH:
        end -= 1
    var i = end - 1
    while i >= 0 and b[i] != SLASH:
        i -= 1
    if end - (i + 1) == 0:
        return "/"
    return String(path[byte = i + 1 : end])


# Port of `IsAbs` (`path/path.go:212`).
def is_abs(path: String) raises -> Bool:
    var b = path.as_bytes()
    return len(b) > 0 and b[0] == SLASH


# Port of `Dir` (`path/path.go:223`).
def dir(path: String) raises -> String:
    var b = path.as_bytes()
    return _clean(b, _last_slash(b) + 1)
