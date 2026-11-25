# What the Mojo tool keeps between runs so that starting CPython costs less
# (docs/measurements/2026-11-25-phase2-python-timings.md). Nothing here changes what a
# command answers: both caches hold what the run would compute anyway, and a
# missing, stale or damaged entry is computed again.
#
# - The CPython library. Mojo's Python interop finds libpython by running
#   `python3 -c <script>` (the first python3 on PATH) unless
#   MOJO_PYTHON_LIBRARY is set, and then sets MOJO_PYTHON_LIBRARY itself, so
#   every child sees it either way. That run took about 0.03 s of every
#   command. `start_python` sets the variable from the cache before Python
#   starts, for the same python3 (its path, the file it resolves to and that
#   file's inode, size and modification time, under the same PATH);
#   `remember_python` stores what Mojo found once Python has started.
#   MOJO_PYTHON (another interpreter), a set MOJO_PYTHON_LIBRARY, a relative
#   PATH entry and a python3 that is not an ELF binary (a shim that picks the
#   interpreter at run time) are never cached.
# - The bytecode of the Python helpers. Each command executed one to four
#   embedded helper sources (up to 170 KB), and compiling them took up to
#   0.1 s; `py_exec` keeps the compiled code next to its source, keyed by the
#   interpreter's bytecode magic number.
#
# Both live in $XDG_CACHE_HOME/mojo-anything (an absolute path), else
# $HOME/.cache/mojo-anything; with neither, nothing is cached.

from std.os import getenv, makedirs, setenv, stat
from std.os.path import isfile, realpath
from std.python import Python, PythonObject

comptime _LIBRARY = "MOJO_PYTHON_LIBRARY"

comptime _BOOT = """
import marshal, os, sys, zlib
from importlib._bootstrap_external import MAGIC_NUMBER

CACHE = ""
_CODE = {}

def _load(source):
    path = None
    if CACHE:
        folder = os.path.join(CACHE, "pyc-" + MAGIC_NUMBER.hex())
        path = os.path.join(folder, "%08x-%d.bin" % (zlib.crc32(source.encode("utf-8")), len(source)))
        try:
            with open(path, "rb") as f:
                saved, code = marshal.loads(f.read())
            if saved == source and type(code) is type(_load.__code__):
                return code
        except Exception:  # noqa: BLE001 - a missing or damaged entry is compiled again
            pass
    # As builtins.exec compiles a string called from outside any frame.
    code = compile(source, "<string>", "exec", dont_inherit=True)
    if path is not None and not sys.dont_write_bytecode:
        try:
            os.makedirs(folder, exist_ok=True)
            tmp = "%s.%d.tmp" % (path, os.getpid())
            with open(tmp, "wb") as f:
                f.write(marshal.dumps((source, code)))
            os.replace(tmp, path)
        except OSError:
            pass
    return code

def run(source, scope):
    code = _CODE.get(source)
    if code is None:
        code = _CODE[source] = _load(source)
    exec(code, scope)
"""


def cache_dir() -> String:
    """$XDG_CACHE_HOME/mojo-anything, else $HOME/.cache/mojo-anything (each
    only when absolute); empty for none."""
    var xdg = getenv("XDG_CACHE_HOME")
    if xdg.startswith("/"):
        return xdg + "/mojo-anything"
    var home = getenv("HOME")
    if home.startswith("/"):
        return home + "/.cache/mojo-anything"
    return ""


def py_exec(source: String, scope: PythonObject) raises:
    """`exec(source, scope)`, with the compiled code kept between runs."""
    var sys = Python.import_module("sys")
    var builtins = Python.import_module("builtins")
    var run = builtins.getattr(sys, "_mojo_anything_exec", Python.none())
    if run is Python.none():
        var boot = Python.dict()
        _ = builtins.exec(_BOOT, boot)
        boot["CACHE"] = PythonObject(cache_dir())
        run = boot["run"]
        _ = builtins.setattr(sys, "_mojo_anything_exec", run)
    _ = run(PythonObject(source), scope)


def _fnv(s: String) -> UInt64:
    var h: UInt64 = 0xCBF29CE484222325
    for b in s.as_bytes():
        h = (h ^ UInt64(b)) * 0x100000001B3
    return h


def _hex(x: UInt64) -> String:
    var digits = "0123456789abcdef"
    var out = String("")
    for i in range(16):
        var d = Int((x >> UInt64(60 - 4 * i)) & 0xF)
        out += digits[byte=d]
    return out^


def _is_elf(path: String) -> Bool:
    try:
        with open(path, "r") as f:
            var b = f.read_bytes(4)
            return (
                len(b) == 4
                and b[0] == 0x7F
                and b[1] == 0x45
                and b[2] == 0x4C
                and b[3] == 0x46
            )
    except:
        return False


def python_key() -> String:
    """What the library Mojo's interop would find depends on: PATH, the
    python3 it runs and the file that resolves to; empty when that cannot be
    cached."""
    if (
        getenv(_LIBRARY).byte_length() > 0
        or getenv("MOJO_PYTHON").byte_length() > 0
    ):
        return ""
    var path = getenv("PATH")
    var found = String("")
    try:
        for part in path.split(":"):
            var entry = String(part)
            if not entry.startswith("/"):
                return ""
            var candidate = entry + "/python3"
            if (
                isfile(candidate)
                and (Int(stat(candidate).st_mode) & 0o111) != 0
            ):
                found = candidate
                break
        if found.byte_length() == 0:
            return ""
        var real = realpath(found)
        if not _is_elf(real):
            return ""
        var st = stat(real)
        return String(
            path,
            "\n",
            found,
            "\n",
            real,
            "\n",
            st.st_ino,
            " ",
            st.st_size,
            " ",
            st.st_mtimespec.tv_sec,
            ".",
            st.st_mtimespec.tv_nsec,
        )
    except:
        return ""


def python_entry(key: String) -> String:
    """The cache file for `key`; empty with no cache folder."""
    var dir = cache_dir()
    if dir.byte_length() == 0 or key.byte_length() == 0:
        return ""
    return dir + "/python-library/" + _hex(_fnv(key))


def cached_python(key: String) -> String:
    """The library stored for `key`, if it still exists; else empty."""
    var entry = python_entry(key)
    if entry.byte_length() == 0:
        return ""
    try:
        var text: String
        with open(entry, "r") as f:
            text = f.read()
        var head = key + "\n"
        if not text.startswith(head) or not text.endswith("\n"):
            return ""
        var lib = String(
            text[byte = head.byte_length() : text.byte_length() - 1]
        )
        if lib.byte_length() == 0 or "\n" in lib or not isfile(lib):
            return ""
        return lib^
    except:
        return ""


def remember_python(key: String, lib: String):
    """Stores `lib` for `key`; a folder that cannot be written is left be."""
    var entry = python_entry(key)
    if entry.byte_length() == 0 or lib.byte_length() == 0 or "\n" in lib:
        return
    try:
        makedirs(cache_dir() + "/python-library", exist_ok=True)
        with open(entry, "w") as f:
            f.write(key + "\n" + lib + "\n")
    except:
        pass


def start_python() -> String:
    """Before CPython starts: sets MOJO_PYTHON_LIBRARY from the cache when it
    holds this python3's library. Returns the key to remember the library
    under once Python has started (empty when it came from the cache or cannot
    be cached)."""
    var key = python_key()
    if key.byte_length() == 0:
        return ""
    var lib = cached_python(key)
    if lib.byte_length() == 0:
        return key
    _ = setenv(_LIBRARY, lib)
    return ""


def end_python(key: String):
    """After a command: when Python started and Mojo found its library,
    stores it under `key` (from `start_python`)."""
    if key.byte_length() == 0:
        return
    remember_python(key, getenv(_LIBRARY))
