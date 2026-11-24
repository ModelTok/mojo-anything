# `bridge` in Mojo (src/bridge.rs, src/codegen_mojo.rs,
# src/codegen_mojo_py.rs): the Mojo binary runs next to the Phase 1 binary on
# copies of the same repository (the fixtures under tests/fixtures/, and small
# ones written here), and the two must agree on stdout, stderr, the exit code
# and every file written, byte for byte, with no fallback logged; the cases
# the Mojo tool does not answer must log one.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-bridge-%d" % os.getpid())

def fixture(side, name, source, files):
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    if source:
        shutil.copytree(source, d, symlinks=True)
    else:
        os.makedirs(d)
    for rel, text in files:
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="") as f:
            f.write(text)
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


def _files(spec: List[String]) raises -> PythonObject:
    var out = Python.list()
    for s in spec:
        var eq = s.find("=")
        out.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    return out


def _both(
    t: PythonObject,
    name: String,
    source: String,
    spec: List[String],
    args: List[String],
) raises -> String:
    """Runs both binaries on fresh copies; returns the Mojo run's fallback
    log."""
    var files = _files(spec)
    var src = PythonObject(source)
    var old = String(
        py=t["fixture"](PythonObject("old"), PythonObject(name), src, files)
    )
    var new = String(
        py=t["fixture"](PythonObject("new"), PythonObject(name), src, files)
    )
    var pargs = Python.list()
    var shown = String(" in " + name + ":")
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


def _owned(
    t: PythonObject,
    name: String,
    source: String,
    spec: List[String],
    args: List[String],
) raises:
    assert_equal(_both(t, name, source, spec, args), "", "fell back in " + name)


def _args(a: String, b: String) -> List[String]:
    var out = List[String]()
    out.append("bridge")
    out.append(a)
    out.append(b)
    return out^


def test_python_fixtures_are_bridged_in_mojo() raises:
    var t = _py()
    var none = List[String]()
    _owned(
        t, "python", "tests/fixtures/python", none, _args(".", "src/textkit/")
    )
    _owned(
        t,
        "mojo",
        "tests/fixtures/python-mojo",
        none,
        _args(".", "src/mathkit/"),
    )
    _owned(
        t,
        "bytes",
        "tests/fixtures/python-mojo-bytes",
        none,
        _args(".", "flip.py"),
    )
    _owned(
        t,
        "names",
        "tests/fixtures/python-mojo-names",
        none,
        _args(".", "src/names/"),
    )
    # One source file of a unit, given with `./`, and a root given by path.
    _owned(
        t,
        "single",
        "tests/fixtures/python",
        none,
        _args(".", "./src/textkit/stack.py"),
    )
    _owned(
        t,
        "rooted",
        "tests/fixtures/python-mojo",
        none,
        _args("./", "src/mathkit"),
    )
    _ = t["gone"]()


def test_python_shapes_match_the_phase1_binary() raises:
    var t = _py()
    var files = List[String]()
    files.append(
        'pyproject.toml=[project]\nname = "shapes"\nversion = "0.1.0"\n'
    )
    files.append("src/shapes/__init__.py=from .core import *\n")
    files.append(
        'src/shapes/core.py="""Shapes."""\nimport math\nfrom typing'
        " import Optional, Union, Literal, Any\n\n\ndef area(r, scale=1.5, *,"
        " label: str = 'x', flag=True, n=1_000) -> float:\n    return math.pi *"
        " r * r * scale\n\n\ndef pick(kind: Literal['a', \"b\"], v: Union[int,"
        " str], o: Optional[list[float]] = None) -> dict[str, Any]:\n    return"
        " {}\n\n\ndef blob(data: bytes, t: tuple[int, int]) -> set[int]:\n   "
        " return set()\n\n\ndef nothing(x: int) -> None:\n    pass\n\n\nasync"
        " def later(x: int) -> int:\n    return x\n\n\n@lru_cache\ndef"
        " cached(n: int) -> int:\n    return n\n\n\n@other.deco(1)\ndef"
        " decorated(n: int) -> int:\n    return n\n\n\ndef cb(f:"
        " Callable[[int], int]) -> int:\n    return 0\n\n\ndef rx(p:"
        " re.Pattern) -> RegExp:\n    return p\n\n\ndef upperCase(HTTPServer:"
        " str, x2Y: int) -> str:\n    return HTTPServer\n\n\ndef only(a, /, b,"
        " *c, d, **e):\n    return a\n\n\nclass Point:\n    def __init__(self,"
        " x: float = 0.0):\n        self._x = x\n\n    def norm(self) ->"
        " float:\n        return self._x\n\n    def copy(self) -> 'Point':\n   "
        "     return self\n\n\nclass Kid(Point):\n    pass\n\n\nclass Gen:\n   "
        " def items(self):\n        yield 1\n\n\nclass Dunder:\n    def"
        " __repr__(self):\n        return ''\n\n    @property\n    def"
        " size(self) -> int:\n        return 1\n\n\nif __name__ =="
        " '__main__':\n    area(1)\n"
    )
    _owned(t, "shapes", "", files, _args(".", "src/shapes/"))
    var main = List[String]()
    main.append(
        "app/__main__.py=def run(x: int) -> int:\n    return x\n\nrun(1)\n"
    )
    main.append("app/tool.py=def keep(x: int) -> int:\n    return x\n")
    _owned(t, "main", "", main, _args(".", "app/"))
    var dunder = List[String]()
    dunder.append(
        "m.py=__all__ = ['a', \"_b\"]\n\n\ndef a(x: int) -> int:\n    return"
        " x\n\n\ndef _b(y: str) -> str:\n    return y\n\n\ndef c(z: int) ->"
        " int:\n    return z\n"
    )
    _owned(t, "dunder", "", dunder, _args(".", "m.py"))
    _ = t["gone"]()


def test_bridge_errors_match_the_phase1_binary() raises:
    var t = _py()
    var none = List[String]()
    _owned(t, "missing", "", none, _args("missing-dir", "unit"))
    _owned(t, "empty", "", none, _args(".", "nope"))
    _owned(t, "nounit", "tests/fixtures/python", none, _args(".", "src/nope/"))
    _owned(t, "php", "tests/fixtures/php", none, _args(".", "src/Text/"))
    _owned(t, "csharp", "tests/fixtures/csharp", none, _args(".", "src/Text/"))
    var gen = List[String]()
    gen.append("g.py=def walk(xs):\n    for x in xs:\n        yield x\n")
    _owned(t, "stays", "", gen, _args(".", "g.py"))
    var private = List[String]()
    private.append("p.py=def _hidden(x):\n    return x\n")
    _owned(t, "private", "", private, _args(".", "p.py"))
    var twice = List[String]()
    twice.append("pkg/__init__.py=\n")
    twice.append("pkg/a.py=def f(x: int) -> int:\n    return x\n")
    twice.append("pkg/b.py=def f(x: int) -> int:\n    return x\n")
    _owned(t, "twice", "", twice, _args(".", "pkg/"))
    var taken = List[String]()
    taken.append("mojo/flip-mojo/keep.txt=mine\n")
    _owned(
        t,
        "taken",
        "tests/fixtures/python-mojo-bytes",
        taken,
        _args(".", "flip.py"),
    )
    _ = t["gone"]()


def test_unanswered_bridges_go_to_the_phase1_binary() raises:
    var t = _py()
    var none = List[String]()
    var kind = _args(".", "flip.py")
    kind.append("--kind")
    kind.append("node")
    var log = _both(t, "kind", "tests/fixtures/python-mojo-bytes", none, kind)
    assert_true(log != "", "--kind did not fall back")
    var broken = List[String]()
    broken.append("b.py=def f(x: int) -> int:\n    return (x\n")
    # analyze declines a syntax error, so bridge does too.
    log = _both(t, "broken", "", broken, _args(".", "b.py"))
    assert_true(log != "", "a syntax error did not fall back")
    log = _both(t, "go", "tests/fixtures/go", none, _args(".", "cmd/strkit/"))
    assert_true(log != "", "a Go unit did not fall back")
    _ = t["gone"]()


def main() raises:
    test_python_fixtures_are_bridged_in_mojo()
    test_python_shapes_match_the_phase1_binary()
    test_bridge_errors_match_the_phase1_binary()
    test_unanswered_bridges_go_to_the_phase1_binary()
    print("test_bridge: 4 passed")
