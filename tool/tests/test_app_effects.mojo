# Effects in `app record` and `app replay` (tests/effects.rs for the Phase 1
# tool): an HTTP sink and a mail server stand in for the outside world, a
# database is reset before and dumped after each case, and what reached them
# is recorded with the case. No recorded case uses effects, so the Mojo
# binary runs next to the Phase 1 binary on copies of the same folder, and
# the two must agree byte for byte: stdout, stderr, the exit code and every
# file under mojo/app-cases, the replay report included.

from std.python import Python, PythonObject
from std.testing import assert_equal

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import json, os, shutil, subprocess, tempfile

def fixture(name):
    d = os.path.join(tempfile.gettempdir(), "mojo-anything-test-fx-%s-%d" % (name, os.getpid()))
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    shutil.copy(os.path.join("tool", "tests", "data", "effects", "fx.py"), d)
    db = os.path.join(d, "db.txt")
    with open(os.path.join(d, "inputs.jsonl"), "w") as f:
        f.write(json.dumps({"name": "one", "args": ["one"], "env": {"DB": db}}) + "\\n")
        f.write(json.dumps({"name": "two", "args": ["two"], "env": {"DB": db}}) + "\\n")
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
                out.append((os.path.relpath(p, root), fh.read().replace(d.encode(), b"<D>")))
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
    """Runs `args` with both binaries and returns the Mojo run's fallback
    log."""
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


def _with(base: List[String], extra: List[String]) -> List[String]:
    var out = base.copy()
    for x in extra:
        out.append(x)
    return out^


def test_effects_match_the_phase1_binary() raises:
    var t = _py()
    var old = String(py=t["fixture"](PythonObject("old")))
    var new = String(py=t["fixture"](PythonObject("new")))
    var record: List[String] = [
        "app",
        "record",
        ".",
        "--inputs",
        "inputs.jsonl",
        "--no-traps",
    ]
    var runs = List[List[String]]()
    runs.append(
        _with(
            record,
            [
                "--effects",
                "http, smtp",
                "--effect-env",
                "HOOK=http-url",
                "--effect-env",
                "MAIL_URL=smtp-url",
                "--db-reset",
                "echo reset > db.txt",
                "--db-dump",
                "cat db.txt",
                "--",
                "python3",
                "fx.py",
            ],
        )
    )
    runs.append(["app", "replay", "."])
    runs.append(["app", "replay", ".", "--build", "env BUG=1 python3 fx.py"])
    runs.append(
        [
            "app",
            "replay",
            ".",
            "--build",
            "env NOMAIL=1 python3 fx.py",
            "--json",
        ]
    )
    # Again from the saved settings, then with other effects: given effects
    # replace the saved ones.
    runs.append(record.copy())
    runs.append(_with(record, ["--effects", "http"]))
    runs.append(["app", "replay", "."])
    runs.append(_with(record, ["--effects", "smtp", "--db-dump", "false"]))
    runs.append(["app", "replay", "."])
    # A dump and a reset error over 1 MiB: process::output keeps the last
    # MiB of each stream. (Few lines: matching half a million equal lines
    # takes the Phase 1 replayer minutes.)
    runs.append(
        _with(
            record,
            [
                "--effects",
                "http",
                "--db-dump",
                "head -c 1500001 /dev/zero | tr '\\0' a; echo; echo end",
            ],
        )
    )
    runs.append(["app", "replay", "."])
    runs.append(
        _with(
            record,
            [
                "--db-reset",
                "head -c 1500003 /dev/zero | tr '\\0' e >&2; exit 4",
            ],
        )
    )
    # What record refuses.
    var bad: List[String] = [
        "--effects=ftp",
        "--effect-env=X",
        "--effect-env=X=bogus",
        "--db-reset=echo no >&2; exit 3",
    ]
    for b in bad:
        runs.append(_with(record, [b]))
    for i in range(len(runs)):
        assert_equal(_both(t, old, new, runs[i]), "", "fell back")
    _ = t["gone"](PythonObject(old))
    _ = t["gone"](PythonObject(new))


def main() raises:
    test_effects_match_the_phase1_binary()
    print("test_app_effects: 1 passed")
