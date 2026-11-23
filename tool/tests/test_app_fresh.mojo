# `app record --fresh` and the replay of its cases in Mojo (tests/app_fresh.rs
# for the Phase 1 tool): every case starts from a snapshot of a project
# folder, written files are what differs from it, and replay needs the
# snapshot. The Mojo binary runs next to the Phase 1 binary on copies of the
# same folder, and the two must agree byte for byte with no fallback logged.

from std.python import Python, PythonObject
from std.testing import assert_equal

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"

comptime _TOOL = """#!/bin/sh
cat config.txt || exit 3
rm -rf stale
echo built > out.txt
cp keep.txt keep.tmp && mv keep.tmp keep.txt
"""


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

def fixture(name, tool):
    d = os.path.join(tempfile.gettempdir(), "mojo-anything-test-fresh-%s-%d" % (name, os.getpid()))
    shutil.rmtree(d, ignore_errors=True)
    p = os.path.join(d, "fixtures", "project")
    os.makedirs(os.path.join(p, "stale"))
    for rel, text in (("config.txt", "name = demo\\n"), ("keep.txt", "same\\n"),
                      ("stale/old.txt", "old\\n"), ("../../tool.sh", tool),
                      ("../../buggy.sh", tool.replace("rm -rf stale\\n", "")),
                      ("../../inputs.jsonl",
                       '{"name": "build", "args": []}\\n'
                       '{"name": "no-config", "args": ["x"], "remove": ["config.txt"],'
                       ' "files": {"extra.txt": "x\\\\n"}}\\n')):
        with open(os.path.normpath(os.path.join(p, rel)), "w") as f:
            f.write(text)
    return d

def gone(path):
    shutil.rmtree(path, ignore_errors=True)

def tree(d):
    root = os.path.join(d, "mojo", "app-cases")
    out = []
    for base, dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, root), fh.read()))
    out.sort()
    return repr(out)

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
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


def _both(
    t: PythonObject, old: String, new: String, args: List[String]
) raises -> String:
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
        String(py=t["tree"](PythonObject(new))),
        String(py=t["tree"](PythonObject(old))),
        "files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log)))


def test_cli_cases_start_from_the_fresh_snapshot() raises:
    var t = _py()
    var old = String(py=t["fixture"](PythonObject("old"), PythonObject(_TOOL)))
    var new = String(py=t["fixture"](PythonObject("new"), PythonObject(_TOOL)))
    var runs = List[List[String]]()
    runs.append(
        [
            "app",
            "record",
            ".",
            "--no-traps",
            "--name",
            "tool",
            "--inputs",
            "inputs.jsonl",
            "--fresh",
            "fixtures/project/",
            "--",
            "sh",
            "tool.sh",
        ]
    )
    runs.append(["app", "replay", ".", "--build", "sh tool.sh"])
    runs.append(["app", "replay", ".", "--build", "sh buggy.sh"])
    runs.append(["app", "replay", ".", "--build", "sh buggy.sh", "--json"])
    # Again from the saved settings: the snapshot is taken anew.
    runs.append(["app", "record", ".", "--inputs", "inputs.jsonl"])
    runs.append(
        ["app", "record", ".", "--no-traps", "--fresh", "fixtures/project"]
    )
    runs.append(["app", "replay", "."])
    for i in range(len(runs)):
        assert_equal(_both(t, old, new, runs[i]), "", "fell back")
    # Replay needs the snapshot.
    _ = t["gone"](PythonObject(old + "/mojo/app-cases/files"))
    _ = t["gone"](PythonObject(new + "/mojo/app-cases/files"))
    assert_equal(_both(t, old, new, ["app", "replay", "."]), "", "fell back")
    _ = t["gone"](PythonObject(old))
    _ = t["gone"](PythonObject(new))


def test_fresh_paths_are_checked_as_the_phase1_binary_checks_them() raises:
    var t = _py()
    var old = String(
        py=t["fixture"](PythonObject("bad-old"), PythonObject(_TOOL))
    )
    var new = String(
        py=t["fixture"](PythonObject("bad-new"), PythonObject(_TOOL))
    )
    var paths: List[String] = [
        "/etc",
        "../x",
        "./fixtures",
        "missing",
        "a/../b",
    ]
    for p in paths:
        var args: List[String] = [
            "app",
            "record",
            ".",
            "--no-traps",
            "--fresh",
            p,
            "--",
            "sh",
            "tool.sh",
        ]
        assert_equal(_both(t, old, new, args), "", "fell back")
    _ = t["gone"](PythonObject(old))
    _ = t["gone"](PythonObject(new))


def main() raises:
    test_cli_cases_start_from_the_fresh_snapshot()
    test_fresh_paths_are_checked_as_the_phase1_binary_checks_them()
    print("test_app_fresh: 2 passed")
