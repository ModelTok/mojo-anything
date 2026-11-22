//! `app lift`: once the front door answers every recorded case through its units, remove the
//! fallback, the kill switches and the units' bindings, and prove the pure binary on the recorded
//! cases: a pure Mojo binary for a CLI, a Rust one for a server or a library (still Cargo apps).
//!
//! The lift is made on a copy of the front door and its units (`mojo/app`, `mojo/app-cases`, the
//! unit folders) and only copied back when every check passes, so a lift
//! that fails leaves the repository as it was.

use crate::walk::Canonical;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail, ensure};
use regex::Regex;
use serde::Serialize;
use toml_edit::{DocumentMut, Item as TomlItem, value};

use crate::app::{self, ReplayOptions, ReplayOutcome};
use crate::front_door::{self, APP_DIR, AppKind, STATE_FILE, State};
use crate::front_door_http as http_door;
use crate::gate::{self, Check};

const BINDING_DEPS: [&str; 5] = ["napi", "napi-derive", "napi-build", "wasm-bindgen", "jni"];
const GENERATED_FILES: [&str; 3] = ["build.rs", "index.cjs", "index.d.ts"];
const GENERATED_DIRS: [&str; 7] = ["python", "go", "ruby", "java", "include", "shadow", "pkg"];
const GENERATED_MODULES: [&str; 5] = ["js", "wire", "pyconv", "utf16", "pynum"];
const ASSET_DIRS: [&str; 9] = [
    "assets",
    "templates",
    "static",
    "data",
    "locales",
    "i18n",
    "public",
    "resources",
    "share",
];
const TARGET_TRIPLE: &str = r"\b(?:x86_64|aarch64|i686|i586|armv7|arm|thumbv7em|wasm32|wasm64|riscv64gc|powerpc64le|s390x|loongarch64)-[a-z0-9_]+(?:-[a-z0-9_]+){1,2}\b";

#[derive(Debug, Clone, Copy, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Mark {
    Pass,
    Warn,
    Fail,
    Skip,
}

/// One line of the lift checklist.
#[derive(Debug, Serialize)]
pub struct Item {
    pub name: String,
    pub mark: Mark,
    pub detail: String,
}

impl Item {
    fn new(name: impl Into<String>, mark: Mark, detail: impl Into<String>) -> Self {
        Item {
            name: name.into(),
            mark,
            detail: detail.into(),
        }
    }

    fn from_check(prefix: &str, check: Check) -> Self {
        Item::new(
            format!("{prefix}: {}", check.name),
            if check.passed { Mark::Pass } else { Mark::Fail },
            check.detail,
        )
    }
}

pub struct LiftOptions<'a> {
    pub repo: &'a Path,
}

#[derive(Debug, Serialize)]
pub struct LiftOutcome {
    pub lifted: bool,
    /// Why the lift did not happen.
    pub blockers: Vec<String>,
    pub checklist: Vec<Item>,
    pub units: Vec<String>,
    /// Files the lift removed, relative to the repository.
    pub removed: Vec<String>,
    pub binary: Option<PathBuf>,
    /// The recorded cases against the lifted binary.
    pub replay: Option<ReplayOutcome>,
    /// The copy the lift was checked in, kept when a check failed.
    pub stage: Option<PathBuf>,
}

impl LiftOutcome {
    fn refused(blockers: Vec<String>, checklist: Vec<Item>, stage: Option<PathBuf>) -> Self {
        LiftOutcome {
            lifted: false,
            blockers,
            checklist,
            units: Vec::new(),
            removed: Vec::new(),
            binary: None,
            replay: None,
            stage,
        }
    }
}

/// Folders a lift neither copies nor touches: build output and tool environments.
fn skipped(name: &std::ffi::OsStr) -> bool {
    name == "target" || name == ".git" || name == ".pixi" || name == ".mojo-anything"
}

fn copy_tree(from: &Path, to: &Path) -> Result<()> {
    std::fs::create_dir_all(to)?;
    for entry in std::fs::read_dir(from)?.flatten() {
        let name = entry.file_name();
        if skipped(&name) {
            continue;
        }
        let kind = entry.file_type()?;
        if kind.is_dir() {
            copy_tree(&entry.path(), &to.join(&name))?;
        } else if kind.is_file() {
            std::fs::copy(entry.path(), to.join(&name))?;
        }
    }
    Ok(())
}

fn files_under(root: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if skipped(&entry.file_name()) {
                continue;
            }
            match entry.file_type() {
                Ok(t) if t.is_dir() => stack.push(path),
                Ok(t) if t.is_file() => out.push(path),
                _ => {}
            }
        }
    }
    out.sort();
    out
}

fn remove_empty_dirs(root: &Path) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.file_type().is_ok_and(|t| t.is_dir()) && !skipped(&entry.file_name()) {
            remove_empty_dirs(&entry.path());
            let _ = std::fs::remove_dir(entry.path());
        }
    }
}

/// Makes `to` hold what `from` holds (its `target/` aside); returns the files removed from `to`.
fn sync(from: &Path, to: &Path) -> Result<Vec<PathBuf>> {
    let mut removed = Vec::new();
    for path in files_under(to) {
        let rel = path.strip_prefix(to).unwrap_or(&path);
        if !from.join(rel).exists() {
            std::fs::remove_file(&path)?;
            removed.push(path);
        }
    }
    copy_tree(from, to)?;
    remove_empty_dirs(to);
    Ok(removed)
}

/// Modules `port.rs` reaches through `crate::` and `super::`, transitively.
fn port_modules(src: &Path) -> BTreeSet<String> {
    let single = Regex::new(r"(?:crate|super)::([A-Za-z_][A-Za-z0-9_]*)").expect("valid regex");
    let group = Regex::new(r"(?:crate|super)::\{([^}]*)\}").expect("valid regex");
    let module_file = |name: &str| -> Option<PathBuf> {
        [
            src.join(format!("{name}.rs")),
            src.join(name).join("mod.rs"),
        ]
        .into_iter()
        .find(|p| p.is_file())
    };
    let mut keep = BTreeSet::new();
    let mut queue = vec![src.join("port.rs")];
    while let Some(file) = queue.pop() {
        let text = std::fs::read_to_string(&file).unwrap_or_default();
        let mut names: Vec<String> = single
            .captures_iter(&text)
            .map(|c| c[1].to_string())
            .collect();
        for c in group.captures_iter(&text) {
            names.extend(
                c[1].split(',')
                    .filter_map(|n| n.split("::").next())
                    .map(|n| n.trim().to_string()),
            );
        }
        for name in names {
            if name == "port" || keep.contains(&name) {
                continue;
            }
            if let Some(path) = module_file(&name) {
                keep.insert(name);
                queue.push(path);
            }
        }
    }
    keep
}

/// Turns a unit crate into a plain library: no `cdylib`, no binding dependencies, `lib.rs` that
/// only exposes `port` (and the modules it uses), and, for a crate `bridge` made, no generated
/// wrappers. Returns the paths it removed.
/// The crates under `rust_dir` that `roots` depend on by path, transitively, roots excluded.
fn path_dependencies(roots: &[PathBuf], rust_dir: &Path) -> Vec<PathBuf> {
    let mut seen: BTreeSet<PathBuf> = roots.iter().cloned().collect();
    let mut found = Vec::new();
    let mut queue: Vec<PathBuf> = roots.to_vec();
    while let Some(dir) = queue.pop() {
        let Ok(text) = std::fs::read_to_string(dir.join("Cargo.toml")) else {
            continue;
        };
        let Ok(doc) = text.parse::<DocumentMut>() else {
            continue;
        };
        for table in ["dependencies", "dev-dependencies", "build-dependencies"] {
            let Some(deps) = doc.get(table).and_then(TomlItem::as_table_like) else {
                continue;
            };
            for (_, dep) in deps.iter() {
                let Some(path) = dep.get("path").and_then(TomlItem::as_str) else {
                    continue;
                };
                let Ok(target) = dir.join(path).canonical() else {
                    continue;
                };
                if target.starts_with(rust_dir) && seen.insert(target.clone()) {
                    found.push(target.clone());
                    queue.push(target);
                }
            }
        }
    }
    found.sort();
    found
}

/// `lib.rs` of a stripped unit: `port` and the generated modules it uses, in the order rustfmt
/// keeps module declarations.
fn stripped_lib_rs(keep: &[String]) -> String {
    let mut modules: Vec<&str> = keep.iter().map(String::as_str).collect();
    modules.push("port");
    modules.sort_unstable();
    modules.dedup();
    modules.iter().map(|m| format!("pub mod {m};\n")).collect()
}

pub fn strip_unit(dir: &Path) -> Result<Vec<PathBuf>> {
    let manifest = crate::bridge::Manifest::load(dir).ok();
    if manifest
        .as_ref()
        .is_some_and(|m| crate::bridge::mojo_unit(m.kind, m.language))
        || (dir.join("port.mojo").is_file() && !dir.join("Cargo.toml").is_file())
    {
        return strip_mojo_unit(dir);
    }
    let cargo = dir.join("Cargo.toml");
    let mut doc: DocumentMut = std::fs::read_to_string(&cargo)
        .with_context(|| format!("reading {}", cargo.display()))?
        .parse()
        .with_context(|| format!("parsing {}", cargo.display()))?;
    if let Some(lib) = doc.get_mut("lib").and_then(TomlItem::as_table_mut) {
        lib.remove("crate-type");
        if lib.is_empty() {
            doc.remove("lib");
        }
    }
    for table in ["dependencies", "build-dependencies"] {
        if let Some(deps) = doc.get_mut(table).and_then(TomlItem::as_table_like_mut) {
            for dep in BINDING_DEPS {
                deps.remove(dep);
            }
        }
    }
    if doc
        .get("build-dependencies")
        .and_then(TomlItem::as_table_like)
        .is_some_and(|t| t.is_empty())
    {
        doc.remove("build-dependencies");
    }
    if let Some(package) = doc.get_mut("package").and_then(TomlItem::as_table_mut) {
        package.remove("build");
    }
    std::fs::write(&cargo, doc.to_string())?;

    let mut removed = Vec::new();
    if !dir.join(crate::bridge::MANIFEST).exists() {
        return Ok(removed);
    }
    let src = dir.join("src");
    let keep = port_modules(&src);
    let kept: Vec<String> = keep.iter().cloned().collect();
    std::fs::write(src.join("lib.rs"), stripped_lib_rs(&kept))?;
    for file in GENERATED_FILES {
        let path = dir.join(file);
        if path.is_file() {
            std::fs::remove_file(&path)?;
            removed.push(path);
        }
    }
    for sub in GENERATED_DIRS {
        let path = dir.join(sub);
        if path.is_dir() {
            removed.extend(files_under(&path));
            std::fs::remove_dir_all(&path)?;
        }
    }
    for module in GENERATED_MODULES {
        let path = src.join(format!("{module}.rs"));
        if !keep.contains(module) && path.is_file() {
            std::fs::remove_file(&path)?;
            removed.push(path);
        }
    }
    for entry in std::fs::read_dir(dir)?.flatten() {
        let path = entry.path();
        if path.extension().is_some_and(|e| e == "node") && path.is_file() {
            std::fs::remove_file(&path)?;
            removed.push(path);
        }
    }
    Ok(removed)
}

/// What the bridges write around a Mojo port for its callers: the Python extension and package,
/// the C exports and header, the JSON dispatcher, the Node-API shim and addon, and the Go and
/// Ruby wrappers.
const MOJO_BRIDGE_FILES: [&str; 8] = [
    "_native.mojo",
    "dispatcher.mojo",
    "exports.mojo",
    "exports_shadow.mojo",
    "node_shim.c",
    "binding.gyp",
    "index.cjs",
    "index.d.ts",
];
const MOJO_BRIDGE_DIRS: [&str; 6] = ["python", "go", "ruby", "include", "shadow", "build"];
/// Helper modules a bridge writes; kept when the port or its tests import them.
const MOJO_HELPERS: [&str; 4] = ["json", "py_num", "pinned", "c_structs"];
const BUILT_LIBRARIES: [&str; 3] = ["so", "node", "dylib"];

/// A Mojo unit without its bridge: `port.mojo`, the modules it or its tests import, its tests,
/// `pixi.toml`, README, manifest and recorded cases stay. Returns the paths it removed.
fn strip_mojo_unit(dir: &Path) -> Result<Vec<PathBuf>> {
    let mut roots = vec!["port".to_string()];
    for entry in std::fs::read_dir(dir)?.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if let Some(test) = name.strip_suffix(".mojo")
            && test.starts_with("test_")
        {
            roots.push(test.to_string());
        }
    }
    let roots: Vec<&str> = roots.iter().map(String::as_str).collect();
    let kept = crate::front_door_mojo::local_modules(dir, &roots);
    let mut removed = Vec::new();
    let helpers = MOJO_HELPERS
        .iter()
        .filter(|h| !kept.iter().any(|k| k == *h))
        .map(|h| format!("{h}.mojo"));
    for file in MOJO_BRIDGE_FILES
        .iter()
        .map(|f| f.to_string())
        .chain(helpers)
    {
        let path = dir.join(&file);
        if path.is_file() {
            std::fs::remove_file(&path)?;
            removed.push(path);
        }
    }
    for sub in MOJO_BRIDGE_DIRS {
        let path = dir.join(sub);
        if path.is_dir() {
            removed.extend(files_under(&path));
            std::fs::remove_dir_all(&path)?;
        }
    }
    for entry in std::fs::read_dir(dir)?.flatten() {
        let path = entry.path();
        if path.is_file()
            && path
                .extension()
                .is_some_and(|e| BUILT_LIBRARIES.iter().any(|b| e == *b))
        {
            std::fs::remove_file(&path)?;
            removed.push(path);
        }
    }
    removed.sort();
    Ok(removed)
}

/// The app's Mojo sources a lift ships: `main.mojo`, `units.mojo` and the glue.
fn app_sources(app_dir: &Path) -> Vec<String> {
    let mut files = vec!["main.mojo".to_string(), "units.mojo".to_string()];
    let mut glue: Vec<String> = std::fs::read_dir(app_dir.join("glue"))
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".mojo"))
        .map(|n| format!("glue/{n}"))
        .collect();
    glue.sort();
    files.extend(glue);
    files
}

/// The names of `files` (name, text) that `mojo format` (from the pixi project `env_dir`) would
/// change, found by formatting copies in `scratch`.
fn unformatted(scratch: &Path, env_dir: &Path, files: &[(String, String)]) -> Result<Vec<String>> {
    if scratch.exists() {
        std::fs::remove_dir_all(scratch)?;
    }
    let mut paths = Vec::new();
    for (i, (_, text)) in files.iter().enumerate() {
        let path = scratch.join(format!("f{i}.mojo"));
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&path, text)?;
        paths.push(path);
    }
    let mut cmd = crate::mojo::command(env_dir)?;
    cmd.arg("format").arg("--quiet").args(&paths);
    let out = crate::process::output(&mut cmd, crate::process::QUICK)?;
    ensure!(
        out.success(),
        "mojo format failed: {}{}",
        out.stdout_text(),
        out.stderr_text()
    );
    let mut differ = Vec::new();
    for ((name, text), path) in files.iter().zip(&paths) {
        if std::fs::read_to_string(path)? != *text {
            differ.push(name.clone());
        }
    }
    let _ = std::fs::remove_dir_all(scratch);
    Ok(differ)
}

/// Whether `main.mojo` is still the one `app front-door` wrote (as `mojo format` left it).
fn generated_main_mojo(repo: &Path, app_dir: &Path, state: &State) -> Result<bool> {
    let main = std::fs::read_to_string(app_dir.join("main.mojo"))?;
    let (_, flags) = front_door::infer_cli(&app::recorded_args(repo)?);
    let generated = crate::front_door_mojo::main_mojo(state, &flags);
    if same_code(&main, &generated) {
        return Ok(true);
    }
    let scratch = app_dir.join(".mojo-anything/format-main");
    Ok(formatted(&scratch, app_dir, &generated)? == main)
}

/// `text` as `mojo format` writes it.
fn formatted(scratch: &Path, env_dir: &Path, text: &str) -> Result<String> {
    std::fs::create_dir_all(scratch)?;
    let path = scratch.join("formatted.mojo");
    std::fs::write(&path, text)?;
    let mut cmd = crate::mojo::command(env_dir)?;
    cmd.arg("format").arg("--quiet").arg(&path);
    let out = crate::process::output(&mut cmd, crate::process::QUICK)?;
    ensure!(out.success(), "mojo format failed: {}", out.stderr_text());
    let text = std::fs::read_to_string(&path)?;
    let _ = std::fs::remove_dir_all(scratch);
    Ok(text)
}

fn same_code(a: &str, b: &str) -> bool {
    let squash = |s: &str| s.split_whitespace().collect::<String>();
    squash(a) == squash(b)
}

fn generated_mains(state: &State) -> Vec<String> {
    match state.kind {
        AppKind::Cli => Vec::new(),
        AppKind::Http => http_door::main_rs_versions(),
        AppKind::Library => Vec::new(),
    }
}

fn is_generated_main(code: &str, state: &State) -> bool {
    generated_mains(state).iter().any(|m| same_code(code, m))
}

fn ship_settings(doc: &mut DocumentMut) {
    if doc["package"].get("rust-version").is_none() {
        doc["package"]["rust-version"] = value(crate::MIN_RUST);
    }
    let release = doc["profile"]["release"].or_insert(toml_edit::table());
    if let Some(release) = release.as_table_like_mut() {
        if release.get("lto").is_none() {
            release.insert("lto", value(true));
        }
        if release.get("codegen-units").is_none() {
            release.insert("codegen-units", value(1));
        }
    }
    if let Some(profile) = doc["profile"].as_table_mut() {
        profile.set_implicit(true);
    }
}

fn lift_library(stage_app: &Path, state: &mut State) -> Result<()> {
    state.lifted = true;
    let _ = std::fs::remove_file(stage_app.join(crate::library::CARGO_CONFIG));
    let lib = stage_app.join("src/lib.rs");
    std::fs::write(&lib, crate::library::lib_rs(state, true))?;
    front_door::rustfmt(&lib);
    std::fs::write(
        stage_app.join(STATE_FILE),
        serde_json::to_string_pretty(state)? + "\n",
    )?;
    let cargo = stage_app.join("Cargo.toml");
    let mut doc: DocumentMut = std::fs::read_to_string(&cargo)?.parse()?;
    doc["package"]["description"] = value(format!(
        "`{}` in Rust, lifted by mojo-anything from its units' ports",
        state.name
    ));
    ship_settings(&mut doc);
    std::fs::write(&cargo, doc.to_string())?;
    Ok(())
}

/// Lifts a server or a library (still Rust apps; a CLI is lifted by [`lift_cli`]).
fn lift_app(stage_app: &Path, state: &mut State) -> Result<()> {
    if state.kind == AppKind::Library {
        return lift_library(stage_app, state);
    }
    let main = stage_app.join("src/main.rs");
    if is_generated_main(&std::fs::read_to_string(&main)?, state) {
        std::fs::write(&main, http_door::lifted_main_rs())?;
    }
    let _ = std::fs::remove_file(stage_app.join("src/original.rs"));
    state.lifted = true;
    let units = stage_app.join("src/units/mod.rs");
    std::fs::write(&units, http_door::units_rs(state, true))?;
    front_door::rustfmt(&units);
    std::fs::write(
        stage_app.join(STATE_FILE),
        serde_json::to_string_pretty(state)? + "\n",
    )?;

    let cargo = stage_app.join("Cargo.toml");
    let mut doc: DocumentMut = std::fs::read_to_string(&cargo)?.parse()?;
    if let Some(description) = doc["package"].get("description").and_then(|d| d.as_str())
        && description.starts_with("Front door for")
    {
        doc["package"]["description"] = value(format!(
            "`{}` in Rust, lifted by mojo-anything from its front door",
            state.name
        ));
    }
    ship_settings(&mut doc);
    if let Some(deps) = doc
        .get_mut("dependencies")
        .and_then(TomlItem::as_table_like_mut)
    {
        deps.remove("reqwest");
    }
    std::fs::write(&cargo, doc.to_string())?;
    front_door::rustfmt(&main);
    Ok(())
}

fn command_output(program: &str, args: &[&str]) -> Option<String> {
    let out = Command::new(program).args(args).output().ok()?;
    out.status
        .success()
        .then(|| String::from_utf8_lossy(&out.stdout).into_owned())
}

fn target_items(repo: &Path, stage_app: &Path, target_dir: &Path) -> Vec<Item> {
    let decisions = repo.join("rust/DECISIONS.md");
    let Ok(text) = std::fs::read_to_string(&decisions) else {
        return vec![Item::new(
            "targets",
            Mark::Skip,
            "no rust/DECISIONS.md: only the host target was built",
        )];
    };
    let triple = Regex::new(TARGET_TRIPLE).expect("valid regex");
    let targets: BTreeSet<&str> = triple.find_iter(&text).map(|m| m.as_str()).collect();
    if targets.is_empty() {
        return vec![Item::new(
            "targets",
            Mark::Skip,
            "rust/DECISIONS.md names no target triple: only the host target was built",
        )];
    }
    let host = command_output("rustc", &["-vV"]).and_then(|v| {
        v.lines()
            .find_map(|l| l.strip_prefix("host: ").map(str::to_string))
    });
    let installed: Vec<String> = command_output("rustup", &["target", "list", "--installed"])
        .map(|t| t.lines().map(str::to_string).collect())
        .unwrap_or_default();
    targets
        .into_iter()
        .map(|target| {
            let name = format!("target {target}");
            if host.as_deref() == Some(target) {
                return Item::new(name, Mark::Pass, "the host: built and tested above");
            }
            if !installed.iter().any(|t| t == target) {
                return Item::new(
                    name,
                    Mark::Skip,
                    format!("not installed here: `rustup target add {target}` to check it"),
                );
            }
            let out = Command::new("cargo")
                .args(["check", "--quiet", "--target", target, "--manifest-path"])
                .arg(stage_app.join("Cargo.toml"))
                .env("CARGO_TARGET_DIR", target_dir)
                .output();
            match out {
                Ok(o) if o.status.success() => {
                    Item::new(name, Mark::Pass, "`cargo check` passes (not linked)")
                }
                Ok(o) => Item::new(
                    name,
                    Mark::Fail,
                    String::from_utf8_lossy(&o.stderr)
                        .lines()
                        .rev()
                        .take(10)
                        .collect::<Vec<_>>()
                        .into_iter()
                        .rev()
                        .collect::<Vec<_>>()
                        .join("\n"),
                ),
                Err(e) => Item::new(name, Mark::Fail, e.to_string()),
            }
        })
        .collect()
}

fn asset_items(repo: &Path, sources: &[PathBuf]) -> Vec<Item> {
    let reads =
        Regex::new(r#"(?:read_to_string|read|read_dir|read_to_end|File::open|open)\(\s*"([^"]+)""#)
            .expect("valid regex");
    let mut items = Vec::new();
    let mut included = String::new();
    for root in sources {
        for file in files_under(root) {
            if file.extension().is_none_or(|e| e != "rs") {
                continue;
            }
            let text = std::fs::read_to_string(&file).unwrap_or_default();
            for line in text.lines().filter(|l| l.contains("include_")) {
                included += line;
            }
            for c in reads.captures_iter(&text) {
                items.push(Item::new(
                    "assets",
                    Mark::Warn,
                    format!(
                        "{} reads `{}` at run time from the working directory: embed it with include_str!/include_bytes! or ship it with the binary",
                        file.file_name().unwrap_or_default().to_string_lossy(),
                        &c[1]
                    ),
                ));
            }
        }
    }
    for dir in ASSET_DIRS {
        if repo.join(dir).is_dir() && !included.contains(dir) {
            items.push(Item::new(
                "assets",
                Mark::Warn,
                format!(
                    "the original has `{dir}/` and no include_str!/include_bytes! names it: embed what the app reads, or ship it with the binary"
                ),
            ));
        }
    }
    if items.is_empty() {
        items.push(Item::new(
            "assets",
            Mark::Pass,
            "no file read at run time from a fixed path, and no asset folder in the original",
        ));
    }
    items
}

/// Why the front door as it is cannot be lifted: a failing build, failing cases, or cases that
/// still fall back (`original` names the file that reports them).
fn front_door_blockers(
    before: Result<ReplayOutcome>,
    library: bool,
    original: &str,
) -> Vec<String> {
    let mut blockers = Vec::new();
    match before {
        Err(e) => blockers.push(format!("the front door does not build: {e:#}")),
        Ok(replay) => {
            if replay.passed != replay.total {
                blockers.push(format!(
                    "{} of {} cases fail against the front door (see {})",
                    replay.total - replay.passed,
                    replay.total,
                    replay.report.display()
                ));
            }
            match &replay.fallback {
                None => blockers.push(format!(
                    "the front door does not report its fallbacks ({original} changed?)"
                )),
                Some(f) if f.cases > 0 => {
                    let mut names = f.names.iter().take(10).cloned().collect::<Vec<_>>();
                    if f.names.len() > 10 {
                        names.push(format!("and {} more", f.names.len() - 10));
                    }
                    blockers.push(if library {
                        format!(
                            "{} of {} exports are still only in the original ({}): wire their units",
                            f.cases,
                            f.total,
                            names.join(", ")
                        )
                    } else {
                        format!(
                            "{} of {} cases still fall back to the original ({}): wire units for them",
                            f.cases,
                            f.total,
                            names.join(", ")
                        )
                    });
                }
                Some(_) => {}
            }
        }
    }
    blockers
}

fn replay_with(repo: &Path, exe: &Path) -> Result<ReplayOutcome> {
    app::replay(&ReplayOptions {
        case: None,
        repo,
        build: Some(&app::shell_quote(&exe.to_string_lossy())),
        timeout_secs: None,
        port: None,
    })
}

fn stage_dir() -> PathBuf {
    std::env::temp_dir().join(format!(
        "mojo-anything-lift-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos())
    ))
}

/// Lifts a CLI front door to a pure Mojo binary: no `original.mojo`, no kill switches, glue
/// that calls only the units' ports, each unit without its bridge.
fn lift_cli(repo: &Path, mut state: State) -> Result<LiftOutcome> {
    ensure!(
        app::Config::load(repo)?.is_some(),
        "no recorded cases: run `app record` first"
    );
    let app_dir = repo.join(APP_DIR);
    let mojo_dir = repo.join("mojo");
    let mut blockers = Vec::new();
    if state.units.is_empty() {
        blockers.push("no unit is wired yet: run `mojo-anything app wire` first".to_string());
    }
    let mut units = Vec::new();
    for unit in &state.units {
        let dir = app_dir
            .join(&unit.path)
            .canonical()
            .with_context(|| format!("unit {} not found at {}", unit.name, unit.path))?;
        if !dir.starts_with(&mojo_dir) {
            blockers.push(format!(
                "{}: lift works on Mojo units under mojo/, and this one is at {}",
                unit.crate_name,
                dir.display()
            ));
        }
        let glue = app_dir.join("glue").join(format!(
            "{}.mojo",
            crate::front_door_mojo::mojo_ident(&unit.name)
        ));
        let glue_text = std::fs::read_to_string(&glue).unwrap_or_default();
        if front_door::is_stub(&glue_text) {
            blockers.push(format!(
                "{}: the glue in {} is still the generated stub",
                unit.name,
                glue.display()
            ));
        } else if calls_original(&glue_text) {
            blockers.push(format!(
                "{}: the glue in {} still hands cases to the original (`original.`): answer them in Mojo, then lift again",
                unit.name,
                glue.display()
            ));
        }
        units.push((unit.clone(), dir));
    }
    let main_generated = generated_main_mojo(repo, &app_dir, &state)?;
    let main = std::fs::read_to_string(app_dir.join("main.mojo")).unwrap_or_default();
    if !main_generated && calls_original(&main) {
        blockers.push(
            "main.mojo was changed and still calls the original: remove `import original`, `original.report_fallbacks()` and `original.run` by hand, then lift again"
                .to_string(),
        );
    }
    let before =
        crate::front_door_mojo::mojo_build(&app_dir).and_then(|exe| replay_with(repo, &exe));
    blockers.extend(front_door_blockers(before, false, "original.mojo"));
    for (unit, dir) in &units {
        if !dir.join(crate::bridge::MANIFEST).exists() {
            continue;
        }
        let checks = gate::gate(dir, &[])?.checks;
        let failed: Vec<&str> = checks
            .iter()
            .filter(|c| !c.passed)
            .map(|c| c.name)
            .collect();
        if !failed.is_empty() {
            blockers.push(format!(
                "{}: gate fails ({}): run `mojo-anything gate {}`",
                unit.crate_name,
                failed.join(", "),
                dir.display()
            ));
        }
    }
    if !blockers.is_empty() {
        return Ok(LiftOutcome::refused(blockers, Vec::new(), None));
    }

    let stage = stage_dir();
    let staged_path = |dir: &Path| stage.join(dir.strip_prefix(repo).unwrap_or(dir));
    let stage_app = staged_path(&app_dir);
    copy_tree(&app_dir, &stage_app)?;
    let cases_dir = app::cases_dir(repo);
    if cases_dir.is_dir() {
        copy_tree(&cases_dir, &staged_path(&cases_dir))?;
    }
    let mut staged_units = Vec::new();
    for (unit, dir) in &units {
        let staged = staged_path(dir);
        copy_tree(dir, &staged)?;
        strip_unit(&staged)?;
        staged_units.push((unit.clone(), dir.clone(), staged));
    }

    // The lifted app: no original, no kill switches, no fallback hook.
    let _ = std::fs::remove_file(stage_app.join("original.mojo"));
    state.lifted = true;
    if main_generated {
        std::fs::write(
            stage_app.join("main.mojo"),
            crate::front_door_mojo::lifted_main_mojo(&state),
        )?;
    }
    std::fs::write(
        stage_app.join("units.mojo"),
        crate::front_door_mojo::units_mojo(&state, true),
    )?;
    for file in app_sources(&stage_app)
        .iter()
        .filter(|f| f.starts_with("glue/"))
    {
        let path = stage_app.join(file);
        let text = std::fs::read_to_string(&path)?;
        let kept: String = text
            .split_inclusive('\n')
            .filter(|l| l.trim() != "import original")
            .collect();
        if kept != text {
            std::fs::write(&path, kept)?;
        }
    }
    std::fs::write(
        stage_app.join(STATE_FILE),
        serde_json::to_string_pretty(&state)? + "\n",
    )?;
    let sources = app_sources(&stage_app);
    let generated: Vec<&str> = ["main.mojo", "units.mojo"]
        .into_iter()
        .filter(|f| *f != "main.mojo" || main_generated)
        .collect();
    crate::front_door_mojo::mojo_format_in(&stage_app, &app_dir, &generated);

    let mut checklist = Vec::new();
    for (unit, _, staged) in &staged_units {
        for check in gate::mojo_checks_in(staged, &app_dir) {
            checklist.push(Item::from_check(&unit.crate_name, check));
        }
    }
    let texts: Vec<(String, String)> = sources
        .iter()
        .map(|f| {
            (
                f.clone(),
                std::fs::read_to_string(stage_app.join(f)).unwrap_or_default(),
            )
        })
        .collect();
    checklist.push(
        match unformatted(&stage_app.join(".mojo-anything/format"), &app_dir, &texts) {
            Ok(differ) if differ.is_empty() => Item::new(
                format!("{APP_DIR}: mojo format"),
                Mark::Pass,
                format!("{} formatted", sources.join(", ")),
            ),
            Ok(differ) => Item::new(
                format!("{APP_DIR}: mojo format"),
                Mark::Fail,
                format!(
                    "not as `mojo format` writes them: {} (run `mojo format` on them in {APP_DIR})",
                    differ.join(", ")
                ),
            ),
            Err(e) => Item::new(
                format!("{APP_DIR}: mojo format"),
                Mark::Fail,
                format!("{e:#}"),
            ),
        },
    );
    let mentions: Vec<&String> = texts
        .iter()
        .filter(|(_, text)| calls_original(text))
        .map(|(name, _)| name)
        .collect();
    checklist.push(Item::new(
        "no original.",
        if mentions.is_empty() {
            Mark::Pass
        } else {
            Mark::Fail
        },
        if mentions.is_empty() {
            "no source of the lifted app calls the original".to_string()
        } else {
            format!(
                "these still call the original: {}",
                mentions
                    .iter()
                    .map(|m| m.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        },
    ));
    let built = crate::front_door_mojo::mojo_build_in(&stage_app, &app_dir);
    let replay = match built {
        Err(e) => {
            checklist.push(Item::new(
                format!("{APP_DIR}: mojo build"),
                Mark::Fail,
                format!("{e:#}"),
            ));
            None
        }
        Ok(exe) => {
            checklist.push(Item::new(
                format!("{APP_DIR}: mojo build"),
                Mark::Pass,
                "`mojo build --Werror` builds the lifted binary",
            ));
            let replay = replay_with(repo, &exe)?;
            checklist.push(Item::new(
                "replay",
                if replay.passed == replay.total {
                    Mark::Pass
                } else {
                    Mark::Fail
                },
                format!(
                    "{}/{} cases pass against the lifted binary",
                    replay.passed, replay.total
                ),
            ));
            let fallbacks = replay.fallback.as_ref().map_or(0, |f| f.cases);
            checklist.push(Item::new(
                "no fallback",
                if fallbacks == 0 {
                    Mark::Pass
                } else {
                    Mark::Fail
                },
                format!(
                    "{fallbacks} fallback line(s) over the whole replay{}",
                    if replay.fallback.is_none() {
                        " (the lifted binary has no fallback hook)"
                    } else {
                        ""
                    }
                ),
            ));
            Some(replay)
        }
    };
    checklist.push(Item::new(
        "replay in CI",
        Mark::Warn,
        format!(
            "Mojo has no test runner for command lines: run `mojo-anything app replay <repo> --build {APP_DIR}/{}/<binary>` in CI",
            crate::front_door_mojo::BUILD_DIR
        ),
    ));
    let mut mojo_sources = vec![stage_app.join("glue")];
    mojo_sources.extend(staged_units.iter().map(|(_, _, s)| s.clone()));
    checklist.extend(mojo_asset_items(repo, &mojo_sources));

    let failed: Vec<String> = checklist
        .iter()
        .filter(|i| i.mark == Mark::Fail)
        .map(|i| format!("{}: {}", i.name, i.detail))
        .collect();
    if !failed.is_empty() {
        let mut outcome = LiftOutcome::refused(failed, checklist, Some(stage));
        outcome.replay = replay;
        return Ok(outcome);
    }
    let mut removed = Vec::new();
    removed.extend(sync(&stage_app, &app_dir)?);
    for (_, dir, staged) in &staged_units {
        removed.extend(sync(staged, dir)?);
    }
    let _ = std::fs::remove_dir_all(&stage);
    let binary = crate::front_door_mojo::mojo_build(&app_dir)?;
    Ok(LiftOutcome {
        lifted: true,
        blockers: Vec::new(),
        checklist,
        units: state.units.iter().map(|u| u.crate_name.clone()).collect(),
        removed: removed
            .iter()
            .map(|p| {
                p.strip_prefix(repo)
                    .unwrap_or(p)
                    .to_string_lossy()
                    .into_owned()
            })
            .collect(),
        binary: Some(binary),
        replay,
        stage: None,
    })
}

/// Whether Mojo source calls into the original's module (`original.run(...)`); prose that
/// ends a sentence with "original." does not count.
fn calls_original(text: &str) -> bool {
    Regex::new(r"(?:^|[^A-Za-z0-9_])original\.[A-Za-z_]")
        .expect("valid regex")
        .is_match(text)
}

/// Files a Mojo unit or glue opens at run time from a fixed path, and asset folders in the
/// original: a binary does not carry them.
fn mojo_asset_items(repo: &Path, sources: &[PathBuf]) -> Vec<Item> {
    let opens = Regex::new(r#"open\(\s*"([^"]+)""#).expect("valid regex");
    let mut items = Vec::new();
    for root in sources {
        for file in files_under(root) {
            if file.extension().is_none_or(|e| e != "mojo") {
                continue;
            }
            let text = std::fs::read_to_string(&file).unwrap_or_default();
            for c in opens.captures_iter(&text) {
                if c[1].starts_with("/dev/") {
                    continue;
                }
                items.push(Item::new(
                    "assets",
                    Mark::Warn,
                    format!(
                        "{} opens `{}` at run time: ship it with the binary",
                        file.file_name().unwrap_or_default().to_string_lossy(),
                        &c[1]
                    ),
                ));
            }
        }
    }
    for dir in ASSET_DIRS {
        if repo.join(dir).is_dir() {
            items.push(Item::new(
                "assets",
                Mark::Warn,
                format!("the original has `{dir}/`: ship what the app reads with the binary"),
            ));
        }
    }
    if items.is_empty() {
        items.push(Item::new(
            "assets",
            Mark::Pass,
            "no file opened at run time from a fixed path, and no asset folder in the original",
        ));
    }
    items
}

pub fn lift(opts: &LiftOptions) -> Result<LiftOutcome> {
    let repo = opts
        .repo
        .canonical()
        .with_context(|| format!("no folder {}", opts.repo.display()))?;
    let mut state = State::load(&repo)?;
    if state.lifted {
        bail!("{} is already lifted", repo.join(APP_DIR).display());
    }
    if state.kind == AppKind::Cli {
        return lift_cli(&repo, state);
    }
    let library = state.kind == AppKind::Library;
    let config = app::Config::load(&repo)?;
    ensure!(
        library || config.is_some(),
        "no recorded cases: run `app record` first"
    );
    let app_dir = repo.join(APP_DIR);
    let rust_dir = repo.join("rust");
    let mut blockers = Vec::new();
    if state.units.is_empty() {
        blockers.push("no unit is wired yet: run `mojo-anything app wire` first".to_string());
    }
    let mut units = Vec::new();
    for unit in &state.units {
        let dir = app_dir
            .join(&unit.path)
            .canonical()
            .with_context(|| format!("unit crate {} not found", unit.path))?;
        if !dir.starts_with(&rust_dir) {
            blockers.push(format!(
                "{}: lift works on unit crates under rust/, and this one is at {}",
                unit.crate_name,
                dir.display()
            ));
        }
        let glue = app_dir
            .join("src/units")
            .join(format!("{}.rs", front_door::ident(&unit.name)));
        let glue_text = std::fs::read_to_string(&glue).unwrap_or_default();
        if !library && front_door::is_stub(&glue_text) {
            blockers.push(format!(
                "{}: the glue in {} is still the generated stub",
                unit.name,
                glue.display()
            ));
        } else if !library && glue_text.contains("original::") {
            blockers.push(format!(
                "{}: the glue in {} still hands cases to the original (`original::`): answer them in Rust, then lift again",
                unit.name,
                glue.display()
            ));
        }
        units.push((unit.clone(), dir));
    }
    let main = std::fs::read_to_string(app_dir.join("src/main.rs")).unwrap_or_default();
    if !library && !is_generated_main(&main, &state) && main.contains("original::") {
        blockers.push(
            "src/main.rs was changed and still calls the original: remove `mod original`, `original::report_fallbacks()` and `original::run` by hand, then lift again"
                .to_string(),
        );
    }

    let target_dir = app_dir.join("target");
    let before = if library {
        crate::library::cargo_build_lib(&app_dir, Some(&target_dir))
            .and_then(|()| crate::library::replay(&repo, &state, None))
    } else {
        front_door::cargo_build(&app_dir, Some(&target_dir)).and_then(|exe| {
            app::replay(&ReplayOptions {
                case: None,
                repo: &repo,
                build: Some(&app::shell_quote(&exe.to_string_lossy())),
                timeout_secs: None,
                port: None,
            })
        })
    };
    let replay_before = match &before {
        Ok(r) => Some((r.passed, r.total)),
        Err(_) => None,
    };
    blockers.extend(front_door_blockers(before, library, "src/original.rs"));
    for (unit, dir) in &units {
        let checks = if dir.join(crate::bridge::MANIFEST).exists() {
            gate::gate(dir, &[])?.checks
        } else {
            let mut checks = gate::rust_checks(dir, &dir.join("target"));
            checks.push(gate::ported_check(dir));
            checks
        };
        let failed: Vec<&str> = checks
            .iter()
            .filter(|c| !c.passed)
            .map(|c| c.name)
            .collect();
        if !failed.is_empty() {
            blockers.push(format!(
                "{}: gate fails ({}): run `mojo-anything gate {}`",
                unit.crate_name,
                failed.join(", "),
                dir.display()
            ));
        }
    }
    if !blockers.is_empty() {
        return Ok(LiftOutcome::refused(blockers, Vec::new(), None));
    }

    let stage = std::env::temp_dir().join(format!(
        "mojo-anything-lift-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_nanos())
    ));
    // The stage mirrors the repository, so the app's relative paths to its units still hold.
    let staged_path = |dir: &Path| stage.join(dir.strip_prefix(&repo).unwrap_or(dir));
    copy_tree(&app_dir, &staged_path(&app_dir))?;
    let cases_dir = app::cases_dir(&repo);
    if cases_dir.is_dir() {
        copy_tree(&cases_dir, &staged_path(&cases_dir))?;
    }
    let mut staged_units = Vec::new();
    for (unit, dir) in &units {
        let staged = staged_path(dir);
        copy_tree(dir, &staged)?;
        strip_unit(&staged)?;
        staged_units.push((unit.clone(), dir.clone(), staged));
    }
    let unit_dirs: Vec<PathBuf> = units.iter().map(|(_, dir)| dir.clone()).collect();
    let mut staged_deps = Vec::new();
    for dir in path_dependencies(&unit_dirs, &rust_dir) {
        if dir == app_dir.canonical().unwrap_or_else(|_| app_dir.clone()) {
            continue;
        }
        let staged = staged_path(&dir);
        copy_tree(&dir, &staged)?;
        strip_unit(&staged)?;
        staged_deps.push((dir, staged));
    }
    let stage_app = staged_path(&app_dir);
    lift_app(&stage_app, &mut state)?;

    let mut checklist = Vec::new();
    for (unit, dir, staged) in &staged_units {
        for check in gate::rust_checks(staged, &dir.join("target")) {
            checklist.push(Item::from_check(&unit.crate_name, check));
        }
    }
    for (dir, staged) in &staged_deps {
        let name = dir
            .file_name()
            .map_or_else(String::new, |n| n.to_string_lossy().into_owned());
        for check in gate::rust_checks(staged, &dir.join("target")) {
            checklist.push(Item::from_check(&name, check));
        }
    }
    for check in gate::rust_checks(&stage_app, &target_dir) {
        checklist.push(Item::from_check(APP_DIR, check));
    }
    checklist.push(Item::new(
        "replay in CI",
        Mark::Warn,
        if library {
            "the recorded cases ran through the units' bindings, which the lift removes: `cargo test` on the crates is what CI keeps; turn the cases that matter into Rust tests"
        } else {
            "trycmd runs command lines only: run `mojo-anything app replay <repo> --build <the binary>` in CI for the HTTP cases"
        },
    ));
    checklist.extend(target_items(&repo, &stage_app, &target_dir));
    let mut sources = vec![stage_app.join("src")];
    sources.extend(staged_units.iter().map(|(_, _, s)| s.join("src")));
    checklist.extend(asset_items(&repo, &sources));

    if library {
        let references = crate::library::original_references(&repo, &state);
        checklist.push(if references.is_empty() {
            Item::new(
                "original package",
                Mark::Pass,
                "nothing in the original names the units' bindings or shadows",
            )
        } else {
            Item::new(
                "original package",
                Mark::Warn,
                format!(
                    "these files use the units' bindings or shadows, which the lift removes; the original stays as reference, so point them back at its own modules: {}",
                    references.join(", ")
                ),
            )
        });
        let unchanged = staged_units.iter().all(|(_, dir, staged)| {
            std::fs::read(dir.join("src/port.rs")).ok()
                == std::fs::read(staged.join("src/port.rs")).ok()
        });
        let built = crate::library::cargo_build_lib(&stage_app, Some(&target_dir));
        let (passed, total) = replay_before.unwrap_or((0, 0));
        checklist.push(Item::new(
            "replay",
            if built.is_ok() && unchanged && passed == total {
                Mark::Pass
            } else {
                Mark::Fail
            },
            match built {
                Err(e) => format!("{e:#}"),
                Ok(()) => format!(
                    "{passed}/{total} recorded cases matched through the bindings before the lift; the lift leaves every port.rs as it was, and the whole API builds as one Rust library"
                ),
            },
        ));
    }
    let built = if library {
        Ok(PathBuf::new())
    } else {
        front_door::cargo_build(&stage_app, Some(&target_dir))
    };
    let replay = match built {
        Ok(_) if library => None,
        Err(e) => {
            checklist.push(Item::new("build", Mark::Fail, format!("{e:#}")));
            None
        }
        Ok(exe) => {
            let replay = app::replay(&ReplayOptions {
                case: None,
                repo: &repo,
                build: Some(&app::shell_quote(&exe.to_string_lossy())),
                timeout_secs: None,
                port: None,
            })?;
            checklist.push(Item::new(
                "replay",
                if replay.passed == replay.total {
                    Mark::Pass
                } else {
                    Mark::Fail
                },
                format!(
                    "{}/{} cases pass against the lifted binary, fallback rate 0 (no fallback path left)",
                    replay.passed, replay.total
                ),
            ));
            Some(replay)
        }
    };
    let failed: Vec<String> = checklist
        .iter()
        .filter(|i| i.mark == Mark::Fail)
        .map(|i| format!("{}: {}", i.name, i.detail))
        .collect();
    if !failed.is_empty() {
        let mut outcome = LiftOutcome::refused(failed, checklist, Some(stage));
        outcome.replay = replay;
        return Ok(outcome);
    }

    let mut removed = Vec::new();
    removed.extend(sync(&stage_app, &app_dir)?);
    for (_, dir, staged) in &staged_units {
        removed.extend(sync(staged, dir)?);
    }
    for (dir, staged) in &staged_deps {
        removed.extend(sync(staged, dir)?);
    }
    let _ = std::fs::remove_dir_all(&stage);
    let binary = if library {
        crate::library::cargo_build_lib(&app_dir, Some(&target_dir))?;
        None
    } else {
        Some(front_door::cargo_build(&app_dir, Some(&target_dir))?)
    };
    Ok(LiftOutcome {
        lifted: true,
        blockers: Vec::new(),
        checklist,
        units: state.units.iter().map(|u| u.crate_name.clone()).collect(),
        removed: removed
            .iter()
            .map(|p| {
                p.strip_prefix(&repo)
                    .unwrap_or(p)
                    .to_string_lossy()
                    .into_owned()
            })
            .collect(),
        binary,
        replay,
        stage: None,
    })
}

#[cfg(test)]
mod tests {
    #[test]
    fn stripped_lib_rs_lists_modules_as_rustfmt_orders_them() {
        assert_eq!(
            super::stripped_lib_rs(&["utf16".into(), "js".into()]),
            "pub mod js;\npub mod port;\npub mod utf16;\n"
        );
    }

    #[test]
    fn path_dependencies_are_found_transitively_under_rust() {
        let root = crate::app::temp_dir("lift-deps").unwrap();
        let rust = root.join("rust");
        let write = |name: &str, deps: &str| {
            let dir = rust.join(name);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(
                dir.join("Cargo.toml"),
                format!("[package]\nname = \"{name}\"\n\n[dependencies]\n{deps}"),
            )
            .unwrap();
        };
        std::fs::create_dir_all(root.join("outside")).unwrap();
        write(
            "unit-rs",
            "shared = { path = \"../shared\" }\nother = { path = \"../../outside\" }\nserde = \"1\"\n",
        );
        write("shared", "leaf = { path = \"../leaf\" }\n");
        write("leaf", "");
        let rust = rust.canonical().unwrap();
        let found = super::path_dependencies(&[rust.join("unit-rs")], &rust);
        std::fs::remove_dir_all(&root).unwrap();
        assert_eq!(found, [rust.join("leaf"), rust.join("shared")]);
    }

    use super::*;

    #[test]
    fn calls_into_the_original_are_found_and_prose_is_not() {
        assert!(calls_original(
            "    return original.run(args)
"
        ));
        assert!(calls_original("original.run_with_stdin(args, data)"));
        assert!(!calls_original(
            "or None to run the
    original.\"\"\"
"
        ));
        assert!(!calls_original("x = my_original.run(args)"));
    }

    #[test]
    fn a_mojo_unit_keeps_its_port_helpers_and_tests() {
        let dir = crate::app::temp_dir("strip-mojo").unwrap();
        for (file, text) in [
            (
                "port.mojo",
                "from json import JsonValue
",
            ),
            ("json.mojo", ""),
            ("py_num.mojo", ""),
            (
                "test_port.mojo",
                "from pinned import x
",
            ),
            ("pinned.mojo", ""),
            ("_native.mojo", ""),
            ("dispatcher.mojo", ""),
            ("lib.so", ""),
            ("python/pkg/__init__.py", ""),
        ] {
            let path = dir.join(file);
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(path, text).unwrap();
        }
        let removed: Vec<String> = strip_unit(&dir)
            .unwrap()
            .iter()
            .map(|p| p.strip_prefix(&dir).unwrap().to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            removed,
            [
                "_native.mojo",
                "dispatcher.mojo",
                "lib.so",
                "py_num.mojo",
                "python/pkg/__init__.py"
            ]
        );
        for kept in ["port.mojo", "json.mojo", "pinned.mojo", "test_port.mojo"] {
            assert!(dir.join(kept).is_file(), "{kept}");
        }
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn port_modules_follow_crate_paths() {
        let dir =
            std::env::temp_dir().join(format!("mojo-anything-lift-mods-{}", std::process::id()));
        let src = dir.join("src");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(
            src.join("port.rs"),
            "use crate::utf16::len;\nuse crate::{helpers, Thing};\n",
        )
        .unwrap();
        std::fs::write(src.join("utf16.rs"), "").unwrap();
        std::fs::write(src.join("helpers.rs"), "use super::deep;\n").unwrap();
        std::fs::write(src.join("deep.rs"), "").unwrap();
        std::fs::write(src.join("wire.rs"), "").unwrap();
        let keep: Vec<String> = port_modules(&src).into_iter().collect();
        assert_eq!(keep, ["deep", "helpers", "utf16"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
