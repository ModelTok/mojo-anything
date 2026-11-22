//! Building a C unit's Mojo port: `exports.mojo` becomes the drop-in shared library that exports
//! the original C names, and `exports_shadow.mojo` a second one exporting `mojo_anything_<name>`
//! for builds that link the port beside the original (bench, shadow). Recording and diffing are
//! the ctypes driver's (`harness_c`), which loads whichever library it is given.

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};

use crate::bridge::Manifest;

/// Where `build` puts the libraries.
pub const BUILD_DIR: &str = ".mojo-anything/build";

/// The generated export files: C names, and the shadow build's prefixed names.
pub const EXPORTS: &str = "exports.mojo";
pub const EXPORTS_SHADOW: &str = "exports_shadow.mojo";

fn library_name(manifest: &Manifest, shadow: bool) -> String {
    let ext = if cfg!(target_os = "macos") {
        "dylib"
    } else {
        "so"
    };
    let tag = if shadow { "_shadow" } else { "" };
    format!("lib{}{tag}.{ext}", manifest.lib_name())
}

/// The drop-in library (`shadow` false) or the shadow library, built or not.
pub fn library_path(unit_dir: &Path, manifest: &Manifest, shadow: bool) -> PathBuf {
    unit_dir
        .join(BUILD_DIR)
        .join(library_name(manifest, shadow))
}

/// Builds `source` in `unit_dir` into the shared library `target` (warnings are errors).
pub fn build_one(unit_dir: &Path, source: &str, target: &Path) -> Result<()> {
    let mut cmd = crate::mojo::command(unit_dir)?;
    cmd.current_dir(unit_dir)
        .args(["build", "--Werror", source])
        .args(["--emit", "shared-lib", "-o"])
        .arg(target);
    let out = crate::process::output(&mut cmd, crate::process::BUILD)?;
    if !out.success() {
        bail!(
            "mojo build {source} failed:\n{}{}",
            out.stdout_text(),
            out.stderr_text()
        );
    }
    Ok(())
}

/// Builds both libraries (warnings are errors); returns the drop-in one.
pub fn build(unit_dir: &Path, manifest: &Manifest) -> Result<PathBuf> {
    let unit_dir = std::path::absolute(unit_dir)?;
    std::fs::create_dir_all(unit_dir.join(BUILD_DIR))?;
    let lib = library_path(&unit_dir, manifest, false);
    build_one(&unit_dir, EXPORTS, &lib)?;
    build_one(
        &unit_dir,
        EXPORTS_SHADOW,
        &library_path(&unit_dir, manifest, true),
    )?;
    Ok(lib)
}

/// The built library, or an error asking for `build`.
pub fn built_library(unit_dir: &Path, manifest: &Manifest, shadow: bool) -> Result<PathBuf> {
    let lib = library_path(unit_dir, manifest, shadow);
    if !lib.exists() {
        bail!(
            "no built library at {} (run `mojo-anything build` first)",
            lib.display()
        );
    }
    Ok(lib)
}
