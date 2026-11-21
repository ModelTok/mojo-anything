//! The pinned Mojo builds a Python extension module that CPython imports. Skips where Mojo cannot
//! run (Windows, or no pixi).

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::mojo;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn build_probe(tag: &str) -> Option<PathBuf> {
    if !mojo::available() {
        eprintln!("skipping: {}", mojo::missing_message());
        return None;
    }
    let dir = std::env::temp_dir().join(format!("mojo-probe-{tag}-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let src = Path::new(ROOT).join("tests/fixtures/mojo-probe/_native.mojo");
    let out = mojo::command(Path::new(ROOT))
        .unwrap()
        .arg("build")
        .arg(&src)
        .args(["--emit", "shared-lib", "-o"])
        .arg(dir.join("_native.so"))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "mojo build failed:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    Some(dir)
}

fn python(dir: &Path, code: &str) -> String {
    let out = Command::new("python3")
        .arg("-c")
        .arg(code)
        .env("PYTHONPATH", dir)
        .env("PYTHONDONTWRITEBYTECODE", "1")
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "python failed:\n{}",
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).trim().to_string()
}

#[test]
fn probe_builds_and_imports() {
    let Some(dir) = build_probe("imports") else {
        return;
    };
    assert_eq!(
        python(&dir, "import _native; print(_native.add(1.5, 2))"),
        "3.5"
    );
    assert_eq!(
        python(&dir, "import _native; print(_native.pair(3))"),
        "(3, 'x')"
    );
}

#[test]
fn probe_raises_value_error() {
    let Some(dir) = build_probe("raises") else {
        return;
    };
    // Mojo 1.2 raises every error as `Exception`; the message carries the Python type, which the
    // generated wrapper package turns back into that type.
    let got = python(
        &dir,
        "import _native\ntry:\n    _native.fail('x')\nexcept Exception as e:\n    print(type(e).__name__, str(e))",
    );
    assert_eq!(got, "Exception ValueError: x");
}
