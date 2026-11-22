//! The Kotlin side of record, build, diff and bench.
//!
//! Mirrors the Java harness, but compiles the original Kotlin sources with `kotlinc` into a
//! fat jar (`-include-runtime`, so the Kotlin stdlib is on the runtime classpath) and then
//! compiles the generated Java reflection driver against that jar. Kotlin static methods are
//! callable from Java, so the same `mojoanything.MojoAnythingDriver` is used for record, diff
//! and bench; against the port it is compiled with the generated Java wrappers, which need no
//! Kotlin at all.

use crate::walk::Canonical;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};
use serde_json::Value;

use crate::bridge::Manifest;
use crate::harness::{BenchRow, CASES, DiffOutcome};
use crate::harness_mojo_jvm::Against;

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

/// Compiles the support driver with the original Kotlin sources (a fat jar) or with the unit's
/// generated Java wrappers, and returns the classpath: the compiled classes, then the jar.
pub(crate) fn classpath(unit_dir: &Path, m: &Manifest, against: Against) -> Result<Vec<PathBuf>> {
    let work = unit_dir.canonical()?.join(WORK_DIR);
    let support = work.join("kotlin-support/mojo-anything");
    std::fs::create_dir_all(&support)?;
    std::fs::write(
        support.join("MojoAnythingJson.java"),
        crate::codegen_kotlin::JSON_JAVA,
    )?;
    std::fs::write(
        support.join("MojoAnythingDriver.java"),
        crate::codegen_kotlin::DRIVER_JAVA,
    )?;

    let classes = work.join(match against {
        Against::Port => "kotlin-port",
        Against::Original => "kotlin-original",
    });
    if classes.exists() {
        std::fs::remove_dir_all(&classes)?;
    }
    std::fs::create_dir_all(&classes)?;

    let mut jar = None;
    let mut sources = java_files(&work.join("kotlin-support"));
    match against {
        Against::Original => {
            // The whole source tree: the unit may call other files of the module.
            let out = work.join("kotlin-original.jar");
            let ws = crate::lang::kotlin::discover(&m.root)?;
            let all: Vec<PathBuf> = ws
                .files
                .iter()
                .filter(|f| f.kind == crate::ts::discover::FileKind::Source)
                .map(|f| m.root.join(&f.path))
                .collect();
            let mut cmd = Command::new("kotlinc");
            cmd.arg("-include-runtime").arg("-d").arg(&out).args(&all);
            run(&mut cmd, "kotlinc (original sources)")?;
            jar = Some(out);
        }
        Against::Port => sources.extend(
            java_files(&unit_dir.join("java"))
                .into_iter()
                .filter(|p| !p.ends_with("mojoanything/MojoAnythingJson.java")),
        ),
    }
    let mut javac = Command::new("javac");
    javac.arg("-encoding").arg("UTF-8").arg("-nowarn");
    if let Some(jar) = &jar {
        javac.arg("-cp").arg(jar);
    }
    javac.arg("-d").arg(&classes).args(&sources);
    run(
        &mut javac,
        match against {
            Against::Port => "javac (driver and wrapper classes)",
            Against::Original => "javac (driver against original Kotlin classes)",
        },
    )?;
    Ok(std::iter::once(classes).chain(jar).collect())
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
    let cp = classpath(unit_dir, m, against)?;
    let work = unit_dir.join(WORK_DIR);
    let targets = work.join("targets.json");
    std::fs::write(&targets, crate::codegen_kotlin::targets(m).to_string())?;
    let mut cmd = Command::new("java");
    cmd.args(crate::harness_java::jvm_args(unit_dir, m, against)?)
        .arg("-cp")
        .arg(std::env::join_paths(&cp).context("building Java classpath")?)
        .arg("mojoanything.MojoAnythingDriver")
        .arg(mode)
        .arg(&targets)
        .arg(cases)
        .arg(out)
        .arg(min_ms.to_string());
    Ok(cmd)
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
