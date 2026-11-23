# `analyze` of Python workspaces in Mojo (src/analyze.rs, src/report.rs,
# src/lang/python.rs read through CPython's `ast`, src/risks.rs, the crate
# table and bridge::js_only_reason): the Mojo binary runs next to the Phase 1
# binary on copies of the same project, and the two must agree byte for byte
# with no fallback logged; a file `ast` may read otherwise than tree-sitter
# goes to the Phase 1 binary.

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
    base = os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-py-%d" % os.getpid(), side)
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
    shutil.rmtree(os.path.join(tempfile.gettempdir(), "mojo-anything-test-analyze-py-%d" % os.getpid()),
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


comptime _WORDS = '''"""Word utilities."""
import dataclasses
import re
import unicodedata
from typing import Optional

_SEPARATORS = re.compile(r"[^\\w]+")


def slugify(text: str, sep: str = "-", *, max_length: Optional[int] = None) -> str:
    normalized = unicodedata.normalize("NFKD", text)
    ascii_only = "".join(c for c in normalized if not unicodedata.combining(c))
    words = [w for w in _SEPARATORS.split(ascii_only.lower()) if w]
    slug = sep.join(words)
    if max_length is not None:
        slug = slug[:max_length].rstrip(sep)
    return slug


def chunk(items: list[int], size: int) -> list[list[int]]:
    if size <= 0:
        raise ValueError("size must be positive")
    return [items[i:i + size] for i in range(0, len(items), size)]


def page_count(total: int, per_page: int) -> int:
    return -(-total // per_page)


@dataclasses.dataclass
class Limits:
    max_length: Optional[int] = None


def walk(items):
    for item in items:
        yield item


def apply(fn, value):
    return fn(value)


def configure(**options):
    return options
'''

comptime _STACK = '''from typing import Optional


class Stack:
    """A bounded stack."""

    def __init__(self, capacity: int = 8):
        if capacity < 1:
            raise ValueError("capacity must be at least 1")
        self._items: list[str] = []

    def push(self, item: str) -> int:
        self._items.append(item)
        return len(self._items)

    def pop(self) -> Optional[str]:
        return self._items.pop() if self._items else None
'''

comptime _RISKS = """import re
import threading
import time
import random
from datetime import datetime
from numba import njit


async def fetch(client, url: str) -> str:
    data = await client.get(url)
    return await data.text()


def gen(n: int):
    yield from range(n)
    yield n


@njit
def fast(x: float) -> float:
    return x ** 2 + (x << 1) + (x & 3) | 4 ^ 5 >> 1


def dynamic(code: str, obj, name: str):
    eval(code)
    exec(code)
    getattr(obj, name)
    isinstance(obj, int)
    kind = type(obj)
    globals()
    vars(obj)
    return set([1, 2]) | {1, 2} | {x for x in range(3)} | frozenset()


def clock() -> float:
    random.random()
    datetime.now()
    threading.Thread(target=clock)
    return time.time()


def regexes(p: str, s: str) -> str:
    re.compile(r"(?<=a)b")
    re.sub(p, "", s)
    re.match(r"(a)\\1", s)
    re.findall("plain", s)
    re.compile()
    return s[1:2] + s[::2] + str(s.find("a")) + str(s.rindex("a")) + str(s.rfind("b"))


def arith(a: int, b: int) -> int:
    a //= b
    a %= b
    a **= 2
    a <<= 1
    a &= 3
    total = 0
    while a > 0:
        a -= 1
        total += {k: k for k in range(a)}[0] if a else 0
    return a % b + total


class Base:
    pass


class Child(Base):
    pass


class Empty():
    pass


Base.extra = 1
Child.x = Base.y = 2


def tried(x: int) -> int:
    try:
        return 1 // x
    except ZeroDivisionError:
        raise


def arrays(a: "np.ndarray", b: list[float], *rest: NDArray) -> None:
    return None
"""

comptime _EXPORTS = """__version__ = "1.0"
__all__ = ["shown", "Kept", "Shape", "entry", "make_parser", "Cached"]

import argparse
from functools import lru_cache
from typing import Callable, Iterator


def shown(x: int) -> int:
    return x


def hidden(x: int) -> int:
    return x


def entry(argv: list[str]) -> int:
    return 0


def make_parser() -> argparse.ArgumentParser:
    return argparse.ArgumentParser()


@lru_cache(maxsize=None)
def Cached(n: int) -> int:
    return n


class Kept:
    def __init__(self, n: int):
        self._n = n

    def value(self) -> int:
        return self._n

    def copy(self) -> "Kept":
        return Kept(self._n)


class Shape(object):
    sides = 3

    def area(self) -> float:
        return 0.0

    def __repr__(self) -> str:
        return "Shape"

    @property
    def name(self) -> str:
        return "shape"

    async def later(self) -> None:
        return None

    def points(self) -> Iterator[int]:
        yield 1


if __name__ == "__main__":
    entry([])
"""

comptime _TYPES = """from typing import Callable, Iterator, Generator, Optional


def takes_fn(f: Callable[[int], int]) -> int:
    return 1


def gives_iter() -> Iterator[int]:
    return iter([])


def opt_fn(f: Optional[Callable[[], None]] = None) -> None:
    return None


def gen_type() -> "Generator[int, None, None]":
    return None


def fine(a: dict[str, list[float]], b: tuple[int, int], c: "Literal['a', 'b']") -> list[Optional[str]]:
    return []


class Point:
    def __init__(self, x: float, y: float):
        self.x = x
        self.y = y


class Pair:
    def __init__(self, *items):
        self._items = items


class Meta(metaclass=type):
    pass


def _private():
    return None
"""

comptime _MAIN = """import sys
from .core import run

def helper(x):
    return x

run(sys.argv)
helper(1)
"""

comptime _CORE = """from . import util
from .util import fmt
from ..outside import nothing
import pkg.util
import requests
import numpy as np
import yaml
import django
import mylocal.sub


def run(argv: list[str]) -> int:
    return len(argv)
"""

comptime _UTIL = """from .core import run


def fmt(x: int) -> str:
    return str(x)
"""


def test_python_plans_match_the_phase1_binary() raises:
    """Units, waves, risks, exports, tests, packages and dependencies of
    Python workspaces, in Markdown and JSON."""
    var t = _py()
    var dot: List[String] = ["analyze", "."]
    _both_ways(
        t,
        "textkit",
        [
            String(
                'pyproject.toml=[project]\nname = "Text_Kit.x"\ndependencies'
                ' = ["regex>=2024.1", "requests"]\n'
            ),
            (
                "src/textkit/__init__.py=from .words import slugify\nfrom"
                " .stack import Stack\n"
            ),
            "src/textkit/words.py=" + _WORDS,
            "src/textkit/stack.py=" + _STACK,
            (
                "tests/test_words.py=from textkit.words import slugify,"
                " chunk\n\n\ndef test_slugify():\n    assert slugify('a') =="
                " 'a'\n"
            ),
            "tests/conftest.py=import pytest\n",
            "setup.py=from setuptools import setup\nsetup()\n",
        ],
        dot,
    )
    _both_ways(t, "risks", ["risks.py=" + _RISKS], dot)
    _both_ways(
        t,
        "exports",
        [
            "exports.py=" + _EXPORTS,
            "types.py=" + _TYPES,
            "tool/__main__.py=" + _MAIN,
            "tool/core.py=" + _CORE,
            "tool/util.py=" + _UTIL,
            "pkg/util.py=def f(x: int) -> int:\n    return x\n",
            "mylocal/x/sub.py=x = 1\n",
            "test_tool.py=from tool.core import run\nimport pkg\n",
            "requirements.txt=# deps\nrequests>=2\n\n-r other.txt\nNumPy\n",
        ],
        dot,
    )
    _both_ways(
        t,
        "workspace",
        [
            (
                'pyproject.toml=[project]\nname = "app"\ndependencies ='
                ' ["core-lib"]\n'
            ),
            (
                "app.py=import core_lib\nimport b\n\n\ndef main(x: int) ->"
                " int:\n    return x\n"
            ),
            'libs/core/pyproject.toml=[project]\nname = "Core_Lib"\n',
            "libs/core/src/core_lib/__init__.py=from .a import f\n",
            (
                "libs/core/src/core_lib/a.py=from .b import g\n\n\ndef f(x:"
                " int) -> int:\n    return g(x)\n"
            ),
            (
                "libs/core/src/core_lib/b/__init__.py=from ..a import"
                " f\n\n\ndef g(x: int) -> int:\n    return x\n"
            ),
            "libs/core/tests/test_a.py=from core_lib.a import f\n",
            "b.py=import app\n",
            "docs/conf.py=x = 1\n",
            "build/gen.py=x = 1\n",
            ".hidden/h.py=x = 1\n",
            "notes.PY=x = 1\n",
        ],
        dot,
    )
    var many = List[String]()
    for i in range(12):
        var body = String("def f", i, "(s: str) -> str:\n")
        for _ in range(i * 3):
            body += "    s = s[1:] + s.lower()\n"
        body += "    return s\n"
        many.append(String("pkg/m", i, ".py=") + body)
    many.append("pyproject.toml=[project]\nname = 'many'\n")
    _both_ways(t, "many", many, dot)
    _both_ways(
        t,
        "lang-flag",
        [
            "main.go=package main\n",
            "a.py=def f(x: int) -> int:\n    return x\n",
        ],
        ["analyze", ".", "--lang", "python"],
    )
    _both_ways(
        t,
        "unreadable",
        [
            "bad.py=b64:eCA9ICf/Jwo=",
            "good.py=def f(x: int) -> int:\n    return x\n",
        ],
        dot,
    )
    _both_ways(t, "nested-root", ["inner/a.py=x = 1\n"], ["analyze", "inner"])


def test_out_writes_a_python_plan() raises:
    var t = _py()
    assert_equal(
        _both(
            t,
            "out",
            ["a.py=def f(x: int) -> int:\n    return x\n"],
            ["analyze", ".", "-o", "plan.md"],
        ),
        "",
        "fell back in out",
    )


def test_what_ast_may_read_otherwise_goes_to_the_phase1_binary() raises:
    """Files where `ast` and tree-sitter-python could disagree."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("syntax", "a.py=def f(:\n"))
    cases.append(("match", "a.py=match x:\n    case 1:\n        pass\n"))
    cases.append(("comment", "a.py=f(1,  # one\n  2)\n"))
    cases.append(("fstring", 'a.py=x = f"{\'a\'}"\ny = f"{"b"}"\n'))
    cases.append(("crlf", "a.py=x = 1\r\ny = 2\r\n"))
    cases.append(("parens", "a.py=(eval)('1')\n"))
    cases.append(("union", "a.py=def f(x: int | None) -> int:\n    return 1\n"))
    cases.append(("type-params", "a.py=def f[T](x: T) -> T:\n    return x\n"))
    cases.append(("bad-toml", "pyproject.toml=x\n|a.py=x = 1\n"))
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        var log = _both(t, c[0], spec, ["analyze", "."])
        assert_equal(log, "analyze .\n", "fallback of " + c[0])


def main() raises:
    test_python_plans_match_the_phase1_binary()
    test_out_writes_a_python_plan()
    test_what_ast_may_read_otherwise_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_analyze_python: 3 passed")
