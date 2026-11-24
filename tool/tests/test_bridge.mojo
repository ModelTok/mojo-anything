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
    log = _both(
        t,
        "go",
        "tests/fixtures/go-mojo-ports",
        none,
        _args(".", "textkit/textkit.go"),
    )
    assert_true(log != "", "a Go unit did not fall back")
    _ = t["gone"]()


def test_units_without_exports_match_the_phase1_binary() raises:
    var t = _py()
    var none = List[String]()
    _owned(t, "go-cmd", "tests/fixtures/go", none, _args(".", "cmd/strkit/"))
    _owned(
        t, "ruby-lib", "tests/fixtures/ruby", none, _args(".", "lib/textkit.rb")
    )
    _owned(
        t, "c-probe", "tests/fixtures/mojo-c-probe", none, _args(".", "probe.c")
    )
    _owned(
        t,
        "c-caller",
        "tests/fixtures/mojo-dispatcher",
        none,
        _args(".", "caller.c"),
    )
    var cpp = List[String]()
    cpp.append("CMakeLists.txt=project(k CXX)\n")
    cpp.append("src/k.cpp=static int twice(int x) { return 2 * x; }\n")
    _owned(t, "cpp-static", "", cpp, _args(".", "src/k.cpp"))
    # A Go file whose functions are all unexported has none either.
    var bad = List[String]()
    bad.append("go.mod=module example.com/b\n\ngo 1.22\n")
    bad.append("b.go=package b\n\nfunc f() {}\n")
    var t2 = _both(t, "go-private", "", bad, _args(".", "b.go"))
    assert_equal(t2, "", "fell back in go-private")
    _ = t["gone"]()


def test_c_units_are_bridged_in_mojo() raises:
    """`bridge_c`: port.mojo, exports.mojo and its shadow twin, the header and
    c_structs.mojo, for every way a C parameter crosses (codegen_c `CKind`)."""
    var t = _py()
    var none = List[String]()
    _owned(t, "c-sum", "tests/fixtures/c", none, _args(".", "src/checksum.c"))
    _owned(t, "c-text", "tests/fixtures/c", none, _args(".", "src/text.c"))
    var kinds = List[String]()
    kinds.append("Makefile=all:\n\tcc -c src/k.c\n")
    kinds.append(
        "src/k.h=#include <stdint.h>\n#include <stddef.h>\ntypedef struct {"
        " int num; int den; } Q;\nstruct point { double x, y; };\ntypedef"
        " struct point Pt;\ntypedef uint32_t hash_t;\ntypedef enum { RED,"
        " GREEN } colour;\ntypedef struct { unsigned char tag; char c; int64_t"
        " n; } Tagged;\n"
    )
    kinds.append(
        'src/k.c=#include "k.h"\n\nQ qmul(Q a, Q b) { Q r = { a.num * b.num,'
        " a.den * b.den }; return r; }\n\nstruct point mid(struct point a, Pt"
        " b) { struct point r = { (a.x + b.x) / 2, (a.y + b.y) / 2 }; return"
        " r; }\n\nTagged tag(Tagged t) { return t; }\n\nsize_t copy_into(char"
        " *dst, size_t size, const char *src) { size_t i = 0; for (; src[i] &&"
        " i + 1 < size; i++) dst[i] = src[i]; if (size) dst[i] = 0; return i;"
        " }\n\nint fill(int count, uint8_t *buf, short cap_unused, size_t len)"
        " { (void)count; (void)buf; return (int)len; }\n\nint sum_bytes(const"
        " uint8_t *data, size_t len) { int s = 0; for (size_t i = 0; i < len;"
        " i++) s += data[i]; return s; }\n\nint parse_int(const char *s, char"
        " **end, int *out) { *out = 0; *end = (char *)s; return 0; }\n\nconst"
        " char *skip_ws(const char *s) { while (*s == ' ') s++; return s;"
        " }\n\nchar *dup(const char *s) { return strdup(s); }\n\nhash_t"
        " h(hash_t x) { return x * 31u; }\n\nint shade(colour c) { return"
        " (int)c; }\n\nint sum(int n, ...) { return n; }\n\nstatic int"
        " hidden(int x) { return x; }\n\nvoid reset(void) {}\n\nlong double"
        " big(long double x) { return x; }\n\nint apply(int (*f)(int), int x)"
        " { return f(x); }\n\nint first(const char *s, int n) { return s[0] +"
        " n; }\n\nint ends(char **p) { return 0; }\n\nint nolen(const uint8_t"
        " *p) { return p[0]; }\n\nint nosize(char *p) { return 0; }\n\nint"
        " arr(int xs[]) { return xs[0]; }\n\nstruct big { int a[2]; };\nint"
        " opaque(struct big b) { return 0; }\n\n_Bool yes(signed char a,"
        " unsigned short b, unsigned long long c, ssize_t d, float e) { return"
        " 1; }\n\nint main(void) { return 0; }\n"
    )
    _owned(t, "c-kinds", "", kinds, _args(".", "src/k.c"))
    # Every export stays in C; a function named like a Mojo keyword.
    var stays = List[String]()
    stays.append("Makefile=all:\n")
    stays.append("v.c=int sum(int n, ...) { return n; }\n")
    _owned(t, "c-stays", "", stays, _args(".", "v.c"))
    var keyword = List[String]()
    keyword.append("Makefile=all:\n")
    keyword.append(
        "w.c=int fn(int x) { return x; }\nint ok(int y) { return y; }\n"
    )
    _owned(t, "c-keyword", "", keyword, _args(".", "w.c"))
    var taken = List[String]()
    taken.append("mojo/checksum-mojo/keep.txt=mine\n")
    _owned(
        t, "c-taken", "tests/fixtures/c", taken, _args(".", "src/checksum.c")
    )
    _ = t["gone"]()


def test_failed_writes_match_the_phase1_binary() raises:
    """Review of 069c8e8..ba4490e: `mojo` is a file, so create_dir_all
    fails, and the error is the Rust tool's text."""
    var t = _py()
    var files = List[String]()
    files.append("mojo=not a folder\n")
    _owned(
        t,
        "mojo-file",
        "tests/fixtures/python-mojo-bytes",
        files,
        _args(".", "flip.py"),
    )
    _ = t["gone"]()


def main() raises:
    test_python_fixtures_are_bridged_in_mojo()
    test_python_shapes_match_the_phase1_binary()
    test_bridge_errors_match_the_phase1_binary()
    test_unanswered_bridges_go_to_the_phase1_binary()
    test_units_without_exports_match_the_phase1_binary()
    test_failed_writes_match_the_phase1_binary()
    test_c_units_are_bridged_in_mojo()
    print("test_bridge: 7 passed")
