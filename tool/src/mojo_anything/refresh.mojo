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
from mojo_anything.bridge import (
    bridge_helpers,
    mojo_ffi_bindings,
    parse_batches,
)
from mojo_anything.cli_parse import Parsed
from mojo_anything.codegen_mojo import (
    Batch,
    MANIFEST,
    SCHEMA,
    is_ascii,
    manifest_json,
    ExportedClass,
    ExportedFn,
    JsOnly,
    Manifest,
    Param,
    join,
    match_export_names,
    parse_port_mojo,
    PortApi,
)
from mojo_anything.codegen_cpp import cpp_bindings
from mojo_anything.codegen_mojo_c import c_bindings, c_manifest_reads_alike
from mojo_anything.codegen_mojo_jvm import mojo_jvm_bindings
from mojo_anything.codegen_mojo_node import mojo_node_bindings
from mojo_anything.codegen_mojo_py import mojo_py_bindings
from mojo_anything.embedded import py_num_mojo
from mojo_anything.fallback import fallback
from mojo_anything.harness_ffi import record_ffi
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
                _opt(p["native_type"]),
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
        _opt(f["native_return"]),
        _opt(f["prototype"]),
        _opt(f["jvm_holder"]),
        Bool(py=f["jvm_constructor"]),
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
    var batches = List[Batch]()
    for i in range(_len(m["batches"])):
        var b = m["batches"][i]
        batches.append(Batch(String(py=b[0]), String(py=b[1])))
    return Manifest(
        String(py=m["root"]),
        String(py=m["unit"]),
        String(py=m["language"]),
        String(py=m["kind"]),
        String(py=m["crate_name"]),
        exports^,
        classes^,
        js_only^,
        batches^,
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


struct Prepared(Movable):
    """What a refresh would write (`paths`, `texts`) and print (`names`),
    found before anything is written; `declined` hands the command to the
    Phase 1 binary instead."""

    var declined: Bool
    var paths: List[String]
    var texts: List[String]
    var names: List[String]
    var gofmt: Bool

    def __init__(out self):
        self.declined = True
        self.paths = List[String]()
        self.texts = List[String]()
        self.names = List[String]()
        self.gofmt = False

    def __init__(
        out self,
        var paths: List[String],
        var texts: List[String],
        var names: List[String],
        gofmt: Bool,
    ):
        self.declined = False
        self.paths = paths^
        self.texts = texts^
        self.names = names^
        self.gofmt = gofmt


def run_refresh(p: Parsed, argv: List[String]) raises -> Int:
    var bh = bridge_helpers()
    var batch = p.all("batch")
    if len(batch) > 0:
        return _add_batches(p.value("CRATE_DIR").or_else("."), batch, argv, bh)
    var l = load(bh, p.value("CRATE_DIR").or_else("."))
    if l.declined:
        return fallback(argv)
    var prep = _prepare(bh, l.crate_dir, l.manifest)
    if prep.declined:
        return fallback(argv)
    _write(bh, l.crate_dir, prep)
    return 0


def _write(bh: PythonObject, crate_dir: String, prep: Prepared) raises:
    """Writes the prepared files (raising the first write's error), runs
    gofmt where the kind needs it, and prints what was regenerated."""
    var pp = Python.list()
    var pt = Python.list()
    for i in range(len(prep.paths)):
        pp.append(PythonObject(prep.paths[i]))
        pt.append(PythonObject(prep.texts[i]))
    var failed = String(py=bh["write_files"](PythonObject(crate_dir), pp, pt))
    if failed.byte_length() > 0:
        raise Error(failed)
    if prep.gofmt:
        _ = bh["gofmt"](PythonObject(crate_dir))
    print(
        String(
            "Regenerated ",
            join(prep.paths, ", "),
            " for ",
            join(prep.names, ", "),
        )
    )


def _add_batches(
    arg: String, specs: List[String], argv: List[String], bh: PythonObject
) raises -> Int:
    """bridge.rs `add_batches`: the manifest gains each batch once (its
    relative root written back as it was), then `refresh`; a refresh that
    fails puts the manifest back as it was. The refresh is prepared from
    the new manifest in memory first, so a decline hands over before
    anything is written."""
    for s in specs:
        if not is_ascii(s):
            return fallback(argv)
    var abs = bh["absolute"](PythonObject(arg))
    if abs is Python.none():
        return fallback(argv)
    # Path::join adds no separator after a trailing slash.
    var crate = String(py=abs)
    var path = crate + MANIFEST if crate.endswith("/") else String(
        crate, "/", MANIFEST
    )
    var before = bh["read_text"](PythonObject(path))
    var bs = String(py=before[0])
    if bs == "missing":
        raise Error(String(path, ": No such file or directory (os error 2)"))
    if bs != "ok":
        return fallback(argv)
    var l = load(bh, arg)
    if l.declined:
        return fallback(argv)
    # The file is written back from the fields Mojo carries: a schema other
    # than the current one, or a float tolerance, goes to the Phase 1 binary.
    if String(py=l.manifest["schema"]) != SCHEMA or Bool(
        py=l.manifest["float_tolerance"]
    ):
        return fallback(argv)
    var m = manifest_from_py(l.manifest)
    for b in parse_batches(specs):
        var known = False
        for k in m.batches:
            if k.function == b.function and k.param == b.param:
                known = True
                break
        if not known:
            m.batches.append(b.copy())
    m.root = String(py=l.manifest["root_written"])
    var text = manifest_json(m)
    # `refresh` loads the manifest just written: read from the text instead.
    var r = bh["parse_manifest"](
        PythonObject(l.crate_dir), PythonObject(path), PythonObject(text)
    )
    var state = String(py=r[0])
    if state == "error":
        raise Error(String(py=r[1]))
    if state != "ok":
        return fallback(argv)
    var prep = _prepare(bh, l.crate_dir, r[1])
    if prep.declined:
        return fallback(argv)
    if not Bool(py=bh["restore"](PythonObject(path), PythonObject(text))):
        # A failed write may have left part of the text: put it back first.
        _ = bh["restore"](PythonObject(path), before[1])
        return fallback(argv)
    try:
        _write(bh, l.crate_dir, prep)
    except e:
        _ = bh["restore"](PythonObject(path), before[1])
        raise e^
    return 0


def _port_text(bh: PythonObject, crate_dir: String) raises -> Optional[String]:
    """port.mojo's text; None declines; raises read_to_string's ENOENT."""
    var port = bh["read_port"](PythonObject(crate_dir))
    var ps = String(py=port[0])
    if ps == "missing":
        raise Error("reading port.mojo: No such file or directory (os error 2)")
    if ps != "ok":
        return None
    return String(py=port[1])


def _fn_names(api: PortApi) -> List[String]:
    var names = List[String]()
    for f in api.functions:
        names.append(f.js_name)
    return names^


def _export_names(m: Manifest) -> List[String]:
    var names = List[String]()
    for f in m.exports:
        names.append(f.name)
    return names^


def _prepare(
    bh: PythonObject, crate_dir: String, manifest: PythonObject
) raises -> Prepared:
    """bridge.rs `refresh` of a loaded manifest, up to the writes."""
    var kind = String(py=manifest["kind"])
    var language = String(py=manifest["language"])
    var cargo = (
        Int(py=bh["exists"](PythonObject(crate_dir + "/Cargo.toml"))) == 1
    )
    var jvm = kind == "mojo-jvm"
    var go_rb = kind == "ffi" and (language == "go" or language == "ruby")
    if (jvm or go_rb) and cargo:
        raise Error(
            String(
                crate_dir,
                (
                    " is a Rust port from before mojo-anything targeted"
                    " Mojo: bridge again to get a Mojo port (port.mojo)"
                ),
            )
        )
    if kind == "ffi" and not go_rb:
        raise Error(
            String(
                "`refresh` has no bindings for a ",
                lang_name(language),
                " unit of kind `ffi`: bridge again",
            )
        )
    var c = kind == "c-abi" and (language == "c" or language == "cpp")
    var node = (kind == "mojo-node" or kind == "mojo-wasm") and language == "ts"
    if not (jvm or go_rb or c or node or kind == "mojo-py"):
        return Prepared()
    var text = _port_text(bh, crate_dir)
    if not text:
        return Prepared()
    var m = manifest_from_py(manifest)
    var paths = List[String]()
    var texts = List[String]()
    if c:
        # c.rs reads the manifest's signatures; the port only says which
        # functions raise.
        if m.language == "c" and not c_manifest_reads_alike(m):
            return Prepared()
        var capi = parse_port_mojo(text.value())
        var signed = Int(py=bh["host"]()[0]) == 1
        if m.language == "cpp":
            cpp_bindings(m, capi, signed, paths, texts)
        else:
            c_bindings(m, capi, signed, paths, texts)
        return Prepared(paths^, texts^, _export_names(m), False)
    var api = parse_port_mojo(text.value())
    match_export_names(m, api)
    if node:
        mojo_node_bindings(m, api, paths, texts)
        return Prepared(paths^, texts^, _export_names(m), False)
    if go_rb:
        if not mojo_ffi_bindings(m, api, paths, texts):
            return Prepared()
        return Prepared(paths^, texts^, _fn_names(api), True)
    if jvm:
        mojo_jvm_bindings(m, api, paths, texts)
        return Prepared(paths^, texts^, _fn_names(api), False)
    if len(api.functions) == 0:
        raise Error("port.mojo has no public `def`: nothing to bind")
    var kept_modules = List[String]()
    for cl in m.classes:
        kept_modules.append(
            String(
                py=bh["module_path"](
                    PythonObject(m.root), PythonObject(cl.file)
                )
            )
        )
    for j in m.js_only:
        kept_modules.append(
            String(
                py=bh["module_path"](PythonObject(m.root), PythonObject(j.file))
            )
        )
    mojo_py_bindings(m, api, kept_modules, py_num_mojo(), paths, texts)
    return Prepared(paths^, texts^, _fn_names(api), False)


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
    if l.declined:
        return fallback(argv)
    var language = String(py=l.manifest["language"])
    var kind = String(py=l.manifest["kind"])
    if (language == "go" or language == "ruby") and kind == "ffi":
        if from_tests:
            return fallback(argv)
        return record_ffi(
            manifest_from_py(l.manifest),
            l.crate_dir,
            p.value("count").or_else("200"),
            p.value("inputs"),
            1 if p.flag("pin-clock") else (2 if p.flag("no-pin-clock") else 0),
            argv,
        )
    # A Python unit of another kind (`ffi`) gets Rust's pinned.rs helper
    # (pin.rs `mojo_unit`), which the Mojo tool does not write.
    if language != "python" or kind != "mojo-py":
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
