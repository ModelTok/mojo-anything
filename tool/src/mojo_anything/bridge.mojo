# `bridge` (port of src/bridge.rs `bridge` and the `bridge` arm of
# src/main.rs).
#
# Answered in Mojo: the root's errors, a unit that is not in the plan, a unit
# the plan keeps or blocks, the PHP and C# units (which no bridge serves yet),
# and Python units: their exports are read through tree-sitter-python
# (analyze_tree.py `python_exports`, python.rs `exports`), and the port's
# layout (`port.mojo`, `pixi.toml`, `.gitignore`, `README.md`,
# `mojo-anything.json`, `_native.mojo`, the wrapper package and `py_num.mojo`)
# is written as the Rust tool writes it. Every other case (other languages'
# exports, `--kind`, `--out`, `--name`, `--keep`, `--batch`, `--as-json`, a
# workspace `analyze` would not answer in Mojo, text outside ASCII) goes to
# the Phase 1 binary before anything is written.

from std.python import Python, PythonObject

from mojo_anything.analyze import (
    detect_lang,
    empty_workspace,
    helpers,
    lang_name,
    lang_plan,
)
from mojo_anything.cli_parse import Parsed
from mojo_anything.codegen_mojo import (
    ExportedClass,
    ExportedFn,
    JsOnly,
    MANIFEST,
    Manifest,
    Param,
    is_alnum,
    is_ascii,
    join,
    manifest_json,
    match_export_names,
    parse_port_mojo,
    port_mojo,
    trim_start_matches,
)
from mojo_anything.codegen_mojo_py import (
    GITIGNORE,
    mojo_py_bindings,
    mojo_readme,
    pixi_toml,
)
from mojo_anything.embedded import py_num_mojo
from mojo_anything.fallback import fallback
from mojo_anything.plan import BLOCKED, KEEP, UnitReport
from mojo_anything.tree_lang import tree_helpers

comptime _PY = """
import os

def canonical(path):
    # ("ok", real path) as fs::canonicalize gives it; ("missing", "") on
    # ENOENT; ("other", "") for anything else (declined).
    try:
        os.stat(path)
    except FileNotFoundError:
        return ("missing", "")
    except (OSError, ValueError):
        return ("other", "")
    real = os.path.realpath(path)
    if not real.isascii() or not os.path.isdir(real):
        return ("other", "")
    return ("ok", real)

def crate_state(path):
    # "free" (absent, or an empty folder), "full" (a folder with entries) or
    # "other" (not a folder, or unreadable).
    if not os.path.lexists(path):
        return "free"
    if os.path.islink(path) or not os.path.isdir(path):
        return "other"
    try:
        return "full" if os.listdir(path) else "free"
    except OSError:
        return "other"

def exists(path):
    return 1 if os.path.exists(path) else 0

def module_path(root, unit):
    # package::python_module_path.
    while unit.endswith("/"):
        unit = unit[:-1]
    if unit.endswith("/__init__.py"):
        unit = unit[: -len("/__init__.py")]
    if unit.endswith(".py"):
        unit = unit[:-3]
    parts = [p for p in unit.split("/") if p]
    start = max(len(parts) - 1, 0)
    if os.path.exists(os.path.join(root, unit)) or os.path.exists(os.path.join(root, unit + ".py")):
        while start > 0 and os.path.exists(os.path.join(root, "/".join(parts[:start]), "__init__.py")):
            start -= 1
    else:
        start = 1 if (parts and parts[0] in ("src", "lib") and len(parts) > 1) else 0
    return ".".join(parts[start:])

def write_files(base, paths, texts):
    for rel, text in zip(paths, texts):
        target = os.path.join(base, rel)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        with open(target, "w", encoding="utf-8", newline="") as f:
            f.write(text)
"""


def bridge_helpers() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(_PY, scope)
    return scope


def _len(x: PythonObject) raises -> Int:
    return Int(py=Python.import_module("builtins").len(x))


def _opt(v: PythonObject) raises -> Optional[String]:
    if v is Python.none():
        return None
    return String(py=v)


def _params(ps: PythonObject) raises -> List[Param]:
    var out = List[Param]()
    for i in range(_len(ps)):
        var p = ps[i]
        out.append(
            Param(
                String(py=p["name"]),
                String(py=p["ts_type"]),
                Bool(py=p["optional"]),
                False,
                _opt(p["default"]),
                Bool(py=p["keyword_only"]),
            )
        )
    return out^


def _function(f: PythonObject) raises -> ExportedFn:
    return ExportedFn(
        String(py=f["name"]),
        String(py=f["file"]),
        Int(py=f["line"]),
        _params(f["params"]),
        String(py=f["returns"]),
        Bool(py=f["is_async"]),
        Bool(py=f["is_generator"]),
        List[String](),
        False,
        _opt(f["blocker"]),
    )


def _is_word(b: UInt8) -> Bool:
    return is_alnum(b) or b == 95 or b == 36


def js_only_reason(f: ExportedFn) -> Optional[String]:
    """bridge::js_only_reason with no local types (every language but TS)."""
    if f.blocker:
        return f.blocker.value()
    if f.is_generator:
        return String("generator: returns a lazy iterator")
    if f.uses_instanceof:
        return String(
            "checks `instanceof`: class identity does not survive the bridge"
        )
    var types = List[String]()
    for p in f.params:
        types.append(p.ts_type)
    types.append(f.returns)
    for t in types:
        if t.find("=>") >= 0:
            return String("takes or returns a function")
    for t in types:
        var bytes = t.as_bytes()
        var start = 0
        for i in range(len(bytes) + 1):
            if i < len(bytes) and _is_word(bytes[i]):
                continue
            if i > start:
                var word = String(t[byte=start:i])
                if word == "RegExp":
                    return String("takes or returns a RegExp")
                if (
                    word == "Generator"
                    or word == "Iterator"
                    or word == "IterableIterator"
                    or word == "AsyncGenerator"
                    or word == "AsyncIterable"
                ):
                    return String("uses `", word, "`, a lazy iterator")
                if word == "Function":
                    return String("takes or returns a function")
                if word in f.type_params:
                    return String(
                        "generic over `",
                        word,
                        "`: values of any shape, functions included",
                    )
            start = i + 1
    return None


def _kind_debug(kind: String) -> String:
    if kind == "mojo-py":
        return "MojoPy"
    if kind == "c-abi":
        return "CAbi"
    if kind == "ffi":
        return "Ffi"
    if kind == "mojo-node":
        return "MojoNode"
    if kind == "mojo-wasm":
        return "MojoWasm"
    return "MojoJvm"


def _status_debug(status: Int) -> String:
    if status == KEEP:
        return "Keep"
    return "Blocked"


def _crate_name(id: String) -> String:
    """The default port name: the unit's last path word up to its first
    `.`, cleaned to ASCII lowercase and `-`, then `-mojo`."""
    var stem = id
    while stem.endswith("/"):
        var _t = String(stem[byte = 0 : stem.byte_length() - 1])
        stem = _t^
    var slash = stem.rfind("/")
    if slash >= 0:
        var _t = String(stem[byte = slash + 1 :])
        stem = _t^
    var dot = stem.find(".")
    if dot >= 0:
        var _t = String(stem[byte=0:dot])
        stem = _t^
    var clean = String("")
    for b in stem.as_bytes():
        if is_alnum(b):
            if b >= 65 and b <= 90:
                clean += chr(Int(b) + 32)
            else:
                clean += chr(Int(b))
        else:
            clean += "-"
    var a = 0
    var bytes = clean.as_bytes()
    var z = len(bytes)
    while a < z and bytes[a] == 45:
        a += 1
    while z > a and bytes[z - 1] == 45:
        z -= 1
    return String(clean[byte=a:z]) + "-mojo"


def _find_unit(units: List[UnitReport], wanted: String) -> Optional[UnitReport]:
    var bare = wanted
    while bare.endswith("/"):
        var _t = String(bare[byte = 0 : bare.byte_length() - 1])
        bare = _t^
    for u in units:
        var id = u.id
        while id.endswith("/"):
            var _t = String(id[byte = 0 : id.byte_length() - 1])
            id = _t^
        if u.id == wanted or id == bare:
            return u.copy()
    for u in units:
        if wanted in u.files:
            var one = u.copy()
            one.id = wanted
            one.files = List[String]()
            one.files.append(wanted)
            return one^
    return None


def _less(a_name: String, a_at: String, b_name: String, b_at: String) -> Bool:
    if a_name != b_name:
        return a_name < b_name
    return a_at < b_at


def run_bridge(p: Parsed, argv: List[String]) raises -> Int:
    for name in ["kind", "out", "name", "keep", "batch", "as-json"]:
        if p.value(name):
            return fallback(argv)
    var force = p.flag("force")
    var root_arg = p.value("ROOT").or_else("")
    var unit_arg = p.value("UNIT").or_else("")
    if root_arg.byte_length() == 0 or not is_ascii(root_arg):
        return fallback(argv)
    if not is_ascii(unit_arg):
        return fallback(argv)
    var bh = bridge_helpers()
    var c = bh["canonical"](PythonObject(root_arg))
    var state = String(py=c[0])
    if state == "missing":
        raise Error(
            String(
                "resolving ",
                root_arg,
                ": No such file or directory (os error 2)",
            )
        )
    if state != "ok":
        return fallback(argv)
    var root = String(py=c[1])
    var lang = detect_lang(root)
    if lang == "java" or lang == "kotlin":
        # require_java runs first; its probe is not ported.
        return fallback(argv)
    var py = helpers()
    var lp = lang_plan(lang, root, py)
    if lp.declined:
        return fallback(argv)
    if not lp.planned:
        var d = empty_workspace(lang, root, py)
        if d.declined:
            return fallback(argv)
    var wanted = trim_start_matches(unit_arg, "./")
    var found = _find_unit(lp.report.units, wanted)
    if not found:
        raise Error(
            String(
                "no unit or source file `",
                wanted,
                (
                    "`; `mojo-anything analyze` lists unit ids, and any source"
                    " file inside a unit can be bridged on its own"
                ),
            )
        )
    var unit = found.value().copy()
    if (unit.status == KEEP or unit.status == BLOCKED) and not force:
        var note = String("")
        if len(unit.notes) > 0:
            note = unit.notes[0]
        raise Error(
            String(
                "unit `",
                unit.id,
                "` is ",
                _status_debug(unit.status),
                ": ",
                note,
                ". Pass --force to bridge it anyway.",
            )
        )
    if lang == "php":
        raise Error(
            "bridging PHP units into Rust comes next (PHP FFI over a C ABI);"
            " for now a PHP app can be analyzed, recorded and replayed (`app"
            " record`, `app replay`) and get a Rust front door (`app"
            " front-door`) that hands everything to the original"
        )
    if lang == "csharp":
        raise Error(
            "bridging C# units into Rust comes next (P/Invoke over a C ABI);"
            " for now a C# app can be analyzed, recorded and replayed (`app"
            " record`, `app replay`) and get a Rust front door (`app"
            " front-door`) that hands everything to the original"
        )
    if lang != "python":
        return fallback(argv)
    return _bridge_python(argv, root, unit, bh)


def _bridge_python(
    argv: List[String], root: String, unit: UnitReport, bh: PythonObject
) raises -> Int:
    var th = tree_helpers()
    var exports = List[ExportedFn]()
    var classes = List[ExportedClass]()
    var js_only = List[JsOnly]()
    for file in unit.files:
        var r = th["python_exports"](
            PythonObject(root + "/" + file), PythonObject(file)
        )
        if String(py=r[0]) != "ok":
            return fallback(argv)
        var fs = r[1]
        for i in range(_len(fs)):
            var f = _function(fs[i])
            var reason = js_only_reason(f)
            if reason:
                js_only.append(JsOnly(f.name, f.file, f.line, reason.value()))
            else:
                exports.append(f^)
        var cs = r[2]
        for i in range(_len(cs)):
            var c = cs[i]
            var methods = List[ExportedFn]()
            var ms = c["methods"]
            for k in range(_len(ms)):
                methods.append(_function(ms[k]))
            var method_reason = Optional[String](None)
            for m in methods:
                var why = js_only_reason(m)
                if why:
                    method_reason = String("`", m.name, "`: ", why.value())
                    break
            var cls = ExportedClass(
                String(py=c["name"]),
                String(py=c["file"]),
                Int(py=c["line"]),
                _params(c["constructor"]),
                methods^,
                _opt(c["blocker"]),
            )
            var why = cls.blocker
            if not why:
                why = method_reason
            if why:
                js_only.append(
                    JsOnly(
                        cls.name, cls.file, cls.line, "class: " + why.value()
                    )
                )
            else:
                classes.append(cls^)
    # Two definitions of one name: sorted by (name, "file:line"), the first
    # adjacent pair.
    var names = List[String]()
    var ats = List[String]()
    for f in exports:
        names.append(f.name)
        ats.append(String(f.file, ":", f.line))
    for c in classes:
        names.append(c.name)
        ats.append(String(c.file, ":", c.line))
    for j in js_only:
        names.append(j.name)
        ats.append(String(j.file, ":", j.line))
    for i in range(1, len(names)):
        var k = i
        while k > 0 and _less(names[k], ats[k], names[k - 1], ats[k - 1]):
            names.swap_elements(k, k - 1)
            ats.swap_elements(k, k - 1)
            k -= 1
    for i in range(1, len(names)):
        if names[i] == names[i - 1]:
            raise Error(
                String(
                    "`",
                    names[i],
                    "` is defined twice in `",
                    unit.id,
                    "` (",
                    ats[i - 1],
                    " and ",
                    ats[i],
                    (
                        "), and the bridge names every export by itself, so one"
                        " would silently replace the other. Bridge the module"
                        " you want on its own (`mojo-anything bridge <root>"
                        " <that file>`), or rename one of them"
                    ),
                )
            )
    if len(exports) == 0 and len(classes) == 0 and len(js_only) > 0:
        var parts = List[String]()
        for j in js_only:
            parts.append(String(j.name, " (", j.reason, ")"))
        raise Error(
            String(
                "every export of `",
                unit.id,
                "` must stay in ",
                lang_name("python"),
                ": ",
                join(parts, ", "),
            )
        )
    if len(exports) == 0 and len(classes) == 0:
        raise Error(
            String(
                "unit `",
                unit.id,
                (
                    "` exports no functions; bridge a unit with an exported"
                    " function API"
                ),
            )
        )
    var crate_name = _crate_name(unit.id)
    var crate_dir = root + "/mojo/" + crate_name
    var cs = String(py=bh["crate_state"](PythonObject(crate_dir)))
    if cs == "other":
        return fallback(argv)
    if cs == "full":
        raise Error(
            String(
                crate_dir,
                (
                    " already exists and is not empty; mojo-anything never"
                    " overwrites a port in progress"
                ),
            )
        )
    var m = Manifest(
        root,
        unit.id,
        "python",
        "mojo-py",
        crate_name,
        exports^,
        classes^,
        js_only^,
    )
    var port = port_mojo(m)
    var api = parse_port_mojo(port)
    match_export_names(m, api)
    var kept_modules = List[String]()
    for c in m.classes:
        kept_modules.append(
            String(
                py=bh["module_path"](PythonObject(root), PythonObject(c.file))
            )
        )
    for j in m.js_only:
        kept_modules.append(
            String(
                py=bh["module_path"](PythonObject(root), PythonObject(j.file))
            )
        )
    var paths = List[String]()
    var texts = List[String]()
    paths.append("port.mojo")
    texts.append(port)
    paths.append("pixi.toml")
    texts.append(pixi_toml(m))
    paths.append(".gitignore")
    texts.append(GITIGNORE)
    paths.append("README.md")
    texts.append(mojo_readme(m))
    paths.append(MANIFEST)
    texts.append(manifest_json(m))
    mojo_py_bindings(m, api, kept_modules, py_num_mojo(), paths, texts)
    var pp = Python.list()
    var pt = Python.list()
    for i in range(len(paths)):
        pp.append(PythonObject(paths[i]))
        pt.append(PythonObject(texts[i]))
    _ = bh["write_files"](PythonObject(crate_dir), pp, pt)
    var exported = List[String]()
    for f in m.exports:
        exported.append(f.name)
    print(
        String(
            "Created ",
            crate_dir,
            " (",
            _kind_debug(m.kind),
            ") for ",
            join(exported, ", "),
        )
    )
    for path in paths:
        print("  " + path)
    print(
        String(
            "- Port each function in port.mojo, then: mojo-anything record ",
            crate_dir,
            " && mojo-anything build ",
            crate_dir,
            " && mojo-anything diff ",
            crate_dir,
        )
    )
    for c in m.classes:
        print(
            String(
                "- Class `",
                c.name,
                "` is not bridged to Mojo yet; it stays in Python.",
            )
        )
    for j in m.js_only:
        print(String("- `", j.name, "` stays in Python: ", j.reason, "."))
    return 0
