# `record` of a Python unit (port of src/harness.rs `record`,
# `generate_cases`, `record_cases` and `summarize`, src/harness_py.rs
# `record` and its driver, and the `record` arm of src/main.rs).
#
# The inputs come from harness.mojo; the original runs in the Rust tool's own
# Python driver (DRIVER_PY, embedded from src/harness_py.rs), which writes
# every line of `cases.jsonl`. The driver runs under the same watchdog:
# Python's `subprocess` starts it in a process group of its own, a case past
# the per-case limit (MOJO_ANYTHING_CASE_TIMEOUT seconds, 10 by default) has
# the group killed and is left out, and the driver goes on with the rest.
#
# `--inputs` lines are read by Python's json behind a screen (no NaN,
# infinities, `-0`, integers past 64 bits or lone surrogates) and written
# back as serde_json writes them, with their `module`. `--pin-clock` and
# `--no-pin-clock` write and remove `pinned.json` (and `pinned.mojo`) as
# src/pin.rs `set` does, and a pinned recording runs the driver with the
# pinned clock and seed. `--from-tests -- <command>` runs the test suite in
# the original's folder with the Rust tool's import hook on PYTHONPATH
# (src/from_tests.rs), keeps the calls it makes to the unit's functions in
# `test-inputs.jsonl` (after the `--inputs` lines, when given) and records
# them as inputs.
#
# Declined before anything is written (the Phase 1 binary records): a type
# the shape reader (shape.mojo) does not read, a named type in a class's
# parameters (Rust reads a class's file with the TS type reader), a dataclass
# file whose tree has an error, a C pointer parameter, a `pinned.json`
# serde_json would refuse or may read otherwise, a per-case limit Rust may
# read otherwise, a `python3` that does not run, and a `--count` other than
# plain digits.

from std.collections import Dict, Set
from std.os import getenv
from std.python import Python, PythonObject

from mojo_anything.codegen_mojo import ExportedFn, Manifest, Param, param_rtype
from mojo_anything.embedded import (
    driver_py,
    pinned_mojo,
    py_hook_head,
    py_hook_tail,
)
from mojo_anything.fallback import fallback
from mojo_anything.harness import (
    GV,
    Gen,
    array_text,
    case_text,
    generate,
    intify,
    is_c_pointer,
    scenarios,
    trap_args,
)
from mojo_anything.js_number import json_number_to_string
from mojo_anything.json_text import write_string
from mojo_anything.process import TESTS
from mojo_anything.process import limit as process_limit
from mojo_anything.recording import save_fingerprint
from mojo_anything.shape import DECLINE
from mojo_anything.tree_lang import tree_helpers

comptime _PY = """
import os, shutil, signal, subprocess, time

_SIGNALS = {
    1: "SIGHUP", 2: "SIGINT", 3: "SIGQUIT", 4: "SIGILL", 5: "SIGTRAP", 6: "SIGABRT",
    7: "SIGBUS", 8: "SIGFPE", 9: "SIGKILL", 10: "SIGUSR1", 11: "SIGSEGV", 12: "SIGUSR2",
    13: "SIGPIPE", 14: "SIGALRM", 15: "SIGTERM", 16: "SIGSTKFLT", 17: "SIGCHLD",
    18: "SIGCONT", 19: "SIGSTOP", 20: "SIGTSTP", 21: "SIGTTIN", 22: "SIGTTOU", 23: "SIGURG",
    24: "SIGXCPU", 25: "SIGXFSZ", 26: "SIGVTALRM", 27: "SIGPROF", 28: "SIGWINCH",
    29: "SIGIO", 30: "SIGPWR", 31: "SIGSYS",
}
_NEXT = [0]

class Failed(Exception):
    pass

def _io(e):
    # io::Error's Display: strerror and the errno.
    return "%s (os error %d)" % (os.strerror(e.errno), e.errno)

def join(a, b):
    # Path::join for a relative `b`.
    if b.startswith("/"):
        return b
    return a + b if a.endswith("/") else a + "/" + b

def read_text(path):
    # fs::read_to_string(path).unwrap_or_default().
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8")
    except (OSError, UnicodeError):
        return ""

def lexists(path):
    return os.path.lexists(path)

def _lines(text):
    # str::lines.
    out = text.split("\\n")
    if out and out[-1] == "":
        out.pop()
    return [l[:-1] if l.endswith("\\r") else l for l in out]

def _status(st):
    # ExitStatus's Display on Unix.
    if os.WIFEXITED(st):
        return "exit status: %d" % os.WEXITSTATUS(st)
    sig = os.WTERMSIG(st)
    name = _SIGNALS.get(sig)
    text = "signal: %d" % sig + (" (%s)" % name if name else "")
    if os.WCOREDUMP(st):
        text += " (core dumped)"
    return text

def python_name():
    # harness_py.rs `python`: python3 when `python3 --version` succeeds.
    try:
        p = subprocess.run(["python3", "--version"], stdin=subprocess.DEVNULL,
                           stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        if p.returncode == 0:
            return "python3"
    except OSError:
        pass
    return "python"

def _create_dir_all(path):
    try:
        os.makedirs(path, exist_ok=True)
    except FileExistsError as e:
        raise Failed(_io(e))
    except OSError as e:
        raise Failed(_io(e))

def _write(path, text):
    try:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
    except OSError as e:
        raise Failed(_io(e))

def _temp_dir(tag):
    # app.rs `temp_dir`.
    base = os.environ.get("TMPDIR") or "/tmp"
    n = _NEXT[0]
    _NEXT[0] += 1
    d = os.path.join(base, "mojo-anything-app-%s-%d-%d" % (tag, os.getpid(), n))
    shutil.rmtree(d, ignore_errors=True)
    try:
        os.makedirs(d, exist_ok=True)
    except OSError as e:
        raise Failed("creating %s: %s" % (d, _io(e)))
    return d

def _started(progress):
    try:
        with open(progress, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        return None
    lines = _lines(text)
    if not lines:
        return None
    last = lines[-1].strip()
    if last.startswith("+"):
        last = last[1:]
    if not last or not all("0" <= c <= "9" for c in last):
        return None
    return int(last)

def record(texts, crate_dir, driver_text, limit, pin):
    # harness.rs `record` from removing the last run's leftovers to writing
    # cases.jsonl: ("ok", [indices left out]) or ("error", message).
    try:
        work = join(crate_dir, ".mojo-anything")
        try:
            os.remove(join(work, "timed-out.json"))
        except OSError:
            pass
        shutil.rmtree(join(work, "coverage"), ignore_errors=True)
        _create_dir_all(work)
        driver = join(work, "driver.py")
        _write(driver, driver_text)
        out = join(crate_dir, "cases.jsonl")
        env = dict(os.environ)
        env["PYTHONHASHSEED"] = "0"
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        # pin::apply: the pinned clock and seed, or none of them.
        if pin is None:
            for key in ("MOJO_ANYTHING_NOW_MS", "MOJO_ANYTHING_SEED", "MOJO_ANYTHING_CASE"):
                env.pop(key, None)
        else:
            env["MOJO_ANYTHING_NOW_MS"] = str(pin[0])
            env["MOJO_ANYTHING_SEED"] = str(pin[1])
            env["TZ"] = "UTC"
            env.pop("MOJO_ANYTHING_CASE", None)
        name = python_name()
        timed = record_cases(texts, texts, work, out, "python",
                             lambda inputs, part: [name, driver, "record", inputs, part], env, limit)
        return ("ok", timed)
    except Failed as e:
        return ("error", str(e))

def record_cases(texts, timed_texts, work, out, what, argv_of, env, limit):
    # harness.rs `record_cases`: runs the driver `argv_of(inputs, part)` over
    # `texts` from a scratch folder under the watchdog, writes `out` and
    # timed-out.json (from `timed_texts`); the indices left out. Raises
    # Failed with Rust's message.
    _create_dir_all(work)
    inputs = join(work, "record-inputs.json")
    part = join(work, "record-part.jsonl")
    progress = join(work, "record-progress")
    stderr_path = join(work, "record-stderr")
    recorded = []
    timed = []
    start = 0
    while start < len(texts):
        _write(inputs, "[" + ",".join(texts[start:]) + "]")
        _write(progress, "")
        try:
            os.remove(part)
        except OSError:
            pass
        run_env = dict(env)
        run_env["MOJO_ANYTHING_PROGRESS"] = progress
        argv = argv_of(inputs, part)
        try:
            err = open(stderr_path, "wb")
        except OSError as e:
            raise Failed(_io(e))
        scratch = _temp_dir("unit")
        try:
            try:
                child = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                         stdout=subprocess.DEVNULL, stderr=err,
                                         cwd=scratch, env=run_env, process_group=0)
            except OSError as e:
                raise Failed("running %s: %s" % (what, _io(e)))
            finally:
                err.close()
            current = None
            status = None
            while True:
                pid, st = os.waitpid(child.pid, os.WNOHANG)
                if pid != 0:
                    status = st
                    break
                i = _started(progress)
                if i is not None and (current is None or current[0] != i):
                    current = (i, time.monotonic())
                if current is not None and time.monotonic() - current[1] > limit:
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
                time.sleep(0.02)
            child.returncode = 0
        finally:
            shutil.rmtree(scratch, ignore_errors=True)
        written = read_text(part)
        end = written.rfind("\\n")
        recorded.append(written[: end + 1] if end >= 0 else "")
        if status is not None:
            if os.WIFEXITED(status) and os.WEXITSTATUS(status) == 0:
                break
            tail = _lines(read_text(stderr_path))[-25:]
            raise Failed("%s failed (%s):\\n%s" % (what, _status(status), "\\n".join(tail)))
        timed.append(start + current[0])
        start += current[0] + 1
    _write(out, "".join(recorded))
    _write(join(work, "timed-out.json"), "[" + ",".join(timed_texts[k] for k in timed) + "]")
    return timed

def _components(path):
    # Path's components: `.` and empty pieces dropped after the first.
    parts = path.split("/")
    return [parts[0]] + [p for p in parts[1:] if p not in ("", ".")]

def python_types(path, th):
    # harness.rs `python_types`: the dataclasses of the file and of the
    # `.py` files beside it (in path order), ("ok", [(name, text)]) or
    # ("decline",) when one of them has a tree python.rs may read otherwise.
    files = [path]
    d = os.path.dirname(path)
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    siblings = []
    for name in names:
        k = name.rfind(".")
        if k <= 0 or name == ".." or name[k + 1 :] != "py":
            continue
        p = os.path.join(d, name)
        if _components(p) == _components(path):
            continue
        siblings.append(p)
    siblings.sort()
    out = []
    for p in files + siblings:
        r = th["python_dataclass_types"](p)
        if r[0] == "unreadable":
            continue
        if r[0] != "ok":
            return ("decline",)
        out += list(r[1])
    return ("ok", out)

def make_loader(th):
    return lambda path: python_types(path, th)

_WS = set("\\t\\n\\x0b\\x0c\\r \\x85\\xa0\\u1680\\u2000\\u2001\\u2002\\u2003\\u2004\\u2005\\u2006"
          "\\u2007\\u2008\\u2009\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000")

class _Odd(Exception):
    pass

def _int(text):
    v = int(text)
    # serde_json reads `-0` as -0.0, and an integer past the 64-bit limits
    # as a float: their texts would differ.
    if (text.startswith("-") and v == 0) or not (-(2 ** 63) <= v < 2 ** 64):
        raise _Odd()
    return v

def _float(text):
    v = float(text)
    if v != v or v in (float("inf"), float("-inf")):
        raise _Odd()
    return v

def _constant(name):
    raise _Odd()

def _pairs(pairs):
    # serde_json's map with preserve_order: a key met again keeps its place
    # and takes the later value, as a dict does.
    out = {}
    for k, v in pairs:
        out[k] = v
    return out

def _plain(v):
    # No lone surrogate in a string or key (serde_json refuses them).
    if isinstance(v, str):
        return not any(0xD800 <= ord(c) <= 0xDFFF for c in v)
    if isinstance(v, list):
        return all(_plain(x) for x in v)
    if isinstance(v, dict):
        return all(_plain(k) and _plain(x) for k, x in v.items())
    return True

def read_inputs(path):
    # The lines of `--inputs` as generate_cases reads them: ("ok", [(line
    # number, value)]), ("error", message) for a file that does not read,
    # ("decline",) where serde_json may read the file or a line otherwise.
    import json
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError as e:
        return ("error", "reading %s: %s" % (path, _io(e)))
    try:
        text = data.decode("utf-8")
    except UnicodeError:
        return ("decline",)
    out = []
    for i, line in enumerate(_lines(text)):
        if all(c in _WS for c in line):
            continue
        try:
            v = json.loads(line, parse_int=_int, parse_float=_float,
                           parse_constant=_constant, object_pairs_hook=_pairs)
        except (ValueError, _Odd, RecursionError):
            return ("decline",)
        if not _plain(v):
            return ("decline",)
        out.append((i + 1, v))
    return ("ok", out)

def read_pin(crate_dir):
    # pin::load: ("none",) when pinned.json does not read as text, ("ok",
    # now_ms, seed), or ("decline",) where serde_json would refuse it (the
    # Rust tool stops after writing the driver) or may read it otherwise.
    import json
    try:
        with open(join(crate_dir, "pinned.json"), "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        return ("none",)

    def pairs(items):
        keys = [k for k, _ in items]
        if len(keys) != len(set(keys)):
            raise _Odd()
        return dict(items)

    try:
        v = json.loads(text, parse_int=_int, parse_float=_float,
                       parse_constant=_constant, object_pairs_hook=pairs)
    except (ValueError, _Odd, RecursionError):
        return ("decline",)
    if not isinstance(v, dict) or not _plain(v):
        return ("decline",)
    now, seed = v.get("now_ms"), v.get("seed")
    if type(now) is not int or type(seed) is not int:
        return ("decline",)
    if not (-(2 ** 63) <= now < 2 ** 63) or not (0 <= seed < 2 ** 32):
        return ("decline",)
    return ("ok", now, seed)

def set_pin(crate_dir, on, helper_text):
    # pin::set after Manifest::load: ("ok", the helper's path when it was
    # written, else ""), or ("error", message).
    path = join(crate_dir, "pinned.json")
    if not on:
        if os.path.exists(path):
            try:
                os.remove(path)
            except OSError as e:
                return ("error", "removing %s: %s" % (path, _io(e)))
        return ("ok", "")
    p = read_pin(crate_dir)
    now, seed = (p[1], p[2]) if p[0] == "ok" else (1700000000000, 1)
    try:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write('{\\n  "now_ms": %d,\\n  "seed": %d\\n}\\n' % (now, seed))
    except OSError as e:
        return ("error", "writing %s: %s" % (path, _io(e)))
    helper = join(crate_dir, "pinned.mojo")
    if os.path.exists(helper):
        return ("ok", "")
    try:
        _create_dir_all(os.path.dirname(helper) or crate_dir)
    except Failed as e:
        return ("error", str(e))
    try:
        with open(helper, "w", encoding="utf-8", newline="") as f:
            f.write(helper_text)
    except OSError as e:
        return ("error", "writing %s: %s" % (helper, _io(e)))
    return ("ok", helper)

def python_hook(driver, head, tail):
    # from_tests.rs `python_hook`: the hook with the driver's `enc`.
    start = driver.find("def enc(")
    end = driver[start:].find("\\ndef dec(") if start >= 0 else -1
    enc = driver[start : start + end] if end >= 0 else "def enc(v, stack=()):\\n    return v\\n"
    return head + "\\n" + enc + "\\n" + tail

def canonical(path):
    try:
        return os.path.realpath(path, strict=True)
    except OSError:
        return None

def capture(crate_dir, root, argv, want, hook_text, exported, limit):
    # from_tests.rs `capture` for a Python unit, after Manifest::load:
    # ("ok", inputs path, [(name, n)] by name, tests passed) or ("error",
    # message).
    import json
    try:
        raw = join(crate_dir, "test-calls.raw.jsonl")
        try:
            os.remove(raw)
        except OSError:
            pass
        hook = join(join(crate_dir, "target"), "from-tests")
        _create_dir_all(hook)
        _write(join(hook, "sitecustomize.py"), hook_text)
        env = dict(os.environ)
        env["MOJO_ANYTHING_CAPTURE"] = raw
        env["CI"] = "1"
        old = os.environ.get("PYTHONPATH")
        env["PYTHONPATH"] = ":".join([hook] + (old.split(":") if old is not None else []))
        env["MOJO_ANYTHING_CAPTURE_FUNCS"] = want
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        shown = " ".join(argv)
        try:
            child = subprocess.Popen(argv, stdin=subprocess.DEVNULL, stdout=2, cwd=root,
                                     env=env, process_group=0)
        except OSError as e:
            raise Failed("running `%s`: running `%s`: %s" % (shown, shown, _io(e)))
        try:
            child.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
            raise Failed(
                "running `%s`: `%s` was still running after %ds and was stopped (set "
                "MOJO_ANYTHING_COMMAND_TIMEOUT to allow longer; a test runner in watch mode "
                "never ends, so run it once, e.g. `vitest run`)" % (shown, shown, int(limit)))
        passed = child.returncode == 0
        text = read_text(raw)
        try:
            os.remove(raw)
        except OSError:
            pass
        seen = set()
        per = {}
        out = []
        for line in _lines(text):
            try:
                call = json.loads(line)
            except (ValueError, RecursionError):
                continue
            name = call.get("fn") if isinstance(call, dict) else None
            if not isinstance(name, str):
                continue
            if name not in exported or not isinstance(call.get("args"), list) or line in seen:
                continue
            seen.add(line)
            n = per.get(name, 0)
            if n >= 1000:
                continue
            per[name] = n + 1
            out.append(line + "\\n")
        inputs = join(crate_dir, "test-inputs.jsonl")
        try:
            with open(inputs, "w", encoding="utf-8", newline="") as f:
                f.write("".join(out))
        except OSError as e:
            raise Failed("writing %s: %s" % (inputs, _io(e)))
        return ("ok", inputs, sorted(per.items()), passed)
    except Failed as e:
        return ("error", str(e))

def with_own_inputs(crate_dir, own, captured):
    # from_tests.rs `with_own_inputs` with `own` given: ("ok", path) or
    # ("error", message).
    try:
        with open(own, "rb") as f:
            data = f.read()
    except OSError as e:
        return ("error", "reading %s: %s" % (own, _io(e)))
    try:
        text = data.decode("utf-8")
    except UnicodeError:
        return ("error", "reading %s: stream did not contain valid UTF-8" % own)
    if text and not text.endswith("\\n"):
        text += "\\n"
    try:
        with open(captured, "rb") as f:
            text += f.read().decode("utf-8")
    except OSError as e:
        return ("error", _io(e))
    except UnicodeError:
        return ("error", "stream did not contain valid UTF-8")
    target = join(crate_dir, "target")
    combined = join(target, "record-inputs.jsonl")
    try:
        _create_dir_all(target)
        _write(combined, text)
    except Failed as e:
        return ("error", str(e))
    return ("ok", combined)

def kind(v):
    # The JSON kind of a value read_inputs gave.
    if v is None:
        return "null"
    if isinstance(v, bool):
        return "bool"
    if isinstance(v, int):
        return "int"
    if isinstance(v, float):
        return "float"
    if isinstance(v, str):
        return "str"
    if isinstance(v, list):
        return "list"
    return "dict"

def summarize(path):
    # harness.rs `summarize` of cases.jsonl: (cases, threw, [(name, n)] by name).
    import json
    per = {}
    count = 0
    errors = 0
    for line in _lines(read_text(path)):
        if not line:
            continue
        case = json.loads(line)
        count += 1
        if not isinstance(case, dict):
            per[""] = per.get("", 0) + 1
            continue
        results = case.get("results")
        class_error = isinstance(results, list) and any(
            isinstance(x, dict) and "error" in x for x in results)
        if "error" in case or "panic" in case or class_error:
            errors += 1
        name = case.get("fn")
        if not isinstance(name, str):
            name = case.get("class")
        if not isinstance(name, str):
            name = ""
        per[name] = per.get(name, 0) + 1
    return (count, errors, sorted(per.items()))
"""


def _helpers() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(_PY, scope)
    return scope


def _len(x: PythonObject) raises -> Int:
    return Int(py=Python.import_module("builtins").len(x))


def _c_pointers(params: List[Param]) -> Bool:
    for p in params:
        if is_c_pointer(p.ts_type):
            return True
    return False


def _plain_count(text: String) -> Int:
    """`--count` as clap's usize parser reads plain digits; -1 otherwise."""
    if text.byte_length() == 0 or text.byte_length() > 18:
        return -1
    var n = 0
    for b in text.as_bytes():
        if b < 48 or b > 57:
            return -1
        n = n * 10 + Int(b - 48)
    return n


def _case_limit() raises -> Float64:
    """harness.rs `case_timeout`: MOJO_ANYTHING_CASE_TIMEOUT seconds when a
    finite positive number, else 10; -1 for one Rust may read otherwise than
    Python's `float` (spaces, underscores, text outside ASCII) or one past
    what `Duration::from_secs_f64` takes."""
    var text = getenv("MOJO_ANYTHING_CASE_TIMEOUT")
    if text == "":
        return 10.0
    for b in text.as_bytes():
        if b == 32 or b == 9 or b == 10 or b == 13 or b == 95 or b > 127:
            return -1.0
    try:
        var v = Float64(py=Python.import_module("builtins").float(text))
        if v != v or v <= 0.0 or v == Float64.MAX * 2.0:
            return 10.0
        if v > 1e18:
            return -1.0
        return v
    except:
        return 10.0


def _serde(h: PythonObject, v: PythonObject) raises -> String:
    """serde_json's `to_string` of a value `read_inputs` gave."""
    var k = String(py=h["kind"](v))
    if k == "null":
        return "null"
    if k == "bool":
        return "true" if Bool(py=v) else "false"
    if k == "int":
        return String(py=Python.import_module("builtins").str(v))
    if k == "float":
        return json_number_to_string(Float64(py=v))
    if k == "str":
        return write_string(String(py=v))
    if k == "list":
        var out = String("[")
        for i in range(_len(v)):
            if i > 0:
                out += ","
            out += _serde(h, v[i])
        return out + "]"
    var out = String("{")
    var items = Python.import_module("builtins").list(v.items())
    for i in range(_len(items)):
        if i > 0:
            out += ","
        out += write_string(String(py=items[i][0])) + ":"
        out += _serde(h, items[i][1])
    return out + "}"


def _str_field(
    h: PythonObject, given: PythonObject, key: String
) raises -> Optional[String]:
    """`given[key].as_str()`."""
    if String(py=h["kind"](given)) != "dict":
        return None
    if not Bool(py=given.__contains__(PythonObject(key))):
        return None
    var v = given[PythonObject(key)]
    if String(py=h["kind"](v)) != "str":
        return None
    return String(py=v)


def _given(
    m: Manifest,
    h: PythonObject,
    path: String,
    mut texts: List[String],
    mut fns: List[String],
    mut shown: List[String],
) raises:
    """generate_cases' `--inputs` lines, each given the module of its
    function or class. Raises DECLINE for a file or line serde_json may read
    otherwise than Python's json."""
    var r = h["read_inputs"](PythonObject(path))
    var state = String(py=r[0])
    if state == "error":
        raise Error(String(py=r[1]))
    if state != "ok":
        raise Error(DECLINE)
    var lines = r[1]
    for i in range(_len(lines)):
        var n = Int(py=lines[i][0])
        var given = lines[i][1]
        var fn_name = _str_field(h, given, "fn")
        var file = Optional[String](None)
        var class_name = _str_field(h, given, "class")
        if class_name:
            for c in m.classes:
                if c.name == class_name.value():
                    file = c.file
                    break
            if not file:
                raise Error(
                    String(
                        path,
                        ":",
                        n,
                        ": `",
                        class_name.value(),
                        "` is not a ported class of this unit",
                    )
                )
        else:
            var name = fn_name.or_else("")
            for f in m.exports:
                if f.name == name:
                    file = f.file
                    break
            if not file:
                raise Error(
                    String(
                        path,
                        ":",
                        n,
                        ": `",
                        name,
                        "` is not an export of this unit",
                    )
                )
        given[PythonObject("module")] = h["join"](
            PythonObject(m.root), PythonObject(file.value())
        )
        texts.append(_serde(h, given))
        fns.append(fn_name.or_else("?"))
        if Bool(py=given.__contains__(PythonObject("args"))):
            shown.append(_serde(h, given[PythonObject("args")]))
        else:
            shown.append("null")


def uses_regex(language: String, text: String) -> Bool:
    """risks.rs `uses_regex` for Python, Go and Ruby sources."""
    var needles: List[String]
    if language == "go":
        needles = ['"regexp"']
    elif language == "ruby":
        needles = [
            "=~",
            "Regexp",
            "%r{",
            ".match(",
            ".scan(/",
            ".gsub(/",
            ".sub(/",
            ".split(/",
            ".match?(",
        ]
    else:
        needles = [
            "import re\n",
            "import re ",
            "from re import",
            "import regex",
            "re.compile(",
        ]
    for needle in needles:
        if text.find(needle) >= 0:
            return True
    return False


def _generate(
    m: Manifest,
    h: PythonObject,
    mut g: Gen,
    count: Int,
    mut texts: List[String],
    mut fns: List[String],
    mut shown: List[String],
    mut regex_functions: List[String],
) raises:
    """generate_cases: every function's inputs and traps, then the classes'
    scenarios. Raises DECLINE for a type the shape reader does not read."""
    var regex_files = Dict[String, Bool]()
    for f in m.exports:
        var module = String(
            py=h["join"](PythonObject(m.root), PythonObject(f.file))
        )
        if f.file not in regex_files:
            var text = String(py=h["read_text"](PythonObject(module)))
            regex_files[f.file] = uses_regex(m.language, text)
        var regex = regex_files[f.file]
        if regex:
            for p in f.params:
                if param_rtype(p) == "Str":
                    regex_functions.append(f.name)
                    break
        # Rust reads other languages' named types with the TS reader.
        g.set_scope(module, m.language != "python")
        var all = generate(g, f, count)
        var seen = Set[String]()
        for a in all:
            seen.add(array_text(a))
        var base = List[GV]()
        if len(all) > 0:
            base = all[0].copy()
        for args in trap_args(g, f.params, base, regex):
            var key = array_text(args)
            if key not in seen:
                seen.add(key)
                all.append(args.copy())
        for i in range(len(all)):
            if m.language == "python" and i % 4 == 3:
                intify(f.params, all[i])
            texts.append(case_text(f, module, all[i]))
            fns.append(f.name)
            shown.append(array_text(_shown_args(f, all[i])))
    for c in m.classes:
        var module = String(
            py=h["join"](PythonObject(m.root), PythonObject(c.file))
        )
        g.set_scope(module, True)
        for s in scenarios(g, c, max(count, 20), module):
            texts.append(s)
            fns.append("?")
            shown.append("null")


def _capture(
    m: Manifest,
    h: PythonObject,
    crate_dir: String,
    command: List[String],
    own: Optional[String],
) raises -> String:
    """from_tests.rs `capture` and `with_own_inputs` for a Python unit, and
    what `record` prints of them: the inputs file the recording takes."""
    var want = Dict[String, List[String]]()
    var paths = List[String]()
    for f in m.exports:
        var path = h["canonical"](
            h["join"](PythonObject(m.root), PythonObject(f.file))
        )
        var key = String(py=path)
        if key not in want:
            want[key] = List[String]()
            paths.append(key)
        want[key].append(f.name)
    # serde_json of a BTreeMap: keys in byte order.
    for i in range(1, len(paths)):
        var j = i
        while j > 0 and paths[j] < paths[j - 1]:
            paths.swap_elements(j, j - 1)
            j -= 1
    var json = String("{")
    for i in range(len(paths)):
        if i > 0:
            json += ","
        json += write_string(paths[i]) + ":["
        ref names = want[paths[i]]
        for k in range(len(names)):
            if k > 0:
                json += ","
            json += write_string(names[k])
        json += "]"
    json += "}"
    var argv = Python.list()
    for a in command:
        argv.append(PythonObject(a))
    var exported = Python.list()
    for f in m.exports:
        exported.append(PythonObject(f.name))
    var hook = h["python_hook"](
        PythonObject(driver_py()),
        PythonObject(py_hook_head()),
        PythonObject(py_hook_tail()),
    )
    var c = h["capture"](
        PythonObject(crate_dir),
        PythonObject(m.root),
        argv,
        PythonObject(json),
        hook,
        exported,
        PythonObject(process_limit(TESTS)),
    )
    if String(py=c[0]) != "ok":
        raise Error(String(py=c[1]))
    var per = c[2]
    var total = 0
    for i in range(_len(per)):
        total += Int(py=per[i][1])
    var failed = String("")
    if not Bool(py=c[3]):
        failed = " (the test command failed; calls made before that are kept)"
    print(String("Captured ", total, " call(s) from the tests", failed, ":"))
    for i in range(_len(per)):
        print(String("  ", String(py=per[i][0]), ": ", Int(py=per[i][1])))
    var captured = String(py=c[1])
    if not own:
        return captured
    var w = h["with_own_inputs"](
        PythonObject(crate_dir),
        PythonObject(own.value()),
        PythonObject(captured),
    )
    if String(py=w[0]) != "ok":
        raise Error(String(py=w[1]))
    return String(py=w[1])


def _declined_from_tests(
    m: Manifest, h: PythonObject, crate_dir: String
) raises -> Bool:
    """What `capture` would do otherwise or fail on after starting: a file of
    the unit that does not canonicalize, a crate path holding the PATH
    separator (join_paths refuses it)."""
    if crate_dir.find(":") >= 0:
        return True
    for f in m.exports:
        if (
            h["canonical"](
                h["join"](PythonObject(m.root), PythonObject(f.file))
            )
            is Python.none()
        ):
            return True
    return False


def record_python(
    m: Manifest,
    crate_dir: String,
    count_text: String,
    inputs: Optional[String],
    pin_clock: Int,
    from_tests: Bool,
    test_command: List[String],
    argv: List[String],
) raises -> Int:
    """`record` of a Python unit; `pin_clock` is 1 for `--pin-clock`, 2 for
    `--no-pin-clock`, 0 for neither."""
    if from_tests and len(test_command) == 0:
        raise Error(
            "--from-tests needs the test command after `--`, e.g. `-- npx jest`"
        )
    var count = _plain_count(count_text)
    var limit = _case_limit()
    if count < 0 or limit < 0.0:
        return fallback(argv)
    for f in m.exports:
        if _c_pointers(f.params):
            return fallback(argv)
    for c in m.classes:
        if _c_pointers(c.constructor):
            return fallback(argv)
        for f in c.methods:
            if _c_pointers(f.params):
                return fallback(argv)
    var h = _helpers()
    if pin_clock != 2:
        var p = h["read_pin"](PythonObject(crate_dir))
        if String(py=p[0]) == "decline":
            return fallback(argv)
    if inputs:
        var r = h["read_inputs"](PythonObject(inputs.value()))
        if String(py=r[0]) == "decline":
            return fallback(argv)
    if from_tests and _declined_from_tests(m, h, crate_dir):
        return fallback(argv)
    if String(py=h["python_name"]()) != "python3":
        return fallback(argv)
    var g = Gen(h["make_loader"](tree_helpers()))
    var texts = List[String]()
    var fns = List[String]()
    var shown = List[String]()
    var regex_functions = List[String]()
    try:
        _generate(m, h, g, count, texts, fns, shown, regex_functions)
    except e:
        if String(e) == DECLINE:
            return fallback(argv)
        raise e^
    # Rust captures the tests and sets the pin before it generates the
    # cases: an error in the inputs comes after both.
    var given = inputs
    if from_tests:
        given = _capture(m, h, crate_dir, test_command, inputs)
    if pin_clock != 0:
        var s = h["set_pin"](
            PythonObject(crate_dir),
            PythonObject(pin_clock == 1),
            PythonObject(pinned_mojo()),
        )
        if String(py=s[0]) != "ok":
            raise Error(String(py=s[1]))
        var helper = String(py=s[1])
        if helper != "":
            print(
                String(
                    "Wrote ",
                    helper,
                    (
                        ": import it in port.mojo (`from pinned import now_ms,"
                        " random`) and call `now_ms()` and `random()` where"
                        " the original reads the clock or draws a number"
                    ),
                )
            )
    var pending = Optional[String](None)
    if given:
        try:
            _given(m, h, given.value(), texts, fns, shown)
        except e:
            pending = String(e)
    if pending:
        raise Error(pending.value())
    var pin = h["read_pin"](PythonObject(crate_dir))
    var pinned = String(py=pin[0]) == "ok"
    var pin_arg = Python.none()
    if pinned:
        pin_arg = Python.tuple(pin[1], pin[2])
    var pt = Python.list()
    for t in texts:
        pt.append(PythonObject(t))
    var r = h["record"](
        pt,
        PythonObject(crate_dir),
        PythonObject(driver_py()),
        PythonObject(limit),
        pin_arg,
    )
    if String(py=r[0]) != "ok":
        raise Error(String(py=r[1]))
    var timed = r[1]
    save_fingerprint(crate_dir, m.root, m.unit)
    var out = String(
        py=h["join"](PythonObject(crate_dir), PythonObject("cases.jsonl"))
    )
    var s = h["summarize"](PythonObject(out))
    print(
        String(
            "Recorded ",
            Int(py=s[0]),
            " cases (",
            Int(py=s[1]),
            " threw) in ",
            out,
        )
    )
    var per = s[2]
    for i in range(_len(per)):
        print(String("  ", String(py=per[i][0]), ": ", Int(py=per[i][1])))
    # outcome.pinned: pinned.json as it is after the recording.
    var after = h["read_pin"](PythonObject(crate_dir))
    if String(py=after[0]) == "ok":
        var builtins = Python.import_module("builtins")
        print(
            String(
                "Clock pinned at ",
                String(py=builtins.str(after[1])),
                " ms (UTC), random numbers from seed ",
                String(py=builtins.str(after[2])),
                " (pinned.json)",
            )
        )
    if len(regex_functions) > 0:
        var joined = String("")
        for i in range(len(regex_functions)):
            if i > 0:
                joined += ", "
            joined += regex_functions[i]
        print(
            "Regex traps (non-ASCII \\w, \\b and case folding) added for: "
            + joined
        )
    var n = _len(timed)
    if n > 0:
        print(
            String(
                "Left out ",
                n,
                (
                    " input(s) the original ran too long on (over the per-case"
                    " limit, MOJO_ANYTHING_CASE_TIMEOUT seconds, 10 by"
                    " default). The original does this itself, so the port"
                    " need not match it there:"
                ),
            )
        )
        for i in range(n):
            var k = Int(py=timed[i])
            print(String("  ", fns[k], "(", shown[k], ")"))
    return 0


def _shown_args(f: ExportedFn, args: List[GV]) -> List[GV]:
    """The `args` a case carries after keyword-only parameters moved out."""
    var keyword = False
    for p in f.params:
        if p.keyword_only:
            keyword = True
    if not keyword:
        return args.copy()
    var out = List[GV]()
    for i in range(len(args)):
        if not (i < len(f.params) and f.params[i].keyword_only):
            out.append(args[i].copy())
    return out^
