//! C functions that take buffers with lengths, write through out-pointers, return a pointer
//! into an argument, or use typedef'd scalars: bridged with the original signatures, recorded,
//! ported to Mojo, diffed and benchmarked. The project ships a `time.h` of its own, as ffmpeg
//! does, which must not shadow `<time.h>`.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge;
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

const TYPES_H: &str = "#include <stdint.h>\n#include <stddef.h>\ntypedef uint32_t Sum;\n\
typedef enum { MODE_LOW, MODE_HIGH } Mode;\n";

const TIME_H: &str = "#define PROJECT_TIME_H 1\n";

const BUF_C: &str = r#"#include <time.h>
#include "types.h"
#include "time.h"

static time_t unused_clock(void) { return (time_t)0; }

Sum sum_update(Sum s, const uint8_t *buf, size_t len)
{
    for (size_t i = 0; i < len; i++)
        s = s * 31 + buf[i];
    return s;
}

int hex_encode(char *out, int out_size, const uint8_t *in, int in_size)
{
    static const char digits[] = "0123456789abcdef";
    int n = 0;
    if (out_size < 2 * in_size + 1)
        return -1;
    for (int i = 0; i < in_size; i++) {
        out[n++] = digits[in[i] >> 4];
        out[n++] = digits[in[i] & 15];
    }
    out[n] = 0;
    return n;
}

char *find_byte(const char *s, int c)
{
    for (; *s; s++)
        if (*s == c)
            return (char *)s;
    return NULL;
}

static int fold(char c)
{
    return c >= 'A' && c <= 'Z' ? c + 32 : (unsigned char)c;
}

int casecmp(const char *a, const char *b)
{
    while (*a && fold(*a) == fold(*b)) {
        a++;
        b++;
    }
    return fold(*a) - fold(*b);
}

int split(int *hi, int *lo, int v, Mode mode)
{
    *hi = mode == MODE_HIGH ? v >> 16 : 0;
    if (lo)
        *lo = v & 0xffff;
    return mode;
}
"#;

const PORT: &str = r#"
def sum_update(s: UInt32, buf: Span[UInt8, ImmutAnyOrigin]) -> UInt32:
    var h = s
    for i in range(len(buf)):
        h = h * 31 + buf[i].cast[DType.uint32]()
    return h


def hex_encode(
    out_: Span[UInt8, MutAnyOrigin], in_: Span[UInt8, ImmutAnyOrigin]
) -> Int32:
    var digits = "0123456789abcdef".as_bytes()
    if len(out_) < 2 * len(in_) + 1:
        return -1
    for i in range(len(in_)):
        out_[2 * i] = digits[Int(in_[i] >> 4)]
        out_[2 * i + 1] = digits[Int(in_[i] & 15)]
    out_[2 * len(in_)] = 0
    return Int32(2 * len(in_))


def find_byte(s: Optional[Span[UInt8, ImmutAnyOrigin]], c: Int32) -> Optional[Int]:
    if not s:
        return None
    var b = s.value()
    for i in range(len(b)):
        if b[i].cast[DType.int8]().cast[DType.int32]() == c:
            return Optional(i)
    return None


def _fold(c: UInt8) -> Int32:
    var v = c.cast[DType.int32]()
    return v + 32 if c >= 65 and c <= 90 else v


def casecmp(
    a: Optional[Span[UInt8, ImmutAnyOrigin]],
    b: Optional[Span[UInt8, ImmutAnyOrigin]],
) -> Int32:
    if not a or not b:
        return 0
    var x = a.value()
    var y = b.value()
    var i = 0
    while True:
        var p: Int32 = _fold(x[i]) if i < len(x) else 0
        var q: Int32 = _fold(y[i]) if i < len(y) else 0
        if p == 0 or p != q:
            return p - q
        i += 1


def split(
    mut hi: Optional[Int32], mut lo: Optional[Int32], v: Int32, mode: Int32
) -> Int32:
    if hi:
        hi = Optional(v >> 16 if mode == 1 else Int32(0))
    if lo:
        lo = Optional(v & 0xFFFF)
    return mode
"#;

const INPUTS: &str = r#"{"fn": "sum_update", "args": [7, "00ff10"]}
{"fn": "sum_update", "args": [0, ""]}
{"fn": "sum_update", "args": [1, null]}
{"fn": "hex_encode", "args": [7, "00ff10"]}
{"fn": "hex_encode", "args": [6, "00ff10"]}
{"fn": "hex_encode", "args": ["ffffffffffffffffff", "abcd"]}
{"fn": "find_byte", "args": ["hello", 108]}
{"fn": "find_byte", "args": ["hello", 122]}
{"fn": "casecmp", "args": ["Hello", "hELLo"]}
{"fn": "casecmp", "args": ["abc", "abd"]}
{"fn": "casecmp", "args": ["", "x"]}
{"fn": "casecmp", "args": ["xy", "x"]}
{"fn": "split", "args": [5, 5, 305419896, 1]}
{"fn": "split", "args": [0, null, 305419896, 0]}
"#;

fn project() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-anything-c-pointers-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src")).unwrap();
    std::fs::write(dir.join("src/types.h"), TYPES_H).unwrap();
    std::fs::write(dir.join("src/time.h"), TIME_H).unwrap();
    std::fs::write(dir.join("src/buf.c"), BUF_C).unwrap();
    dir
}

fn bridged(repo: &Path) -> PathBuf {
    bridge::bridge(&bridge::Options {
        root: repo,
        unit: "src/buf.c",
        kind: None,
        out: None,
        name: None,
        force: true,
        keep: Vec::new(),
        lang: Some(mojo_anything::lang::Lang::C),
        batch: Vec::new(),
        as_json: Vec::new(),
    })
    .unwrap()
    .crate_dir
}

#[test]
fn pointer_arguments_cross_the_c_bridge() {
    if !common::have("cc") || common::python().is_none() || !common::have_mojo() {
        return;
    }
    let repo = project();
    let dir = bridged(&repo);
    let manifest = bridge::Manifest::load(&dir).unwrap();
    let kinds = |name: &str| -> Vec<String> {
        let f = manifest.exports.iter().find(|f| f.name == name).unwrap();
        f.params.iter().map(|p| p.ts_type.clone()).collect()
    };
    assert_eq!(kinds("sum_update"), ["int", "bytes", "len:1"]);
    assert_eq!(kinds("hex_encode"), ["buffer", "len:0", "bytes", "len:2"]);
    assert_eq!(kinds("split"), ["out", "out", "int", "int"]);
    assert_eq!(kinds("casecmp"), ["string", "string"]);
    let find = manifest
        .exports
        .iter()
        .find(|f| f.name == "find_byte")
        .unwrap();
    assert_eq!(find.returns, "ptr:0");

    let header = std::fs::read_to_string(dir.join("include/buf_mojo.h")).unwrap();
    assert!(
        header.contains("uint32_t sum_update(uint32_t s, const uint8_t *buf, size_t len);"),
        "{header}"
    );

    let port = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    assert!(
        port.contains(
            "def hex_encode(out_: Span[UInt8, MutAnyOrigin], in_: Span[UInt8, ImmutAnyOrigin]) -> Int32:"
        ),
        "{port}"
    );
    let head = port.split("\n\n# Port of").next().unwrap();
    std::fs::write(dir.join("port.mojo"), format!("{head}\n{PORT}")).unwrap();
    mojo_anything::bridge::refresh(&dir).unwrap();

    let inputs = repo.join("inputs.jsonl");
    std::fs::write(&inputs, INPUTS).unwrap();
    harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 20,
        inputs: Some(&inputs),
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    let cases = std::fs::read_to_string(dir.join("cases.jsonl")).unwrap();
    assert!(
        cases.contains(r#""args": [7, "00ff10"], "ok": {"return": 6, "out": "30306666313000"}"#),
        "{cases}"
    );
    assert!(
        cases.contains(r#""args": ["hello", 108], "ok": 2"#),
        "{cases}"
    );
    assert!(
        cases.contains(
            r#""args": [5, 5, 305419896, 1], "ok": {"return": 1, "hi": 4660, "lo": 22136}"#
        ),
        "{cases}"
    );

    let built = Command::new(env!("CARGO_BIN_EXE_mojo-anything"))
        .args(["build", "."])
        .current_dir(&dir)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "a relative crate path builds: {}",
        String::from_utf8_lossy(&built.stderr)
    );
    let diff = harness::diff(&DiffOptions {
        crate_dir: &dir,
        module: None,
        ignore_key_order: false,
        node_args: &[],
        float_tolerance: None,
    })
    .unwrap();
    assert_eq!(diff.passed, diff.total, "{:?}", diff.mismatches);
    assert!(diff.total > 10);

    let rows = harness::bench(&harness::BenchOptions {
        crate_dir: &dir,
        min_ms: 5,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    assert_eq!(rows.len(), 5, "every function benchmarked");
    std::fs::remove_dir_all(&repo).unwrap();
}
