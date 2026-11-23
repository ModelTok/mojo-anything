# `analyze` of C# workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/csharp.rs read through tree-sitter's Python bindings, src/risks.rs,
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
    base = os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-csharp-%d" % os.getpid(), side)
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
    shutil.rmtree(os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-csharp-%d" % os.getpid()),
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


comptime _SLUG = """using System;
using System.Collections.Generic;
using System.Reflection;
using System.Threading.Tasks;
using System.Text.RegularExpressions;
using static System.Math;
using Newtonsoft.Json;
using Acme.Textkit.Util;
using Acme.Textkit.Missing;
using Serilog;

namespace Acme.Textkit.Text;

public static class Slug : Base, IThing
{
    private static volatile int seen;

    public static string Slugify(string text, int max)
    {
        var s = text.Substring(0, max).IndexOf("a").ToString();
        for (int i = 0; i < 3; i++) { }
        foreach (var c in text) { }
        while (max > 0) { max--; }
        do { max++; } while (max < 3);
        return s;
    }

    public static List<string> Words(string text) => new List<string>();
    public static Dictionary<string, List<int>> Index(IEnumerable<string> w) => null;
    public static Dictionary<int, string> ByNumber(int n) => null;
    public static int? Maybe(Nullable<double> x) => null;
    public static double[] Scale(double[] xs, float f) => xs;
    public static int Add(int a, int b) => a + b;
    public static double Add(double a, double b) => a + b;
    public static T Id<T>(T x) => x;
    public static int Sum(params int[] xs) => 0;
    public static void Swap(ref int a, ref int b) { }
    public static bool TryParse(string s, out int v) { v = 0; return true; }
    public static decimal Money(decimal d) => d;
    public static char Head(string s) => s[0];
    public static object Any(object o) => o;
    public static Func<int, int> Fn() => x => x;
    public static Task<int> Later() => null;
    public static (int, int) Pair() => (1, 2);
    public static ulong Big(ulong x) => x;
    public static List Raw(List xs) => xs;
    static int Hidden() => 1;
    public int Instance() => 1;

    public static async Task<int> Risky(object o, string p, dynamic d)
    {
        lock (o) { }
        await Task.Delay(1);
        if (o is string) { }
        if (o is string t2) { }
        var x = o as string;
        var y = (string)o;
        Func<int, int> f = q => q;
        Action a = delegate { };
        int z = 7 / 2 % 3 << 1 >> 1 * 2;
        o.GetHashCode();
        o.GetType();
        new Regex("(?=a)b");
        new Regex(@"(a)\\1");
        new Regex(p);
        Regex.IsMatch(p, "(?<=a)");
        Regex.Replace(p, p, "");
        var h = new HashSet<int>();
        var dd = new Dictionary<string, int>();
        decimal m = 1m;
        var q2 = from c in p select c;
        try { throw new Exception(); } catch (Exception) { }
        string s = null;
        unsafe { int* ptr = null; fixed (char* c = p) { } }
        return 1;
    }

    public static IEnumerable<int> Gen()
    {
        yield return 1;
    }
}

namespace Acme.Textkit.Inner
{
    public class Point
    {
        public static int Dist(int a, int b) => a - b;
    }

    class Hidden2
    {
        public static int No() => 1;
    }
}
"""


def test_csharp_plans_match_the_phase1_binary() raises:
    """Projects, units, waves, risks, exports, tests and dependencies of C#
    workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "projects",
        [
            "Acme.sln=x\n",
            String(
                "src/Acme.Textkit/Acme.Textkit.csproj=<Project"
                ' Sdk="Microsoft.NET.Sdk">\n  <PropertyGroup><AssemblyName>'
                " Acme.Textkit </AssemblyName></PropertyGroup>\n  <ItemGroup>\n"
                '    <PackageReference Include="Newtonsoft.Json" Version="13"'
                ' />\n    <!-- <PackageReference Include="Hidden" /> -->\n   '
                ' <PackageReference Include="Serilog" />\n '
                " </ItemGroup>\n</Project>\n"
            ),
            "src/Acme.Textkit/Text/Slug.cs=" + _SLUG,
            (
                "src/Acme.Textkit/Util/Helpers.cs=namespace"
                " Acme.Textkit.Util;\nusing Acme.Textkit.Text;\npublic class"
                " Helpers { public static string Twice(string s) => s + s; }\n"
            ),
            (
                "src/Acme.Textkit/Root.cs=public class Root { public static int"
                " F() => 1; }\n"
            ),
            (
                "tests/Acme.Textkit.Tests/Acme.Textkit.Tests.csproj=<Project>\n"
                '  <PackageReference Include="xunit" />\n</Project>\n'
            ),
            (
                "tests/Acme.Textkit.Tests/SlugTests.cs=using"
                " Acme.Textkit.Text;\nusing Xunit;\npublic class SlugTests {}\n"
            ),
            (
                "tools/Gen/Gen.csproj=<Project><IsTestProject> true"
                " </IsTestProject></Project>\n"
            ),
            "tools/Gen/Gen.cs=class Gen {}\n",
            "src/Acme.Textkit/bin/X.cs=class X {}\n",
            "src/Acme.Textkit/obj/Y.cs=class Y {}\n",
            "misc/OtherTest.cs=class OtherTest {}\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "no-project",
        [
            (
                "a/A.cs=namespace a { public class A { public static int F(int"
                " x) => x; } }\n"
            ),
            "b/B.cs=using a;\nnamespace b { public class B { } }\n",
        ],
        ["analyze", ".", "--lang", "csharp"],
    )
    var many = List[String]()
    many.append("App.csproj=<Project></Project>\n")
    for i in range(12):
        var body = String(
            "namespace App.M",
            i,
            ";\npublic class M",
            i,
            " {\n  public static string F(string s) {\n",
        )
        for _ in range(i * 3):
            body += "    s = s.Substring(1) + s.ToLower();\n"
        body += "    return s;\n  }\n}\n"
        many.append(String("M", i, "/M.cs=") + body)
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "unreadable",
        [
            "App.csproj=<Project></Project>\n",
            "Bad.cs=b64:" + String(_BAD),
            "Good.cs=public class Good { public static int F(int x) => x; }\n",
        ],
        dot,
    )


def test_out_writes_a_csharp_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            [
                "App.csproj=<Project></Project>\n",
                "A.cs=public class A { public static int F(int x) => x; }\n",
            ],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A tree with an error, two projects in one folder and ignore files with
    alternates."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "App.csproj=x\n|A.cs=class A { int F( }\n"))
    cases.append(
        ("two-projects", "A.csproj=x\n|B.csproj=y\n|A.cs=class A {}\n")
    )
    cases.append(
        (
            "ignore-braces",
            "App.csproj=x\n|.gitignore={a,b}/\n|A.cs=class A {}\n",
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
    test_csharp_plans_match_the_phase1_binary()
    test_out_writes_a_csharp_plan()
    test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_csharp: 3 passed")
