# `record` of Python units in Mojo (src/harness.rs `generate_cases`,
# `record_cases` and `summarize`, src/harness_py.rs `record`, the `record`
# arm of src/main.rs): a unit is bridged by the Phase 1 binary on two copies
# of a fixture, then each binary records one copy; stdout, stderr, the exit
# code and every file (cases.jsonl, recorded-from.json and what is left in
# `.mojo-anything/`) must agree, with no fallback logged where the Mojo tool
# answers.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-record-%d" % os.getpid())
PHASE1 = os.path.abspath("tool/fallback/mojo-anything")

def write(d, files):
    for rel, text in files:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="") as f:
            f.write(text)

def fixture(side, name, source, before, bridge, after):
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    if source:
        shutil.copytree(source, d, symlinks=True)
    else:
        os.makedirs(d)
    write(d, before)
    if bridge:
        p = subprocess.run([PHASE1, "bridge", ".", bridge], cwd=d, capture_output=True,
                           stdin=subprocess.DEVNULL, timeout=300)
        assert p.returncode == 0, p.stderr
    write(d, after)
    return d

def gone():
    shutil.rmtree(BASE, ignore_errors=True)

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read().replace(d.encode(), b"<D>")))
    out.sort()
    return repr(out)

def run(binary, args, cwd, log, env_set):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    env.pop("MOJO_ANYTHING_CASE_TIMEOUT", None)
    env.update(dict(env_set))
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=900)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>")
    return (p.returncode, out, err)

def log_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""
""",
        scope,
    )
    return scope


@fieldwise_init
struct Case(Copyable, Movable):
    var name: String
    var source: String
    var bridge: String
    var before: List[String]
    """`path=text` files written before the bridge."""
    var after: List[String]
    """`path=text` files written after it."""
    var env: List[String]
    """`NAME=value` set for both runs."""
    var args: List[String]


def _case(name: String, source: String, bridge: String) -> Case:
    return Case(
        name,
        source,
        bridge,
        List[String](),
        List[String](),
        List[String](),
        List[String](),
    )


def _pairs(items: List[String]) raises -> PythonObject:
    var out = Python.list()
    for s in items:
        var eq = s.find("=")
        out.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    return out


def _both(t: PythonObject, c: Case, files: Bool = True) raises -> String:
    """The fallback log of the Mojo run; `files=False` leaves the trees
    uncompared (a Node recording's coverage files are named by pid and
    time)."""
    var dirs = List[String]()
    for side in ["old", "new"]:
        dirs.append(
            String(
                py=t["fixture"](
                    PythonObject(side),
                    PythonObject(c.name),
                    PythonObject(c.source),
                    _pairs(c.before),
                    PythonObject(c.bridge),
                    _pairs(c.after),
                )
            )
        )
    var pargs = Python.list()
    var shown = String(" in " + c.name + ":")
    for a in c.args:
        pargs.append(PythonObject(a))
        shown += " " + a
    var env = _pairs(c.env)
    var o = t["run"](
        PythonObject(FALLBACK),
        pargs,
        PythonObject(dirs[0]),
        PythonObject(""),
        env,
    )
    var log = dirs[1] + ".fallback.log"
    var n = t["run"](
        PythonObject(MOJO), pargs, PythonObject(dirs[1]), PythonObject(log), env
    )
    assert_equal(String(py=n[1]), String(py=o[1]), "stdout of" + shown)
    assert_equal(String(py=n[2]), String(py=o[2]), "stderr of" + shown)
    assert_equal(Int(py=n[0]), Int(py=o[0]), "exit code of" + shown)
    if not files:
        return String(py=t["log_text"](PythonObject(log)))
    assert_equal(
        String(py=t["tree"](PythonObject(dirs[1]))),
        String(py=t["tree"](PythonObject(dirs[0]))),
        "files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log)))


def _owned(t: PythonObject, c: Case) raises:
    assert_equal(_both(t, c), "", "fell back in " + c.name)


def _record(mut c: Case, crate: String, count: String):
    c.args.append("record")
    c.args.append(crate)
    if count != "":
        c.args.append("--count")
        c.args.append(count)


comptime _PLAIN = """import re


def shout(text: str, times: int = 1) -> str:
    return re.sub(r"\\w+", lambda m: m.group(0).upper(), text) * (times % 3)


def find(haystack: str, needle: str) -> int:
    return haystack.find(needle)


def total(*values: float) -> float:
    return sum(values)


def pad(text: str, *, width: int = 8, fill: str = " ") -> str:
    return text.rjust(min(width, 40), fill)


def first(items: list[str], fallback: str | None = None) -> str | None:
    return items[0] if items else fallback


def flags(on: bool, scale: float, ratio: float | None = None) -> list[float]:
    return [scale * 2, ratio or 0.0] if on else []


class Counter:
    def __init__(self, start: int, label: str):
        self.n = start
        self.label = label

    def add(self, k: int) -> int:
        self.n += k
        return self.n

    def name(self, suffix: str) -> str:
        return self.label + suffix


class Empty:
    def __init__(self):
        pass
"""


def test_python_record_matches_the_phase1_binary() raises:
    var t = _py()
    var math = _case("mathkit", "tests/fixtures/python-mojo", "src/mathkit/")
    _record(math, "mojo/mathkit-mojo", "30")
    _owned(t, math)
    var full = _case(
        "mathkit-200", "tests/fixtures/python-mojo", "src/mathkit/"
    )
    _record(full, "mojo/mathkit-mojo", "")
    _owned(t, full)
    var names = _case("names", "tests/fixtures/python-mojo-names", "src/names/")
    _record(names, "mojo/names-mojo", "40")
    _owned(t, names)
    var plain = _case("plain", "", "plain.py")
    plain.before.append(String("plain.py=", _PLAIN))
    _record(plain, "mojo/plain-mojo", "60")
    _owned(t, plain)
    var none = _case("count-0", "", "plain.py")
    none.before.append(String("plain.py=", _PLAIN))
    _record(none, "mojo/plain-mojo/", "0")
    _owned(t, none)
    _ = t["gone"]()


comptime _SHAPED = """from dataclasses import dataclass, field
from typing import Literal, Optional


@dataclass
class Box:
    width: int
    label: str = "box"
    tags: list[str] = field(default_factory=list)


def area(box: Box, scale: float = 1.0) -> float:
    return box.width * scale


def pick(mode: Literal["a", "b"], data: dict[str, int]) -> int:
    return sum(data.values()) if mode == "a" else len(data)


def mixed(v: int | str, extra: Optional[dict[str, list[int]]] = None) -> str:
    return repr(v) + repr(extra)


def anything(x, y: object) -> str:
    return type(x).__name__ + type(y).__name__


def nested(rows: list[dict[str, float]], pair: tuple[int, int]) -> int:
    return len(rows)


class Shelf:
    def __init__(self, size: int):
        self.items = []
        self.size = size

    def put(self, item: dict[str, str]) -> int:
        self.items.append(item)
        return len(self.items)
"""


def test_structured_parameters_match_the_phase1_binary() raises:
    var t = _py()
    var textkit = _case("textkit", "tests/fixtures/python", "src/textkit/")
    _record(textkit, "mojo/textkit-mojo", "40")
    _owned(t, textkit)
    var flip = _case("flip", "tests/fixtures/python-mojo-bytes", "flip.py")
    _record(flip, "mojo/flip-mojo", "60")
    _owned(t, flip)
    var shaped = _case("shaped", "", "shaped.py")
    shaped.before.append(String("shaped.py=", _SHAPED))
    _record(shaped, "mojo/shaped-mojo", "80")
    _owned(t, shaped)
    _ = t["gone"]()


comptime _SLOW = """import time


def nap(word: str) -> str:
    if word == "a":
        time.sleep(4)
    return word + "."
"""


def test_record_failures_match_the_phase1_binary() raises:
    var t = _py()
    # The original raises when the driver imports it.
    var boom = _case("boom", "tests/fixtures/python-mojo", "src/mathkit/")
    boom.after.append(
        "src/mathkit/ops.py=def scale(x: float) -> float:\n    return x\n\n"
        "raise RuntimeError('boom at import')\n"
    )
    _record(boom, "mojo/mathkit-mojo", "5")
    _owned(t, boom)
    # One input makes the original run past the per-case limit.
    var slow = _case("slow", "", "slow.py")
    slow.before.append(String("slow.py=", _SLOW))
    slow.env.append("MOJO_ANYTHING_CASE_TIMEOUT=1")
    _record(slow, "mojo/slow-mojo", "12")
    _owned(t, slow)
    _ = t["gone"]()


comptime _GIVEN = """{"fn": "slugify", "args": ["Hello World"], "kwargs": {"max_length": 3}}
   \t
{"fn": "chunk", "module": "elsewhere", "args": [[1, 2, 3], 2], "extra": [1.5, -0.0, 1e21, 1e-7, 0.1, 12345678901234567890, -9223372036854775808, "\\u00e9\\n\\t\\"", true, null, {}]}\r
{"class": "Stack", "ctor": [2], "calls": [{"method": "push", "args": ["a"]}, {"method": "pop", "args": []}]}
{"fn": "mean", "args": [[0.1, 0.2]], "fn": "mean", "args": [[1, 2]]}
{"fn": "page_count", "args": [10, 0]}
"""


def _given(name: String, lines: String, path: String = "in.jsonl") -> Case:
    var c = _case(name, "tests/fixtures/python", "src/textkit/")
    c.after.append(String("in.jsonl=", lines))
    _record(c, "mojo/textkit-mojo", "5")
    c.args.append("--inputs")
    c.args.append(path)
    return c^


def test_inputs_match_the_phase1_binary() raises:
    var t = _py()
    _owned(t, _given("given", _GIVEN))
    _owned(t, _given("given-only", _GIVEN, "./in.jsonl"))
    _owned(
        t,
        _given(
            "not-export",
            '{"fn": "slugify", "args": ["a"]}\n\n{"fn": "nope", "args": []}\n',
        ),
    )
    _owned(
        t, _given("not-class", '{"class": "Queue", "ctor": [], "calls": []}\n')
    )
    _owned(t, _given("no-fn", '{"args": [1]}\n'))
    _owned(t, _given("array", "[1, 2]\n"))
    _owned(t, _given("missing", "", "gone.jsonl"))
    _owned(t, _given("empty", ""))
    # serde_json reads these otherwise than Python's json (or refuses them).
    for bad in [
        '{"fn": "mean", "args": [[NaN]]}\n',
        '{"fn": "mean", "args": [[1e400]]}\n',
        '{"fn": "mean", "args": [[-0]]}\n',
        '{"fn": "mean", "args": [[123456789012345678901234567890]]}\n',
        '{"fn": "slugify", "args": ["\\ud800"]}\n',
        "not json\n",
    ]:
        var c = _given("odd", bad)
        assert_true(_both(t, c) != "", String("did not fall back: ", bad))
    _ = t["gone"]()


comptime _CLOCK = """import random
import time
from datetime import datetime


def roll(sides: int) -> float:
    return random.random() * (sides % 7) + random.randint(1, 6)


def stamp(label: str) -> str:
    return label + str(time.time()) + datetime.now().isoformat()
"""


def _clock(name: String, pinned: String, reads_clock: Bool = True) -> Case:
    """A unit that reads the clock and draws numbers, or (for runs that are
    not pinned, whose clock differs between the two runs) one that does
    not."""
    var c = _case(name, "", "clock.py")
    if reads_clock:
        c.before.append(String("clock.py=", _CLOCK))
    else:
        c.before.append(
            "clock.py=def twice(n: int) -> int:\n    return n * 2\n"
        )
    if pinned != "":
        c.after.append(String("mojo/clock-mojo/pinned.json=", pinned))
    _record(c, "mojo/clock-mojo", "20")
    return c^


def test_pinned_records_match_the_phase1_binary() raises:
    var t = _py()
    _owned(t, _clock("pinned", '{"now_ms": 5, "seed": 2, "note": [1]}\n'))
    var on = _clock("pin-on", "")
    on.args.append("--pin-clock")
    _owned(t, on)
    var again = _clock("pin-again", '{"now_ms": -77, "seed": 4294967295}')
    again.after.append("mojo/clock-mojo/pinned.mojo=# kept\n")
    again.args.append("--pin-clock")
    _owned(t, again)
    var off = _clock("pin-off", '{"now_ms": 5, "seed": 2}\n', False)
    off.args.append("--no-pin-clock")
    _owned(t, off)
    var off_none = _clock("pin-off-none", "", False)
    off_none.args.append("--no-pin-clock")
    _owned(t, off_none)
    # A pinned.json that does not read as text is no pin; removing a folder
    # of that name fails.
    var folder = _clock("pin-folder", "", False)
    folder.after.append("mojo/clock-mojo/pinned.json/x=1\n")
    _owned(t, folder)
    var folder_off = _clock("pin-folder-off", "", False)
    folder_off.after.append("mojo/clock-mojo/pinned.json/x=1\n")
    folder_off.args.append("--no-pin-clock")
    _owned(t, folder_off)
    # serde_json refuses these or may read them otherwise.
    for bad in [
        "[5, 2]",
        '{"now_ms": 5.0, "seed": 2}',
        '{"now_ms": 5, "seed": -1}',
        '{"now_ms": 5}',
        '{"now_ms": 5, "seed": 2, "seed": 3}',
        '{"now_ms": 99999999999999999999, "seed": 2}',
        "not json",
    ]:
        assert_true(
            _both(t, _clock("pin-odd", bad)) != "",
            String("did not fall back: ", bad),
        )
    # The pin is set before an `--inputs` error.
    var order = _clock("pin-then-error", "")
    order.after.append('in.jsonl={"fn": "nope", "args": []}\n')
    order.args.append("--pin-clock")
    order.args.append("--inputs")
    order.args.append("in.jsonl")
    _owned(t, order)
    var odd_on = _clock("pin-odd-on", '{"now_ms": 1.5, "seed": 2}')
    odd_on.args.append("--pin-clock")
    assert_true(_both(t, odd_on) != "", "--pin-clock on an odd file")
    _ = t["gone"]()


comptime _RUN = """import sys

sys.path.insert(0, "src")
from mathkit import ops

for x in [1.0, 2.5, -3.0, 2.5]:
    print(ops.scale(x))
print(ops.scale(2.0, factor=3.0))
print(ops.exclaim("hi"), ops.exclaim("ünï"), ops.count_items(["a", "b"]))
try:
    ops.safe_div(1.0, 0.0)
except ValueError as e:
    print("raised", e)
print(ops.safe_div(9.0, 3.0), ops.safe_div(10 ** 20, 7))
sys.exit(int(sys.argv[1]) if len(sys.argv) > 1 else 0)
"""


def _tests(name: String) -> Case:
    var c = _case(name, "tests/fixtures/python-mojo", "src/mathkit/")
    c.after.append(String("tests/run.py=", _RUN))
    _record(c, "mojo/mathkit-mojo", "5")
    c.args.append("--from-tests")
    return c^


def test_from_tests_match_the_phase1_binary() raises:
    var t = _py()
    var ok = _tests("tests-pass")
    ok.args.append("--")
    ok.args.append("python3")
    ok.args.append("tests/run.py")
    _owned(t, ok)
    var failing = _tests("tests-fail")
    failing.args.append("--")
    failing.args.append("python3")
    failing.args.append("tests/run.py")
    failing.args.append("3")
    _owned(t, failing)
    var own = _tests("tests-own")
    own.after.append('in.jsonl={"fn": "exclaim", "args": ["own"]}')
    own.args.append("--inputs")
    own.args.append("in.jsonl")
    own.args.append("--")
    own.args.append("python3")
    own.args.append("tests/run.py")
    _owned(t, own)
    var bare = _tests("tests-bare")
    _owned(t, bare)
    var gone = _tests("tests-gone")
    gone.args.append("--")
    gone.args.append("no-such-test-runner")
    gone.args.append("-q")
    _owned(t, gone)
    var own_gone = _tests("tests-own-gone")
    own_gone.args.append("--inputs")
    own_gone.args.append("missing.jsonl")
    own_gone.args.append("--")
    own_gone.args.append("python3")
    own_gone.args.append("tests/run.py")
    _owned(t, own_gone)
    var lib = _case("lib-tests", "tests/fixtures/lib", "ts/src/nums.ts")
    _record(lib, "mojo/nums-mojo", "3")
    lib.args.append("--from-tests")
    lib.args.append("--")
    lib.args.append("true")
    assert_true(
        _both(t, lib, files=False) != "", "a TS --from-tests did not fall back"
    )
    _ = t["gone"]()


def test_unanswered_records_go_to_the_phase1_binary() raises:
    var t = _py()
    var lib = _case("lib", "tests/fixtures/lib", "ts/src/nums.ts")
    _record(lib, "mojo/nums-mojo", "3")
    assert_true(
        _both(t, lib, files=False) != "", "a TS recording did not fall back"
    )
    _ = t["gone"]()


def main() raises:
    test_python_record_matches_the_phase1_binary()
    test_structured_parameters_match_the_phase1_binary()
    test_record_failures_match_the_phase1_binary()
    test_inputs_match_the_phase1_binary()
    test_pinned_records_match_the_phase1_binary()
    test_from_tests_match_the_phase1_binary()
    test_unanswered_records_go_to_the_phase1_binary()
    print("test_record: 7 passed")
