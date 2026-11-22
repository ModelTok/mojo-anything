//! Step 6: turn a gated port into packages end users install. Writes files only: it never builds
//! for other platforms and never publishes.
//!
//! Not yet for any kind: npm packages of Mojo ports (`mojo-node`), Python wheels and the rest
//! come with the packaging plan (M7, `docs/superpowers/plans/2026-11-21-m7-package-docs-release.md`).
//! The napi-rs and wasm-bindgen layouts this step wrote went with those bridges.

use std::path::{Path, PathBuf};

use anyhow::{Result, bail};
use serde::Serialize;

use crate::bridge::{Kind, Manifest};

/// Why `package` fails for a TS/JS unit.
pub const NPM_NOT_YET: &str = "not yet: npm packages of Mojo ports come with the packaging plan      (M7, docs/superpowers/plans/2026-11-21-m7-package-docs-release.md)";

pub struct Options<'a> {
    pub crate_dir: &'a Path,
    /// Package name on npm or PyPI; defaults to the crate name.
    pub name: Option<String>,
    /// Package version; defaults to the original package's.
    pub version: Option<String>,
    /// Output folder; defaults to `<crate>/package`.
    pub out: Option<PathBuf>,
    /// List what would be written, write nothing.
    pub dry_run: bool,
}

#[derive(Debug, Serialize)]
pub struct Outcome {
    pub kind: Kind,
    pub name: String,
    pub version: String,
    pub out: PathBuf,
    /// Python: the module the wheel installs (`import <module>`).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub module: Option<String>,
    pub files: Vec<String>,
    pub dry_run: bool,
    pub notes: Vec<String>,
}

pub fn package(opts: &Options) -> Result<Outcome> {
    let crate_dir = std::path::absolute(opts.crate_dir)?;
    let manifest = Manifest::load(&crate_dir)?;
    match manifest.kind {
        Kind::MojoNode | Kind::MojoWasm => bail!("{NPM_NOT_YET}"),
        Kind::MojoPy => bail!("packaging a Mojo Python extension is not supported yet"),
        Kind::CAbi | Kind::Ffi => bail!(
            "packaging {:?} units is not supported yet (see the packaging plan, M7)",
            manifest.kind
        ),
    }
}

/// The version of the package the unit belongs to: the nearest `package.json` for JS, the
/// `pyproject.toml` (or `setup.cfg`, or `__version__`) for Python.
pub fn original_version(manifest: &Manifest) -> Option<String> {
    let root = &manifest.root;
    let unit = root.join(manifest.unit.trim_end_matches('/'));
    match manifest.language {
        crate::lang::Lang::Python => python_version(root, &unit),
        _ => {
            let mut dir = unit.parent()?.to_path_buf();
            loop {
                let pkg = dir.join("package.json");
                if let Ok(text) = std::fs::read_to_string(&pkg)
                    && let Ok(value) = serde_json::from_str::<serde_json::Value>(&text)
                    && let Some(v) = value["version"].as_str()
                {
                    return Some(v.to_string());
                }
                if dir == *root || !dir.pop() || !dir.starts_with(root) {
                    return None;
                }
            }
        }
    }
}

fn python_version(root: &Path, unit: &Path) -> Option<String> {
    if let Ok(text) = std::fs::read_to_string(root.join("pyproject.toml"))
        && let Ok(doc) = text.parse::<toml_edit::DocumentMut>()
    {
        let v = doc
            .get("project")
            .and_then(|p| p.get("version"))
            .or_else(|| {
                doc.get("tool")
                    .and_then(|t| t.get("poetry"))
                    .and_then(|p| p.get("version"))
            })
            .and_then(|v| v.as_str());
        if let Some(v) = v {
            return Some(v.to_string());
        }
    }
    if let Ok(text) = std::fs::read_to_string(root.join("setup.cfg")) {
        let mut in_metadata = false;
        for line in text.lines() {
            let line = line.trim();
            if line.starts_with('[') {
                in_metadata = line == "[metadata]";
            } else if in_metadata
                && let Some((key, value)) = line.split_once('=')
                && key.trim() == "version"
                && !value.trim().starts_with("attr:")
            {
                return Some(value.trim().to_string());
            }
        }
    }
    let init = if unit.is_dir() {
        unit.join("__init__.py")
    } else {
        unit.parent()?.join("__init__.py")
    };
    let text = std::fs::read_to_string(init).ok()?;
    text.lines().find_map(|l| {
        let rest = l.trim().strip_prefix("__version__")?.trim_start();
        let rest = rest.strip_prefix('=')?.trim();
        let quote = rest.chars().next().filter(|c| *c == '"' || *c == '\'')?;
        rest[1..].split(quote).next().map(str::to_string)
    })
}

/// The dotted module the original unit is imported as: `src/textkit/` is `textkit`,
/// `src/textkit/words.py` is `textkit.words`. Folders above count while they are packages
/// (hold `__init__.py`); without the sources, a leading `src/` or `lib/` is dropped.
pub fn python_module(manifest: &Manifest) -> String {
    python_module_path(&manifest.root, &manifest.unit)
}

/// The dotted module a source path under `root` is imported as (see [`python_module`]).
pub fn python_module_path(root: &std::path::Path, unit: &str) -> String {
    let unit = unit.trim_end_matches('/');
    let unit = unit.strip_suffix("/__init__.py").unwrap_or(unit);
    let unit = unit.strip_suffix(".py").unwrap_or(unit);
    let parts: Vec<&str> = unit.split('/').filter(|p| !p.is_empty()).collect();
    let mut start = parts.len().saturating_sub(1);
    if root.join(unit).exists() || root.join(format!("{unit}.py")).exists() {
        while start > 0
            && root
                .join(parts[..start].join("/"))
                .join("__init__.py")
                .exists()
        {
            start -= 1;
        }
    } else {
        start = usize::from(matches!(parts.first(), Some(&"src" | &"lib")) && parts.len() > 1);
    }
    parts[start..].join(".")
}
