//! `package`: the layouts it writes, and a napi port installed from its npm tarballs that
//! replays its recording, then falls back to the original where no binary fits.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge::{self, Kind};
use mojo_anything::harness::{self, DiffOptions, RecordOptions};
use mojo_anything::package::{self, Options, STAMP};

fn project(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-package-{name}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    for (path, text) in files {
        let path = root.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
    root
}

fn bridged(root: &Path, unit: &str, kind: Kind) -> PathBuf {
    let dir = root.join("port");
    bridge::bridge(&bridge::Options {
        root,
        unit,
        kind: Some(kind),
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
    dir
}

fn options(crate_dir: &Path) -> Options<'_> {
    Options {
        crate_dir,
        name: None,
        version: None,
        out: None,
        dry_run: false,
        fallback: None,
    }
}

fn run(dir: &Path, program: &str, args: &[&str]) -> String {
    let output = Command::new(program)
        .args(args)
        .current_dir(dir)
        .output()
        .unwrap_or_else(|e| panic!("{program}: {e}"));
    assert!(
        output.status.success(),
        "{program} {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

fn replay(crate_dir: &Path, module: &Path) -> (usize, usize) {
    let outcome = harness::diff(&DiffOptions {
        crate_dir,
        module: Some(module),
        ignore_key_order: false,
        node_args: &[],
        float_tolerance: None,
    })
    .unwrap();
    assert_eq!(outcome.failed, 0, "{:#?}", outcome.mismatches);
    (outcome.passed, outcome.total)
}

#[test]
fn napi_package_installs_from_tarballs_and_falls_back_to_the_original() {
    if !common::have("node") || !common::have("npm") {
        return;
    }
    let Some(host) = package::host_key() else {
        return;
    };
    let root = project(
        "napi",
        &[
            ("package.json", r#"{"name":"shout","version":"2.3.4"}"#),
            (
                "src/shout.js",
                "/**\n * @param {string} text\n * @returns {string}\n */\nexport function shout(text) {\n  return text + \"!\";\n}\n",
            ),
        ],
    );
    let dir = bridged(&root, "src/shout.js", Kind::Napi);
    harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 30,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    let port_path = dir.join("src/port.rs");
    let port = std::fs::read_to_string(&port_path).unwrap();
    let open = port.find("pub fn shout(").unwrap();
    let open = open + port[open..].find('{').unwrap();
    let close = open + port[open..].find("\n}").unwrap();
    let ported = format!(
        "{}{{\n    Ok(format!(\"{{text}}!\")){}",
        &port[..open],
        &port[close..]
    );
    std::fs::write(&port_path, ported).unwrap();
    harness::build(&dir).unwrap();

    let dry = package::package(&Options {
        dry_run: true,
        ..options(&dir)
    })
    .unwrap();
    assert!(!dir.join("package").exists());
    let outcome = package::package(&options(&dir)).unwrap();
    assert_eq!(outcome.files, dry.files);
    assert_eq!(outcome.version, "2.3.4");
    assert_eq!(outcome.name, "shout-rs");
    let out = outcome.out.clone();
    assert!(out.join("fallback/shout.js").exists());
    assert!(out.join(".github/workflows/shout-rs-npm.yml").exists());
    let main: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(out.join("package.json")).unwrap()).unwrap();
    assert_eq!(
        main["optionalDependencies"][format!("shout-rs-{host}")],
        "2.3.4"
    );
    let platform: serde_json::Value = serde_json::from_str(
        &std::fs::read_to_string(out.join(format!("npm/{host}/package.json"))).unwrap(),
    )
    .unwrap();
    assert_eq!(platform["main"], format!("shout_rs.{host}.node"));

    std::fs::write(out.join("stray.txt"), "kept").unwrap();
    package::package(&options(&dir)).unwrap();
    assert!(out.join("stray.txt").exists());
    let foreign = root.join("not-a-package");
    std::fs::create_dir_all(&foreign).unwrap();
    std::fs::write(foreign.join("x"), "").unwrap();
    let refused = package::package(&Options {
        out: Some(foreign),
        ..options(&dir)
    })
    .unwrap_err();
    assert!(format!("{refused:#}").contains("not empty"), "{refused:#}");

    let tarballs = root.join("tarballs");
    std::fs::create_dir_all(&tarballs).unwrap();
    let dest = tarballs.to_str().unwrap();
    run(
        &out.join("npm").join(host),
        "npm",
        &["pack", "--pack-destination", dest],
    );
    run(&out, "npm", &["pack", "--pack-destination", dest]);
    let app = root.join("app");
    std::fs::create_dir_all(&app).unwrap();
    std::fs::write(
        app.join("package.json"),
        r#"{"name":"app","version":"1.0.0"}"#,
    )
    .unwrap();
    let main_tgz = tarballs.join("shout-rs-2.3.4.tgz");
    let platform_tgz = tarballs.join(format!("shout-rs-{host}-2.3.4.tgz"));
    run(
        &app,
        "npm",
        &[
            "install",
            "--offline",
            "--no-audit",
            "--no-fund",
            platform_tgz.to_str().unwrap(),
            main_tgz.to_str().unwrap(),
        ],
    );
    let installed = app.join("node_modules/shout-rs");
    assert!(!installed.join(STAMP).exists());
    let native = run(
        &app,
        "node",
        &[
            "-e",
            "process.stdout.write(String(!!require('shout-rs/native.cjs').load().binding))",
        ],
    );
    assert_eq!(native, "true");
    let (passed, total) = replay(&dir, &installed.join("index.cjs"));
    assert_eq!(passed, total);

    std::fs::remove_dir_all(app.join(format!("node_modules/shout-rs-{host}"))).unwrap();
    let native = run(
        &app,
        "node",
        &[
            "-e",
            "process.stdout.write(String(!!require('shout-rs/native.cjs').load().binding))",
        ],
    );
    assert_eq!(native, "false");
    let (passed, total) = replay(&dir, &installed.join("index.cjs"));
    assert_eq!(passed, total);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn napi_package_without_a_fallback_says_so() {
    let root = project(
        "napi-imports",
        &[
            ("package.json", r#"{"name":"shout","version":"0.4.0"}"#),
            ("src/util.ts", "export const bang = '!';\n"),
            (
                "src/shout.ts",
                "import { bang } from './util';\nexport function shout(text: string): string {\n  return text + bang;\n}\n",
            ),
        ],
    );
    let dir = bridged(&root, "src/shout.ts", Kind::Napi);
    let outcome = package::package(&options(&dir)).unwrap();
    assert!(!outcome.files.iter().any(|f| f.starts_with("fallback/")));
    assert!(
        outcome.notes.iter().any(|n| n.contains("No fallback")),
        "{:?}",
        outcome.notes
    );
    let index = std::fs::read_to_string(outcome.out.join("index.cjs")).unwrap();
    assert!(index.contains("has no Rust build"), "{index}");

    let with = package::package(&Options {
        fallback: Some("shout".into()),
        version: Some("9.9.9".into()),
        ..options(&dir)
    })
    .unwrap();
    assert_eq!(with.version, "9.9.9");
    let index = std::fs::read_to_string(with.out.join("index.cjs")).unwrap();
    assert!(index.contains("require(\"shout\")"), "{index}");
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn wasm_package_needs_a_build() {
    let root = project(
        "wasm",
        &[
            ("package.json", r#"{"name":"shout","version":"0.1.0"}"#),
            (
                "src/shout.ts",
                "export function shout(text: string): string {\n  return text + \"!\";\n}\n",
            ),
        ],
    );
    let dir = bridged(&root, "src/shout.ts", Kind::Wasm);
    let err = package::package(&options(&dir)).unwrap_err();
    assert!(
        format!("{err:#}").contains("mojo-anything build"),
        "{err:#}"
    );
    std::fs::remove_dir_all(root).unwrap();
}
