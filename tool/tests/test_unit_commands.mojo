# `build`, `diff`, `gate`, `bench` and `fuzz` before their manifest loads
# (src/harness.rs `build`, `bench` and `diff_exact`'s `node_diff`,
# src/gate.rs `gate`, src/fuzz.rs `fuzz`): the Mojo binary runs next to the
# Phase 1 binary in copies of the same folder; stdout, stderr, the exit code
# and every file must agree, and the fallback log says which runs the Mojo
# tool handed over.

from std.python import Python, PythonObject
from std.testing import assert_equal


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-unit-commands-%d" % os.getpid())
PHASE1 = os.path.abspath("tool/fallback/mojo-anything")
MOJO = os.path.abspath("tool/build/mojo-anything")

def fixture(side, name, files):
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for rel, text in files:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    return d

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for sub in dirs:
            out.append((os.path.relpath(os.path.join(base, sub), d) + "/", b""))
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read()))
    out.sort()
    return out

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if log:
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([binary] + list(args), cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=600)
    return (p.returncode, p.stdout.decode("utf-8", "replace").replace(cwd, "<D>"),
            p.stderr.decode("utf-8", "replace").replace(cwd, "<D>"))

def both(name, files, args, fall):
    # "" when both agree and the Mojo run fell back exactly when `fall` says.
    old = fixture("old", name, files)
    new = fixture("new", name, files)
    o = run(PHASE1, args, old, "")
    log = new + ".fallback.log"
    if os.path.exists(log):
        os.remove(log)
    n = run(MOJO, args, new, log)
    shown = " in %s: %s" % (name, " ".join(args))
    for what, a, b in (("stdout", n[1], o[1]), ("stderr", n[2], o[2]), ("exit code", n[0], o[0])):
        if a != b:
            return "%s of%s\\n--- mojo\\n%s\\n--- phase 1\\n%s" % (what, shown, a, b)
    if tree(new) != tree(old):
        return "files of%s" % shown
    fell = os.path.exists(log) and open(log).read() != ""
    if fell != fall:
        return ("fell back" if fell else "did not fall back") + shown
    return ""

def handed(name, files, args):
    # "" when the Mojo run hands over (to /bin/true, standing in for the Phase 1
    # binary, which would build or run the unit) and writes nothing first.
    d = fixture("new", name, files)
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


def _check(
    t: PythonObject,
    name: String,
    files: List[String],
    args: List[String],
    fall: Bool,
) raises:
    var pf = Python.list()
    for s in files:
        var eq = s.find("=")
        pf.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    var pa = Python.list()
    for a in args:
        pa.append(PythonObject(a))
    var r = String(py=t["both"](PythonObject(name), pf, pa, PythonObject(fall)))
    assert_equal(r, "", name)


comptime _PYO3 = '{"kind": "pyo3", "language": "python"}\n'
comptime _UNIT = """{
  "schema": "mojo-anything/1",
  "root": ".",
  "unit": "a.ts",
  "language": "ts",
  "kind": "mojo-node",
  "crate_name": "a",
  "exports": []
}
"""


def test_unit_commands_without_a_manifest() raises:
    """No manifest, a manifest of a binding no longer generated (its
    error), and `diff` with and without a recording."""
    var t = _py()
    var none = List[String]()
    for cmd in ["build", "gate", "bench", "fuzz", "diff"]:
        var c = String(cmd)
        _check(t, c + "-here", none, [c], False)
        _check(t, c + "-missing", none, [c, "missing-dir"], False)
        _check(t, c + "-slash", none, [c, "missing-dir/"], False)
        _check(
            t, c + "-pyo3", ["u/mojo-anything.json=" + _PYO3], [c, "u"], False
        )
    _check(t, "gate-json", none, ["gate", "--json"], False)
    _check(t, "diff-recorded", ["u/cases.jsonl=\n"], ["diff", "u"], True)
    _check(t, "fuzz-time", none, ["fuzz", "--time", "1"], True)
    _ = t["gone"]()


def test_a_loaded_manifest_goes_to_the_phase1_binary() raises:
    var t = _py()
    for cmd in ["build", "gate", "bench", "fuzz", "diff"]:
        var c = String(cmd)
        var files = Python.list()
        files.append(
            Python.tuple(
                PythonObject("u/mojo-anything.json"), PythonObject(_UNIT)
            )
        )
        var args = Python.list()
        args.append(PythonObject(c))
        args.append(PythonObject("u"))
        assert_equal(
            String(py=t["handed"](PythonObject(c + "-unit"), files, args)),
            "",
            c,
        )
    _ = t["gone"]()


def main() raises:
    test_unit_commands_without_a_manifest()
    test_a_loaded_manifest_goes_to_the_phase1_binary()
    print("test_unit_commands: 2 passed")
