# The Node side of a TS/JS unit ported to Mojo (src/codegen_mojo_node.rs):
# the Node-API addon in C that forwards `call(name, argsJson)` to the Mojo
# library's JSON dispatcher, its `binding.gyp`, and the `index.cjs` that
# keeps the original API, the JS value markers and the JS error classes. The
# fixed texts are the Rust tool's own (tool/embedded.py).

from mojo_anything.codegen_mojo import Manifest, PortApi, join
from mojo_anything.codegen_ffi import DISPATCHER, dispatcher_mojo
from mojo_anything.codegen_mojo_py import unit_pixi_toml
from mojo_anything.embedded import (
    js_batch,
    js_call,
    js_codec,
    js_wasm,
    json_mojo,
    node_shim,
)


def node_shim_c(m: Manifest) -> String:
    """The addon source of a unit: it loads `lib<lib>.so` (`.dylib` on
    macOS) from its own folder."""
    return node_shim().replace("@LIB@", m.lib_name())


def binding_gyp(m: Manifest) -> String:
    """A `binding.gyp` for building the addon with node-gyp."""
    return String(
        '{\n  "targets": [\n    {\n      "target_name": "',
        m.lib_name(),
        (
            '",\n      "sources": ["node_shim.c"],\n      "libraries":'
            ' ["-ldl"]\n    }\n  ]\n}\n'
        ),
    )


def _is_space(b: UInt8) -> Bool:
    # char::is_whitespace on the ASCII types the port reader gives.
    return b == 32 or (b >= 9 and b <= 13)


def _holds_string(t: String) -> Bool:
    """`String` inside any nesting of `Optional[...]` and `List[...]`."""
    var compact = String("")
    for b in t.as_bytes():
        if not _is_space(b):
            compact += chr(Int(b))
    var inner = compact^
    while True:
        var rest: String
        if inner.startswith("Optional["):
            rest = String(inner[byte=9:])
        elif inner.startswith("List["):
            rest = String(inner[byte=5:])
        else:
            break
        if not rest.endswith("]"):
            break
        inner = String(rest[byte = 0 : rest.byte_length() - 1])
    return inner == "String"


def _bool(b: Bool) -> String:
    if b:
        return "true"
    return "false"


def pascal(name: String) -> String:
    """codegen_batch.rs `pascal`: `fuzzy_score` and `fuzzyScore` give
    `FuzzyScore` (the names are ASCII here)."""
    var out = String("")
    var up = True
    for b in name.as_bytes():
        if b == UInt8(ord("_")) or b == UInt8(ord("-")):
            up = True
        elif up:
            out += String(chr(Int(b))).upper()
            up = False
        else:
            out += chr(Int(b))
    return out


def _item_kind(mojo: String) -> String:
    """The JS `typeof` a batch item of this Mojo type must have, or ""."""
    var t = String(mojo.strip())
    if (
        t == "Float64"
        or t == "Float32"
        or t == "Int"
        or t == "Int64"
        or t == "Int32"
        or t == "UInt64"
        or t == "UInt32"
    ):
        return "number"
    if t == "String":
        return "string"
    if t == "Bool":
        return "boolean"
    return ""


def index_cjs_mojo(m: Manifest, api: PortApi) -> String:
    """`index.cjs` of a `mojo-node` or `mojo-wasm` unit: each export encodes
    its arguments with the JS codec, calls the dispatcher through the addon
    or the module and decodes the answer; each `--batch` adds a batch
    class."""
    var ports = List[String]()
    for f in api.functions:
        var is_async = False
        var rest = -1
        for e in m.exports:
            if e.name == f.js_name:
                is_async = e.is_async
                for i in range(len(e.params)):
                    if e.params[i].rest:
                        rest = i
                        break
                break
        var strings = List[String]()
        for i in range(len(f.param_types)):
            if _holds_string(f.param_types[i]):
                strings.append(String(i))
        ports.append(
            String(
                "  ",
                f.js_name,
                ": [",
                _bool(is_async),
                ", [",
                join(strings, ", "),
                "], ",
                len(f.param_types),
                ", ",
                rest,
                "],",
            )
        )
    var batches = List[String]()
    for b in m.batches:
        var fi = -1
        for i in range(len(api.functions)):
            if api.functions[i].js_name == b.function:
                fi = i
                break
        if fi < 0:
            continue
        var at = -1
        for e in m.exports:
            if e.name == b.function:
                for i in range(len(e.params)):
                    if e.params[i].name == b.param:
                        at = i
                        break
                break
        if at < 0 or at >= len(api.functions[fi].param_types):
            continue
        batches.append(
            String(
                "  ",
                pascal(api.functions[fi].js_name),
                "Batch: ['",
                api.functions[fi].js_name,
                "', ",
                at,
                ", ",
                len(api.functions[fi].param_types),
                ", '",
                _item_kind(api.functions[fi].param_types[at]),
                "', ",
                _bool(_item_kind(api.functions[fi].ret) == "number"),
                "],",
            )
        )
    var batch_js = String("")
    if len(batches) > 0:
        batch_js = String(
            "// Batches: [function, item position, parameter count, item type,",
            " numeric results].\nconst batches = {\n",
            join(batches, "\n"),
            "\n}\n",
            js_batch(),
        )
    var over: String
    var native: String
    if m.kind == "mojo-wasm":
        over = "WebAssembly module"
        native = js_wasm().replace("@LIB@", m.lib_name())
    else:
        over = "Node-API\n// addon"
        native = String("const native = require('./", m.lib_name(), ".node')\n")
    return String(
        "// The Mojo port of `",
        m.unit,
        "`, generated by mojo-anything: the original API over the ",
        over,
        "\n// built by `mojo-anything build`. Regenerate with `mojo-anything",
        " refresh`.\n",
        native,
        js_codec(),
        (
            "\n// Functions: [async, positions of Mojo String parameters,"
            " parameter"
        ),
        " count, position\n// of the rest parameter or -1].\nconst ports =",
        " {\n",
        join(ports, "\n"),
        "\n}\n",
        js_call(),
        batch_js,
    )


def mojo_node_bindings(
    m: Manifest,
    api: PortApi,
    mut paths: List[String],
    mut texts: List[String],
) raises:
    """Bridge.rs `mojo_node_bindings`: `pixi.toml`, `json.mojo`, the
    dispatcher, the Node-API addon source and `binding.gyp` (a wasm unit
    loads its module from `index.cjs` instead), and `index.cjs`. Only the
    unit's exports cross."""
    var exported = PortApi()
    for f in api.functions:
        for e in m.exports:
            if e.name == f.js_name:
                exported.functions.append(f.copy())
                break
    for s in api.structs:
        exported.structs.append(s)
    paths.append("pixi.toml")
    texts.append(unit_pixi_toml(m, True))
    paths.append("json.mojo")
    texts.append(json_mojo())
    paths.append(DISPATCHER)
    texts.append(dispatcher_mojo(m, exported))
    if m.kind == "mojo-node":
        paths.append("node_shim.c")
        texts.append(node_shim_c(m))
        paths.append("binding.gyp")
        texts.append(binding_gyp(m))
    paths.append("index.cjs")
    texts.append(index_cjs_mojo(m, exported))
