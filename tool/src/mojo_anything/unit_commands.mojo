# The commands that start from a unit's manifest (`build`, `diff`, `gate`,
# `bench`, `fuzz`): what they answer when the manifest does not load is
# answered here; `build` and `diff` of a Python unit go to unit_python.mojo,
# and every other loaded manifest goes to the Phase 1 binary before anything
# is written.
#
# src/harness.rs `build` and `bench`, src/gate.rs `gate` and src/fuzz.rs
# `fuzz` give `Manifest::load`'s error first (main.rs checks `fuzz --time`
# before it). `diff` ignores that error (jvm.rs `require_java_for`, and each
# language's arm of harness.rs `diff_exact`) and reaches `node_diff`, whose
# first check is the recording: no `cases.jsonl` is an error, a recording
# goes to the Phase 1 binary.

from std.python import Python, PythonObject

from mojo_anything.bridge import bridge_helpers
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback
from mojo_anything.refresh import load
from mojo_anything.unit_python import build_python, diff_python


def _ffi_without_build(language: String) -> Optional[String]:
    """harness.rs `build`'s error for an `ffi` unit of a language with no
    `ffi` build (Go and Ruby build; Java and Kotlin fail to load)."""
    var name: String
    if language == "ts":
        name = "TypeScript/JavaScript"
    elif language == "python":
        name = "Python"
    elif language == "c":
        name = "C"
    elif language == "cpp":
        name = "C++"
    elif language == "php":
        name = "PHP"
    elif language == "csharp":
        name = "C#"
    else:
        return None
    return String("no build for a ", name, " unit of kind `ffi`: bridge again")


def run_unit_command(p: Parsed, argv: List[String]) raises -> Int:
    var path = p.path()
    if path == "fuzz" and p.value("time"):
        return fallback(argv)
    var bh = bridge_helpers()
    var arg = p.value("CRATE_DIR").or_else(".")
    if path == "build":
        var l = load(bh, arg)
        if l.declined:
            return fallback(argv)
        var language = String(py=l.manifest["language"])
        var kind = String(py=l.manifest["kind"])
        if kind == "ffi":
            var why = _ffi_without_build(language)
            if why:
                raise Error(why.value())
        if language == "python" and kind == "mojo-py":
            return build_python(l.crate_dir, l.manifest, argv)
        return fallback(argv)
    if path != "diff":
        _ = load(bh, arg)
        return fallback(argv)
    var loaded = False
    var declined = True
    var crate_dir = String("")
    var manifest = Python.none()
    try:
        var l = load(bh, arg)
        loaded = True
        declined = l.declined
        crate_dir = l.crate_dir
        manifest = l.manifest
    except:
        var abs = bh["absolute"](PythonObject(arg))
        if abs is Python.none():
            return fallback(argv)
        var dir = String(py=abs)
        var cases = dir + (
            "cases.jsonl" if dir.endswith("/") else "/cases.jsonl"
        )
        var os = Python.import_module("os")
        if not Bool(py=os.path.exists(PythonObject(cases))):
            raise Error(
                String(
                    "no cases.jsonl in ",
                    dir,
                    " (run `mojo-anything record` first)",
                )
            )
    if (
        loaded
        and not declined
        and String(py=manifest["language"]) == "python"
        and not p.value("module")
    ):
        return diff_python(
            crate_dir,
            manifest,
            p.flag("ignore-key-order"),
            p.value("float-tolerance"),
            p.flag("json"),
            argv,
        )
    return fallback(argv)
