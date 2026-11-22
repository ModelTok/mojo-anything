//! Building a TS/JS unit ported to Mojo: the dispatcher library with `mojo build`, then the
//! Node-API addon with the C compiler against Node's own headers.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

use crate::bridge::Manifest;

/// The addon's C source in the unit folder.
pub const NODE_SHIM: &str = "node_shim.c";

/// The addon `index.cjs` requires: `<lib>.node` beside it.
pub fn addon_path(unit_dir: &Path, m: &Manifest) -> PathBuf {
    unit_dir.join(format!("{}.node", m.lib_name()))
}

/// Node's header folder (`node_api.h`), from the running `node`.
fn node_include() -> Result<PathBuf> {
    let mut cmd = Command::new("node");
    cmd.args([
        "-p",
        "require('path').join(process.execPath, '..', '..', 'include', 'node')",
    ]);
    let out = crate::process::output(&mut cmd, crate::process::BUILD)
        .context("running node to find its headers")?;
    if !out.success() {
        bail!(
            "node could not say where its headers are:\n{}",
            out.stderr_text()
        );
    }
    let dir = PathBuf::from(out.stdout_text().trim());
    if !dir.join("node_api.h").is_file() {
        bail!(
            "{} has no node_api.h: install Node's headers (they ship with the official builds)",
            dir.display()
        );
    }
    Ok(dir)
}

/// Builds the dispatcher (warnings are errors) and the addon; copies the library next to the
/// addon, where the addon looks for it. Returns the addon's path.
pub fn build(unit_dir: &Path, m: &Manifest) -> Result<PathBuf> {
    let unit_dir = std::path::absolute(unit_dir)?;
    std::fs::create_dir_all(unit_dir.join(crate::harness_mojo_c::BUILD_DIR))?;
    let lib = crate::harness_mojo_c::library_path(&unit_dir, m, false);
    crate::harness_mojo_c::build_one(&unit_dir, crate::codegen_ffi::DISPATCHER, &lib)?;
    let file_name = lib.file_name().context("library path has no file name")?;
    std::fs::copy(&lib, unit_dir.join(file_name))
        .with_context(|| format!("copying {} next to the addon", lib.display()))?;
    let addon = addon_path(&unit_dir, m);
    let mut cc = Command::new("cc");
    cc.current_dir(&unit_dir)
        .args(["-shared", "-fPIC", "-O2", "-Wall", "-Werror", "-I"])
        .arg(node_include()?)
        .arg(format!("-DNODE_GYP_MODULE_NAME={}", m.lib_name()))
        .arg(NODE_SHIM)
        .arg("-o")
        .arg(&addon);
    if cfg!(target_os = "macos") {
        cc.args(["-undefined", "dynamic_lookup"]);
    } else {
        cc.arg("-ldl");
    }
    let out = crate::process::output(&mut cc, crate::process::BUILD)
        .context("running cc for the Node-API addon")?;
    if !out.success() {
        bail!(
            "cc {NODE_SHIM} failed:\n{}{}",
            out.stdout_text(),
            out.stderr_text()
        );
    }
    Ok(addon)
}
