//! Bridges built for real: compile the generated crate, load it from the original language and
//! replay the recording. Run on every CI platform, since linking differs between them.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge::{self, Kind};
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

fn project(name: &str, files: &[(&str, &str)]) -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-native-{name}-{}",
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

/// A freshly bridged crate is all `unimplemented!` stubs: replaying it must pass no case, even
/// where the original throws the same kind of error a panic turns into.
fn stubs_fail(root: &Path, unit: &str, kind: Option<Kind>, program: &str) {
    if !common::have(program) {
        return;
    }
    // Go, Ruby and TS/JS units are Mojo ports.
    if matches!(program, "go" | "ruby" | "node") && !common::have_mojo() {
        return;
    }
    let dir = std::env::temp_dir().join(format!(
        "mojo-anything-stubs-{}-{}",
        root.file_name().unwrap().to_string_lossy(),
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root,
        unit,
        kind,
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
        count: 20,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert!(
        recorded.errors > 0,
        "{}: no recorded case throws, so this proves nothing",
        root.display()
    );
    harness::build(&dir).unwrap();
    let outcome = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        node_args: &[],
        float_tolerance: None,
    })
    .unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(outcome.passed, 0, "a stub matched {outcome:#?}");
}

fn fixture(name: &str) -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/fixtures")
        .join(name)
}

#[test]
fn unported_stubs_never_match_in_typescript() {
    // Every call of  throws in the original (no such file); the Mojo stub raises too.
    stubs_fail(
        &fixture("mini"),
        "packages/a/src/fs.ts",
        Some(Kind::MojoNode),
        "node",
    );
}

#[test]
fn unported_stubs_never_match_in_python() {
    let Some(python) = common::python() else {
        return;
    };
    if !mojo_anything::mojo::available() {
        return;
    }
    stubs_fail(&fixture("python"), "src/textkit/", None, python);
}

#[test]
fn unported_stubs_never_match_a_ruby_runtime_error() {
    if cfg!(windows) {
        eprintln!(
            "skipped: RubyInstaller's Ruby is built with MinGW, and an MSVC Rust extension cannot load into it"
        );
        return;
    }
    let root = project(
        "stubs-ruby",
        &[
            ("shout.gemspec", ""),
            (
                "lib/shout.rb",
                "module Shout\n  def self.shout(s)\n    raise \"empty\" if s.empty?\n    s + \"!\"\n  end\nend\n",
            ),
        ],
    );
    stubs_fail(&root, "lib/shout.rb", None, "ruby");
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn unported_stubs_never_match_a_java_runtime_exception() {
    let root = project(
        "stubs-java",
        &[
            (
                "pom.xml",
                "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>com.example</groupId>\n  <artifactId>shout</artifactId>\n  <version>0.1.0</version>\n</project>\n",
            ),
            (
                "src/main/java/com/example/shout/Shout.java",
                "package com.example.shout;\n\npublic final class Shout {\n    public static String shout(String s) {\n        if (s.isEmpty()) {\n            throw new RuntimeException(\"empty\");\n        }\n        return s + \"!\";\n    }\n}\n",
            ),
        ],
    );
    stubs_fail(&root, "src/main/java/com/example/shout/", None, "java");
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn unported_stubs_never_match_a_go_panic() {
    let root = project(
        "stubs-go",
        &[
            ("go.mod", "module example.com/shout\n\ngo 1.22\n"),
            (
                "shout/shout.go",
                "package shout\n\nfunc Shout(s string) string {\n\tif s == \"\" {\n\t\tpanic(\"empty\")\n\t}\n\treturn s + \"!\"\n}\n",
            ),
        ],
    );
    stubs_fail(&root, "shout/", None, "go");
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn java_records_with_the_bridge_crate_inside_the_project() {
    if !common::have("javac") {
        return;
    }
    let root = project(
        "java-default-out",
        &[
            (
                "pom.xml",
                "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n  <modelVersion>4.0.0</modelVersion>\n  <groupId>com.example</groupId>\n  <artifactId>smoke</artifactId>\n  <version>0.1.0</version>\n</project>\n",
            ),
            (
                "src/main/java/com/example/smoke/TextKit.java",
                "package com.example.smoke;\n\npublic final class TextKit {\n    public static int wordCount(String s) {\n        return s.isBlank() ? 0 : s.trim().split(\"\\\\s+\").length;\n    }\n}\n",
            ),
        ],
    );
    let outcome = bridge::bridge(&bridge::Options {
        root: &root,
        unit: "src/main/java/com/example/smoke/",
        kind: None,
        out: None,
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap();
    assert!(outcome.crate_dir.ends_with("rust/smoke-rs"), "{outcome:?}");
    let recorded = harness::record(&RecordOptions {
        crate_dir: &outcome.crate_dir,
        count: 10,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    std::fs::remove_dir_all(&root).unwrap();
    assert!(recorded.cases > 0, "{recorded:?}");
}

fn bridge_python(root: &Path, unit: &str) -> anyhow::Result<bridge::Outcome> {
    bridge::bridge(&bridge::Options {
        root,
        unit,
        kind: None,
        out: Some(root.join("port")),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })
}

#[test]
fn a_name_defined_twice_in_a_unit_is_refused() {
    let root = project(
        "twice",
        &[
            (
                "pyproject.toml",
                "[project]\nname = \"hp\"\nversion = \"0.1.0\"\n",
            ),
            (
                "hp/__init__.py",
                "from . import verdict as _v\n\ndef verdict(*args, **options):\n    return _v.verdict(*args, **options)\n",
            ),
            (
                "hp/verdict.py",
                "def verdict(score: int) -> str:\n    return \"ok\" if score > 0 else \"no\"\n",
            ),
        ],
    );
    let err = bridge_python(&root, "hp/").unwrap_err();
    std::fs::remove_dir_all(&root).unwrap();
    let text = format!("{err:#}");
    assert!(text.contains("`verdict` is defined twice"), "{text}");
    assert!(
        text.contains("hp/__init__.py") && text.contains("hp/verdict.py"),
        "{text}"
    );
}

#[test]
fn cli_entry_points_stay_in_python() {
    let root = project(
        "entry",
        &[
            (
                "pyproject.toml",
                "[project]\nname = \"tool\"\nversion = \"0.1.0\"\n",
            ),
            (
                "tool/cli.py",
                "import argparse\n\n\
                 def build_parser() -> argparse.ArgumentParser:\n    return argparse.ArgumentParser()\n\n\
                 def shout(text: str) -> str:\n    return text.upper()\n\n\
                 def main() -> int:\n    build_parser().parse_args()\n    return 0\n\n\
                 if __name__ == \"__main__\":\n    raise SystemExit(main())\n",
            ),
        ],
    );
    let outcome = bridge_python(&root, "tool/").unwrap();
    let manifest = mojo_anything::bridge::Manifest::load(&outcome.crate_dir).unwrap();
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(outcome.exports, ["shout"]);
    let kept: Vec<&str> = manifest.js_only.iter().map(|j| j.name.as_str()).collect();
    assert_eq!(kept, ["build_parser", "main"]);
    assert!(
        manifest.js_only[0]
            .reason
            .contains("command-line entry point")
    );
}

#[test]
fn dataclass_parameters_get_real_instances() {
    if !common::have("python3") {
        return;
    }
    let root = project(
        "dataclass",
        &[
            (
                "pyproject.toml",
                "[project]\nname = \"clip\"\nversion = \"0.1.0\"\n",
            ),
            ("clip/__init__.py", ""),
            (
                "clip/models.py",
                "from dataclasses import dataclass\n\n\
                 @dataclass\nclass Limits:\n    low: int\n    high: int = 10\n",
            ),
            (
                "clip/ops.py",
                "from .models import Limits\n\n\
                 def clamp(value: int, limits: Limits) -> int:\n    return max(limits.low, min(value, limits.high))\n",
            ),
        ],
    );
    let outcome = bridge_python(&root, "clip/").unwrap();
    harness::record(&RecordOptions {
        crate_dir: &outcome.crate_dir,
        count: 40,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    let cases = std::fs::read_to_string(outcome.crate_dir.join("cases.jsonl")).unwrap();
    std::fs::remove_dir_all(&root).unwrap();
    let with_instance = cases
        .lines()
        .filter_map(|l| serde_json::from_str::<serde_json::Value>(l).ok())
        .filter(|c| c["fn"] == "clamp")
        .filter(|c| c["args"][1]["$object"] == "Limits" && c.get("ok").is_some())
        .count();
    assert!(
        with_instance >= 5,
        "only {with_instance} clamp cases ran with a real Limits instance:\n{cases}"
    );
}

#[test]
fn one_file_of_a_unit_can_be_bridged_alone() {
    if !common::have("python3") {
        return;
    }
    let root = project(
        "one-file",
        &[
            (
                "pyproject.toml",
                "[project]\nname = \"pkg\"\nversion = \"0.1.0\"\n",
            ),
            ("pkg/__init__.py", ""),
            (
                "pkg/core.py",
                "def score(text: str) -> int:\n    return len(text.split())\n",
            ),
            (
                "pkg/tool.py",
                "def helper(path: str) -> str:\n    return open(path).read()\n",
            ),
        ],
    );
    let outcome = bridge_python(&root, "pkg/core.py").unwrap();
    assert_eq!(outcome.exports, ["score"]);
    let manifest = mojo_anything::bridge::Manifest::load(&outcome.crate_dir).unwrap();
    assert_eq!(manifest.unit, "pkg/core.py");
    let recorded = harness::record(&RecordOptions {
        crate_dir: &outcome.crate_dir,
        count: 10,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    let missing = bridge_python(&root, "pkg/nope.py").unwrap_err();
    std::fs::remove_dir_all(&root).unwrap();
    assert!(recorded.cases > 0, "{recorded:?}");
    assert!(format!("{missing:#}").contains("no unit or source file"));
}

fn have_node_mojo() -> bool {
    common::have("node") && common::have("cc") && common::have_mojo()
}

/// Bridge `unit` as a Mojo port behind the Node-API addon, put `port` in place and build.
fn mojo_node_unit(root: &Path, unit: &str, port: &str) -> PathBuf {
    let dir = root.join("port");
    bridge::bridge(&bridge::Options {
        root,
        unit,
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
    std::fs::write(dir.join("port.mojo"), port).unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    dir
}

#[test]
fn node_addon_loads_from_unicode_path() {
    if !have_node_mojo() {
        return;
    }
    let root = project(
        "node path with spaces ünïcøde",
        &[
            ("package.json", r#"{"name":"shout","version":"0.1.0"}"#),
            (
                "src/shout.ts",
                "export function shout(text: string): string {\n  return text + \"!\";\n}\n",
            ),
        ],
    );
    let dir = mojo_node_unit(
        &root,
        "src/shout.ts",
        "def shout(text: String) raises -> String:\n    return text + \"!\"\n",
    );
    let recorded = harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 30,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    let outcome = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        node_args: &[],
        float_tolerance: None,
    })
    .unwrap();
    std::fs::remove_dir_all(&root).unwrap();
    assert!(recorded.cases > 0);
    assert_eq!(
        (outcome.passed, outcome.failed),
        (outcome.total, 0),
        "{:#?}",
        outcome.mismatches
    );
}

#[test]
fn node_errors_keep_their_class_and_async_rejects() {
    if !have_node_mojo() {
        return;
    }
    let root = project(
        "node-errors",
        &[
            ("package.json", r#"{"name":"guard","version":"0.1.0"}"#),
            (
                "src/guard.ts",
                "export function check(text: string): string {\n  if (text === '') throw new TypeError('empty');\n  return text;\n}\n\
                 export async function later(text: string): Promise<string> {\n  return text;\n}\n",
            ),
        ],
    );
    let dir = mojo_node_unit(
        &root,
        "src/guard.ts",
        "def check(text: String) raises -> String:\n    if text.byte_length() == 0:\n        raise Error(\"TypeError: empty\")\n    return text\n\n\n\
         def later(text: String) raises -> String:\n    return text\n",
    );
    let script = r#"
const m = require(process.argv[1])
const out = []
try { m.check('') } catch (e) { out.push(e instanceof TypeError, e.message) }
try { m.check('a\uD800') } catch (e) { out.push(e instanceof TypeError && /lone surrogate/.test(e.message)) }
let threw = false
const p = (() => { try { return m.later(5) } catch { threw = true } })()
out.push(!threw && p instanceof Promise)
;(p ? p.catch(e => e.code) : Promise.resolve(null)).then(code => {
  out.push(code)
  return m.later('x')
}).then(x => { out.push(x); console.log(JSON.stringify(out)) })
"#;
    let output = Command::new("node")
        .args(["-e", script])
        .arg(dir.join("index.cjs"))
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    std::fs::remove_dir_all(&root).unwrap();
    // `later(5)` passes a number for a string: the dispatcher answers with a panic, and the
    // promise rejects with it instead of throwing.
    assert_eq!(
        stdout.trim(),
        r#"[true,"empty",true,true,"MOJO_PANIC","x"]"#,
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn node_carries_markers_through_mojo() {
    if !have_node_mojo() {
        return;
    }
    let root = project(
        "node-markers",
        &[
            ("package.json", r#"{"name":"same","version":"0.1.0"}"#),
            (
                "src/same.ts",
                "export function same(v: unknown): unknown { return v }\n",
            ),
        ],
    );
    let dir = mojo_node_unit(
        &root,
        "src/same.ts",
        "from json import JsonValue\n\n\ndef same(v: JsonValue) raises -> JsonValue:\n    return v.copy()\n",
    );
    let script = r#"
const { same } = require(process.argv[1])
const when = new Date('2024-02-29T12:00:00.000Z')
const bytes = same(new Uint8Array([0, 7, 255]))
console.log(JSON.stringify([
  same(undefined) === undefined,
  Object.is(same(NaN), NaN),
  Object.is(same(-0), -0),
  same(Infinity) === Infinity,
  same(9007199254740993n) === 9007199254740993n,
  same(when) instanceof Date && same(when).getTime() === when.getTime(),
  [...same(new Map([['a', 1]]))].join(),
  [...same(new Set(['x', 'y']))].join(),
  bytes instanceof Uint8Array && [...bytes].join(),
  same('a\uD800') === 'a\uD800',
  Object.is(same({ k: undefined, n: [1.5, -0] }).n[1], -0),
]))
"#;
    let output = Command::new("node")
        .args(["-e", script])
        .arg(dir.join("index.cjs"))
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(
        stdout.trim(),
        r#"[true,true,true,true,true,true,"a,1","x,y","0,7,255",true,true]"#,
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
}

/// Bridge `unit` as a Mojo port with `batch`, put `port` in place and build.
fn mojo_node_batch_unit(root: &Path, unit: &str, batch: &str, port: &str) -> PathBuf {
    let dir = root.join("port");
    bridge::bridge(&bridge::Options {
        root,
        unit,
        kind: Some(Kind::MojoNode),
        out: Some(dir.clone()),
        name: None,
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: vec![batch.into()],
        as_json: Vec::new(),
    })
    .unwrap();
    std::fs::write(dir.join("port.mojo"), port).unwrap();
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    dir
}

fn run_node(dir: &Path, script: &str) -> String {
    let output = Command::new("node")
        .args(["-e", script])
        .arg(dir.join("index.cjs"))
        .output()
        .unwrap();
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout).trim(),
        String::from_utf8_lossy(&output.stderr)
    )
}

const LABEL_MOJO: &str = "from json import JsonValue\n\n\n\
    def label(n: Float64, options: Optional[JsonValue]) raises -> String:\n    \
    var text = String(Int(n)) if n == Float64(Int(n)) else String(n)\n    \
    var long = False\n    \
    if options:\n        \
    ref o = options.value()\n        \
    if o.is_object() and \"long\" in o.object():\n            \
    ref v = o.object()[\"long\"]\n            \
    long = v.is_bool() and v.bool()\n    \
    return text + \" units\" if long else text + \"u\"\n";

#[test]
fn node_batches_take_structured_parameters() {
    if !have_node_mojo() {
        return;
    }
    let root = project(
        "node-batch-options",
        &[
            ("package.json", r#"{"name":"fmt","version":"0.1.0"}"#),
            (
                "src/fmt.ts",
                "export function label(n: number, options?: { long?: boolean }): string {\n  return options?.long ? `${n} units` : `${n}u`;\n}\n",
            ),
        ],
    );
    let dir = mojo_node_batch_unit(&root, "src/fmt.ts", "label:n", LABEL_MOJO);
    let out = run_node(
        &dir,
        r#"
const { LabelBatch, label } = require(process.argv[1])
const batch = new LabelBatch([1, 2])
const refused = [() => new LabelBatch(3), () => new LabelBatch([1, '2'])].map(f => { try { f(); return 'no' } catch (e) { return e.name } })
console.log(JSON.stringify([batch.run(), batch.run({ long: true }), batch instanceof LabelBatch, refused, label(3)]))
"#,
    );
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(
        out,
        r#"[["1u","2u"],["1 units","2 units"],true,["TypeError","TypeError"],"3u"]"#
    );
}

#[test]
fn node_string_batches_cross_joined() {
    if !have_node_mojo() {
        return;
    }
    let root = project(
        "node-batch-strings",
        &[
            ("package.json", r#"{"name":"wrap","version":"0.1.0"}"#),
            (
                "src/wrap.ts",
                "export function wrap(s: string): number {\n  return s.length;\n}\n",
            ),
        ],
    );
    let dir = mojo_node_batch_unit(
        &root,
        "src/wrap.ts",
        "wrap:s",
        "def wrap(s: String) raises -> Float64:\n    return Float64(s.byte_length())\n",
    );
    let out = run_node(
        &dir,
        r#"
const { WrapBatch } = require(process.argv[1])
const batch = new WrapBatch(['', 'a', 'é', '😀x', 'ascii only'])
const refused = [() => new WrapBatch('ab'), () => new WrapBatch(['a', 1]), () => new WrapBatch(['b\uD800c'])].map(f => { try { f(); return 'no' } catch (e) { return e.name } })
console.log(JSON.stringify([batch.run(), batch.rank(2), refused, new WrapBatch([]).run()]))
"#,
    );
    std::fs::remove_dir_all(&root).unwrap();
    // `rank(min)`: the indexes of results at least `min`, best first, ties in item order.
    assert_eq!(
        out,
        r#"[[0,1,2,5,10],[4,3,2],["TypeError","TypeError","TypeError"],[]]"#
    );
}

#[test]
fn node_batch_handle_freed() {
    if !have_node_mojo() {
        return;
    }
    let root = project(
        "node-batch-free",
        &[
            ("package.json", r#"{"name":"fmt","version":"0.1.0"}"#),
            (
                "src/fmt.ts",
                "export function label(n: number, options?: { long?: boolean }): string {\n  return options?.long ? `${n} units` : `${n}u`;\n}\n",
            ),
        ],
    );
    let dir = mojo_node_batch_unit(&root, "src/fmt.ts", "label:n", LABEL_MOJO);
    let out = run_node(
        &dir,
        r#"
const { LabelBatch } = require(process.argv[1])
const batch = new LabelBatch([1])
batch.free()
try { batch.run() } catch (e) { console.log(e.constructor.name, e.message) }
"#,
    );
    std::fs::remove_dir_all(&root).unwrap();
    assert_eq!(out, "Error LabelBatch was freed");
}
