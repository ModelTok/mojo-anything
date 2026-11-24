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
    c_type_rels,
    cpp_type_rels,
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
from mojo_anything.codegen_mojo_c import BUILD_DIR, c_bindings, port_mojo_c
from mojo_anything.codegen_cpp import WRAPPER, cpp_bindings, port_mojo_cpp
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
import json, os

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

def _io(e):
    # io::Error's Display: strerror and the errno.
    return "%s (os error %d)" % (os.strerror(e.errno), e.errno)

def _create_dir_all(path):
    # std::fs::create_dir_all.
    if path == "":
        return
    try:
        os.mkdir(path)
        return
    except FileNotFoundError:
        pass
    except OSError:
        if os.path.isdir(path):
            return
        raise
    parent = os.path.dirname(path)
    if parent == path:
        raise OSError(0, "failed to create whole tree")
    _create_dir_all(parent)
    try:
        os.mkdir(path)
    except OSError:
        if not os.path.isdir(path):
            raise

def write_files(base, paths, texts):
    # bridge.rs `write_files`: "" when every file was written, else the
    # error it stops with (create_dir_all's bare, fs::write's with the path).
    for rel, text in zip(paths, texts):
        target = os.path.join(base, rel)
        try:
            _create_dir_all(os.path.dirname(target))
        except OSError as e:
            if not e.errno:
                return "failed to create whole tree"
            return _io(e)
        try:
            with open(target, "w", encoding="utf-8", newline="") as f:
                f.write(text)
        except OSError as e:
            return "writing %s: %s" % (target, _io(e))
    return ""

def absolute(arg):
    # std::path::absolute on Unix: `.` components dropped, `..` kept, a
    # trailing slash kept; None for an empty path (clap refuses it).
    if arg == "":
        return None
    parts = [p for p in arg.split("/") if p not in ("", ".")]
    if arg.startswith("/"):
        base = "//" if arg.startswith("//") and not arg.startswith("///") else "/"
    else:
        base = os.getcwd()
    out = base
    for p in parts:
        out = out + p if out.endswith("/") else out + "/" + p
    if arg.endswith("/") and not out.endswith("/"):
        out += "/"
    return out

_LANGS = ("ts", "python", "c", "go", "ruby", "java", "kotlin", "php", "csharp", "cpp")
_KINDS = ("c-abi", "ffi", "mojo-py", "mojo-node", "mojo-wasm", "mojo-jvm")

class _Bad(Exception):
    pass

def _pairs(pairs):
    out = {}
    for k, v in pairs:
        if k in out:
            raise _Bad("duplicate field")
        out[k] = v
    return out

def _const(name):
    raise _Bad(name)

def _float(text):
    # serde_json refuses a number that overflows f64 (out of range).
    v = float(text)
    if v in (float("inf"), float("-inf")):
        raise _Bad("out of range")
    return v

def _int(text):
    # serde_json reads `-0` as the float -0.0, and an integer beyond u64 or
    # i64 as f64 (out of range past f64's largest).
    if text == "-0":
        raise _Bad("-0")
    v = int(text)
    if v >= 2**64 or v < -(2**63):
        return _float(text)
    return v

def _is(v, t):
    return type(v) is t

def _str(d, k, required=True):
    if k not in d:
        if required:
            raise _Bad(k)
        return None
    if not _is(d[k], str):
        raise _Bad(k)
    return d[k]

def _opt_str(d, k):
    v = d.get(k)
    if v is not None and not _is(v, str):
        raise _Bad(k)
    return v

def _flag(d, k, required):
    if k not in d:
        if required:
            raise _Bad(k)
        return False
    if not _is(d[k], bool):
        raise _Bad(k)
    return d[k]

def _u32(d, k):
    v = d.get(k)
    if not _is(v, int) or v < 0 or v > 4294967295:
        raise _Bad(k)
    return v

def _list(d, k, required):
    if k not in d:
        if required:
            raise _Bad(k)
        return []
    if not _is(d[k], list):
        raise _Bad(k)
    return d[k]

def _obj(v):
    if not _is(v, dict):
        raise _Bad("not an object")
    return v

def _param(p):
    p = _obj(p)
    return {
        "name": _str(p, "name"),
        "ts_type": _str(p, "ts_type"),
        "optional": _flag(p, "optional", True),
        "rest": _flag(p, "rest", True),
        "default": _opt_str(p, "default"),
        "keyword_only": _flag(p, "keyword_only", False),
        "native_type": _opt_str(p, "native_type"),
    }

def _function(f):
    f = _obj(f)
    tps = _list(f, "type_params", False)
    if not all(_is(t, str) for t in tps):
        raise _Bad("type_params")
    if f.get("jvm_holder") is not None:
        raise _Bad("jvm_holder")
    return {
        "name": _str(f, "name"),
        "file": _str(f, "file"),
        "line": _u32(f, "line"),
        "params": [_param(p) for p in _list(f, "params", True)],
        "returns": _str(f, "returns"),
        "is_async": _flag(f, "is_async", True),
        "is_generator": _flag(f, "is_generator", False),
        "type_params": tps,
        "uses_instanceof": _flag(f, "uses_instanceof", False),
        "blocker": _opt_str(f, "blocker"),
        "native_return": _opt_str(f, "native_return"),
        "prototype": _opt_str(f, "prototype"),
        "jvm_constructor": _flag(f, "jvm_constructor", False),
    }

def _class(c):
    c = _obj(c)
    return {
        "name": _str(c, "name"),
        "file": _str(c, "file"),
        "line": _u32(c, "line"),
        "constructor": [_param(p) for p in _list(c, "constructor", True)],
        "methods": [_function(m) for m in _list(c, "methods", True)],
        "blocker": _opt_str(c, "blocker"),
    }

def _js_only(j):
    j = _obj(j)
    return {"name": _str(j, "name"), "file": _str(j, "file"), "line": _u32(j, "line"), "reason": _str(j, "reason")}

def _ascii_all(v):
    if isinstance(v, str):
        return v.isascii()
    if isinstance(v, dict):
        return all(_ascii_all(x) for x in v.values())
    if isinstance(v, list):
        return all(_ascii_all(x) for x in v)
    return True

def load_manifest(crate_dir):
    # bridge::Manifest::load: ("ok", manifest dict, path), ("error", message)
    # for the errors it gives that the Mojo tool reproduces, ("decline",)
    # for the rest (a file serde_json may read otherwise than json, text
    # outside ASCII, an io error other than ENOENT, batches).
    path = os.path.join(crate_dir, "mojo-anything.json")
    old = os.path.join(crate_dir, "rust-anything.json")
    if not os.path.exists(path) and os.path.exists(old):
        path = old
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return ("error", "reading %s (run `mojo-anything bridge` first): No such file or directory (os error 2)" % path)
    except OSError:
        return ("decline",)
    try:
        text = data.decode("utf-8")
    except UnicodeError:
        return ("decline",)
    if not text.isascii() or "\\\\u" in text or len(text) > 50000000:
        return ("decline",)
    depth = 0
    for c in text:
        if c in "[{":
            depth += 1
            if depth > 100:
                return ("decline",)
        elif c in "]}":
            depth -= 1
    try:
        top = json.loads(
            text, object_pairs_hook=_pairs, parse_constant=_const, parse_float=_float, parse_int=_int
        )
    except (ValueError, _Bad, RecursionError):
        return ("decline",)
    if not _is(top, dict):
        return ("decline",)
    kind = top.get("kind")
    olds = {"pyo3": "PyO3", "napi": "napi-rs", "wasm": "wasm-bindgen"}
    if _is(kind, str) and kind in olds:
        return ("error", "%s was bridged with %s, which mojo-anything no longer generates: run bridge again to port the unit to Mojo" % (path, olds[kind]))
    try:
        language = _str(top, "language", False) or "ts"
        if "language" in top and top["language"] not in _LANGS:
            raise _Bad("language")
        if kind not in _KINDS:
            raise _Bad("kind")
        m = {
            "schema": _str(top, "schema"),
            "root": _str(top, "root"),
            "unit": _str(top, "unit"),
            "language": language,
            "kind": kind,
            "crate_name": _str(top, "crate_name"),
            "exports": [_function(f) for f in _list(top, "exports", True)],
            "classes": [_class(c) for c in _list(top, "classes", False)],
            "js_only": [_js_only(j) for j in _list(top, "js_only", False)],
        }
        if _list(top, "batches", False):
            raise _Bad("batches")
        ft = top.get("float_tolerance")
        if ft is not None and not (_is(ft, float) or _is(ft, int)):
            raise _Bad("float_tolerance")
    except _Bad:
        return ("decline",)
    if not _ascii_all(m):
        return ("decline",)
    if kind == "ffi" and language in ("java", "kotlin"):
        return ("error", "%s is a Rust JNI crate, which mojo-anything no longer generates: run bridge again to port the unit to Mojo (Java's Foreign Function & Memory API, Java 22+)" % crate_dir)
    if kind == "c-abi" and os.path.exists(os.path.join(crate_dir, "Cargo.toml")):
        return ("error", "%s is a Rust C ABI crate, which mojo-anything no longer generates: run bridge again to port the unit to Mojo" % crate_dir)
    root = m["root"]
    if not root.startswith("/"):
        resolved = os.path.join(crate_dir, root)
        try:
            os.stat(resolved)
            resolved = os.path.realpath(resolved)
        except OSError:
            pass
        m["root"] = resolved
    return ("ok", m, path)

def read_port(crate_dir):
    # ("ok", text), ("missing",) on ENOENT, ("decline",) otherwise (an io
    # error, not UTF-8, text outside ASCII).
    try:
        with open(os.path.join(crate_dir, "port.mojo"), "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return ("missing",)
    except OSError:
        return ("decline",)
    if not data.isascii():
        return ("decline",)
    return ("ok", data.decode("ascii"))

def host():
    # (plain char is signed, the shared library's extension): c.rs
    # plain_char_is_signed and harness_mojo_c's `library_name`, for this host.
    import platform, sys
    m = platform.machine().lower()
    unsigned = sys.platform.startswith("linux") and m.startswith(
        ("aarch64", "arm", "ppc", "powerpc", "riscv", "s390")
    )
    return (0 if unsigned else 1, "dylib" if sys.platform == "darwin" else "so")

def readable(root, files):
    # 1 when every file reads as UTF-8 (read_to_string succeeds).
    for rel in files:
        try:
            with open(os.path.join(root, rel), "rb") as f:
                f.read().decode("utf-8")
        except (OSError, UnicodeError):
            return 0
    return 1
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
                None,
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
        None,
        None,
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
    if lang == "c":
        return _bridge_c(argv, root, unit, bh)
    if lang == "cpp":
        return _bridge_cpp(argv, root, unit, bh)
    if lang == "go" or lang == "ruby":
        # A unit `analyze` counted no exports in (functions and classes,
        # read by the same tree-sitter readers bridge's `lang::exports`
        # uses) has none to bridge, when every file of it reads as UTF-8
        # (an unreadable file is skipped by analyze, an error in bridge).
        # A unit with exports is not ported yet.
        var files = Python.list()
        for f in unit.files:
            files.append(PythonObject(f))
        if (
            unit.exports == 0
            and unit.status != KEEP
            and unit.status != BLOCKED
            and Int(py=bh["readable"](PythonObject(root), files)) == 1
        ):
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
        return fallback(argv)
    if lang != "python":
        return fallback(argv)
    return _bridge_python(argv, root, unit, bh)


def _check_defined(
    unit: UnitReport,
    lang: String,
    exports: List[ExportedFn],
    classes: List[ExportedClass],
    js_only: List[JsOnly],
) raises:
    """bridge.rs: two definitions of one name, and a unit with nothing
    to bridge."""
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
                lang_name(lang),
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
    _check_defined(unit, "python", exports, classes, js_only)
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
    var failed = String(py=bh["write_files"](PythonObject(crate_dir), pp, pt))
    if failed.byte_length() > 0:
        raise Error(failed)
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


def _c_function(f: PythonObject) raises -> ExportedFn:
    var params = List[Param]()
    var ps = f["params"]
    for i in range(_len(ps)):
        var p = ps[i]
        params.append(
            Param(
                String(py=p["name"]),
                String(py=p["ts_type"]),
                False,
                False,
                None,
                False,
                _opt(p["native_type"]),
            )
        )
    return ExportedFn(
        String(py=f["name"]),
        String(py=f["file"]),
        Int(py=f["line"]),
        params^,
        String(py=f["returns"]),
        False,
        False,
        List[String](),
        False,
        _opt(f["blocker"]),
        _opt(f["native_return"]),
        _opt(f["prototype"]),
    )


def readme(m: Manifest) -> String:
    """Bridge.rs `readme`: every kind but `mojo-py`'s."""
    var kind = String("the C ABI")
    if m.kind == "c-abi" and m.language == "cpp":
        kind = (
            "a C ABI shim (`cpp/shim.cpp`) and a C++ wrapper with the original"
            " signatures (`cpp/wrapper.cpp`)"
        )
    elif m.kind == "ffi":
        kind = "a JSON dispatcher"
    elif m.kind == "mojo-node":
        kind = "a Node-API addon over the JSON dispatcher"
    elif m.kind == "mojo-wasm":
        kind = "a WebAssembly module of the JSON dispatcher"
    elif m.kind == "mojo-jvm":
        kind = "Java's Foreign Function & Memory API over the JSON dispatcher"
    var functions = String("")
    for f in m.exports:
        functions += String("- `", f.name, "` (`", f.file, ":", f.line, "`)\n")
    return String(
        "# ",
        m.crate_name,
        "\n\nMojo port of `",
        m.unit,
        "`, bridged with ",
        kind,
        ". Generated by mojo-anything.\n\n## Functions\n\n",
        functions,
        "\n## Loop\n\n```sh\nmojo-anything record .   # record what the",
        " original does\nmojo-anything build .    # build ",
        kind,
        "\nmojo-anything diff .     # run the recorded cases against the",
        " port\nmojo-anything shadow .   # run both in the app, log",
        " mismatches\nmojo-anything gate .     # format, lint, tests, unsafe,",
        " API, diff\n```\n",
    )


def _free_crate_dir(crate_dir: String, bh: PythonObject) raises -> Bool:
    """False when the crate folder is declined (not a folder, a link,
    unreadable); raises bridge's error when it holds entries."""
    var cs = String(py=bh["crate_state"](PythonObject(crate_dir)))
    if cs == "other":
        return False
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
    return True


def _write(
    crate_dir: String,
    paths: List[String],
    texts: List[String],
    bh: PythonObject,
) raises:
    var pp = Python.list()
    var pt = Python.list()
    for i in range(len(paths)):
        pp.append(PythonObject(paths[i]))
        pt.append(PythonObject(texts[i]))
    var failed = String(py=bh["write_files"](PythonObject(crate_dir), pp, pt))
    if failed.byte_length() > 0:
        raise Error(failed)


def _outcome(
    crate_dir: String,
    kind: String,
    paths: List[String],
    m: Manifest,
    notes: List[String],
):
    """Main.rs's report of a bridge Outcome."""
    var exported = List[String]()
    for f in m.exports:
        exported.append(f.name)
    print(
        String(
            "Created ",
            crate_dir,
            " (",
            _kind_debug(kind),
            ") for ",
            join(exported, ", "),
        )
    )
    for path in paths:
        print("  " + path)
    for n in notes:
        print("- " + n)


def _bridge_c(
    argv: List[String], root: String, unit: UnitReport, bh: PythonObject
) raises -> Int:
    """Bridge.rs `bridge` for a C unit (`bridge_c`, `c_bindings`)."""
    var th = tree_helpers()
    if Int(py=th["c_use_types"](PythonObject(root), c_type_rels(root))) != 1:
        return fallback(argv)
    var files = Python.list()
    for f in unit.files:
        files.append(PythonObject(f))
    var r = th["c_bridge_exports"](PythonObject(root), files)
    if String(py=r[0]) != "ok":
        return fallback(argv)
    var exports = List[ExportedFn]()
    var classes = List[ExportedClass]()
    var js_only = List[JsOnly]()
    var fs = r[1]
    for i in range(_len(fs)):
        var f = _c_function(fs[i])
        var reason = js_only_reason(f)
        if reason:
            js_only.append(JsOnly(f.name, f.file, f.line, reason.value()))
        else:
            exports.append(f^)
    _check_defined(unit, "c", exports, classes, js_only)
    var crate_name = _crate_name(unit.id)
    var crate_dir = root + "/mojo/" + crate_name
    if not _free_crate_dir(crate_dir, bh):
        return fallback(argv)
    var host = bh["host"]()
    var signed = Int(py=host[0]) == 1
    var ext = String(py=host[1])
    var m = Manifest(
        root,
        unit.id,
        "c",
        "c-abi",
        crate_name,
        exports^,
        classes^,
        js_only^,
    )
    # Everything is generated before anything is written.
    var port = port_mojo_c(m, signed)
    var api = parse_port_mojo(port)
    var paths = List[String]()
    var texts = List[String]()
    paths.append("port.mojo")
    texts.append(port)
    paths.append("pixi.toml")
    texts.append(pixi_toml(m))
    paths.append(".gitignore")
    texts.append(".mojo-anything/\n.pixi/\n")
    paths.append("README.md")
    texts.append(readme(m))
    paths.append(MANIFEST)
    texts.append(manifest_json(m))
    c_bindings(m, api, signed, paths, texts)
    _write(crate_dir, paths, texts, bh)
    var notes = List[String]()
    notes.append(
        String(
            "Port each function in port.mojo, then: mojo-anything record ",
            crate_dir,
            " && mojo-anything build ",
            crate_dir,
            " && mojo-anything diff ",
            crate_dir,
        )
    )
    notes.append(
        String(
            "Link ",
            BUILD_DIR,
            "/lib",
            m.lib_name(),
            ".",
            ext,
            " instead of the C objects; include/",
            m.lib_name(),
            ".h has the prototypes.",
        )
    )
    notes.append(
        "The library is not self-contained yet: once it uses the Mojo standard"
        " library it needs libKGENCompilerRTShared (.so, or .dylib on macOS)"
        " from the unit's .pixi/envs/default/lib, and it finds it there through"
        " an absolute RUNPATH. Ship that file beside it (and set the runpath"
        " to $ORIGIN) before linking it into a program that runs elsewhere."
    )
    for j in m.js_only:
        notes.append(String("`", j.name, "` stays in C: ", j.reason, "."))
    _outcome(crate_dir, m.kind, paths, m, notes)
    return 0


def _bridge_cpp(
    argv: List[String], root: String, unit: UnitReport, bh: PythonObject
) raises -> Int:
    """Bridge.rs `bridge` for a C++ unit (`bridge_cpp`, codegen_cpp
    `bindings`)."""
    var th = tree_helpers()
    if (
        Int(py=th["cpp_use_types"](PythonObject(root), cpp_type_rels(root)))
        != 1
    ):
        return fallback(argv)
    var files = Python.list()
    for f in unit.files:
        files.append(PythonObject(f))
    var r = th["cpp_bridge_exports"](PythonObject(root), files)
    if String(py=r[0]) != "ok":
        return fallback(argv)
    var exports = List[ExportedFn]()
    var classes = List[ExportedClass]()
    var js_only = List[JsOnly]()
    var items = r[1]
    for i in range(_len(items)):
        var item = items[i]
        if Bool(py=item["is_class"]):
            # A C++ class always carries its refusal.
            js_only.append(
                JsOnly(
                    String(py=item["name"]),
                    String(py=item["file"]),
                    Int(py=item["line"]),
                    "class: " + String(py=item["blocker"]),
                )
            )
            continue
        var f = _c_function(item)
        var reason = js_only_reason(f)
        if reason:
            js_only.append(JsOnly(f.name, f.file, f.line, reason.value()))
        else:
            exports.append(f^)
    _check_defined(unit, "cpp", exports, classes, js_only)
    var crate_name = _crate_name(unit.id)
    var crate_dir = root + "/mojo/" + crate_name
    if not _free_crate_dir(crate_dir, bh):
        return fallback(argv)
    var host = bh["host"]()
    var signed = Int(py=host[0]) == 1
    var ext = String(py=host[1])
    var m = Manifest(
        root,
        unit.id,
        "cpp",
        "c-abi",
        crate_name,
        exports^,
        classes^,
        js_only^,
    )
    # Everything is generated before anything is written.
    var port = port_mojo_cpp(m, signed)
    var api = parse_port_mojo(port)
    var paths = List[String]()
    var texts = List[String]()
    paths.append("port.mojo")
    texts.append(port)
    paths.append("pixi.toml")
    texts.append(pixi_toml(m))
    paths.append(".gitignore")
    texts.append(".mojo-anything/\n.pixi/\n")
    paths.append("README.md")
    texts.append(readme(m))
    paths.append(MANIFEST)
    texts.append(manifest_json(m))
    cpp_bindings(m, api, signed, paths, texts)
    _write(crate_dir, paths, texts, bh)
    var notes = List[String]()
    notes.append(
        String(
            "Port each function in port.mojo, then: mojo-anything record ",
            crate_dir,
            " && mojo-anything build ",
            crate_dir,
            " && mojo-anything diff ",
            crate_dir,
        )
    )
    notes.append(
        String(
            "C++ callers keep the original header: compile ",
            WRAPPER,
            " and link ",
            BUILD_DIR,
            "/lib",
            m.lib_name(),
            ".",
            ext,
            " instead of ",
            m.unit,
            ". The wrapper replaces only the bridged functions of ",
            m.unit,
            (
                ", so move its other definitions into a file of their own that"
                " stays in the build (`gate`'s `cpp api` names any left"
                " behind)."
            ),
        )
    )
    notes.append(
        "The library is not self-contained yet: once it uses the Mojo standard"
        " library it needs libKGENCompilerRTShared (.so, or .dylib on macOS)"
        " from the unit's .pixi/envs/default/lib, and it finds it there through"
        " an absolute RUNPATH. Ship that file beside it (and set the runpath"
        " to $ORIGIN) before linking it into a program that runs elsewhere."
    )
    for j in m.js_only:
        var reason = j.reason
        if j.reason.startswith("class: "):
            reason = String(j.reason[byte=7:])
        notes.append(String("`", j.name, "` stays in C++: ", reason, "."))
    _outcome(crate_dir, m.kind, paths, m, notes)
    return 0
