//! C++ units through the C ABI shim: `tests/fixtures/cpp` bridged, recorded through
//! `cpp/shim.cpp`, ported to Mojo, diffed, gated and benchmarked, and a C++ caller compiled
//! against the original header linked against `cpp/wrapper.cpp` and the Mojo library.
//! Skips without a C++ compiler, Python or Mojo.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge;
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

const PORT: &str = r#"from std.math import sqrt


def add(a: Int32, b: Int32) -> Int32:
    return a + b


def wide(a: Int64, b: Int64) -> Int64:
    return a * b


def wrap(a: UInt32, b: UInt32) -> UInt32:
    return a - b


def count_bytes(s: String) -> UInt:
    return UInt(s.byte_length())


def half(x: Float32) -> Float32:
    return x / 2


def mean(xs: List[Float64]) -> Float64:
    var sum: Float64 = 0
    for i in range(len(xs)):
        sum += xs[i]
    if len(xs) == 0:
        return 0
    return sum / Float64(len(xs))


def evens(xs: List[Int32]) -> List[Int32]:
    var out = List[Int32]()
    for i in range(len(xs)):
        if xs[i] % 2 == 0:
            out.append(xs[i])
    return out^


def scale(xs: List[Float64], k: Float64) -> List[Float64]:
    var out = List[Float64]()
    for i in range(len(xs)):
        out.append(xs[i] * k)
    return out^


def is_upper(s: String) -> Bool:
    var b = s.as_bytes()
    for i in range(len(b)):
        if b[i] >= 97 and b[i] <= 122:
            return False
    return len(b) > 0


def shout(s: String) -> String:
    var b = s.as_bytes()
    var out = List[UInt8](capacity=len(b) + 1)
    for i in range(len(b)):
        var c = b[i]
        out.append(c - 32 if c >= 97 and c <= 122 else c)
    out.append(33)
    # SAFETY: the input's UTF-8 with ASCII letters changed and `!` added is UTF-8.
    return String(unsafe_from_utf8=Span(out))


def checked_sqrt(x: Float64) raises -> Float64:
    if x < 0:
        raise Error("std::domain_error: negative input")
    return sqrt(x)


def touch():
    pass


def join(xs: List[Int64], sep: String) -> String:
    var out = String()
    for i in range(len(xs)):
        if i > 0:
            out += sep
        out += String(xs[i])
    return out
"#;

const INPUTS: &str = r#"{"fn": "kit::add", "args": [2147483647, 1]}
{"fn": "kit::add", "args": [-2, 3]}
{"fn": "kit::wide", "args": [9223372036854775807, 2]}
{"fn": "kit::wrap", "args": [0, 1]}
{"fn": "kit::count_bytes", "args": ["héllo"]}
{"fn": "kit::count_bytes", "args": [""]}
{"fn": "kit::half", "args": [0.1]}
{"fn": "kit::mean", "args": [[1, 2, 4]]}
{"fn": "kit::mean", "args": [[]]}
{"fn": "kit::mean", "args": [[0.1, 0.2]]}
{"fn": "kit::evens", "args": [[1, 2, 3, 4, -6]]}
{"fn": "kit::evens", "args": [[]]}
{"fn": "kit::scale", "args": [[1.5, -2, {"$num": "-0"}], 3]}
{"fn": "kit::scale", "args": [[], 3]}
{"fn": "kit::is_upper", "args": ["ABC"]}
{"fn": "kit::is_upper", "args": ["AbC"]}
{"fn": "kit::is_upper", "args": [""]}
{"fn": "kit::shout", "args": ["hi there"]}
{"fn": "kit::shout", "args": [""]}
{"fn": "kit::shout", "args": ["a\u0000b é"]}
{"fn": "kit::checked_sqrt", "args": [2]}
{"fn": "kit::checked_sqrt", "args": [-1]}
{"fn": "kit::touch", "args": []}
{"fn": "kit::text::join", "args": [[1, -2, 9223372036854775807], ", "]}
{"fn": "kit::text::join", "args": [[], "-"]}
"#;

fn ready() -> bool {
    common::have("c++") && common::python().is_some() && common::have_mojo()
}

/// A copy of the fixture with its inputs (and a 3 MB string), to bridge into.
fn project(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-anything-cpp-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/cpp");
    std::fs::create_dir_all(dir.join("src")).unwrap();
    for f in [
        "CMakeLists.txt",
        "src/kit.hpp",
        "src/kit.cpp",
        "src/refused.cpp",
        "src/main.cpp",
    ] {
        std::fs::copy(fixture.join(f), dir.join(f)).unwrap();
    }
    let big = "x".repeat(3_000_000);
    std::fs::write(
        dir.join("inputs.jsonl"),
        format!("{INPUTS}{{\"fn\": \"kit::shout\", \"args\": [\"{big}\"]}}\n"),
    )
    .unwrap();
    dir
}

fn bridged(repo: &Path, unit: &str) -> bridge::Outcome {
    bridge::bridge(&bridge::Options {
        root: repo,
        unit,
        kind: None,
        out: None,
        name: None,
        force: true,
        keep: Vec::new(),
        lang: Some(mojo_anything::lang::Lang::Cpp),
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap()
}

fn record(dir: &Path, repo: &Path) {
    harness::record(&RecordOptions {
        crate_dir: dir,
        count: 0,
        inputs: Some(&repo.join("inputs.jsonl")),
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
}

/// Writes `port` in place of the stubs and builds.
fn ported(dir: &Path, port: &str) {
    let stubs = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    // The stubs' header, from the stubs or from a port written over them.
    let head = stubs.split("\n\n# Port of").next().unwrap();
    let head = head.split("from std.math import sqrt").next().unwrap();
    let head = head.replace("from std.os import abort\n", "");
    std::fs::write(dir.join("port.mojo"), format!("{head}{port}")).unwrap();
    bridge::refresh(dir).unwrap();
    harness::build(dir).unwrap();
}

fn diff(dir: &Path) -> harness::DiffOutcome {
    harness::diff(&DiffOptions {
        crate_dir: dir,
        module: None,
        ignore_key_order: false,
        node_args: &[],
        float_tolerance: None,
    })
    .unwrap()
}

#[test]
fn cpp_bridge_writes_the_unit_and_says_what_stays() {
    if !common::have("c++") {
        return;
    }
    let repo = project("bridge");
    let out = bridged(&repo, "src/kit.cpp");
    for f in [
        "port.mojo",
        "exports.mojo",
        "cpp/shim.cpp",
        "cpp/wrapper.cpp",
        "pixi.toml",
        "mojo-anything.json",
    ] {
        assert!(out.files.iter().any(|g| g == f), "{f} in {:?}", out.files);
        assert!(out.crate_dir.join(f).is_file(), "{f}");
    }
    assert_eq!(out.exports.len(), 13, "{:?}", out.exports);
    assert!(out.exports.contains(&"kit::text::join".to_string()));
    let manifest = std::fs::read_to_string(out.crate_dir.join("mojo-anything.json")).unwrap();
    assert!(manifest.contains("\"language\": \"cpp\""), "{manifest}");
    assert!(manifest.contains("\"kind\": \"c-abi\""), "{manifest}");

    let refused = bridged(&repo, "src/refused.cpp");
    assert_eq!(refused.exports, ["kept"]);
    let notes = refused.notes.join("\n");
    for says in [
        "`Counter` stays in C++: is a class: member functions do not cross",
        "`Meter::read` stays in C++: is a member function of `Meter`",
        "`twice` stays in C++: is a template",
        "`pick` stays in C++: is overloaded (2 definitions)",
        "`step` stays in C++: takes `EnergyPlusData &`, a state object",
        "`peek` stays in C++: takes `const EnergyPlusData *`, a pointer to a state object",
        "`take` stays in C++: takes an rvalue reference",
        "`name` stays in C++: returns a pointer (`const char *`)",
        "`fast` stays in C++: is `inline`",
        "`square` stays in C++: is `constexpr`",
    ] {
        assert!(notes.contains(says), "{says} in {notes}");
    }
    for slip in ["that that", "class: `"] {
        assert!(!notes.contains(slip), "{slip} in {notes}");
    }
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn cpp_every_type_round_trips() {
    if !ready() {
        return;
    }
    let repo = project("types");
    let dir = bridged(&repo, "src/kit.cpp").crate_dir;
    record(&dir, &repo);
    let cases = std::fs::read_to_string(dir.join(harness::CASES)).unwrap();
    for expected in [
        r#""fn": "kit::add", "args": [2147483647, 1], "ok": -2147483648"#,
        r#""fn": "kit::wide", "args": [9223372036854775807, 2], "ok": -2"#,
        r#""fn": "kit::wrap", "args": [0, 1], "ok": 4294967295"#,
        r#""args": ["héllo"], "ok": 6"#,
        r#""fn": "kit::half", "args": [0.1], "ok": 0.05000000074505806"#,
        r#""args": [[1, 2, 4]], "ok": 2.3333333333333335"#,
        r#""fn": "kit::mean", "args": [[]], "ok": 0.0"#,
        r#""args": [[1, 2, 3, 4, -6]], "ok": [2, 4, -6]"#,
        r#""args": [[1.5, -2, {"$num": "-0"}], 3], "ok": [4.5, -6.0, {"$num": "-0"}]"#,
        r#""args": [[], 3], "ok": []"#,
        r#""args": ["AbC"], "ok": false"#,
        r#""args": ["hi there"], "ok": "HI THERE!""#,
        r#""args": [""], "ok": "!""#,
        r#""args": ["a\u0000b é"], "ok": "A\u0000B é!""#,
        r#""fn": "kit::checked_sqrt", "args": [-1], "error": "std::domain_error: negative input""#,
        r#""fn": "kit::touch", "args": [], "ok": null"#,
        r#""args": [[1, -2, 9223372036854775807], ", "], "ok": "1, -2, 9223372036854775807""#,
        r#""args": [[], "-"], "ok": """#,
    ] {
        let head: String = cases.chars().take(4000).collect();
        assert!(cases.contains(expected), "{expected} in {head}");
    }
    ported(&dir, PORT);
    let d = diff(&dir);
    assert_eq!((d.passed, d.failed), (d.total, 0), "{:?}", d.mismatches);
    assert_eq!(d.total, 26);

    // A wrong port fails exactly the cases it gets wrong, an error included.
    let wrong = PORT
        .replace("    out.append(33)\n", "")
        .replace("negative input", "negative");
    assert_ne!(wrong, PORT);
    ported(&dir, &wrong);
    let failed: std::collections::BTreeMap<String, usize> =
        diff(&dir)
            .mismatches
            .iter()
            .fold(Default::default(), |mut m, c| {
                *m.entry(c["fn"].as_str().unwrap().to_string()).or_default() += 1;
                m
            });
    assert_eq!(
        failed.into_iter().collect::<Vec<_>>(),
        [
            ("kit::checked_sqrt".to_string(), 1),
            ("kit::shout".to_string(), 4)
        ]
    );
    std::fs::remove_dir_all(&repo).unwrap();
}

const CALLER: &str = r#"#include <iostream>
#include <stdexcept>

#include "kit.hpp"

int main()
{
    std::cout << kit::add(2, 3) << " " << kit::wide(1LL << 40, 3) << " " << kit::wrap(0, 1) << "\n";
    std::cout << kit::count_bytes("hello") << " " << kit::half(3.0f) << " " << kit::mean({1, 2, 4}) << "\n";
    for (int x : kit::evens({1, 2, 3, 4}))
        std::cout << x << " ";
    for (double x : kit::scale({1.5, 2}, 2))
        std::cout << x << " ";
    std::cout << "\n" << kit::is_upper("ABC") << " " << kit::shout("hi") << " "
              << kit::text::join({1, 2, 3}, "+") << "\n";
    kit::touch();
    try {
        kit::checked_sqrt(-1);
        std::cout << "no exception\n";
    } catch (const std::domain_error &e) {
        std::cout << "domain_error: " << e.what() << "\n";
    }
    std::cout << kit::checked_sqrt(16) << "\n";
    return 0;
}
"#;

#[test]
fn cpp_caller_links_against_the_wrapper() {
    if !ready() {
        return;
    }
    let repo = project("caller");
    let dir = bridged(&repo, "src/kit.cpp").crate_dir;
    ported(&dir, PORT);
    std::fs::write(repo.join("caller.cpp"), CALLER).unwrap();
    let run = |args: &[&str], name: &str| -> String {
        let bin = repo.join(name);
        let out = Command::new("c++")
            .args(["-std=c++17", "-I"])
            .arg(repo.join("src"))
            .arg(repo.join("caller.cpp"))
            .args(args)
            .arg("-o")
            .arg(&bin)
            .output()
            .unwrap();
        assert!(
            out.status.success(),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        let ran = Command::new(&bin).output().unwrap();
        assert!(
            ran.status.success(),
            "{}",
            String::from_utf8_lossy(&ran.stderr)
        );
        String::from_utf8(ran.stdout).unwrap()
    };
    let original = run(&[repo.join("src/kit.cpp").to_str().unwrap()], "original");
    let manifest = bridge::Manifest::load(&dir).unwrap();
    let lib = mojo_anything::harness_mojo_c::library_path(&dir, &manifest, false);
    let build = lib.parent().unwrap().to_str().unwrap().to_string();
    let file = lib.file_name().unwrap().to_str().unwrap().to_string();
    let wrapper = dir.join("cpp/wrapper.cpp");
    let ported = run(
        &[
            wrapper.to_str().unwrap(),
            &format!("-L{build}"),
            &format!("-l:{file}"),
            &format!("-Wl,-rpath,{build}"),
        ],
        "ported",
    );
    assert!(
        original.contains("domain_error: negative input"),
        "{original}"
    );
    assert_eq!(ported, original);
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn cpp_gate_and_bench() {
    if !ready() {
        return;
    }
    let repo = project("gate");
    let dir = bridged(&repo, "src/kit.cpp").crate_dir;
    record(&dir, &repo);
    ported(&dir, PORT);
    let rows = harness::bench(&harness::BenchOptions {
        crate_dir: &dir,
        min_ms: 1,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!(rows.len(), 13, "every function benchmarked: {rows:?}");
    assert!(
        rows.iter()
            .all(|r| r.original_ns > 0.0 && r.rust_ns > 0.0 && r.cases > 0),
        "{rows:?}"
    );

    let formatted = mojo_anything::mojo::command(&dir)
        .unwrap()
        .args(["format", "--quiet", "port.mojo"])
        .current_dir(&dir)
        .status()
        .unwrap();
    assert!(formatted.success());
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    let failed: Vec<_> = gate.checks.iter().filter(|c| !c.passed).collect();
    assert!(failed.is_empty(), "{failed:#?}");
    let names: Vec<&str> = gate.checks.iter().map(|c| c.name).collect();
    for name in [
        "cpp api", "exports", "pointers", "unsafe", "ported", "behavior",
    ] {
        assert!(names.contains(&name), "{name} in {names:?}");
    }

    // A wrapper whose signature no longer mangles as the original's fails `cpp api`.
    let wrapper = dir.join("cpp/wrapper.cpp");
    let text = std::fs::read_to_string(&wrapper).unwrap();
    let changed = text.replace(
        "std::string shout(std::string s)",
        "std::string shout(const std::string &s)",
    );
    assert_ne!(changed, text);
    std::fs::write(&wrapper, changed).unwrap();
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    let api = gate.checks.iter().find(|c| c.name == "cpp api").unwrap();
    assert!(!api.passed);
    assert!(api.detail.contains("kit::shout"), "{}", api.detail);
    assert!(
        api.fix.as_deref().unwrap().contains("refresh"),
        "{:?}",
        api.fix
    );
    bridge::refresh(&dir).unwrap();
    let gate = mojo_anything::gate::gate(&dir, &[]).unwrap();
    assert!(gate.checks.iter().any(|c| c.name == "cpp api" && c.passed));
    std::fs::remove_dir_all(&repo).unwrap();
}
