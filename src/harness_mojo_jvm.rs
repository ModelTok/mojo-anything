//! Building a `mojo-jvm` unit: `dispatcher.mojo` becomes the shared library the generated Java
//! classes load through the Foreign Function & Memory API. Record, diff and bench run the
//! reflection driver in `harness_java`, compiled against the original sources or the wrappers.

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

use crate::bridge::Manifest;

/// What the reflection driver is compiled with: the original sources (to record) or the
/// generated wrappers over the port (to diff and bench).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Against {
    Original,
    Port,
}

/// The library the wrappers load, built or not.
pub fn library_path(unit_dir: &Path, m: &Manifest) -> PathBuf {
    crate::harness_mojo_c::library_path(unit_dir, m, false)
}

/// Builds `dispatcher.mojo` with `--emit shared-lib` into the unit's build folder (warnings are
/// errors) and returns the library. The Java sources compile in `diff`.
pub fn build(unit_dir: &Path, m: &Manifest) -> Result<PathBuf> {
    if !crate::mojo::available() {
        bail!("{}", crate::mojo::missing_message());
    }
    let unit_dir = std::path::absolute(unit_dir)?;
    if !unit_dir.join(crate::codegen_ffi::DISPATCHER).is_file() {
        bail!(
            "{} has no {}: run `mojo-anything refresh {}`",
            unit_dir.display(),
            crate::codegen_ffi::DISPATCHER,
            unit_dir.display()
        );
    }
    std::fs::create_dir_all(unit_dir.join(crate::harness_mojo_c::BUILD_DIR))?;
    let lib = library_path(&unit_dir, m);
    crate::harness_mojo_c::build_one(&unit_dir, crate::codegen_ffi::DISPATCHER, &lib)?;
    Ok(lib)
}

/// The built library, or an error asking for `build`.
pub fn built_library(unit_dir: &Path, m: &Manifest) -> Result<PathBuf> {
    let lib = library_path(unit_dir, m);
    if !lib.is_file() {
        bail!(
            "no built library at {} (run `mojo-anything build {}` first)",
            lib.display(),
            unit_dir.display()
        );
    }
    Ok(lib)
}
