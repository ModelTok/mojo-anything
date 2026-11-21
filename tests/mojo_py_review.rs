//! Cases the M1 review found: Python names Mojo cannot take as they are, a parameter named
//! like the port module, wrong argument types, names the port leaves in Python, and a port
//! that never returns.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use mojo_anything::bridge;
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

const PORT: &str = "from py_num import PyNum


def pick(type: String, out_: String, port: String) raises -> String:
    return type + out_ + port


def match_(case_: String) raises -> String:
    return case_ + \"!\"


def lengths(items: List[String]) raises -> List[PyNum]:
    var res = List[PyNum]()
    for s in items:
        res.append(PyNum(len(s.codepoints())))
    return res^


def spin(n: PyNum) raises -> PyNum:
    return n.copy()
";

fn fixture() -> PathBuf {
    Path::new(ROOT).join("tests/fixtures/python-mojo-names")
}

fn ready() -> bool {
    if !common::have_mojo() {
        eprintln!("skipping: {}", mojo_anything::mojo::missing_message());
        return false;
    }
    common::have("python3")
}

fn bridged(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-py-review-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "src/names/",
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
    dir
}

fn recorded(tag: &str, port: &str) -> PathBuf {
    let dir = bridged(tag);
    harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 20,
        inputs: None,
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    std::fs::write(dir.join("port.mojo"), port).unwrap();
    harness::build(&dir).unwrap();
    dir
}

#[test]
fn mojo_keywords_get_a_trailing_underscore() {
    let dir = bridged("stubs");
    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    for line in [
        "def pick(type: String, out_: String, port: String) raises -> String:",
        "def match_(case_: String) raises -> String:",
    ] {
        assert!(port.contains(line), "{line}\n{port}");
    }
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn keyword_names_build_and_match() {
    if !ready() {
        return;
    }
    let dir = recorded("match", PORT);
    let d = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        node_args: &[],
        float_tolerance: None,
    })
    .unwrap();
    assert_eq!((d.failed, d.passed), (0, d.total), "{:?}", d.mismatches);
    std::fs::remove_dir_all(&dir).unwrap();
}

#[test]
fn wrapper_checks_types_and_keeps_what_stays_in_python() {
    if !ready() {
        return;
    }
    let dir = recorded("wrapper", PORT);
    let script = "import names_mojo as m\n\
        for call in (lambda: m.pick(5, 'a', 'b'), lambda: m.lengths('ab'), lambda: m.lengths([1])):\n\
        \x20   try:\n        call()\n        print('no error')\n\
        \x20   except TypeError:\n        print('TypeError')\n\
        print(m.pick('a', 'b', 'c'), m.total(1, 2), m.Box(3).v)\n\
        from names_mojo import total, Box\n";
    let paths = std::env::join_paths([dir.join("python"), fixture().join("src")]).unwrap();
    let out = Command::new("python3")
        .arg("-c")
        .arg(script)
        .env("PYTHONPATH", paths)
        .output()
        .unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "TypeError\nTypeError\nTypeError\nabc 3 3\n",
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}

#[test]
fn a_port_that_never_returns_is_stopped() {
    if !ready() {
        return;
    }
    let looping = PORT.replace(
        "    return n.copy()",
        "    var x = n.copy()\n    while x == x:\n        x = x + PyNum(1)\n    return x^",
    );
    let dir = recorded("spin", &looping);
    let start = Instant::now();
    let out = Command::new(env!("CARGO_BIN_EXE_mojo-anything"))
        .arg("diff")
        .arg(&dir)
        .env("MOJO_ANYTHING_COMMAND_TIMEOUT", "20")
        .output()
        .unwrap();
    let took = start.elapsed();
    std::fs::remove_dir_all(&dir).unwrap();
    assert!(!out.status.success(), "{out:?}");
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("was stopped"), "{stderr}");
    assert!(took < Duration::from_secs(90), "diff ran {took:?}");
}
