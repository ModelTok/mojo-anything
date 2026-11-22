//! The Node-API shim over a Mojo port's dispatcher, built and called from Node.

mod common;

use std::path::PathBuf;
use std::process::Command;

use mojo_anything::bridge::Manifest;

fn have_all() -> bool {
    common::have_mojo() && common::have("node") && common::have("cc")
}

/// A one-function `mojo-node` unit, generated and built in a scratch folder.
fn built_unit(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "mojo-anything-node-shim-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let manifest = r#"{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "src/check.ts",
        "language": "ts", "kind": "mojo-node", "crate_name": "shim-mojo",
        "exports": [{"name": "check", "file": "src/check.ts", "line": 1,
          "params": [{"name": "s", "ts_type": "string", "optional": false, "rest": false}],
          "returns": "string", "is_async": false, "is_generator": false,
          "type_params": [], "uses_instanceof": false}]}"#;
    std::fs::write(dir.join("mojo-anything.json"), manifest).unwrap();
    let m = Manifest::load(&dir).unwrap();
    let port = "# A port that refuses the empty string.\n\n\n\
                def check(s: String) raises -> String:\n    \
                if s.byte_length() == 0:\n        raise Error(\"TypeError: empty\")\n    \
                return s\n";
    std::fs::write(dir.join("port.mojo"), port).unwrap();
    let mut api = mojo_anything::codegen_mojo::parse_port_mojo(port);
    mojo_anything::bridge::match_export_names(&m, &mut api);
    let files = [
        (
            "dispatcher.mojo",
            mojo_anything::codegen_ffi::dispatcher_mojo(&m, &api).unwrap(),
        ),
        (
            "json.mojo",
            mojo_anything::codegen_mojo::JSON_MOJO.to_string(),
        ),
        (
            "pixi.toml",
            mojo_anything::codegen_mojo_py::unit_pixi_toml(&m, true),
        ),
        (
            "node_shim.c",
            mojo_anything::codegen_mojo_node::node_shim_c(&m),
        ),
        (
            "index.cjs",
            mojo_anything::codegen_mojo_node::index_cjs_mojo(&m, &api),
        ),
    ];
    for (name, text) in files {
        std::fs::write(dir.join(name), text).unwrap();
    }
    mojo_anything::harness_mojo_node::build(&dir, &m).unwrap();
    dir
}

#[test]
fn shim_turns_panic_into_error() {
    if !have_all() {
        return;
    }
    let dir = built_unit("panic");
    let script = format!(
        "const m = require({:?})\n\
         console.log(m.check('ok'))\n\
         try {{ m.check('') }} catch (e) {{ console.log(e.constructor.name, e.message) }}\n\
         try {{ m.check(1) }} catch (e) {{ console.log(e.code, e.message) }}\n",
        dir.join("index.cjs")
    );
    let out = Command::new("node").args(["-e", &script]).output().unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let lines: Vec<&str> = stdout.lines().collect();
    assert_eq!(
        lines.len(),
        3,
        "{stdout}{}",
        String::from_utf8_lossy(&out.stderr)
    );
    assert_eq!(lines[0], "ok");
    assert_eq!(lines[1], "TypeError empty");
    assert!(
        lines[2].starts_with("MOJO_PANIC panic in check"),
        "{stdout}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
