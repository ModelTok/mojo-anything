//! A Python unit that takes and returns bytes: a port declares them as `List[UInt8]`, and the
//! bindings turn any bytes-like object into the list and the list back into `bytes`.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge;
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

const PORT: &str = "# Port of `invert` (`flip.py:5`).
def invert(data: List[UInt8], keep_ascii: Bool) raises -> List[UInt8]:
    var out = List[UInt8](capacity=len(data))
    for c in data:
        if keep_ascii and c < 128:
            out.append(c)
        else:
            out.append(255 - c)
    return out^
";

fn fixture() -> PathBuf {
    Path::new(ROOT).join("tests/fixtures/python-mojo-bytes")
}

fn ready() -> bool {
    if !common::have_mojo() {
        eprintln!("skipping: {}", mojo_anything::mojo::missing_message());
        return false;
    }
    common::have("python3")
}

/// The bytes cases, as the recording encodes them: every byte value, empty, and a NUL.
fn inputs(dir: &Path) -> PathBuf {
    let all: Vec<u8> = (0..=255).collect();
    let lines = [
        serde_json::json!({"fn": "invert", "args": [{"$bytes": all}]}),
        serde_json::json!({"fn": "invert", "args": [{"$bytes": all}, true]}),
        serde_json::json!({"fn": "invert", "args": [{"$bytes": []}, false]}),
        serde_json::json!({"fn": "invert", "args": [{"$bytes": [0, 200, 65]}, true]}),
    ];
    std::fs::create_dir_all(dir).unwrap();
    let path = dir.join("bytes-inputs.jsonl");
    let text: String = lines.iter().map(|l| format!("{l}\n")).collect();
    std::fs::write(&path, text).unwrap();
    path
}

#[test]
fn bytes_cross_the_python_bridge_as_a_list_of_uint8() {
    if !ready() {
        return;
    }
    let dir = std::env::temp_dir().join(format!("mojo-py-bytes-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    bridge::bridge(&bridge::Options {
        root: &fixture(),
        unit: "flip.py",
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
    let inputs_dir = std::env::temp_dir().join(format!("mojo-py-bytes-in-{}", std::process::id()));
    let inputs = inputs(&inputs_dir);
    harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 0,
        inputs: Some(&inputs),
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    std::fs::write(dir.join("port.mojo"), PORT).unwrap();
    // The port changed the stub's types (`PythonObject`, for a parameter with no hint).
    bridge::refresh(&dir).unwrap();
    harness::build(&dir).unwrap();
    let d = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        node_args: &[],
        float_tolerance: None,
    })
    .unwrap();
    assert!(d.total >= 4, "{} cases", d.total);
    assert_eq!((d.failed, d.passed), (0, d.total), "{:?}", d.mismatches);

    // Any bytes-like object goes in, `bytes` comes out, and anything else is a TypeError.
    let script = "import flip_mojo as m\n\
        print(m.invert(b'\\x00\\xff'), m.invert(bytearray(b'A'), True), m.invert(memoryview(b'\\x01')))\n\
        for bad in ('text', [1, 2], 3):\n\
        \x20   try:\n        m.invert(bad)\n        print('no error')\n\
        \x20   except TypeError:\n        print('TypeError')\n";
    let out = Command::new("python3")
        .arg("-c")
        .arg(script)
        .env("PYTHONPATH", dir.join("python"))
        .output()
        .unwrap();
    std::fs::remove_dir_all(&dir).unwrap();
    std::fs::remove_dir_all(&inputs_dir).unwrap();
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "b'\\xff\\x00' b'A' b'\\xfe'\nTypeError\nTypeError\nTypeError\n",
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
}
