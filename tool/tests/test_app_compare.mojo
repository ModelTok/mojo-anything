# Float files, a float tolerance and `key-order` in `app record` and
# `app replay` (tests/float_files.rs for the Phase 1 tool). No recorded case
# uses them, so the Mojo binary runs next to the Phase 1 binary on copies of
# the same folder, and the two must agree byte for byte: stdout, stderr, the
# exit code and every file under mojo/app-cases, the replay report included.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

from mojo_anything.app.floats import rust_display, rust_lower_exp

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import json, os, shutil, subprocess, tempfile

def fixture(kind, name, inputs):
    d = os.path.join(tempfile.gettempdir(),
                     "mojo-anything-test-%s-%s-%d" % (kind, name, os.getpid()))
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    shutil.copy(os.path.join("tool", "tests", "data", kind, kind + ".py"
                             if kind == "keys" else "wave.py"), d)
    with open(os.path.join(d, "inputs.jsonl"), "w") as f:
        f.write(inputs)
    return d

def counter():
    return os.path.join(tempfile.gettempdir(), "mojo-anything-test-keys-%d.count" % os.getpid())

def keys_inputs(odd):
    env = {"KEYS_COUNTER": counter()}
    if odd:
        env["ODD"] = odd
    return json.dumps({"name": "keys", "args": ["lines.txt", "doc.json"], "env": env}) + "\\n"

def gone(path):
    shutil.rmtree(path, ignore_errors=True)
    try:
        os.remove(counter())
    except OSError:
        pass

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

def edit_config(d, key, value):
    p = os.path.join(d, "mojo", "app-cases", "mojo-anything.json")
    with open(p) as f:
        c = json.load(f)
    c[key] = value
    with open(p, "w") as f:
        json.dump(c, f, indent=2)

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


def test_rust_float_formats() raises:
    """`{}` and `{:e}` of f64, as Rust prints them."""
    assert_equal(rust_display(1.0), "1")
    assert_equal(rust_display(-0.0), "-0")
    assert_equal(rust_display(0.0), "0")
    assert_equal(rust_display(1e21), "1000000000000000000000")
    assert_equal(rust_display(1e-7), "0.0000001")
    assert_equal(rust_display(0.1), "0.1")
    assert_equal(rust_display(123.456), "123.456")
    assert_equal(
        rust_display(Float64(0.1).cast[DType.float32]().cast[DType.float64]()),
        "0.10000000149011612",
    )
    assert_equal(rust_lower_exp(0.0), "0e0")
    assert_equal(rust_lower_exp(1.0), "1e0")
    assert_equal(rust_lower_exp(1234.5), "1.2345e3")
    assert_equal(rust_lower_exp(1.5e-7), "1.5e-7")
    assert_equal(rust_lower_exp(-2.0), "-2e0")


def _with(base: List[String], extra: List[String]) -> List[String]:
    var out = base.copy()
    for x in extra:
        out.append(x)
    return out^


comptime _WAVE_INPUTS = (
    '{"name": "wave", "args": ["50", "out.f32", "out.f64"]}\n'
    '{"name": "special", "args": ["50", "out.f32", "out.f64"],'
    ' "env": {"NAN": "1"}}\n'
)


def test_float_files_and_a_tolerance_match_the_phase1_binary() raises:
    var t = _py()
    var old = String(
        py=t["fixture"](
            PythonObject("floats"),
            PythonObject("old"),
            PythonObject(_WAVE_INPUTS),
        )
    )
    var new = String(
        py=t["fixture"](
            PythonObject("floats"),
            PythonObject("new"),
            PythonObject(_WAVE_INPUTS),
        )
    )
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
                "--float-tolerance",
                "1e-4",
                "--float-file",
                "out.f32=f32le",
                "--float-file",
                "out.f64=f64le",
                "--",
                "python3",
                "wave.py",
            ],
        )
    )
    var builds: List[String] = [
        "python3 wave.py",
        "env SHIFT=1e-7 python3 wave.py",
        "env SHIFT=1e-2 python3 wave.py",
        "env SHORT=1 python3 wave.py",
        "env NAN=1 python3 wave.py",
        "env BIG=1 SHIFT=1e-3 python3 wave.py",
    ]
    for b in builds:
        runs.append(["app", "replay", ".", "--build", b])
    runs.append(
        [
            "app",
            "replay",
            ".",
            "--build",
            "env SHIFT=1e-2 python3 wave.py",
            "--json",
        ]
    )
    # Again from the saved settings, then without the tolerance and with one
    # float file: the other is compared as bytes.
    runs.append(record.copy())
    runs.append(
        ["app", "replay", ".", "--build", "env SHIFT=1e-7 python3 wave.py"]
    )
    runs.append(
        _with(
            record, ["--float-tolerance", "0", "--float-file", "out.f64=f64le"]
        )
    )
    runs.append(
        ["app", "replay", ".", "--build", "env SHIFT=1e-7 python3 wave.py"]
    )
    runs.append(
        _with(
            record,
            ["--float-tolerance", "0.5e-3", "--float-file", "out.f32=f32le"],
        )
    )
    runs.append(
        ["app", "replay", ".", "--build", "env SHIFT=1e-7 python3 wave.py"]
    )
    for i in range(len(runs)):
        assert_equal(_both(t, old, new, runs[i]), "", "fell back")
    # What record and replay refuse.
    var bad: List[String] = [
        "--float-file=out.f32",
        "--float-file=out.f32=f16le",
        "--float-tolerance=1.5",
        "--float-tolerance=1",
    ]
    for b in bad:
        var args = record.copy()
        args.append(b)
        assert_equal(_both(t, old, new, args), "", "fell back")
    var dirs: List[String] = [old, new]
    for d in dirs:
        _ = t["edit_config"](
            PythonObject(d), PythonObject("float_tolerance"), PythonObject(2.5)
        )
    assert_equal(_both(t, old, new, ["app", "replay", "."]), "", "fell back")
    assert_equal(_both(t, old, new, record.copy()), "", "fell back")
    var formats = Python.dict()
    formats["out.f32"] = "f16le"
    for d in dirs:
        _ = t["edit_config"](
            PythonObject(d), PythonObject("float_tolerance"), PythonObject(None)
        )
        _ = t["edit_config"](
            PythonObject(d), PythonObject("float_files"), formats
        )
    assert_equal(_both(t, old, new, ["app", "replay", "."]), "", "fell back")
    _ = t["gone"](PythonObject(old))
    _ = t["gone"](PythonObject(new))


def _keys(t: PythonObject, name: String, odd: String) raises -> String:
    return String(
        py=t["fixture"](
            PythonObject("keys"),
            PythonObject(name),
            t["keys_inputs"](PythonObject(odd)),
        )
    )


def _keys_record() -> List[String]:
    return [
        "app",
        "record",
        ".",
        "--inputs",
        "inputs.jsonl",
        "--no-traps",
        "--normalize",
        "key-order",
        "--",
        "python3",
        "keys.py",
    ]


def test_key_order_matches_the_phase1_binary() raises:
    var t = _py()
    var old = _keys(t, "old", "")
    var new = _keys(t, "new", "")
    var runs = List[List[String]]()
    runs.append(_keys_record())
    runs.append(["app", "replay", "."])
    runs.append(["app", "replay", ".", "--build", "env V=1 python3 keys.py"])
    runs.append(
        ["app", "replay", ".", "--build", "env V=1 python3 keys.py", "--json"]
    )
    for i in range(len(runs)):
        assert_equal(_both(t, old, new, runs[i]), "", "fell back")
    # A replay whose output serde_json may read otherwise: declined after
    # the run.
    var log = _both(
        t,
        old,
        new,
        ["app", "replay", ".", "--build", "env ODD=huge python3 keys.py"],
    )
    assert_true(log != "", "an odd output did not fall back")
    _ = t["gone"](PythonObject(old))
    _ = t["gone"](PythonObject(new))


def test_json_serde_may_read_otherwise_goes_to_the_phase1_binary() raises:
    var t = _py()
    var odd: List[String] = [
        "surrogate",
        "huge",
        "huge-int",
        "tiny",
        "deep-127",
        "deep-128",
    ]
    for o in odd:
        var old = _keys(t, "odd-old", o)
        var new = _keys(t, "odd-new", o)
        var log = _both(t, old, new, _keys_record())
        assert_true(log != "", "did not fall back: " + o)
        _ = t["gone"](PythonObject(old))
        _ = t["gone"](PythonObject(new))


def main() raises:
    test_rust_float_formats()
    test_float_files_and_a_tolerance_match_the_phase1_binary()
    test_key_order_matches_the_phase1_binary()
    test_json_serde_may_read_otherwise_goes_to_the_phase1_binary()
    print("test_app_compare: 4 passed")
