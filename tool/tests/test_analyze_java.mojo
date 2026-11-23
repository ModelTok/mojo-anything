# `analyze` of Java workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/java.rs read through tree-sitter's Python bindings, src/risks.rs,
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


comptime _STRINGS = """package com.example.text;

import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.regex.Pattern;
import java.lang.reflect.Method;
import static java.lang.Math.max;
import com.google.common.base.Joiner;
import org.example.unknown.Thing;
import com.example.util.Helpers;
import com.example.model.*;

/** String helpers. */
public final class Strings extends Base implements Comparable<Strings> {
    private static volatile int seen = 0;

    private Strings() {}

    public static String slugify(String text, int max) {
        StringBuilder out = new StringBuilder();
        for (int i = 0; i < text.length(); i++) {
            char c = text.charAt(i);
            if (Character.isLetterOrDigit(c)) {
                out.append(c);
            }
        }
        String s = out.toString();
        return s.substring(0, Math.min(max, s.length()));
    }

    public static List<String> words(String text) {
        List<String> out = new ArrayList<>();
        for (String w : text.split("\\\\s+")) {
            out.add(w);
        }
        return out;
    }

    public static Map<String, List<Integer>> index(List<String> words) {
        return new HashMap<>();
    }

    public static Map<Integer, String> byNumber(int n) {
        return null;
    }

    public static Optional<String> first(List<String> words) {
        return words.isEmpty() ? Optional.empty() : Optional.of(words.get(0));
    }

    public static int add(int a, int b) { return a + b; }
    public static double add(double a, double b) { return a + b; }
    public static <T> T id(T x) { return x; }
    public static int sum(int... xs) { return 0; }
    public static char head(String s) { return s.charAt(0); }
    public static Object any(Object o) { return o; }
    public static java.util.function.Function<String, String> fn() { return x -> x; }
    public static String raw(List xs) { return ""; }
    public static double[] scale(double[] xs, float f) { return xs; }
    public static void touch(Map<String, Optional<Long>> m) { }
    static int hidden() { return 1; }
    public int instance() { return 1; }

    public static synchronized int risky(Object o, String p, String s) throws Exception {
        if (o instanceof String) {
            String t = (String) o;
        }
        Runnable r = () -> {};
        Runnable q = Strings::hidden;
        int x = 7 / 2 % 3 << 1 >> 1 >>> 1;
        int y = x * 2;
        s.hashCode();
        o.getClass();
        Class.forName("x");
        s.matches("(?=a)b");
        s.replaceAll("(a)\\\\1", "");
        s.replaceFirst("plain", "");
        Pattern.compile(p);
        s.split(p);
        s.indexOf("a");
        s.lastIndexOf("a");
        s.codePointAt(0);
        synchronized (Strings.class) {
            seen++;
        }
        try {
            throw new RuntimeException("x");
        } catch (RuntimeException e) {
            return 0;
        }
        while (x > 0) { x--; }
        do { x++; } while (x < 3);
    }
}

abstract class Base {}
"""

comptime _MODEL = """package com.example.model;

public class Point {
    public Point(int x) {}

    public static Point origin() { return null; }

    public static int dist(int a, int b) { return a - b; }
}
"""

comptime _HELPERS = """package com.example.util;

import com.example.text.Strings;

public abstract class Helpers {
    public static String twice(String s) { return s + s; }
}
"""


def test_java_plans_match_the_phase1_binary() raises:
    """Maven and Gradle modules, units, waves, cycles, risks, exports,
    tests and dependencies of Java workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "maven",
        [
            String(
                "pom.xml=<project>\n  <artifactId>textkit</artifactId>\n "
                " <dependencies>\n    <dependency>\n     "
                " <groupId>com.google.guava</groupId>\n     "
                " <artifactId>guava</artifactId>\n    </dependency>\n   "
                " <dependency>\n      <groupId>org.junit</groupId>\n     "
                " <artifactId>junit</artifactId>\n     "
                " <scope>test</scope>\n    </dependency>\n "
                " </dependencies>\n</project>\n"
            ),
            "src/main/java/com/example/text/Strings.java=" + _STRINGS,
            "src/main/java/com/example/model/Point.java=" + _MODEL,
            "src/main/java/com/example/util/Helpers.java=" + _HELPERS,
            (
                "src/test/java/com/example/text/StringsTest.java=package"
                " com.example.text;\nimport"
                " com.example.text.Strings;\nimport"
                " org.junit.Test;\nclass StringsTest {}\n"
            ),
            (
                "src/main/java/com/example/util/HelpersIT.java=package"
                " com.example.util;\nimport com.example.model.*;\nclass"
                " HelpersIT {}\n"
            ),
        ],
        dot,
    )
    _both_ways(
        t,
        "gradle",
        [
            "settings.gradle=include 'core', 'app'\n",
            (
                "app/build.gradle=dependencies {\n    implementation"
                " project(':core')\n    implementation"
                " 'com.google.guava:guava:33.0'\n    api"
                ' "org.apache.commons:commons-lang3:3.14"\n   '
                " testImplementation 'junit:junit:4.13'\n    runtimeOnly"
                " 'x'\n}\n"
            ),
            (
                "app/src/main/java/app/Main.java=package app;\nimport"
                " core.Lib;\npublic class Main {\n    public static int"
                " run(int x) { return Lib.twice(x); }\n}\n"
            ),
            (
                "core/build.gradle.kts=dependencies {\n   "
                ' implementation("com.squareup.okio:okio:3.0")\n}\n'
            ),
            (
                "core/src/main/java/core/Lib.java=package core;\nimport"
                " app.Main;\npublic class Lib {\n    public static int"
                " twice(int x) { return x * 2; }\n}\n"
            ),
            (
                "core/src/main/java/core/LibTests.java=package core;\nclass"
                " LibTests {}\n"
            ),
            "core/build/Gen.java=class Gen {}\n",
            "core/.hidden/H.java=class H {}\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "plain",
        [
            (
                "src/com/x/A.java=package com.x;\nimport com.x.b.B;\npublic"
                " class A { public static int f(int x) { return x; } }\n"
            ),
            (
                "src/com/x/b/B.java=package com.x.b;\nimport com.x.A;\npublic"
                " class B { public static long g(long x) { return x; } }\n"
            ),
            (
                "Top.java=public class Top { public static String s() { return"
                ' ""; } }\n'
            ),
        ],
        dot,
    )
    _both_ways(
        t,
        "no-src",
        [
            "a/A.java=package a;\npublic class A {}\n",
            "b/B.java=package b;\nimport a.A;\npublic class B {}\n",
        ],
        dot,
    )
    var many = List[String]()
    for i in range(12):
        var body = String(
            "package p;\npublic class M",
            i,
            " {\n  public static String f(String s) {\n",
        )
        for _ in range(i * 3):
            body += "    s = s.substring(1) + s.toLowerCase();\n"
        body += "    return s;\n  }\n}\n"
        many.append(String("src/main/java/p", i, "/M", i, ".java=") + body)
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "lang-flag",
        [
            "main.go=package main\n",
            (
                "A.java=public class A { public static int f(int x) { return x;"
                " } }\n"
            ),
        ],
        ["analyze", ".", "--lang", "java"],
    )
    _both_ways(
        t,
        "unreadable",
        [
            "Bad.java=b64:Y2xhc3MgQiB7IC8qIP8gKi8gfQo=",
            (
                "Good.java=public class Good { public static int f(int x) {"
                " return x; } }\n"
            ),
        ],
        dot,
    )


def test_out_writes_a_java_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            [
                "A.java=public class A { public static int f(int x) { return x;"
                " } }\n"
            ],
            ["analyze", ".", "--lang", "java", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A tree with an error (error recovery may differ between the cores),
    a folder holding two manifests (which one names the package depends on
    the walk's order) and ignore files with alternates."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "A.java=public class A { int f( }\n"))
    cases.append(
        (
            "two-manifests",
            (
                "pom.xml=<artifactId>a</artifactId>\n|build.gradle=x\n|A.java=class"
                " A {}\n"
            ),
        )
    )
    cases.append(("ignore-braces", ".gitignore={a,b}/\n|A.java=class A {}\n"))
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", ".", "--lang", "java"])
        # The log names the subcommand and its positional arguments.
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def test_answers_outside_the_pixi_environment() raises:
    """With only the system's `python3` on PATH (as `app replay` runs it),
    the bindings come from the repository's pixi environment."""
    var t = _py()
    _ = Python.import_module("builtins").exec(
        """
def plain(binary, args, cwd, log):
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/")}
    if os.path.exists(log):
        os.remove(log)
    env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
    return (p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"))
""",
        t,
    )
    var files = _files(
        ["A.java=public class A { public static int f(int x) { return x; } }\n"]
    )
    var old = t["fixture"](PythonObject("old"), PythonObject("plain"), files)
    var new = String(
        py=t["fixture"](PythonObject("new"), PythonObject("plain"), files)
    )
    var args = Python.list()
    args.append(PythonObject("analyze"))
    args.append(PythonObject("."))
    var o = t["run"](PythonObject(FALLBACK), args, old, PythonObject(""))
    var log = new + ".fallback.log"
    var n = t["plain"](
        PythonObject(MOJO), args, PythonObject(new), PythonObject(log)
    )
    assert_equal(String(py=n[2]), String(py=o[2]), "stderr outside pixi")
    assert_equal(String(py=n[1]), String(py=o[1]), "stdout outside pixi")
    assert_equal(
        String(py=t["log_text"](PythonObject(log))),
        "",
        "fell back outside pixi",
    )


def test_a_foreign_tree_sitter_on_the_path_is_not_read() raises:
    """Bindings of another version earlier on the interpreter's path (an old
    core whose `Language` takes a path and a name) neither crash the command
    nor stand in for the pinned ones."""
    var t = _py()
    _ = Python.import_module("builtins").exec(
        """
def foreign(binary, args, cwd, log):
    site = os.path.join(os.path.dirname(cwd), "foreign-site")
    for name, body in (("tree_sitter", "class Language:\\n    def __init__(self, path, name):\\n        pass\\n"),
                       ("tree_sitter_java", "def language():\\n    return 0\\n")):
        os.makedirs(os.path.join(site, name), exist_ok=True)
        with open(os.path.join(site, name, "__init__.py"), "w") as f:
            f.write(body)
    env = {"PATH": "/usr/bin:/bin", "HOME": os.environ.get("HOME", "/"), "PYTHONPATH": site}
    if os.path.exists(log):
        os.remove(log)
    env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
    return (p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"))
""",
        t,
    )
    var files = _files(
        ["A.java=public class A { public static int f(int x) { return x; } }\n"]
    )
    var old = t["fixture"](PythonObject("old"), PythonObject("foreign"), files)
    var new = String(
        py=t["fixture"](PythonObject("new"), PythonObject("foreign"), files)
    )
    var args = Python.list()
    args.append(PythonObject("analyze"))
    args.append(PythonObject("."))
    var o = t["run"](PythonObject(FALLBACK), args, old, PythonObject(""))
    var log = new + ".fallback.log"
    var n = t["foreign"](
        PythonObject(MOJO), args, PythonObject(new), PythonObject(log)
    )
    assert_equal(
        String(py=n[2]), String(py=o[2]), "stderr with foreign bindings"
    )
    assert_equal(
        String(py=n[1]), String(py=o[1]), "stdout with foreign bindings"
    )
    assert_equal(
        String(py=t["log_text"](PythonObject(log))),
        "",
        "fell back with foreign bindings",
    )


def main() raises:
    test_a_foreign_tree_sitter_on_the_path_is_not_read()
    test_answers_outside_the_pixi_environment()
    test_java_plans_match_the_phase1_binary()
    test_out_writes_a_java_plan()
    test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_java: 5 passed")
