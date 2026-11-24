# `refresh` and the manifest every later step reads (port of src/bridge.rs
# `Manifest::load` and `refresh`, and the `refresh` arm of src/main.rs).
#
# Answered in Mojo: every error `Manifest::load` gives (no manifest, a unit
# bridged with a binding the tool no longer generates, a Rust JNI or C ABI
# crate), the errors of the kinds the Mojo tool does not regenerate yet, and
# the regeneration of a Python unit's bindings (`_native.mojo`, the wrapper
# package and `py_num.mojo`) from the signatures in `port.mojo`. A manifest
# serde_json may read otherwise than Python's json, text outside ASCII,
# `--batch`, and the other kinds go to the Phase 1 binary before anything is
# written.

from std.python import Python, PythonObject

from mojo_anything.analyze import lang_name
from mojo_anything.bridge import bridge_helpers
from mojo_anything.cli_parse import Parsed
from mojo_anything.codegen_mojo import (
    ExportedClass,
    ExportedFn,
    JsOnly,
    Manifest,
    Param,
    join,
    match_export_names,
    parse_port_mojo,
)
from mojo_anything.codegen_mojo_py import mojo_py_bindings
from mojo_anything.embedded import py_num_mojo
from mojo_anything.fallback import fallback
from mojo_anything.harness_py import record_python


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
                Bool(py=p["rest"]),
                _opt(p["default"]),
                Bool(py=p["keyword_only"]),
            )
        )
    return out^


def _function(f: PythonObject) raises -> ExportedFn:
    var tps = List[String]()
    for i in range(_len(f["type_params"])):
        tps.append(String(py=f["type_params"][i]))
    return ExportedFn(
        String(py=f["name"]),
        String(py=f["file"]),
        Int(py=f["line"]),
        _params(f["params"]),
        String(py=f["returns"]),
        Bool(py=f["is_async"]),
        Bool(py=f["is_generator"]),
        tps^,
        Bool(py=f["uses_instanceof"]),
        _opt(f["blocker"]),
    )


def manifest_from_py(m: PythonObject) raises -> Manifest:
    """A manifest `load_manifest` read (the fields the Mojo generators use)."""
    var exports = List[ExportedFn]()
    for i in range(_len(m["exports"])):
        exports.append(_function(m["exports"][i]))
    var classes = List[ExportedClass]()
    for i in range(_len(m["classes"])):
        var c = m["classes"][i]
        var methods = List[ExportedFn]()
        for k in range(_len(c["methods"])):
            methods.append(_function(c["methods"][k]))
        classes.append(
            ExportedClass(
                String(py=c["name"]),
                String(py=c["file"]),
                Int(py=c["line"]),
                _params(c["constructor"]),
                methods^,
                _opt(c["blocker"]),
            )
        )
    var js_only = List[JsOnly]()
    for i in range(_len(m["js_only"])):
        var j = m["js_only"][i]
        js_only.append(
            JsOnly(
                String(py=j["name"]),
                String(py=j["file"]),
                Int(py=j["line"]),
                String(py=j["reason"]),
            )
        )
    return Manifest(
        String(py=m["root"]),
        String(py=m["unit"]),
        String(py=m["language"]),
        String(py=m["kind"]),
        String(py=m["crate_name"]),
        exports^,
        classes^,
        js_only^,
    )


struct Loaded(Movable):
    """What `load` gives: `declined` (the Phase 1 binary answers), or the
    crate folder made absolute and its manifest as Python read it."""

    var declined: Bool
    var crate_dir: String
    var manifest: PythonObject

    def __init__(
        out self, declined: Bool, crate_dir: String, manifest: PythonObject
    ):
        self.declined = declined
        self.crate_dir = crate_dir
        self.manifest = manifest


def load(bh: PythonObject, arg: String) raises -> Loaded:
    """The crate folder as `std::path::absolute` gives it and
    `Manifest::load` of it; raises the errors `load` gives."""
    var abs = bh["absolute"](PythonObject(arg))
    if abs is Python.none():
        return Loaded(True, "", Python.none())
    var crate_dir = String(py=abs)
    var r = bh["load_manifest"](PythonObject(crate_dir))
    var state = String(py=r[0])
    if state == "error":
        raise Error(String(py=r[1]))
    if state != "ok":
        return Loaded(True, crate_dir, Python.none())
    return Loaded(False, crate_dir, r[1])


def run_refresh(p: Parsed, argv: List[String]) raises -> Int:
    if p.value("batch"):
        return fallback(argv)
    var bh = bridge_helpers()
    var l = load(bh, p.value("CRATE_DIR").or_else("."))
    if l.declined:
        return fallback(argv)
    var crate_dir = l.crate_dir
    var kind = String(py=l.manifest["kind"])
    var language = String(py=l.manifest["language"])
    var cargo = (
        Int(py=bh["exists"](PythonObject(crate_dir + "/Cargo.toml"))) == 1
    )
    if kind == "mojo-jvm" or (
        kind == "ffi" and (language == "go" or language == "ruby")
    ):
        if cargo:
            raise Error(
                String(
                    crate_dir,
                    (
                        " is a Rust port from before mojo-anything targeted"
                        " Mojo: bridge again to get a Mojo port (port.mojo)"
                    ),
                )
            )
        return fallback(argv)
    if kind == "ffi":
        raise Error(
            String(
                "`refresh` has no bindings for a ",
                lang_name(language),
                " unit of kind `ffi`: bridge again",
            )
        )
    if kind != "mojo-py":
        return fallback(argv)
    var port = bh["read_port"](PythonObject(crate_dir))
    var ps = String(py=port[0])
    if ps == "missing":
        raise Error("reading port.mojo: No such file or directory (os error 2)")
    if ps != "ok":
        return fallback(argv)
    var m = manifest_from_py(l.manifest)
    var api = parse_port_mojo(String(py=port[1]))
    match_export_names(m, api)
    if len(api.functions) == 0:
        raise Error("port.mojo has no public `def`: nothing to bind")
    var kept_modules = List[String]()
    for c in m.classes:
        kept_modules.append(
            String(
                py=bh["module_path"](PythonObject(m.root), PythonObject(c.file))
            )
        )
    for j in m.js_only:
        kept_modules.append(
            String(
                py=bh["module_path"](PythonObject(m.root), PythonObject(j.file))
            )
        )
    var paths = List[String]()
    var texts = List[String]()
    mojo_py_bindings(m, api, kept_modules, py_num_mojo(), paths, texts)
    var pp = Python.list()
    var pt = Python.list()
    for i in range(len(paths)):
        pp.append(PythonObject(paths[i]))
        pt.append(PythonObject(texts[i]))
    var failed = String(py=bh["write_files"](PythonObject(crate_dir), pp, pt))
    if failed.byte_length() > 0:
        raise Error(failed)
    var names = List[String]()
    for f in api.functions:
        names.append(f.js_name)
    print(String("Regenerated ", join(paths, ", "), " for ", join(names, ", ")))
    return 0


def run_record(p: Parsed, argv: List[String]) raises -> Int:
    """`record`: `Manifest::load`'s errors, and recordings of Python units
    (harness_py.mojo); other languages go to the Phase 1 binary."""
    var from_tests = p.flag("from-tests")
    if len(p.rest) > 0 and not from_tests:
        raise Error(
            "a command after `--` is the test suite for `--from-tests`; add the"
            " flag"
        )
    for name in [
        "module",
        "resolve-from",
        "node-arg",
        "float-tolerance",
    ]:
        if p.value(name):
            return fallback(argv)
    var bh = bridge_helpers()
    var l: Loaded
    try:
        l = load(bh, p.value("CRATE_DIR").or_else("."))
    except e:
        # Rust's `--no-pin-clock` removes pinned.json before it reads the
        # manifest (main.rs); the Phase 1 binary gives that order.
        if p.flag("no-pin-clock") and not from_tests:
            return fallback(argv)
        raise e^
    # A Python unit of another kind (`ffi`) gets Rust's pinned.rs helper
    # (pin.rs `mojo_unit`), which the Mojo tool does not write.
    if (
        l.declined
        or String(py=l.manifest["language"]) != "python"
        or String(py=l.manifest["kind"]) != "mojo-py"
    ):
        return fallback(argv)
    return record_python(
        manifest_from_py(l.manifest),
        l.crate_dir,
        p.value("count").or_else("200"),
        p.value("inputs"),
        1 if p.flag("pin-clock") else (2 if p.flag("no-pin-clock") else 0),
        from_tests,
        p.rest,
        argv,
    )
