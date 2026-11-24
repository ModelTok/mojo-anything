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
    text outside ASCII, a requirements file outside ASCII, and other
    languages."""
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
    cases.append(("go", "go.mod=module m\n|a.go=package m\n"))
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


def main() raises:
    test_whole_app_plans_match_the_phase1_binary()
    test_out_writes_a_whole_app_plan()
    test_what_python_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_whole_app: 3 passed")
