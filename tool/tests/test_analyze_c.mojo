# `analyze` of C workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/c.rs read through tree-sitter's Python bindings, src/risks.rs,
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


comptime _TYPES = """#ifndef TYPES_H
#define TYPES_H
#include <stdint.h>
typedef uint32_t Adler;
typedef Adler Checksum;
typedef enum { RED, GREEN } Color;
typedef struct Rational { int num; int den; } Rational;
struct Point { double x, y; };
typedef struct Point PointT;
typedef struct Opaque Opaque;
struct Bits { int a : 3; };
typedef struct { const char *name; } Named;
typedef struct { Adler a; long b; } Pair;
#define MAX(a, b) ((a) > (b) ? (a) : (b))
#endif
"""

comptime _TEXT_C = """#include "text.h"
#include "types.h"
#include "util/helpers.h"
#include <stdio.h>
#include <string.h>
#include <zlib.h>
#include <pthread.h>
#include <SDL2/SDL.h>
#include "missing.h"

static int hidden(int x) { return x; }

int add(int a, int b) { return a + b; }
unsigned long count(const char *s) { return strlen(s); }
size_t fill(char *out, size_t cap) { snprintf(out, cap, "x"); return cap; }
int sum(const uint8_t *data, size_t len) { return (int)len; }
void sum2(uint8_t *buf, int x, size_t size) { buf[0] = 1; }
int split(const char *s, char **end) { *end = (char *)s; return 0; }
int bad_pp(int **p) { return 0; }
const char *skip(const char *s) { return s + 1; }
char *dup(const char *s) { return strdup(s); }
void *raw(int n) { return malloc(n); }
int fmt(const char *f, ...) { return 0; }
int cb(int (*f)(int)) { return f(1); }
Checksum adler(Checksum a, Color c) { return a; }
Rational half(Rational r) { r.den *= 2; return r; }
PointT shift(PointT p) { return p; }
Pair pair(Pair p) { return p; }
Opaque *open_it(void) { return 0; }
Named name(Named n) { return n; }
struct Bits bits(struct Bits b) { return b; }
int arr(int xs[], int n) { return xs[0]; }
int out1(int *result) { *result = 1; return 0; }
double ratio(double a, double b) { return a / b; }
int unnamed(int, const char *) { return 0; }
float nothing(void) { return 0.0f; }
enum Mode mode(enum Mode m) { return m; }
_Bool flag(bool b) { return b; }
long long big(long long x) { return x << 2; }

int risky(int *p, int n) {
    volatile int v = 0;
    int *q = (int *)0x1000;
    char buf[16];
    strcpy(buf, "x");
    pthread_mutex_lock(0);
    if (n % 2) exit(1);
    while (n > 0) { n--; }
    do { n++; } while (n < 3);
    for (int i = 0; i < n; i++) { v += *p; }
    __asm__("nop");
    void *z = NULL;
    free(z);
    return (int)(v >> 1);
}

int main(void) { return 0; }
"""

comptime _TEXT_H = """#include "types.h"
#include <stdlib.h>
int add(int a, int b);
"""

comptime _HELPERS_C = """#include "helpers.h"
#include "../text.h"
int helper(int x) { return add(x, 1); }
"""


def test_c_plans_match_the_phase1_binary() raises:
    """Build folders, units, waves, cycles, risks, exports, tests and
    dependencies of C workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "make",
        [
            "Makefile=all:\n\tcc src/*.c\n",
            "src/text.c=" + _TEXT_C,
            "src/text.h=" + _TEXT_H,
            "include/types.h=" + _TYPES,
            "src/util/helpers.c=" + _HELPERS_C,
            "src/util/helpers.h=int helper(int x);\n",
            "src/arch/x86/cpu.c=int cpu(void) { return 1; }\n",
            (
                "src/lone.h=#pragma pack(1)\nstruct __attribute__((packed)) P {"
                " int a; };\n"
            ),
            (
                'tests/test_text.c=#include "../src/text.h"\nint main(void) {'
                " return add(1, 2); }\n"
            ),
            "src/text_test.c=int t(void) { return 0; }\n",
            "lib/CMakeLists.txt=project(lib)\n",
            (
                'lib/src/lib.c=#include "lib.h"\nint lib(int x) { return x /'
                " 3; }\n"
            ),
            "lib/src/lib.h=int lib(int x);\n",
            "vendor/v.c=typedef int VendorInt;\nint v(void) { return 0; }\n",
            "build/gen.c=int gen(void) { return 0; }\n",
            ".hidden/h.c=int h(void) { return 0; }\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "plain",
        [
            'a.c=#include "b.h"\nint a(int x) { return b(x); }\n',
            'b.c=#include "a.h"\nint b(int x) { return a(x); }\n',
            "a.h=int a(int x);\n",
            "b.h=int b(int x);\n",
            (
                'pkg/c.c=#include "pkg/d.h"\n#include "other/e.h"\nint c(void)'
                " { return 0; }\n"
            ),
            "pkg/d.h=int d;\n",
            "e.h=int e;\n",
        ],
        ["analyze", ".", "--lang", "c"],
    )
    var many = List[String]()
    many.append("Makefile=x\n")
    for i in range(12):
        var body = String(
            "#include <string.h>\nint f", i, "(const char *s) {\n"
        )
        body += "    int n = 0;\n"
        for _ in range(i * 3):
            body += "    n += strlen(s) / 2;\n"
        body += "    return n;\n}\n"
        many.append(String("m", i, "/m", i, ".c=") + body)
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "unreadable",
        [
            "Makefile=x\n",
            "bad.c=b64:aW50IGIodm9pZCkgeyAvKiD/ICovIHJldHVybiAwOyB9Cg==",
            "good.c=int f(int x) { return x; }\n",
        ],
        dot,
    )


def test_out_writes_a_c_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            ["Makefile=x\n", "a.c=int f(int x) { return x; }\n"],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A tree with an error (in a source file or any header the typedef walk
    reads), a typedef two files give different meanings and ignore files
    with alternates."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "Makefile=x\n|a.c=int f( {\n"))
    cases.append(
        (
            "vendor-syntax",
            (
                "Makefile=x\n|a.c=int f(void) { return 0; }\n|vendor/x.h=int"
                " g( {\n"
            ),
        )
    )
    cases.append(
        (
            "two-typedefs",
            (
                "Makefile=x\n|a.c=typedef int T;\nT f(T x) { return x;"
                " }\n|b.h=typedef double T;\n"
            ),
        )
    )
    cases.append(
        (
            "ignore-braces",
            ".gitignore={a,b}/\n|Makefile=x\n|a.c=int f(void) { return 0; }\n",
        )
    )
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def main() raises:
    test_c_plans_match_the_phase1_binary()
    test_out_writes_a_c_plan()
    test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_c: 3 passed")
