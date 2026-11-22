mod common;

use std::{path::Path, process::Command};

use mojo_anything::{
    bridge::{self, Kind},
    codegen_java::{DRIVER_JAVA, JSON_JAVA},
    harness::{self, DiffOptions, DiffOutcome},
};

#[test]
fn java_replay_distinguishes_null_from_a_rejected_argument() {
    if !common::have("java") || !common::have("javac") {
        return;
    }

    let root = std::env::temp_dir().join(format!("mojo-anything-java-null-{}", std::process::id()));
    std::fs::create_dir_all(&root).unwrap();
    let result = replay(&root);
    std::fs::remove_dir_all(root).unwrap();

    let diff = result.unwrap();
    assert_eq!((diff.passed, diff.failed), (1, 1));
    assert_eq!(diff.mismatches[0]["actual"]["invalid"], true);
}

fn replay(root: &Path) -> anyhow::Result<DiffOutcome> {
    std::fs::write(root.join("MojoAnythingDriver.java"), DRIVER_JAVA)?;
    std::fs::write(root.join("MojoAnythingJson.java"), JSON_JAVA)?;
    std::fs::write(
        root.join("Port.java"),
        "public class Port { public static String value(int input) { return null; } }",
    )?;
    std::fs::write(root.join("targets.json"), r#"{"value":["Port","value"]}"#)?;
    std::fs::write(
        root.join("cases.jsonl"),
        r#"{"fn":"value","args":[1],"ok":null}
{"fn":"value","args":["previously accepted"],"ok":null}
"#,
    )?;

    run(Command::new("javac").current_dir(root).args([
        "-d",
        ".",
        "MojoAnythingDriver.java",
        "MojoAnythingJson.java",
        "Port.java",
    ]))?;
    run(Command::new("java").current_dir(root).args([
        "-cp",
        ".",
        "mojoanything.MojoAnythingDriver",
        "diff",
        "targets.json",
        "cases.jsonl",
        "diff.json",
    ]))?;
    Ok(serde_json::from_slice(&std::fs::read(
        root.join("diff.json"),
    )?)?)
}

/// An exception's message is part of what the original did: a port that throws the same
/// exception class with another message does not match.
#[test]
fn java_diff_compares_exception_messages() {
    if !common::have("java") || !common::have("javac") {
        return;
    }
    let root = std::env::temp_dir().join(format!(
        "mojo-anything-java-messages-{}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let result = replay_messages(&root);
    std::fs::remove_dir_all(root).unwrap();

    let diff = result.unwrap();
    assert_eq!((diff.passed, diff.failed), (1, 2), "{diff:?}");
    assert_eq!(diff.mismatches[0]["args"][0], "x", "{diff:?}");
    assert_eq!(diff.mismatches[1]["args"][0], "z", "{diff:?}");
}

fn replay_messages(root: &Path) -> anyhow::Result<DiffOutcome> {
    std::fs::write(root.join("MojoAnythingDriver.java"), DRIVER_JAVA)?;
    std::fs::write(root.join("MojoAnythingJson.java"), JSON_JAVA)?;
    std::fs::write(
        root.join("Port.java"),
        "public class Port { public static int parse(String s) { throw new NumberFormatException(\"other\"); } }",
    )?;
    std::fs::write(root.join("targets.json"), r#"{"parse":["Port","parse"]}"#)?;
    // The message differs; the message and class agree; the class differs.
    std::fs::write(
        root.join("cases.jsonl"),
        r#"{"fn":"parse","args":["x"],"error":"For input string: \"x\"","error_type":"NumberFormatException"}
{"fn":"parse","args":["y"],"error":"other","error_type":"NumberFormatException"}
{"fn":"parse","args":["z"],"error":"other","error_type":"IllegalArgumentException"}
"#,
    )?;
    run(Command::new("javac").current_dir(root).args([
        "-d",
        ".",
        "MojoAnythingDriver.java",
        "MojoAnythingJson.java",
        "Port.java",
    ]))?;
    run(Command::new("java").current_dir(root).args([
        "-cp",
        ".",
        "mojoanything.MojoAnythingDriver",
        "diff",
        "targets.json",
        "cases.jsonl",
        "diff.json",
    ]))?;
    Ok(serde_json::from_slice(&std::fs::read(
        root.join("diff.json"),
    )?)?)
}

fn run(cmd: &mut Command) -> anyhow::Result<()> {
    let output = cmd.output()?;
    anyhow::ensure!(
        output.status.success(),
        "{cmd:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    Ok(())
}

/// The same two cases through a `mojo-jvm` unit: the Mojo port returns `null`, and a case whose
/// argument the signature rejects is reported as invalid, not as a `null` that matches.
#[test]
fn jvm_replay_distinguishes_null_from_a_rejected_argument() {
    if !common::have_java() || !common::have_mojo() {
        return;
    }
    let root = std::env::temp_dir().join(format!("mojo-anything-jvm-null-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let result = replay_mojo(&root);
    let _ = std::fs::remove_dir_all(&root);

    let diff = result.unwrap();
    assert_eq!((diff.passed, diff.failed), (1, 1), "{diff:?}");
    assert_eq!(diff.mismatches[0]["actual"]["invalid"], true, "{diff:?}");
}

fn replay_mojo(root: &Path) -> anyhow::Result<DiffOutcome> {
    let project = root.join("project");
    let source = project.join("src/main/java/com/example/nulls/Port.java");
    std::fs::create_dir_all(source.parent().unwrap())?;
    std::fs::write(
        project.join("pom.xml"),
        "<project xmlns=\"http://maven.apache.org/POM/4.0.0\">\n  <modelVersion>4.0.0</modelVersion>\n  \
         <groupId>com.example</groupId>\n  <artifactId>nulls</artifactId>\n  <version>0.1.0</version>\n</project>\n",
    )?;
    std::fs::write(
        &source,
        "package com.example.nulls;\n\npublic final class Port {\n    public static String value(int input) {\n        return null;\n    }\n}\n",
    )?;
    let unit = root.join("unit");
    let outcome = bridge::bridge(&bridge::Options {
        root: &project,
        unit: "src/main/java/com/example/nulls/",
        kind: None,
        out: Some(unit.clone()),
        name: Some("nulls-mojo".into()),
        force: false,
        keep: Vec::new(),
        lang: None,
        batch: Vec::new(),
        as_json: Vec::new(),
    })?;
    anyhow::ensure!(outcome.kind == Kind::MojoJvm, "{outcome:?}");
    // The port answers `null`: an `Optional[String]` that is empty.
    std::fs::write(
        unit.join("port.mojo"),
        "# The Mojo port of `Port`.\n\n\n# Port of `value`.\n\
         def value(input: Int32) raises -> Optional[String]:\n    return None\n",
    )?;
    bridge::refresh(&unit)?;
    harness::build(&unit)?;
    std::fs::write(
        unit.join("cases.jsonl"),
        r#"{"fn":"value","args":[1],"ok":null}
{"fn":"value","args":["previously accepted"],"ok":null}
"#,
    )?;
    harness::diff(&DiffOptions {
        crate_dir: &unit,
        module: None,
        ignore_key_order: false,
        float_tolerance: None,
        node_args: &[],
    })
}
