//! C inputs a Mojo port must treat as C does: `NULL` against `""` for a `const char *`, a buffer
//! written only as far as the function writes it, a `char **` set into the caller's string, and
//! integers that wrap at their C width (`int32_t` overflow, `unsigned` underflow, signed `char`).
//! Skips without a C compiler, Python or Mojo.

mod common;

use std::path::{Path, PathBuf};

use mojo_anything::bridge;
use mojo_anything::harness::{self, DiffOptions, RecordOptions};

const EDGE_C: &str = r#"#include <stddef.h>
#include <stdint.h>

int is_null(const char *s)
{
    return s == NULL;
}

void fill_but_four(char *buf, size_t size)
{
    for (size_t i = 0; i + 4 < size; i++)
        buf[i] = 'x';
}

int skip_spaces(const char *s, char **end)
{
    int n = 0;
    while (s[n] == ' ')
        n++;
    if (end)
        *end = (char *)s + n;
    return n;
}

int32_t add32(int32_t a, int32_t b)
{
    return (int32_t)((uint32_t)a + (uint32_t)b);
}

unsigned sub_u(unsigned a, unsigned b)
{
    return a - b;
}

int negative(char c)
{
    return c < 0;
}
"#;

const PORT: &str = r#"
def is_null(s: Optional[Span[UInt8, ImmutAnyOrigin]]) -> Int32:
    return 1 if not s else 0


def fill_but_four(buf: Span[UInt8, MutAnyOrigin]):
    var i = 0
    while i + 4 < len(buf):
        buf[i] = 120
        i += 1


def skip_spaces(
    s: Optional[Span[UInt8, ImmutAnyOrigin]], mut end: Optional[Int]
) -> Int32:
    var n = 0
    var b = s.value()
    while n < len(b) and b[n] == 32:
        n += 1
    end = Optional(n)
    return Int32(n)


def add32(a: Int32, b: Int32) -> Int32:
    return a + b


def sub_u(a: UInt32, b: UInt32) -> UInt32:
    return a - b


def negative(c: Int8) -> Int32:
    return 1 if c < 0 else 0
"#;

const INPUTS: &str = r#"{"fn": "is_null", "args": [null]}
{"fn": "is_null", "args": [""]}
{"fn": "is_null", "args": ["x"]}
{"fn": "fill_but_four", "args": [10]}
{"fn": "fill_but_four", "args": [4]}
{"fn": "fill_but_four", "args": [0]}
{"fn": "skip_spaces", "args": ["   x", true]}
{"fn": "skip_spaces", "args": ["x", true]}
{"fn": "skip_spaces", "args": ["  ", null]}
{"fn": "add32", "args": [2147483647, 1]}
{"fn": "add32", "args": [-2147483648, -1]}
{"fn": "sub_u", "args": [0, 1]}
{"fn": "negative", "args": [-128]}
{"fn": "negative", "args": [127]}
"#;

fn project(tag: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("mojo-anything-c-edge-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("src")).unwrap();
    std::fs::write(dir.join("src/edge.c"), EDGE_C).unwrap();
    std::fs::write(dir.join("inputs.jsonl"), INPUTS).unwrap();
    dir
}

fn ready() -> bool {
    common::have("cc") && common::python().is_some() && common::have_mojo()
}

/// Bridged, recorded from `INPUTS`, with `port` in place of the stubs, and built.
fn ported(repo: &Path, port: &str) -> PathBuf {
    let dir = bridge::bridge(&bridge::Options {
        root: repo,
        unit: "src/edge.c",
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
    .crate_dir;
    harness::record(&RecordOptions {
        crate_dir: &dir,
        count: 0,
        inputs: Some(&repo.join("inputs.jsonl")),
        module: None,
        resolve_from: None,
        node_args: &[],
    })
    .unwrap();
    let stubs = std::fs::read_to_string(dir.join("port.mojo")).unwrap();
    let head = stubs.split("\n\n# Port of").next().unwrap();
    std::fs::write(dir.join("port.mojo"), format!("{head}\n{port}")).unwrap();
    harness::build(&dir).unwrap();
    dir
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
fn c_edge_cases_match_their_mojo_port() {
    if !ready() {
        return;
    }
    let repo = project("match");
    let dir = ported(&repo, PORT);
    let cases = std::fs::read_to_string(dir.join(harness::CASES)).unwrap();
    for expected in [
        r#""args": [null], "ok": 1"#,
        r#""args": [""], "ok": 0"#,
        r#""args": [2147483647, 1], "ok": -2147483648"#,
        r#""args": [0, 1], "ok": 4294967295"#,
        r#""args": [-128], "ok": 1"#,
        r#""args": ["   x", true], "ok": {"return": 3, "end": 3}"#,
    ] {
        assert!(cases.contains(expected), "{expected} in {cases}");
    }
    let d = diff(&dir);
    assert_eq!((d.passed, d.failed), (d.total, 0), "{:?}", d.mismatches);
    assert_eq!(d.total, 14);
    std::fs::remove_dir_all(&repo).unwrap();
}

#[test]
fn c_buffer_overrun_is_caught() {
    if !ready() {
        return;
    }
    let repo = project("overrun");
    let dir = ported(
        &repo,
        &PORT.replace("while i + 4 < len(buf):", "while i + 3 < len(buf):"),
    );
    let d = diff(&dir);
    let failed: Vec<&str> = d
        .mismatches
        .iter()
        .filter_map(|m| m["fn"].as_str())
        .collect();
    assert!(
        !failed.is_empty() && failed.iter().all(|f| *f == "fill_but_four"),
        "{:?}",
        d.mismatches
    );
    std::fs::remove_dir_all(&repo).unwrap();
}
