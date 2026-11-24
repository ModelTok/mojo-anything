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
# Declined before anything is written (the Phase 1 binary records): a type
# the shape reader (shape.mojo) does not read, a named type in a class's
# parameters (Rust reads a class's file with the TS type reader), a dataclass
# file whose tree has an error, a C pointer parameter, `pinned.json`, a
# per-case limit Rust may read otherwise, a `python3` that does not run, and
# a `--count` other than plain digits.

from std.collections import Dict, Set
from std.os import getenv
from std.python import Python, PythonObject

from mojo_anything.codegen_mojo import ExportedFn, Manifest, Param, param_rtype
from mojo_anything.embedded import driver_py
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
    text = "signal: %d (%s)" % (sig, _SIGNALS.get(sig, ""))
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

def record(texts, crate_dir, driver_text, limit):
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
            env = dict(os.environ)
            env["PYTHONHASHSEED"] = "0"
            env["PYTHONDONTWRITEBYTECODE"] = "1"
            for key in ("MOJO_ANYTHING_NOW_MS", "MOJO_ANYTHING_SEED", "MOJO_ANYTHING_CASE"):
                env.pop(key, None)
            env["MOJO_ANYTHING_PROGRESS"] = progress
            argv = [python_name(), driver, "record", inputs, part]
            try:
                err = open(stderr_path, "wb")
            except OSError as e:
                raise Failed(_io(e))
            scratch = _temp_dir("unit")
            try:
                try:
                    child = subprocess.Popen(argv, stdin=subprocess.DEVNULL,
                                             stdout=subprocess.DEVNULL, stderr=err,
                                             cwd=scratch, env=env, process_group=0)
                except OSError as e:
                    raise Failed("running python: " + _io(e))
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
                raise Failed("python failed (%s):\\n%s" % (_status(status), "\\n".join(tail)))
            timed.append(start + current[0])
            start += current[0] + 1
        _write(out, "".join(recorded))
        _write(join(work, "timed-out.json"), "[" + ",".join(texts[k] for k in timed) + "]")
        return ("ok", timed)
    except Failed as e:
        return ("error", str(e))

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
            var uses = False
            for needle in [
                "import re\n",
                "import re ",
                "from re import",
                "import regex",
                "re.compile(",
            ]:
                if text.find(needle) >= 0:
                    uses = True
            regex_files[f.file] = uses
        var regex = regex_files[f.file]
        if regex:
            for p in f.params:
                if param_rtype(p) == "Str":
                    regex_functions.append(f.name)
                    break
        g.set_scope(module, False)
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
            if i % 4 == 3:
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
            fns.append("")
            shown.append("null")


def record_python(
    m: Manifest, crate_dir: String, count_text: String, argv: List[String]
) raises -> Int:
    """`record` of a Python unit."""
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
    var pinned = h["join"](PythonObject(crate_dir), PythonObject("pinned.json"))
    if Bool(py=h["lexists"](pinned)):
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
    var pt = Python.list()
    for t in texts:
        pt.append(PythonObject(t))
    var r = h["record"](
        pt,
        PythonObject(crate_dir),
        PythonObject(driver_py()),
        PythonObject(limit),
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
            var name = fns[k] if fns[k] != "" else "?"
            print(String("  ", name, "(", shown[k], ")"))
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
