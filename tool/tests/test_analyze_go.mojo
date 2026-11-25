# `analyze` of Go workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/go.rs read through tree-sitter's Python bindings, src/risks.rs,
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
    base = os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-go-%d" % os.getpid(), side)
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
    shutil.rmtree(os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-go-%d" % os.getpid()),
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


comptime _BAD = "cGFja2FnZSB1Ci8vIP8K"


comptime _TEXT = """package text

import (
	"encoding/json"
	"fmt"
	re "regexp"
	"reflect"
	"strings"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/google/uuid"
	"golang.org/x/text/unicode/norm"
	"example.com/kit/util"
	"example.com/kit/missing"
	"example.com/other/lib"
)

type Point struct {
	X      int     `json:"x"`
	Y      float64 `json:"y,omitempty"`
	Label  string
	hidden int
	Skip   int `json:"-"`
}

type Wrapped struct {
	Point
	Z int
}

type Bad struct {
	P *int
}

type Named struct {
	Function string `json:"fn"`
}

// Slugify lowercases text.
func Slugify(text string, max int) string {
	out := strings.ToLower(text)
	for i := 0; i < len(out); i++ {
		_ = out[i:]
	}
	for _, r := range out {
		_ = r
	}
	m := map[string]int{}
	for k := range m {
		_ = k
	}
	return out[:max]
}

func Add(a, b int) int { return a + b }
func Div(a float64, b float64) (float64, error) { return a / b, nil }
func Pair(a int) (x int, y string, err error) { return 0, "", nil }
func Many(xs ...string) []string { return xs }
func (p Point) Norm() float64 { return 0 }
func Gen[T any](x T) T { return x }
func Move(p Point) Point { return p }
func Wrap(w Wrapped) Wrapped { return w }
func Ptr(p *Point) {}
func Fn(f func(int) int) int { return f(1) }
func Ch(c chan int) {}
func Any(x any) {}
func Arr(x [3]int) {}
func Err(e error) {}
func Ext(x util.Thing) {}
func Lower(x point) {}
func Maps(m map[string][]int) map[string]Point { return nil }
func IntKeys(m map[int]string) {}
func Unknown(u Other) Other { return u }
func BadField(b Bad) {}
func NamedFn(n Named) Named { return n }
func Blank(_ int, _ string) {}
func Nested(x [][]float32) []map[string]bool { return nil }
func hidden() {}

func risky(x interface{}, p *int, c chan int) {
	var mu sync.Mutex
	go func() {}()
	c <- 1
	select {
	case <-c:
	default:
	}
	q := &x
	_ = q
	y := 7 / 2 % 3 << 1 >> 1
	z := int64(y) + int(y)
	_ = float64(z)
	_ = uint8(1)
	if x == nil {
		panic("x")
	}
	defer recover()
	switch x.(type) {
	case int:
	}
	_ = x.(string)
	var f func()
	_ = f
	_ = json.Marshal
	_ = reflect.TypeOf
	_ = atomic.AddInt32
	_ = unsafe.Sizeof
	_ = re.MustCompile
	_ = fmt.Sprint
	_ = uuid.New
	_ = norm.NFC
	_ = mu
	_ = MyInt(3)
}

type MyInt int
"""

comptime _UTIL = """package util

import "example.com/kit/text"

type Thing struct{}

func Twice(s string) string { return text.Slugify(s, 3) + s }
"""


def test_go_plans_match_the_phase1_binary() raises:
    """Modules, units, waves, cycles, risks, exports, tests and
    dependencies of Go workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "module",
        [
            String(
                "go.mod=module example.com/kit\n\ngo 1.22\n\nrequire (\n\t"
                "github.com/google/uuid v1.6.0\n\tgolang.org/x/text v0.14.0"
                " // indirect\n\t// a comment\n)\nrequire"
                " github.com/pkg/errors v0.9.1\n"
            ),
            "text/text.go=" + _TEXT,
            "util/util.go=" + _UTIL,
            (
                "text/text_test.go=package text\nimport"
                ' "testing"\nimport "example.com/kit/util"\nfunc'
                " TestX(t *testing.T) {}\n"
            ),
            "main.go=package main\nfunc main() {}\n",
            "vendor/v/v.go=package v\n",
            "testdata/d.go=package d\n",
            "_skip/s.go=package s\n",
            ".hidden/h.go=package h\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "workspace",
        [
            'go.mod=module "example.com/app"\n',
            (
                "cmd/app/main.go=package main\nimport"
                ' "example.com/lib/core"\nfunc main() { core.F() }\n'
            ),
            (
                "lib/go.mod=module example.com/lib // the library\nrequire"
                " x.y/z v1\n"
            ),
            (
                "lib/core/core.go=package core\nimport"
                ' "example.com/lib"\nfunc F() int { return 1 }\n'
            ),
            (
                'lib/lib.go=package lib\nimport "example.com/lib/core"\nfunc'
                " G() {}\n"
            ),
            "nomod/go.mod=go 1.21\n",
            'nomod/n.go=package n\nimport "nomod/x"\n',
        ],
        dot,
    )
    # A `module` line with no value (or a comment for one) is passed over:
    # the first line that has one names the module.
    _both_ways(
        t,
        "mod-later",
        [
            "go.mod=module\nmodule // later\nmodule example.com/late\n",
            "a/a.go=package a\nfunc A(x int) int { return x }\n",
            (
                'b/b.go=package b\nimport "example.com/late/a"\nfunc B() int {'
                " return a.A(1) }\n"
            ),
        ],
        dot,
    )
    _both_ways(
        t,
        "no-mod",
        [
            'a/a.go=package a\nimport "b"\nfunc A(x int) int { return x }\n',
            "b/b.go=package b\nfunc B() {}\n",
        ],
        ["analyze", ".", "--lang", "go"],
    )
    var many = List[String]()
    many.append("go.mod=module m\n")
    for i in range(12):
        var body = String("package p", i, "\nfunc F(s string) string {\n")
        for _ in range(i * 3):
            body += "\ts = s[1:] + s\n"
        body += "\treturn s\n}\n"
        many.append(String("p", i, "/f.go=") + body)
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "unreadable",
        [
            "go.mod=module u\n",
            "bad.go=b64:" + String(_BAD),
            "good.go=package u\nfunc F(x int) int { return x }\n",
        ],
        dot,
    )


def test_out_writes_a_go_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            ["go.mod=module o\n", "a.go=package o\nfunc F() {}\n"],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A tree with an error, names outside ASCII where Rust's Unicode tables
    decide, and ignore files with alternates."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "go.mod=module s\n|a.go=package s\nfunc F( {\n"))
    cases.append(
        (
            "unicode-name",
            "go.mod=module u\n|a.go=package u\nfunc Éclair() {}\n",
        )
    )
    cases.append(
        (
            "unicode-key",
            (
                "go.mod=module u\n|a.go=package u\ntype P struct { X int"
                ' `json:"x€Function"` }\nfunc F(p P) {}\n'
            ),
        )
    )
    cases.append(
        (
            "ignore-braces",
            "go.mod=module i\n|.gitignore={a,b}/\n|a.go=package i\n",
        )
    )
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        # The log names the subcommand and its positional arguments.
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def main() raises:
    test_go_plans_match_the_phase1_binary()
    test_out_writes_a_go_plan()
    test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_go: 3 passed")
