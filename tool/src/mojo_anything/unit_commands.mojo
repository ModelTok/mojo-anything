# The commands that start from a unit's manifest and are not ported yet
# (`build`, `diff`, `gate`, `bench`, `fuzz`): what they answer when the
# manifest does not load is answered in Mojo, and a manifest that loads goes
# to the Phase 1 binary before anything is written.
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


def run_unit_command(p: Parsed, argv: List[String]) raises -> Int:
    var path = p.path()
    if path == "fuzz" and p.value("time"):
        return fallback(argv)
    var bh = bridge_helpers()
    var arg = p.value("CRATE_DIR").or_else(".")
    if path != "diff":
        _ = load(bh, arg)
        return fallback(argv)
    try:
        _ = load(bh, arg)
    except:
        var abs = bh["absolute"](PythonObject(arg))
        if abs is Python.none():
            return fallback(argv)
        var crate_dir = String(py=abs)
        var cases = crate_dir + (
            "cases.jsonl" if crate_dir.endswith("/") else "/cases.jsonl"
        )
        var os = Python.import_module("os")
        if not Bool(py=os.path.exists(PythonObject(cases))):
            raise Error(
                String(
                    "no cases.jsonl in ",
                    crate_dir,
                    " (run `mojo-anything record` first)",
                )
            )
    return fallback(argv)
