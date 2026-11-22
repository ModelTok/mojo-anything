//! `--kind wasm`: TS/JS units ported to Mojo and compiled to WebAssembly, loaded by the
//! generated `index.cjs` and checked against the original with `record` and `diff`.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge::{self, Kind};
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

fn have_all() -> bool {
    common::have("node") && common::have_mojo() && common::have_mojowasm()
}

fn fixtures() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures")
}

/// Bridges `unit` of the fixture project `root` as a wasm unit into a scratch folder.
fn bridged(root: &str, unit: &str, tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-anything-wasm-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &fixtures().join(root),
        unit,
        kind: Some(Kind::MojoWasm),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    dir
}

/// Records, copies the fixture port in, builds the wasm module and replays every case.
fn record_build_diff(dir: &Path, port: &str) -> (usize, usize, usize) {
    let recorded = harness::record(&RecordOptions {
        crate_dir: dir,
        count: 40,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    std::fs::copy(
        fixtures().join(port).join("port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    let built = harness::build(dir).unwrap();
    assert_eq!(built.extension().and_then(|e| e.to_str()), Some("wasm"));
    assert_eq!(built.parent(), Some(dir), "{}", built.display());
    let outcome = harness::diff(&DiffOptions {
        crate_dir: dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    assert!(outcome.mismatches.is_empty(), "{:#?}", outcome.mismatches);
    (recorded.cases, outcome.passed, outcome.failed)
}

/// Runs `script` with Node, stopped after `secs` seconds; returns stdout.
fn node(script: &str, secs: u32) -> String {
    let out = Command::new("timeout")
        .arg(secs.to_string())
        .args(["node", "-e", script])
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "node exited with {:?} (124 is the time limit)\n{}{}",
        out.status.code(),
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

#[test]
fn wasm_loop_matches() {
    if !have_all() {
        return;
    }
    let dir = bridged("mini", "packages/a/src/util.ts", "loop");
    for f in [
        "port.mojo",
        "dispatcher.mojo",
        "json.mojo",
        "index.cjs",
        "pixi.toml",
    ] {
        assert!(dir.join(f).is_file(), "{f} missing");
    }
    assert!(
        !dir.join("node_shim.c").exists(),
        "a wasm unit has no Node-API shim"
    );
    let (cases, passed, failed) = record_build_diff(&dir, "mini-mojo-port");
    assert!(cases > 0);
    assert_eq!((passed, failed), (cases, 0));
    assert!(dir.join("util_mojo.wasm").is_file());
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn wasm_float_results_replay() {
    if !have_all() {
        return;
    }
    let dir = bridged("wasm-floats", "src/floats.ts", "floats");
    let (cases, passed, failed) = record_build_diff(&dir, "wasm-floats-port");
    assert_eq!((passed, failed), (cases, 0));
    // Each value on its own, each call under a 5 s limit: a float writer that hangs on wasm
    // fails here instead of stalling the suite.
    for (call, want) in [
        ("third()", "0.30000000000000004"),
        ("negZero()", "-0"),
        ("tiny()", "5e-324"),
        ("huge()", "1.7976931348623157e+308"),
        ("sum(0.1, 0.2)", "0.30000000000000004"),
        ("sum(-0, -0)", "-0"),
        (
            "echoAll([-0, NaN, Infinity, -Infinity, 5e-324])",
            "-0,NaN,Infinity,-Infinity,5e-324",
        ),
    ] {
        let script = format!(
            "const m = require({:?})\nconst r = [m.{call}].flat()\n\
             console.log(r.map(x => Object.is(x, -0) ? '-0' : String(x)).join(','))",
            dir.join("index.cjs")
        );
        assert_eq!(node(&script, 5).trim(), want, "{call}");
    }
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn wasm_large_offsets() {
    if !have_all() {
        return;
    }
    let dir = bridged("wasm-floats", "src/floats.ts", "large");
    std::fs::copy(
        fixtures().join("wasm-floats-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    harness::build(&dir).unwrap();
    // 3 MB of text, non-ASCII included: the arguments and the answer lie past 2^21 in linear
    // memory, and the answer is read back whole.
    let script = format!(
        "const m = require({:?})\n\
         const s = 'ab\u{e9}\u{1f600} '.repeat(3 * 1024 * 1024 / 9)\n\
         for (let i = 0; i < 3; i++) {{\n\
           const r = m.same(s)\n\
           if (r !== s) throw new Error('changed at round ' + i + ': ' + r.length + ' vs ' + s.length)\n\
         }}\n\
         console.log(Buffer.byteLength(s), m.same('small'))",
        dir.join("index.cjs")
    );
    let out = node(&script, 60);
    let mut words = out.split_whitespace();
    let bytes: usize = words.next().unwrap().parse().unwrap();
    assert!(bytes > 3_000_000, "{out}");
    assert_eq!(words.next(), Some("small"), "{out}");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn wasm_errors_keep_their_class() {
    if !have_all() {
        return;
    }
    let dir = bridged("wasm-floats", "src/floats.ts", "errors");
    let port = std::fs::read_to_string(fixtures().join("wasm-floats-port/port.mojo"))
        .unwrap()
        .replace(
            "def same(text: String) raises -> String:\n    return text",
            "def same(text: String) raises -> String:\n    if text.byte_length() == 0:\n        \
             raise Error(\"TypeError: empty\")\n    return text",
        );
    std::fs::write(dir.join("port.mojo"), port).unwrap();
    harness::build(&dir).unwrap();
    let script = format!(
        "const m = require({:?})\n\
         try {{ m.same('') }} catch (e) {{ console.log(e.constructor.name, e.message) }}\n\
         try {{ m.same(1) }} catch (e) {{ console.log(e.code, e.message) }}\n\
         console.log(m.same('after'))",
        dir.join("index.cjs")
    );
    let out = node(&script, 20);
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.first(), Some(&"TypeError empty"), "{out}");
    assert!(
        lines
            .get(1)
            .is_some_and(|l| l.starts_with("MOJO_PANIC panic in same")),
        "{out}"
    );
    assert_eq!(lines.get(2), Some(&"after"), "{out}");
    std::fs::remove_dir_all(&dir).unwrap();
}
