//! The whole loop for a Python unit ported to Mojo: bridge, record, port, build, diff. The
//! recording and diff need `python3`; the build needs Mojo, so these skip where it cannot run.

mod common;

use std::path::{Path, PathBuf};

use mojo_anything::bridge::{self, Kind, Manifest};
use mojo_anything::harness::{self, DiffOptions, DiffOutcome, RecordOptions};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn fixture() -> PathBuf {
    Path::new(ROOT).join("tests/fixtures/python-mojo")
}

fn bridged(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-py-loop-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "src/mathkit/",
        kind: None,
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator: Default::default(),
    })
    .unwrap();
    assert_eq!(outcome.kind, Kind::MojoPy);
    dir
}

fn ready() -> bool {
    if !mojo_anything::mojo::available() {
        eprintln!("skipping: {}", mojo_anything::mojo::missing_message());
        return false;
    }
    common::have("python3")
}

fn record(dir: &Path) {
    let recorded = harness::record(&RecordOptions {
        crate_dir: dir,
        count: 40,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert!(recorded.cases > 40, "{} cases", recorded.cases);
}

fn port(dir: &Path, edit: impl Fn(String) -> String) {
    let port =
        std::fs::read_to_string(fixture().with_file_name("python-mojo-port/port.mojo")).unwrap();
    std::fs::write(dir.join("port.mojo"), edit(port)).unwrap();
}

fn diff(dir: &Path) -> DiffOutcome {
    harness::build(dir).unwrap();
    harness::diff(&DiffOptions {
        crate_dir: dir,
        module: None,
        ignore_key_order: false,
        node_args: &[],
        float_tolerance: None,
    })
    .unwrap()
}

fn mismatched(d: &DiffOutcome) -> Vec<String> {
    let mut names: Vec<String> = d
        .mismatches
        .iter()
        .filter_map(|m| m["fn"].as_str().map(str::to_string))
        .collect();
    names.sort();
    names.dedup();
    names
}

#[test]
fn python_mojo_bridge_files() {
    let dir = bridged("files");
    let mut files: Vec<String> = Vec::new();
    for entry in walk(&dir) {
        files.push(
            entry
                .strip_prefix(&dir)
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/"),
        );
    }
    files.sort();
    assert_eq!(
        files,
        [
            ".gitignore",
            "README.md",
            "_native.mojo",
            "mojo-anything.json",
            "pixi.toml",
            "port.mojo",
            "py_num.mojo",
            "python/mathkit_mojo/__init__.py",
        ]
    );
    let m = Manifest::load(&dir).unwrap();
    assert_eq!(m.crate_name, "mathkit-mojo");
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    assert!(
        port.contains("def scale(x: PyNum, factor: PyNum) raises -> PyNum:"),
        "{port}"
    );
    assert!(
        port.contains("def count_items(items: List[String]) raises -> PyNum:"),
        "{port}"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        let p = e.path();
        if p.is_dir() {
            out.extend(walk(&p));
        } else {
            out.push(p);
        }
    }
    out
}

#[test]
fn python_mojo_loop_matches() {
    if !ready() {
        return;
    }
    let dir = bridged("matches");
    record(&dir);
    port(&dir, |p| p);
    let d = diff(&dir);
    assert_eq!(d.failed, 0, "{:?}", d.mismatches);
    assert_eq!(d.passed, d.total);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn python_mojo_wrong_port_mismatches() {
    if !ready() {
        return;
    }
    let dir = bridged("wrong");
    record(&dir);
    port(&dir, |p| {
        p.replace("return text + \"!\"", "return text + \"?\"")
    });
    let d = diff(&dir);
    assert_eq!(mismatched(&d), ["exclaim"]);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn mojo_py_error_type_replays() {
    if !ready() {
        return;
    }
    let dir = bridged("error");
    record(&dir);
    let cases = std::fs::read_to_string(dir.join(harness::CASES)).unwrap();
    assert!(
        cases.contains("\"error\": \"ValueError: cannot divide by zero\""),
        "the recording has no ValueError case"
    );
    // A port raising the wrong exception type fails those cases.
    port(&dir, |p| {
        p.replace("\"ValueError: cannot", "\"KeyError: cannot")
    });
    assert_eq!(mismatched(&diff(&dir)), ["safe_div"]);
    port(&dir, |p| p);
    assert!(mismatched(&diff(&dir)).is_empty());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn mojo_py_rebuild_after_edit() {
    if !ready() {
        return;
    }
    let dir = bridged("rebuild");
    record(&dir);
    port(&dir, |p| p);
    assert!(mismatched(&diff(&dir)).is_empty());
    port(&dir, |p| {
        p.replace("return x * factor", "return x * factor + PyNum(1)")
    });
    assert_eq!(mismatched(&diff(&dir)), ["scale"]);
    std::fs::remove_dir_all(&dir).unwrap();
}

fn failed_checks(dir: &Path) -> Vec<String> {
    let outcome = mojo_anything::gate::gate(dir, &[]).unwrap();
    outcome
        .checks
        .iter()
        .filter(|c| !c.passed)
        .map(|c| format!("{}: {}", c.name, c.detail))
        .collect()
}

#[test]
fn python_mojo_gate_passes() {
    if !ready() {
        return;
    }
    let dir = bridged("gate");
    record(&dir);
    port(&dir, |p| p);
    let failed = failed_checks(&dir);
    assert!(failed.is_empty(), "{failed:#?}");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn python_mojo_gate_fails_on_stub() {
    if !ready() {
        return;
    }
    let dir = bridged("gate-stub");
    record(&dir);
    let outcome = mojo_anything::gate::gate(&dir, &[]).unwrap();
    let ported = outcome.checks.iter().find(|c| c.name == "ported").unwrap();
    assert!(!ported.passed);
    assert!(
        ported
            .fix
            .as_deref()
            .unwrap_or_default()
            .contains("port.mojo"),
        "{ported:?}"
    );
    assert!(!outcome.passed);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn python_mojo_gate_fails_on_unformatted_port() {
    if !ready() {
        return;
    }
    let dir = bridged("gate-format");
    record(&dir);
    port(&dir, |p| p.replace("return x * factor", "return x*factor"));
    let failed = failed_checks(&dir);
    assert_eq!(failed.len(), 1, "{failed:#?}");
    assert!(failed[0].starts_with("mojo format"), "{failed:#?}");
    std::fs::remove_dir_all(&dir).unwrap();
}
