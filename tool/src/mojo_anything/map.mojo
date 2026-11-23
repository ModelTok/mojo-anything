# `map`: which units have a Mojo port and which do not yet (port of
# src/port_map.rs and the `map` arm of src/main.rs).
#
# This slice answers a repository with no port in it and no unit for
# `analyze` to list (its empty plan, analyze.mojo's `empty_workspace`): the
# map in Markdown, JSON or mojo/PORT_MAP.md (`--write`), and `--check`, which
# has nothing to fail on. A repository that does not exist gets the Rust
# tool's error. A `mojo-anything.json` anywhere under the repository (a port
# to list), front-door glue (`mojo/app/glue`), `--crates`, a repository that
# is a file or `/`, and every workspace `analyze` would not answer in Mojo go
# to the Phase 1 binary before anything is written.

from std.python import Python, PythonObject

from mojo_anything.analyze import detect_lang, empty_workspace, helpers
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback
from mojo_anything.json_text import write_string

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


def empty_map_markdown(root: String) -> String:
    """port_map::markdown of a map with no port and nothing left to port."""
    var out = String("# Port map: ", _name_of(root), "\n\n")
    out += "0 of 0 units have a Mojo port.\n\n"
    out += "## Ports\n\n"
    out += "None yet: `mojo-anything bridge` starts one.\n\n"
    out += "## Not ported yet\n\n"
    out += "Every unit `analyze` found has a port.\n\n"
    out += (
        "Regenerate with `mojo-anything map --write`. Commit this file: when"
        " the original changes upstream, the next map marks every port whose"
        " recording it outdated.\n"
    )
    return out^


def empty_map_json(root: String) -> String:
    """serde_json::to_string_pretty of the same map, and a newline."""
    var out = String("{\n")
    out += '  "root": ' + write_string(root) + ",\n"
    out += '  "ports": [],\n'
    out += '  "not_ported": [],\n'
    out += '  "glue": []\n'
    out += "}\n"
    return out^


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
    var d = empty_workspace(detect_lang(root), root, py)
    if d.declined:
        return fallback(argv)
    if p.flag("json"):
        print(empty_map_json(root), end="")
    elif p.flag("write"):
        if (
            Int(
                py=scope["write_map"](
                    PythonObject(root), PythonObject(empty_map_markdown(root))
                )
            )
            != 1
        ):
            return fallback(argv)
        print("Wrote " + root + "/" + MAP_FILE)
    else:
        print(empty_map_markdown(root), end="")
    # `--check` fails only on a port whose original changed: there is none.
    return 0
