//! The bridge -> record -> diff -> shadow loop on the fixture repo.
//!
//! A hand-written JS module stands in for the built port, so most of these tests check the
//! harness itself without compiling one. They need `node` on PATH.

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
        kind: Some(Kind::MojoNode),
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
fn bridge_writes_a_crate_and_never_overwrites_it() {
    let dir = bridged("bridge");
    let manifest = Manifest::load(&dir).unwrap();
    let names: Vec<&str> = manifest.exports.iter().map(|f| f.name.as_str()).collect();
    assert_eq!(names, ["rangeOf", "words", "count"]);
    assert!(dir.join("port.mojo").is_file() && dir.join("index.cjs").is_file());
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
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
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
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
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
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    // Classes are not ported to Mojo yet: they stay in TS, so `gate`, `diff` and the shadow do
    // not expect them from the generated `index.cjs`, which exports no class.
    assert!(
        outcome
            .notes
            .iter()
            .any(|n| n.contains("`LruCache` stays in") && n.contains("not ported to Mojo yet")),
        "{:?}",
        outcome.notes
    );
    let manifest = Manifest::load(&dir).unwrap();
    assert!(manifest.classes.is_empty(), "{:?}", manifest.classes);
    for name in ["TextStats", "LruCache"] {
        assert!(
            manifest
                .js_only
                .iter()
                .any(|j| j.name == name && j.reason.contains("not ported to Mojo yet")),
            "{name}: {:?}",
            manifest.js_only
        );
    }
    assert!(
        manifest
            .js_only
            .iter()
            .any(|j| j.name == "Blocked" && j.reason.contains("extends"))
    );
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
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
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
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
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
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
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
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
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
fn kotlin_functions_bridge_record_and_diff() {
    // Bridging a Kotlin unit needs Java 22 or newer.
    if !common::have_java() {
        return;
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/kotlin");
    let dir = std::env::temp_dir().join(format!("mojo-anything-kotlin-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main/kotlin/com/example/text/",
        kind: None,
        out: Some(dir.clone()),
        name: Some("text-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    assert_eq!(outcome.kind, Kind::MojoJvm);
    for rust in ["Cargo.toml", "src"] {
        assert!(!dir.join(rust).exists(), "{rust}");
    }
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    for sig in [
        "def slugify(text: String, max: Int32) raises -> String:",
        "def words(text: String) raises -> List[String]:",
        "def frequencies(text: String) raises -> JsonValue:",
        "def gcd(a: Int64, b: Int64) raises -> Int64:",
        "def pages(total: Int32, per_page: Int32) raises -> Int32:",
    ] {
        assert!(port.contains(sig), "{sig}\n{port}");
    }
    let native =
        std::fs::read_to_string(dir.join("java/mojoanything/TextMojoNative.java")).unwrap();
    assert!(native.contains("java.lang.foreign"), "{native}");
    // Kotlin type names must become Java ones, or javac rejects the wrapper; top-level
    // functions live on `StringsKt`, `@JvmStatic` members of `object Nums` on `Nums`.
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
    assert!(
        wrapper.contains("TextMojoNative.invoke(\"slugify\""),
        "{wrapper}"
    );
    let nums = std::fs::read_to_string(dir.join("java/com/example/text/Nums.java")).unwrap();
    assert!(
        nums.contains("public static long gcd(long a, long b)"),
        "{nums}"
    );
    if !common::have("kotlinc") || !common::have_mojo() {
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
    let opts = DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    };
    // The stubs raise `not ported: ...`, which never matches.
    harness::build(&dir).unwrap();
    let stubs = harness::diff(&opts).unwrap();
    assert_eq!(stubs.passed, 0, "{stubs:?}");
    assert_eq!(stubs.total, recorded.cases);
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/kotlin-mojo-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    let diff = harness::diff(&opts).unwrap();
    assert_eq!(diff.failed, 0, "{diff:?}");
    assert_eq!(diff.passed, recorded.cases, "{diff:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// A top-level function (owner `TextKt`), a companion object's `@JvmStatic` member (owner
/// `Units`) and a nested object's (owner `Shapes$Sign`) in one Kotlin file: all three bridge,
/// record and replay through the Mojo port.
#[test]
fn kotlin_top_level_and_companion_replay() {
    if !common::have_java() {
        return;
    }
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let dir = std::env::temp_dir().join(format!(
        "mojo-anything-kotlin-owners-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &fixtures.join("kotlin-owners"),
        unit: "src/main/kotlin/com/example/owners/Text.kt",
        kind: None,
        out: Some(dir.clone()),
        name: Some("owners-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    assert_eq!(outcome.kind, Kind::MojoJvm);
    let mut exports = outcome.exports.clone();
    exports.sort();
    assert_eq!(exports, ["parse", "sign", "slug"]);
    let m = Manifest::load(&dir).unwrap();
    let owner = |name: &str| {
        let f = m.exports.iter().find(|f| f.name == name).unwrap();
        mojo_anything::lang::java::receiver(f).0
    };
    assert_eq!(owner("slug"), "com.example.owners.TextKt");
    assert_eq!(owner("parse"), "com.example.owners.Units");
    assert_eq!(owner("sign"), "com.example.owners.Shapes$Sign");
    let sign =
        std::fs::read_to_string(dir.join("java/com/example/owners/Shapes$Sign.java")).unwrap();
    assert!(sign.contains("public static long sign(long n) {"), "{sign}");
    let text = std::fs::read_to_string(dir.join("java/com/example/owners/TextKt.java")).unwrap();
    assert!(
        text.contains("public static String slug(String s) {"),
        "{text}"
    );
    let units = std::fs::read_to_string(dir.join("java/com/example/owners/Units.java")).unwrap();
    assert!(
        units.contains("public static long parse(String s) {"),
        "{units}"
    );
    if !common::have("kotlinc") || !common::have_mojo() {
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
    for name in ["slug", "parse", "sign"] {
        assert!(
            recorded.per_function.get(name).copied().unwrap_or(0) > 10,
            "{recorded:?}"
        );
    }
    // Most generated text is not a number: `parse` throws NumberFormatException.
    assert!(recorded.errors > 0, "{recorded:?}");
    std::fs::copy(
        fixtures.join("kotlin-mojo-port/owners.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    let diff = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!(diff.failed, 0, "{diff:?}");
    assert_eq!(diff.passed, recorded.cases, "{diff:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

/// `tests/fixtures/kotlin-owners`' unit bridged to Mojo in a fresh folder.
fn kotlin_owners_bridged(tag: &str) -> PathBuf {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/kotlin-owners");
    let dir = std::env::temp_dir().join(format!(
        "mojo-anything-kotlin-owners-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main/kotlin/com/example/owners/Text.kt",
        kind: None,
        out: Some(dir.clone()),
        name: Some("owners-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    assert_eq!(outcome.kind, Kind::MojoJvm);
    dir
}

/// Runs `cmd` and returns its stdout, failing the test with its output when it fails.
fn stdout_of(cmd: &mut Command) -> String {
    let out = cmd.output().unwrap();
    assert!(
        out.status.success(),
        "{cmd:?}\n{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8(out.stdout).unwrap()
}

/// Every `.java` file under `dir`.
fn java_sources(dir: &Path) -> Vec<PathBuf> {
    let mut sources = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "java") {
                sources.push(p);
            }
        }
    }
    sources
}

/// A Kotlin caller compiled against the original classes prints the same against the wrappers.
/// Kotlin calls a companion object's `@JvmStatic` member through the companion
/// (`getstatic Units.Companion`, then `invokevirtual Units$Companion.parse`), so a wrapper with
/// the static method alone fails at link time with `NoSuchFieldError`. `Units()` needs the
/// implicit public constructor, and `Shapes.Sign.sign` the class `Shapes$Sign`; the original
/// classes are not on the wrappers' class path, so a call that missed the wrappers fails.
#[test]
fn kotlin_caller_links_against_the_wrappers() {
    if !common::have_java() || !common::have("kotlinc") || !common::have_mojo() {
        return;
    }
    let fixtures = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    let dir = kotlin_owners_bridged("caller");
    std::fs::copy(
        fixtures.join("kotlin-mojo-port/owners.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    bridge::refresh(&dir).unwrap();
    let lib = harness::build(&dir).unwrap();
    let check = dir.join("check");
    std::fs::create_dir_all(&check).unwrap();
    let original = check.join("original.jar");
    stdout_of(
        Command::new("kotlinc")
            .arg(fixtures.join("kotlin-owners/src/main/kotlin/com/example/owners/Text.kt"))
            .arg("-d")
            .arg(&original),
    );
    std::fs::write(
        check.join("Caller.kt"),
        r#"import com.example.owners.Shapes
import com.example.owners.Units
import com.example.owners.slug

fun main() {
    println(slug("a b c"))
    println(Units.parse(" 42 "))
    println(Units.Companion.parse("-7"))
    println(Units().javaClass.name)
    println(Shapes.Sign.sign(-5))
    println(Shapes.Sign.sign(9))
    try {
        Units.parse("x")
    } catch (e: NumberFormatException) {
        println("NumberFormatException: ${e.message}")
    }
}
"#,
    )
    .unwrap();
    let caller = check.join("caller.jar");
    stdout_of(
        Command::new("kotlinc")
            .arg("-cp")
            .arg(&original)
            .arg(check.join("Caller.kt"))
            .arg("-include-runtime")
            .arg("-d")
            .arg(&caller),
    );
    let wrappers = check.join("wrappers");
    stdout_of(
        Command::new("javac")
            .args(["-encoding", "UTF-8", "-nowarn", "-d"])
            .arg(&wrappers)
            .args(java_sources(&dir.join("java"))),
    );
    let run = |classes: &Path| {
        stdout_of(
            Command::new("java")
                .args([
                    "-XX:-UsePerfData",
                    "--enable-native-access=ALL-UNNAMED",
                    "-Dfile.encoding=UTF-8",
                    "-cp",
                ])
                .arg(std::env::join_paths([caller.as_path(), classes]).unwrap())
                .arg("CallerKt")
                .env("MOJO_ANYTHING_LIB", &lib),
        )
    };
    let expected = run(&original);
    assert!(
        expected.contains("\n42\n-7\ncom.example.owners.Units\n-1\n1\n"),
        "{expected}"
    );
    assert_eq!(run(&wrappers), expected);
    let _ = std::fs::remove_dir_all(&dir);
}

/// `java api` compares the owner class's fields and nested classes too: a wrapper without the
/// `Companion` field that Kotlin callers read fails it.
#[test]
fn kotlin_java_api_checks_the_companion() {
    if !common::have_java() || !common::have("kotlinc") || !common::have_mojo() {
        return;
    }
    let dir = kotlin_owners_bridged("gate");
    let path = dir.join("java/com/example/owners/Units.java");
    let units = std::fs::read_to_string(&path).unwrap();
    let field = "    public static final Companion Companion = new Companion();\n";
    assert!(units.contains(field), "{units}");
    let api = |dir: &Path| {
        let gate = mojo_anything::gate::gate(dir, &[]).unwrap();
        gate.checks
            .into_iter()
            .find(|c| c.name == "java api")
            .unwrap()
    };
    let passing = api(&dir);
    assert!(passing.passed, "{passing:?}");
    assert!(
        passing.detail.contains("Units.Companion"),
        "{}",
        passing.detail
    );
    std::fs::write(&path, units.replace(field, "")).unwrap();
    let failing = api(&dir);
    assert!(!failing.passed, "{failing:?}");
    assert!(
        failing.detail.contains("Units.Companion"),
        "{}",
        failing.detail
    );
    let _ = std::fs::remove_dir_all(&dir);
}

/// The wrapper replaces the whole class, so `java api` fails naming every public member of the
/// original that it does not keep: a constant and a generic method the bridge leaves out.
#[test]
fn java_api_names_members_the_wrapper_drops() {
    if !common::have_java() || !common::have_mojo() {
        return;
    }
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/java-members");
    let dir =
        std::env::temp_dir().join(format!("mojo-anything-java-members-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main/java/com/example/members/",
        kind: None,
        out: Some(dir.clone()),
        name: Some("members-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    assert_eq!(outcome.exports, ["twice"]);
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    let api = gate.checks.iter().find(|c| c.name == "java api").unwrap();
    assert!(!api.passed, "{api:?}");
    assert!(api.detail.contains("Limits.MAX"), "{}", api.detail);
    assert!(api.detail.contains("Limits.id"), "{}", api.detail);
    assert!(!api.detail.contains("Limits.twice"), "{}", api.detail);
    let fix = api.fix.as_deref().unwrap_or_default();
    assert!(fix.contains("port"), "{fix}");
    assert!(fix.contains("move"), "{fix}");
    // The bridge says so too: the class is replaced, `id` does not stay in Java.
    let notes = outcome.notes.join("\n");
    assert!(notes.contains("`id`"), "{notes}");
    assert!(notes.contains("java api"), "{notes}");
    assert!(!notes.contains("stays in Java"), "{notes}");
    let _ = std::fs::remove_dir_all(&dir);
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

/// The addon finds a missing library when it is loaded, so the shadow runs the original alone
/// with its "module not loaded" warning instead of reporting every call as a mismatch.
#[test]
fn shadow_falls_back_when_library_is_missing() {
    if !(common::have("node") && common::have("cc") && common::have_mojo()) {
        return;
    }
    let dir = bridged_mojo("ts-mojo-no-lib");
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/mini-mojo-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    harness::build(&dir).unwrap();
    let mut removed = 0;
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if name.starts_with("lib") && (name.ends_with(".so") || name.ends_with(".dylib")) {
            std::fs::remove_file(&path).unwrap();
            removed += 1;
        }
    }
    assert_eq!(removed, 1, "the built library in {}", dir.display());
    let out = shadow::shadow(&dir, None).unwrap();
    let script = dir.join("use.ts");
    std::fs::write(
        &script,
        format!(
            "import {{ count, shadowStats }} from '{}'\n\
             console.log(JSON.stringify([count('a b'), count('a\\tb'), shadowStats]))\n",
            out.path.display()
        ),
    )
    .unwrap();
    let o = Command::new("node")
        .arg(&script)
        .env("MOJO_ANYTHING_MODE", "shadow")
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&o.stderr);
    assert!(o.status.success(), "{stderr}");
    assert_eq!(
        String::from_utf8_lossy(&o.stdout).trim(),
        r#"[1,0,{"calls":0,"mismatches":0}]"#,
        "{stderr}"
    );
    assert!(stderr.contains("Mojo module not loaded"), "{stderr}");
    let text = std::fs::read_to_string(&out.path).unwrap();
    assert!(
        !text.contains("Rust"),
        "the shadow still says Rust:\n{text}"
    );
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

// ---- Java units ported to Mojo (`mojo-jvm`) ----------------------------------------------------

/// `tests/fixtures/java`'s text unit bridged to Mojo in a fresh folder.
fn java_mojo_bridged(tag: &str) -> PathBuf {
    let root = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/java");
    let dir = std::env::temp_dir().join(format!(
        "mojo-anything-java-mojo-{tag}-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main/java/com/example/text/",
        kind: None,
        out: Some(dir.clone()),
        name: Some("text-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    assert_eq!(outcome.kind, Kind::MojoJvm);
    dir
}

fn java_mojo_record(dir: &Path) -> harness::RecordOutcome {
    harness::record(&RecordOptions {
        crate_dir: dir,
        count: 30,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap()
}

fn java_mojo_diff(dir: &Path) -> anyhow::Result<harness::DiffOutcome> {
    harness::diff(&DiffOptions {
        crate_dir: dir,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
}

/// The fixture's Mojo port in place of the stubs, with the bindings regenerated.
fn java_mojo_port(dir: &Path) {
    std::fs::copy(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/java-mojo-port/port.mojo"),
        dir.join("port.mojo"),
    )
    .unwrap();
    bridge::refresh(dir).unwrap();
}

#[test]
fn java_mojo_bridge_files() {
    if !common::have_java() {
        return;
    }
    let dir = java_mojo_bridged("files");
    for file in [
        "port.mojo",
        "dispatcher.mojo",
        "json.mojo",
        "pixi.toml",
        "mojo-anything.json",
        "README.md",
        "java/mojoanything/TextMojoNative.java",
        "java/mojoanything/MojoAnythingJson.java",
        "java/mojoanything/MojoAnythingError.java",
        "java/com/example/text/Strings.java",
        "java/com/example/text/Nums.java",
    ] {
        assert!(dir.join(file).is_file(), "{file}");
    }
    for rust in ["Cargo.toml", "src"] {
        assert!(!dir.join(rust).exists(), "{rust}");
    }
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    for sig in [
        "def slugify(text: String, max: Int32) raises -> String:",
        "def words(text: String) raises -> List[String]:",
        "def frequencies(text: String) raises -> JsonValue:",
        "def parse_port(text: String) raises -> Int32:",
        "def gcd(a: Int64, b: Int64) raises -> Int64:",
        "def mean(values: List[Float64]) raises -> Float64:",
        "def pages(total: Int32, per_page: Int32) raises -> Int32:",
    ] {
        assert!(port.contains(sig), "{sig}\n{port}");
    }
    let native =
        std::fs::read_to_string(dir.join("java/mojoanything/TextMojoNative.java")).unwrap();
    assert!(native.contains("java.lang.foreign"), "{native}");
    let pixi = std::fs::read_to_string(dir.join("pixi.toml")).unwrap();
    assert!(pixi.contains("emberjson"), "{pixi}");
    let manifest = std::fs::read_to_string(dir.join("mojo-anything.json")).unwrap();
    assert!(manifest.contains("\"kind\": \"mojo-jvm\""), "{manifest}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn java_mojo_loop_matches() {
    if !common::have_java() || !common::have_mojo() {
        return;
    }
    let dir = java_mojo_bridged("loop");
    let recorded = java_mojo_record(&dir);
    assert!(recorded.cases > 100, "{recorded:?}");
    // `parsePort` throws NumberFormatException and `pages` ArithmeticException.
    assert!(recorded.errors > 0, "{recorded:?}");
    // The stubs raise `not ported: ...`, which never matches.
    harness::build(&dir).unwrap();
    let stubs = java_mojo_diff(&dir).unwrap();
    assert_eq!(stubs.passed, 0, "{stubs:?}");
    java_mojo_port(&dir);
    harness::build(&dir).unwrap();
    let out = java_mojo_diff(&dir).unwrap();
    assert_eq!(out.failed, 0, "{out:?}");
    assert_eq!(out.passed, recorded.cases, "{out:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn java_mojo_rebuild_after_edit() {
    if !common::have_java() || !common::have_mojo() {
        return;
    }
    let dir = java_mojo_bridged("rebuild");
    let recorded = java_mojo_record(&dir);
    java_mojo_port(&dir);
    harness::build(&dir).unwrap();
    assert_eq!(java_mojo_diff(&dir).unwrap().passed, recorded.cases);
    // A wrong gcd: diff refuses the stale library, and after a build it mismatches.
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    let wrong = port.replace(
        "        y = t\n    return x\n",
        "        y = t\n    return x + 1\n",
    );
    assert_ne!(port, wrong);
    std::fs::write(dir.join("port.mojo"), wrong).unwrap();
    let stale = java_mojo_diff(&dir).unwrap_err().to_string();
    assert!(stale.contains("mojo-anything build"), "{stale}");
    harness::build(&dir).unwrap();
    let out = java_mojo_diff(&dir).unwrap();
    assert!(out.failed > 0, "{out:?}");
    assert!(
        out.mismatches.iter().all(|m| m["fn"] == "gcd"),
        "{:?}",
        out.mismatches
    );
    assert_eq!(out.passed + out.failed, recorded.cases);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn java_mojo_gate_passes() {
    if !common::have_java() || !common::have_mojo() {
        return;
    }
    let dir = java_mojo_bridged("gate");
    java_mojo_record(&dir);
    java_mojo_port(&dir);
    // The Task 3 matching unit, built: the build makes the unit's pixi environment, which
    // `mojo format` would otherwise wait for within its one-minute limit.
    harness::build(&dir).unwrap();
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    assert!(gate.passed, "{:#?}", gate.checks);
    let api = gate.checks.iter().find(|c| c.name == "java api").unwrap();
    assert!(api.passed, "{api:?}");
    assert!(api.detail.contains("Nums.gcd"), "{}", api.detail);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn java_mojo_gate_fails_on_changed_signature() {
    if !common::have_java() || !common::have_mojo() {
        return;
    }
    let dir = java_mojo_bridged("gate-signature");
    java_mojo_port(&dir);
    // A wrapper edited by hand: `gcd` now returns `int`. Callers compiled against the
    // original's `long gcd(long, long)` would not link against it.
    let nums = dir.join("java/com/example/text/Nums.java");
    let text = std::fs::read_to_string(&nums).unwrap();
    let edited = text.replace(
        "public static long gcd(long a, long b) {\n        return (Long)",
        "public static int gcd(long a, long b) {\n        return (int) (long) (Long)",
    );
    assert_ne!(text, edited, "{text}");
    std::fs::write(&nums, edited).unwrap();
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    assert!(!gate.passed);
    let api = gate.checks.iter().find(|c| c.name == "java api").unwrap();
    assert!(!api.passed, "{api:?}");
    assert!(api.detail.contains("gcd"), "{}", api.detail);
    assert!(api.detail.contains("(JJ)I"), "{}", api.detail);
    let fix = api.fix.as_deref().unwrap_or_default();
    assert!(fix.contains("mojo-anything refresh"), "{fix}");
    // `refresh` writes the wrapper back with the original signature.
    bridge::refresh(&dir).unwrap();
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    let api = gate.checks.iter().find(|c| c.name == "java api").unwrap();
    assert!(api.passed, "{api:?}");
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn jvm_parallel_calls_match() {
    if !common::have_java() || !common::have_mojo() {
        return;
    }
    let dir = java_mojo_bridged("parallel");
    java_mojo_port(&dir);
    let lib = harness::build(&dir).unwrap();
    let check = dir.join("check");
    std::fs::create_dir_all(&check).unwrap();
    std::fs::write(
        check.join("Parallel.java"),
        r#"import com.example.text.Nums;
import com.example.text.Strings;
import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.atomic.AtomicInteger;

public class Parallel {
    static String input(int i) {
        return "Hello, Wörld " + (i % 97) + " ΣΑΣ " + "x".repeat(i % 13);
    }

    public static void main(String[] args) throws Exception {
        int calls = 10_000;
        String[] slugs = new String[calls];
        int[] hashes = new int[calls];
        long[] gcds = new long[calls];
        for (int i = 0; i < calls; i++) {
            slugs[i] = Strings.slugify(input(i), i % 7);
            hashes[i] = Strings.hash(input(i));
            gcds[i] = Nums.gcd(i * 6L, 4_000L);
        }
        AtomicInteger wrong = new AtomicInteger();
        List<Thread> threads = new ArrayList<>();
        for (int t = 0; t < 8; t++) {
            final int offset = t * 1_237;
            Thread thread = new Thread(() -> {
                for (int k = 0; k < calls; k++) {
                    int i = (k + offset) % calls;
                    if (!Strings.slugify(input(i), i % 7).equals(slugs[i])
                        || Strings.hash(input(i)) != hashes[i]
                        || Nums.gcd(i * 6L, 4_000L) != gcds[i]) {
                        wrong.incrementAndGet();
                    }
                }
            });
            threads.add(thread);
            thread.start();
        }
        for (Thread thread : threads) {
            thread.join();
        }
        System.out.println(wrong.get() == 0 ? "same" : wrong.get() + " differ");
    }
}
"#,
    )
    .unwrap();
    let classes = check.join("classes");
    let mut sources = vec![check.join("Parallel.java")];
    let mut stack = vec![dir.join("java")];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                stack.push(p);
            } else if p.extension().is_some_and(|x| x == "java") {
                sources.push(p);
            }
        }
    }
    let javac = Command::new("javac")
        .args(["-encoding", "UTF-8", "-nowarn", "-d"])
        .arg(&classes)
        .args(&sources)
        .output()
        .unwrap();
    assert!(
        javac.status.success(),
        "{}",
        String::from_utf8_lossy(&javac.stderr)
    );
    let run = Command::new("java")
        .args([
            "-XX:-UsePerfData",
            "--enable-native-access=ALL-UNNAMED",
            "-Dfile.encoding=UTF-8",
        ])
        .arg(format!("-Dmojo-anything.lib.text_mojo={}", lib.display()))
        .arg("-cp")
        .arg(&classes)
        .arg("Parallel")
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&run.stdout);
    let stderr = String::from_utf8_lossy(&run.stderr);
    assert_eq!(stdout.trim(), "same", "{stdout}{stderr}");
    // No restricted-method warning reaches the output.
    assert!(!stderr.contains("WARNING"), "{stderr}");
    let _ = std::fs::remove_dir_all(&dir);
}
