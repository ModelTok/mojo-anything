# `mojo-anything app replay` of a library (port of `replay` and `pending` in
# src/library.rs): every wired unit's recorded cases run through its bindings
# with `diff`, and the fallback rate is the share of the public API still
# answered by the original. `diff` is not moved yet: each unit's runs as
# `<this binary> diff <crate> --json`, which hands it to the Phase 1 binary
# and logs that fallback. What its output holds that this port cannot print
# as serde_json would (a float) goes to the Phase 1 binary, before the report
# is written.

from std.python import Python, PythonObject


from mojo_anything.pycache import py_exec
from mojo_anything.app.cases import REPORT_FILE, decline, join, words_quotable
from mojo_anything.app.py import py_len, py_strings
from mojo_anything.app.replay import Failure, Outcome, Problem, report_markdown

comptime APP_DIR = "mojo/app"

comptime _SOURCE = """
_APP_SCHEMA = "mojo-anything/app@1"


def _str_or_null(d, key):
    return key not in d or d[key] is None or isinstance(d[key], str)


def _list_of_str(d, key, required=False):
    if key not in d:
        return not required
    v = d[key]
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def library_state(repo):
    # ("lib", state) when mojo/app/mojo-anything.json is a library's state
    # that front_door's `State::load` reads; ("no", None) otherwise, or when
    # serde could read it otherwise.
    path = os.path.join(repo, "mojo", "app", "mojo-anything.json")
    if not os.path.isfile(path):
        return ("no", None)
    text = _read_utf8(path)
    if text is None:
        return ("no", None)
    kind, v = _json_value(text)
    if kind != "ok" or not isinstance(v, dict) or v.get("schema") != _APP_SCHEMA:
        return ("no", None)
    if not isinstance(v.get("name"), str) or not _list_of_str(v, "commands", True):
        return ("no", None)
    if "lifted" in v and not isinstance(v["lifted"], bool):
        return ("no", None)
    if not _list_of_str(v, "routes") or v.get("kind", "cli") != "library":
        return ("no", None)
    units = v.get("units", [])
    api = v.get("api", [])
    if not isinstance(units, list) or not isinstance(api, list):
        return ("no", None)
    out_units = []
    for u in units:
        if not isinstance(u, dict):
            return ("no", None)
        for key in ("name", "crate", "path", "switch"):
            if not isinstance(u.get(key), str):
                return ("no", None)
        if not (_list_of_str(u, "commands") and _list_of_str(u, "routes")
                and _list_of_str(u, "kept") and _str_or_null(u, "unit")
                and _str_or_null(u, "shadow")):
            return ("no", None)
        out_units.append((u["name"], u["path"], u.get("unit"), list(u.get("kept", []))))
    out_api = []
    for a in api:
        if not isinstance(a, dict):
            return ("no", None)
        if not (isinstance(a.get("unit"), str) and isinstance(a.get("module"), str)
                and _list_of_str(a, "exports", True)):
            return ("no", None)
        out_api.append((a["unit"], list(a["exports"])))
    return ("lib", {"name": v["name"], "units": out_units, "api": out_api})


class _Float(Exception):
    pass


def _no_float(s):
    raise _Float()


def _compact(v):
    # serde_json's Display of a Value without floats.
    return json.dumps(v, ensure_ascii=False, separators=(",", ":"))


def library_diff(crate_dir):
    # `diff` of one unit through this binary (see library_diff_read).
    exe = os.readlink("/proc/self/exe")
    try:
        p = subprocess.run([exe, "diff", crate_dir, "--json"], stdin=subprocess.DEVNULL,
                           capture_output=True, close_fds=False)
    except (OSError, ValueError):
        # ValueError: a NUL in the path, which Rust reports otherwise.
        return ("odd",)
    return library_diff_read(p.returncode, p.stdout, p.stderr)


def library_diff_read(code, out, err):
    # What `diff --json` exited with and printed: ("ok", total, passed,
    # [(fn or None, [args], expected, actual)], missing), the values as
    # serde_json's Display writes them; ("error", text) for `error: text`;
    # ("odd",) for anything else, a float included.
    if code in (0, 1) and out and not err:
        try:
            v = json.loads(out.decode("utf-8"), parse_float=_no_float,
                           parse_constant=_const)
        except Exception:
            return ("odd",)
        if not isinstance(v, dict):
            return ("odd",)
        total, passed, missing = v.get("total"), v.get("passed"), v.get("missing")
        if not (_is_int(total) and _is_int(passed) and isinstance(missing, list)
                and all(isinstance(x, str) for x in missing)
                and isinstance(v.get("mismatches", []), list)):
            return ("odd",)
        mismatches = []
        for m in v.get("mismatches", []):
            if not isinstance(m, dict):
                return ("odd",)
            fn = m.get("fn")
            args = m.get("args")
            mismatches.append((
                fn if isinstance(fn, str) else None,
                [_compact(a) for a in args] if isinstance(args, list) else [],
                _compact(m.get("expected")),
                _compact(m.get("actual")),
            ))
        return ("ok", total, passed, mismatches, missing)
    if code != 0 and not out:
        try:
            t = err.decode("utf-8")
        except UnicodeDecodeError:
            return ("odd",)
        if t.startswith("error: ") and t.endswith("\\n"):
            return ("error", t[len("error: "):-1])
    return ("odd",)
"""


def library_helpers(h: PythonObject) raises:
    """Adds the helpers above to py.mojo's scope `h`."""
    py_exec(_SOURCE, h)


def _plain_unit_path(path: String) -> Bool:
    """A unit path `Path::join` and `std::path::absolute` spell alike: no
    empty or `.` component, no slash at either end."""
    if path == "" or path.startswith("/") or path.endswith("/"):
        return False
    var b = path.as_bytes()
    var start = 0
    for i in range(len(b) + 1):
        if i < len(b) and b[i] != 47:
            continue
        var part = String(path[byte=start:i])
        if part == "" or part == ".":
            return False
        start = i + 1
    return True


def _joined(items: List[String]) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += ", "
        out += items[i]
    return out


def pending(h: PythonObject, st: PythonObject) raises -> List[String]:
    """library.rs `pending`: the exports no wired Mojo unit answers yet."""
    var out = List[String]()
    var units = st["units"]
    var api = st["api"]
    for i in range(py_len(api)):
        var unit = String(py=api[i][0])
        var wired = -1
        for k in range(py_len(units)):
            var u = units[k][2]
            if not Bool(py=h["is_none"](u)) and String(py=u) == unit:
                wired = k
                break
        var kept = List[String]()
        if wired >= 0:
            kept = py_strings(units[wired][3])
        for name in py_strings(api[i][1]):
            if wired < 0 or name in kept:
                out.append(unit + ": " + name)
    return out^


def exports_count(st: PythonObject) raises -> Int:
    var n = 0
    var api = st["api"]
    for i in range(py_len(api)):
        n += py_len(api[i][1])
    return n


def replay(
    h: PythonObject, repo: String, st: PythonObject, only: Optional[String]
) raises -> Outcome:
    """library.rs `replay`."""
    var app_dir = join(repo, APP_DIR)
    var build: List[String] = ["the units' bindings"]
    var outcome = Outcome(build^, app_dir + "/" + REPORT_FILE)
    var units = st["units"]
    var chosen = List[Int]()
    var names = List[String]()
    for k in range(py_len(units)):
        var name = String(py=units[k][0])
        names.append(name)
        if not only or name == only.value():
            chosen.append(k)
    if only and len(chosen) == 0:
        raise Error(
            "no case named "
            + only.value()
            + "; the cases are: "
            + _joined(names)
        )
    for k in chosen:
        if not _plain_unit_path(String(py=units[k][1])):
            raise decline()
    for k in chosen:
        var name = String(py=units[k][0])
        var crate_dir = join(app_dir, String(py=units[k][1]))
        var d = h["library_diff"](PythonObject(crate_dir))
        var kind = String(py=d[0])
        if kind == "odd":
            raise decline()
        if kind == "error":
            outcome.total += 1
            var problems = List[Problem]()
            problems.append(
                Problem(
                    "replay",
                    String(py=d[1])
                    + "\n(build it first: mojo-anything build "
                    + crate_dir
                    + ")\n",
                )
            )
            outcome.failures.append(Failure(name, List[String](), problems^))
            continue
        outcome.total += Int(py=d[1])
        outcome.passed += Int(py=d[2])
        var mismatches = d[3]
        for i in range(py_len(mismatches)):
            var m = mismatches[i]
            var fn_name = String("?")
            if not Bool(py=h["is_none"](m[0])):
                fn_name = String(py=m[0])
            var args = py_strings(m[1])
            if not words_quotable(h, args):
                raise decline()
            var problems = List[Problem]()
            problems.append(
                Problem(
                    "result",
                    "- " + String(py=m[2]) + "\n+ " + String(py=m[3]) + "\n",
                )
            )
            outcome.failures.append(
                Failure(name + ": " + fn_name, args^, problems^)
            )
        var missing = py_strings(d[4])
        if len(missing) > 0:
            outcome.total += 1
            var problems = List[Problem]()
            problems.append(
                Problem("exports", "missing: " + _joined(missing) + "\n")
            )
            outcome.failures.append(
                Failure(name + ": api", List[String](), problems^)
            )
    outcome.reported = True
    outcome.fell_back = pending(h, st)
    outcome.fallback_total = exports_count(st)
    var text = report_markdown(h, outcome)
    var err = String(
        py=h["write_bytes"](
            PythonObject(outcome.report), h["utf8"](PythonObject(text))
        )
    )
    if err != "":
        raise Error("writing " + outcome.report + ": " + err)
    return outcome^
