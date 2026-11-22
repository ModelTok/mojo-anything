//! The Java side of record, build, diff and bench. A generated driver calls the unit's static
//! methods by reflection: compiled with the original sources to record, and with the wrapper
//! classes to diff: over the Mojo library through the Foreign Function & Memory API for a
//! `mojo-jvm` unit, over the Rust library through JNI for a Rust-era `ffi` crate.

use crate::walk::Canonical;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::bridge::{Kind, Manifest};
use crate::harness::{BenchRow, CASES, DiffOutcome};
pub use crate::harness_mojo_jvm::Against;

const WORK_DIR: &str = ".mojo-anything";

fn run(cmd: &mut Command, what: &str) -> Result<()> {
    let _scratch = crate::harness::scratch_cwd(cmd)?;
    let output = cmd.output().with_context(|| format!("running {what}"))?;
    if !output.status.success() {
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        let tail: Vec<&str> = text
            .lines()
            .filter(|l| !l.starts_with("Picked up JAVA_TOOL_OPTIONS"))
            .rev()
            .take(30)
            .collect();
        bail!(
            "{what} failed ({}):\n{}",
            output.status,
            tail.into_iter().rev().collect::<Vec<_>>().join("\n")
        );
    }
    Ok(())
}

fn java_files(dir: &Path) -> Vec<PathBuf> {
    crate::walk::builder(dir)
        .require_git(false)
        .build()
        .flatten()
        .map(|e| e.into_path())
        .filter(|p| p.extension().is_some_and(|e| e == "java"))
        .collect()
}

/// Compiles the driver with the original sources or with the unit's wrapper classes.
fn compile(unit_dir: &Path, m: &Manifest, against: Against) -> Result<PathBuf> {
    let work = unit_dir.canonical()?.join(WORK_DIR);
    let support = work.join("java-support/mojo-anything");
    std::fs::create_dir_all(&support)?;
    std::fs::write(
        support.join("MojoAnythingJson.java"),
        crate::codegen_java::JSON_JAVA,
    )?;
    std::fs::write(
        support.join("MojoAnythingDriver.java"),
        crate::codegen_java::DRIVER_JAVA,
    )?;
    let classes = work.join(match against {
        Against::Port => "java-port",
        Against::Original => "java-original",
    });
    if classes.exists() {
        std::fs::remove_dir_all(&classes)?;
    }
    std::fs::create_dir_all(&classes)?;
    let mut sources = java_files(&work.join("java-support"));
    match against {
        Against::Port => sources.extend(
            java_files(&unit_dir.join("java"))
                .into_iter()
                .filter(|p| !p.ends_with("mojoanything/MojoAnythingJson.java")),
        ),
        Against::Original => {
            // The whole source tree: the unit's classes may use others from the same module.
            let ws = crate::lang::java::discover(&m.root)?;
            sources.extend(
                ws.files
                    .iter()
                    .filter(|f| f.kind == crate::ts::discover::FileKind::Source)
                    .map(|f| m.root.join(&f.path)),
            );
        }
    }
    run(
        Command::new("javac")
            .args(["-encoding", "UTF-8", "-nowarn", "-d"])
            .arg(&classes)
            .args(&sources),
        match against {
            Against::Port => "javac (driver and wrapper classes)",
            Against::Original => "javac (driver and original sources)",
        },
    )?;
    Ok(classes)
}

/// The classpath of the driver compiled with the original sources or with the wrappers.
pub(crate) fn classpath(unit_dir: &Path, m: &Manifest, against: Against) -> Result<Vec<PathBuf>> {
    Ok(vec![compile(unit_dir, m, against)?])
}

fn driver(
    unit_dir: &Path,
    m: &Manifest,
    mode: &str,
    cases: &Path,
    out: &Path,
    min_ms: u64,
    against: Against,
) -> Result<()> {
    let mut cmd = driver_command(unit_dir, m, mode, cases, out, min_ms, against)?;
    run(&mut cmd, &format!("java driver ({mode})"))
}

/// Java class files for a dexed on-device run: support driver plus either the original Java
/// sources (`rust: false`) or the generated JNI wrappers (`rust: true`).
pub(crate) fn android_classes(crate_dir: &Path, m: &Manifest, rust: bool) -> Result<Vec<PathBuf>> {
    let against = if rust {
        Against::Port
    } else {
        Against::Original
    };
    let classes = compile(crate_dir, m, against)?;
    Ok(crate::walk::builder(&classes)
        .require_git(false)
        .build()
        .flatten()
        .map(|e| e.into_path())
        .filter(|p| p.extension().is_some_and(|e| e == "class"))
        .collect())
}

/// The JVM's flags: UTF-8, no perf data file (pitfall: a JVM warning about a locked
/// `hsperfdata` file reached a recording), native access, and for the port its library.
pub(crate) fn jvm_args(unit_dir: &Path, m: &Manifest, against: Against) -> Result<Vec<String>> {
    let mut args = vec![
        "-Dfile.encoding=UTF-8".to_string(),
        "-XX:-UsePerfData".into(),
        // `java.lang.foreign` and `System.load` are restricted: without this Java 22+ warns.
        "--enable-native-access=ALL-UNNAMED".into(),
    ];
    if against == Against::Port {
        let lib = if m.kind == Kind::MojoJvm {
            crate::harness_mojo_jvm::built_library(unit_dir, m)?
        } else {
            crate::harness_cargo::built_library(unit_dir, m)?
        };
        args.push(format!(
            "-Dmojo-anything.lib.{}={}",
            m.lib_name(),
            lib.canonical()?.display()
        ));
    }
    Ok(args)
}

fn driver_command(
    unit_dir: &Path,
    m: &Manifest,
    mode: &str,
    cases: &Path,
    out: &Path,
    min_ms: u64,
    against: Against,
) -> Result<Command> {
    let classes = compile(unit_dir, m, against)?;
    let work = unit_dir.join(WORK_DIR);
    let targets = work.join("targets.json");
    std::fs::write(&targets, crate::codegen_java::targets(m).to_string())?;
    let mut cmd = Command::new("java");
    cmd.args(jvm_args(unit_dir, m, against)?)
        .arg("-cp")
        .arg(&classes)
        .arg("mojoanything.MojoAnythingDriver")
        .arg(mode)
        .arg(&targets)
        .arg(cases)
        .arg(out)
        .arg(min_ms.to_string());
    Ok(cmd)
}

pub fn record(unit_dir: &Path, m: &Manifest, cases: &[Value]) -> Result<PathBuf> {
    std::fs::create_dir_all(unit_dir.join(WORK_DIR))?;
    let out = unit_dir.join(CASES);
    crate::harness::record_cases(
        cases,
        &unit_dir.join(WORK_DIR),
        &out,
        "java driver (record)",
        |inputs, part| driver_command(unit_dir, m, "record", inputs, part, 0, Against::Original),
    )?;
    Ok(out)
}

pub fn diff(unit_dir: &Path, m: &Manifest) -> Result<DiffOutcome> {
    let cases = unit_dir.join(CASES);
    if !cases.exists() {
        bail!(
            "no {CASES} in {} (run `mojo-anything record` first)",
            unit_dir.display()
        );
    }
    let out = unit_dir.join(WORK_DIR).join("diff.json");
    driver(unit_dir, m, "diff", &cases, &out, 0, Against::Port)?;
    Ok(serde_json::from_str(&std::fs::read_to_string(&out)?)?)
}

pub fn bench(unit_dir: &Path, m: &Manifest, min_ms: u64) -> Result<Vec<BenchRow>> {
    let cases = unit_dir.join(CASES);
    if !cases.exists() {
        bail!(
            "no {CASES} in {} (run `mojo-anything record` first)",
            unit_dir.display()
        );
    }
    let mut timings = Vec::new();
    for against in [Against::Original, Against::Port] {
        let out = unit_dir.join(WORK_DIR).join(match against {
            Against::Port => "bench-port.json",
            Against::Original => "bench-original.json",
        });
        driver(unit_dir, m, "bench", &cases, &out, min_ms, against)?;
        timings.push(serde_json::from_str(&std::fs::read_to_string(&out)?)?);
    }
    Ok(crate::harness::bench_rows(m, &timings[0], &timings[1]))
}
