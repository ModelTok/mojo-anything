# `build` and `diff` of a Python unit (port of src/harness.rs `build`,
# `diff`, `diff_after`, `settle`, `diff_exact` and `stale_build`,
# src/harness_mojo_py.rs `build` and `sources_newer_than`, src/harness_py.rs
# `diff`, `diff_with` and `run`, src/mojo.rs `command`, src/tolerance.rs
# `apply`, and the `build` and `diff` arms of src/main.rs).
#
# `build` runs the unit's own pinned Mojo through pixi as the Rust tool does;
# `diff` runs the Rust tool's Python driver (DRIVER_PY) over `cases.jsonl`
# under the same watchdog, then applies the float tolerance, the entries of
# `known-diffs.jsonl`, the diff history and the stale check in Mojo.
#
# Declined before anything is written (the Phase 1 binary answers): `--module`,
# a float tolerance outside [0, 1), a `pinned.json` serde_json may read
# otherwise, a `python3` that does not run, a crate folder with whitespace in
# its path (src/mojo.rs copies its pixi.toml to a cache folder), and a
# `known-diffs.jsonl`, `recorded-from.json` or diff history that serde_json
# and EmberJson may read differently. A `diff.json` the driver wrote that they
# may read differently goes to the Phase 1 binary after the run, which writes
# the same driver and runs it again.

from emberjson import Value
from std.python import Python, PythonObject

from mojo_anything.embedded import driver_py
from mojo_anything.fallback import fallback
from mojo_anything.harness_py import _helpers
from mojo_anything.json import parse_json
from mojo_anything.json_text import _pretty, write_compact, write_string
from mojo_anything.process import BUILD, TESTS, Command, output
from mojo_anything.process import limit as process_limit
from mojo_anything.recording import (
    KNOWN_DIFFS,
    STALL_AFTER,
    DiffOutcome,
    Trend,
    apply_known,
    known_diffs,
    stale,
    track,
)
from mojo_anything.tolerance import check, values_close

comptime SHOWN_MISMATCHES = 20

comptime _PY = """
import json, os, re, signal, subprocess, tempfile, time

class _Odd(Exception):
    pass

def _odd_constant(name):
    raise _Odd(name)

def _odd_int(text):
    # serde_json reads `-0` as -0.0 and an integer past 64 bits as a float.
    if text == "-0":
        raise _Odd(text)
    v = int(text)
    if v >= 2 ** 64 or v < -(2 ** 63):
        raise _Odd(text)
    return v

def _odd_float(text):
    v = float(text)
    if v in (float("inf"), float("-inf")):
        raise _Odd(text)
    return v

def _unique(items):
    keys = [k for k, _ in items]
    if len(keys) != len(set(keys)):
        raise _Odd("duplicate key")
    return dict(items)

def _deepest(text):
    depth = most = 0
    inside = escaped = False
    for c in text:
        if inside:
            if escaped:
                escaped = False
            elif c == "\\\\":
                escaped = True
            elif c == '"':
                inside = False
        elif c == '"':
            inside = True
        elif c in "[{":
            depth += 1
            most = max(most, depth)
        elif c in "]}":
            depth -= 1
    return most

_SURROGATE = re.compile(r"\\\\u[dD][89abAB]")

def plain_json(text):
    # True when serde_json and EmberJson read `text` alike: strict JSON, no
    # NaN or infinities, no `-0`, no integer past 64 bits, no lone or paired
    # surrogate escape, no duplicate key, and nesting well under serde_json's
    # recursion limit.
    if _deepest(text) > 100 or _SURROGATE.search(text):
        return False
    try:
        json.loads(text, parse_int=_odd_int, parse_float=_odd_float,
                   parse_constant=_odd_constant, object_pairs_hook=_unique)
    except (ValueError, _Odd, RecursionError):
        return False
    return True

def read_utf8(path):
    # ("missing",) when `path` is not a file, ("ok", text), ("odd",) when it
    # does not read as UTF-8.
    if not os.path.isfile(path):
        return ("missing",)
    try:
        with open(path, "rb") as f:
            return ("ok", f.read().decode("utf-8"))
    except (OSError, UnicodeError):
        return ("odd",)

def known_plain(path):
    # recording.rs `known_diffs` reads this file as recording.mojo does: it
    # is UTF-8 (Rust ignores a file that is not), every line trims alike
    # (no whitespace outside ASCII) and every line it parses is plain JSON.
    r = read_utf8(path)
    if r[0] == "missing":
        return True
    if r[0] != "ok":
        return False
    text = r[1]
    if any(c.isspace() and ord(c) > 127 for c in text):
        return False
    for raw in text.split("\\n"):
        line = raw.strip()
        if not line or line.startswith("//"):
            continue
        if not plain_json(line):
            return False
    return True

_RUN = re.compile(r'{"port":"[0-9a-f]{16}","passed":(0|[1-9][0-9]{0,18}),"total":(0|[1-9][0-9]{0,18})}')

def history_plain(path):
    # recording.rs `track` keeps each line it reads as it was; recording.mojo
    # writes the three fields back, so every line must be one `track` wrote.
    r = read_utf8(path)
    if r[0] == "missing":
        return True
    if r[0] != "ok":
        return False
    for line in r[1].split("\\n"):
        if line and not _RUN.fullmatch(line):
            return False
    return True

def recorded_plain(path):
    r = read_utf8(path)
    if r[0] == "missing":
        return True
    return r[0] == "ok" and plain_json(r[1])

def outcome_plain(path):
    # ("ok", text) when diff.json reads alike in serde_json and EmberJson and
    # has the fields harness::DiffOutcome needs, ("odd",) otherwise.
    r = read_utf8(path)
    if r[0] != "ok" or not plain_json(r[1]):
        return ("odd",)
    v = json.loads(r[1])
    if not isinstance(v, dict):
        return ("odd",)
    for key in ("total", "passed", "failed"):
        n = v.get(key)
        if type(n) is not int or n < 0:
            return ("odd",)
    missing, mismatches = v.get("missing"), v.get("mismatches")
    if not isinstance(missing, list) or not all(isinstance(x, str) for x in missing):
        return ("odd",)
    if not isinstance(mismatches, list):
        return ("odd",)
    if any(k in v for k in ("accepted", "stale_known", "trend")):
        return ("odd",)
    return ("ok", r[1])

def sources_newer(crate_dir, built):
    # harness_mojo_py::sources_newer_than: any `*.mojo` entry of the folder
    # (its own time, not a link's target) newer than `built`.
    try:
        at = os.stat(built).st_mtime_ns
    except OSError:
        return False
    try:
        entries = list(os.scandir(crate_dir))
    except OSError:
        return False
    for e in entries:
        n = e.name
        i = n.rfind(".")
        if i <= 0 or n[i + 1:] != "mojo":
            continue
        try:
            t = e.stat(follow_symlinks=False).st_mtime_ns
        except OSError:
            continue
        if t > at:
            return True
    return False

def find_pixi():
    # mojo.rs `find_pixi`: `pixi` on PATH, else ~/.pixi/bin/pixi.
    path = os.environ.get("PATH")
    if path is not None:
        for d in path.split(":"):
            p = os.path.join(d, "pixi") if d else "pixi"
            if os.path.isfile(p):
                return p
    home = os.environ.get("HOME")
    if home is not None:
        p = os.path.join(home, ".pixi", "bin", "pixi")
        if os.path.isfile(p):
            return p
    return ""

def has_space(path):
    return any(c.isspace() for c in path)

_NAMES = {
    1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
    7: "SIGBUS", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGUSR1", 11: "SIGSEGV", 12: "SIGUSR2",
    13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM", 16: "SIGSTKFLT", 17: "SIGCHLD",
    18: "SIGCONT", 19: "SIGSTOP", 20: "SIGTSTP", 21: "SIGTTIN", 22: "SIGTTOU", 23: "SIGURG",
    24: "SIGXCPU", 25: "SIGXFSZ", 26: "SIGVTALRM", 27: "SIGPROF", 28: "SIGWINCH",
    29: "SIGIO", 30: "SIGPWR", 31: "SIGSYS",
}

def status_text(st):
    # ExitStatus's Display on Linux.
    if os.WIFEXITED(st):
        return "exit status: %d" % os.WEXITSTATUS(st)
    sig = os.WTERMSIG(st)
    name = _NAMES.get(sig)
    text = "signal: %d" % sig + (" (%s)" % name if name else "")
    if os.WCOREDUMP(st):
        text += " (core dumped)"
    return text

def run_driver(argv, env_set, env_remove, limit, shown):
    # harness_py.rs `run`: the driver from a scratch folder, stdin closed, in
    # a process group of its own, stopped with the group at the limit. ""
    # when it succeeded, else the error as anyhow prints it.
    try:
        scratch = _temp_dir("unit")
    except Failed as e:
        return str(e)
    env = dict(os.environ)
    for k in env_remove:
        env.pop(k, None)
    env.update(env_set)
    try:
        err = tempfile.TemporaryFile()
        try:
            try:
                child = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.DEVNULL, stderr=err,
                                         cwd=scratch, env=env, process_group=0)
            except OSError as e:
                return "running python: running `%s`: %s" % (shown, _io(e))
            start = time.monotonic()
            pause = 0.005
            status = None
            while True:
                pid, st = os.waitpid(child.pid, os.WNOHANG)
                if pid != 0:
                    status = st
                    break
                if time.monotonic() - start > limit:
                    try:
                        os.killpg(child.pid, signal.SIGKILL)
                    except OSError:
                        pass
                    try:
                        os.kill(child.pid, signal.SIGKILL)
                    except OSError:
                        pass
                    os.waitpid(child.pid, 0)
                    break
                time.sleep(pause)
                pause = min(pause * 2, 0.1)
            child.returncode = 0
            if status is None:
                return ("running python: `%s` was still running after %ds and was stopped "
                        "(set MOJO_ANYTHING_COMMAND_TIMEOUT to allow longer; a test runner in "
                        "watch mode never ends, so run it once, e.g. `vitest run`)"
                        % (shown, int(limit)))
            if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
                return ""
            err.seek(0)
            data = err.read()[-(1 << 20):]
        finally:
            err.close()
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    tail = _lines(data.decode("utf-8", "replace"))[-25:]
    return "python failed (%s):\\n%s" % (status_text(status), "\\n".join(tail))

def write_driver(crate_dir, text):
    # harness_py.rs `driver`: "" or the io error.
    try:
        work = join(crate_dir, ".mojo-anything")
        _create_dir_all(work)
        _write(join(work, "driver.py"), text)
    except Failed as e:
        return str(e)
    return ""

def make_package(path):
    try:
        _create_dir_all(path)
    except Failed as e:
        return str(e)
    return ""

def to_float(text):
    return float(text)
"""


def _h() raises -> PythonObject:
    var h = _helpers()
    _ = Python.import_module("builtins").exec(_PY, h)
    return h


def _join(h: PythonObject, a: String, b: String) raises -> String:
    return String(py=h["join"](PythonObject(a), PythonObject(b)))


def _yes(v: PythonObject) raises -> Bool:
    return Bool(py=v)


# ---- build -------------------------------------------------------------------


def build_python(
    crate_dir: String, manifest: PythonObject, argv: List[String]
) raises -> Int:
    """`build` of a `mojo-py` unit: `_native.mojo` into the wrapper package,
    warnings as errors, by the unit's own Mojo."""
    var h = _h()
    var name = String(py=manifest["crate_name"]).replace("-", "_")
    var package_dir = _join(h, _join(h, crate_dir, "python"), name)
    var pixi = String(py=h["find_pixi"]())
    if Bool(py=h["has_space"](PythonObject(crate_dir))):
        return fallback(argv)
    var made = String(py=h["make_package"](PythonObject(package_dir)))
    if made.byte_length() > 0:
        raise Error(made)
    if pixi.byte_length() == 0:
        raise Error(
            "Mojo needs pixi, which is not on PATH or in ~/.pixi/bin: install"
            " it from https://pixi.sh (Mojo runs only on Linux and macOS)"
        )
    var target = _join(h, package_dir, "_native.so")
    var cmd = Command(pixi)
    for a in [
        "run",
        "--manifest-path",
        _join(h, crate_dir, "pixi.toml"),
        "mojo",
        "build",
        "--Werror",
        "_native.mojo",
        "--emit",
        "shared-lib",
        "-o",
        target,
    ]:
        cmd.args.append(a)
    cmd.cwd = crate_dir
    var out = output(cmd, BUILD)
    if not out.success:
        raise Error(
            String("mojo build failed:\n", out.stdout_text(), out.stderr_text())
        )
    print(String("Built ", package_dir))
    return 0


# ---- diff --------------------------------------------------------------------


def _get(v: Value, key: String) -> Value:
    """`v[key]` as serde_json indexes: null when absent."""
    if v.is_object():
        ref o = v.object()
        if key in o:
            try:
                return o[key].copy()
            except:
                pass
    return Value(None)


def _count(v: Value) -> Int:
    if v.is_uint():
        return Int(v.uint())
    if v.is_int():
        return Int(v.int())
    return 0


def _values_close_ordered(
    expected: Value, actual: Value, tolerance: Float64, ignore_key_order: Bool
) -> Bool:
    """tolerance.rs `values_close_with_order`."""
    if ignore_key_order:
        return values_close(expected, actual, tolerance)
    if expected.is_array() and actual.is_array():
        ref x = expected.array()
        ref y = actual.array()
        if len(x) != len(y):
            return False
        for i in range(len(x)):
            if not _values_close_ordered(x[i], y[i], tolerance, False):
                return False
        return True
    if expected.is_object() and actual.is_object():
        ref x = expected.object()
        ref y = actual.object()
        if len(x) != len(y):
            return False
        var xk = List[String]()
        var yk = List[String]()
        for kv in x.items():
            xk.append(kv.key)
        for kv in y.items():
            yk.append(kv.key)
        for i in range(len(xk)):
            if xk[i] != yk[i]:
                return False
        for kv in x.items():
            try:
                if not _values_close_ordered(
                    kv.value, y[kv.key], tolerance, False
                ):
                    return False
            except:
                return False
        return True
    return values_close(expected, actual, tolerance)


def _pretty_items(items: List[String]) -> String:
    """A pretty array at the top level's first indent, of items already
    written at the second."""
    if len(items) == 0:
        return "[]"
    var out = String("[\n")
    for i in range(len(items)):
        if i > 0:
            out += ",\n"
        out += "    " + items[i]
    return out + "\n  ]"


def _json_outcome(
    d: DiffOutcome, missing: List[String], trend: Optional[Trend]
) -> String:
    """`serde_json::to_string_pretty` of harness::DiffOutcome."""
    var out = String("{\n")
    out += String('  "total": ', d.total, ",\n")
    out += String('  "passed": ', d.passed, ",\n")
    out += String('  "failed": ', d.failed, ",\n")
    var shown = List[String]()
    for m in missing:
        shown.append(write_string(m))
    out += '  "missing": ' + _pretty_items(shown) + ",\n"
    var ms = List[String]()
    for m in d.mismatches:
        ms.append(_pretty(m, "    "))
    out += '  "mismatches": ' + _pretty_items(ms)
    if d.accepted > 0:
        out += String(',\n  "accepted": ', d.accepted)
    if len(d.stale_known) > 0:
        var ks = List[String]()
        for e in d.stale_known:
            ks.append(_pretty(e, "    "))
        out += ',\n  "stale_known": ' + _pretty_items(ks)
    if trend:
        ref t = trend.value()
        var ps = List[String]()
        for p in t.passed:
            ps.append(String(p))
        var arr = String("[]")
        if len(ps) > 0:
            arr = String("[\n")
            for i in range(len(ps)):
                if i > 0:
                    arr += ",\n"
                arr += "      " + ps[i]
            arr += "\n    ]"
        out += ',\n  "trend": {\n    "passed": ' + arr + ",\n"
        out += String('    "total": ', t.total, ",\n")
        out += '    "stalled": ' + ("true" if t.stalled else "false") + "\n  }"
    return out + "\n}"


def _str_or_empty(v: Value) -> String:
    return v.string() if v.is_string() else String("")


def _args_text(v: Value) -> String:
    """`m["args"].as_array()` joined with `, `, each as serde_json writes it."""
    if not v.is_array():
        return ""
    var out = String("")
    var first = True
    for a in v.array():
        if not first:
            out += ", "
        first = False
        out += write_compact(a)
    return out


def diff_python(
    crate_dir: String,
    manifest: PythonObject,
    ignore_key_order: Bool,
    tolerance_arg: Optional[String],
    as_json: Bool,
    argv: List[String],
) raises -> Int:
    """`diff` of a Python unit (its manifest loaded, no `--module`)."""
    var h = _h()
    var builtins = Python.import_module("builtins")
    var kind = String(py=manifest["kind"])
    # The float tolerance: this run's, else the one `record` saved.
    var tolerance = Optional[Float64](None)
    if tolerance_arg:
        tolerance = Float64(
            py=h["to_float"](PythonObject(tolerance_arg.value()))
        )
    elif not (manifest["float_tolerance_value"] is Python.none()):
        tolerance = Float64(py=manifest["float_tolerance_value"])
    if tolerance and not check(tolerance.value()):
        return fallback(argv)
    # Files Rust and Mojo must read alike.
    if not _yes(
        h["known_plain"](PythonObject(_join(h, crate_dir, KNOWN_DIFFS)))
    ):
        return fallback(argv)
    if not _yes(
        h["history_plain"](
            PythonObject(
                _join(h, crate_dir, ".mojo-anything/diff-history.jsonl")
            )
        )
    ):
        return fallback(argv)
    if not _yes(
        h["recorded_plain"](
            PythonObject(_join(h, crate_dir, "recorded-from.json"))
        )
    ):
        return fallback(argv)
    var pin = h["read_pin"](PythonObject(crate_dir))
    if String(py=pin[0]) == "decline":
        return fallback(argv)
    if String(py=h["python_name"]()) != "python3":
        return fallback(argv)
    var name = String(py=manifest["crate_name"]).replace("-", "_")
    var package = _join(h, crate_dir, "python")
    # harness.rs `stale_build`: a forgotten `build` would test the old port.
    if kind == "mojo-py":
        var built = _join(h, _join(h, package, name), "_native.so")
        if _yes(
            h["sources_newer"](PythonObject(crate_dir), PythonObject(built))
        ):
            raise Error(
                String(
                    built,
                    (
                        " is older than the crate's sources, so diff would"
                        " test the previous port; run `mojo-anything build "
                    ),
                    crate_dir,
                    "` first",
                )
            )
    else:
        return fallback(argv)
    var cases = _join(h, crate_dir, "cases.jsonl")
    if not Bool(py=Python.import_module("os").path.exists(PythonObject(cases))):
        raise Error(
            String(
                "no cases.jsonl in ",
                crate_dir,
                " (run `mojo-anything record` first)",
            )
        )
    var wrote = String(
        py=h["write_driver"](PythonObject(crate_dir), PythonObject(driver_py()))
    )
    if wrote.byte_length() > 0:
        raise Error(wrote)
    var work = _join(h, crate_dir, ".mojo-anything")
    var driver = _join(h, work, "driver.py")
    var out_path = _join(h, work, "diff.json")
    var args = Python.list()
    var shown = String("python3")
    args.append(PythonObject("python3"))
    for a in [
        driver,
        String("diff"),
        cases,
        out_path,
        package,
        name,
        String("sort") if ignore_key_order else String("keep"),
    ]:
        args.append(PythonObject(a))
        shown += " " + a
    var env_set = Python.dict()
    env_set["PYTHONHASHSEED"] = "0"
    env_set["PYTHONDONTWRITEBYTECODE"] = "1"
    var env_remove = Python.list()
    if String(py=pin[0]) == "ok":
        env_set["MOJO_ANYTHING_NOW_MS"] = builtins.str(pin[1])
        env_set["MOJO_ANYTHING_SEED"] = builtins.str(pin[2])
        env_set["TZ"] = "UTC"
        env_remove.append("MOJO_ANYTHING_CASE")
    else:
        for k in [
            "MOJO_ANYTHING_NOW_MS",
            "MOJO_ANYTHING_SEED",
            "MOJO_ANYTHING_CASE",
        ]:
            env_remove.append(PythonObject(k))
    var failed = String(
        py=h["run_driver"](
            args,
            env_set,
            env_remove,
            PythonObject(process_limit(TESTS)),
            PythonObject(shown),
        )
    )
    if failed.byte_length() > 0:
        raise Error(failed)
    var read = h["outcome_plain"](PythonObject(out_path))
    if String(py=read[0]) != "ok":
        return fallback(argv)
    var v = parse_json(String(py=read[1]))
    var d = DiffOutcome(
        _count(_get(v, "total")),
        _count(_get(v, "passed")),
        _count(_get(v, "failed")),
    )
    var missing = List[String]()
    for m in _get(v, "missing").array():
        missing.append(m.string())
    for m in _get(v, "mismatches").array():
        d.mismatches.append(m.copy())
    # harness.rs `settle`: the tolerance, then the known diffs.
    if tolerance:
        var kept = List[Value]()
        for m in d.mismatches:
            if not _values_close_ordered(
                _get(m, "expected"),
                _get(m, "actual"),
                tolerance.value(),
                ignore_key_order,
            ):
                kept.append(m.copy())
        var forgiven = len(d.mismatches) - len(kept)
        d.mismatches = kept^
        d.passed += forgiven
        d.failed = max(d.failed - forgiven, 0)
    var entries: List[Value]
    try:
        entries = known_diffs(crate_dir)
    except e:
        if String(e).find(": not JSON: ") >= 0:
            return fallback(argv)
        raise e^
    d = apply_known(d^, entries)
    while len(d.mismatches) > SHOWN_MISMATCHES:
        _ = d.mismatches.pop()
    if d.total == 0:
        raise Error(
            "no recorded cases to compare; run `mojo-anything record` first"
        )
    var trend = track(crate_dir, d.passed, d.total)
    var why = stale(
        crate_dir, String(py=manifest["root"]), String(py=manifest["unit"])
    )
    if as_json:
        print(_json_outcome(d, missing, trend))
    else:
        if why:
            print("Stale recording: " + why.value())
        if d.accepted > 0:
            print(
                String(
                    d.passed,
                    "/",
                    d.total,
                    " cases match (",
                    d.accepted,
                    " by ",
                    KNOWN_DIFFS,
                    ")",
                )
            )
        else:
            print(String(d.passed, "/", d.total, " cases match"))
        if trend and trend.value().stalled:
            ref t = trend.value()
            var shown_passed = String("")
            for i in range(len(t.passed)):
                if i > 0:
                    shown_passed += ", "
                shown_passed += String(t.passed[i])
            print(
                String(
                    "Stalled: the last ",
                    STALL_AFTER,
                    " changes to the port gained no matching case (",
                    shown_passed,
                    " of ",
                    t.total,
                    (
                        "). Stop and look at the remaining mismatches with a"
                        " person, or keep these functions in the original for"
                        " now."
                    ),
                )
            )
        for e in d.stale_known:
            print(
                String(
                    "Known diff no longer happens, remove it from ",
                    KNOWN_DIFFS,
                    ": ",
                    _str_or_empty(_get(e, "fn")),
                    "(",
                    write_compact(_get(e, "args")),
                    ")",
                )
            )
        if len(missing) > 0:
            var joined = String("")
            for i in range(len(missing)):
                if i > 0:
                    joined += ", "
                joined += missing[i]
            print("Missing exports: " + joined)
        for m in d.mismatches:
            print(
                String(
                    "- ",
                    _str_or_empty(_get(m, "fn")),
                    "(",
                    _args_text(_get(m, "args")),
                    "): expected ",
                    write_compact(_get(m, "expected")),
                    ", got ",
                    write_compact(_get(m, "actual")),
                )
            )
    if d.failed > 0 or why:
        return 1
    return 0
