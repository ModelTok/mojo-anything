#!/usr/bin/env python3
"""Write tool/src/mojo_anything/embedded.mojo: texts the Mojo tool carries in its binary.

- `analyze_py_source()`: tool/src/mojo_anything/analyze_py.py, the Python that reads a Python
  file through CPython's `ast` where the Rust tool walks tree-sitter-python's tree.
- `analyze_tree_source()`: tool/src/mojo_anything/analyze_tree.py, the Python that reads a
  file through tree-sitter's Python bindings for the other languages the Rust tool reads with
  tree-sitter.
- `oxc_reader_source()`: tool/src/mojo_anything/oxc_reader.mjs, the JavaScript that reads a
  TS/JS file through oxc's own parser (tool/oxc) where the Rust tool walks oxc's AST.
- `replacements_toml()`: src/replacements.toml, the crate table, which the Rust tool embeds with
  `include_str!` (src/crates.rs).
- `py_num_mojo()`: src/mojo/py_num.mojo, which `bridge` writes into a Python unit's port
  (src/codegen_mojo_py.rs `PY_NUM_MOJO`, an `include_str!`).
- `driver_py()`: the Python driver `record` writes to `.mojo-anything/driver.py`
  (src/harness_py.rs `DRIVER_PY`, a raw string in the Rust source).
- `pinned_mojo()`: src/mojo/pinned.mojo, the helper `record --pin-clock` writes beside a Mojo
  port (src/pin.rs `HELPER_MOJO_SRC`, an `include_str!`).
- `py_hook_head()`, `py_hook_tail()`: the two halves of the `sitecustomize.py` that
  `record --from-tests` puts on a Python test suite's path (src/from_tests.rs).
- `json_mojo()`: src/mojo/json.mojo, which `bridge` writes into a unit that needs JSON
  (src/codegen_mojo.rs `JSON_MOJO`, an `include_str!`).
- `dispatcher_helpers()`: the helpers of every JSON dispatcher (src/codegen_ffi.rs).
- `go_helpers()`, `go_call()`, `go_typed_helpers()`, `go_typed_helpers_mojo()`: the fixed
  parts of a Go unit's cgo wrapper and `exports.mojo` (src/codegen_go.rs).
- `ruby_codec()`, `ruby_native()`: the fixed parts of a Ruby unit's Fiddle module
  (src/codegen_ruby.rs).
- `node_shim()`: src/mojo/node_shim.c, the Node-API addon a `mojo-node` unit builds
  (src/codegen_mojo_node.rs `NODE_SHIM_C`, an `include_str!`).
- `java_native_ffm()`, `java_json()`, `java_error()`: the fixed Java classes of a mojo-jvm
  unit (src/codegen_mojo_jvm.rs `NATIVE_FFM`, src/codegen_java.rs `JSON_JAVA` and
  `ERROR_JAVA`).
- `js_codec()`, `js_call()`, `js_wasm()`, `js_batch()`: the fixed parts of a TS/JS unit's
  `index.cjs` (`js_batch()` is src/codegen_mojo_node.rs `BATCH_CJS`)
  (src/codegen_js.rs `CODEC_CJS`, src/codegen_mojo_node.rs `CALL_CJS` and `WASM_CJS`).

Run by tool/build.sh and tool/check.sh; the output is not committed (.gitignore) and not
formatted.
"""

import json
import os

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
OUT = os.path.join(REPO, "tool", "src", "mojo_anything", "embedded.mojo")
FILES = [
    ("analyze_py_source", os.path.join(REPO, "tool", "src", "mojo_anything", "analyze_py.py")),
    ("analyze_tree_source", os.path.join(REPO, "tool", "src", "mojo_anything", "analyze_tree.py")),
    ("oxc_reader_source", os.path.join(REPO, "tool", "src", "mojo_anything", "oxc_reader.mjs")),
    ("replacements_toml", os.path.join(REPO, "src", "replacements.toml")),
    ("py_num_mojo", os.path.join(REPO, "src", "mojo", "py_num.mojo")),
    ("driver_py", os.path.join(REPO, "src", "harness_py.rs") + "#DRIVER_PY"),
    ("pinned_mojo", os.path.join(REPO, "src", "mojo", "pinned.mojo")),
    ("py_hook_head", os.path.join(REPO, "src", "from_tests.rs") + "#PY_HOOK_HEAD"),
    ("py_hook_tail", os.path.join(REPO, "src", "from_tests.rs") + "#PY_HOOK_TAIL"),
    ("json_mojo", os.path.join(REPO, "src", "mojo", "json.mojo")),
    ("dispatcher_helpers", os.path.join(REPO, "src", "codegen_ffi.rs") + "#DISPATCHER_HELPERS"),
    ("go_helpers", os.path.join(REPO, "src", "codegen_go.rs") + "#HELPERS_GO"),
    ("go_call", os.path.join(REPO, "src", "codegen_go.rs") + "#CALL_GO"),
    ("go_typed_helpers", os.path.join(REPO, "src", "codegen_go.rs") + "#TYPED_HELPERS_GO"),
    ("go_typed_helpers_mojo", os.path.join(REPO, "src", "codegen_go.rs") + "#TYPED_HELPERS_MOJO"),
    ("ruby_codec", os.path.join(REPO, "src", "codegen_ruby.rs") + "#CODEC_RB"),
    ("ruby_native", os.path.join(REPO, "src", "codegen_ruby.rs") + "#NATIVE_RB"),
    ("node_shim", os.path.join(REPO, "src", "mojo", "node_shim.c")),
    ("js_codec", os.path.join(REPO, "src", "codegen_js.rs") + "#CODEC_CJS"),
    ("js_call", os.path.join(REPO, "src", "codegen_mojo_node.rs") + "#CALL_CJS"),
    ("js_wasm", os.path.join(REPO, "src", "codegen_mojo_node.rs") + "#WASM_CJS"),
    ("js_batch", os.path.join(REPO, "src", "codegen_mojo_node.rs") + "#BATCH_CJS"),
    ("java_native_ffm", os.path.join(REPO, "src", "codegen_mojo_jvm.rs") + "#NATIVE_FFM"),
    ("java_json", os.path.join(REPO, "src", "codegen_java.rs") + "#JSON_JAVA"),
    ("java_error", os.path.join(REPO, "src", "codegen_java.rs") + "#ERROR_JAVA"),
]


def _rust_raw_const(path, name):
    """The text of `[pub] const NAME: &str = r#"..."#;` in a Rust file."""
    with open(path, encoding="utf-8") as f:
        source = f.read()
    start = source.index("const %s: &str = r#\"" % name)
    start = source.index('r#"', start) + 3
    return source[start : source.index('"#;', start)]


def main():
    out = [
        "# Generated by tool/embedded.py. Do not edit.",
    ]
    for name, path in FILES:
        if "#" in path:
            path, const = path.split("#")
            text = _rust_raw_const(path, const)
        else:
            with open(path, encoding="utf-8") as f:
                text = f.read()
        bad = sorted({c for c in text if ord(c) < 32 and c not in "\n\t"})
        if bad:
            raise SystemExit(f"{path}: control characters {bad} have no Mojo escape here")
        out += ["", "", f"def {name}() -> String:"]
        out.append(f"    return {json.dumps(text, ensure_ascii=False)}")
    text = "\n".join(out) + "\n"
    try:
        with open(OUT, encoding="utf-8") as f:
            if f.read() == text:
                return
    except FileNotFoundError:
        pass
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)


if __name__ == "__main__":
    main()
