# `refresh` and the manifest's errors in Mojo (src/bridge.rs
# `Manifest::load` and `refresh`, the `refresh` and `record` arms of
# src/main.rs): a Python unit is bridged by the Phase 1 binary on two copies
# of a fixture, its port.mojo is edited the same way in both, and then each
# binary regenerates one copy; stdout, stderr, the exit code and every file
# must agree, with no fallback logged where the Mojo tool answers.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-refresh-%d" % os.getpid())
PHASE1 = os.path.abspath("tool/fallback/mojo-anything")

def fixture(side, name, source, bridge, files, remove):
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    if source:
        shutil.copytree(source, d, symlinks=True)
    else:
        os.makedirs(d)
    if bridge:
        p = subprocess.run([PHASE1, "bridge", ".", bridge], cwd=d, capture_output=True,
                           stdin=subprocess.DEVNULL, timeout=300)
        assert p.returncode == 0, p.stderr
    for rel, text in files:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="") as f:
            f.write(text)
    for rel in remove:
        os.remove(os.path.join(d, rel))
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

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
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
    var files: List[String]
    var remove: List[String]
    var cwd: String
    var args: List[String]


def _case(name: String, source: String, bridge: String) -> Case:
    var args = List[String]()
    return Case(name, source, bridge, List[String](), List[String](), "", args^)


def _both(t: PythonObject, c: Case) raises -> String:
    var files = Python.list()
    for s in c.files:
        var eq = s.find("=")
        files.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    var remove = Python.list()
    for r in c.remove:
        remove.append(PythonObject(r))
    var dirs = List[String]()
    for side in ["old", "new"]:
        dirs.append(
            String(
                py=t["fixture"](
                    PythonObject(side),
                    PythonObject(c.name),
                    PythonObject(c.source),
                    PythonObject(c.bridge),
                    files,
                    remove,
                )
            )
        )
    var pargs = Python.list()
    var shown = String(" in " + c.name + ":")
    for a in c.args:
        pargs.append(PythonObject(a))
        shown += " " + a
    var o = t["run"](
        PythonObject(FALLBACK),
        pargs,
        PythonObject(dirs[0] + c.cwd),
        PythonObject(""),
    )
    var log = dirs[1] + ".fallback.log"
    var n = t["run"](
        PythonObject(MOJO),
        pargs,
        PythonObject(dirs[1] + c.cwd),
        PythonObject(log),
    )
    assert_equal(String(py=n[1]), String(py=o[1]), "stdout of" + shown)
    assert_equal(String(py=n[2]), String(py=o[2]), "stderr of" + shown)
    assert_equal(Int(py=n[0]), Int(py=o[0]), "exit code of" + shown)
    assert_equal(
        String(py=t["tree"](PythonObject(dirs[1]))),
        String(py=t["tree"](PythonObject(dirs[0]))),
        "files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log)))


def _owned(t: PythonObject, c: Case) raises:
    assert_equal(_both(t, c), "", "fell back in " + c.name)


comptime _CRATE = "mojo/mathkit-mojo"

comptime _EDITED = """# A port with helpers, a renamed function and wrapped signatures.

from std.python import Python, PythonObject


struct Point:
    var x: Int


struct _Hidden:
    var y: Int


def _clamp(x: Float64) -> Float64:
    return x


# Port of `scale`.
@always_inline
def scale_it(
    x: Float64,
    factor: Optional[Float64] = None,
) raises -> Float64:
    return x


def safe_div(var a: Int, mut b: Int) -> Optional[Int]:
    return None


def exclaim(text: String, data: List[UInt8]) raises -> List[UInt8]:
    return data^


def count_items(items: List[Optional[String]], flag: Bool) raises:
    pass


def generic[T: AnyType](x: Int) -> Int:
    return x


def extra(o: PythonObject) raises -> List[List[Bool]]:
    return List[List[Bool]]()
"""


def test_python_refresh_matches_the_phase1_binary() raises:
    var t = _py()
    var c = _case("port", "tests/fixtures/python-mojo", "src/mathkit/")
    c.files.append(
        String(_CRATE, "/port.mojo=")
        + String(
            py=Python.import_module("builtins")
            .open("tests/fixtures/python-mojo-port/port.mojo")
            .read()
        )
    )
    c.args.append("refresh")
    c.args.append(_CRATE)
    _owned(t, c)
    var stubs = _case("stubs", "tests/fixtures/python-mojo", "src/mathkit/")
    stubs.cwd = "/" + _CRATE
    stubs.args.append("refresh")
    _owned(t, stubs)
    var edited = _case("edited", "tests/fixtures/python", "src/textkit/")
    edited.files.append(String("mojo/textkit-mojo/port.mojo=", _EDITED))
    edited.args.append("refresh")
    edited.args.append("./mojo/textkit-mojo/")
    _owned(t, edited)
    var names = _case("names", "tests/fixtures/python-mojo-names", "src/names/")
    names.args.append("refresh")
    names.args.append("mojo/names-mojo")
    _owned(t, names)
    _ = t["gone"]()


def test_refresh_errors_match_the_phase1_binary() raises:
    var t = _py()
    var bad = _case("bad-type", "tests/fixtures/python-mojo", "src/mathkit/")
    bad.files.append(
        String(
            _CRATE,
            (
                "/port.mojo=def f(x: Dict[String, Int]) raises -> Int:\n   "
                " return 1\n"
            ),
        )
    )
    bad.args.append("refresh")
    bad.args.append(_CRATE)
    _owned(t, bad)
    var bad_ret = _case("bad-ret", "tests/fixtures/python-mojo", "src/mathkit/")
    bad_ret.files.append(
        String(
            _CRATE,
            "/port.mojo=def f(x: Int) raises -> Float32:\n    return 1\n",
        )
    )
    bad_ret.args.append("refresh")
    bad_ret.args.append(_CRATE)
    _owned(t, bad_ret)
    var empty = _case("no-def", "tests/fixtures/python-mojo", "src/mathkit/")
    empty.files.append(
        String(_CRATE, "/port.mojo=def _only() -> Int:\n    return 1\n")
    )
    empty.args.append("refresh")
    empty.args.append(_CRATE)
    _owned(t, empty)
    var gone = _case("no-port", "tests/fixtures/python-mojo", "src/mathkit/")
    gone.remove.append(String(_CRATE, "/port.mojo"))
    gone.args.append("refresh")
    gone.args.append(_CRATE)
    _owned(t, gone)
    var none = _case("no-manifest", "", "")
    none.args.append("refresh")
    _owned(t, none)
    var missing = _case("missing", "", "")
    missing.args.append("refresh")
    missing.args.append("missing-dir")
    _owned(t, missing)
    var manifests = List[String]()
    manifests.append('pyo3/mojo-anything.json={"kind": "pyo3", "schema": 1}')
    manifests.append('old/rust-anything.json={"kind": "napi"}')
    var base = String(
        '{"schema": "mojo-anything/bridge@1", "root": "..", "unit": "u",'
        ' "crate_name": "u-mojo", "exports": [], '
    )
    manifests.append(
        String(
            "jni/mojo-anything.json=",
            base,
            '"language": "java", "kind": "ffi"}',
        )
    )
    manifests.append(
        String(
            "cabi/mojo-anything.json=",
            base,
            '"language": "c", "kind": "c-abi"}',
        )
    )
    manifests.append("cabi/Cargo.toml=[package]\n")
    manifests.append(
        String(
            "jvm/mojo-anything.json=",
            base,
            '"language": "java", "kind": "mojo-jvm"}',
        )
    )
    manifests.append("jvm/Cargo.toml=[package]\n")
    manifests.append(
        String(
            "go/mojo-anything.json=", base, '"language": "go", "kind": "ffi"}'
        )
    )
    manifests.append("go/Cargo.toml=[package]\n")
    manifests.append(
        String(
            "php/mojo-anything.json=", base, '"language": "php", "kind": "ffi"}'
        )
    )
    manifests.append(String("ts/mojo-anything.json=", base, '"kind": "ffi"}'))
    for dir in ["pyo3", "old", "jni", "cabi", "jvm", "go", "php", "ts"]:
        var c = _case(String("manifest-", dir), "", "")
        c.files = manifests.copy()
        c.args.append("refresh")
        c.args.append(dir)
        _owned(t, c)
    _ = t["gone"]()


def test_record_load_errors_match_the_phase1_binary() raises:
    var t = _py()
    var none = _case("record-none", "", "")
    none.args.append("record")
    _owned(t, none)
    var missing = _case("record-missing", "", "")
    missing.args.append("record")
    missing.args.append("missing-dir")
    missing.args.append("--count")
    missing.args.append("3")
    _owned(t, missing)
    var rest = _case("record-rest", "", "")
    rest.args.append("record")
    rest.args.append(".")
    rest.args.append("--")
    rest.args.append("pytest")
    _owned(t, rest)
    _ = t["gone"]()


def test_unanswered_go_to_the_phase1_binary() raises:
    var t = _py()
    var batch = _case("batch", "tests/fixtures/python-mojo", "src/mathkit/")
    batch.args.append("refresh")
    batch.args.append(_CRATE)
    batch.args.append("--batch")
    batch.args.append("scale:x")
    assert_true(_both(t, batch) != "", "--batch did not fall back")
    var lib = _case("lib", "tests/fixtures/lib", "ts/src/nums.ts")
    lib.args.append("refresh")
    lib.args.append("mojo/nums-mojo")
    assert_true(_both(t, lib) != "", "a mojo-node refresh did not fall back")
    var rec = _case("record", "tests/fixtures/python-mojo", "src/mathkit/")
    rec.args.append("record")
    rec.args.append(_CRATE)
    rec.args.append("--count")
    rec.args.append("2")
    assert_true(_both(t, rec) != "", "a recording did not fall back")
    _ = t["gone"]()


def main() raises:
    test_python_refresh_matches_the_phase1_binary()
    test_refresh_errors_match_the_phase1_binary()
    test_record_load_errors_match_the_phase1_binary()
    test_unanswered_go_to_the_phase1_binary()
    print("test_refresh: 4 passed")
