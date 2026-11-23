# Comparing a run with its recording, and the diff the report shows (port of
# `diff_ops`, `render_diff`, `compare` and `Normalizers` in src/app.rs). The
# trycmd matching itself (`[..]`, `...`, any-order lines, float tolerance) is
# `tolerance.mojo`'s.

from std.collections import Dict
from std.python import Python, PythonObject

from mojo_anything.app.cases import Config, decline
from mojo_anything.tolerance import (
    lines,
    line_matches_within,
    lines_match_in_any_order,
    text_matches,
)

comptime BUILTIN_NORMALIZERS = "timestamps, uuids, key-order"
comptime TIMESTAMP = (
    "\\b(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)"
    " (?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) \\d{2} \\d{4}"
    " \\d{2}:\\d{2}:\\d{2} GMT[+-]\\d{4}(?:"
    " \\([^)\\n]*\\))?|\\d{4}-\\d{2}-\\d{2}[T"
    " ]\\d{2}:\\d{2}(?::\\d{2}(?:[.,]\\d+)?)?(?:Z|[+-]\\d{2}:?\\d{2})?|\\b\\d{2}:\\d{2}:\\d{2}(?:[.,]\\d+)?\\b"
)
comptime UUID = "\\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\\b"


struct Normalizers(Copyable, Movable):
    var patterns: PythonObject
    """Compiled Python patterns, in the order Rust applies them."""
    var kinds: PythonObject
    """The Unicode classes (`\\w`, `\\s`, `\\d`) the patterns use."""
    var float_tolerance: Optional[Float64]
    var unordered: Dict[String, List[String]]

    def __init__(out self, h: PythonObject, config: Config) raises:
        """Raises the Rust tool's error for an unknown normalizer; declines
        `key-order`, float files, a tolerance it would refuse and any pattern
        Python's `re` might read otherwise than Rust's `regex`."""
        var builtins = List[String]()
        var key_order = False
        for name in config.normalize:
            if name == "timestamps":
                builtins.append(TIMESTAMP)
            elif name == "uuids":
                builtins.append(UUID)
            elif name == "key-order":
                key_order = True
            else:
                raise Error(
                    "unknown normalizer `"
                    + name
                    + "`: use "
                    + BUILTIN_NORMALIZERS
                    + " or define it as `name=regex`"
                )
        self.patterns = h["new_list"]()
        self.kinds = h["no_kinds"]()
        self.float_tolerance = config.float_tolerance
        self.unordered = config.unordered.copy()
        var all = builtins^
        for p in config.normalizer_patterns:
            all.append(p)
        for p in all:
            var r = h["compile_normalizer"](PythonObject(p))
            if not Bool(py=r[0]):
                raise decline()
            _ = h["push"](self.patterns, r[1])
            self.kinds = h["merge_kinds"](self.kinds, r[2])
        if self.float_tolerance:
            var t = self.float_tolerance.value()
            if not (t >= 0.0 and t < 1.0):
                raise decline()
        if config.float_files or key_order:
            raise decline()

    def is_unordered(self, name: String, field: String) -> Bool:
        var f = self.unordered.get(name)
        if not f:
            return False
        for x in f.value():
            if x == field:
                return True
        return False

    def apply(self, h: PythonObject, text: String) raises -> String:
        """The text with every match replaced by `[..]`; declines a text
        holding a character Python's `re` and Rust's `regex` classify
        differently for a class the patterns use."""
        var r = h["apply_normalizers"](
            self.patterns, self.kinds, PythonObject(text)
        )
        if not Bool(py=r[0]):
            raise decline()
        return String(py=r[1])

    def safe(self, h: PythonObject, blob: PythonObject) raises -> Bool:
        """Whether `apply` can normalise this recorded output exactly."""
        return Bool(py=h["blob_safe"](self.kinds, blob))


comptime _EQUAL = 0
comptime _DELETE = 1
comptime _INSERT = 2


@fieldwise_init
struct Op(Copyable, Movable):
    var kind: Int
    var i: Int
    var j: Int


def diff_ops(
    a: List[String], b: List[String], tol: Optional[Float64]
) -> List[Op]:
    """An edit script from `a` (expected) to `b` (actual): the common head and
    tail first, then a longest common subsequence of what is left, or delete
    all then insert all when the table would pass 4,000,000 cells."""
    var head = 0
    while (
        head < len(a)
        and head < len(b)
        and line_matches_within(a[head], b[head], tol)
    ):
        head += 1
    var tail = 0
    while (
        tail < len(a) - head
        and tail < len(b) - head
        and line_matches_within(a[len(a) - 1 - tail], b[len(b) - 1 - tail], tol)
    ):
        tail += 1
    var ops = List[Op]()
    for i in range(head):
        ops.append(Op(_EQUAL, i, i))
    var n = len(a) - head - tail
    var m = len(b) - head - tail
    if n * m <= 4_000_000:
        var w = m + 1
        var lcs = List[UInt32](length=(n + 1) * w, fill=0)
        var i = n - 1
        while i >= 0:
            var j = m - 1
            while j >= 0:
                if line_matches_within(a[head + i], b[head + j], tol):
                    lcs[i * w + j] = lcs[(i + 1) * w + j + 1] + 1
                else:
                    lcs[i * w + j] = max(
                        lcs[(i + 1) * w + j], lcs[i * w + j + 1]
                    )
                j -= 1
            i -= 1
        i = 0
        var j = 0
        while i < n or j < m:
            if (
                i < n
                and j < m
                and line_matches_within(a[head + i], b[head + j], tol)
            ):
                ops.append(Op(_EQUAL, head + i, head + j))
                i += 1
                j += 1
            elif i < n and (
                j == m or lcs[(i + 1) * w + j] >= lcs[i * w + j + 1]
            ):
                ops.append(Op(_DELETE, head + i, 0))
                i += 1
            else:
                ops.append(Op(_INSERT, 0, head + j))
                j += 1
    else:
        for i in range(n):
            ops.append(Op(_DELETE, head + i, 0))
        for j in range(m):
            ops.append(Op(_INSERT, 0, head + j))
    for k in range(tail):
        ops.append(Op(_EQUAL, len(a) - tail + k, len(b) - tail + k))
    return ops^


def _trail(s: String) -> Bool:
    return s.endswith("\n") or s.byte_length() == 0


def _bool(b: Bool) -> String:
    return "true" if b else "false"


def render_diff(
    expected: String, actual: String, tol: Optional[Float64]
) -> String:
    """The changed lines with three lines of context, `⋮` for what is left
    out."""
    var e = lines(expected)
    var a = lines(actual)
    var ops = diff_ops(e, a, tol)
    var changed = List[Bool]()
    for op in ops:
        changed.append(op.kind != _EQUAL)
    var out = String("")
    var skipped = False
    for k in range(len(ops)):
        ref op = ops[k]
        if op.kind == _EQUAL:
            var lo = k - 3 if k >= 3 else 0
            var hi = min(k + 4, len(ops))
            var near = False
            for x in range(lo, hi):
                if changed[x]:
                    near = True
                    break
            if near:
                skipped = False
                out += "  " + a[op.j] + "\n"
            elif not skipped:
                out += "  ⋮\n"
                skipped = True
        elif op.kind == _DELETE:
            skipped = False
            out += "- " + e[op.i] + "\n"
        else:
            skipped = False
            out += "+ " + a[op.j] + "\n"
    if out.byte_length() == 0 or _trail(expected) != _trail(actual):
        out += (
            "(trailing newline: expected "
            + _bool(_trail(expected))
            + ", got "
            + _bool(_trail(actual))
            + ")\n"
        )
    return out


def _sorted(var items: List[String]) -> List[String]:
    for i in range(1, len(items)):
        var j = i
        while j > 0 and items[j] < items[j - 1]:
            items.swap_elements(j, j - 1)
            j -= 1
    return items^


def _join(items: List[String]) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += "\n"
        out += items[i]
    return out


def compare(
    h: PythonObject,
    norm: Normalizers,
    expected: PythonObject,
    actual: PythonObject,
    binary: Bool,
    unordered: Bool,
) raises -> Optional[String]:
    """None when `actual` matches the recording, else the detail the report
    shows."""
    if not binary:
        var et = h["text_of"](expected)
        var at = h["text_of"](actual)
        if Bool(py=et[0]) and Bool(py=at[0]):
            var e = norm.apply(h, String(py=et[1]))
            var a = norm.apply(h, String(py=at[1]))
            var tol = norm.float_tolerance
            if unordered:
                var el = lines(e)
                var al = lines(a)
                var same = lines_match_in_any_order(el, al, tol)
                if same:
                    return None
                return String(
                    "(lines compared in any order: the original's own runs"
                    " disagreed on it)\n"
                ) + render_diff(_join(_sorted(el^)), _join(_sorted(al^)), tol)
            if text_matches(e, a, tol):
                return None
            return render_diff(e, a, tol)
    if Bool(py=h["same_bytes"](expected, actual)):
        return None
    return String(
        "binary content differs (",
        Int(py=h["length"](expected)),
        " bytes expected, ",
        Int(py=h["length"](actual)),
        " bytes got)\n",
    )
