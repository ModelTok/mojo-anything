//! The bridge -> record -> diff -> shadow loop on the fixture repo.
//!
//! A hand-written JS module stands in for the built Rust module, so these tests check the
//! harness itself without compiling a native crate. They need `node` on PATH.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge::{self, Kind, Manifest};
use mojo_anything::harness::{self, DiffOptions, RecordOptions};
use mojo_anything::shadow;

fn fixture() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mini")
}

/// A fresh crate for `util.ts` in a temp folder.
fn bridged(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-anything-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "packages/a/src/util.ts",
        kind: Some(Kind::Napi),
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

/// JS stand-in for the Rust module; `buggy` miscounts tabs as spaces.
fn stand_in(dir: &Path, buggy: bool) {
    let space = if buggy { "/[ \\t]/" } else { "/ /" };
    std::fs::write(
        dir.join("index.cjs"),
        format!(
            "const after = /(?<=\\$)\\w+/g\n\
             exports.rangeOf = (text, word) => {{ const start = text.indexOf(word); return {{ start, end: start + word.length, rest: text.slice(start) }} }}\n\
             exports.words = text => [...text.matchAll(after)].map(m => m[0])\n\
             exports.count = text => [...text].filter(c => {space}.test(c)).length\n"
        ),
    )
    .unwrap();
}

#[test]
fn refresh_keeps_the_original_name_for_raw_rust_identifiers() {
    let dir = bridged("raw-identifiers");
    let mut manifest = Manifest::load(&dir).unwrap();
    manifest.exports.truncate(1);
    manifest.exports[0].name = "Type".into();
    manifest.save(&dir).unwrap();
    std::fs::write(dir.join("src/port.rs"), "pub fn r#type() -> f64 { 1.0 }\n").unwrap();

    let refreshed = bridge::refresh(&dir).unwrap();
    assert_eq!(refreshed.functions, ["Type"]);
    let bindings = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    assert!(bindings.contains(r#"js_name = "Type""#), "{bindings}");
    std::fs::remove_dir_all(dir).unwrap();
}

#[test]
fn bridge_writes_a_crate_and_never_overwrites_it() {
    let dir = bridged("bridge");
    let manifest = Manifest::load(&dir).unwrap();
    let names: Vec<&str> = manifest.exports.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(names, ["rangeOf", "words", "count"]);
    let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    // Structured results cross as JSON text; string lists cross natively.
    assert!(lib.contains("pub fn range_of(text: String, word: String) -> napi::Result<String>"));
    assert!(lib.contains("pub fn words(text: String) -> napi::Result<Vec<String>>"));
    let port = std::fs::read_to_string(dir.join("src/port.rs")).unwrap();
    assert!(port.contains(
        "pub fn range_of(text: String, word: String) -> Result<serde_json::Value, String>"
    ));
    assert!(
        dir.join("src/utf16.rs").exists(),
        "util.ts uses string offsets"
    );
    let again = bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "packages/a/src/util.ts",
        kind: None,
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator: Default::default(),
    });
    assert!(again.unwrap_err().to_string().contains("never overwrites"));
    let blocked = bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "packages/a/src/svelte.ts",
        kind: None,
        out: Some(dir.join("nope")),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator: Default::default(),
    });
    assert!(blocked.unwrap_err().to_string().contains("Blocked"));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn diff_rejects_an_empty_recording() {
    if !common::have("node") {
        return;
    }
    let dir = bridged("empty-recording");
    std::fs::write(dir.join(harness::CASES), "").unwrap();
    stand_in(&dir, false);
    let err = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap_err();
    std::fs::remove_dir_all(&dir).unwrap();
    assert!(
        err.to_string().contains("no recorded cases to compare"),
        "{err:#}"
    );
}

#[test]
fn record_and_diff_catch_a_behavior_change() {
    if !common::have("node") {
        return;
    }
    let dir = bridged("diff");
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 120,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!(recorded.cases - recorded.traps, 360);
    assert!(recorded.traps > 0);

    let diff = |dir: &Path| {
        harness::diff(&DiffOptions {
            crate_dir: dir,
            module: None,
            ignore_key_order: false,
            float_tolerance: None,
            node_args: &[],
        })
        .unwrap()
    };
    stand_in(&dir, true);
    let buggy = diff(&dir);
    assert!(buggy.failed > 0, "the tab bug must show up");
    assert!(buggy.mismatches.iter().all(|m| m["fn"] == "count"));

    stand_in(&dir, false);
    let fixed = diff(&dir);
    assert_eq!((fixed.passed, fixed.failed), (recorded.cases, 0));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn diff_replays_large_strings_with_lone_surrogates() {
    if !common::have("node") {
        return;
    }
    let unsplit = 0xd800;
    let mut units = vec![u16::from(b'a'); 200_000];
    units.push(unsplit);
    let dir = bridged("long-utf16");
    let input = serde_json::json!({
        "fn": "inspect",
        "args": [{ "$utf16": units }],
        "ok": [200_001, unsplit]
    });
    std::fs::write(dir.join(harness::CASES), input.to_string()).unwrap();
    std::fs::write(
        dir.join("index.cjs"),
        "exports.inspect = s => [s.length, s.charCodeAt(s.length - 1)]",
    )
    .unwrap();
    let result = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    });
    std::fs::remove_dir_all(&dir).unwrap();
    let outcome = result.unwrap();
    assert_eq!(
        outcome.passed,
        1,
        "{:?}",
        outcome
            .mismatches
            .iter()
            .map(|m| &m["actual"])
            .collect::<Vec<_>>()
    );
}

#[test]
fn float_tolerance_preserves_object_key_order_unless_requested() {
    if !common::have("node") {
        return;
    }
    let dir = bridged("tolerance-order");
    std::fs::write(
        dir.join(harness::CASES),
        r#"{"fn":"f","args":[],"ok":{"nested":{"first":0.3,"second":1}}}"#,
    )
    .unwrap();
    std::fs::write(
        dir.join("index.cjs"),
        "exports.f = () => ({ nested: { second: 1, first: 0.30000000000000004 } })",
    )
    .unwrap();
    let mut opts = DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: Some(1e-9),
        node_args: &[],
    };
    let strict = harness::diff(&opts).unwrap();
    opts.ignore_key_order = true;
    let unordered = harness::diff(&opts).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
    assert_eq!(strict.failed, 1);
    assert_eq!(unordered.passed, 1);
}

#[test]
fn shadow_returns_the_original_and_reports_mismatches() {
    if !common::have("node") {
        return;
    }
    let dir = bridged("shadow");
    stand_in(&dir, true);
    let out = shadow::shadow(&dir, None).unwrap();
    let script = dir.join("use.ts");
    std::fs::write(
        &script,
        format!(
            "import {{ count, shadowStats, onMismatch }} from '{}'\n\
             const seen: string[] = []\n\
             onMismatch(m => seen.push(m.fn))\n\
             console.log(JSON.stringify([count('a b'), count('a\\tb'), shadowStats.calls, seen]))\n",
            out.path.display()
        ),
    )
    .unwrap();
    let run = |mode: &str| {
        let o = Command::new("node")
            .arg(&script)
            .env("MOJO_ANYTHING_MODE", mode)
            .output()
            .unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
        String::from_utf8_lossy(&o.stdout).trim().to_string()
    };
    // Shadow: callers get the original's answers; the tab case is reported.
    assert_eq!(run("shadow"), r#"[1,0,2,["count"]]"#);
    assert_eq!(run("old"), r#"[1,0,0,[]]"#);
    // New: the stand-in answers, bug included.
    assert_eq!(run("new"), r#"[1,1,0,[]]"#);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn mcp_runs_analyze() {
    let response = mojo_anything::mcp::handle(&serde_json::json!({
        "jsonrpc": "2.0",
        "id": 7,
        "method": "tools/call",
        "params": { "name": "analyze", "arguments": { "root": fixture() } },
    }))
    .unwrap();
    assert_eq!(response["result"]["isError"], false);
    assert_eq!(
        response["result"]["structuredContent"]["schema"],
        "mojo-anything/analyze@1"
    );
}

#[test]
fn record_follows_bundler_style_imports() {
    if !common::have("node") {
        return;
    }
    // `fs.ts` imports `./util.js`, a file that only exists as `util.ts`.
    let dir = std::env::temp_dir().join(format!("mojo-anything-resolve-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "packages/a/src/fs.ts",
        kind: Some(Kind::Napi),
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
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 5,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    // The paths do not exist: every call throws, but the module loaded and ran.
    assert_eq!(recorded.cases - recorded.traps, 5);
    assert_eq!(recorded.errors, recorded.cases);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn record_registers_its_resolver_from_a_path_with_url_delimiters() {
    if !common::have("node") {
        return;
    }
    let dir = bridged("record #1 % café");
    let result = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 2,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    });
    std::fs::remove_dir_all(&dir).unwrap();
    let recorded = result.unwrap();
    assert!(recorded.cases > 0);
    assert_eq!(recorded.errors, 0);
}

#[test]
fn async_functions_get_async_bindings() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/async");
    for kind in [Kind::Napi, Kind::Wasm] {
        let dir = std::env::temp_dir().join(format!(
            "mojo-anything-async-{kind:?}-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        bridge::bridge(&bridge::Options {
            root: &root,
            unit: "src/pipeline.ts",
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
        let port = std::fs::read_to_string(dir.join("src/port.rs")).unwrap();
        assert!(port.contains("pub async fn count_words(text: String) -> Result<f64, String>"));
        assert!(port.contains("pub fn upper(text: String) -> Result<String, String>"));
        let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
        assert!(
            lib.contains("pub async fn count_words(text: String)"),
            "{lib}"
        );
        let cargo = std::fs::read_to_string(dir.join("Cargo.toml")).unwrap();
        match kind {
            Kind::Napi => {
                assert!(cargo.contains("features = [\"async\"]") && cargo.contains("futures"))
            }
            Kind::Wasm => assert!(cargo.contains("wasm-bindgen-futures")),
            Kind::MojoPy | Kind::CAbi | Kind::Ffi | Kind::MojoNode => {}
        }
        let index = std::fs::read_to_string(dir.join("index.cjs")).unwrap();
        assert!(
            index.contains("normalize: [[1, 0], 'json', true]"),
            "{index}"
        );
        assert!(index.contains("  countWords: [true, [0]],"), "{index}");
        std::fs::remove_dir_all(&dir).unwrap();
    }
}

#[test]
fn benchmark_awaits_async_typescript_calls_and_counts_rejections() {
    if !common::have("node") {
        return;
    }
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-ts-async-bench-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(
        root.join("main.mts"),
        "export async function delayed(): Promise<number> { await new Promise(r => setTimeout(r, 15)); throw new Error('intentional'); }",
    )
    .unwrap();
    let dir = root.join("bridge");
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "main.mts",
        kind: Some(Kind::Napi),
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
    std::fs::write(
        dir.join(harness::CASES),
        r#"{"fn":"delayed","args":[],"error":"intentional"}"#,
    )
    .unwrap();
    std::fs::write(
        dir.join("index.cjs"),
        "exports.delayed = async () => { await new Promise(r => setTimeout(r, 15)); throw new Error('intentional') }",
    )
    .unwrap();
    let result = harness::bench(&harness::BenchOptions {
        crate_dir: &dir,
        min_ms: 1,
        resolve_from: None,
        node_args: &[],
    });
    std::fs::remove_dir_all(root).unwrap();
    let rows = result.unwrap();
    assert_eq!(rows.len(), 1);
    assert!(rows[0].original_ns > 5_000_000.0, "{rows:?}");
    assert!(rows[0].rust_ns > 5_000_000.0, "{rows:?}");
}

#[test]
fn classes_are_bridged_recorded_and_replayed() {
    if !common::have("node") {
        return;
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/classes");
    let dir = std::env::temp_dir().join(format!("mojo-anything-classes-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/stats.ts",
        kind: Some(Kind::Napi),
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
    assert_eq!(outcome.exports, ["class TextStats", "class LruCache"]);
    let manifest = Manifest::load(&dir).unwrap();
    assert!(
        manifest
            .js_only
            .iter()
            .any(|j| j.name == "Blocked" && j.reason.contains("extends"))
    );
    let port = std::fs::read_to_string(dir.join("src/port.rs")).unwrap();
    assert!(port.contains("pub fn new(capacity: f64) -> Result<Self, String>"));
    assert!(port.contains("pub fn get(&mut self, key: String) -> Result<Option<String>, String>"));
    let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    assert!(lib.contains("#[napi(constructor)]") && lib.contains("inner: port::LruCache"));

    // Record scenarios (the TS uses parameter properties: Node needs to transform it).
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 150,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!(recorded.cases, 300);
    // A JS stand-in with an LRU bug: `get` does not refresh recency.
    std::fs::write(
        dir.join("index.cjs"),
        "class TextStats { constructor(s = '\\n') { this.s = s; this.w = 0; this.l = 0; this.long = '' }\n\
         add(t) { const p = t.split(this.s); this.l += p.length; for (const x of p) for (const w of x.split(/\\s+/).filter(Boolean)) { this.w++; if (w.length > this.long.length) this.long = w } return this.w }\n\
         stats() { return { words: this.w, lines: this.l } } longestWord() { return this.long } reset() { this.w = 0; this.l = 0; this.long = '' } }\n\
         class LruCache { constructor(c) { if (!(c >= 1)) throw new RangeError('x'); this.c = c; this.m = new Map() }\n\
         get(k) { return this.m.get(k) }\n\
         set(k, v) { this.m.delete(k); this.m.set(k, v); const e = []; while (this.m.size > this.c) { const o = this.m.keys().next().value; this.m.delete(o); e.push(o) } return e }\n\
         keys() { return [...this.m.keys()] } }\n\
         module.exports = { TextStats, LruCache }\n",
    )
    .unwrap();
    let diff = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    assert!(diff.failed > 0, "the recency bug must show up");
    assert!(diff.mismatches.iter().all(|m| m["fn"] == "LruCache"));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn recording_substitutes_typescript_extensions_from_emitted_module_imports() {
    if !common::have("node") {
        return;
    }
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-ts-extensions-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(root.join("esm.mts"), "export const value: number = 2;").unwrap();
    std::fs::write(
        root.join("common.cts"),
        "module.exports = 40 satisfies number;",
    )
    .unwrap();
    std::fs::write(
        root.join("main.mts"),
        "import { value } from './esm.mjs'; import common from './common.cjs'; export function answer(): number { return value + common; }",
    )
    .unwrap();
    let dir = root.join("bridge");
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "main.mts",
        kind: Some(Kind::Napi),
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
    let result = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 1,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    });
    let evidence = std::fs::read_to_string(dir.join(harness::CASES));
    std::fs::remove_dir_all(root).unwrap();
    result.unwrap();
    assert!(evidence.unwrap().contains(r#""ok":42"#));
}

#[test]
fn tsconfig_aliases_are_followed() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/aliases");
    let report = mojo_anything::analyze::analyze(&root).unwrap();
    let greet = report
        .units
        .iter()
        .find(|u| u.id == "src/greet.ts")
        .unwrap();
    assert_eq!(greet.internal_deps, ["src/lib/", "src/util/"]);
    if !common::have("node") {
        return;
    }
    let dir = std::env::temp_dir().join(format!("mojo-anything-alias-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/greet.ts",
        kind: Some(Kind::Napi),
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
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 5,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!((recorded.cases - recorded.traps, recorded.errors), (5, 0));
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn record_prefers_an_exact_tsconfig_alias_to_a_matching_wildcard() {
    if !common::have("node") {
        return;
    }
    let root =
        std::env::temp_dir().join(format!("mojo-anything-exact-alias-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(root.join("src")).unwrap();
    std::fs::write(root.join("package.json"), r#"{"type":"module"}"#).unwrap();
    std::fs::write(
        root.join("tsconfig.json"),
        r#"{"compilerOptions":{"paths":{"@demo*":["./src/wild*"],"@demo":["./src/exact.ts"]}}}"#,
    )
    .unwrap();
    std::fs::write(root.join("src/wild.ts"), "export const value = 'wild';").unwrap();
    std::fs::write(root.join("src/exact.ts"), "export const value = 'exact';").unwrap();
    std::fs::write(
        root.join("src/main.ts"),
        "import { value } from '@demo'; export function selected(): string { return value; }",
    )
    .unwrap();
    let dir = root.join("bridge");
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main.ts",
        kind: Some(Kind::Napi),
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
    let result = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 1,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    });
    let evidence = std::fs::read_to_string(dir.join(harness::CASES));
    std::fs::remove_dir_all(root).unwrap();
    result.unwrap();
    assert!(evidence.unwrap().contains(r#""ok":"exact""#));
}

#[test]
fn record_resolves_workspace_packages_to_source() {
    if !common::have("node") {
        return;
    }
    // `@m/b` imports `@m/a` by name; `@m/a` has no build output (`dist/` does not exist).
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/monorepo");
    let dir = std::env::temp_dir().join(format!("mojo-anything-monorepo-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "packages/b/src/titles.ts",
        kind: Some(Kind::Napi),
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
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 10,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!((recorded.cases - recorded.traps, recorded.errors), (10, 0));
    std::fs::remove_dir_all(&dir).unwrap();
}

fn error_checks(dir: &Path, fails: &str) -> Vec<mojo_anything::gate::Check> {
    let checks = mojo_anything::error_paths::checks(dir, &Manifest::load(dir).unwrap());
    let errors = &checks[0];
    assert_eq!(errors.name, "error cases");
    assert!(errors.passed, "{errors:?}");
    assert!(
        errors.detail.starts_with("each of the"),
        "{fails} fails in the original: {errors:?}"
    );
    checks
}

#[test]
fn c_bridge_string_helper_does_not_collide_with_source_names() {
    let root = std::env::temp_dir().join(format!("mojo-anything-c-names-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    std::fs::write(
        root.join("names.c"),
        "int c_str(const char *c_str) { return c_str != 0; }\n",
    )
    .unwrap();
    let dir = root.join("bridge");
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "names.c",
        kind: None,
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: Some(mojo_anything::lang::Lang::C),
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator: Default::default(),
    })
    .unwrap();
    let exports = std::fs::read_to_string(dir.join("exports.mojo")).unwrap();
    assert!(exports.contains("def c_str(a_c_str: "), "{exports}");
    // The drop-in library is not self-contained: the note says what it needs at run time.
    assert!(
        outcome
            .notes
            .iter()
            .any(|n| n.contains("libKGENCompilerRTShared")),
        "{:?}",
        outcome.notes
    );
    if common::have_mojo() {
        harness::build(&dir).unwrap();
    }
    std::fs::remove_dir_all(root).unwrap();
}

/// The Mojo port of `tests/fixtures/c/src/text.c`, with `vowels` forgetting upper case.
const C_TEXT_PORT: &str = "
def _space(b: UInt8) -> Bool:
    return b == 32 or (b >= 9 and b <= 13)


def count_words(s: Optional[Span[UInt8, ImmutAnyOrigin]]) -> UInt:
    if not s:
        return 0
    var b = s.value()
    var n: UInt = 0
    var inword = False
    for i in range(len(b)):
        if _space(b[i]):
            inword = False
        elif not inword:
            inword = True
            n += 1
    return n


def vowels(s: Optional[Span[UInt8, ImmutAnyOrigin]]) -> Int32:
    if not s:
        return -1
    var b = s.value()
    var n: Int32 = 0
    for i in range(len(b)):
        var c = b[i]
        if c == 97 or c == 101 or c == 105 or c == 111 or c == 117:
            n += 1
    return n


def is_palindrome(s: Optional[Span[UInt8, ImmutAnyOrigin]]) -> Bool:
    if not s:
        return False
    var b = s.value()
    for i in range(len(b) // 2):
        if b[i] != b[len(b) - 1 - i]:
            return False
    return True
";

#[test]
fn c_units_bridge_record_and_diff() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/c");
    let dir = std::env::temp_dir().join(format!("mojo-anything-c-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/text.c",
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
    assert_eq!(outcome.kind, Kind::CAbi);
    let manifest = Manifest::load(&dir).unwrap();
    // A returned pointer needs an ownership design: it stays in C.
    let kept: Vec<&str> = manifest.js_only.iter().map(|j| j.name.as_str()).collect();
    assert_eq!(kept, ["upper_copy"]);
    let exports = std::fs::read_to_string(dir.join("exports.mojo")).unwrap();
    assert!(
        exports.contains(
            "def count_words(a_s: Optional[Pointer[Int8, ImmutAnyOrigin]]) abi(\"C\") -> UInt:"
        ),
        "{exports}"
    );
    let header = std::fs::read_to_string(dir.join("include/text_mojo.h")).unwrap();
    assert!(
        header.contains("bool is_palindrome(const char *s);"),
        "{header}"
    );
    if !(common::have("cc") && common::have("python3") && common::have_mojo()) {
        return;
    }
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 40,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!(recorded.cases - recorded.traps, 120);
    // `vowels` forgets upper case: the diff must notice.
    let stubs = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    let head = stubs.split("\n\n# Port of").next().unwrap();
    std::fs::write(dir.join("port.mojo"), format!("{head}\n{C_TEXT_PORT}")).unwrap();
    harness::build(&dir).unwrap();
    let diff = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    assert!(diff.missing.is_empty());
    assert!(diff.failed > 0 && diff.failed < 40, "{diff:?}");
    assert!(
        diff.mismatches.iter().all(|m| m["fn"] == "vowels"),
        "{diff:?}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn go_packages_bridge_record_and_diff() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/go");
    let dir = std::env::temp_dir().join(format!("mojo-anything-go-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "strkit/",
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
    assert_eq!(outcome.kind, Kind::Ffi);
    let manifest = Manifest::load(&dir).unwrap();
    let kept: Vec<&str> = manifest.js_only.iter().map(|j| j.name.as_str()).collect();
    assert_eq!(kept, ["Join"]);
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    assert!(
        port.contains("def parse_port(s: String) raises -> Int:"),
        "{port}"
    );
    assert!(
        port.contains("def midpoint(a: JsonValue, b: JsonValue) raises -> JsonValue:"),
        "{port}"
    );
    let wrapper = std::fs::read_to_string(dir.join("go/strkit.go")).unwrap();
    assert!(
        wrapper.contains("func ParsePort(raArg0 string) (int, error) {"),
        "{wrapper}"
    );
    assert!(wrapper.contains("type Point struct"), "{wrapper}");
    assert!(!dir.join("Cargo.toml").exists());
    // Batches for Go come after correctness, and a refused batch leaves the unit as it was.
    let err = bridge::add_batches(&dir, &["Slugify:s".into()])
        .unwrap_err()
        .to_string();
    assert!(err.contains("not yet"), "{err}");
    assert!(Manifest::load(&dir).unwrap().batches.is_empty());
    if !common::have("go") || !common::have_mojo() {
        return;
    }
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 30,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert!(recorded.cases > 100, "{recorded:?}");
    assert!(recorded.errors > 0, "ParsePort returns errors");
    assert!(error_checks(&dir, "ParsePort")[1].passed);
    // A port where every function fails: the diff must run through the Go wrapper and say so.
    harness::build(&dir).unwrap();
    let diff = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!(diff.passed, 0, "{diff:?}");
    assert_eq!(diff.total, recorded.cases);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn ruby_modules_bridge_record_and_diff() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ruby");
    let dir = std::env::temp_dir().join(format!("mojo-anything-ruby-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "lib/textkit/",
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
    assert_eq!(outcome.kind, Kind::Ffi);
    let manifest = Manifest::load(&dir).unwrap();
    let kept: Vec<&str> = manifest.js_only.iter().map(|j| j.name.as_str()).collect();
    assert_eq!(kept, ["each_word"]);
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    // YARD types, a literal default kept as a plain value, and `nil` as an Optional.
    assert!(
        port.contains("def slugify(text: String, sep: String, max: Optional[Int]) raises"),
        "{port}"
    );
    let wrapper = std::fs::read_to_string(dir.join("ruby/textkit_mojo.rb")).unwrap();
    assert!(
        wrapper.contains("def self.slugify(text, sep = \"-\", max: nil)"),
        "{wrapper}"
    );
    assert!(
        wrapper.contains("MojoAnythingNativeTextkitMojo.call(\"slugify\", text, sep, max)"),
        "{wrapper}"
    );
    // Batches for Ruby come after correctness.
    let err = bridge::add_batches(&dir, &["slugify:text".into()])
        .unwrap_err()
        .to_string();
    assert!(err.contains("not yet"), "{err}");
    if !common::have("ruby") || !common::have_mojo() {
        return;
    }
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 30,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert!(recorded.cases > 100, "{recorded:?}");
    // `page_count` raises ArgumentError for a non-positive page size.
    assert!(recorded.errors > 0);
    assert!(error_checks(&dir, "the fixture")[1].passed);
    harness::build(&dir).unwrap();
    let diff = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    // Unported functions raise `not ported: ...`, which never matches.
    assert_eq!(diff.passed, 0, "{diff:?}");
    assert_eq!(diff.total, recorded.cases);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn java_classes_bridge_record_and_diff() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/java");
    let dir = std::env::temp_dir().join(format!("mojo-anything-java-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main/java/com/example/text/",
        kind: None,
        out: Some(dir.clone()),
        name: Some("text-rs".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator: Default::default(),
    })
    .unwrap();
    assert_eq!(outcome.kind, Kind::Ffi);
    let port = std::fs::read_to_string(dir.join("src/port.rs")).unwrap();
    assert!(
        port.contains("pub fn parse_port(text: String) -> Result<i64, String>"),
        "{port}"
    );
    let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    assert!(
        lib.contains("fn Java_mojoanything_TextRsNative_call"),
        "{lib}"
    );
    let wrapper = std::fs::read_to_string(dir.join("java/com/example/text/Strings.java")).unwrap();
    assert!(
        wrapper.contains("public static List<String> words(String text)"),
        "{wrapper}"
    );
    // Batches: a list result cannot be batched; the others get a class beside the original.
    assert!(bridge::add_batches(&dir, &["words:text".into()]).is_err());
    bridge::add_batches(&dir, &["slugify:text".into(), "pages:total".into()]).unwrap();
    let batch =
        std::fs::read_to_string(dir.join("java/com/example/text/SlugifyBatch.java")).unwrap();
    assert!(
        batch.contains("public final class SlugifyBatch implements AutoCloseable"),
        "{batch}"
    );
    assert!(batch.contains("public String[] run(int max)"), "{batch}");
    let pages = std::fs::read_to_string(dir.join("java/com/example/text/PagesBatch.java")).unwrap();
    assert!(
        pages.contains("public int[] rank(int perPage, double min)"),
        "{pages}"
    );
    let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    assert!(
        lib.contains("fn Java_com_example_text_SlugifyBatch_nRun"),
        "{lib}"
    );
    if !common::have("javac") {
        return;
    }
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 30,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert!(recorded.cases > 100, "{recorded:?}");
    // `parsePort` throws NumberFormatException for text.
    assert!(recorded.errors > 0);
    assert!(error_checks(&dir, "the fixture")[1].passed);
    harness::build(&dir).unwrap();
    let diff = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    // Unported functions panic, which Java sees as a RuntimeException: nothing can match.
    assert_eq!(diff.passed, 0, "{diff:?}");
    assert_eq!(diff.total, recorded.cases);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn kotlin_functions_bridge_record_and_diff() {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/kotlin");
    let dir = std::env::temp_dir().join(format!("mojo-anything-kotlin-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main/kotlin/com/example/text/",
        kind: None,
        out: Some(dir.clone()),
        name: Some("text-rs".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator: Default::default(),
    })
    .unwrap();
    assert_eq!(outcome.kind, Kind::Ffi);
    let port = std::fs::read_to_string(dir.join("src/port.rs")).unwrap();
    assert!(
        port.contains("pub fn slugify(text: String, max: i64) -> Result<String, String>"),
        "{port}"
    );
    let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    assert!(
        lib.contains("fn Java_mojoanything_TextRsNative_call"),
        "{lib}"
    );
    // Kotlin type names must become Java ones, or javac rejects the wrapper.
    let wrapper =
        std::fs::read_to_string(dir.join("java/com/example/text/StringsKt.java")).unwrap();
    assert!(
        wrapper.contains("public static String slugify(String text, int max)"),
        "{wrapper}"
    );
    assert!(
        wrapper.contains("public static Map<String, Integer> frequencies(String text)"),
        "{wrapper}"
    );
    let nums = std::fs::read_to_string(dir.join("java/com/example/text/Nums.java")).unwrap();
    assert!(
        nums.contains("public static long gcd(long a, long b)"),
        "{nums}"
    );
    if !common::have("kotlinc") || !common::have("javac") {
        return;
    }
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 10,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert!(recorded.cases > 50, "{recorded:?}");
    // `pages` divides by zero for a generated per-page of 0.
    assert!(recorded.errors > 0, "{recorded:?}");
    harness::build(&dir).unwrap();
    let diff = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    // Unported functions panic, which Java sees as a RuntimeException: nothing can match.
    assert_eq!(diff.passed, 0, "{diff:?}");
    assert_eq!(diff.total, recorded.cases);
    let _ = std::fs::remove_dir_all(&dir);
}

/// The Android half: build the same JNI crate for an Android ABI and install it into `jniLibs/`.
/// Skips when there is no NDK or the Rust target is missing, as CI usually has neither.
#[test]
fn android_build_installs_a_jni_library() {
    let Ok(ndk) = mojo_anything::android::ndk_root(None) else {
        return;
    };
    let installed = Command::new("rustup")
        .args(["target", "list", "--installed"])
        .output()
        .ok()
        .filter(|o| o.status.success())
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let Some(abi) = mojo_anything::android::DEFAULT_ABIS
        .iter()
        .find(|abi| installed.lines().any(|l| l.trim() == abi.triple()))
    else {
        return;
    };
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/kotlin");
    let dir = std::env::temp_dir().join(format!(
        "mojo-anything-android-{}-{}",
        std::process::id(),
        abi.name()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main/kotlin/com/example/text/",
        kind: None,
        out: Some(dir.clone()),
        name: Some("text-rs".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator: Default::default(),
    })
    .unwrap();
    // Also exercise --jni-libs: Gradle's default is src/main/jniLibs, not the crate root.
    let jni_libs = dir.join("libs");
    let report = harness::build_android(
        &dir,
        &mojo_anything::android::Options {
            abis: vec![abi.name().into(), abi.name().into()], // duplicate ABIs build once
            api: mojo_anything::android::DEFAULT_API,
            ndk: None,
            out: Some(jni_libs),
        },
    )
    .unwrap();
    assert_eq!(report.ndk, ndk);
    assert_eq!(report.libraries.len(), 1, "{report:?}");
    let library = &report.libraries[0];
    assert_eq!(library.abi, abi.name());
    assert!(library.path.is_file(), "{library:?}");
    assert!(
        library
            .path
            .ends_with(format!("libs/{}/libtext_rs.so", abi.name())),
        "{library:?}"
    );
    // call + the five exported functions.
    assert_eq!(library.entry_points, 6, "{library:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn batches_keep_items_in_rust() {
    let dir = bridged("batch");
    std::fs::write(
        dir.join("src/port.rs"),
        "pub fn range_of(text: String, word: String) -> Result<serde_json::Value, String> { let _ = (text, word); Ok(serde_json::Value::Null) }\n\
         pub fn words(text: String) -> Vec<String> { vec![text] }\n\
         pub fn count(text: String) -> f64 { text.matches(' ').count() as f64 }\n",
    )
    .unwrap();
    // Structured results cannot be batched, and a refused batch leaves the crate as it was.
    let refused = bridge::add_batches(&dir, &["rangeOf:text".into()]).unwrap_err();
    assert!(
        format!("{refused:#}").contains("numbers, booleans or strings"),
        "{refused:#}"
    );
    assert!(Manifest::load(&dir).unwrap().batches.is_empty());
    assert!(bridge::add_batches(&dir, &["count:nope".into()]).is_err());

    bridge::add_batches(&dir, &["count:text".into()]).unwrap();
    let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    assert!(lib.contains("#[napi(js_name = \"CountBatch\")]"), "{lib}");
    assert!(lib.contains("pub struct CountDefaultIndex"));
    assert!(lib.contains("par_iter()"), "napi batches run on all cores");
    assert!(
        lib.contains("Float64Array"),
        "number results cross as one typed array"
    );
    assert!(lib.contains("pub fn rank("));
    let cargo = std::fs::read_to_string(dir.join("Cargo.toml")).unwrap();
    assert!(cargo.contains("rayon"));

    // An index in port.rs replaces the default one.
    let mut port = std::fs::read_to_string(dir.join("src/port.rs")).unwrap();
    port.push_str(
        "pub struct CountIndex(Vec<String>);\n\
         impl CountIndex {\n    pub fn new(items: Vec<String>) -> Self { Self(items) }\n    \
         pub fn run(&self) -> Result<Vec<f64>, String> { Ok(self.0.iter().map(|t| count(t.clone())).collect()) }\n}\n",
    );
    std::fs::write(dir.join("src/port.rs"), port).unwrap();
    bridge::refresh(&dir).unwrap();
    let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    assert!(lib.contains("inner: port::CountIndex,"));
    assert!(!lib.contains("CountDefaultIndex"));
    assert!(
        lib.contains("self.inner.run()"),
        "no `rank` of its own yet: {lib}"
    );
    // An index with its own `rank` (say, narrowing as the user types) is called for `rank`.
    let mut port = std::fs::read_to_string(dir.join("src/port.rs")).unwrap();
    port = port.replace(
        "    pub fn run(&self)",
        "    pub fn rank(&self, min: f64) -> Result<Vec<u32>, String> {\n        let _ = min;\n        Ok(Vec::new())\n    }\n    pub fn run(&self)",
    );
    std::fs::write(dir.join("src/port.rs"), port).unwrap();
    bridge::refresh(&dir).unwrap();
    let lib = std::fs::read_to_string(dir.join("src/lib.rs")).unwrap();
    assert!(lib.contains("self.inner.rank(min)"), "{lib}");
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn diff_compares_own_proto_named_properties_in_arguments_and_results() {
    if !common::have("node") {
        return;
    }
    let dir = bridged("proto-properties");
    std::fs::write(
        dir.join(harness::CASES),
        r#"{"fn":"echo","args":[{"__proto__":{"value":1}}],"ok":{"__proto__":{"value":1}}}"#,
    )
    .unwrap();
    let module = dir.join("index.cjs");
    let opts = DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    };
    std::fs::write(
        &module,
        "exports.echo = x => Object.hasOwn(x, '__proto__') ? x : {}",
    )
    .unwrap();
    let matching = harness::diff(&opts).unwrap();
    std::fs::write(&module, "exports.echo = () => ({})").unwrap();
    let changed = harness::diff(&opts).unwrap();
    std::fs::remove_dir_all(dir).unwrap();
    assert_eq!(matching.passed, 1);
    assert_eq!(changed.failed, 1);
}

/// A crate for `util.ts` with a `count:text` batch, bridged as `kind` with `allocator`.
fn batch_crate(name: &str, kind: Kind, allocator: bridge::Allocator) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-anything-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "packages/a/src/util.ts",
        kind: Some(kind),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator,
    })
    .unwrap();
    std::fs::write(
        dir.join("src/port.rs"),
        "pub fn count(text: String) -> f64 { text.matches(' ').count() as f64 }\n",
    )
    .unwrap();
    bridge::add_batches(&dir, &["count:text".into()]).unwrap();
    dir
}

#[test]
fn batches_use_the_chosen_allocator() {
    let read = |dir: &Path, file: &str| std::fs::read_to_string(dir.join(file)).unwrap();

    // The default stays mimalloc, and the manifest does not mention it.
    let dir = batch_crate("alloc-mi", Kind::Napi, bridge::Allocator::Mimalloc);
    assert!(read(&dir, "src/lib.rs").contains("static GLOBAL: mimalloc::MiMalloc"));
    assert!(read(&dir, "Cargo.toml").contains("mimalloc = \"0.1\""));
    assert!(!read(&dir, "mojo-anything.json").contains("allocator"));
    std::fs::remove_dir_all(&dir).unwrap();

    // rusty_alloc replaces it, and `refresh` keeps the choice from the manifest.
    let dir = batch_crate("alloc-ra", Kind::Napi, bridge::Allocator::RustyAlloc);
    for _ in 0..2 {
        let lib = read(&dir, "src/lib.rs");
        assert!(
            lib.contains(
                "static GLOBAL: rusty_alloc_api::RustyAlloc = rusty_alloc_api::RustyAlloc;"
            ),
            "{lib}"
        );
        assert!(!lib.contains("mimalloc"), "{lib}");
        let cargo = read(&dir, "Cargo.toml");
        assert!(cargo.contains("rusty_alloc-api = \"2.6\""), "{cargo}");
        assert!(!cargo.contains("mimalloc"), "{cargo}");
        assert!(read(&dir, "mojo-anything.json").contains("\"allocator\": \"rusty_alloc\""));
        assert_eq!(
            Manifest::load(&dir).unwrap().allocator,
            bridge::Allocator::RustyAlloc
        );
        bridge::refresh(&dir).unwrap();
    }
    std::fs::remove_dir_all(&dir).unwrap();

    // wasm keeps Rust's allocator under the default, and takes rusty_alloc when asked.
    let dir = batch_crate("alloc-wasm-mi", Kind::Wasm, bridge::Allocator::Mimalloc);
    assert!(!read(&dir, "src/lib.rs").contains("global_allocator"));
    assert!(!read(&dir, "Cargo.toml").contains("mimalloc"));
    std::fs::remove_dir_all(&dir).unwrap();
    let dir = batch_crate("alloc-wasm-ra", Kind::Wasm, bridge::Allocator::RustyAlloc);
    assert!(read(&dir, "src/lib.rs").contains("static GLOBAL: rusty_alloc_api::RustyAlloc"));
    assert!(read(&dir, "Cargo.toml").contains("rusty_alloc-api"));
    std::fs::remove_dir_all(&dir).unwrap();

    // Without batches there is no global allocator to choose.
    let dir = std::env::temp_dir().join(format!("mojo-anything-alloc-none-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "packages/a/src/util.ts",
        kind: Some(Kind::Napi),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
        allocator: bridge::Allocator::RustyAlloc,
    })
    .unwrap();
    assert!(!read(&dir, "src/lib.rs").contains("global_allocator"));
    assert!(!read(&dir, "Cargo.toml").contains("rusty_alloc"));
    std::fs::remove_dir_all(&dir).unwrap();
}

/// `util.ts` bridged to a Mojo port behind the Node-API addon.
fn bridged_mojo(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-anything-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "packages/a/src/util.ts",
        kind: Some(Kind::MojoNode),
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

#[test]
fn ts_mojo_bridge_files() {
    let dir = bridged_mojo("ts-mojo-files");
    for f in [
        "port.mojo",
        "dispatcher.mojo",
        "json.mojo",
        "node_shim.c",
        "binding.gyp",
        "index.cjs",
        "pixi.toml",
        "mojo-anything.json",
        "README.md",
    ] {
        assert!(dir.join(f).is_file(), "{f}");
    }
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    assert!(
        port.contains("def range_of(text: String, word: String) raises -> JsonValue:"),
        "{port}"
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn ts_mojo_loop_matches() {
    if !(common::have("node") && common::have("cc") && common::have_mojo()) {
        return;
    }
    let dir = bridged_mojo("ts-mojo-loop");
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 120,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mini-mojo-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    harness::build(&dir).unwrap();
    let outcome = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!(
        (outcome.passed, outcome.failed),
        (recorded.cases, 0),
        "{:#?}",
        outcome.mismatches
    );
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn ts_mojo_shadow_reports_mismatch() {
    if !(common::have("node") && common::have("cc") && common::have_mojo()) {
        return;
    }
    let dir = bridged_mojo("ts-mojo-shadow");
    // The fixture port, with `count` miscounting tabs as spaces.
    let port = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mini-mojo-port/port.mojo"),
    )
    .unwrap()
    .replace("if c == 32:", "if c == 32 or c == 9:");
    std::fs::write(dir.join("port.mojo"), port).unwrap();
    harness::build(&dir).unwrap();
    let out = shadow::shadow(&dir, None).unwrap();
    let file = out.path.file_name().unwrap().to_string_lossy().into_owned();
    assert!(!file.contains("-mojo"), "{file}");
    let script = dir.join("use.ts");
    std::fs::write(
        &script,
        format!(
            "import {{ count, shadowStats, onMismatch }} from '{}'\n\
             const seen: string[] = []\n\
             onMismatch(m => seen.push(m.fn))\n\
             console.log(JSON.stringify([count('a b'), count('a\\tb'), shadowStats.calls, seen]))\n",
            out.path.display()
        ),
    )
    .unwrap();
    let run = |mode: &str| {
        let o = Command::new("node")
            .arg(&script)
            .env("MOJO_ANYTHING_MODE", mode)
            .output()
            .unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
        String::from_utf8_lossy(&o.stdout).trim().to_string()
    };
    assert_eq!(run("shadow"), r#"[1,0,2,["count"]]"#);
    // New: the Mojo port answers, bug included.
    assert_eq!(run("new"), r#"[1,1,0,[]]"#);
    std::fs::remove_dir_all(&dir).unwrap();
}

/// The Task 3 unit with the fixture port, recorded and built.
fn gated_mojo(name: &str) -> PathBuf {
    let dir = bridged_mojo(name);
    harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 60,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mini-mojo-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    dir
}

#[test]
fn ts_mojo_gate_passes() {
    if !(common::have("node") && common::have("cc") && common::have_mojo()) {
        return;
    }
    let dir = gated_mojo("ts-mojo-gate");
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    assert!(gate.passed, "{:#?}", gate.checks);
    let names: Vec<&str> = gate.checks.iter().map(|c| c.name).collect();
    for name in [
        "mojo format",
        "ported",
        "unsafe",
        "size",
        "build",
        "api",
        "behavior",
    ] {
        assert!(names.contains(&name), "{name}: {names:?}");
    }
    let size = gate.checks.iter().find(|c| c.name == "size").unwrap();
    assert!(size.detail.contains("lines of Mojo for"), "{}", size.detail);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn ts_mojo_gate_fails_on_missing_export() {
    if !(common::have("node") && common::have("cc") && common::have_mojo()) {
        return;
    }
    let dir = gated_mojo("ts-mojo-gate-missing");
    let index = dir.join("index.cjs");
    let text = std::fs::read_to_string(&index).unwrap();
    let kept: Vec<&str> = text
        .lines()
        .filter(|l| !l.starts_with("  count: ["))
        .collect();
    assert!(kept.len() < text.lines().count(), "{text}");
    std::fs::write(&index, kept.join("\n") + "\n").unwrap();
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    assert!(!gate.passed);
    let api = gate.checks.iter().find(|c| c.name == "api").unwrap();
    assert!(!api.passed, "{api:?}");
    assert!(api.detail.contains("count"), "{}", api.detail);
    let fix = api.fix.as_deref().unwrap_or_default();
    assert!(fix.contains("mojo-anything refresh"), "{fix}");
    assert!(!fix.contains("src/port.rs"), "{fix}");
    std::fs::remove_dir_all(&dir).unwrap();
}
