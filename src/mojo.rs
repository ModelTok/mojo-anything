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
        .arg(env_manifest(project)?)
        .arg("mojo");
    Ok(cmd)
}

/// The `pixi.toml` whose environment runs Mojo for `project`: its own, unless the project's
/// path holds whitespace. Packages pixi builds from source (EmberJson) run build scripts that
/// do not quote paths, so such a project gets a copy of its `pixi.toml` in a cache folder named
/// by the file's hash, shared by every project with the same file.
fn env_manifest(project: &Path) -> Result<PathBuf> {
    use std::hash::{Hash, Hasher};
    let own = project.join("pixi.toml");
    let absolute = std::path::absolute(project)?;
    if !absolute.to_string_lossy().contains(char::is_whitespace) {
        return Ok(own);
    }
    let text =
        std::fs::read(&own).map_err(|e| anyhow::anyhow!("reading {}: {e}", own.display()))?;
    let mut hasher = std::collections::hash_map::DefaultHasher::new();
    text.hash(&mut hasher);
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .unwrap_or_else(std::env::temp_dir);
    let dir = cache
        .join("mojo-anything")
        .join("pixi")
        .join(format!("{:016x}", hasher.finish()));
    if dir.to_string_lossy().contains(char::is_whitespace) {
        bail!(
            "{} has whitespace in its path, and so does the cache folder {}: Mojo packages built \
             from source cannot build there; move the project",
            project.display(),
            dir.display()
        );
    }
    std::fs::create_dir_all(&dir)?;
    let copy = dir.join("pixi.toml");
    if std::fs::read(&copy).ok().as_deref() != Some(&text[..]) {
        std::fs::write(&copy, &text)?;
    }
    Ok(copy)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_project_path_with_spaces_gets_its_environment_elsewhere() {
        let base = std::env::temp_dir().join(format!("mojo env spaces {}", std::process::id()));
        std::fs::create_dir_all(&base).unwrap();
        std::fs::write(base.join("pixi.toml"), "[workspace]\nname = \"x\"\n").unwrap();
        let manifest = env_manifest(&base).unwrap();
        assert!(
            !manifest.to_string_lossy().contains(char::is_whitespace),
            "{}",
            manifest.display()
        );
        assert_eq!(
            std::fs::read_to_string(&manifest).unwrap(),
            "[workspace]\nname = \"x\"\n"
        );
        let plain = std::env::temp_dir().join(format!("mojo-env-plain-{}", std::process::id()));
        assert_eq!(env_manifest(&plain).unwrap(), plain.join("pixi.toml"));
        std::fs::remove_dir_all(&base).unwrap();
    }

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
