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

def made(name):
    # 1 when the Mojo run wrote a crate (a mojo-anything.json somewhere).
    for base, dirs, files in os.walk(os.path.join(BASE, "new", name)):
        if "mojo-anything.json" in files:
            return 1
    return 0

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        # Folders too, so an empty one left behind shows.
        for sub in dirs:
            out.append((os.path.relpath(os.path.join(base, sub), d) + "/", b""))
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
    var go_batch = _args(".", "textkit/textkit.go")
    go_batch.append("--batch")
    go_batch.append("Echo:s")
    log = _both(t, "go", "tests/fixtures/go-mojo-ports", none, go_batch)
    assert_true(log != "", "--batch on a Go unit did not fall back")
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


def test_cpp_units_are_bridged_in_mojo() raises:
    """`bridge_cpp`: port.mojo, exports.mojo, cpp/shim.cpp and
    cpp/wrapper.cpp, and the reason each refused function stays in C++."""
    var t = _py()
    var none = List[String]()
    _owned(t, "cpp-kit", "tests/fixtures/cpp", none, _args(".", "src/kit.cpp"))
    _owned(
        t,
        "cpp-mixed",
        "tests/fixtures/cpp-mixed",
        none,
        _args(".", "src/mixed.cpp"),
    )
    var kinds = List[String]()
    kinds.append("CMakeLists.txt=project(k CXX)\n")
    kinds.append(
        "src/k.hpp=#include <string>\n#include <vector>\nusing Real ="
        " double;\ntypedef long Count;\nstruct State { int n; void tick(); };\n"
    )
    kinds.append(
        'src/k.cpp=#include "k.hpp"\n#include <stdexcept>\nusing namespace'
        " std;\n\nnamespace kit {\nnamespace text {\n\nstring join(const"
        " vector<string> &xs) { return xs.empty() ? string() : xs[0];"
        " }\n\nstd::string upper(const std::string &s /* the text */) { return"
        " s; }\n\nint count(const std::string s, // the input\n          char"
        " c) { return 0; }\n\n}  // namespace text\n\nstd::vector<double>"
        " scale(const std::vector<double> &xs, Real k) { return xs;"
        " }\n\nvector<long> ids(vector<int64_t> xs, Count n) { return {};"
        " }\n\nbool positive(double x) { return x > 0; }\n\nvoid nothing()"
        " {}\n\nunsigned long long big(unsigned short a, signed char b, float"
        " c, size_t d) { return 0; }\n\ninline int twice(int x) { return 2 * x;"
        " }\n\nconstexpr int thrice(int x) { return 3 * x; }\n\ntemplate"
        " <typename T> T id(T x) { return x; }\n\ntemplate <typename T> struct"
        ' Box { T v; };\n\nextern "C" int plain(int x) { return x; }\n\nvoid'
        " State::tick() {}\n\nint over(int x) { return x; }\nint over(double x)"
        " { return 0; }\n\nint ptr(int *p) { return *p; }\n\nint state(State"
        " *s) { return 0; }\n\nint by_ref(State &s) { return 0; }\n\nvoid"
        " fill(std::vector<int> &out) {}\n\nint moved(std::string &&s) { return"
        " 0; }\n\nint call(int (*f)(int)) { return f(1); }\n\nint vol(volatile"
        " int x) { return x; }\n\nint bits(std::vector<bool> b) { return 0;"
        " }\n\nint ld(long double x) { return 0; }\n\nint *where(int x) {"
        " static int y; return &y; }\n\nconst std::string &name() { static"
        " std::string s; return s; }\n\nauto guess(int x) { return x;"
        " }\n\nState make() { return State(); }\n\nint arr(int xs[]) { return"
        " 0; }\n\nint varargs(int n, ...) { return n; }\n\nclass Meter {"
        " public: int read() const { return 0; } };\n\nnamespace {\nint"
        " hidden(int x) { return x; }\n}\n\nstatic int also_hidden(int x) {"
        " return x; }\n\n}  // namespace kit\n\nnamespace other {\nbool"
        " positive(double x) { return x > 0; }\n}\n\nint main() { return 0; }\n"
    )
    _owned(t, "cpp-kinds", "", kinds, _args(".", "src/k.cpp"))
    var stays = List[String]()
    stays.append("CMakeLists.txt=project(k CXX)\n")
    stays.append("v.cpp=inline int f(int x) { return x; }\n")
    _owned(t, "cpp-stays", "", stays, _args(".", "v.cpp"))
    var taken = List[String]()
    taken.append("mojo/kit-mojo/keep.txt=mine\n")
    _owned(
        t, "cpp-taken", "tests/fixtures/cpp", taken, _args(".", "src/kit.cpp")
    )
    _ = t["gone"]()


def _with(var args: List[String], extra: List[String]) -> List[String]:
    for a in extra:
        args.append(a)
    return args^


def test_bridge_flags_match_the_phase1_binary() raises:
    """`--keep`, `--name`, `--out`/`-o`, `--as-json` and `--kind wasm` on
    the languages bridged in Mojo."""
    var t = _py()
    var none = List[String]()
    var py = List[String]()
    py.append("--keep")
    py.append("scale")
    py.append("--name")
    py.append("mk")
    py.append("--as-json")
    py.append("T")
    _owned(
        t,
        "py-flags",
        "tests/fixtures/python-mojo",
        none,
        _with(_args(".", "src/mathkit/"), py),
    )
    var out = List[String]()
    out.append("-o")
    out.append("ports/mk/")
    _owned(
        t,
        "py-out",
        "tests/fixtures/python-mojo",
        none,
        _with(_args(".", "src/mathkit/"), out),
    )
    var c = List[String]()
    c.append("--keep")
    c.append("fnv1a: hashed elsewhere ")
    c.append("--keep")
    c.append("clamp:")
    c.append("--name")
    c.append("sums")
    c.append("--out")
    c.append("out/sums")
    _owned(
        t,
        "c-flags",
        "tests/fixtures/c",
        none,
        _with(_args(".", "src/checksum.c"), c),
    )
    var cpp = List[String]()
    cpp.append("--keep")
    cpp.append("kit::add")
    cpp.append("--keep")
    cpp.append(" kit::shout : loud")
    _owned(
        t,
        "cpp-flags",
        "tests/fixtures/cpp",
        none,
        _with(_args(".", "src/kit.cpp"), cpp),
    )
    # Keeping every export, and a `--name` taken by a port in progress.
    var all = List[String]()
    all.append("--keep")
    all.append("adler32")
    var stays = List[String]()
    stays.append("Makefile=all:\n")
    stays.append("a.c=int adler32(int x) { return x; }\n")
    _owned(t, "c-all-kept", "", stays, _with(_args(".", "a.c"), all))
    var taken = List[String]()
    taken.append("mojo/mine/keep.txt=mine\n")
    var named = List[String]()
    named.append("--name")
    named.append("mine")
    _owned(
        t,
        "c-name-taken",
        "tests/fixtures/c",
        taken,
        _with(_args(".", "src/checksum.c"), named),
    )
    var wasm = List[String]()
    wasm.append("--kind")
    wasm.append("wasm")
    _owned(
        t,
        "py-wasm",
        "tests/fixtures/python-mojo",
        none,
        _with(_args(".", "src/mathkit/"), wasm),
    )
    _owned(
        t,
        "c-wasm",
        "tests/fixtures/c",
        none,
        _with(_args(".", "src/checksum.c"), wasm),
    )
    var batch = List[String]()
    batch.append("--batch")
    batch.append("adler32:data")
    var log = _both(
        t,
        "c-batch",
        "tests/fixtures/c",
        none,
        _with(_args(".", "src/checksum.c"), batch),
    )
    assert_true(log != "", "--batch did not fall back")
    _ = t["gone"]()


comptime _GO_SHAPES = """package shapes

import "errors"

// Point is a point.
type Point struct {
	X      float64 `json:"x"`
	Y      float64 `json:"y,omitempty"`
	hidden int
	Skip   int `json:"-"`
	Label  string
}

// Box embeds a Point.
type Box struct {
	Point
	W int
}

type Tags map[string][]string

func Dist(a Point, b Point) float64 { return 0 }

func Scale(p Point, k float64) (Point, error) { return p, nil }

func Split(s string, sep string) ([]string, int) { return nil, 0 }

func Check(ok bool) error {
	if !ok {
		return errors.New("no")
	}
	return nil
}

func Nothing() {}

func Widths(b byte, r rune, u uint, u8 uint8, i8 int8, i16 int16, i32 int32, f32 float32, up uintptr) (uint64, error) {
	return 0, nil
}

func Name(_ string, x int) (string, error) { return "", nil }

func Unnamed(int, string) bool { return true }

func Pair(a, b int) (x, y int) { return a, b }

func Counts(m map[string]int) map[string][]int { return nil }

func Boxed(b Box) Box { return b }

func Tagged(t Tags) Tags { return t }

func Grow(s Size) Size { return s }

func Ptr(p *Point) int { return 0 }

func Fn(f func(int) int) int { return 0 }

func Ch(c chan int) {}

func Any(v any) {}

func Arr(a [3]int) {}

func Err(e error) {}

func Other(d time.Duration) {}

func Keys(m map[int]string) {}

func Gen[T any](x T) T { return x }

func Var(xs ...int) int { return 0 }

func lower(x int) int { return x }

func (p Point) Method() int { return 0 }

func Commented(a int /* the a */, b int) int { return a }

func   Spaced(  a   int,
	b int ) int { return a }
"""

comptime _GO_SIZE = """package shapes

// Size is a width.
type Size int

type unused struct{ A int }
"""

comptime _GO_CALC = """package calc

func Add(a int, b int) int { return a + b }

func Neg(b bool) (bool, error) { return !b, nil }

func Clean(path string) string { return path }

func Ratio(a float32, b float64) float64 { return b }

func Ok() error { return nil }

func Do(x int8) {}

func Big(x uint) uint { return x }
"""

comptime _RUBY_KIT = """# frozen_string_literal: true

module Kit
  # Mixes things.
  #
  # @param text [String]
  # @param sep [String, nil]
  # @param n [Array<Integer>]
  # @return [Hash{String => Array<Float>}]
  def self.mix(text, sep = nil, n = [], flag: true, limit: 1_000, rate: 1.5, big: +5, e: 1e3, name: "x", sym: :a, req:)
    {}
  end

  # @param a [Integer, Float]
  # @return [Hash{Symbol => Integer}]
  def self.weird(a, b = 2)
    a * b + 1
  end

  def self.math(x, y)
    x - y
  end

  def self.cmp(a, b)
    a < 3
  end

  def self.splat(*args) end
  def self.opts(**o) end
  def self.blk(&b) end

  def self.yields(x)
    yield x
  end

  def self.bang!(x) x end
  def self.set=(x) end
  def self.empty?(x) x end
  def self.Upper(x) x end

  class << self
    def inside(a) a end

    private

    def hidden(a) a end
  end

  module Inner
    module_function

    # @param a [Array]
    # @return [Boolean]
    def one(a) a end

    private

    def two(a) a end
  end

  module Late
    def a(x) x end
    def b(x) x end
    module_function :a
  end

  class Tool
    def self.make(n) n end
    def self.secret(n) n end
    private_class_method :secret

    def instance(x) x end
  end
end
"""


def _made(
    t: PythonObject,
    name: String,
    source: String,
    spec: List[String],
    args: List[String],
) raises:
    """`_owned`, and the run wrote a crate (not an error both binaries
    agree on)."""
    _owned(t, name, source, spec, args)
    assert_equal(
        Int(py=t["made"](PythonObject(name))), 1, "no crate in " + name
    )


def _forced(a: String, b: String) -> List[String]:
    var out = _args(a, b)
    out.append("--force")
    return out^


def test_go_and_ruby_units_are_bridged_in_mojo() raises:
    """`bridge_ffi_mojo`: port.mojo, exports.mojo (typed calls and the JSON
    dispatcher), the cgo wrapper after gofmt, and for Ruby the dispatcher,
    the Fiddle module and the wrapper with the original module functions."""
    var t = _py()
    var none = List[String]()
    _made(
        t,
        "go-ports",
        "tests/fixtures/go-mojo-ports",
        none,
        _args(".", "textkit/textkit.go"),
    )
    _made(t, "go-strkit", "tests/fixtures/go", none, _args(".", "strkit/"))
    var shapes = List[String]()
    shapes.append("go.mod=module example.com/shapes\n\ngo 1.22\n")
    shapes.append(String("shapes/shapes.go=", _GO_SHAPES))
    shapes.append(String("shapes/size.go=", _GO_SIZE))
    shapes.append("shapes/shapes_test.go=package shapes\n\nfunc TestX() {}\n")
    _made(t, "go-shapes", "", shapes, _forced(".", "shapes/"))
    _made(t, "go-shapes-file", "", shapes, _forced(".", "shapes/shapes.go"))
    var calc = List[String]()
    calc.append("go.mod=module example.com/calc\n\ngo 1.22\n")
    calc.append(String("calc.go=", _GO_CALC))
    _made(t, "go-calc", "", calc, _forced(".", "calc.go"))
    var stays = List[String]()
    stays.append("go.mod=module example.com/v\n\ngo 1.22\n")
    stays.append("v.go=package v\n\nfunc V(xs ...int) int { return 0 }\n")
    _owned(t, "go-stays", "", stays, _forced(".", "v.go"))
    var twice = List[String]()
    twice.append("go.mod=module example.com/w\n\ngo 1.22\n")
    twice.append("w/a.go=package w\n\nfunc F(x int) int { return x }\n")
    twice.append("w/b.go=package w\n\nfunc F(x int) int { return x }\n")
    _owned(t, "go-twice", "", twice, _forced(".", "w/"))
    var taken = List[String]()
    taken.append("mojo/textkit-mojo/keep.txt=mine\n")
    _owned(
        t,
        "go-taken",
        "tests/fixtures/go-mojo-ports",
        taken,
        _args(".", "textkit/textkit.go"),
    )
    _made(
        t,
        "rb-ports",
        "tests/fixtures/ruby-mojo-ports",
        none,
        _args(".", "textkit/lib/textkit.rb"),
    )
    _made(t, "rb-lib", "tests/fixtures/ruby", none, _args(".", "lib/textkit/"))
    _made(
        t,
        "rb-words",
        "tests/fixtures/ruby",
        none,
        _args(".", "lib/textkit/words.rb"),
    )
    var kit = List[String]()
    kit.append("Gemfile=source 'https://rubygems.org'\n")
    kit.append(String("lib/kit.rb=", _RUBY_KIT))
    _made(t, "rb-kit", "", kit, _forced(".", "lib/kit.rb"))
    # Review of 473398e..8eabb18: a default past CPython's 4300-digit limit
    # for int() is a number to Rust (parse::<f64> gives inf).
    var digits = String("")
    for _ in range(5000):
        digits += "1"
    var long = List[String]()
    long.append("Gemfile=source 'https://rubygems.org'\n")
    long.append(
        String(
            "l.rb=module L\n  def self.f(x = ", digits, ")\n    x\n  end\nend\n"
        )
    )
    _made(t, "rb-long", "", long, _forced(".", "l.rb"))
    var rb_stays = List[String]()
    rb_stays.append("Gemfile=source 'https://rubygems.org'\n")
    rb_stays.append("s.rb=module S\n  def self.each(&b) end\nend\n")
    _owned(t, "rb-stays", "", rb_stays, _forced(".", "s.rb"))
    # Flags: --keep with and without a reason, --name, --out.
    var go_flags = List[String]()
    go_flags.append("--keep")
    go_flags.append("Echo")
    go_flags.append("--keep")
    go_flags.append("Pair: two results")
    go_flags.append("--name")
    go_flags.append("tk")
    go_flags.append("--out")
    go_flags.append("ports/tk")
    _made(
        t,
        "go-flags",
        "tests/fixtures/go-mojo-ports",
        none,
        _with(_args(".", "textkit/textkit.go"), go_flags),
    )
    var rb_flags = List[String]()
    rb_flags.append("--keep")
    rb_flags.append("half:floats")
    rb_flags.append("--name")
    rb_flags.append("rk")
    _made(
        t,
        "rb-flags",
        "tests/fixtures/ruby-mojo-ports",
        none,
        _with(_args(".", "textkit/lib/textkit.rb"), rb_flags),
    )
    var wasm = List[String]()
    wasm.append("--kind")
    wasm.append("wasm")
    _owned(
        t,
        "go-wasm",
        "tests/fixtures/go-mojo-ports",
        none,
        _with(_args(".", "textkit/textkit.go"), wasm),
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
    test_cpp_units_are_bridged_in_mojo()
    test_bridge_flags_match_the_phase1_binary()
    test_go_and_ruby_units_are_bridged_in_mojo()
    print("test_bridge: 10 passed")
