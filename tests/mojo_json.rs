//! `json.mojo`, the reader and writer every Mojo unit with structured values uses: floats
//! written as V8 writes them, deep input, big integers, markers, strings and errors. Runs
//! `tests/fixtures/mojo-json/test_json.mojo` beside the embedded `json.mojo`.

mod common;

use std::path::Path;

use mojo_anything::{codegen_mojo::JSON_MOJO, mojo};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

#[test]
fn json_mojo_passes_its_checks() {
    if !common::have_mojo() {
        return;
    }
    let dir = std::env::temp_dir().join(format!("mojo-json-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(dir.join("json.mojo"), JSON_MOJO).unwrap();
    for f in ["test_json.mojo", "floats.txt"] {
        std::fs::copy(
            Path::new(ROOT).join("tests/fixtures/mojo-json").join(f),
            dir.join(f),
        )
        .unwrap();
    }
    let out = mojo::command(Path::new(ROOT))
        .unwrap()
        .current_dir(&dir)
        .args(["run", "test_json.mojo"])
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        out.status.success() && stdout.trim_end().ends_with("ok"),
        "stdout:\n{stdout}\nstderr:\n{stderr}"
    );
    for check in [
        "json_float_corpus",
        "json_200_deep",
        "json_key_order",
        "json_big_ints_exact",
        "json_markers",
        "json_strings",
        "json_rejects",
    ] {
        assert!(
            stdout.contains(&format!("pass {check}")),
            "{check}: {stdout}"
        );
    }
    std::fs::remove_dir_all(&dir).unwrap();
}
