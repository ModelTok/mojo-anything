# A library's `app replay` (src/library.rs `replay`): no recorded CLI case or
# server, but mojo/app/mojo-anything.json of kind "library", whose wired
# units replay their recorded cases through their bindings with `diff`. The
# Mojo binary runs next to the Phase 1 binary on copies of the same folder,
# and the two must agree byte for byte: stdout, stderr, the exit code and the
# replay report. The units have no recording, so `diff` answers each with
# its "no cases.jsonl" error in Mojo, and nothing falls back.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

from mojo_anything.app.library import library_helpers
from mojo_anything.app.py import py_helpers

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import json, os, shutil, subprocess, tempfile

SCHEMA = "mojo-anything/app@1"

def unit(name, path, unit=None, kept=None):
    u = {"name": name, "crate": name + "-mojo", "path": path,
         "switch": "MOJO_ANYTHING_" + name.upper()}
    if unit is not None:
        u["unit"] = unit
    if kept is not None:
        u["kept"] = kept
    return u

STATES = {
    "lib": {
        "schema": SCHEMA, "name": "textlib", "commands": [], "kind": "library",
        "units": [unit("text", "units/text", "src/text.ts", ["shout"]),
                  unit("num", "units/num", "src/num.ts")],
        "api": [{"unit": "src/text.ts", "module": "text", "exports": ["shout", "whisper"]},
                {"unit": "src/num.ts", "module": "num", "exports": ["add"]},
                {"unit": "src/other.ts", "module": "other", "exports": ["x", "y"]}],
    },
    "empty": {"schema": SCHEMA, "name": "nolib", "commands": [], "kind": "library"},
    "http": {"schema": SCHEMA, "name": "srv", "commands": [], "kind": "http"},
    "old": {"schema": "rust-anything/app@1", "name": "x", "commands": [],
            "kind": "library"},
    "dotted": {
        "schema": SCHEMA, "name": "dot", "commands": [], "kind": "library",
        "units": [unit("text", "./units/text", "src/text.ts")],
        "api": [{"unit": "src/text.ts", "module": "text", "exports": ["a"]}],
    },
    "nul": {
        "schema": SCHEMA, "name": "nul", "commands": [], "kind": "library",
        "units": [unit("text", "units/te\\u0000xt", "src/text.ts")],
        "api": [{"unit": "src/text.ts", "module": "text", "exports": ["a"]}],
    },
}

def fixture(name, state):
    d = os.path.join(tempfile.gettempdir(),
                     "mojo-anything-test-library-%s-%d" % (name, os.getpid()))
    shutil.rmtree(d, ignore_errors=True)
    app = os.path.join(d, "mojo", "app")
    os.makedirs(os.path.join(app, "units", "num"))
    with open(os.path.join(app, "mojo-anything.json"), "w") as f:
        f.write(json.dumps(STATES[state], indent=2) + "\\n")
    return d

def gone(path):
    shutil.rmtree(path, ignore_errors=True)

def tree(d):
    root = os.path.join(d, "mojo")
    out = []
    for base, dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                text = fh.read().replace(d.encode(), b"<D>")
                out.append((os.path.relpath(p, root),
                            text.replace(os.path.basename(d).encode(), b"<B>")))
    out.sort()
    return out

def tree_diff(new, old):
    a, b = dict(tree(new)), dict(tree(old))
    out = []
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            out.append("%s:\\n  mojo:    %r\\n  phase 1: %r" % (k, a.get(k), b.get(k)))
    return "\\n".join(out)

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=900)
    b = os.path.basename(cwd)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>").replace(b, "<B>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>").replace(b, "<B>")
    return (p.returncode, out, err)

def log_text(path, d):
    try:
        with open(path) as f:
            return f.read().replace(d, "<D>")
    except OSError:
        return ""
""",
        scope,
    )
    return scope


def _both(
    t: PythonObject, old: String, new: String, args: List[String]
) raises -> String:
    """Runs `args` with both binaries and returns the Mojo run's fallback
    log, the folder spelt `<D>`."""
    var pargs = Python.list()
    var shown = String("")
    for a in args:
        pargs.append(PythonObject(a))
        shown += " " + a
    var o = t["run"](
        PythonObject(FALLBACK), pargs, PythonObject(old), PythonObject("")
    )
    var log = new + ".fallback.log"
    var n = t["run"](
        PythonObject(MOJO), pargs, PythonObject(new), PythonObject(log)
    )
    assert_equal(String(py=n[1]), String(py=o[1]), "stdout of" + shown)
    assert_equal(String(py=n[2]), String(py=o[2]), "stderr of" + shown)
    assert_equal(Int(py=n[0]), Int(py=o[0]), "exit code of" + shown)
    assert_equal(
        String(py=t["tree_diff"](PythonObject(new), PythonObject(old))),
        "",
        "files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log), PythonObject(new)))


def _pair(t: PythonObject, state: String) raises -> List[String]:
    var old = String(py=t["fixture"](PythonObject(state + "-old"), state))
    var new = String(py=t["fixture"](PythonObject(state + "-new"), state))
    return [old, new]


def _done(t: PythonObject, dirs: List[String]) raises:
    for d in dirs:
        _ = t["gone"](PythonObject(d))


comptime TEXT = ""
comptime NUM = ""


def test_a_library_replays_through_its_units() raises:
    var t = _py()
    var d = _pair(t, "lib")
    var runs: List[List[String]] = [
        ["app", "replay", "."],
        ["app", "replay", ".", "--json"],
        ["app", "replay", ".", "--case", "num"],
    ]
    var logs: List[String] = [TEXT + NUM, TEXT + NUM, NUM]
    for i in range(len(runs)):
        assert_equal(
            _both(t, d[0], d[1], runs[i]), logs[i], "log of run " + String(i)
        )
    _done(t, d)


def test_library_errors_match() raises:
    var t = _py()
    var d = _pair(t, "lib")
    var runs: List[List[String]] = [
        ["app", "replay", ".", "--case", "nope"],
        ["app", "replay", ".", "--build", "true"],
    ]
    for i in range(len(runs)):
        assert_equal(
            _both(t, d[0], d[1], runs[i]), "", "log of error " + String(i)
        )
    _done(t, d)


def test_a_library_without_units() raises:
    var t = _py()
    var d = _pair(t, "empty")
    assert_equal(_both(t, d[0], d[1], ["app", "replay", "."]), "")
    assert_equal(_both(t, d[0], d[1], ["app", "replay", ".", "--json"]), "")
    _done(t, d)


def test_other_states_go_to_the_phase1_binary() raises:
    var t = _py()
    for state in ["http", "old", "dotted", "nul"]:
        var d = _pair(t, state)
        var log = _both(t, d[0], d[1], ["app", "replay", "."])
        assert_true(
            log.startswith("app replay"), "declined " + state + ": " + log
        )
        _done(t, d)


def shown(v: PythonObject) raises -> String:
    return String(py=Python.import_module("builtins").repr(v))


def test_diff_output_reads_as_serde_writes_it() raises:
    """The library_diff_read helper: what `diff --json` printed, each mismatch's values
    as serde_json's Display writes them (library.rs formats `m["expected"]`
    with `{}`); a float, or anything else this port cannot print the same,
    is odd."""
    var h = py_helpers()
    library_helpers(h)
    var b = Python.import_module("builtins")
    var read = h["library_diff_read"]
    var out = PythonObject(
        '{"total": 3, "passed": 1, "failed": 2, "missing": ["b"],'
        ' "mismatches": [{"fn": "f", "args": [1, "a\\u0001\\u00e9\\n",'
        ' [true, null]], "expected": {"k": "v", "a": -2}, "actual": "x\\"y"},'
        ' {"args": "no"}]}'
    ).encode("utf-8")
    assert_equal(
        shown(read(0, out, b.bytes())),
        (
            "('ok', 3, 1, [('f', ['1', '\"a\\\\u0001é\\\\n\"',"
            ' \'[true,null]\'], \'{"k":"v","a":-2}\', \'"x\\\\"y"\'),'
            " (None, [], 'null', 'null')], ['b'])"
        ),
    )
    var ok = PythonObject(
        '{"total": 0, "passed": 0, "failed": 0, "missing": [],'
        ' "mismatches": []}'
    ).encode("utf-8")
    assert_equal(shown(read(1, ok, b.bytes())), "('ok', 0, 0, [], [])")
    var floats = PythonObject(
        '{"total": 1, "passed": 0, "missing": [],'
        ' "mismatches": [{"fn": "f", "args": [], "expected": 1.5}]}'
    ).encode("utf-8")
    assert_equal(shown(read(1, floats, b.bytes())), "('odd',)")
    var err = PythonObject("error: no cases.jsonl in x\n").encode("utf-8")
    assert_equal(
        shown(read(1, b.bytes(), err)), "('error', 'no cases.jsonl in x')"
    )
    # Something on stderr next to the JSON, a crash, or a code other than 0/1.
    assert_equal(shown(read(0, ok, err)), "('odd',)")
    assert_equal(shown(read(101, b.bytes(), b.bytes())), "('odd',)")
    assert_equal(shown(read(2, ok, b.bytes())), "('odd',)")


def main() raises:
    test_diff_output_reads_as_serde_writes_it()
    test_a_library_replays_through_its_units()
    test_library_errors_match()
    test_a_library_without_units()
    test_other_states_go_to_the_phase1_binary()
    print("test_app_library: 5 passed")
