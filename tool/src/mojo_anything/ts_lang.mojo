# TypeScript and JavaScript for `analyze`: what src/ts/scan.rs and the
# exports and type rules `check_bridgeable` applies read from oxc's AST comes
# from oxc_reader.mjs, run on the project's Node with oxc's own parser at the
# release Cargo.lock pins (tool/oxc, DECISIONS.md F20). Discovery, resolution
# and the planner are Mojo (analyze.mojo, plan.mojo). A file the reader
# declines, a missing or older Node and a missing oxc-parser send the whole
# command to the Phase 1 binary.

from std.python import Python, PythonObject


from mojo_anything.pycache import py_exec
from mojo_anything.embedded import oxc_reader_source
from mojo_anything.fallback import dirname, own_binary
from mojo_anything.python_lang import Facts
from mojo_anything.risks import risk_index

comptime _PY = """
import json, os, shutil, subprocess

OXC_VERSION = "0.158.0"

def ts_package(path):
    # (has_name, name, deps) of a package.json Python's json reads: its
    # string `name`, and the keys of dependencies, peerDependencies,
    # optionalDependencies and devDependencies in that order.
    with open(path, "rb") as f:
        v = json.loads(f.read().decode("utf-8"))
    def keys(field):
        x = v.get(field) if isinstance(v, dict) else None
        return list(x.keys()) if isinstance(x, dict) else []
    name = v.get("name") if isinstance(v, dict) else None
    deps = keys("dependencies") + keys("peerDependencies") + keys("optionalDependencies")
    deps += keys("devDependencies")
    if isinstance(name, str):
        return (1, name, deps)
    return (0, "", deps)

def _node_ok(version):
    # oxc-parser's engines: ^20.19.0 || >=22.12.0.
    try:
        parts = [int(x) for x in version.strip().lstrip("v").split(".")[:2]]
    except ValueError:
        return False
    if len(parts) < 2:
        return False
    major, minor = parts
    return (major == 20 and minor >= 19) or (major == 22 and minor >= 12) or major > 22

def _run(repo, source, request):
    # ("ok", the reader's answer) or ("decline", why).
    oxc = os.path.join(repo, "tool", "oxc", "node_modules", "oxc-parser")
    try:
        with open(os.path.join(oxc, "package.json"), "rb") as f:
            if json.loads(f.read().decode("utf-8")).get("version") != OXC_VERSION:
                return ("decline", "oxc-parser is not " + OXC_VERSION)
    except (OSError, ValueError, AttributeError):
        return ("decline", "no oxc-parser in tool/oxc")
    node = shutil.which("node")
    if node is None:
        return ("decline", "no node")
    # NODE_* and NAPI_RS_* (NAPI_RS_NATIVE_LIBRARY_PATH, NAPI_RS_FORCE_WASI)
    # can change what Node runs or which binding oxc-parser loads.
    env = {k: v for k, v in os.environ.items()
           if not k.startswith("NODE_") and not k.startswith("NAPI_RS_")}
    try:
        v = subprocess.run([node, "--version"], capture_output=True, encoding="utf-8",
                           env=env, stdin=subprocess.DEVNULL, timeout=120)
    except (OSError, subprocess.SubprocessError, ValueError):
        return ("decline", "node does not run")
    if v.returncode != 0 or not _node_ok(v.stdout):
        return ("decline", "node is older than oxc-parser needs")
    request = dict(request, oxc=os.path.join(oxc, "src-js", "index.js"))
    # The source and the answer are UTF-8 whatever the locale says: the
    # source goes as bytes (the locale's codec may not hold it), the answer
    # is decoded as UTF-8 (UnicodeDecodeError is a ValueError).
    try:
        p = subprocess.run([os.fsencode(node), b"--input-type=module", b"-e",
                            source.encode("utf-8")],
                           input=json.dumps(request), capture_output=True, encoding="utf-8",
                           env=env, timeout=1800)
    except (OSError, subprocess.SubprocessError, ValueError):
        return ("decline", "the reader did not run")
    if p.returncode != 0:
        return ("decline", "the reader failed: " + p.stderr[-2000:])
    try:
        answer = json.loads(p.stdout)
    except ValueError:
        return ("decline", "the reader's answer is not JSON")
    if "decline" in answer:
        return ("decline", answer["decline"])
    return ("ok", answer)

def read(repo, source, root, files, packages):
    # ("ok", [per file]) or ("decline", why).
    r = _run(repo, source, {
        "root": root,
        "files": [{"path": p, "parse_as": a, "exports": bool(e)} for p, a, e in files],
        "packages": [[n, d] for n, d in packages],
    })
    if r[0] != "ok":
        return r
    answer = r[1]
    out = []
    for f in answer["files"]:
        if f["status"] != "ok":
            out.append(("unreadable",))
            continue
        bits = 0
        for name, bit in (("node", 1), ("browser", 2), ("editor", 4), ("ui", 8)):
            if name in f["platforms"]:
                bits |= bit
        out.append(("ok", f["loc"], f["parse_errors"], f["imports"],
                    sorted(f["risks"].items()), bits, f["loops"], f["exports"], f["bridgeable"]))
    return ("ok", out)

def bridge(repo, source, root, files, packages, as_json):
    # ("ok", [{classes, functions} per file]) or ("decline", why).
    r = _run(repo, source, {
        "mode": "bridge",
        "root": root,
        "files": list(files),
        "packages": [[n, d] for n, d in packages],
        "as_json": list(as_json),
    })
    if r[0] != "ok":
        return r
    return ("ok", r[1]["files"])
"""


def ts_helpers() raises -> PythonObject:
    var scope = Python.dict()
    py_exec(_PY, scope)
    return scope


def _len(x: PythonObject) raises -> Int:
    return Int(py=Python.import_module("builtins").len(x))


def read_ts_facts(
    th: PythonObject,
    root: String,
    paths: List[String],
    parse_as: List[String],
    exports: List[Bool],
    names: List[String],
    dirs: List[String],
    mut declined: Bool,
) raises -> List[Facts]:
    """The facts of each file (root-relative `paths`, parsed as `parse_as`
    names them), with the exports `check_bridgeable` counts where `exports`
    says so; `declined` is set when the reader declines. `names` and `dirs`
    are the workspace's packages, in its order."""
    var out = List[Facts]()
    var files = Python.list()
    for i in range(len(paths)):
        files.append(
            Python.tuple(
                PythonObject(paths[i]),
                PythonObject(parse_as[i]),
                PythonObject(exports[i]),
            )
        )
    var packages = Python.list()
    for i in range(len(names)):
        packages.append(
            Python.tuple(PythonObject(names[i]), PythonObject(dirs[i]))
        )
    var repo = dirname(dirname(dirname(own_binary())))
    var r = th["read"](
        PythonObject(repo),
        PythonObject(oxc_reader_source()),
        PythonObject(root),
        files,
        packages,
    )
    if String(py=r[0]) != "ok":
        declined = True
        return out^
    var answer = r[1]
    for i in range(_len(answer)):
        var a = answer[i]
        var f = Facts()
        if String(py=a[0]) != "ok":
            out.append(f^)
            continue
        f.readable = True
        f.loc = Int(py=a[1])
        f.parse_errors = Int(py=a[2])
        var imports = a[3]
        for k in range(_len(imports)):
            var imp = imports[k]
            f.specs.append(String(py=imp[0]))
            f.type_only.append(Bool(py=imp[1]))
            f.platform.append(Bool(py=imp[2]))
            f.package.append(String(py=imp[3]))
            var cands = List[String]()
            for c in range(_len(imp[4])):
                cands.append(String(py=imp[4][c]))
            f.aliases.append(cands^)
        var risks = a[4]
        for k in range(_len(risks)):
            var idx = risk_index(String(py=risks[k][0]))
            if idx < 0:
                declined = True
                return out^
            var lines = risks[k][1]
            for j in range(_len(lines)):
                f.risks[idx].append(Int(py=lines[j]))
        f.platforms = Int(py=a[5])
        f.loops = Int(py=a[6])
        f.exports = Int(py=a[7])
        f.bridgeable = Int(py=a[8])
        out.append(f^)
    return out^


def read_ts_bridge(
    root: String,
    files: List[String],
    names: List[String],
    dirs: List[String],
    as_json: List[String],
    mut declined: Bool,
) raises -> PythonObject:
    """For each root-relative file of a unit, its exported classes (name,
    line, blocker, the first constructor or method reason) and functions
    (as exports.rs gives them, the declaration file's types applied,
    aliases and constraints resolved, `--as-json` type parameters made
    `unknown`, with their js_only_reason); `declined` is set when the
    reader declines."""
    var fs = Python.list()
    for f in files:
        fs.append(PythonObject(f))
    var packages = Python.list()
    for i in range(len(names)):
        packages.append(
            Python.tuple(PythonObject(names[i]), PythonObject(dirs[i]))
        )
    var aj = Python.list()
    for a in as_json:
        aj.append(PythonObject(a))
    var repo = dirname(dirname(dirname(own_binary())))
    var r = ts_helpers()["bridge"](
        PythonObject(repo),
        PythonObject(oxc_reader_source()),
        PythonObject(root),
        fs,
        packages,
        aj,
    )
    if String(py=r[0]) != "ok":
        declined = True
        return Python.list()
    return r[1]
