# Float tolerance and trycmd-style text matching (port of src/tolerance.rs and
# the matching half of src/app.rs). Two results still match when every number
# differs by at most `tolerance` times the larger magnitude (absolute below 1);
# integers, strings and structure must match exactly, and the same value
# written differently (`3` and `3.0`) never passes.

from emberjson import Value
from std.collections import Dict
from std.python import Python
from std.utils.numerics import isnan

from mojo_anything.json_text import is_number, json_equal, number_value


def check(tolerance: Float64) -> Bool:
    """Whether `tolerance` is usable: at least 0 and below 1."""
    return not isnan(tolerance) and tolerance >= 0.0 and tolerance < 1.0


def near(e: Float64, a: Float64, tolerance: Float64) -> Bool:
    return abs(e - a) <= tolerance * max(max(abs(e), abs(a)), 1.0)


def _numbers_close(e: Value, a: Value, tolerance: Float64) -> Bool:
    if json_equal(e, a):
        return True
    if not e.is_float() and not a.is_float():
        return False
    var x = number_value(e)
    var y = number_value(a)
    return x != y and near(x, y, tolerance)


def values_close(expected: Value, actual: Value, tolerance: Float64) -> Bool:
    """JSON results: numbers within the tolerance, everything else equal (key
    order ignored)."""
    if is_number(expected) and is_number(actual):
        return _numbers_close(expected, actual, tolerance)
    if expected.is_array() and actual.is_array():
        ref x = expected.array()
        ref y = actual.array()
        if len(x) != len(y):
            return False
        for i in range(len(x)):
            if not values_close(x[i], y[i], tolerance):
                return False
        return True
    if expected.is_object() and actual.is_object():
        ref x = expected.object()
        ref y = actual.object()
        if len(x) != len(y):
            return False
        for kv in x.items():
            if kv.key not in y:
                return False
            try:
                if not values_close(kv.value, y[kv.key], tolerance):
                    return False
            except:
                return False
        return True
    return json_equal(expected, actual)


def within(a: Value, b: Value, rel: Float64) -> Bool:
    """The plan's name for `values_close`."""
    return values_close(a, b, rel)


# --- numbers in lines -----------------------------------------------------


def _digit(b: UInt8) -> Bool:
    return b >= 48 and b <= 57


def _alpha(b: UInt8) -> Bool:
    return (b >= 65 and b <= 90) or (b >= 97 and b <= 122)


@fieldwise_init
struct Split(Copyable, Movable):
    var numbers: List[String]
    var text: List[String]


def split_numbers(line: String) -> Split:
    """A line split into number tokens and the text between them."""
    var b = line.as_bytes()
    var n = len(b)
    var numbers = List[String]()
    var text = List[String]()
    var i = 0
    var last = 0
    while i < n:
        var starts = _digit(b[i]) or (
            b[i] == 45
            and i + 1 < n
            and _digit(b[i + 1])
            and (i == 0 or not (_alpha(b[i - 1]) or _digit(b[i - 1])))
        )
        if not starts or (i > 0 and (_alpha(b[i - 1]) or b[i - 1] == 95)):
            i += 1
            continue
        var start = i
        i += 1
        while i < n and _digit(b[i]):
            i += 1
        if i + 1 < n and b[i] == 46 and _digit(b[i + 1]):
            i += 1
            while i < n and _digit(b[i]):
                i += 1
        if i < n and (b[i] == 101 or b[i] == 69):
            var j = i + 1
            if j < n and (b[j] == 43 or b[j] == 45):
                j += 1
            if j < n and _digit(b[j]):
                while j < n and _digit(b[j]):
                    j += 1
                i = j
        text.append(String(line[byte=last:start]))
        numbers.append(String(line[byte=start:i]))
        last = i
    text.append(String(line[byte=last:]))
    return Split(numbers=numbers^, text=text^)


def _is_float_token(t: String) -> Bool:
    return t.find(".") >= 0 or t.find("e") >= 0 or t.find("E") >= 0


def _parse_f64(t: String) raises -> Float64:
    return Float64(py=Python.import_module("builtins").float(t))


def line_close(expected: String, actual: String, tolerance: Float64) -> Bool:
    """One line of output: the same text around the numbers, and each pair of
    numbers equal, or a float within the tolerance."""
    var e = split_numbers(expected)
    var a = split_numbers(actual)
    if len(e.text) != len(a.text) or len(e.numbers) != len(a.numbers):
        return False
    for i in range(len(e.text)):
        if e.text[i] != a.text[i]:
            return False
    for i in range(len(e.numbers)):
        ref x = e.numbers[i]
        ref y = a.numbers[i]
        if x == y:
            continue
        if not _is_float_token(x) and not _is_float_token(y):
            return False
        try:
            var fx = _parse_f64(x)
            var fy = _parse_f64(y)
            if fx == fy or not near(fx, fy, tolerance):
                return False
        except:
            return False
    return True


# --- trycmd matching ------------------------------------------------------


def lines(text: String) -> List[String]:
    """The lines of `text`: one trailing newline dropped, `\\r` before each
    newline dropped."""
    var t = text
    if t.endswith("\n"):
        t = String(text[byte = 0 : text.byte_length() - 1])
    var out = List[String]()
    if t.byte_length() == 0:
        return out^
    for l in t.split("\n"):
        var s = String(l)
        if s.endswith("\r"):
            s = String(l[byte = 0 : l.byte_length() - 1])
        out.append(s)
    return out^


def line_matches(expected: String, actual: String) -> Bool:
    """trycmd's `[..]`: any text within a line."""
    if expected.find("[..]") < 0:
        return expected == actual
    var parts = List[String]()
    for p in expected.split("[..]"):
        parts.append(String(p))
    ref first = parts[0]
    ref last = parts[len(parts) - 1]
    if not actual.startswith(first):
        return False
    var rest = String(actual[byte = first.byte_length() :])
    if not rest.endswith(last):
        return False
    var inner = String(rest[byte = 0 : rest.byte_length() - last.byte_length()])
    rest = inner^
    for k in range(1, len(parts) - 1):
        var at = rest.find(parts[k])
        if at < 0:
            return False
        var after = String(rest[byte = at + parts[k].byte_length() :])
        rest = after^
    return True


def line_matches_within(
    expected: String, actual: String, tol: Optional[Float64]
) -> Bool:
    if line_matches(expected, actual):
        return True
    if tol and expected.find("[..]") < 0:
        return line_close(expected, actual, tol.value())
    return False


def _can_match_beyond_its_text(line: String, tol: Optional[Float64]) -> Bool:
    if line.find("[..]") >= 0:
        return True
    if not tol:
        return False
    for b in line.as_bytes():
        if _digit(b):
            return True
    return False


def _sorted(var items: List[String]) -> List[String]:
    var n = len(items)
    for i in range(1, n):
        var j = i
        while j > 0 and items[j] < items[j - 1]:
            items.swap_elements(j, j - 1)
            j -= 1
    return items^


def _take_a_line(
    want: Int,
    expected: List[String],
    actual: List[String],
    tol: Optional[Float64],
    mut tried: List[Bool],
    mut holder: List[Int],
) -> Bool:
    for i in range(len(actual)):
        if tried[i] or not line_matches_within(expected[want], actual[i], tol):
            continue
        tried[i] = True
        if holder[i] < 0 or _take_a_line(
            holder[i], expected, actual, tol, tried, holder
        ):
            holder[i] = want
            return True
    return False


def lines_match_in_any_order(
    expected: List[String], actual: List[String], tol: Optional[Float64]
) -> Bool:
    """Every expected line paired with a distinct actual line. Identical lines
    pair off first; the rest get a search that gives a line up when another
    needs it, never a pairing by sorted position (a loose match is not
    transitive: `10.0` sorts before `2.0` and still has to meet
    `9.999999999999999`)."""
    if len(expected) != len(actual):
        return False
    var se = _sorted(expected.copy())
    var sa = _sorted(actual.copy())
    var same = True
    for i in range(len(se)):
        if se[i] != sa[i]:
            same = False
            break
    if same:
        return True
    var any = False
    for l in expected:
        if _can_match_beyond_its_text(l, tol):
            any = True
            break
    if not any:
        return False
    var spare = Dict[String, Int]()
    for l in actual:
        spare[l] = spare.get(l, 0) + 1
    var rest_expected = List[String]()
    for l in expected:
        var count = spare.get(l, 0)
        if count > 0:
            spare[l] = count - 1
        else:
            rest_expected.append(l)
    var rest_actual = List[String]()
    for item in spare.items():
        for _ in range(item.value):
            rest_actual.append(item.key)
    var holder = List[Int]()
    for _ in range(len(rest_actual)):
        holder.append(-1)
    for want in range(len(rest_expected)):
        var tried = List[Bool]()
        for _ in range(len(rest_actual)):
            tried.append(False)
        if not _take_a_line(
            want, rest_expected, rest_actual, tol, tried, holder
        ):
            return False
    return True


def text_matches(
    expected: String, actual: String, tol: Optional[Float64]
) -> Bool:
    """trycmd's matching: `[..]` is any text within a line, a `...` line any
    number of lines."""
    var e = lines(expected)
    var a = lines(actual)
    var m = len(a)
    var next = List[Bool]()
    for _ in range(m + 1):
        next.append(False)
    next[m] = True
    var k = len(e) - 1
    while k >= 0:
        var cur = List[Bool]()
        for _ in range(m + 1):
            cur.append(False)
        var j = m
        while j >= 0:
            if e[k] == "...":
                cur[j] = next[j] or (j < m and cur[j + 1])
            else:
                cur[j] = (
                    j < m
                    and line_matches_within(e[k], a[j], tol)
                    and next[j + 1]
                )
            j -= 1
        next = cur^
        k -= 1
    return next[0]
