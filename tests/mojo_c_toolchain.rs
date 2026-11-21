//! The pinned Mojo builds a shared library exporting C functions under their C names, which a C
//! program compiled by the system compiler calls: scalars, a nullable `const char *`, a buffer
//! sized by another argument, a struct by value and a `char **` written back. Skips where Mojo
//! or a C compiler cannot run.

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::mojo;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

/// Builds the probe library and the C program that calls it; returns the program's output.
fn probe(tag: &str) -> Option<(PathBuf, String)> {
    if !mojo::available() {
        eprintln!("skipping: {}", mojo::missing_message());
        return None;
    }
    if !common::have("cc") {
        return None;
    }
    let fixture = Path::new(ROOT).join("tests/fixtures/mojo-c-probe");
    let dir = std::env::temp_dir().join(format!("mojo-c-probe-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let lib = dir.join("libprobe.so");
    let built = mojo::command(Path::new(ROOT))
        .unwrap()
        .arg("build")
        .arg("--Werror")
        .arg(fixture.join("exports.mojo"))
        .args(["--emit", "shared-lib", "-o"])
        .arg(&lib)
        .output()
        .unwrap();
    assert!(
        built.status.success(),
        "mojo build failed:\n{}",
        String::from_utf8_lossy(&built.stderr)
    );
    let program = dir.join("probe");
    let cc = Command::new("cc")
        .arg(fixture.join("probe.c"))
        .arg(&lib)
        .arg(format!("-Wl,-rpath,{}", dir.display()))
        .arg("-o")
        .arg(&program)
        .output()
        .unwrap();
    assert!(
        cc.status.success(),
        "{}",
        String::from_utf8_lossy(&cc.stderr)
    );
    let run = Command::new(&program).output().unwrap();
    assert!(run.status.success(), "{run:?}");
    Some((lib, String::from_utf8_lossy(&run.stdout).into_owned()))
}

fn line<'a>(out: &'a str, key: &str) -> &'a str {
    out.lines()
        .find_map(|l| l.strip_prefix(key)?.strip_prefix(' '))
        .unwrap_or_else(|| panic!("no `{key}` in\n{out}"))
}

#[test]
fn probe_scalars_and_strings() {
    let Some((_, out)) = probe("scalars") else {
        return;
    };
    assert_eq!(line(&out, "add"), "5");
    assert_eq!(line(&out, "len"), "3");
    assert_eq!(line(&out, "len_null"), u64::MAX.to_string());
}

#[test]
fn probe_buffer_written_to_length() {
    let Some((_, out)) = probe("buffer") else {
        return;
    };
    assert_eq!(line(&out, "fill"), "0 1 2 3 255 255");
}

#[test]
fn probe_struct_by_value() {
    let Some((_, out)) = probe("struct") else {
        return;
    };
    assert_eq!(line(&out, "swap"), "2 5");
}

#[test]
fn probe_out_ptr() {
    let Some((_, out)) = probe("outptr") else {
        return;
    };
    assert_eq!(line(&out, "end"), "2");
}

#[test]
fn probe_exports_only_c_names() {
    let Some((lib, _)) = probe("nm") else {
        return;
    };
    let nm = Command::new("nm")
        .args(["-D", "--defined-only"])
        .arg(&lib)
        .output()
        .unwrap();
    let text: Vec<String> = String::from_utf8_lossy(&nm.stdout)
        .lines()
        .filter_map(|l| {
            let mut parts = l.split_whitespace();
            let (_, kind, name) = (parts.next()?, parts.next()?, parts.next()?);
            (kind == "T").then(|| name.to_string())
        })
        .collect();
    assert_eq!(
        text,
        [
            "probe_add",
            "probe_end",
            "probe_fill",
            "probe_len",
            "probe_swap"
        ]
    );
}
