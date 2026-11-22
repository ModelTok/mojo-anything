//! Ruby units ported to Mojo: bridge `tests/fixtures/ruby-mojo-ports/textkit`, record it, drop
//! in the Mojo port, build, and diff through the Fiddle wrapper and the JSON dispatcher.

mod common;

use std::path::{Path, PathBuf};

use mojo_anything::bridge;
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn fixture() -> PathBuf {
    Path::new(ROOT).join("tests/fixtures/ruby-mojo-ports")
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_dir(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// A copy of the fixture gem, bridged to `<copy>/port`, recorded with the fixture inputs.
fn recorded(tag: &str) -> (PathBuf, PathBuf, harness::RecordOutcome) {
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-ruby-mojo-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    copy_dir(&fixture().join("textkit"), &root);
    let dir = root.join("port");
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "lib/textkit.rb",
        kind: None,
        out: Some(dir.clone()),
        name: Some("textkit-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: Some(mojo_anything::lang::Lang::Ruby),
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    let inputs = fixture().join("inputs.jsonl");
    let outcome = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 5,
        inputs: Some(&inputs),
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    (root, dir, outcome)
}

fn diff(dir: &Path) -> harness::DiffOutcome {
    harness::diff(&DiffOptions {
        crate_dir: dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap()
}

fn have_all() -> bool {
    common::have("ruby") && common::have_mojo()
}

/// The recorded cases whose arguments are integers beyond 64 bits, which the dispatcher refuses.
fn bignum_cases(dir: &Path) -> usize {
    std::fs::read_to_string(dir.join("cases.jsonl"))
        .unwrap()
        .lines()
        .filter(|l| {
            let c: serde_json::Value = serde_json::from_str(l).unwrap();
            c["args"].as_array().unwrap().iter().any(|a| {
                a.is_number() && a.as_i64().is_none() && a.as_u64().is_none() && !a.is_f64()
            })
        })
        .count()
}

#[test]
fn ruby_mojo_loop_matches() {
    if !have_all() {
        return;
    }
    let (root, dir, recorded) = recorded("loop");
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    for sig in [
        "def repeat(s: String, n: Int) raises -> String:",
        "def echo(v: JsonValue) raises -> JsonValue:",
        "def half(x: Float64) raises -> Float64:",
    ] {
        assert!(port.contains(sig), "{sig}\n{port}");
    }
    assert!(dir.join("dispatcher.mojo").exists() && dir.join("json.mojo").exists());
    assert!(!dir.join("Cargo.toml").exists());
    assert!(
        recorded.errors > 0,
        "repeat raises ArgumentError: {recorded:?}"
    );
    std::fs::copy(fixture().join("textkit.mojo"), dir.join("port.mojo")).unwrap();
    harness::build(&dir).unwrap();
    let out = diff(&dir);
    // Every case matches but those with integers beyond 64 bits, which are refused.
    let refused = bignum_cases(&dir);
    assert_eq!(out.failed, refused, "{out:?}");
    assert_eq!(out.passed + out.failed, recorded.cases, "{out:?}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn ruby_error_class_raised() {
    if !have_all() {
        return;
    }
    let (root, dir, _) = recorded("errors");
    // A port that raises a RuntimeError where the original raises ArgumentError mismatches.
    let port = std::fs::read_to_string(fixture().join("textkit.mojo"))
        .unwrap()
        .replace("ArgumentError: bad count", "bad count");
    std::fs::write(dir.join("port.mojo"), port).unwrap();
    harness::build(&dir).unwrap();
    let out = diff(&dir);
    assert!(out.failed > 0, "{out:?}");
    assert!(
        out.mismatches
            .iter()
            .all(|m| m["fn"] == "repeat" || m["args"].to_string().contains("18446744073709551615")),
        "{out:?}"
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn ruby_symbols_hashes_and_bignums() {
    if !have_all() {
        return;
    }
    let (root, dir, _) = recorded("values");
    std::fs::copy(fixture().join("textkit.mojo"), dir.join("port.mojo")).unwrap();
    harness::build(&dir).unwrap();
    let out = diff(&dir);
    let passed_echo = |needle: &str| {
        !out.mismatches
            .iter()
            .any(|m| m["fn"] == "echo" && m["args"].to_string().contains(needle))
    };
    for needle in ["$sym", "$hash", "NaN", "-0", "1e21"] {
        assert!(passed_echo(needle), "{needle}: {out:?}");
    }
    // A u64 fits; an integer beyond 64 bits is refused with a named error, not changed.
    assert!(passed_echo("18446744073709551615"), "{out:?}");
    let ruby = std::process::Command::new("ruby")
        .arg("-e")
        .arg(format!(
            "require {:?}; begin; Textkit.echo(2**70); rescue RuntimeError => e; puts e.message; end",
            dir.join("ruby/textkit_mojo.rb").display().to_string()
        ))
        .output()
        .unwrap();
    let said = String::from_utf8_lossy(&ruby.stdout);
    assert!(
        said.contains("beyond 64 bits"),
        "{said}{}",
        String::from_utf8_lossy(&ruby.stderr)
    );
    let _ = std::fs::remove_dir_all(&root);
}
