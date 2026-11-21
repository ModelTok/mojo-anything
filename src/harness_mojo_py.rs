//! Building a Python unit's Mojo port: `_native.mojo` becomes the extension module inside the
//! wrapper package, built by the unit's own pinned Mojo. Recording and diffing are the Python
//! driver's (`harness_py`), which imports the package whatever built it.

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

use crate::bridge::Manifest;
use crate::codegen_mojo_py::NATIVE;

/// The folder the wrapper package lives in, and the package name.
pub fn package(unit_dir: &Path, manifest: &Manifest) -> (PathBuf, String) {
    (unit_dir.join("python"), manifest.lib_name())
}

/// The built extension module inside the wrapper package.
pub fn native_file(unit_dir: &Path, manifest: &Manifest) -> PathBuf {
    let (dir, name) = package(unit_dir, manifest);
    dir.join(name).join(format!("{NATIVE}.so"))
}

/// Builds `_native.mojo` (warnings are errors) into the wrapper package.
pub fn build(unit_dir: &Path, manifest: &Manifest) -> Result<PathBuf> {
    let (dir, name) = package(unit_dir, manifest);
    let package_dir = dir.join(name);
    std::fs::create_dir_all(&package_dir)?;
    let target = native_file(unit_dir, manifest);
    let mut cmd = crate::mojo::command(unit_dir)?;
    cmd.current_dir(unit_dir)
        .args(["build", "--Werror", &format!("{NATIVE}.mojo")])
        .args(["--emit", "shared-lib", "-o"])
        .arg(&target);
    let out = crate::process::output(&mut cmd, crate::process::BUILD)?;
    if !out.success() {
        bail!(
            "mojo build failed:\n{}{}",
            out.stdout_text(),
            out.stderr_text()
        );
    }
    Ok(package_dir)
}

/// True when any `.mojo` file of the unit is newer than `built`.
pub fn sources_newer_than(unit_dir: &Path, built: &Path) -> bool {
    let Ok(built_at) = std::fs::metadata(built).and_then(|m| m.modified()) else {
        return false;
    };
    std::fs::read_dir(unit_dir)
        .into_iter()
        .flatten()
        .flatten()
        .filter(|e| e.path().extension().is_some_and(|x| x == "mojo"))
        .filter_map(|e| e.metadata().and_then(|m| m.modified()).ok())
        .any(|t| t > built_at)
}
