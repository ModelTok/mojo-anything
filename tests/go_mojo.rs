//! Go units ported to Mojo: bridge `tests/fixtures/go-mojo-ports/textkit`, record it, drop in the
//! Mojo port, build, and diff through the cgo wrapper (typed calls and the JSON dispatcher).

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge::{self, Manifest};
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn fixture() -> PathBuf {
    Path::new(ROOT).join("tests/fixtures/go-mojo-ports")
}

/// A copy of the fixture package in a fresh folder, bridged to `<copy>/port`.
fn bridged(tag: &str, unit: &str) -> (PathBuf, PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-go-mojo-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    for f in ["go.mod", "textkit.go"] {
        std::fs::copy(fixture().join("textkit").join(f), root.join(f)).unwrap();
    }
    if unit != "textkit.go" {
        // Keep only the functions the typed path carries.
        let text = std::fs::read_to_string(root.join("textkit.go")).unwrap();
        let kept: String = text
            .split("\n// ")
            .filter(|part| {
                !["Repeat", "Split", "Pair", "Add", "Half", "IsNeg"]
                    .iter()
                    .any(|n| part.starts_with(n))
            })
            .collect::<Vec<_>>()
            .join("\n// ");
        std::fs::write(
            root.join("textkit.go"),
            kept.replace("\t\"errors\"\n\t\"strings\"\n", "")
                .replace("import (\n)\n", ""),
        )
        .unwrap();
    }
    let out = root.join("port");
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "textkit.go",
        kind: None,
        out: Some(out.clone()),
        name: Some("textkit-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    (root, out)
}

fn record(dir: &Path, inputs: &Path) -> harness::RecordOutcome {
    harness::record(&RecordOptions {
        crate_dir: dir,
        count: 5,
        inputs: Some(inputs),
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap()
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
    common::have("go") && common::have_mojo()
}

#[test]
fn go_mojo_loop_matches() {
    if !have_all() {
        return;
    }
    let (root, dir) = bridged("loop", "textkit.go");
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    for sig in [
        "def echo(s: String) raises -> String:",
        "def repeat(s: String, n: Int) raises -> String:",
        "def add(a: UInt64, b: UInt64) raises -> UInt64:",
        "def split(s: String) raises -> List[String]:",
        "def pair(s: String) raises -> JsonValue:",
    ] {
        assert!(port.contains(sig), "{sig}\n{port}");
    }
    assert!(
        dir.join("json.mojo").exists(),
        "Split and Pair go through the dispatcher"
    );
    let pixi = std::fs::read_to_string(dir.join("pixi.toml")).unwrap();
    assert!(pixi.contains("emberjson"), "{pixi}");
    // A 1 MB string result does not fit the wrapper's first buffer (status 2).
    let inputs = root.join("inputs.jsonl");
    let mut text = std::fs::read_to_string(fixture().join("inputs.jsonl")).unwrap();
    text.push_str(&format!(
        "{}\n",
        serde_json::json!({"fn": "Echo", "args": ["é".repeat(500_000)]})
    ));
    std::fs::write(&inputs, text).unwrap();
    let recorded = record(&dir, &inputs);
    assert!(recorded.errors > 0, "Repeat returns errors: {recorded:?}");
    std::fs::copy(fixture().join("textkit.mojo"), dir.join("port.mojo")).unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    let out = diff(&dir);
    assert_eq!(out.failed, 0, "{out:?}");
    assert_eq!(out.passed, recorded.cases, "{out:?}");
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn go_wrong_port_mismatches_and_errors_return() {
    if !have_all() {
        return;
    }
    let (root, dir) = bridged("wrong", "textkit.go");
    let recorded = record(&dir, &fixture().join("inputs.jsonl"));
    // A port that raises `bad count` for every Repeat: the error cases still match through Go's
    // `error`, the others mismatch.
    let port = std::fs::read_to_string(fixture().join("textkit.mojo"))
        .unwrap()
        .replace(
            "    if n < 0 or n > 8:\n        raise",
            "    if n > -1000000:\n        raise",
        );
    std::fs::write(dir.join("port.mojo"), port).unwrap();
    harness::build(&dir).unwrap();
    let out = diff(&dir);
    let wrong: Vec<&serde_json::Value> = out.mismatches.iter().map(|m| &m["fn"]).collect();
    assert!(
        !wrong.is_empty() && wrong.iter().all(|f| *f == "Repeat"),
        "{out:?}"
    );
    // The report lists the first 20 mismatches.
    assert!(out.failed >= wrong.len(), "{out:?}");
    assert_eq!(out.passed + out.failed, recorded.cases);
    // Repeat's recorded errors (n out of range) match the port's raise through Go's `error`.
    let errors = std::fs::read_to_string(dir.join("cases.jsonl"))
        .unwrap()
        .lines()
        .filter(|l| l.contains("\"Repeat\"") && l.contains("\"error\""))
        .count();
    assert!(errors > 0 && out.passed > 0);
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn go_string_bytes_survive() {
    if !have_all() {
        return;
    }
    let (root, dir) = bridged("bytes", "textkit.go");
    std::fs::copy(fixture().join("textkit.mojo"), dir.join("port.mojo")).unwrap();
    harness::build(&dir).unwrap();
    let manifest = Manifest::load(&dir).unwrap();
    // JSON cannot carry invalid UTF-8, so a Go program calls the wrapper directly.
    let prog = root.join("bytes-check");
    std::fs::create_dir_all(&prog).unwrap();
    let module = mojo_anything::harness_go::wrapper_module(&manifest);
    std::fs::write(
        prog.join("go.mod"),
        format!(
            "module bytescheck\n\ngo 1.21\n\nrequire {module} v0.0.0\n\nreplace {module} => {}\n",
            dir.join("go").display()
        ),
    )
    .unwrap();
    std::fs::write(
        prog.join("main.go"),
        format!(
            "package main\n\nimport (\n\t\"fmt\"\n\t\"strings\"\n\n\tt \"{module}\"\n)\n\n\
             func main() {{\n\tfor _, s := range []string{{\"\\xff\\xfe\", \"a\\x00b\", \"\", strings.Repeat(\"\\xc3\", 1<<20)}} {{\n\
             \t\tif got := t.Echo(s); got != s {{\n\t\t\tfmt.Printf(\"differs: %q\\n\", s[:min(len(s), 8)])\n\t\t\treturn\n\t\t}}\n\
             \t\tif t.Count(s) != len(s) {{\n\t\t\tfmt.Println(\"count differs\")\n\t\t\treturn\n\t\t}}\n\t}}\n\
             \tif m := splitPanics(); !strings.Contains(m, \"invalid UTF-8\") {{\n\t\tfmt.Println(\"split:\", m)\n\t\treturn\n\t}}\n\
             \tfmt.Println(\"same\")\n}}\n\n\
             // JSON cannot carry invalid UTF-8: the dispatcher path refuses it by name.\n\
             func splitPanics() (msg string) {{\n\tdefer func() {{\n\t\tif r := recover(); r != nil {{\n\t\t\tmsg = fmt.Sprint(r)\n\t\t}}\n\t}}()\n\
             \tt.Split(\"\\xff,a\")\n\treturn \"no panic\"\n}}\n"
        ),
    )
    .unwrap();
    let out = Command::new("go")
        .args(["run", "."])
        .current_dir(&prog)
        .env("GOWORK", "off")
        .env("GOFLAGS", "-mod=mod")
        .env("CGO_ENABLED", "1")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert_eq!(
        stdout.trim(),
        "same",
        "{stdout}{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn go_scalar_unit_builds_without_json() {
    if !have_all() {
        return;
    }
    let (root, dir) = bridged("scalar", "scalar");
    assert!(!dir.join("json.mojo").exists());
    let exports = std::fs::read_to_string(dir.join("exports.mojo")).unwrap();
    assert!(!exports.contains("mojo_anything_call"), "{exports}");
    let pixi = std::fs::read_to_string(dir.join("pixi.toml")).unwrap();
    assert!(!pixi.contains("emberjson"), "{pixi}");
    let none = root.join("none.jsonl");
    std::fs::write(&none, "").unwrap();
    record(&dir, &none);
    let port = std::fs::read_to_string(fixture().join("textkit.mojo")).unwrap();
    let keep: Vec<&str> = port
        .split("\n\n\n")
        .filter(|part| part.contains("def echo") || part.contains("def count"))
        .collect();
    std::fs::write(
        dir.join("port.mojo"),
        format!(
            "# The scalar part of the textkit port.\n\n\n{}\n",
            keep.join("\n\n\n")
        ),
    )
    .unwrap();
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    assert!(
        gate.passed,
        "{:#?}",
        gate.checks.iter().filter(|c| !c.passed).collect::<Vec<_>>()
    );
    let _ = std::fs::remove_dir_all(&root);
}

#[test]
fn go_batch_not_yet() {
    if !common::have("go") {
        return;
    }
    let root = std::env::temp_dir().join(format!("mojo-anything-go-batch-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    for f in ["go.mod", "textkit.go"] {
        std::fs::copy(fixture().join("textkit").join(f), root.join(f)).unwrap();
    }
    let err = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "textkit.go",
        kind: None,
        out: Some(root.join("port")),
        name: Some("textkit-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: vec!["Echo:s".into()],
        as_json: Vec::new(),
    })
    .unwrap_err()
    .to_string();
    assert!(err.contains("not yet"), "{err}");
}

#[test]
fn go_refresh_after_a_type_change_still_builds() {
    if !have_all() {
        return;
    }
    let (root, dir) = bridged("retype", "scalar");
    assert!(!dir.join("json.mojo").exists());
    // `count` now returns Int64 where the Go `int` maps to Int, so it goes through the
    // dispatcher; `is_space` is a public helper that matches no export.
    std::fs::write(
        dir.join("port.mojo"),
        "# The scalar part of the textkit port, retyped.\n\n\n\
         def echo(s: String) raises -> String:\n    return s\n\n\n\
         def count(s: String) raises -> Int64:\n    return Int64(s.byte_length())\n\n\n\
         def is_space(c: UInt8) -> Bool:\n    return c == 32\n",
    )
    .unwrap();
    bridge::refresh(&dir).unwrap();
    let exports = std::fs::read_to_string(dir.join("exports.mojo")).unwrap();
    assert!(!exports.contains("is_space"), "{exports}");
    assert!(exports.contains("mojo_anything_call"), "{exports}");
    harness::build(&dir).unwrap();
    let _ = std::fs::remove_dir_all(&root);
}
