# The Phase 1 binary behind the Mojo front door. Every subcommand the Mojo tool
# does not own yet is handed to it: the process is replaced by
# tool/fallback/mojo-anything with the same argv, stdin and environment
# (execv keeps the descriptors and `environ`), so its output, stderr and exit
# status reach the caller unchanged. Each hand-over is one fallback, logged to
# $MOJO_ANYTHING_FALLBACK_LOG when it is set, as generated front doors do.

from std.ffi import external_call
from std.memory import Pointer
from std.os import getenv
from std.sys import stderr

from mojo_anything.pycache import forget_python

comptime _Bytes = Pointer[UInt8, MutAnyOrigin]
comptime _CStrs = Pointer[Optional[_Bytes], MutAnyOrigin]
comptime FALLBACK_LOG = "MOJO_ANYTHING_FALLBACK_LOG"
comptime FALLBACK_ENV = "MOJO_ANYTHING_FALLBACK"
comptime FALLBACK_HOME = "tool/fallback"


def _alloc(n: Int) -> _Bytes:
    # SAFETY: malloc returns `n` writable bytes; `value()` aborts on NULL.
    return external_call["malloc", Optional[_Bytes]](n).value()


def _free(p: _Bytes):
    # SAFETY: `p` came from `_alloc` and is freed once.
    external_call["free", NoneType](p)


def _cstr(s: String) -> _Bytes:
    """A NUL-terminated copy of `s` in C memory."""
    var bytes = s.as_bytes()
    var n = len(bytes)
    var p = _alloc(n + 1)
    for i in range(n):
        p[unsafe_offset=i] = bytes[i]
    p[unsafe_offset=n] = 0
    return p


def dirname(path: String) -> String:
    """The folder of `path`, as `dirname(1)` gives it."""
    var bytes = path.as_bytes()
    var end = len(bytes)
    while end > 1 and bytes[end - 1] == 47:
        end -= 1
    while end > 0 and bytes[end - 1] != 47:
        end -= 1
    while end > 1 and bytes[end - 1] == 47:
        end -= 1
    if end == 0:
        return "."
    return String(path[byte=0:end])


def own_binary() -> String:
    """This binary's own path, through /proc/self/exe (symlinks resolved)."""
    var size = 4096
    var buf = _alloc(size)
    var link = _cstr("/proc/self/exe")
    # SAFETY: `link` is NUL-terminated and `buf` holds `size` writable bytes;
    # readlink writes at most that many and returns how many it wrote.
    var n = external_call["readlink", Int](link, buf, size)
    _free(link)
    var out = String("")
    if n > 0 and n < size:
        out = String(
            unsafe_from_utf8=Span[UInt8, ImmutAnyOrigin](
                unsafe_ptr=buf, length=n
            )
        )
    _free(buf)
    return out


def fallback_path() -> String:
    """$MOJO_ANYTHING_FALLBACK, or `../fallback/mojo-anything` beside this
    binary (tool/build/mojo-anything finds tool/fallback/mojo-anything)."""
    var set = getenv(FALLBACK_ENV)
    if set.byte_length() > 0:
        return set
    return dirname(dirname(own_binary())) + "/fallback/mojo-anything"


def report_owned():
    """Tells `mojo-anything app replay` this build counts its fallbacks, even
    when it makes none: the log exists, empty."""
    var path = getenv(FALLBACK_LOG)
    if path.byte_length() == 0:
        return
    try:
        var log = open(path, "a")
        log.close()
    except:
        pass


def _log(argv: List[String]):
    """One line per fallback: the subcommand words, without the program."""
    var path = getenv(FALLBACK_LOG)
    if path.byte_length() == 0:
        return
    var line = String()
    for i in range(1, len(argv)):
        if argv[i].startswith("-"):
            break
        if i > 1:
            line += " "
        line += argv[i]
    if line.byte_length() == 0:
        line = "(no subcommand)"
    try:
        var log = open(path, "a")
        log.write(line + "\n")
        log.close()
    except:
        pass


def fallback(argv: List[String]) -> Int:
    """Replaces this process with the Phase 1 binary and the same argv; returns
    only when that fails, with the exit code the caller should use."""
    _log(argv)
    forget_python()
    var path = fallback_path()
    var n = len(argv)
    # SAFETY: room for `n` pointers and the NULL that ends execv's argv.
    var cargv = external_call["malloc", Optional[_CStrs]]((n + 1) * 8).value()
    for i in range(n):
        cargv[unsafe_offset=i] = _cstr(argv[i])
    cargv[unsafe_offset=n] = None
    var cpath = _cstr(path)
    print("", end="", flush=True)
    # SAFETY: `cpath` is NUL-terminated and `cargv` holds `n` NUL-terminated
    # strings followed by NULL; execv returns only on failure.
    _ = external_call["execv", Int32](cpath, cargv)
    var errno = _errno()
    _free(cpath)
    for i in range(n):
        _free(cargv[unsafe_offset=i].value())
    # SAFETY: `cargv` came from malloc above and is freed once.
    external_call["free", NoneType](cargv)
    print(
        String(
            "mojo-anything: cannot run the Phase 1 binary ",
            path,
            " (errno ",
            errno,
            "); build it into ",
            FALLBACK_HOME,
            "/ with scripts/build-fallback.sh, or name it with ",
            FALLBACK_ENV,
        ),
        file=stderr,
    )
    return 127


def _errno() -> Int32:
    # SAFETY: glibc's errno of this thread, always a valid int.
    return external_call["__errno_location", Pointer[Int32, MutAnyOrigin]]()[]
