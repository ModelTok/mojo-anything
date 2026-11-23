# `analyze` of Kotlin workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/kotlin.rs read through tree-sitter's Python bindings, src/risks.rs,
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


comptime _STRINGS = """@file:Suppress("unused")
package com.example.text

import kotlinx.coroutines.runBlocking
import kotlin.reflect.KClass
import java.util.regex.Pattern
import kotlin.text.Regex
import java.util.HashMap
import com.google.common.base.Joiner
import androidx.room.Room
import org.example.unknown.Thing as Other
import com.example.util.Helpers
import com.example.model.*
import com.example.model.Point.Companion

/** String helpers. */
fun slugify(text: String, max: Int): String {
    val out = StringBuilder()
    for (c in text) {
        if (c.isLetterOrDigit()) out.append(c)
    }
    val s = out.toString()
    return s.substring(0, minOf(max, s.length))
}

fun words(text: String): List<String> = text.split(" ")
fun index(words: List<String>): Map<String, List<Int>> = mapOf()
fun byNumber(n: Int): Map<Int, String> = mapOf()
fun first(words: List<String>): String? = words.firstOrNull()
fun nums(xs: IntArray, ys: LongArray, zs: DoubleArray, bs: BooleanArray): Array<String> = arrayOf()
fun shorts(xs: ShortArray): Int = 0
fun nested(xs: List<List<String?>>): MutableMap<String, Boolean> = mutableMapOf()
fun add(a: Int, b: Int): Int = a + b
fun add(a: Double, b: Double): Double = a + b
fun <T> id(x: T): T = x
fun sum(vararg xs: Int): Int = 0
fun head(s: String): Char = s[0]
fun any(o: Any): Any = o
fun set(o: Set<String>): Int = 0
fun seq(o: Sequence<String>): Int = 0
fun pair(o: Pair<String, Int>): Int = 0
fun fn(f: (String) -> String): String = f("")
fun raw(xs: List<*>): String = ""
fun cls(x: Point): Long = 0L
fun noType(x: Int) = x + 1
fun unit(x: Float) { }
fun String.shout(): String = this.uppercase()
suspend fun slow(x: String): String = x
inline fun fast(x: String): String = x
@JvmName("renamed") fun named(): String = ""
private fun hidden(): Int = 1
internal fun inner(): Int = 1
fun nothing(): Nothing = throw IllegalStateException("x")

open class Base
class Child(val x: Int) : Base(), Comparable<Child> {
    override fun compareTo(other: Child): Int = x - other.x

    companion object Factory {
        @JvmStatic fun make(s: String): String = s
        fun notStatic(s: String): String = s
        @JvmStatic private fun hiddenStatic(s: String): String = s
    }

    object Sign {
        @JvmStatic fun sign(n: Long): Long = if (n < 0) -1 else 1
    }
}

object Math {
    @JvmStatic fun mul(a: Int, b: Int): Int = a * b
    @JvmStatic fun div(a: Int, b: Int): Int = a / b % 3
    fun instanceOnly(): Int = 1
}

class Risky {
    @Volatile var seen = 0

    @Synchronized
    fun risky(o: Any, p: String, s: String): Int {
        if (o is String) {
            val t = o as String
        }
        val r = { x: Int -> x + 1 }
        val y = 7 * 2
        s.toInt()
        s.toLong()
        o.javaClass
        o::class
        Class.forName("x")
        s.indexOf("a")
        s.getClass()
        Regex("(?=a)b")
        Regex("plain")
        synchronized(this) { seen++ }
        try {
            throw RuntimeException("x")
        } catch (e: RuntimeException) {
            return 0
        }
        var x = 3
        while (x > 0) { x-- }
        do { x++ } while (x < 3)
        return y
    }
}
"""

comptime _MODEL = """package com.example.model

data class Point(val x: Int, val y: Int) {
    companion object {
        @JvmStatic fun origin(): Point = Point(0, 0)
        @JvmStatic fun dist(a: Int, b: Int): Int = a - b
    }
}
"""

comptime _HELPERS = """@file:JvmName("Helpers")
package com.example.util

import com.example.text.slugify

fun twice(s: String): String = s + s
"""


def test_kotlin_plans_match_the_phase1_binary() raises:
    """Gradle modules, units, waves, cycles, risks, exports, tests and
    dependencies of Kotlin workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "gradle",
        [
            String(
                'build.gradle.kts=plugins {\n    kotlin("jvm")\n}\ndependencies'
                " {\n   "
                ' implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.0")\n'
                '    api("com.google.guava:guava:33.0")\n   '
                ' implementation("androidx.room:room-runtime:2.6")\n   '
                " compileOnly 'org.example:unknown:1'\n   "
                ' testImplementation("junit:junit:4.13")\n   '
                ' androidTestImplementation("androidx.test:core:1.5")\n   '
                ' runtimeOnly("x")\n}\n'
            ),
            "src/main/kotlin/com/example/text/Strings.kt=" + _STRINGS,
            "src/main/kotlin/com/example/model/Point.kt=" + _MODEL,
            "src/main/kotlin/com/example/util/Helpers.kt=" + _HELPERS,
            (
                "src/main/kotlin/com/example/util/my-file.kt=package"
                ' com.example.util\nfun ping(): String = "pong"\n'
            ),
            (
                "src/test/kotlin/com/example/text/StringsTest.kt=package"
                " com.example.text\nimport com.example.text.slugify\nclass"
                " StringsTest\n"
            ),
            (
                "src/androidTest/kotlin/com/example/UiCheck.kt=package"
                " com.example\nclass UiCheck\n"
            ),
            (
                "src/main/kotlin/com/example/util/HelpersTest.kt=package"
                " com.example.util\nclass HelpersTest\n"
            ),
            "build/generated/Gen.kt=class Gen\n",
            (
                "src/main/kotlin/build/Real.kt=package build\nfun real(): Int"
                " = 1\n"
            ),
            ".hidden/H.kt=class H\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "modules",
        [
            'settings.gradle.kts=include("core", "app")\n',
            (
                "app/build.gradle.kts=dependencies {\n   "
                ' implementation(project(":core"))\n   '
                ' implementation("com.squareup.okio:okio:3.0")\n}\n'
            ),
            (
                "app/src/main/kotlin/app/Main.kt=package app\nimport"
                " core.twice\nfun run(x: Int): Int = twice(x)\n"
            ),
            (
                "core/build.gradle=dependencies {\n    implementation"
                " 'com.squareup.moshi:moshi:1.15'\n}\n"
            ),
            (
                "core/src/main/kotlin/core/Lib.kt=package core\nimport"
                " app.run\nfun twice(x: Int): Int = x * 2\n"
            ),
            "java/pom.xml=<project/>\n",
            "java/src/main/java/j/J.kt=package j\nfun j(): Int = 1\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "plain",
        [
            (
                "src/com/x/A.kt=package com.x\nimport com.x.b.B\nfun f(x:"
                " Int): Int = x\n"
            ),
            (
                "src/com/x/b/B.kt=package com.x.b\nimport com.x.f\nfun g(x:"
                " Long): Long = x\n"
            ),
            'Top.kt=fun s(): String = ""\n',
        ],
        ["analyze", ".", "--lang", "kotlin"],
    )
    # kotlin.rs and Lang::detect keep a `build/` with no `src` in its path
    # and prune one under `src/` (the reverse of their comments).
    # Detected as Java (whose own walk prunes `build/`, so Mojo declines);
    # the outputs agree whoever answers.
    _ = _both(
        t,
        "build-java",
        [
            "build.gradle.kts=\n",
            "src/main/kotlin/A.kt=fun f(x: Int): Int = x\n",
            "build/B.java=public class B {}\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "under-src",
        [
            "src/app/build.gradle.kts=\n",
            "src/app/A.kt=fun f(x: Int): Int = x\n",
            "src/app/build/B.kt=fun g(x: Int): Int = x\n",
            "src/app/out/C.kt=fun h(x: Int): Int = x\n",
        ],
        ["analyze", "src/app"],
    )
    var many = List[String]()
    many.append('build.gradle.kts=plugins { kotlin("jvm") }\n')
    for i in range(12):
        var body = String(
            "package p",
            i,
            "\nfun f",
            i,
            "(s: String): String {\n    var t = s\n",
        )
        for _ in range(i * 3):
            body += "    t = t.substring(1) + t.lowercase()\n"
        body += "    return t\n}\n"
        many.append(String("src/main/kotlin/p", i, "/M", i, ".kt=") + body)
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "unreadable",
        [
            "build.gradle.kts=\n",
            "Bad.kt=b64:Y2xhc3MgQiB7IC8qIP8gKi8gfQo=",
            "Good.kt=fun f(x: Int): Int = x\n",
        ],
        dot,
    )


def test_out_writes_a_kotlin_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            ["build.gradle.kts=\n", "A.kt=fun f(x: Int): Int = x\n"],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A tree with an error, a folder holding two manifests and ignore files
    with alternates."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "build.gradle.kts=\n|A.kt=fun f( {\n"))
    cases.append(
        (
            "two-manifests",
            "build.gradle=x\n|build.gradle.kts=y\n|A.kt=fun f(): Int = 1\n",
        )
    )
    cases.append(
        (
            "ignore-braces",
            ".gitignore={a,b}/\n|build.gradle.kts=\n|A.kt=fun f(): Int = 1\n",
        )
    )
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def main() raises:
    test_kotlin_plans_match_the_phase1_binary()
    test_out_writes_a_kotlin_plan()
    test_what_tree_sitter_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_kotlin: 3 passed")
