# What the Mojo tool keeps between runs to start CPython faster (pycache.mojo):
# the CPython library Mojo's interop finds by running python3, and the
# compiled embedded helpers. A run stores both; a later run uses them, a
# stale or damaged entry is found again, and the answers stay those of the
# Phase 1 binary. MOJO_ANYTHING_TEST_BINARY names another binary to test (a
# build from before the cache, to see these tests fail).

from std.os import getenv, setenv, unsetenv
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

from mojo_anything.pycache import python_entry, python_key

comptime FALLBACK = "tool/fallback/mojo-anything"


def _binary() -> String:
    var given = getenv("MOJO_ANYTHING_TEST_BINARY")
    if given.byte_length() > 0:
        return given
    return "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import glob, os, shutil, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-pycache-%d" % os.getpid())
PROBE = '''
import os
import sys
from pathlib import Path
from sysconfig import get_config_var
ext = "dll" if os.name == "nt" else "dylib" if sys.platform == "darwin" else "so"
pyver = get_config_var("py_version_short")
abiflags = get_config_var("ABIFLAGS") or ""
binary = f"libpython{pyver}{abiflags}.{ext}"
for libpython in [Path(get_config_var(p)) / binary for p in ["LIBPL", "LIBDIR"]]:
    if libpython.exists():
        print(libpython.resolve())
        exit(0)
exit(1)
'''

def setup():
    shutil.rmtree(BASE, ignore_errors=True)
    for d in ("cache", "bin", "py", "ts", "extra"):
        os.makedirs(os.path.join(BASE, d))
    with open(os.path.join(BASE, "py", "kit.py"), "w") as f:
        f.write("import os\\n\\n\\ndef add(a: int, b: int) -> int:\\n    return a + b\\n")
    with open(os.path.join(BASE, "ts", "package.json"), "w") as f:
        f.write('{"name": "kit", "version": "1.0.0"}\\n')
    with open(os.path.join(BASE, "ts", "kit.ts"), "w") as f:
        f.write("export function add(a: number, b: number): number {\\n  return a + b;\\n}\\n")
    # A node that says which CPython library its parent started with, then fails
    # (the TS reader declines and the command goes to the Phase 1 binary).
    node = os.path.join(BASE, "bin", "node")
    with open(node, "w") as f:
        f.write('#!/bin/sh\\necho "$MOJO_PYTHON_LIBRARY" >> "%s"\\nexit 1\\n' % os.path.join(BASE, "node.log"))
    os.chmod(node, 0o755)
    return BASE

def env(extra_path=False):
    e = dict(os.environ)
    for k in ("MOJO_PYTHON_LIBRARY", "MOJO_PYTHON", "MOJO_ANYTHING_FALLBACK_LOG"):
        e.pop(k, None)
    e["XDG_CACHE_HOME"] = os.path.join(BASE, "cache")
    e["PATH"] = os.path.join(BASE, "bin") + ":" + os.environ["PATH"]
    if extra_path:
        e["PATH"] += ":" + os.path.join(BASE, "extra")
    return e

def probe(e):
    return subprocess.run(["python3", "-c", PROBE], env=e, capture_output=True, text=True,
                          stdin=subprocess.DEVNULL).stdout.strip()

def run(binary, args, e):
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=BASE, env=e,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
    return (p.returncode, p.stdout, p.stderr)

def read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""

def write(path, text):
    with open(path, "w") as f:
        f.write(text)

def node_log():
    text = read(os.path.join(BASE, "node.log"))
    os.makedirs(BASE, exist_ok=True)
    write(os.path.join(BASE, "node.log"), "")
    return text

def copy_library(lib):
    dst = os.path.join(BASE, "libpython-copy.so")
    shutil.copy(lib, dst)
    return dst

def bytecode():
    return sorted(glob.glob(os.path.join(BASE, "cache", "mojo-anything", "pyc-*", "*.bin")))

def spoil(paths):
    for p in paths:
        with open(p, "wb") as f:
            f.write(b"not marshal")

def spoilt(paths):
    out = 0
    for p in paths:
        with open(p, "rb") as f:
            out += f.read() == b"not marshal"
    return out

def gone():
    shutil.rmtree(BASE, ignore_errors=True)
""",
        scope,
    )
    return scope


def _args(xs: List[String]) raises -> PythonObject:
    var out = Python.list()
    for x in xs:
        out.append(PythonObject(x))
    return out


def _same(
    t: PythonObject, args: List[String], env: PythonObject, what: String
) raises:
    var n = t["run"](PythonObject(_binary()), _args(args), env)
    var o = t["run"](PythonObject(FALLBACK), _args(args), env)
    assert_equal(
        String(py=n[1].decode()), String(py=o[1].decode()), "stdout " + what
    )
    assert_equal(
        String(py=n[2].decode()), String(py=o[2].decode()), "stderr " + what
    )
    assert_equal(Int(py=n[0]), Int(py=o[0]), "exit code " + what)


def _key_for(env: PythonObject) raises -> String:
    """python_key() as the binary computes it under `env`."""
    _ = unsetenv("MOJO_PYTHON_LIBRARY")
    _ = unsetenv("MOJO_PYTHON")
    _ = setenv("PATH", String(py=env["PATH"]))
    _ = setenv("XDG_CACHE_HOME", String(py=env["XDG_CACHE_HOME"]))
    return python_key()


def test_library_is_remembered_and_used() raises:
    var t = _py()
    _ = t["setup"]()
    var path = getenv("PATH")
    var env = t["env"]()
    var key = _key_for(env)
    assert_true(key.byte_length() > 0, "a python3 on PATH that can be cached")
    var entry = python_entry(key)
    var lib = String(py=t["probe"](env))
    assert_true(lib.byte_length() > 0, "python3 finds its library")

    # A run that starts Python stores the library Mojo found.
    _same(t, ["analyze", "py"], env, "of the first run")
    assert_equal(
        String(py=t["read"](PythonObject(entry))), key + "\n" + lib + "\n"
    )

    # A later run starts with the stored library: its children see it.
    var copy = String(py=t["copy_library"](PythonObject(lib)))
    _ = t["write"](PythonObject(entry), PythonObject(key + "\n" + copy + "\n"))
    _ = t["node_log"]()
    _same(t, ["analyze", "ts"], env, "with a stored library")
    assert_equal(String(py=t["node_log"]()), copy + "\n", "the library used")

    # Under another PATH the entry is not this run's: Mojo finds the library.
    var other = t["env"](True)
    _same(t, ["analyze", "ts"], other, "under another PATH")
    assert_equal(String(py=t["node_log"]()), lib + "\n", "the library found")

    # An entry naming a library that is gone is found again.
    _ = t["write"](
        PythonObject(entry), PythonObject(key + "\n" + copy + ".gone\n")
    )
    _same(t, ["analyze", "ts"], env, "with a stale entry")
    assert_equal(String(py=t["node_log"]()), lib + "\n", "a stale entry")
    _ = setenv("PATH", path)
    _ = t["gone"]()


def test_bytecode_is_kept() raises:
    var t = _py()
    _ = t["setup"]()
    var env = t["env"]()
    var n = Python.import_module("builtins").len
    _same(t, ["analyze", "py"], env, "with no bytecode")
    var kept = t["bytecode"]()
    assert_true(Int(py=n(kept)) >= 2, "the helpers analyze runs are kept")
    _same(t, ["analyze", "py", "--json"], env, "with bytecode")
    _ = t["spoil"](kept)
    _same(t, ["analyze", "py"], env, "with damaged bytecode")
    assert_equal(Int(py=t["spoilt"](kept)), 0, "damaged entries written again")
    _ = t["gone"]()


def main() raises:
    test_library_is_remembered_and_used()
    test_bytecode_is_kept()
    print("test_pycache: 2 passed")
