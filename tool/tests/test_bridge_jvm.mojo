# `bridge` and `refresh` of Java and Kotlin units in Mojo (src/jvm.rs
# `require_java`, src/lang/java.rs and src/lang/kotlin.rs `exports`,
# src/codegen_mojo_jvm.rs, the mojo-jvm arms of src/bridge.rs): the Mojo
# binary runs next to the Phase 1 binary on copies of the same repository, and
# the two must agree on stdout, stderr, the exit code and every file and
# folder written, byte for byte, with no fallback logged.

from std.python import Python, PythonObject
from std.testing import assert_equal


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, re, shutil, stat, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-bridge-jvm-%d" % os.getpid())
PHASE1 = os.path.abspath("tool/fallback/mojo-anything")
MOJO = os.path.abspath("tool/build/mojo-anything")

def _fixture(side, name, source, files, bridge, port):
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    if source:
        shutil.copytree(source, d, symlinks=True)
    else:
        os.makedirs(d)
    # With a bridge first, the files are written into what it made.
    if bridge:
        p = subprocess.run([PHASE1, "bridge", ".", bridge], cwd=d, capture_output=True,
                           stdin=subprocess.DEVNULL, timeout=300)
        assert p.returncode == 0, p.stderr
    for rel, text in files:
        if rel.startswith("!"):
            os.remove(os.path.join(d, rel[1:]))
            continue
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="") as f:
            f.write(text)
        if rel.startswith("bin/"):
            os.chmod(p, 0o755)
    for crate, src in port:
        # A port.mojo outside ASCII declines (parse_port_mojo's trims use
        # Unicode tables); the fixtures' one such comment is spelled out.
        with open(os.path.abspath(src), encoding="utf-8") as f:
            text = f.read().replace("\\u0130", "capital I with a dot")
        with open(os.path.join(d, crate, "port.mojo"), "w", newline="") as f:
            f.write(text)
    return d

def _tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for sub in dirs:
            out.append((os.path.relpath(os.path.join(base, sub), d) + "/", b""))
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read().replace(d.encode(), b"<D>")))
    out.sort()
    return out

def _run(binary, args, cwd, log, path):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if path:
        env["PATH"] = path.replace("<D>", cwd)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([binary] + list(args), cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=600)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>")
    err = re.sub(r"thread 'main' \\(\\d+\\)", "thread 'main'", err)
    return (p.returncode, out, err)

def both(name, source, files, bridge, port, cwd, args, path):
    # "" when both binaries agree and nothing fell back; what differs otherwise.
    old = _fixture("old", name, source, files, bridge, port)
    new = _fixture("new", name, source, files, bridge, port)
    o = _run(PHASE1, args, old + cwd, "", path)
    log = new + ".fallback.log"
    n = _run(MOJO, args, new + cwd, log, path)
    shown = " in %s: %s" % (name, " ".join(args))
    for what, a, b in (("stdout", n[1], o[1]), ("stderr", n[2], o[2]), ("exit code", n[0], o[0])):
        if a != b:
            return "%s of%s\\n--- mojo\\n%s\\n--- phase 1\\n%s" % (what, shown, a, b)
    tn, to = _tree(new), _tree(old)
    if tn != to:
        for x, y in zip(tn, to):
            if x != y:
                return "files of%s: %r vs %r" % (shown, x[0], y[0]) + "\\n" + x[1].decode("utf-8", "replace")[:3000] + "\\n---\\n" + y[1].decode("utf-8", "replace")[:3000]
        return "files of%s: %d vs %d entries" % (shown, len(tn), len(to))
    try:
        with open(log) as f:
            fell = f.read()
    except OSError:
        fell = ""
    if fell:
        return "fell back%s" % shown
    if o[0] == 0 and bridge == "" and not any(f == "mojo-anything.json" for _, _, fs in os.walk(new) for f in fs):
        return "nothing was bridged%s" % shown
    return ""

def gone():
    shutil.rmtree(BASE, ignore_errors=True)
""",
        scope,
    )
    return scope


@fieldwise_init
struct Case(Copyable, Movable):
    var name: String
    var source: String
    var files: List[String]
    var bridge: String
    var port: List[String]
    """`crate=fixture` pairs copied over port.mojo after the bridge."""
    var cwd: String
    var args: List[String]
    var path: String
    """PATH for both binaries (`<D>` is the fixture), or "" to keep it."""


def _case(name: String, source: String, var args: List[String]) -> Case:
    return Case(
        name,
        source,
        List[String](),
        "",
        List[String](),
        "",
        args^,
        "",
    )


def _check(t: PythonObject, c: Case) raises:
    var files = Python.list()
    for s in c.files:
        var eq = s.find("=")
        files.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    var port = Python.list()
    for s in c.port:
        var eq = s.find("=")
        port.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    var args = Python.list()
    for a in c.args:
        args.append(PythonObject(a))
    var r = String(
        py=t["both"](
            PythonObject(c.name),
            PythonObject(c.source),
            files,
            PythonObject(c.bridge),
            port,
            PythonObject(c.cwd),
            args,
            PythonObject(c.path),
        )
    )
    assert_equal(r, "", c.name)


def _bridge(a: String, b: String) -> List[String]:
    return ["bridge", a, b]


def test_jvm_fixtures_are_bridged_in_mojo() raises:
    """The recorded Java and Kotlin fixtures, a folder unit and a single
    file, with the flags the Mojo tool answers."""
    var t = _py()
    var java = "src/main/java/com/example/text/"
    var kt = "src/main/kotlin/com/example/text/"
    _check(t, _case("java", "tests/fixtures/java", _bridge(".", java)))
    _check(
        t,
        _case(
            "java-file",
            "tests/fixtures/java",
            _bridge(".", "./src/main/java/com/example/text/Nums.java"),
        ),
    )
    _check(
        t,
        _case(
            "java-guava",
            "tests/fixtures/java-guava",
            _bridge(".", "src/main/java/com/example/"),
        ),
    )
    _check(
        t,
        _case(
            "java-members",
            "tests/fixtures/java-members",
            _bridge(".", "src/main/java/com/example/members/"),
        ),
    )
    _check(t, _case("kotlin", "tests/fixtures/kotlin", _bridge(".", kt)))
    _check(
        t,
        _case(
            "kotlin-owners",
            "tests/fixtures/kotlin-owners",
            _bridge(".", "src/main/kotlin/com/example/owners/"),
        ),
    )
    var flags = _bridge(".", java)
    flags += ["--keep", "slugify:needs the JDK", "--name", "txt"]
    flags += ["--out", "out/txt", "--force"]
    _check(t, _case("java-flags", "tests/fixtures/java", flags^))
    var kept = _bridge(".", kt)
    kept += ["--keep", "slugify"]
    _check(t, _case("kotlin-keep", "tests/fixtures/kotlin", kept^))
    var wasm = _bridge(".", java)
    wasm += ["--kind", "wasm"]
    _check(t, _case("java-wasm", "tests/fixtures/java", wasm^))
    _ = t["gone"]()


comptime _POM = "pom.xml=<project><artifactId>shapes</artifactId></project>\n"

comptime _JAVA_SHAPES = """package p.q;

import java.util.*;
import java.util.function.Function;

/** Every Java type the dialect carries, and every reason one stays. */
public class Shapes {
    public Shapes(int x) {}
    public static int ok(int a, long b, short c, byte d) { return a; }
    public static double fl(double a, float b, Double c, Float d) { return a; }
    public static boolean bo(Boolean b, Integer i, Long l, Short s, Byte y) { return b; }
    public static void nothing(String s, CharSequence t) {}
    public static Void nada() { return null; }
    public static List<String> lst(ArrayList<Integer> a, Collection<Long> b,
            Iterable<Boolean> c, LinkedList<Double> d) { return null; }
    public static Map<String, List<Integer>> mp(LinkedHashMap<String, Integer> a,
            TreeMap<String, String> b, HashMap<String, Double> c) { return null; }
    public static Optional<String> opt(OptionalInt a, OptionalLong b, OptionalDouble c) { return null; }
    public static List<Optional<Integer>> nested(int[] a, String[][] b, long[] c) { return null; }
    public static <T> T gen(T x) { return x; }
    public static int varargs(int... xs) { return 0; }
    public static char ch(char c) { return c; }
    public static Character ch2() { return 'a'; }
    public static Object obj(Object o) { return o; }
    public static int fn(Function<Integer, Integer> f) { return 0; }
    public static int run(Runnable r) { return 0; }
    public static java.util.stream.Stream<String> st() { return null; }
    public static Iterator<String> it() { return null; }
    public static IntStream ist() { return null; }
    public static Point cls(Point p) { return p; }
    public static List raw(List x) { return x; }
    public static Map<Integer, String> keys() { return null; }
    static int hidden() { return 0; }
    public int inst() { return 0; }
    @Deprecated
    public static int annotated(final int x) { return x; }
    public static java.util.List<String> qualified(java.lang.String s) { return null; }
    public static Set<String> set(Optional<List<String>> o) { return null; }
}

class Hidden {
    public static int nope() { return 1; }
}
"""

comptime _JAVA_CTORS = """package p.q;

public abstract class Abs {
    public static int abs1(int x) { return x; }
}
"""

comptime _JAVA_PRIV = """package p.q;

public final class Priv {
    private Priv() {}
    public Priv(int x) {}
    public static int priv1(int x) { return x; }
}
"""

comptime _JAVA_PUB = """package p.q;

public final class Pub {
    Pub(String s) {}
    public Pub() {}
    public static String pub1(String x) { return x; }
}
"""

comptime _JAVA_OVER = """package p.o;

public final class Over {
    public static int add(int a, int b) { return a + b; }
    public static double add(double a, double b) { return a + b; }
    public static int one() { return 1; }
}
"""

comptime _JAVA_NOPKG = """public class Top {
    public static int top(int x) { return x; }
}
"""

comptime _JAVA_STAYS = """package p.s;

public class Stays {
    public static char only(char c) { return c; }
    public static Object other(Object o) { return o; }
}
"""

comptime _KT_GRADLE = 'build.gradle.kts=plugins { kotlin("jvm") }\n'

comptime _KT_SHAPES = """@file:JvmName("ShapeUtils")
package p.k

fun ok(a: Int, b: Long, c: Short, d: Byte): Int = a
fun fl(a: Float, b: Double): Double { return a + b }
fun nul(a: String?, b: Int?): Long? { return null }
fun arr(a: IntArray, b: LongArray, c: DoubleArray, d: BooleanArray, e: Array<String>): List<Int> { return listOf() }
fun sa(a: ShortArray): Int { return 0 }
fun mp(a: Map<String, Int>, b: MutableMap<String, List<String>>): LinkedHashMap<String, Int> { return LinkedHashMap() }
fun badmap(a: Map<Int, Int>): Int { return 0 }
fun String.ext(): Int { return 0 }
suspend fun sus(): Int { return 0 }
inline fun inl(x: Int): Int { return x }
@JvmName("renamed") fun ren(x: Int): Int { return x }
fun <T> gen(x: T): T { return x }
fun va(vararg xs: Int): Int { return 0 }
fun ch(c: Char): Char { return c }
fun anything(a: Any): Any { return a }
fun st(s: Set<String>): Int { return 0 }
fun sq(): Sequence<Int> { return sequenceOf() }
fun pr(): Pair<Int, Int> { return Pair(1, 2) }
fun higher(g: (Int) -> Int): Int { return g(1) }
fun eb(x: Int) = x
fun unit(x: Int) { }
fun nothing(): Nothing { throw Exception() }
fun cs(c: CharSequence, l: MutableList<Boolean>, it: Iterable<Long>): Collection<Double> { return listOf() }
fun klass(p: Point): Point { return p }
fun rawl(a: List): Int { return 0 }
private fun priv(): Int { return 0 }
internal fun inter(): Int { return 0 }
protected fun prot(): Int { return 0 }

object Registry {
    @JvmStatic fun reg(x: Int): Int { return x }
    fun notStatic(x: Int): Int { return x }
    @JvmStatic private fun hiddenReg(x: Int): Int { return x }
}

class Holder {
    companion object Factory {
        @JvmStatic fun make(x: Int): Int { return x }
        fun plain(x: Int): Int { return x }
    }
    object Nested {
        @JvmStatic fun nest(x: Int): Int { return x }
    }
}

class WithCtor(val x: Int) {
    companion object {
        @JvmStatic fun wc(): Int { return 1 }
    }
}

class Defaults(val x: Int = 1) {
    companion object {
        @JvmStatic fun df(): Int { return 1 }
    }
}

class Empty() {
    companion object {
        @JvmStatic fun em(): Int { return 1 }
    }
}

abstract class Abs {
    companion object {
        @JvmStatic fun ab(): Int = 1
    }
}

class Sec {
    constructor(x: Int) {
    }
    constructor() {
    }
    companion object {
        @JvmStatic fun sec(): Int { return 1 }
    }
}

class SecOnly {
    constructor(x: Int) {
    }
    companion object {
        @JvmStatic fun seco(): Int { return 1 }
    }
}

class PrivCtor private constructor() {
    companion object {
        @JvmStatic fun pc(): Int { return 1 }
    }
}

interface Iface {
    companion object {
        @JvmStatic fun ifc(): Int { return 1 }
    }
}

enum class Colour {
    RED;
    companion object {
        @JvmStatic fun col(): Int { return 1 }
    }
}
"""

comptime _KT_NAME = """package p.k

fun lives(x: Int): Int { return x }
"""

comptime _KT_OVER = """package p.o

fun add(a: Int, b: Int): Int { return a + b }
fun add(a: Double, b: Double): Double { return a + b }
fun one(): Int { return 1 }
"""

comptime _KT_NOPKG = """fun top(x: Int): Int { return x }

object Solo {
    @JvmStatic fun solo(x: Int): Int { return x }
}
"""


def test_jvm_shapes_match_the_phase1_binary() raises:
    """Every type java.rs and kotlin.rs map, each reason an export stays,
    constructors kept or not, holders, a JVM name that is not Java's,
    overloads (bridge's defined-twice error), no package, and a unit whose
    every export stays."""
    var t = _py()
    var java = _case("java-shapes", "", _bridge(".", "src/main/java/p/q/"))
    java.files = [
        _POM,
        "src/main/java/p/q/Shapes.java=" + _JAVA_SHAPES,
        "src/main/java/p/q/Abs.java=" + _JAVA_CTORS,
        "src/main/java/p/q/Priv.java=" + _JAVA_PRIV,
        "src/main/java/p/q/Pub.java=" + _JAVA_PUB,
        "src/main/java/p/o/Over.java=" + _JAVA_OVER,
        "src/main/java/p/s/Stays.java=" + _JAVA_STAYS,
        "src/main/java/Top.java=" + _JAVA_NOPKG,
    ]
    _check(t, java.copy())
    var junits: List[String] = [
        "src/main/java/p/o/",
        "src/main/java/p/s/",
        "src/main/java/",
    ]
    for unit in junits:
        var c = java.copy()
        c.name = "java-unit-" + String(unit.replace("/", "-"))
        c.args = _bridge(".", unit)
        _check(t, c)
    var kt = _case("kotlin-shapes", "", _bridge(".", "src/main/kotlin/p/k/"))
    kt.files = [
        _KT_GRADLE,
        "src/main/kotlin/p/k/Shapes.kt=" + _KT_SHAPES,
        "src/main/kotlin/p/k/9lives.kt=" + _KT_NAME,
        "src/main/kotlin/p/o/Over.kt=" + _KT_OVER,
        "src/main/kotlin/Top.kt=" + _KT_NOPKG,
    ]
    _check(t, kt.copy())
    var kunits: List[String] = ["src/main/kotlin/p/o/", "src/main/kotlin/"]
    for unit in kunits:
        var c = kt.copy()
        c.name = "kotlin-unit-" + String(unit.replace("/", "-"))
        c.args = _bridge(".", unit)
        _check(t, c)
    _ = t["gone"]()


def _java_on_path(t: PythonObject, name: String, files: List[String]) raises:
    """The bridge with only `<D>/bin` on PATH, and with a unit that is not
    in the plan."""
    var k = _case(
        name,
        "tests/fixtures/java",
        _bridge(".", "src/main/java/com/example/text/"),
    )
    k.files = files.copy()
    k.files.append('bin/python3=#!/bin/sh\nexec /usr/bin/python3 "$@"\n')
    k.path = "<D>/bin"
    _check(t, k.copy())
    k.name = name + "-missing"
    k.args = _bridge(".", "nope/")
    _check(t, k)


def test_require_java_matches_the_phase1_binary() raises:
    """The require_java probe: no `java` on PATH, a Java or javac older than 22, one
    that prints no version, the old `1.8` scheme; the probe runs before the
    plan, so a missing unit gets the Java error first."""
    var t = _py()
    var real = 'bin/java=#!/bin/sh\nexec /usr/bin/java "$@"\n'
    _java_on_path(t, "no-java", [])
    _java_on_path(
        t,
        "java-17",
        [
            "bin/java=#!/bin/sh\necho 'openjdk version \"17.0.2\"' >&2\n",
            "bin/javac=#!/bin/sh\necho 'javac 17.0.2'\n",
        ],
    )
    _java_on_path(
        t, "javac-21", [real, "bin/javac=#!/bin/sh\necho 'javac 21.0.4'\n"]
    )
    _java_on_path(t, "no-version", ["bin/java=#!/bin/sh\necho 'hello'\n"])
    _java_on_path(
        t,
        "java-8",
        ["bin/java=#!/bin/sh\necho 'java version \"1.8.0_281\"' >&2\n"],
    )
    _java_on_path(t, "no-javac", [real])
    _ = t["gone"]()


comptime _JAVA_EDITED = """# A port with a helper and a public function the manifest does not name.


def _clamp(x: Int32) -> Int32:
    return x


def slugify(text: String, max: Int32) raises -> String:
    return text


def helper(x: Int) -> Int:
    return x
"""


def test_jvm_refresh_matches_the_phase1_binary() raises:
    """Refresh of mojo-jvm units from their stubs, from the fixtures' ports,
    from an edited port, and without port.mojo."""
    var t = _py()
    var java = "src/main/java/com/example/text/"
    var c = _case("refresh-java", "tests/fixtures/java", ["refresh"])
    c.bridge = java
    c.cwd = "/mojo/text-mojo"
    _check(t, c.copy())
    var ported = c.copy()
    ported.name = "refresh-java-ported"
    ported.port = ["mojo/text-mojo=tests/fixtures/java-mojo-port/port.mojo"]
    _check(t, ported)
    var edited = c.copy()
    edited.name = "refresh-java-edited"
    edited.files = ["mojo/text-mojo/port.mojo=" + _JAVA_EDITED]
    _check(t, edited.copy())
    var noport = c.copy()
    noport.name = "refresh-java-noport"
    noport.files = ["!mojo/text-mojo/port.mojo="]
    _check(t, noport)
    var kt = _case(
        "refresh-kotlin", "tests/fixtures/kotlin", ["refresh", "mojo/text-mojo"]
    )
    kt.bridge = "src/main/kotlin/com/example/text/"
    _check(t, kt.copy())
    var kt_ported = kt.copy()
    kt_ported.name = "refresh-kotlin-ported"
    kt_ported.port = [
        "mojo/text-mojo=tests/fixtures/kotlin-mojo-port/port.mojo"
    ]
    _check(t, kt_ported)
    var owners = _case(
        "refresh-owners",
        "tests/fixtures/kotlin-owners",
        ["refresh", "mojo/owners-mojo"],
    )
    owners.bridge = "src/main/kotlin/com/example/owners/"
    _check(t, owners.copy())
    var owners_ported = owners.copy()
    owners_ported.name = "refresh-owners-ported"
    owners_ported.port = [
        "mojo/owners-mojo=tests/fixtures/kotlin-mojo-port/owners.mojo"
    ]
    _check(t, owners_ported)
    _ = t["gone"]()


def main() raises:
    test_jvm_fixtures_are_bridged_in_mojo()
    test_jvm_shapes_match_the_phase1_binary()
    test_require_java_matches_the_phase1_binary()
    test_jvm_refresh_matches_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_bridge_jvm: 4 passed")
