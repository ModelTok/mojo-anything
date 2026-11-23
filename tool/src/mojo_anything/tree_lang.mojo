# The languages the Rust tool reads with tree-sitter grammars, for `analyze`:
# what a file holds comes from analyze_tree.py through tree-sitter's Python
# bindings (the same grammar versions as Cargo.lock's); the bridge rules
# applied to its exports (bridge::js_only_reason with no local types) are
# Mojo. A file whose tree has an error sends the whole command to the Phase 1
# binary.

from std.python import Python, PythonObject

from mojo_anything.embedded import analyze_tree_source
from mojo_anything.fallback import dirname, own_binary
from mojo_anything.python_lang import Facts, js_shaped
from mojo_anything.risks import risk_index


def tree_helpers() raises -> PythonObject:
    """analyze_tree.py, with tree-sitter's bindings on the path when this
    interpreter or the repository's pixi environment has them (the binary is
    tool/build/mojo-anything in the repository); without them every file
    declines."""
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(analyze_tree_source(), scope)
    var repo = dirname(dirname(dirname(own_binary())))
    _ = scope["find_bindings"](PythonObject(repo))
    return scope


def _len(x: PythonObject) raises -> Int:
    return Int(py=Python.import_module("builtins").len(x))


def read_tree_facts(
    th: PythonObject, lang: String, path: String, mut declined: Bool
) raises -> Facts:
    """The facts of the file at `path`; `declined` is set when its tree has
    an error."""
    var out = Facts()
    var r = th["read_file"](PythonObject(lang), PythonObject(path))
    var status = String(py=r[0])
    if status == "unreadable":
        return out^
    if status != "ok":
        declined = True
        return out^
    out.readable = True
    out.loc = Int(py=r[1])
    var imports = r[2]
    for i in range(_len(imports)):
        out.specs.append(String(py=imports[i]))
        out.type_only.append(False)
    var risks = r[3]
    for i in range(_len(risks)):
        var k = risk_index(String(py=risks[i][0]))
        if k < 0:
            declined = True
            return out^
        var lines = risks[i][1]
        for j in range(_len(lines)):
            out.risks[k].append(Int(py=lines[j]))
    out.loops = Int(py=r[4])
    var exports = r[5]
    for i in range(_len(exports)):
        out.exports += 1
        var types = List[String]()
        var given = exports[i][1]
        for j in range(_len(given)):
            types.append(String(py=given[j]))
        if not Bool(py=exports[i][0]) and not js_shaped(types):
            out.bridgeable += 1
    return out^
