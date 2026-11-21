//! The Rust `cdylib` of the bridges that still generate Rust (Go, Ruby, Java and Kotlin), until
//! each of them ports to Mojo. C and Python units build with `mojo` instead.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

use crate::bridge::Manifest;

fn library_names(manifest: &Manifest) -> [String; 3] {
    let lib = manifest.lib_name();
    [
        format!("lib{lib}.so"),
        format!("lib{lib}.dylib"),
        format!("{lib}.dll"),
    ]
}

/// Builds the crate with `cargo build --release` into its own `target/`, and returns the
/// shared library: `lib<name>.so`, `.dylib` or `.dll`.
pub fn build(crate_dir: &Path, manifest: &Manifest) -> Result<PathBuf> {
    let target = crate_dir.join("target");
    let mut cmd = Command::new("cargo");
    cmd.args(["build", "--release", "--manifest-path"])
        .arg(crate_dir.join("Cargo.toml"))
        .env("CARGO_TARGET_DIR", &target);
    let _scratch = crate::harness::scratch_cwd(&mut cmd)?;
    let output = cmd.output().context("running cargo build")?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let tail: Vec<&str> = stderr.lines().rev().take(25).collect();
        bail!(
            "cargo build failed ({}):\n{}",
            output.status,
            tail.into_iter().rev().collect::<Vec<_>>().join("\n")
        );
    }
    let release = target.join("release");
    library_names(manifest)
        .iter()
        .map(|n| release.join(n))
        .find(|p| p.exists())
        .with_context(|| {
            format!(
                "no shared library for `{}` in {}",
                manifest.lib_name(),
                release.display()
            )
        })
}

/// The library `build` left in the crate's `target/release`.
pub fn built_library(crate_dir: &Path, manifest: &Manifest) -> Result<PathBuf> {
    let release = crate_dir.join("target/release");
    library_names(manifest)
        .iter()
        .map(|n| release.join(n))
        .find(|p| p.exists())
        .with_context(|| {
            format!(
                "no built library in {} (run `mojo-anything build` first)",
                release.display()
            )
        })
}
