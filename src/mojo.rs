//! The Mojo toolchain: pixi runs a pinned Mojo inside each generated unit's own environment.
//!
//! Mojo builds only on Linux and macOS, so on Windows every Mojo step stops with
//! [`missing_message`] and points at the WSL clone.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Result, bail};

/// The Mojo every generated unit pins, and the one `pixi.toml` at the repository root pins.
pub const MOJO_VERSION: &str = "1.2.0";

/// The conda channels Mojo comes from, in the order pixi searches them.
pub const CHANNELS: &[&str] = &["https://conda.modular.com/max", "conda-forge"];

/// The platforms a generated `pixi.toml` lists: where Mojo ships.
pub const PLATFORMS: &[&str] = &["linux-64", "linux-aarch64", "osx-arm64"];

/// `pixi` on `path`, else `<home>/.pixi/bin/pixi` (where pixi's installer puts it).
pub(crate) fn find_pixi(path: Option<OsString>, home: Option<PathBuf>) -> Option<PathBuf> {
    let name = if cfg!(windows) { "pixi.exe" } else { "pixi" };
    let on_path = path
        .iter()
        .flat_map(std::env::split_paths)
        .map(|dir| dir.join(name))
        .find(|p| p.is_file());
    on_path.or_else(|| {
        home.map(|h| h.join(".pixi").join("bin").join(name))
            .filter(|p| p.is_file())
    })
}

fn pixi() -> Option<PathBuf> {
    if cfg!(windows) {
        return None;
    }
    find_pixi(
        std::env::var_os("PATH"),
        std::env::var_os("HOME").map(PathBuf::from),
    )
}

/// Whether Mojo can run here: not Windows, and pixi is installed.
pub fn available() -> bool {
    pixi().is_some()
}

/// One line saying what is missing and where Mojo runs.
pub fn missing_message() -> String {
    if cfg!(windows) {
        "Mojo runs only on Linux and macOS: run mojo-anything from the WSL clone \
         (see docs/mojo-notes.md)"
            .into()
    } else {
        "Mojo needs pixi, which is not on PATH or in ~/.pixi/bin: install it from \
         https://pixi.sh (Mojo runs only on Linux and macOS)"
            .into()
    }
}

/// `pixi run --manifest-path <project>/pixi.toml mojo`, ready for its arguments.
pub fn command(project: &Path) -> Result<Command> {
    let Some(pixi) = pixi() else {
        bail!("{}", missing_message());
    };
    let mut cmd = Command::new(pixi);
    cmd.arg("run")
        .arg("--manifest-path")
        .arg(project.join("pixi.toml"))
        .arg("mojo");
    Ok(cmd)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_pixi_without_path_or_home() {
        assert_eq!(find_pixi(None, None), None);
        assert_eq!(
            find_pixi(Some(OsString::new()), Some(PathBuf::from("/nonexistent"))),
            None
        );
    }

    #[test]
    fn missing_mojo_message() {
        let m = missing_message();
        assert!(m.contains("Linux and macOS"), "{m}");
        if !cfg!(windows) {
            assert!(m.contains("pixi"), "{m}");
        }
    }

    #[test]
    fn root_pixi_toml_pins_the_same_mojo() {
        let text = std::fs::read_to_string(concat!(env!("CARGO_MANIFEST_DIR"), "/pixi.toml"))
            .expect("pixi.toml at the repository root");
        assert!(
            text.contains(&format!("mojo = \"=={MOJO_VERSION}\"")),
            "pixi.toml must pin mojo =={MOJO_VERSION}"
        );
    }
}
