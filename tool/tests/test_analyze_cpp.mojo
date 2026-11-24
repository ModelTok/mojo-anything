# `analyze` of C++ workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/cpp.rs read through tree-sitter's Python bindings, src/risks.rs,
# the crate table and bridge::js_only_reason): the Mojo binary runs next to
# the Phase 1 binary on copies of the same project, and the two must agree
# byte for byte with no fallback logged; a file tree-sitter may read
# otherwise goes to the Phase 1 binary.

from std.python import Python, PythonObject
from std.testing import assert_equal


comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

def fixture(side, name, files):
    base = os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-tree-%d" % os.getpid(), side)
    d = os.path.join(base, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for rel, text in files:
        p = os.path.join(d, rel)
        if rel.endswith("/"):
            os.makedirs(p, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        if text.startswith("link:"):
            os.symlink(text[5:].rstrip(), p)
            continue
        if text.startswith("b64:"):
            import base64
            with open(p, "wb") as f:
                f.write(base64.b64decode(text[4:]))
            continue
        with open(p, "w", newline="") as f:
            f.write(text)
    return d

def gone():
    shutil.rmtree(os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-tree-%d" % os.getpid()),
                  ignore_errors=True)

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for f in files:
            p = os.path.join(base, f)
            if f.endswith(".fallback.log"):
                continue
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read()))
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
    """Pairs of (path, text) from `path=text` strings; `dir/` makes a folder."""
    var out = Python.list()
    for s in spec:
        var eq = s.find("=")
        if eq < 0:
            out.append(Python.tuple(PythonObject(s), PythonObject("")))
        else:
            out.append(
                Python.tuple(
                    PythonObject(String(s[byte=0:eq])),
                    PythonObject(String(s[byte = eq + 1 :])),
                )
            )
    return out


def _both(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises -> String:
    """Runs both binaries on fresh copies of the project; returns the Mojo
    run's fallback log."""
    var files = _files(spec)
    var old = String(
        py=t["fixture"](PythonObject("old"), PythonObject(name), files)
    )
    var new = String(
        py=t["fixture"](PythonObject("new"), PythonObject(name), files)
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


def _both_ways(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises:
    """Markdown and `--json`, both owned by Mojo."""
    assert_equal(_both(t, name, spec, args), "", "fell back in " + name)
    var j = args.copy()
    j.append("--json")
    assert_equal(_both(t, name, spec, j), "", "fell back in " + name)


comptime _KIT_HPP = """#pragma once
#include <cstdint>
#include <string>
#include <vector>
using Real64 = double;
typedef Real64 Kelvin;
typedef std::int64_t Wide;
using Nothing = void;
struct State { int n; };
class Engine;
namespace kit {
int add(int a, int b);
}
"""

comptime _KIT_CPP = """#include "kit.hpp"
#include "util/helpers.hpp"
#include <vector>
#include <string>
#include <boost/any.hpp>
#include <regex>
#include <zlib.h>
#include "missing.hpp"

using namespace std;

namespace kit {
int add(int a, int b) { return a + b; }
std::int64_t wide(std::int64_t a, unsigned long b) { return a / b; }
double mean(const std::vector<double> &xs) {
    double s = 0;
    for (double x : xs) s += x;
    return s / xs.size();
}
std::vector<int> evens(std::vector<int> xs) { return xs; }
bool upper(const std::string &s) { return s.size() % 2 == 0; }
string shout(string s) { return s; }
void touch() {}
Kelvin warm(Real64 t, const vector<Real64> &ts) { return t; }
Wide widen(Wide w) { return w; }
VendorReal far(VendorReal v) { return v; }
Nothing none() {}
namespace text {
std::string join(std::vector<std::int64_t> const &xs, const std::string &sep) { return sep; }
}
int count(State s) { return s.n; }
}
namespace a::b { float half(const float x) { return x / 2; } }
double kit::later(double x) { return x; }
"""

comptime _REFUSED_CPP = """#include <map>
#include <string>
#include <vector>

struct Data { double timestep = 0.25; };

class Counter {
public:
    int bump(int n) { total += n; return total; }
    int total = 0;
};

struct Meter { double read() const; };
double Meter::read() const { return 1.0; }
int Engine::run() { return 0; }

class Plain { int x; };
struct WithDecl { int get(); };
class Gauge { public: int read(); } gauge;
template <typename T> class Box { T v; };

template <typename T>
T twice(T x) { return x + x; }

int pick(int x) { return x; }
int pick(double x) { return static_cast<int>(x); }

namespace x { int same(int a) { return a; } }
namespace y { int same(int b) { return b; } }

double step(Data &state, double dt) { return state.timestep * dt; }
double peek(const Data *state) { return state->timestep; }
void bump(int &n) { n++; }
std::string take(std::string &&s) { return s; }
const char *name() { return "refused"; }
int &first(int &x) { return x; }
inline int fast(int x) { return x; }
constexpr int square(int x) { return x * x; }
int sizes(const std::map<std::string, int> &m) { return static_cast<int>(m.size()); }
int flags(const std::vector<bool> &v) { return static_cast<int>(v.size()); }
int widen(long double x) { return static_cast<int>(x); }
int total(int n, ...) { return n; }
auto deduced(int x) { return x; }
int arr(int xs[]) { return xs[0]; }
int apply(int (*f)(int)) { return f(1); }
int vol(volatile int x) { return x; }
int nostd(string s) { return 0; }
int vecs(vector<int> v) { return 0; }
int only_void(void) { return 0; }
bool operator==(const Data &a, const Data &b) { return true; }

extern "C" int c_one(int x) { return x; }
extern "C" {
int c_two(int x) { return x; }
int c_three(int y) { return y; }
}

static int hidden(int x) { return x; }

namespace {
int anonymous(int x) { return hidden(x); }
}

int kept(int x) { return anonymous(x); }

int main() { return 0; }
"""

comptime _RISKY_CPP = """#include <cstdlib>
#include <cstring>
#include <csetjmp>
#include <thread>
#include <mutex>
#include <unordered_map>
#include <stdexcept>

struct Base { virtual ~Base() {} };
struct Derived : Base { int v = 0; };

int risky(int *p, int n) {
    int *q = new int(3);
    delete q;
    void *m = std::malloc(8);
    std::memcpy(m, p, 4);
    free(m);
    char buf[8];
    std::strcpy(buf, "x");
    int len = strlen(buf);
    std::thread t;
    std::mutex mu;
    std::unordered_map<int, int> seen;
    if (n % 3 == 0) std::exit(1);
    if (n < 0) abort();
    try { throw std::runtime_error("x"); } catch (...) {}
    int *z = nullptr;
    long w = (long)n;
    for (int i = 0; i < n; i++) { n--; }
    for (int x : {1, 2}) { n += x; }
    while (n > 0) { n--; }
    do { n++; } while (n < 3);
    return *p / 2 + len + (int)w;
}

#define SQ(x) ((x) * (x))
"""


def _kit_project() -> List[String]:
    return [
        "CMakeLists.txt=project(kit)\n",
        "src/kit.hpp=" + _KIT_HPP,
        "src/kit.cpp=" + _KIT_CPP,
        "src/refused.cpp=" + _REFUSED_CPP,
        "src/risky.cc=" + _RISKY_CPP,
        "src/util/helpers.hpp=int helper(int x);\n",
        (
            'src/util/helpers.cxx=#include "helpers.hpp"\n#include'
            ' "../kit.hpp"\nint helper(int x) { return kit::add(x, 1); }\n'
        ),
        "src/only.hh=#include <vector>\nint lonely();\n",
        "src/plain.h=int plain;\n",
        (
            'src/main.cpp=#include "kit.hpp"\nint main() { return kit::add(1,'
            " 2); }\n"
        ),
        (
            'tests/test_kit.cpp=#include "../src/kit.hpp"\nint main() { return'
            " kit::add(1, 2); }\n"
        ),
        "src/kit_test.cc=int t() { return 0; }\n",
        "lib/CMakeLists.txt=project(lib)\n",
        (
            'lib/src/lib.cpp=#include "lib.hpp"\nint lib(int x) { return x /'
            " 3; }\n"
        ),
        "lib/src/lib.hpp=int lib(int x);\n",
        "vendor/v.hpp=using VendorReal = double;\n",
        "vendor/v.cpp=int v() { return 0; }\n",
        "build/gen.cpp=int gen() { return 0; }\n",
        ".hidden/h.cpp=int h() { return 0; }\n",
    ]


def test_cpp_plans_match_the_phase1_binary() raises:
    """Build folders, units, merged headers, waves, risks, exports (the
    subset, classes, members, templates, overloads, linkage), tests and
    dependencies of C++ workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(t, "kit", _kit_project(), dot)
    _both_ways(
        t,
        "cycle",
        [
            'a.cpp=#include "b.hpp"\nint a(int x) { return b(x); }\n',
            'b.cpp=#include "a.hpp"\nint b(int x) { return a(x); }\n',
            "a.hpp=int a(int x);\n",
            "b.hpp=int b(int x);\n",
            "c.h=int c;\n",
        ],
        ["analyze", ".", "--lang", "cpp"],
    )
    var many = List[String]()
    many.append("Makefile=x\n")
    for i in range(12):
        var body = String(
            "#include <string>\nint f", i, "(const std::string &s) {\n"
        )
        body += "    int n = 0;\n"
        for _ in range(i * 3):
            body += "    n += s.size() / 2;\n"
        body += "    return n;\n}\n"
        many.append(String("m", i, "/m", i, ".cpp=") + body)
    _both_ways(t, "many", many, dot)
    # Every export refused: the unit is caution, with C++'s note.
    _both_ways(
        t,
        "all-refused",
        [
            "CMakeLists.txt=x\n",
            (
                "a.cpp=class A { public: int f() { return 0; } };\nint g(int"
                " *p) { return *p; }\n"
            ),
        ],
        dot,
    )
    _both_ways(
        t,
        "unreadable",
        [
            "Makefile=x\n",
            "bad.cpp=b64:aW50IGIoKSB7IC8qIP8gKi8gcmV0dXJuIDA7IH0K",
            "good.cpp=int f(int x) { return x; }\n",
        ],
        dot,
    )


def test_out_writes_a_cpp_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            ["CMakeLists.txt=x\n", "a.cpp=int f(int x) { return x; }\n"],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A tree with an error (in a source file or any file the alias walk
    reads), an alias two files give different meanings and ignore files
    with alternates."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "CMakeLists.txt=x\n|a.cpp=int f( {\n"))
    cases.append(
        (
            "vendor-syntax",
            (
                "CMakeLists.txt=x\n|a.cpp=int f() { return 0;"
                " }\n|vendor/x.hpp=int g( {\n"
            ),
        )
    )
    cases.append(
        (
            "two-aliases",
            (
                "CMakeLists.txt=x\n|a.cpp=using T = int;\nT f(T x) { return x;"
                " }\n|b.hpp=using T = double;\n"
            ),
        )
    )
    # A symlinked header: cpp.rs reads it for aliases and class names (the
    # walk yields the link, read_to_string follows it).
    cases.append(
        (
            "symlink-alias",
            (
                "CMakeLists.txt=x\n|shared/alias.inc=using Real ="
                " double;\n|src/alias.hpp=link:../shared/alias.inc\n"
                '|src/lib.cpp=#include "alias.hpp"\nReal f(Real x) { return'
                " x; }\n"
            ),
        )
    )
    cases.append(
        (
            "symlink-class",
            (
                "CMakeLists.txt=x\n|shared/eng.inc=class Eng;\n"
                "|src/eng.hpp=link:../shared/eng.inc\n|src/lib.cpp=int"
                " Eng::run(int x) { return x; }\nint g(int x) { return x; }\n"
            ),
        )
    )
    cases.append(
        (
            "ignore-braces",
            (
                ".gitignore={a,b}/\n|CMakeLists.txt=x\n|a.cpp=int f() { return"
                " 0; }\n"
            ),
        )
    )
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def main() raises:
    test_cpp_plans_match_the_phase1_binary()
    test_out_writes_a_cpp_plan()
    test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_cpp: 3 passed")
