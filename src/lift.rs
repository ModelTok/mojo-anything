//! `app lift`: once the front door answers every recorded case through its units, remove the
//! fallback, the kill switches and the units' bindings, and prove the pure binary on the recorded
//! cases: a pure Mojo binary for a CLI or a server, and a pure Mojo package for a library.
//!
//! The lift is made on a copy of the front door and its units (`mojo/app`, `mojo/app-cases`, the
//! unit folders) and only copied back when every check passes, so a lift
//! that fails leaves the repository as it was.

use crate::walk::Canonical;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};
use regex::Regex;
use serde::Serialize;

use crate::app::{self, ReplayOptions, ReplayOutcome};
use crate::front_door::{self, APP_DIR, AppKind, STATE_FILE, State};
use crate::front_door_http as http_door;
use crate::gate::{self, Check};

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

/// A unit without its bridge (see [`strip_mojo_unit`]); refuses a folder with no `port.mojo`,
/// which no front door wires (a Java or Kotlin unit bridged to Rust with `--kind ffi`), and a
/// `mojo-jvm` unit, which no front door wires yet either.
pub fn strip_unit(dir: &Path) -> Result<Vec<PathBuf>> {
    ensure!(
        dir.join("port.mojo").is_file(),
        "{} has no port.mojo: lift strips Mojo units only (Java and Kotlin units move to Mojo with M5)",
        dir.display()
    );
    if let Ok(m) = crate::bridge::Manifest::load(dir) {
        ensure!(
            m.kind != crate::bridge::Kind::MojoJvm,
            "{} is a Java or Kotlin unit ported to Mojo (`mojo-jvm`): front doors do not wire \
             those yet, so lift does not strip them",
            dir.display()
        );
    }
    strip_mojo_unit(dir)
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

/// The app's Mojo sources a lift ships: `main.mojo`, `units.mojo`, a server's `http.mojo` and
/// the glue.
fn app_sources(app_dir: &Path) -> Vec<String> {
    let mut files = vec!["main.mojo".to_string(), "units.mojo".to_string()];
    if app_dir.join("http.mojo").is_file() {
        files.push("http.mojo".to_string());
    }
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

/// The arguments every start of a recorded server gets (`--port {port}`); none for a CLI.
fn server_args(repo: &Path) -> Result<Vec<String>> {
    Ok(app::Config::load(repo)?
        .and_then(|c| c.http)
        .map(|h| h.args)
        .unwrap_or_default())
}

/// Whether `main.mojo` is still the one `app front-door` wrote (as `mojo format` left it).
fn generated_main_mojo(repo: &Path, app_dir: &Path, state: &State) -> Result<bool> {
    let main = std::fs::read_to_string(app_dir.join("main.mojo"))?;
    let generated = if state.kind == AppKind::Http {
        http_door::main_mojo_http(state, &server_args(repo)?)
    } else {
        let (_, flags) = front_door::infer_cli(&app::recorded_args(repo)?);
        crate::front_door_mojo::main_mojo(state, &flags)
    };
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

/// Lifts a CLI or server front door to a pure Mojo binary: no `original.mojo`, no kill
/// switches, glue that calls only the units' ports, each unit without its bridge.
fn lift_binary(repo: &Path, mut state: State) -> Result<LiftOutcome> {
    let server = state.kind == AppKind::Http;
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
            if server {
                http_door::lifted_main_mojo_http(&state, &server_args(repo)?)
            } else {
                crate::front_door_mojo::lifted_main_mojo(&state)
            },
        )?;
    }
    std::fs::write(
        stage_app.join("units.mojo"),
        if server {
            http_door::units_mojo_http(&state, true)
        } else {
            crate::front_door_mojo::units_mojo(&state, true)
        },
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
            "Mojo has no test runner for {}: run `mojo-anything app replay <repo> --build {APP_DIR}/{}/<binary>` in CI",
            if server { "HTTP cases" } else { "command lines" },
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

/// Lifts a library front door to a pure Mojo package: `__init__.mojo` re-exports each unit's
/// port with no kill switches or bindings left, each unit without its bridge.
fn lift_library(repo: &Path, mut state: State) -> Result<LiftOutcome> {
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
        units.push((unit.clone(), dir));
    }
    let before = crate::library::mojo_build_lib(&app_dir)
        .and_then(|_| crate::library::replay(repo, &state, None));
    let replay_before = before.as_ref().ok().map(|r| (r.passed, r.total));
    blockers.extend(front_door_blockers(before, true, crate::library::INIT_FILE));
    for (unit, dir) in &units {
        let checks = if dir.join(crate::bridge::MANIFEST).exists() {
            gate::gate(dir, &[])?.checks
        } else {
            gate::mojo_checks(dir)
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

    let stage = stage_dir();
    let staged_path = |dir: &Path| stage.join(dir.strip_prefix(repo).unwrap_or(dir));
    let stage_app = staged_path(&app_dir);
    copy_tree(&app_dir, &stage_app)?;
    let mut staged_units = Vec::new();
    for (unit, dir) in &units {
        let staged = staged_path(dir);
        copy_tree(dir, &staged)?;
        strip_unit(&staged)?;
        staged_units.push((unit.clone(), dir.clone(), staged));
    }
    state.lifted = true;
    let init = crate::library::INIT_FILE;
    std::fs::write(stage_app.join(init), crate::library::lib_mojo(&state, true))?;
    std::fs::write(
        stage_app.join(STATE_FILE),
        serde_json::to_string_pretty(&state)? + "\n",
    )?;
    crate::front_door_mojo::mojo_format_in(&stage_app, &app_dir, &[init]);

    let mut checklist = Vec::new();
    for (unit, _, staged) in &staged_units {
        for check in gate::mojo_checks_in(staged, &app_dir) {
            checklist.push(Item::from_check(&unit.crate_name, check));
        }
    }
    let text = std::fs::read_to_string(stage_app.join(init)).unwrap_or_default();
    checklist.push(
        match unformatted(
            &stage_app.join(".mojo-anything/format"),
            &app_dir,
            &[(init.to_string(), text)],
        ) {
            Ok(differ) if differ.is_empty() => Item::new(
                format!("{APP_DIR}: mojo format"),
                Mark::Pass,
                format!("{init} formatted"),
            ),
            Ok(_) => Item::new(
                format!("{APP_DIR}: mojo format"),
                Mark::Fail,
                format!("{init} is not as `mojo format` writes it (run `mojo format {init}` in {APP_DIR})"),
            ),
            Err(e) => Item::new(
                format!("{APP_DIR}: mojo format"),
                Mark::Fail,
                format!("{e:#}"),
            ),
        },
    );
    let unchanged = staged_units.iter().all(|(_, dir, staged)| {
        std::fs::read(dir.join("port.mojo")).ok() == std::fs::read(staged.join("port.mojo")).ok()
    });
    match crate::library::mojo_build_lib_in(&stage_app, &app_dir) {
        Ok(_) => checklist.push(Item::new(
            format!("{APP_DIR}: mojo precompile"),
            Mark::Pass,
            "`mojo precompile` builds the lifted package from the units' ports",
        )),
        Err(e) => checklist.push(Item::new(
            format!("{APP_DIR}: mojo precompile"),
            Mark::Fail,
            format!("{e:#}"),
        )),
    }
    let (passed, total) = replay_before.unwrap_or((0, 0));
    checklist.push(Item::new(
        "replay",
        if unchanged && passed == total {
            Mark::Pass
        } else {
            Mark::Fail
        },
        format!(
            "{passed}/{total} recorded cases matched through the bindings before the lift; the lift leaves every port.mojo as it was"
        ),
    ));
    checklist.push(Item::new(
        "replay in CI",
        Mark::Warn,
        "the recorded cases ran through the units' bindings, which the lift removes: each unit's test_*.mojo is what CI keeps; turn the cases that matter into Mojo tests",
    ));
    let references = crate::library::original_references(repo, &state);
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
    let sources: Vec<PathBuf> = staged_units.iter().map(|(_, _, s)| s.clone()).collect();
    checklist.extend(mojo_asset_items(repo, &sources));

    let failed: Vec<String> = checklist
        .iter()
        .filter(|i| i.mark == Mark::Fail)
        .map(|i| format!("{}: {}", i.name, i.detail))
        .collect();
    if !failed.is_empty() {
        return Ok(LiftOutcome::refused(failed, checklist, Some(stage)));
    }
    let mut removed = Vec::new();
    removed.extend(sync(&stage_app, &app_dir)?);
    for (_, dir, staged) in &staged_units {
        removed.extend(sync(staged, dir)?);
    }
    let _ = std::fs::remove_dir_all(&stage);
    let package = crate::library::mojo_build_lib(&app_dir)?;
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
        binary: Some(package),
        replay: None,
        stage: None,
    })
}

/// Whether Mojo source calls into the original's module (`original.run(...)`); prose that
/// ends a sentence with "original." does not count.
pub(crate) fn calls_original(text: &str) -> bool {
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
    let state = State::load(&repo)?;
    if state.lifted {
        bail!("{} is already lifted", repo.join(APP_DIR).display());
    }
    match state.kind {
        AppKind::Cli | AppKind::Http => lift_binary(&repo, state),
        AppKind::Library => lift_library(&repo, state),
    }
}

#[cfg(test)]
mod tests {
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
}
