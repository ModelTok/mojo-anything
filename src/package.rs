//! Step 6: turn a gated port into packages end users install. Writes files only: it never builds
//! for other platforms and never publishes. The libraries of this machine's build go in its
//! platform's place; a GitHub workflow written beside them builds the other platforms.
//!
//! No package carries the Mojo runtime (`libKGENCompilerRTShared` and the two libraries it
//! needs): Modular's licence lets an application redistribute only the components its
//! documentation names, so a Python package depends on the `mojo-compiler` wheel instead, and
//! the others ask for the runtime on the library path (`docs/packaging.md`, `DECISIONS.md`).

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::Serialize;

use crate::bridge::{Kind, Manifest};

/// A platform packages are built for: where the pinned Mojo ships (pixi's `linux-64`,
/// `linux-aarch64` and `osx-arm64`). There is no Windows and no Intel macOS build of Mojo.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Platform {
    /// The name packages use: `linux-x64`, `linux-arm64`, `darwin-arm64`.
    pub name: &'static str,
    /// Node's `process.platform` and Go's `GOOS`.
    pub os: &'static str,
    /// Node's `process.arch`.
    pub node_arch: &'static str,
    /// Go's `GOARCH`.
    pub go_arch: &'static str,
    /// Python's `platform.machine()` and RubyGems' CPU.
    pub machine: &'static str,
    /// The shared-library suffix.
    pub lib_ext: &'static str,
    /// The GitHub Actions runner that builds it.
    pub runner: &'static str,
}

/// Every platform a package or workflow names, in this order.
pub const PLATFORMS: &[Platform] = &[
    Platform {
        name: "linux-x64",
        os: "linux",
        node_arch: "x64",
        go_arch: "amd64",
        machine: "x86_64",
        lib_ext: "so",
        runner: "ubuntu-24.04",
    },
    Platform {
        name: "linux-arm64",
        os: "linux",
        node_arch: "arm64",
        go_arch: "arm64",
        machine: "aarch64",
        lib_ext: "so",
        runner: "ubuntu-24.04-arm",
    },
    Platform {
        name: "darwin-arm64",
        os: "darwin",
        node_arch: "arm64",
        go_arch: "arm64",
        machine: "arm64",
        lib_ext: "dylib",
        runner: "macos-14",
    },
];

/// The supported platforms' names, comma-separated, for messages.
pub fn platform_list() -> String {
    PLATFORMS
        .iter()
        .map(|p| p.name)
        .collect::<Vec<_>>()
        .join(", ")
}

/// The platform this machine is, when it is one of [`PLATFORMS`].
pub fn host_platform() -> Option<&'static Platform> {
    let name = match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => "linux-x64",
        ("linux", "aarch64") => "linux-arm64",
        ("macos", "aarch64") => "darwin-arm64",
        _ => return None,
    };
    PLATFORMS.iter().find(|p| p.name == name)
}

/// The Mojo runtime libraries every Mojo shared library needs, which no package carries.
pub const MOJO_RUNTIME: &[&str] = &[
    "libMSupportGlobals",
    "libAsyncRTRuntimeGlobals",
    "libKGENCompilerRTShared",
];

/// A file `package` writes: text, or bytes (a built library).
pub(crate) enum Content {
    Text(String),
    Binary(Vec<u8>),
}

/// The files of one package, by path under the output folder.
pub(crate) type Files = Vec<(String, Content)>;

/// A built library made fit to ship: its run path no longer names the folders of the machine
/// that built it (pixi's environment), but only its own folder. The Mojo runtime is then found
/// on the library path or loaded beforehand by the package's loader.
pub(crate) fn relocatable(path: &Path) -> Result<Vec<u8>> {
    let mut bytes = std::fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    if bytes.starts_with(b"\x7fELF") {
        clear_elf_run_path(&mut bytes)
            .with_context(|| format!("resetting the run path of {}", path.display()))?;
        return Ok(bytes);
    }
    if bytes.starts_with(&[0xcf, 0xfa, 0xed, 0xfe]) {
        return macho_without_rpaths(path);
    }
    bail!("{} is neither an ELF nor a Mach-O library", path.display())
}

/// Overwrites every `DT_RUNPATH` and `DT_RPATH` string of a 64-bit little-endian ELF file with
/// `$ORIGIN` (padded with NULs), in place: no section moves.
fn clear_elf_run_path(bytes: &mut [u8]) -> Result<()> {
    let u16_at = |b: &[u8], at: usize| -> Result<u64> {
        let s = b.get(at..at + 2).context("ELF file cut short")?;
        Ok(u64::from(u16::from_le_bytes([s[0], s[1]])))
    };
    let u32_at = |b: &[u8], at: usize| -> Result<u64> {
        let s = b.get(at..at + 4).context("ELF file cut short")?;
        Ok(u64::from(u32::from_le_bytes([s[0], s[1], s[2], s[3]])))
    };
    let u64_at = |b: &[u8], at: usize| -> Result<u64> {
        let s = b.get(at..at + 8).context("ELF file cut short")?;
        let mut a = [0u8; 8];
        a.copy_from_slice(s);
        Ok(u64::from_le_bytes(a))
    };
    let usize_of = |v: u64| usize::try_from(v).context("ELF offset too large");
    if bytes.get(4) != Some(&2) || bytes.get(5) != Some(&1) {
        bail!("only 64-bit little-endian ELF files are handled");
    }
    let shoff = usize_of(u64_at(bytes, 0x28)?)?;
    let shentsize = usize_of(u16_at(bytes, 0x3a)?)?;
    let shnum = usize_of(u16_at(bytes, 0x3c)?)?;
    let section = |b: &[u8], i: usize| -> Result<(u64, usize, usize, usize)> {
        let at = shoff + i * shentsize;
        Ok((
            u32_at(b, at + 4)?,
            usize_of(u64_at(b, at + 0x18)?)?,
            usize_of(u64_at(b, at + 0x20)?)?,
            usize_of(u32_at(b, at + 0x28)?)?,
        ))
    };
    let mut strings = Vec::new();
    for i in 0..shnum {
        let (kind, offset, size, link) = section(bytes, i)?;
        // SHT_DYNAMIC: (tag, value) pairs of 8 bytes each.
        if kind != 6 {
            continue;
        }
        let (_, str_offset, str_size, _) = section(bytes, link)?;
        for entry in (offset..offset + size).step_by(16) {
            let tag = u64_at(bytes, entry)?;
            // DT_RPATH 15, DT_RUNPATH 29.
            if tag == 15 || tag == 29 {
                let at = usize_of(u64_at(bytes, entry + 8)?)?;
                if at < str_size {
                    strings.push(str_offset + at);
                }
            }
        }
    }
    for start in strings {
        let len = bytes[start..]
            .iter()
            .position(|b| *b == 0)
            .context("unterminated run path")?;
        let field = &mut bytes[start..start + len];
        field.fill(0);
        let origin = b"$ORIGIN";
        if len >= origin.len() {
            field[..origin.len()].copy_from_slice(origin);
        }
    }
    Ok(())
}

/// A Mach-O library's bytes with its `LC_RPATH` entries replaced by `@loader_path`
/// (`otool` and `install_name_tool`, on a copy). Not run: no macOS machine.
fn macho_without_rpaths(path: &Path) -> Result<Vec<u8>> {
    let copy = std::env::temp_dir().join(format!(
        "mojo-anything-relocate-{}-{}",
        std::process::id(),
        path.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default()
    ));
    std::fs::copy(path, &copy)?;
    let mut otool = std::process::Command::new("otool");
    otool.arg("-l").arg(&copy);
    let out = crate::process::output(&mut otool, crate::process::BUILD).context("running otool")?;
    let listing = out.stdout_text();
    let mut lines = listing.lines();
    while let Some(line) = lines.next() {
        if line.trim() == "cmd LC_RPATH" {
            let _ = lines.next();
            if let Some(p) = lines.next().and_then(|l| l.trim().strip_prefix("path ")) {
                let old = p.split(" (offset").next().unwrap_or(p).to_string();
                let mut tool = std::process::Command::new("install_name_tool");
                tool.arg("-delete_rpath").arg(&old).arg(&copy);
                crate::process::output(&mut tool, crate::process::BUILD)?;
            }
        }
    }
    let mut tool = std::process::Command::new("install_name_tool");
    tool.arg("-add_rpath").arg("@loader_path").arg(&copy);
    crate::process::output(&mut tool, crate::process::BUILD)?;
    let bytes = std::fs::read(&copy)?;
    let _ = std::fs::remove_file(&copy);
    Ok(bytes)
}

/// `path` relative to the repository root, for workflows (which run from a checkout); a path
/// outside it keeps its last component and is marked for the reader to set.
pub(crate) fn repo_relative(root: &Path, path: &Path) -> String {
    match path.strip_prefix(root) {
        Ok(rel) if !rel.as_os_str().is_empty() => rel.to_string_lossy().replace('\\', "/"),
        Ok(_) => ".".into(),
        Err(_) => path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| ".".into()),
    }
}

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

/// What one kind's generator lays out.
pub(crate) struct Generated {
    pub files: Files,
    pub module: Option<String>,
    pub notes: Vec<String>,
}

/// What every generator is given.
pub(crate) struct Unit<'a> {
    pub dir: &'a Path,
    pub manifest: &'a Manifest,
    pub name: &'a str,
    pub version: &'a str,
    /// The output folder, for paths a workflow names.
    pub out: &'a Path,
}

pub fn package(opts: &Options) -> Result<Outcome> {
    let crate_dir = std::path::absolute(opts.crate_dir)?;
    let manifest = Manifest::load(&crate_dir)?;
    let mut notes = Vec::new();
    let name = opts
        .name
        .clone()
        .unwrap_or_else(|| manifest.crate_name.clone());
    let version = match opts.version.clone().or_else(|| original_version(&manifest)) {
        Some(v) => v,
        None => {
            notes
                .push("No version found beside the original; wrote 0.1.0 (pass --version).".into());
            "0.1.0".into()
        }
    };
    let out = match &opts.out {
        Some(o) => std::path::absolute(o)?,
        None => crate_dir.join("package"),
    };
    let unit = Unit {
        dir: &crate_dir,
        manifest: &manifest,
        name: &name,
        version: &version,
        out: &out,
    };
    let generated = match manifest.kind {
        Kind::MojoPy => crate::package_mojo_py::generate(&unit)?,
        Kind::MojoNode | Kind::MojoWasm => bail!("{NPM_NOT_YET}"),
        Kind::CAbi | Kind::Ffi | Kind::MojoJvm => bail!(
            "packaging {:?} units is not supported yet (see the packaging plan, M7)",
            manifest.kind
        ),
    };
    notes.extend(generated.notes);
    let mut files = Vec::new();
    for (path, content) in &generated.files {
        files.push(path.clone());
        if opts.dry_run {
            continue;
        }
        let target = out.join(path);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        match content {
            Content::Text(text) => std::fs::write(&target, text),
            Content::Binary(bytes) => std::fs::write(&target, bytes),
        }
        .with_context(|| format!("writing {}", target.display()))?;
    }
    Ok(Outcome {
        kind: manifest.kind,
        name,
        version,
        out,
        module: generated.module,
        files,
        dry_run: opts.dry_run,
        notes,
    })
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
