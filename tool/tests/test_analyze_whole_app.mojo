# `analyze --whole-app` of Python workspaces in Mojo (src/whole_app.rs and
# the whole-app section of src/report.rs over analyze's plan): the Mojo
# binary runs next to the Phase 1 binary on copies of the same project, and
# the two must agree byte for byte with no fallback logged; what Python's
# readers may read otherwise goes to the Phase 1 binary.

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


comptime _PYPROJECT = """[project]
name = "tool"
version = "1.0"
dependencies = [
    "Requests>=2",
    "PyYAML",
    "numpy ; python_version > '3'",
    "git+https://example.com/y.git",
    "./local.whl",
    "Click_Extra[all]",
    3,
]

[project.scripts]
tool = "tool.cli:main"
other = "tool.other:run"
odd = 1
"""

comptime _CLI = """import sys

import requests
import yaml

from tool import core


def main():
    text = sys.argv[1]
    print(core.count(text) // 2)


if __name__ == "__main__":
    main()
"""

comptime _CORE = """import numpy


def count(text):
    n = 0
    for word in text.split():
        n += len(word) % 3
    return n
"""

comptime _SERVER = """from flask import Flask

app = Flask(__name__)


def hello():
    return "hi"


if __name__ == "__main__":
    app.run()
"""


def _whole(t: PythonObject, name: String, spec: List[String]) raises:
    _both_ways(t, name, spec, ["analyze", ".", "--whole-app"])


def test_whole_app_plans_match_the_phase1_binary() raises:
    """Entry points from pyproject scripts and the code, every dependency
    (imported or declared, requirements files and their includes), pieces
    and decisions, in Markdown and JSON."""
    var t = _py()
    _whole(
        t,
        "cli",
        [
            "pyproject.toml=" + _PYPROJECT,
            (
                "requirements.txt=# pinned\nclick==8.1\n-r more/extra.txt\n"
                "--requirement=more/extra.txt\n-e .\nflask @ https://x\n\n"
            ),
            "more/extra.txt=-r ../requirements.txt\nrich>=13 # pretty\nb_c.D\n",
            "tool/__init__.py=",
            "tool/cli.py=" + _CLI,
            "tool/core.py=" + _CORE,
        ],
    )
    _whole(
        t,
        "server",
        ["requirements.txt=flask\n", "app.py=" + _SERVER],
    )
    _whole(
        t,
        "library",
        [
            (
                "pyproject.toml=[tool.poetry]\nname = 'lib'\n\n"
                "[tool.poetry.dependencies]\npython = '^3.10'\nrequests ="
                " '*'\nNumpy_Fast = '1'\n"
            ),
            "lib/__init__.py=",
            "lib/a.py=from lib import b\n\n\ndef fa(x):\n    return b.fb(x)\n",
            "lib/b.py=from lib import a\n\n\ndef fb(x):\n    return a.fa(x)\n",
            (
                "lib/fast.py=from numba import njit\n\n\n@njit\ndef f(x):\n"
                "    return x * 2\n"
            ),
            "lib/c.py=import requests\n\n\ndef fc(x):\n    return x\n",
        ],
    )
    _whole(
        t,
        "poetry-cli",
        [
            (
                "pyproject.toml=[tool.poetry]\nname = 'p'\n\n"
                "[tool.poetry.scripts]\ncli = 'p.cli:main'\n"
            ),
            "p/__init__.py=",
            (
                "p/cli.py=def main():\n    return 0\n\n\nif __name__ =="
                ' "__main__":\n    main()\n'
            ),
        ],
    )


def test_out_writes_a_whole_app_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            ["requirements.txt=flask\n", "app.py=" + _SERVER],
            ["analyze", ".", "--whole-app", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_python_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """A package.json (read as serde_json reads it), a regex trigger next to
    text outside ASCII, a requirements file outside ASCII, and C# and TS
    workspaces."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(
        (
            "package-json",
            (
                "pyproject.toml=[project]\nname ="
                " 'x'\n|package.json={}\n|a.py=x = 1\n"
            ),
        )
    )
    cases.append(
        ("non-ascii", "requirements.txt=x\n|a.py=s = 'é'\napp.run()\n")
    )
    cases.append(("requirements", "requirements.txt=café\n|a.py=x = 1\n"))
    cases.append(
        (
            "csharp",
            (
                'tool.csproj=<Project Sdk="Microsoft.NET.Sdk" />\n|A.cs=class A'
                " {}\n"
            ),
        )
    )
    cases.append(
        ("ts", 'package.json={"name": "t"}\n|a.ts=export const x = 1;\n')
    )
    # tomllib reads integers past i64 and floats that overflow; toml_edit
    # refuses the file, so Rust reads no scripts and no dependencies.
    for big in ["99999999999999999999", "1e999", "-1e999"]:
        cases.append(
            (
                "big-" + big,
                (
                    "pyproject.toml=[project]\nname = 'tool'\ndependencies ="
                    " ['Requests>=2']\n[project.scripts]\ntool ="
                    " 'tool.cli:main'\n[tool.x]\nn = "
                    + big
                    + "\n|tool/__init__.py=|tool/cli.py="
                    + _CLI
                ),
            )
        )
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", ".", "--whole-app"])
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


comptime _GO_MOD = """module example.com/tool

go 1.21

require (
	github.com/a/b v1.0.0
	github.com/c/d v1.0.0 // indirect
	// github.com/e/f v1.0.0
)

require golang.org/x/text v0.3.0
"""

comptime _GEMSPEC = """Gem::Specification.new do |s|
  s.name = "tool"
  s.executables = %w[tool other]
  s.add_dependency 'json'
  s.add_runtime_dependency("rake")
  s.add_development_dependency "minitest"
end
"""

comptime _GEMFILE = """source 'https://rubygems.org'
gem 'sinatra'
group :test do
  platform :mri do
    gem 'pry'
  end
  gem 'rspec'
end
gem 'puma'
"""

comptime _POM = """<project>
  <dependencies>
    <dependency>
      <groupId>com.google.guava</groupId>
      <artifactId>guava</artifactId>
    </dependency>
    <dependency>
      <groupId>junit</groupId>
      <artifactId>junit</artifactId>
      <scope>test</scope>
    </dependency>
    <!-- <dependency><groupId>a.b</groupId><artifactId>c</artifactId></dependency> -->
  </dependencies>
</project>
"""

comptime _GRADLE = """dependencies {
    implementation("org.slf4j:slf4j-api:2.0.0")
    api 'com.squareup:okio:3.0.0'
    // implementation("x.y:z:1")
    /* compile("p.q:r:1") */
    testImplementation("junit:junit:4")
}
"""

comptime _COMPOSER = """{
  "name": "acme/tool",
  "bin": ["./bin/tool", "bin/other"],
  "require": {"php": ">=8", "ext-json": "*", "guzzlehttp/guzzle": "^7"}
}
"""


def test_other_languages_match_the_phase1_binary() raises:
    """Go (`cmd/` folders, go.mod requirements, `package main`), C and C++
    mains, Ruby (gemspec executables and dependencies, Gemfile groups),
    Java and Kotlin (pom.xml, Gradle, comments), PHP (composer.json `bin`
    and `require`, a front controller), in Markdown and JSON."""
    var t = _py()
    _whole(
        t,
        "go-cmd",
        [
            "go.mod=" + _GO_MOD,
            "cmd/tool/main.go=package main\n\nfunc main() {\n}\n",
            "cmd/zz/main.go=package main\n\nfunc main() {\n}\n",
            "lib.go=package tool\n\nfunc F(a int) int {\n\treturn a * 2\n}\n",
        ],
    )
    _whole(
        t,
        "go-server",
        [
            "go.mod=module example.com/srv\n\ngo 1.22\n",
            (
                'main.go=package main\n\nimport "net/http"\n\nfunc main()'
                ' {\n\thttp.ListenAndServe(":8080", nil)\n}\n'
            ),
        ],
    )
    _whole(
        t,
        "c-main",
        [
            "tool.c=#include <stdio.h>\n\nint main(void) {\n  return 0;\n}\n",
            "util.c=int twice(int x) { return x * 2; }\n",
        ],
    )
    _whole(
        t,
        "cpp-main",
        [
            "tool.cpp=int add(int a, int b) { return a + b; }\nint main() {"
            " return add(1, 2); }\n"
        ],
    )
    _whole(
        t,
        "ruby-gem",
        [
            "tool.gemspec=" + _GEMSPEC,
            "Gemfile=" + _GEMFILE,
            (
                "lib/tool.rb=module Tool\n  def self.twice(a)\n    a * 2\n "
                " end\nend\n"
            ),
        ],
    )
    _whole(
        t,
        "ruby-argv",
        ["tool.rb=def run(args)\n  args.size\nend\n\nputs run(ARGV)\n"],
    )
    _whole(
        t,
        "java-pom",
        [
            "pom.xml=" + _POM,
            (
                "src/main/java/a/Main.java=package a;\n\npublic class Main {\n "
                " public static void main(String[] args) {\n  }\n}\n"
            ),
        ],
    )
    _whole(
        t,
        "kotlin-gradle",
        [
            "build.gradle.kts=" + _GRADLE,
            "src/main/kotlin/a/Main.kt=package a\n\nfun main() {\n}\n",
        ],
    )
    _whole(
        t,
        "php-composer",
        [
            "composer.json=" + _COMPOSER,
            "public/index.php=<?php\necho 'hi';\n",
            "src/Tool.php=<?php\nfunction twice($a) { return $a * 2; }\n",
        ],
    )


def main() raises:
    test_whole_app_plans_match_the_phase1_binary()
    test_out_writes_a_whole_app_plan()
    test_other_languages_match_the_phase1_binary()
    test_what_python_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_whole_app: 4 passed")
