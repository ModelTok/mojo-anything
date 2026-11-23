# `map`: which units have a Mojo port and which do not yet (port of
# src/port_map.rs and the `map` arm of src/main.rs).
#
# This slice answers a repository with no port in it: one with no unit for
# `analyze` to list (its empty plan, analyze.mojo's `empty_workspace`), and a
# Python repository whose plan analyze.mojo builds, every unit of which is
# then not ported yet: the map in Markdown, JSON or mojo/PORT_MAP.md
# (`--write`), and `--check`, which has nothing to fail on. A repository that
# does not exist gets the Rust tool's error. A `mojo-anything.json` anywhere
# under the repository (a port to list), front-door glue (`mojo/app/glue`),
# `--crates`, a repository that is a file or `/`, and every workspace
# `analyze` would not answer in Mojo go to the Phase 1 binary before anything
# is written.

from std.python import Python, PythonObject

from mojo_anything.analyze import (
    detect_lang,
    empty_workspace,
    helpers,
    python_plan,
    python_workspace,
)
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback
from mojo_anything.json_text import write_string
from mojo_anything.plan import Report, UnitReport
from mojo_anything.python_lang import py_helpers

comptime MAP_FILE = "mojo/PORT_MAP.md"

comptime _PY = """
import os

def canon(repo):
    try:
        os.stat(repo)
    except FileNotFoundError:
        return ("missing", "")
    except (OSError, ValueError):
        return ("other", "")
    if not os.path.isdir(repo):
        return ("other", "")
    return ("dir", os.path.realpath(repo))

def has_manifest(root):
    bad = []
    for base, dirs, files in os.walk(root, onerror=bad.append):
        if "mojo-anything.json" in dirs or "mojo-anything.json" in files:
            return 1
    return 1 if bad else 0

def write_map(root, text):
    try:
        os.makedirs(os.path.join(root, "mojo"), exist_ok=True)
        with open(os.path.join(root, "mojo", "PORT_MAP.md"), "w", encoding="utf-8", newline="") as f:
            f.write(text)
        return 1
    except OSError:
        return 0
"""


def _name_of(path: String) -> String:
    var slash = path.rfind("/")
    if slash < 0:
        return path
    return String(path[byte = slash + 1 :])


def _order(r: Report, id: String) -> Int:
    """A unit's place in start_here (usize::MAX for none)."""
    for i in range(len(r.start_here)):
        if r.start_here[i] == id:
            return i
    return len(r.start_here) + 1


def not_ported(report: Report) -> List[UnitReport]:
    """Every unit of the plan (a map with no port covers none), in the order
    `analyze` suggests: start_here first, then priority, then id."""
    var out = List[UnitReport]()
    for u in report.units:
        var at = len(out)
        while at > 0:
            ref q = out[at - 1]
            var oq = _order(report, q.id)
            var ou = _order(report, u.id)
            var before = oq < ou or (
                oq == ou
                and (
                    q.priority > u.priority
                    or (q.priority == u.priority and q.id <= u.id)
                )
            )
            if before:
                break
            at -= 1
        out.insert(at, u.copy())
    return out^


def map_markdown(root: String, units: List[UnitReport]) -> String:
    """port_map::markdown of a map with no port."""
    var out = String("# Port map: ", _name_of(root), "\n\n")
    out += String("0 of ", len(units), " units have a Mojo port.\n\n")
    out += "## Ports\n\n"
    out += "None yet: `mojo-anything bridge` starts one.\n\n"
    out += "## Not ported yet\n\n"
    if len(units) == 0:
        out += "Every unit `analyze` found has a port.\n\n"
    else:
        out += "In the order `analyze` suggests.\n\n"
        out += "| Unit | Lines | Exports | Readiness |\n"
        out += "| --- | ---: | ---: | ---: |\n"
        for u in units:
            out += String(
                "| `",
                u.id,
                "` | ",
                u.loc,
                " | ",
                u.exports,
                " | ",
                u.readiness,
                " |\n",
            )
        out += "\n"
    out += (
        "Regenerate with `mojo-anything map --write`. Commit this file: when"
        " the original changes upstream, the next map marks every port whose"
        " recording it outdated.\n"
    )
    return out^


def map_json(root: String, units: List[UnitReport]) -> String:
    """serde_json::to_string_pretty of the same map, and a newline."""
    var out = String("{\n")
    out += '  "root": ' + write_string(root) + ",\n"
    out += '  "ports": [],\n'
    if len(units) == 0:
        out += '  "not_ported": [],\n'
    else:
        out += '  "not_ported": [\n'
        for i in range(len(units)):
            ref u = units[i]
            out += "    {\n"
            out += '      "unit": ' + write_string(u.id) + ",\n"
            out += String('      "loc": ', u.loc, ",\n")
            out += String('      "readiness": ', u.readiness, ",\n")
            out += String('      "exports": ', u.exports, "\n")
            out += "    }"
            if i + 1 < len(units):
                out += ","
            out += "\n"
        out += "  ],\n"
    out += '  "glue": []\n'
    out += "}\n"
    return out^


def empty_map_markdown(root: String) -> String:
    """port_map::markdown of a map with no port and nothing left to port."""
    return map_markdown(root, List[UnitReport]())


def empty_map_json(root: String) -> String:
    """serde_json::to_string_pretty of the same map, and a newline."""
    return map_json(root, List[UnitReport]())


def run_map(p: Parsed, argv: List[String]) raises -> Int:
    if len(p.all("crates")) > 0:
        return fallback(argv)
    var repo = p.value("REPO").or_else(".")
    if repo.byte_length() == 0:
        return fallback(argv)
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(_PY, scope)
    var c = scope["canon"](PythonObject(repo))
    var state = String(py=c[0])
    if state == "missing":
        raise Error("No such file or directory (os error 2)")
    if state != "dir":
        return fallback(argv)
    var root = String(py=c[1])
    if root == "/":
        return fallback(argv)
    if Int(py=scope["has_manifest"](PythonObject(root))) != 0:
        return fallback(argv)
    var os = Python.import_module("os")
    if Bool(py=os.path.lexists(PythonObject(root + "/mojo/app/glue"))):
        return fallback(argv)
    var py = helpers()
    var lang = detect_lang(root)
    var units = List[UnitReport]()
    var planned = False
    if lang == "python":
        var pyh = py_helpers()
        var ws = python_workspace(root, pyh)
        if ws.declined:
            return fallback(argv)
        if len(ws.files) > 0:
            var declined = False
            var report = python_plan(root, ws, pyh, declined)
            if declined:
                return fallback(argv)
            units = not_ported(report)
            planned = True
    if not planned:
        var d = empty_workspace(lang, root, py)
        if d.declined:
            return fallback(argv)
    if p.flag("json"):
        print(map_json(root, units), end="")
    elif p.flag("write"):
        if (
            Int(
                py=scope["write_map"](
                    PythonObject(root), PythonObject(map_markdown(root, units))
                )
            )
            != 1
        ):
            return fallback(argv)
        print("Wrote " + root + "/" + MAP_FILE)
    else:
        print(map_markdown(root, units), end="")
    # `--check` fails only on a port whose original changed: there is none.
    return 0
