//! Java and Kotlin units need Java 22 or newer: with an older JDK first on PATH, `bridge`,
//! `record` and `build` stop before generating or compiling anything.

#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Command;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn copy_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for entry in std::fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            std::fs::copy(entry.path(), target).unwrap();
        }
    }
}

/// A folder holding a fake JDK 21 `java` and `javac`. The scripts are copied from text files
/// with `cp` and never rewritten (pitfall: "Text file busy").
fn fake_jdk_21(base: &Path) -> PathBuf {
    let bin = base.join("bin");
    std::fs::create_dir_all(&bin).unwrap();
    for tool in ["java", "javac"] {
        let status = Command::new("cp")
            .arg(Path::new(ROOT).join(format!("tests/fixtures/jvm-21/{tool}.txt")))
            .arg(bin.join(tool))
            .status()
            .unwrap();
        assert!(status.success());
        let status = Command::new("chmod")
            .arg("755")
            .arg(bin.join(tool))
            .status()
            .unwrap();
        assert!(status.success());
    }
    bin
}

fn with_path(cmd: &mut Command, bin: &Path) {
    let mut dirs = vec![bin.to_path_buf()];
    dirs.extend(std::env::split_paths(
        &std::env::var_os("PATH").unwrap_or_default(),
    ));
    cmd.env("PATH", std::env::join_paths(dirs).unwrap());
}

#[test]
fn java_21_is_refused() {
    let base = std::env::temp_dir().join(format!("mojo-anything-jvm21-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&base);
    let root = base.join("project");
    copy_tree(&Path::new(ROOT).join("tests/fixtures/java"), &root);
    let bin = fake_jdk_21(&base);

    let mut cmd = Command::new(env!("CARGO_BIN_EXE_mojo-anything"));
    cmd.arg("bridge")
        .arg(&root)
        .arg("src/main/java/com/example/text/");
    with_path(&mut cmd, &bin);
    let out = cmd.output().unwrap();
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(!out.status.success(), "bridge passed on Java 21: {stderr}");
    assert!(stderr.contains("22"), "{stderr}");
    assert!(stderr.contains("found 21"), "{stderr}");
    // Nothing was generated: no Mojo port, and no Rust one either.
    assert!(!root.join("mojo").exists(), "a mojo/ folder was written");
    assert!(!root.join("rust").exists(), "a rust/ folder was written");

    // `build` and `record` on a unit folder stop the same way, before reading anything else.
    let unit = base.join("unit");
    std::fs::create_dir_all(&unit).unwrap();
    std::fs::write(
        unit.join("mojo-anything.json"),
        format!(
            r#"{{"schema": "mojo-anything/bridge@1", "root": "{}", "unit": "src/main/java/com/example/text/",
                "language": "java", "kind": "mojo-jvm", "crate_name": "text-mojo", "exports": []}}"#,
            root.display()
        ),
    )
    .unwrap();
    for step in ["build", "record"] {
        let mut cmd = Command::new(env!("CARGO_BIN_EXE_mojo-anything"));
        cmd.arg(step).arg(&unit);
        with_path(&mut cmd, &bin);
        let out = cmd.output().unwrap();
        let stderr = String::from_utf8_lossy(&out.stderr);
        assert!(!out.status.success(), "{step} passed on Java 21: {stderr}");
        assert!(
            stderr.contains("Java 22 or newer") && stderr.contains("found 21"),
            "{step}: {stderr}"
        );
        assert!(!unit.join(".mojo-anything").exists(), "{step} wrote files");
    }
    let _ = std::fs::remove_dir_all(&base);
}
