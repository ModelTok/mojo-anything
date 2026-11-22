//! The generated Java of a `mojo-jvm` unit: the error mapping run on a real JVM, and every
//! generated class compiled by `javac` (no Mojo library is needed for either).

mod common;

use std::path::{Path, PathBuf};
use std::process::Command;

use mojo_anything::bridge::{Kind, Manifest, SCHEMA};
use mojo_anything::codegen::PortApi;
use mojo_anything::codegen_java::ERROR_JAVA;
use mojo_anything::codegen_mojo_jvm::{support_files, wrappers_ffm};
use mojo_anything::lang::Lang;

const ROOT: &str = env!("CARGO_MANIFEST_DIR");

fn scratch(tag: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("mojo-anything-jvm-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn run(cmd: &mut Command) -> String {
    let out = cmd.output().unwrap();
    assert!(
        out.status.success(),
        "{cmd:?} failed:\n{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    String::from_utf8_lossy(&out.stdout).into_owned()
}

fn java_sources(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            out.extend(java_sources(&path));
        } else if path.extension().is_some_and(|e| e == "java") {
            out.push(path);
        }
    }
    out
}

#[test]
fn error_maps_to_declared_exception() {
    if !common::have_java() {
        return;
    }
    let dir = scratch("error");
    write(
        &dir.join("src/mojoanything/MojoAnythingError.java"),
        ERROR_JAVA,
    );
    write(
        &dir.join("src/Check.java"),
        r#"import mojoanything.MojoAnythingError;

public class Check {
    static String show(String text) {
        try {
            throw MojoAnythingError.raise(text);
        } catch (RuntimeException e) {
            return e.getClass().getName() + "|" + e.getMessage();
        }
    }

    public static void main(String[] args) {
        System.out.println(show("java.lang.NumberFormatException: For input string: \"x\""));
        System.out.println(show("NumberFormatException: For input string: \"x\""));
        System.out.println(show("IllegalArgumentException: port out of range: 0"));
        System.out.println(show("com.example.Missing: boom"));
        System.out.println(show("java.io.UncheckedIOException: no (String) constructor"));
        System.out.println(show("java.io.IOException: checked"));
        System.out.println(show("no type here: at all"));
        System.out.println(show("plain text"));
    }
}
"#,
    );
    let classes = dir.join("classes");
    run(Command::new("javac")
        .args(["-encoding", "UTF-8", "-d"])
        .arg(&classes)
        .args(java_sources(&dir.join("src"))));
    let out = run(Command::new("java")
        .args(["-XX:-UsePerfData", "-cp"])
        .arg(&classes)
        .arg("Check"));
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(
        lines,
        [
            "java.lang.NumberFormatException|For input string: \"x\"",
            "java.lang.NumberFormatException|For input string: \"x\"",
            "java.lang.IllegalArgumentException|port out of range: 0",
            "java.lang.RuntimeException|com.example.Missing: boom",
            "java.lang.RuntimeException|java.io.UncheckedIOException: no (String) constructor",
            "java.lang.RuntimeException|java.io.IOException: checked",
            "java.lang.RuntimeException|no type here: at all",
            "java.lang.RuntimeException|plain text",
        ],
        "{out}"
    );
    let _ = std::fs::remove_dir_all(&dir);
}

fn fixture_manifest() -> Manifest {
    let root = Path::new(ROOT).join("tests/fixtures/java");
    let mut exports = Vec::new();
    for file in [
        "src/main/java/com/example/text/Strings.java",
        "src/main/java/com/example/text/Nums.java",
    ] {
        let text = std::fs::read_to_string(root.join(file)).unwrap();
        exports.extend(mojo_anything::lang::java::exports(file, &text));
    }
    Manifest {
        schema: SCHEMA.into(),
        root,
        root_written: None,
        unit: "src/main/java/com/example/text/".into(),
        language: Lang::Java,
        kind: Kind::MojoJvm,
        crate_name: "text-mojo".into(),
        exports,
        classes: Vec::new(),
        js_only: Vec::new(),
        batches: Vec::new(),
        float_tolerance: None,
    }
}

#[test]
fn generated_java_compiles_without_preview_features() {
    if !common::have_java() {
        return;
    }
    let dir = scratch("compile");
    let m = fixture_manifest();
    for (path, text) in support_files(&m)
        .into_iter()
        .chain(wrappers_ffm(&m, &PortApi::default()))
    {
        write(&dir.join(&path), &text);
    }
    // `--release 22`: the oldest Java the generated classes promise to compile on.
    let out = Command::new("javac")
        .args(["-encoding", "UTF-8", "--release", "22", "-d"])
        .arg(dir.join("classes"))
        .args(java_sources(&dir.join("java")))
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(
        dir.join("classes/mojoanything/TextMojoNative.class")
            .is_file()
    );
    assert!(dir.join("classes/com/example/text/Strings.class").is_file());
    let _ = std::fs::remove_dir_all(&dir);
}
