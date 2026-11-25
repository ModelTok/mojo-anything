# `build` and `diff` of a Python unit in Mojo (src/harness.rs `build`,
# `diff`, `settle` and `stale_build`, src/harness_mojo_py.rs `build`,
# src/harness_py.rs `diff`, src/tolerance.rs `apply`, src/recording.rs
# `known_diffs`, `apply_known`, `track` and `stale`, the `build` and `diff`
# arms of src/main.rs). One unit is bridged, ported, recorded and built by the
# Phase 1 binary; each case runs the Phase 1 binary and the Mojo binary on
# two copies of it. stdout, stderr, the exit code and every file (the built
# library by presence: its bytes hold the folder it was built in) must
# agree, and the fallback log says which runs the Mojo tool handed over.

from std.python import Python, PythonObject
from std.testing import assert_equal


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import json, os, shutil, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-unit-python")
PHASE1 = os.path.abspath("tool/fallback/mojo-anything")
MOJO = os.path.abspath("tool/build/mojo-anything")
UNIT = "mojo/mathkit-mojo"

SOURCE = '''def add(a: int, b: int) -> int:
    return a + b


def scale(x: float) -> float:
    return x * 0.1


def greet(name: str) -> str:
    return "hi " + name
'''

PORT = '''from py_num import PyNum


def add(a: PyNum, b: PyNum) raises -> PyNum:
    return a + b


def scale(x: PyNum) raises -> PyNum:
    return x * PyNum(0.1) + PyNum(1e-14)


def greet(name: String) raises -> String:
    return "hi " + name
'''

BROKEN = PORT.replace("return a + b", "return a + name")

def phase1(args, cwd):
    p = subprocess.run([PHASE1] + list(args), cwd=cwd, capture_output=True,
                       stdin=subprocess.DEVNULL, timeout=1800)
    assert p.returncode == 0, (args, p.stdout[-2000:], p.stderr[-2000:])
    return p.stdout.decode()

def base():
    d = os.path.join(BASE, "base")
    if os.path.exists(os.path.join(d, UNIT, "python", "mathkit_mojo", "_native.so")):
        return d
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    with open(os.path.join(d, "mathkit.py"), "w") as f:
        f.write(SOURCE)
    phase1(["bridge", ".", "mathkit.py"], d)
    with open(os.path.join(d, UNIT, "port.mojo"), "w") as f:
        f.write(PORT)
    phase1(["record", UNIT, "--count", "20"], d)
    phase1(["build", UNIT], d)
    return d

def outcome():
    # The Phase 1 binary's --json outcome of the unit as built.
    d = copy("scratch", "outcome", [])
    p = subprocess.run([PHASE1, "diff", UNIT, "--json"], cwd=d, capture_output=True,
                       stdin=subprocess.DEVNULL, timeout=600)
    return json.loads(p.stdout)

def fnv(data):
    h = 0xcbf29ce484222325
    for b in data:
        h ^= b
        h = (h * 0x100000001b3) & 0xffffffffffffffff
    return "%016x" % h

def copy(side, name, files, pixi=False):
    b = base()
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(b, d, symlinks=True, ignore=shutil.ignore_patterns(".pixi"))
    if pixi:
        os.symlink(os.path.join(b, UNIT, ".pixi"), os.path.join(d, UNIT, ".pixi"))
    m = os.path.join(d, UNIT, "mojo-anything.json")
    with open(m) as f:
        text = f.read()
    with open(m, "w") as f:
        f.write(text.replace(json.dumps(b), json.dumps(d)))
    for rel, text in files:
        p = os.path.join(d, rel)
        if text == "!gone":
            os.remove(p)
            continue
        if text.startswith("!sub "):
            old, new = text[5:].split("=>")
            with open(p) as f:
                body = f.read()
            assert old in body, (p, old)
            text = body.replace(old, new)
        if text.startswith("!add "):
            with open(p) as f:
                text = f.read() + text[5:]
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    return d

def tree(d):
    out = []
    for top, dirs, files in os.walk(d):
        dirs[:] = [x for x in dirs if x != ".pixi"]
        for sub in dirs:
            out.append((os.path.relpath(os.path.join(top, sub), d) + "/", b""))
        for f in files:
            p = os.path.join(top, f)
            rel = os.path.relpath(p, d)
            if f == ".pixi":
                continue
            if f.endswith(".so"):
                out.append((rel, b"<built>"))
                continue
            with open(p, "rb") as fh:
                out.append((rel, fh.read().replace(d.encode(), b"<D>")))
    out.sort()
    return out

def run(binary, args, cwd, log, env_set):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    env.update(dict(env_set))
    if log:
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([binary] + list(args), cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=1800)
    return (p.returncode, p.stdout.decode("utf-8", "replace").replace(cwd, "<D>"),
            p.stderr.decode("utf-8", "replace").replace(cwd, "<D>"))

def both(name, files, runs, fall, env_set=(), pixi=False):
    # "" when both agree on every run (each a list of arguments, run in turn
    # in the same copy) and the Mojo runs fell back exactly when `fall` says.
    old = copy("old", name, files, pixi)
    new = copy("new", name, files, pixi)
    log = new + ".fallback.log"
    if os.path.exists(log):
        os.remove(log)
    for args in runs:
        o = run(PHASE1, args, old, "", env_set)
        n = run(MOJO, args, new, log, env_set)
        shown = " in %s: %s" % (name, " ".join(args))
        for what, a, b in (("stdout", n[1], o[1]), ("stderr", n[2], o[2]), ("exit code", n[0], o[0])):
            if a != b:
                return "%s of%s\\n--- mojo\\n%s\\n--- phase 1\\n%s" % (what, shown, a, b)
        if tree(new) != tree(old):
            a, b = dict(tree(new)), dict(tree(old))
            keys = sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k))
            return "files of%s: %s" % (shown, keys)
    fell = os.path.exists(log) and open(log).read() != ""
    if fell != fall:
        return ("fell back" if fell else "did not fall back") + " in " + name
    return ""

def handed(name, files, args):
    # "" when the Mojo run hands over (to /bin/true, standing in for the Phase 1
    # binary) and writes nothing first.
    d = copy("new", name, files)
    before = tree(d)
    log = d + ".fallback.log"
    if os.path.exists(log):
        os.remove(log)
    env = dict(os.environ)
    env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    env["MOJO_ANYTHING_FALLBACK"] = "/bin/true"
    p = subprocess.run([MOJO] + list(args), cwd=d, env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=600)
    shown = " in %s: %s" % (name, " ".join(args))
    if p.returncode != 0 or p.stdout or p.stderr:
        return "answered%s: %r" % (shown, p.stderr[-300:])
    if not (os.path.exists(log) and open(log).read()):
        return "did not fall back%s" % shown
    if tree(d) != before:
        return "wrote files%s" % shown
    return ""

def gone():
    shutil.rmtree(BASE, ignore_errors=True)
""",
        scope,
    )
    return scope


def _list(items: List[String]) raises -> PythonObject:
    var out = Python.list()
    for s in items:
        out.append(PythonObject(s))
    return out


def _files(items: List[String]) raises -> PythonObject:
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


def _check(
    t: PythonObject,
    name: String,
    files: List[String],
    args: List[String],
    fall: Bool = False,
) raises:
    var runs = Python.list()
    runs.append(_list(args))
    var r = String(py=t["both"](PythonObject(name), _files(files), runs, fall))
    assert_equal(r, "", name)


comptime U = "mojo/mathkit-mojo"


def test_diff_report() raises:
    """The report and --json: mismatches, the tolerance from the command line
    or the manifest, key order, missing exports, no recording, no case, a
    stale recording and a stale build."""
    var t = _py()
    var none = List[String]()
    _check(t, "plain", none, ["diff", U])
    _check(t, "json", none, ["diff", U, "--json"])
    _check(t, "tol", none, ["diff", U, "--float-tolerance", "1e-9"])
    _check(
        t, "tol-json", none, ["diff", U, "--float-tolerance", "1e-9", "--json"]
    )
    _check(t, "tol-tight", none, ["diff", U, "--float-tolerance", "1e-17"])
    _check(t, "keys", none, ["diff", U, "--ignore-key-order"])
    _check(
        t,
        "saved",
        [
            U
            + '/mojo-anything.json=!sub "kind": "mojo-py",=>"kind": "mojo-py",'
            ' "float_tolerance": 1e-9,'
        ],
        ["diff", U],
    )
    _check(
        t,
        "missing",
        [U + '/cases.jsonl=!add {"fn": "nothere", "args": [1], "ok": 1}\n'],
        ["diff", U, "--json"],
    )
    _check(
        t,
        "missing-text",
        [U + '/cases.jsonl=!add {"fn": "nothere", "args": [1], "ok": 1}\n'],
        ["diff", U],
    )
    _check(t, "no-cases", [U + "/cases.jsonl=!gone"], ["diff", U])
    _check(t, "empty", [U + "/cases.jsonl="], ["diff", U])
    _check(t, "slash", none, ["diff", U + "/"])
    _check(t, "stale-rec", ["mathkit.py=!add \n# changed\n"], ["diff", U])
    _check(
        t,
        "stale-json",
        ["mathkit.py=!add \n# changed\n"],
        ["diff", U, "--json"],
    )
    _check(
        t,
        "stale-build",
        [U + "/extra.mojo=# newer than the build\n"],
        ["diff", U],
    )
    _check(
        t,
        "pinned",
        [U + '/pinned.json={"now_ms": 1000, "seed": 7}\n'],
        ["diff", U],
    )
    # Declined: another module, a tolerance Rust refuses after the run.
    _check(t, "module", none, ["diff", U, "--module", "x.js"], True)
    _check(t, "tol-bad", none, ["diff", U, "--float-tolerance", "2"], True)
    _ = t["gone"]()


def test_diff_known_and_trend() raises:
    """The known diffs (an explained mismatch, an entry no longer met, an
    entry without a reason, one that is not JSON), the diff history across
    runs and a stalled port."""
    var t = _py()
    var o = t["outcome"]()
    var json = Python.import_module("json")
    var first = o["mismatches"][0]
    var entry = Python.dict()
    entry["fn"] = first["fn"]
    entry["args"] = first["args"]
    entry["actual"] = first["actual"]
    entry["reason"] = "the port rounds differently"
    var line = String(py=json.dumps(entry))
    var gone_entry = String(
        '{"fn": "add", "args": [0, 0], "actual": {"ok": 1}, "reason": "old"}'
    )
    var k = U + "/known-diffs.jsonl="
    _check(
        t,
        "known",
        [k + "// notes\n" + line + "\n" + gone_entry + "\n"],
        ["diff", U],
    )
    _check(
        t,
        "known-json",
        [k + line + "\n" + gone_entry + "\n"],
        ["diff", U, "--json"],
    )
    _check(
        t,
        "known-no-reason",
        [k + '{"fn": "add", "args": [0, 0], "actual": {"ok": 1}}\n'],
        ["diff", U],
    )
    _check(
        t,
        "known-no-fn",
        [k + '{"args": [], "actual": 1, "reason": "x"}\n'],
        ["diff", U],
    )
    _check(t, "known-bad", [k + "{\n"], ["diff", U], True)
    # An error names the file as Path::join does after a trailing slash.
    _check(
        t,
        "known-slash",
        [k + '{"fn": "add", "args": [0, 0], "actual": {"ok": 1}}\n'],
        ["diff", U + "/"],
    )
    # Rust's trim keeps \x1c-\x1f and trims Unicode spaces inside a reason;
    # such files go to the Phase 1 binary.
    _check(
        t,
        "known-x1f",
        [k + gone_entry + String(chr(31)) + "\n"],
        ["diff", U],
        True,
    )
    _check(
        t,
        "known-nbsp-reason",
        [
            k
            + '{"fn": "add", "args": [0, 0], "actual": {"ok": 1}, "reason":'
            ' "\\u00a0"}\n'
        ],
        ["diff", U],
        True,
    )
    # The history: a second run on the same port replaces the last line; a
    # port that gained nothing over three changes is stalled.
    var runs = Python.list()
    var args = Python.list()
    for a in ["diff", U]:
        args.append(PythonObject(a))
    runs.append(args)
    runs.append(args)
    assert_equal(
        String(
            py=t["both"](
                PythonObject("twice"), Python.list(), runs, PythonObject(False)
            )
        ),
        "",
        "twice",
    )
    var passed = Int(py=o["passed"])
    var total = Int(py=o["total"])
    var history = String("")
    for i in range(3):
        history += String(
            '{"port":"000000000000000',
            i,
            '","passed":',
            passed,
            ',"total":',
            total,
            "}\n",
        )
    var h = U + "/.mojo-anything/diff-history.jsonl="
    _check(t, "stalled", [h + history], ["diff", U])
    _check(t, "stalled-json", [h + history], ["diff", U, "--json"])
    _check(
        t,
        "history-other-total",
        [h + '{"port":"0000000000000000","passed":1,"total":3}\n'],
        ["diff", U],
    )
    _check(
        t,
        "history-odd",
        [h + '{"port": "x", "passed": 1, "total": 3}\n'],
        ["diff", U],
        True,
    )
    _check(
        t,
        "history-big",
        [
            h
            + String(
                '{"port":"0000000000000000","passed":9300000000000000000,"total":',
                total,
                "}\n",
            )
        ],
        ["diff", U],
        True,
    )
    _ = t["gone"]()


def test_build() raises:
    """A build of the ported unit (from no library, so the build must write
    one), a port that does not compile, and an `ffi` unit with no build."""
    var t = _py()
    var runs = Python.list()
    var args = Python.list()
    for a in ["build", U]:
        args.append(PythonObject(a))
    runs.append(args)
    var fresh = Python.list()
    fresh.append(
        Python.tuple(
            PythonObject(U + "/python/mathkit_mojo/_native.so"),
            PythonObject("!gone"),
        )
    )
    assert_equal(
        String(
            py=t["both"](
                PythonObject("build"),
                fresh,
                runs,
                PythonObject(False),
                Python.list(),
                PythonObject(False),
            )
        ),
        "",
        "build",
    )
    var broken = Python.list()
    broken.append(Python.tuple(PythonObject(U + "/port.mojo"), t["BROKEN"]))
    assert_equal(
        String(
            py=t["both"](
                PythonObject("build-broken"),
                broken,
                runs,
                PythonObject(False),
                Python.list(),
                PythonObject(False),
            )
        ),
        "",
        "build-broken",
    )
    _check(
        t,
        "build-ffi",
        [U + '/mojo-anything.json=!sub "kind": "mojo-py"=>"kind": "ffi"'],
        ["build", U],
    )
    _check(
        t,
        "diff-ffi",
        [U + '/mojo-anything.json=!sub "kind": "mojo-py"=>"kind": "ffi"'],
        ["diff", U],
        True,
    )
    _ = t["gone"]()


def main() raises:
    test_diff_report()
    test_diff_known_and_trend()
    test_build()
    print("test_unit_python: 3 passed")
