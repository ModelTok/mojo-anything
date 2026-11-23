# `analyze` in Mojo (src/analyze.rs, src/report.rs, the discovery halves of
# src/ts/discover.rs and src/lang/*.rs, and Lang::detect): the Mojo binary runs
# next to the Phase 1 binary on copies of the same project, and the two must
# agree byte for byte (stdout, stderr, exit code and the files written) with no
# fallback logged where Mojo owns the case, and with the fallback logged where
# it does not.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

from mojo_anything.analyze import detect_lang

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

def fixture(side, name, files):
    base = os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-%d" % os.getpid(), side)
    d = os.path.join(base, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for rel, text in files:
        p = os.path.join(d, rel)
        if rel.endswith("/"):
            os.makedirs(p, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    return d

def gone():
    shutil.rmtree(os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-%d" % os.getpid()),
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


def _owned(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises:
    var log = _both(t, name, spec, args)
    assert_equal(log, "", "fell back in " + name)


def _both_ways(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises:
    """Markdown and `--json`."""
    _owned(t, name, spec, args)
    var j = args.copy()
    j.append("--json")
    _owned(t, name, spec, j)


def test_detects_the_language_as_the_phase1_tool() raises:
    """Lang::detect's manifests first, then the most common source files."""
    var t = _py()
    var cases: List[Tuple[String, String]] = [
        ("go.mod=module x\n|pom.xml=<project/>\n", "go"),
        ("build.gradle.kts=x\n|src/main/kotlin/A.kt=package a\n", "kotlin"),
        (
            "build.gradle.kts=x\n|src/main/kotlin/A.kt=x\n|src/main/java/B.java=x\n",
            "java",
        ),
        ("build.gradle.kts=x\n", "java"),
        ("pom.xml=x\n|src/main/kotlin/A.kt=x\n", "java"),
        # Lang::detect keeps a build/ folder with no src component and
        # prunes one with it (checked against the Phase 1 binary).
        ("build/A.kt=x\n|build.gradle=x\n", "kotlin"),
        ("src/build/A.kt=x\n|build.gradle=x\n", "java"),
        ("x.sln=x\n|package.json={}\n", "csharp"),
        ("Directory.Build.props=x\n", "csharp"),
        ("setup.cfg=x\n|Gemfile=x\n", "python"),
        ("Gemfile=x\n|composer.json={}\n", "ruby"),
        ("composer.json={}\n|package.json={}\n", "php"),
        ("package.json={}\n|a.py=x\n", "ts"),
        ("a.py=x\n|b.rb=x\n|c.rb=x\n", "ruby"),
        ("a.py=x\n|b.rb=x\n", "python"),
        ("src/a.cpp=x\n|src/a.h=x\n|src/b.h=x\n|src/c.h=x\n", "cpp"),
        ("src/a.c=x\n|src/b.c=x\n|src/a.h=x\n|src/x.cpp=x\n", "c"),
        ("a.mojo=x\n", "ts"),
        (".hidden/a.py=x\n|b.go=x\n", "go"),
    ]
    for c in cases:
        var spec = List[String]()
        for part in c[0].split("|"):
            spec.append(String(part))
        var d = String(
            py=t["fixture"](
                PythonObject("detect"), PythonObject("p"), _files(spec)
            )
        )
        assert_equal(detect_lang(d), c[1], c[0])


def test_empty_plans_match_the_phase1_binary() raises:
    """Workspaces with no source file of their language: the packages each
    language's discovery finds, the empty plan in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(t, "only-mojo", ["textops.mojo=def main(): pass\n"], dot)
    _both_ways(t, "go-reqs", ["go.mod=module x\n\ngo 1.22\n"], dot)
    _both_ways(
        t,
        "go-modules",
        ["go.mod=module a\n", "sub/go.mod=module b\n", "vendor/go.mod=x\n"],
        dot,
    )
    _both_ways(t, "ruby-gems", ["Gemfile=gem 'rake'\n"], dot)
    _both_ways(
        t, "ruby-sub", ["Gemfile=x\n", "a/x.gemspec=x\n", "a/Gemfile=x\n"], dot
    )
    _both_ways(t, "java-pom", ["pom.xml=<project/>\n"], dot)
    _both_ways(
        t,
        "java-modules",
        [
            "build.gradle=x\n",
            "a/pom.xml=x\n",
            "a/build.gradle=x\n",
            "b/pom.xml=x\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "kotlin-dsl",
        ["build.gradle.kts=x\n", "app/build.gradle.kts=x\n"],
        dot,
    )
    _both_ways(
        t, "csharp", ["App.csproj=<Project/>\n", "t/T.csproj=<Project/>\n"], dot
    )
    _both_ways(t, "csharp-props", ["Directory.Build.props=x\n"], dot)
    _both_ways(t, "python-reqs", ["requirements.txt=rich\n"], dot)
    _both_ways(
        t,
        "python-pkgs",
        [
            "pyproject.toml=x\n",
            "lib/setup.cfg=x\n",
            "lib/pyproject.toml=x\n",
            "docs/setup.cfg=x\n",
        ],
        dot,
    )
    _both_ways(t, "python-sub", ["setup.cfg=x\n", "a/pyproject.toml=x\n"], dot)
    _both_ways(t, "php", ["composer.json={}\n", "sub/composer.json={}\n"], dot)
    _both_ways(
        t,
        "ts-pkgs",
        [
            "package.json={}\n",
            'packages/a/package.json={"name": "a"}\n',
            "node_modules/b/package.json=x\n",
        ],
        dot,
    )
    _both_ways(
        t, "ts-sub", ["packages/a/package.json={}\n", "README.md=x\n"], dot
    )
    _both_ways(
        t, "ignored", [".gitignore=sub/\n", "sub/go.mod=x\n", "go.mod=x\n"], dot
    )
    _both_ways(t, "hidden", [".hidden/go.mod=x\n", "go.mod=x\n"], dot)
    _both_ways(
        t,
        "bridged",
        ["go.mod=x\n", "port/mojo-anything.json={}\n", "port/go.mod=x\n"],
        dot,
    )
    var empty = List[String]()
    _both_ways(t, "empty", empty, dot)
    for lang in [
        "ts",
        "python",
        "c",
        "go",
        "ruby",
        "java",
        "kotlin",
        "php",
        "csharp",
        "cpp",
    ]:
        _both_ways(
            t,
            "lang-" + lang,
            [
                "Makefile=x\n",
                "lib/CMakeLists.txt=x\n",
                "pom.xml=x\n",
                "a/go.mod=x\n",
            ],
            ["analyze", ".", "--lang", lang],
        )
    _both_ways(t, "nested", ["inner/go.mod=x\n"], ["analyze", "inner"])
    _both_ways(t, "default-root", ["go.mod=x\n"], ["analyze"])


def test_root_errors_match_the_phase1_binary() raises:
    var t = _py()
    var empty = List[String]()
    _owned(t, "missing", empty, ["analyze", "missing-dir"])
    _owned(t, "missing-json", empty, ["analyze", "missing-dir", "--json"])
    _both_ways(
        t, "missing-go", empty, ["analyze", "missing-dir", "--lang", "go"]
    )
    _owned(t, "jar", ["app.jar=x"], ["analyze", "app.jar"])
    _owned(t, "upper-apk", ["App.APK=x"], ["analyze", "App.APK"])
    _owned(t, "text", ["notes.txt=x"], ["analyze", "notes.txt"])
    _owned(t, "no-ext", ["Makefile=x"], ["analyze", "Makefile", "--json"])


def test_out_writes_the_plan() raises:
    var t = _py()
    _owned(t, "out-md", ["go.mod=x\n"], ["analyze", ".", "--out", "plan.md"])
    _owned(
        t,
        "out-json",
        ["go.mod=x\n"],
        ["analyze", ".", "-o", "p.json", "--json"],
    )
    _owned(
        t,
        "out-sub",
        ["go.mod=x\n", "docs/"],
        ["analyze", ".", "-o", "docs/plan.md"],
    )


def test_what_is_not_ported_goes_to_the_phase1_binary() raises:
    """Source files, warnings and `--whole-app` still run the Phase 1 binary,
    and it answers them."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(
        ("python", "pyproject.toml=x\n|pkg/core.py=def f(x):\n    return x\n")
    )
    cases.append(("ts", "package.json={}\n|src/a.ts=export const a = 1;\n"))
    cases.append(("compiled", "go.mod=x\n|lib/a.so=x"))
    cases.append(
        ("ignored-src", ".gitignore=*.go\n|go.mod=x\n|a.go=package a\n")
    )
    cases.append(("bad-json", "package.json={\n"))
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        assert_equal(log, "analyze .\n", "fallback of " + c[0])
    var w = _both(t, "whole", ["go.mod=x\n"], ["analyze", ".", "--whole-app"])
    assert_equal(w, "analyze .\n", "fallback of --whole-app")


def test_ts_ignore_files_with_plain_patterns_are_read() raises:
    """A TS walk stops at an ignore file the ignore crate cannot parse; plain
    patterns (no class, no alternates, no trailing escape) parse, and the
    walk reads them as the other languages' walks do."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "ts-ignores",
        [
            ".gitignore=dist/\n*.log\n# a comment\n\n!keep.log\n",
            ".ignore=skipped/\n",
            "skipped/package.json={}\n",
            "kept/package.json={}\n",
            "port/mojo-anything.json={}\n",
            "port/.gitignore=.mojo-anything/\n.pixi/\ncases.jsonl\n",
        ],
        dot,
    )
    var log = _both(t, "ts-bad-ignore", [".gitignore=a[\n"], dot)
    assert_equal(log, "analyze .\n", "fallback of a class in .gitignore")


def test_review_findings_go_to_the_phase1_binary() raises:
    """What the Rust tool answers otherwise than an empty plan: a root folder
    named like a compiled file (Rust warns: its compiled walk sees the root
    itself), a package.json integer beyond f64 (serde_json: number out of
    range), brace alternates in an ignore file (globset reads them, the Mojo
    walk does not)."""
    var t = _py()
    var zeros = String("")
    for _ in range(400):
        zeros += "0"
    var cases = List[Tuple[String, String, String]]()
    cases.append(("so-root", "lib.so/go.mod=module x\n", "lib.so"))
    cases.append(("jar-root", "app.JAR/go.mod=module x\n", "app.JAR/"))
    cases.append(("big-int", 'package.json={"n": 1' + zeros + "}\n", "."))
    cases.append(
        (
            "braces",
            ".gitignore={legacy,old}/\n|go.mod=x\n|legacy/go.mod=x\n",
            ".",
        )
    )
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", c[2]])
        assert_equal(log, "analyze " + c[2] + "\n", "fallback of " + c[0])


def main() raises:
    test_detects_the_language_as_the_phase1_tool()
    test_empty_plans_match_the_phase1_binary()
    test_root_errors_match_the_phase1_binary()
    test_out_writes_the_plan()
    test_what_is_not_ported_goes_to_the_phase1_binary()
    test_ts_ignore_files_with_plain_patterns_are_read()
    test_review_findings_go_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze: 7 passed")
