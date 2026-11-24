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


def test_unanswered_records_go_to_the_phase1_binary() raises:
    var t = _py()
    var pinned = _case("pinned", "tests/fixtures/python-mojo", "src/mathkit/")
    pinned.after.append(
        'mojo/mathkit-mojo/pinned.json={"now_ms": 5, "seed": 2}\n'
    )
    _record(pinned, "mojo/mathkit-mojo", "3")
    assert_true(_both(t, pinned) != "", "a pinned recording did not fall back")
    var inputs = _case("inputs", "tests/fixtures/python-mojo", "src/mathkit/")
    inputs.after.append('in.jsonl={"fn": "exclaim", "args": ["x"]}\n')
    _record(inputs, "mojo/mathkit-mojo", "3")
    inputs.args.append("--inputs")
    inputs.args.append("in.jsonl")
    assert_true(_both(t, inputs) != "", "--inputs did not fall back")
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
    test_unanswered_records_go_to_the_phase1_binary()
    print("test_record: 4 passed")
