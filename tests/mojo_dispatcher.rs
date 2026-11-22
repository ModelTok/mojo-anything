//! `dispatcher.mojo`, the C entry point of Go and Ruby units: a generated dispatcher over
//! `tests/fixtures/mojo-dispatcher/port.mojo`, built with Mojo and called from C.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

use mojo_anything::bridge::Manifest;
use mojo_anything::codegen_ffi::{DISPATCHER, dispatcher_mojo};
use mojo_anything::codegen_mojo::{JSON_MOJO, parse_port_mojo};
use mojo_anything::mojo;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn manifest() -> Manifest {
    serde_json::from_str(
        r#"{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "fixture.rb",
            "language": "ruby", "kind": "ffi", "crate_name": "fixture-mojo", "exports": []}"#,
    )
    .unwrap()
}

/// The built caller, once per test binary; `None` without Mojo or a C compiler.
fn caller() -> Option<&'static PathBuf> {
    static CALLER: OnceLock<Option<PathBuf>> = OnceLock::new();
    CALLER
        .get_or_init(|| {
            if !common::have_mojo() || !common::have("cc") {
                return None;
            }
            let fixture = Path::new(ROOT).join("tests/fixtures/mojo-dispatcher");
            let dir = std::env::temp_dir().join(format!("mojo-dispatcher-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let port = std::fs::read_to_string(fixture.join("port.mojo")).unwrap();
            let source = dispatcher_mojo(&manifest(), &parse_port_mojo(&port)).unwrap();
            std::fs::write(dir.join("port.mojo"), &port).unwrap();
            std::fs::write(dir.join("json.mojo"), JSON_MOJO).unwrap();
            std::fs::write(dir.join(DISPATCHER), &source).unwrap();
            let out = mojo::command(Path::new(ROOT))
                .unwrap()
                .current_dir(&dir)
                .args([
                    "build",
                    "--Werror",
                    DISPATCHER,
                    "--emit",
                    "shared-lib",
                    "-o",
                ])
                .arg(dir.join("libfixture.so"))
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "mojo build:\n{}{}\n{source}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            );
            let exe = dir.join("caller");
            let out = Command::new("cc")
                .arg(fixture.join("caller.c"))
                .arg("-o")
                .arg(&exe)
                .arg(format!("-L{}", dir.display()))
                .arg("-lfixture")
                .arg(format!("-Wl,-rpath,{}", dir.display()))
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "cc: {}",
                String::from_utf8_lossy(&out.stderr)
            );
            Some(exe)
        })
        .as_ref()
}

fn run(args: &[&str]) -> Vec<String> {
    let out = Command::new(caller().unwrap()).args(args).output().unwrap();
    assert!(
        out.status.success(),
        "caller {args:?} failed: {}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(str::to_string)
        .collect()
}

#[test]
fn dispatcher_ok() {
    if caller().is_none() {
        return;
    }
    let out = run(&[
        "add",
        "[1.5, 2]",
        "echo",
        r#"[{"b":[1,{"$num":"-0"}],"a":"x"}]"#,
        "repeat",
        r#"[["ab","c"],2,7]"#,
        "repeat",
        r#"[["ab"],null,0]"#,
        "nothing",
        "[]",
    ]);
    assert_eq!(
        out,
        [
            r#"{"ok":3.5}"#,
            r#"{"ok":{"b":[1,{"$num":"-0"}],"a":"x"}}"#,
            r#"{"ok":["ab7","c7","ab7","c7"]}"#,
            r#"{"ok":["ab0"]}"#,
            r#"{"ok":null}"#,
        ]
    );
}

#[test]
fn dispatcher_error_and_panic() {
    if caller().is_none() {
        return;
    }
    let out = run(&[
        "fail",
        r#"["bad"]"#,
        "nope",
        "[]",
        "add",
        "[1]",
        "repeat",
        r#"[["a"],1,256]"#,
        "add",
        r#"["x", 1]"#,
        "add",
        "not json",
    ]);
    assert_eq!(out[0], r#"{"error":"ArgumentError: bad"}"#);
    assert_eq!(out[1], r#"{"panic":"unknown function: nope"}"#);
    assert_eq!(out[2], r#"{"panic":"add takes 2 arguments, got 1"}"#);
    assert!(out[3].starts_with(r#"{"panic":"repeat: "#) && out[3].contains("out of range"));
    assert!(out[4].starts_with(r#"{"panic":"add: "#) && out[4].contains("expected a number"));
    assert!(
        out[5].starts_with(r#"{"panic":"the arguments are not JSON"#),
        "{}",
        out[5]
    );
}

#[test]
fn dispatcher_free_null() {
    if caller().is_none() {
        return;
    }
    assert_eq!(run(&["--free-null"]), ["freed"]);
}

#[test]
fn dispatcher_many_calls_no_growth() {
    if caller().is_none() {
        return;
    }
    let out = run(&["--rss"]);
    let kb: Vec<i64> = out[0]
        .strip_prefix("rss ")
        .unwrap()
        .split(' ')
        .map(|n| n.parse().unwrap())
        .collect();
    assert!(kb[0] > 0, "{out:?}");
    assert!(kb[1] - kb[0] < 10 * 1024, "resident set grew: {out:?}");
}
