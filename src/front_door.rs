//! The front door: `mojo/app`, which owns an app's entry point from day one and runs the original
//! for everything not ported yet (a Mojo binary for a CLI, see `front_door_mojo`; still a Cargo
//! project for a server or a library), and `wire`, which hands commands to a unit's port behind a
//! kill switch.

use crate::walk::Canonical;
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail, ensure};
use serde::{Deserialize, Serialize};
use toml_edit::{DocumentMut, InlineTable, value};

use crate::app::{self, ReplayOptions, ReplayOutcome};
use crate::front_door_http as http_door;
use crate::front_door_mojo as mojo_door;

pub const APP_DIR: &str = "mojo/app";
pub const STATE_FILE: &str = "mojo-anything.json";
pub const KILL_SWITCH_PREFIX: &str = "MOJO_ANYTHING_UNIT_";
const SCHEMA: &str = "mojo-anything/app@1";
/// Where rust-anything kept its front door.
const OLD_APP_DIR: &str = "rust/app";
const GLUE_MARKER: &str = "unimplemented!(\"glue for";

/// The glue file still holds a stub `wire` wrote (Rust or Mojo), however it was formatted.
pub fn is_stub(glue: &str) -> bool {
    let squash = |s: &str| s.split_whitespace().collect::<String>();
    let glue = squash(glue);
    glue.contains(&squash(GLUE_MARKER)) || glue.contains(&squash(mojo_door::GLUE_MARKER))
}

/// `mojo/app/mojo-anything.json`: the commands the front door routes and the units wired to them.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct State {
    pub schema: String,
    pub name: String,
    pub commands: Vec<String>,
    #[serde(default)]
    pub units: Vec<WiredUnit>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub lifted: bool,
    #[serde(default, skip_serializing_if = "AppKind::is_cli")]
    pub kind: AppKind,
    /// Servers: the requests recorded, as `METHOD /path`, to choose routes from.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub routes: Vec<String>,
    /// Libraries: the public API, unit by unit.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub api: Vec<crate::library::ApiUnit>,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AppKind {
    #[default]
    Cli,
    Http,
    Library,
}

impl AppKind {
    fn is_cli(&self) -> bool {
        *self == AppKind::Cli
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WiredUnit {
    pub name: String,
    #[serde(rename = "crate")]
    pub crate_name: String,
    pub path: String,
    #[serde(default)]
    pub commands: Vec<String>,
    /// Servers: the routes the unit answers.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub routes: Vec<String>,
    pub switch: String,
    /// Libraries: the unit id the crate ports.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub unit: Option<String>,
    /// Libraries: the shadow drop-in the original package imports in place of the unit.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shadow: Option<String>,
    /// Libraries: exports that stay in the original language.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub kept: Vec<String>,
}

impl State {
    pub fn load(repo: &Path) -> Result<State> {
        let path = repo.join(APP_DIR).join(STATE_FILE);
        if !path.is_file() {
            let old = repo.join(OLD_APP_DIR);
            if [crate::bridge::OLD_MANIFEST, STATE_FILE]
                .iter()
                .any(|f| old.join(f).is_file())
            {
                bail!(
                    "{} is a Rust front door from before the move to Mojo: run `mojo-anything app front-door` again to scaffold {APP_DIR}",
                    old.display()
                );
            }
        }
        let text = std::fs::read_to_string(&path).with_context(|| {
            format!(
                "reading {}: run `mojo-anything app front-door` first",
                path.display()
            )
        })?;
        let value: serde_json::Value =
            serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
        let schema = value["schema"].as_str().unwrap_or_default();
        ensure!(
            schema == SCHEMA,
            "{} was written by an older front door (schema `{schema}`, not `{SCHEMA}`): move it aside and run `mojo-anything app front-door` again",
            path.display()
        );
        serde_json::from_value(value).with_context(|| format!("parsing {}", path.display()))
    }

    fn save(&self, repo: &Path) -> Result<()> {
        let path = repo.join(APP_DIR).join(STATE_FILE);
        std::fs::write(&path, serde_json::to_string_pretty(self)? + "\n")
            .with_context(|| format!("writing {}", path.display()))
    }
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Flag {
    pub long: Option<String>,
    pub short: Option<char>,
    pub takes_value: bool,
}

pub(crate) fn package_name(name: &str) -> String {
    let mut out: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '-' || c == '_' {
                c.to_ascii_lowercase()
            } else {
                '-'
            }
        })
        .collect();
    out = out.trim_matches('-').to_string();
    if out.is_empty() || out.starts_with(|c: char| c.is_ascii_digit()) {
        out = format!("app-{out}").trim_end_matches('-').to_string();
    }
    out
}

/// `MOJO_ANYTHING_UNIT_<NAME>`, the variable that sends a unit back to the original.
pub fn kill_switch(crate_name: &str) -> String {
    let name = unit_name(crate_name);
    format!(
        "{KILL_SWITCH_PREFIX}{}",
        ident(name).trim_start_matches("unit_").to_uppercase()
    )
}

/// The unit's name without the `-mojo` suffix `bridge` gives its folder (or the `-rs` of a
/// unit still bridged to Rust).
pub(crate) fn unit_name(crate_name: &str) -> &str {
    crate_name
        .strip_suffix("-mojo")
        .or_else(|| crate_name.strip_suffix("-rs"))
        .unwrap_or(crate_name)
}

/// `path` as the front door names it: relative to `mojo/app` when it is inside the repository.
pub(crate) fn from_app_dir(repo: &Path, path: &Path) -> String {
    match path.strip_prefix(repo) {
        Ok(rel) => {
            let up = "../".repeat(Path::new(APP_DIR).components().count());
            format!("{up}{}", rel.to_string_lossy().replace('\\', "/"))
        }
        Err(_) => path.to_string_lossy().into_owned(),
    }
}

pub(crate) fn ident(name: &str) -> String {
    let mut out: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    let keywords = [
        "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn",
        "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
        "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
        "where", "while", "async", "await", "dyn", "gen", "try",
    ];
    if out.is_empty()
        || out.starts_with(|c: char| c.is_ascii_digit())
        || keywords.contains(&out.as_str())
    {
        out = format!("unit_{out}");
    }
    out
}

/// The commands (first arguments of cases the original ran successfully) and the flags seen with
/// each; the key `""` holds the flags of an app without commands.
pub(crate) fn infer_cli(
    cases: &[(Vec<String>, bool)],
) -> (Vec<String>, BTreeMap<String, BTreeMap<String, Flag>>) {
    let commands: BTreeSet<String> = cases
        .iter()
        .filter(|(args, ok)| *ok && args.first().is_some_and(|a| app::is_word(a)))
        .map(|(args, _)| args[0].clone())
        .collect();
    let mut flags: BTreeMap<String, BTreeMap<String, Flag>> = BTreeMap::new();
    for (args, ok) in cases {
        if !ok {
            continue;
        }
        let (key, rest) = match args.split_first() {
            Some((first, rest)) if commands.contains(first) => (first.clone(), rest),
            _ if commands.is_empty() => (String::new(), args.as_slice()),
            _ => continue,
        };
        let entry = flags.entry(key).or_default();
        for arg in rest {
            if arg == "--" {
                break;
            }
            if let Some(long) = arg.strip_prefix("--") {
                let (name, has_value) = match long.split_once('=') {
                    Some((n, _)) => (n, true),
                    None => (long, false),
                };
                let valid = !name.is_empty()
                    && name
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_');
                if valid {
                    let id = if name == "args" { "flag-args" } else { name };
                    let flag = entry.entry(id.to_string()).or_default();
                    flag.long = Some(name.to_string());
                    flag.takes_value |= has_value;
                }
            } else if let Some(short) = arg.strip_prefix('-') {
                let mut chars = short.chars();
                if let (Some(c), None) = (chars.next(), chars.next())
                    && c.is_ascii_alphabetic()
                {
                    entry.entry(format!("short-{c}")).or_default().short = Some(c);
                }
            }
        }
    }
    (commands.into_iter().collect(), flags)
}

pub(crate) fn rustfmt(file: &Path) {
    let _ = Command::new("rustfmt")
        .args(["--edition", "2024"])
        .arg(file)
        .output();
}

/// Set when mojo-anything builds a front door: the repository the original runs from, so a
/// `rust/` that is a symlink to a folder elsewhere still finds it.
pub(crate) const REPO_ENV: &str = "MOJO_ANYTHING_REPO";

pub(crate) fn cargo_build(app_dir: &Path, target_dir: Option<&Path>) -> Result<PathBuf> {
    let mut cmd = Command::new("cargo");
    cmd.args([
        "build",
        "--message-format=json-render-diagnostics",
        "--manifest-path",
    ])
    .arg(app_dir.join("Cargo.toml"));
    if let Some(repo) = app_dir.parent().and_then(Path::parent)
        && let Ok(repo) = repo.canonical()
    {
        cmd.env(REPO_ENV, repo);
    }
    if let Some(dir) = target_dir {
        cmd.env("CARGO_TARGET_DIR", dir);
    }
    let out = cmd.output().context("running cargo")?;
    ensure!(
        out.status.success(),
        "cargo build in {} failed:\n{}",
        app_dir.display(),
        String::from_utf8_lossy(&out.stderr)
    );
    let mut exe = None;
    for line in String::from_utf8_lossy(&out.stdout).lines() {
        let Ok(msg) = serde_json::from_str::<serde_json::Value>(line) else {
            continue;
        };
        let is_bin = msg["target"]["kind"]
            .as_array()
            .is_some_and(|k| k.iter().any(|v| v == "bin"));
        if msg["reason"] == "compiler-artifact"
            && is_bin
            && let Some(path) = msg["executable"].as_str()
        {
            exe = Some(PathBuf::from(path));
        }
    }
    exe.context("cargo built no binary")
}

fn build_and_replay(repo: &Path, state: &State) -> Result<ReplayOutcome> {
    let app_dir = repo.join(APP_DIR);
    let target_dir = app_dir.join("target");
    if state.kind == AppKind::Library {
        crate::library::mojo_build_lib(&app_dir)?;
        return crate::library::replay(repo, state, None);
    }
    let exe = if state.kind == AppKind::Cli {
        mojo_door::mojo_build(&app_dir)?
    } else {
        cargo_build(&app_dir, Some(&target_dir))?
    };
    app::replay(&ReplayOptions {
        case: None,
        repo,
        build: Some(&app::shell_quote(&exe.to_string_lossy())),
        timeout_secs: None,
        port: None,
    })
}

pub struct FrontDoorOptions<'a> {
    pub repo: &'a Path,
    /// Treat the repository as a library even when it has a `main` (a demo, a test runner).
    pub library: bool,
    /// Build the front door and replay the recorded cases against it.
    pub check: bool,
}

#[derive(Debug, Serialize)]
pub struct FrontDoorOutcome {
    pub dir: PathBuf,
    pub binary: String,
    pub commands: Vec<String>,
    /// Servers: the recorded requests, as `METHOD /path`.
    pub routes: Vec<String>,
    /// Libraries: the public API, unit by unit.
    pub api: Vec<crate::library::ApiUnit>,
    pub flags: BTreeMap<String, BTreeMap<String, Flag>>,
    pub files: Vec<String>,
    pub replay: Option<ReplayOutcome>,
}

pub fn front_door(opts: &FrontDoorOptions) -> Result<FrontDoorOutcome> {
    let repo = opts
        .repo
        .canonical()
        .with_context(|| format!("no folder {}", opts.repo.display()))?;
    let config = app::Config::load(&repo)?;
    let config = match config {
        Some(c) if !opts.library => c,
        _ => {
            let report = crate::analyze::analyze(&repo)?;
            let shape = crate::whole_app::whole_app(&repo, &report).shape;
            ensure!(
                opts.library || shape == "library",
                "no recorded cases in {}: run `mojo-anything app record` first (or --library if this {shape} is used as a library)",
                app::cases_dir(&repo).display()
            );
            return library_front_door(&repo, opts, &report);
        }
    };
    let dir = repo.join(APP_DIR);
    ensure!(
        !dir.exists(),
        "{} already exists; the front door is yours once scaffolded (remove it to scaffold again)",
        dir.display()
    );
    let binary = package_name(&config.name);
    if let Some(http) = &config.http {
        ensure!(
            http.port.is_none(),
            "the front door starts the original on a port of its own: make the original take its port from PORT or `{{port}}` in its command, then record again without --port"
        );
        let routes = crate::http::recorded_routes(&repo)?;
        let state = State {
            schema: SCHEMA.to_string(),
            name: config.name.clone(),
            commands: Vec::new(),
            units: Vec::new(),
            lifted: false,
            kind: AppKind::Http,
            routes: routes.clone(),
            api: Vec::new(),
        };
        let files: Vec<(&str, String)> = vec![
            ("Cargo.toml", http_door::cargo_toml(&binary, &config.name)),
            (".gitignore", "/target\n".to_string()),
            ("src/main.rs", http_door::main_rs()),
            (
                "src/original.rs",
                http_door::original_rs(&config.run, http.fresh.is_empty()),
            ),
            ("src/units/mod.rs", http_door::units_rs(&state, false)),
        ];
        return finish_front_door(
            &repo,
            opts,
            state,
            files,
            binary,
            Vec::new(),
            BTreeMap::new(),
            routes,
        );
    }
    let (commands, flags) = infer_cli(&app::recorded_args(&repo)?);
    let state = State {
        schema: SCHEMA.to_string(),
        name: config.name.clone(),
        commands: commands.clone(),
        units: Vec::new(),
        lifted: false,
        kind: AppKind::Cli,
        routes: Vec::new(),
        api: Vec::new(),
    };
    let files: Vec<(&str, String)> = vec![
        ("pixi.toml", mojo_door::pixi_toml_app(&binary, false)),
        (".gitignore", "/.pixi/\n/.mojo-anything/\n".to_string()),
        ("main.mojo", mojo_door::main_mojo(&state, &flags)),
        (
            "original.mojo",
            mojo_door::original_mojo(&config.run, false),
        ),
        ("units.mojo", mojo_door::units_mojo(&state, false)),
    ];
    finish_front_door(
        &repo,
        opts,
        state,
        files,
        binary,
        commands,
        flags,
        Vec::new(),
    )
}
#[allow(clippy::too_many_arguments)]
fn finish_front_door(
    repo: &Path,
    opts: &FrontDoorOptions,
    state: State,
    files: Vec<(&str, String)>,
    binary: String,
    commands: Vec<String>,
    flags: BTreeMap<String, BTreeMap<String, Flag>>,
    routes: Vec<String>,
) -> Result<FrontDoorOutcome> {
    let repo = repo.to_path_buf();
    let dir = repo.join(APP_DIR);
    let state_api = state.api.clone();
    for (path, text) in &files {
        let target = dir.join(path);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&target, text).with_context(|| format!("writing {}", target.display()))?;
    }
    match state.kind {
        AppKind::Library => mojo_door::mojo_format(&dir, &[crate::library::INIT_FILE]),
        AppKind::Http => rustfmt(&dir.join("src/main.rs")),
        AppKind::Cli => mojo_door::mojo_format(&dir, &mojo_door::SOURCES),
    }
    state.save(&repo)?;
    let replay = if opts.check {
        Some(build_and_replay(&repo, &state)?)
    } else {
        None
    };
    let mut written: Vec<String> = files.iter().map(|(p, _)| p.to_string()).collect();
    written.push(STATE_FILE.to_string());
    Ok(FrontDoorOutcome {
        dir,
        binary,
        commands,
        routes,
        api: state_api,
        flags,
        files: written,
        replay,
    })
}

fn library_front_door(
    repo: &Path,
    opts: &FrontDoorOptions,
    report: &crate::analyze::Report,
) -> Result<FrontDoorOutcome> {
    let name = report
        .packages
        .first()
        .map(|p| p.name.clone())
        .filter(|n| !n.is_empty())
        .or_else(|| repo.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "lib".to_string());
    let package = crate::library::package_ident(&name);
    let state = State {
        schema: SCHEMA.to_string(),
        name: name.clone(),
        commands: Vec::new(),
        units: Vec::new(),
        lifted: false,
        kind: AppKind::Library,
        routes: Vec::new(),
        api: crate::library::public_api(repo, report),
    };
    ensure!(
        !state.api.is_empty(),
        "no exported function or class found to make a public API from"
    );
    let files: Vec<(&str, String)> = vec![
        (
            "pixi.toml",
            mojo_door::pixi_toml_app(&package_name(&name), false),
        ),
        (".gitignore", "/.pixi/\n/.mojo-anything/\n".to_string()),
        (
            crate::library::INIT_FILE,
            crate::library::lib_mojo(&state, false),
        ),
    ];
    finish_front_door(
        repo,
        opts,
        state,
        files,
        package,
        Vec::new(),
        BTreeMap::new(),
        Vec::new(),
    )
}

/// `wire` for a library: a Mojo unit `bridge` made becomes a module of the package in
/// `mojo/app`, and the original package reaches it through its shadow drop-in.
fn library_wire(repo: &Path, opts: &WireOptions, mut state: State) -> Result<WireOutcome> {
    ensure!(
        opts.commands.is_empty() && opts.routes.is_empty(),
        "{} is a library: a unit answers its own exports, so wire takes no --command or --route",
        state.name
    );
    let unit_dir = find_mojo_unit(repo, opts.unit, "the library front door is a Mojo package")?;
    let manifest = crate::bridge::Manifest::load(&unit_dir).with_context(|| {
        format!(
            "a library unit is one `bridge` made (the original package calls it through its bindings), and {} has no manifest",
            unit_dir.display()
        )
    })?;
    let crate_name = manifest.crate_name.clone();
    let name = unit_name(&crate_name).to_string();
    let switch = kill_switch(&crate_name);
    let gate = if opts.skip_gate {
        None
    } else {
        let outcome = crate::gate::gate(&unit_dir, &[])?;
        if !outcome.passed {
            let failed: Vec<String> = outcome
                .checks
                .iter()
                .filter(|c| !c.passed)
                .map(|c| c.name.to_string())
                .collect();
            bail!(
                "{crate_name} does not pass gate ({}): run `mojo-anything gate {}` and fix it before wiring",
                failed.join(", "),
                unit_dir.display()
            );
        }
        Some(true)
    };
    let api = crate::library::api_unit(&state, &manifest.unit)?.clone();
    let app_dir = repo.join(APP_DIR);
    let previous = state.units.iter().position(|u| u.name == name);
    let shadow = crate::library::shadow_for(
        &unit_dir,
        previous.and_then(|i| state.units[i].shadow.as_deref()),
    )?;
    let entry = WiredUnit {
        name: name.clone(),
        crate_name,
        path: from_app_dir(repo, &unit_dir),
        commands: Vec::new(),
        routes: Vec::new(),
        switch: switch.clone(),
        unit: Some(api.unit.clone()),
        shadow: shadow.as_ref().map(|p| p.to_string_lossy().into_owned()),
        kept: manifest.js_only.iter().map(|j| j.name.clone()).collect(),
    };
    match previous {
        Some(i) => state.units[i] = entry,
        None => state.units.push(entry),
    }
    let init = app_dir.join(crate::library::INIT_FILE);
    std::fs::write(&init, crate::library::lib_mojo(&state, false))?;
    mojo_door::mojo_format(&app_dir, &[crate::library::INIT_FILE]);
    if mojo_door::port_modules(&unit_dir)
        .iter()
        .any(|m| m == "json")
    {
        mojo_door::add_json_dependency(&app_dir)?;
    }
    state.save(repo)?;
    let replay = if opts.check {
        Some(build_and_replay(repo, &state)?)
    } else {
        None
    };
    Ok(WireOutcome {
        shadow,
        unit: name,
        crate_dir: unit_dir,
        commands: Vec::new(),
        routes: Vec::new(),
        switch,
        glue: init,
        glue_pending: false,
        gate,
        replay,
    })
}

fn find_unit(repo: &Path, unit: &str) -> Result<PathBuf> {
    let rust = repo.join("rust");
    for candidate in [
        rust.join(unit),
        rust.join(format!("{unit}-rs")),
        repo.join(unit),
        PathBuf::from(unit),
    ] {
        if candidate.join("Cargo.toml").is_file() && candidate != repo.join(APP_DIR) {
            return Ok(candidate.canonical()?);
        }
    }
    let wanted = unit.trim_end_matches('/');
    if let Ok(entries) = std::fs::read_dir(&rust) {
        for entry in entries.flatten() {
            if let Ok(m) = crate::bridge::Manifest::load(&entry.path())
                && m.unit.trim_end_matches('/') == wanted
            {
                return Ok(entry.path().canonical()?);
            }
        }
    }
    refuse_mojo_unit(repo, unit)?;
    bail!(
        "no unit crate `{unit}`: give the crate folder (`rust/<name>`, as `bridge` made it) or the unit id"
    )
}

/// Fails with a clear message when `unit` names a Mojo unit (a folder or a unit id under
/// `mojo/`): the front door, `wire` and `lift` still build a Rust app around Rust crates.
fn refuse_mojo_unit(repo: &Path, unit: &str) -> Result<()> {
    let mojo = repo.join("mojo");
    let wanted = unit.trim_end_matches('/');
    let mut candidates = vec![repo.join(unit), PathBuf::from(unit), mojo.join(unit)];
    if let Ok(entries) = std::fs::read_dir(&mojo) {
        candidates.extend(entries.flatten().map(|e| e.path()));
    }
    for dir in candidates {
        if !dir.join(crate::bridge::MANIFEST).is_file() {
            continue;
        }
        let Ok(m) = crate::bridge::Manifest::load(&dir) else {
            continue;
        };
        let named = dir == repo.join(unit) || dir == Path::new(unit) || dir == mojo.join(unit);
        if matches!(
            m.kind,
            crate::bridge::Kind::MojoPy | crate::bridge::Kind::CAbi | crate::bridge::Kind::MojoNode
        ) && (named || m.unit.trim_end_matches('/') == wanted)
        {
            bail!(
                "{} is a Mojo unit: the server front door is still a Rust app and \
                 cannot take Mojo units yet; check the unit on its own with diff, shadow and gate",
                dir.display()
            );
        }
    }
    Ok(())
}

pub struct WireOptions<'a> {
    pub repo: &'a Path,
    /// The unit: its folder, its name under `mojo/` (`rust/` for a server), or the unit id it
    /// was bridged from.
    pub unit: &'a str,
    /// Commands the unit answers; kept from the last wire when empty.
    pub commands: &'a [String],
    /// Servers: routes the unit answers (`GET /users/{id}`, `/path` for any method, `*` for
    /// everything else); kept from the last wire when empty.
    pub routes: &'a [String],
    /// Wire without running `gate` on the unit first (when it just passed).
    pub skip_gate: bool,
    pub check: bool,
}

#[derive(Debug, Serialize)]
pub struct WireOutcome {
    /// Libraries: the drop-in the original package imports in place of the unit.
    pub shadow: Option<PathBuf>,
    pub unit: String,
    pub crate_dir: PathBuf,
    pub commands: Vec<String>,
    pub routes: Vec<String>,
    pub switch: String,
    pub glue: PathBuf,
    /// The glue file still holds the generated stub.
    pub glue_pending: bool,
    pub gate: Option<bool>,
    pub replay: Option<ReplayOutcome>,
}

pub fn wire(opts: &WireOptions) -> Result<WireOutcome> {
    let repo = opts
        .repo
        .canonical()
        .with_context(|| format!("no folder {}", opts.repo.display()))?;
    let mut state = State::load(&repo)?;
    ensure!(
        !state.lifted,
        "the app is lifted: there is no fallback left to wire around; call the crate from src/units directly"
    );
    match state.kind {
        AppKind::Cli => return cli_wire(&repo, opts, state),
        AppKind::Library => return library_wire(&repo, opts, state),
        AppKind::Http => {}
    }
    let app_dir = repo.join(APP_DIR);
    let crate_dir = find_unit(&repo, opts.unit)?;
    let manifest_text = std::fs::read_to_string(crate_dir.join("Cargo.toml"))?;
    let unit_doc: DocumentMut = manifest_text.parse()?;
    let crate_name = unit_doc
        .get("package")
        .and_then(|p| p.get("name"))
        .and_then(|n| n.as_str())
        .context("the unit's Cargo.toml has no package name")?
        .to_string();
    if let Some(kinds) = unit_doc
        .get("lib")
        .and_then(|l| l.get("crate-type"))
        .and_then(|k| k.as_array())
    {
        ensure!(
            kinds.iter().any(|k| k.as_str() == Some("rlib")),
            "{crate_name} is not a Rust library: add \"rlib\" to `crate-type` in its Cargo.toml"
        );
    }
    let name = unit_name(&crate_name).to_string();
    let switch = kill_switch(&crate_name);

    let gate = if opts.skip_gate {
        None
    } else {
        let outcome = crate::gate::gate(&crate_dir, &[])?;
        if !outcome.passed {
            let failed: Vec<String> = outcome
                .checks
                .iter()
                .filter(|c| !c.passed)
                .map(|c| c.name.to_string())
                .collect();
            bail!(
                "{crate_name} does not pass gate ({}): run `mojo-anything gate {}` and fix it before wiring",
                failed.join(", "),
                crate_dir.display()
            );
        }
        Some(true)
    };

    let previous = state.units.iter().position(|u| u.name == name);
    let http = state.kind == AppKind::Http;
    ensure!(
        !http || opts.commands.is_empty(),
        "{} is a server: name what {name} answers with --route, not --command",
        state.name
    );
    ensure!(
        http || opts.routes.is_empty(),
        "{} is a CLI: name what {name} answers with --command, not --route",
        state.name
    );
    let routes = if !http {
        Vec::new()
    } else if opts.routes.is_empty() {
        previous
            .map(|i| state.units[i].routes.clone())
            .filter(|r| !r.is_empty())
            .with_context(|| format!("name the routes {name} answers with --route"))?
    } else {
        http_door::check_routes(&state, &name, opts.routes)?
            .iter()
            .map(http_door::Route::key)
            .collect()
    };
    let commands = if http {
        Vec::new()
    } else if opts.commands.is_empty() {
        previous
            .map(|i| state.units[i].commands.clone())
            .with_context(|| format!("name the commands {name} answers with --command"))?
    } else {
        opts.commands.to_vec()
    };
    let routable: Vec<&str> = state
        .commands
        .iter()
        .map(String::as_str)
        .chain([state.name.as_str()])
        .collect();
    for command in commands.iter().filter(|_| !http) {
        ensure!(
            routable.contains(&command.as_str()),
            "the front door has no command `{command}` (it has: {}); add it to src/cli.rs and to `commands` in {}",
            routable.join(", "),
            app_dir.join(STATE_FILE).display()
        );
        if let Some(other) = state
            .units
            .iter()
            .find(|u| u.name != name && u.commands.contains(command))
        {
            bail!("`{command}` is already wired to {}", other.name);
        }
    }
    let path = from_app_dir(&repo, &crate_dir);
    let entry = WiredUnit {
        name: name.clone(),
        crate_name: crate_name.clone(),
        path: path.clone(),
        commands: commands.clone(),
        routes: routes.clone(),
        switch: switch.clone(),
        unit: None,
        shadow: None,
        kept: Vec::new(),
    };
    match previous {
        Some(i) => state.units[i] = entry,
        None => state.units.push(entry),
    }

    let cargo_path = app_dir.join("Cargo.toml");
    let mut doc: DocumentMut = std::fs::read_to_string(&cargo_path)?.parse()?;
    let mut dep = InlineTable::new();
    dep.insert("path", path.as_str().into());
    doc["dependencies"][crate_name.as_str()] = value(dep);
    std::fs::write(&cargo_path, doc.to_string())?;

    let glue = app_dir
        .join("src/units")
        .join(format!("{}.rs", ident(&name)));
    if !glue.exists() {
        std::fs::write(&glue, http_door::glue_rs(&crate_name))?;
    }
    std::fs::write(
        app_dir.join("src/units/mod.rs"),
        http_door::units_rs(&state, false),
    )?;
    rustfmt(&app_dir.join("src/units/mod.rs"));
    state.save(&repo)?;
    let glue_pending = is_stub(&std::fs::read_to_string(&glue)?);
    let replay = if opts.check {
        Some(build_and_replay(&repo, &state)?)
    } else {
        None
    };
    Ok(WireOutcome {
        shadow: None,
        unit: name,
        crate_dir,
        commands,
        routes,
        switch,
        glue,
        glue_pending,
        gate,
        replay,
    })
}

/// A Mojo unit folder for the CLI front door: `mojo/<unit>`, `mojo/<unit>-mojo`, a folder
/// given as a path, or the unit id a manifest under `mojo/` names. A folder is a Mojo unit
/// when it holds `port.mojo`.
fn find_mojo_unit(repo: &Path, unit: &str, door: &str) -> Result<PathBuf> {
    let mojo = repo.join("mojo");
    let app_dir = repo.join(APP_DIR);
    for candidate in [
        mojo.join(unit),
        mojo.join(format!("{unit}-mojo")),
        repo.join(unit),
        PathBuf::from(unit),
    ] {
        if candidate.join("port.mojo").is_file() && candidate != app_dir {
            return Ok(candidate.canonical()?);
        }
    }
    let wanted = unit.trim_end_matches('/');
    if let Ok(entries) = std::fs::read_dir(&mojo) {
        for entry in entries.flatten() {
            if let Ok(m) = crate::bridge::Manifest::load(&entry.path())
                && m.unit.trim_end_matches('/') == wanted
                && entry.path().join("port.mojo").is_file()
            {
                return Ok(entry.path().canonical()?);
            }
        }
    }
    let rust = repo.join("rust");
    for candidate in [
        rust.join(unit),
        rust.join(format!("{unit}-rs")),
        repo.join(unit),
        PathBuf::from(unit),
    ] {
        if candidate.join("Cargo.toml").is_file() {
            bail!(
                "{} is a Rust crate: {door} and wires Mojo units (a folder with port.mojo); \
                 Java and Kotlin units move to Mojo with M5",
                candidate.display()
            );
        }
    }
    if let Ok(entries) = std::fs::read_dir(&rust) {
        for entry in entries.flatten() {
            if let Ok(m) = crate::bridge::Manifest::load(&entry.path())
                && m.unit.trim_end_matches('/') == wanted
            {
                bail!(
                    "{} is a Rust crate: {door} and wires Mojo units (a folder with port.mojo); \
                     Java and Kotlin units move to Mojo with M5",
                    entry.path().display()
                );
            }
        }
    }
    bail!(
        "no Mojo unit `{unit}`: give the unit folder (`mojo/<name>`, as `bridge` made it, with a port.mojo) or the unit id"
    )
}

/// `wire` for the CLI front door: the unit's port becomes a package the glue imports, and
/// each wired command gets a glue function in `mojo/app/glue/<unit>.mojo`.
fn cli_wire(repo: &Path, opts: &WireOptions, mut state: State) -> Result<WireOutcome> {
    ensure!(
        opts.routes.is_empty(),
        "{} is a CLI: name what the unit answers with --command, not --route",
        state.name
    );
    let app_dir = repo.join(APP_DIR);
    let unit_dir = find_mojo_unit(repo, opts.unit, "the CLI front door is a Mojo binary")?;
    let manifest = crate::bridge::Manifest::load(&unit_dir).ok();
    let crate_name = match &manifest {
        Some(m) => m.crate_name.clone(),
        None => unit_dir
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .context("the unit folder has no name")?,
    };
    let name = unit_name(&crate_name).to_string();
    let switch = kill_switch(&crate_name);
    let gate = if opts.skip_gate {
        None
    } else {
        let checks = if manifest.is_some() {
            crate::gate::gate(&unit_dir, &[])?.checks
        } else {
            crate::gate::mojo_checks(&unit_dir)
        };
        let failed: Vec<&str> = checks
            .iter()
            .filter(|c| !c.passed)
            .map(|c| c.name)
            .collect();
        ensure!(
            failed.is_empty(),
            "{crate_name} does not pass gate ({}): run `mojo-anything gate {}` and fix it before wiring",
            failed.join(", "),
            unit_dir.display()
        );
        Some(true)
    };
    let previous = state.units.iter().position(|u| u.name == name);
    let commands = if opts.commands.is_empty() {
        previous
            .map(|i| state.units[i].commands.clone())
            .with_context(|| format!("name the commands {name} answers with --command"))?
    } else {
        opts.commands.to_vec()
    };
    let routable: Vec<&str> = state
        .commands
        .iter()
        .map(String::as_str)
        .chain([state.name.as_str()])
        .collect();
    for command in &commands {
        ensure!(
            routable.contains(&command.as_str()),
            "the front door has no command `{command}` (it has: {}); add it to `commands` in {}",
            routable.join(", "),
            app_dir.join(STATE_FILE).display()
        );
        if let Some(other) = state
            .units
            .iter()
            .find(|u| u.name != name && u.commands.contains(command))
        {
            bail!("`{command}` is already wired to {}", other.name);
        }
    }
    let entry = WiredUnit {
        name: name.clone(),
        crate_name,
        path: from_app_dir(repo, &unit_dir),
        commands: commands.clone(),
        routes: Vec::new(),
        switch: switch.clone(),
        unit: None,
        shadow: None,
        kept: Vec::new(),
    };
    let glue_dir = app_dir.join("glue");
    std::fs::create_dir_all(&glue_dir)?;
    let init = glue_dir.join("__init__.mojo");
    if !init.exists() {
        std::fs::write(
            &init,
            "# The glue between the front door and the wired units, one module per unit.\n",
        )?;
    }
    let glue_file = format!("glue/{}.mojo", mojo_door::mojo_ident(&name));
    let glue = app_dir.join(&glue_file);
    let mut format = vec!["units.mojo".to_string()];
    match std::fs::read_to_string(&glue) {
        Ok(text) => {
            let more = mojo_door::missing_glue(&text, &commands);
            if !more.is_empty() {
                std::fs::write(&glue, text + &more)?;
                format.push(glue_file.clone());
            }
        }
        Err(_) => {
            let port = std::fs::read_to_string(unit_dir.join("port.mojo"))?;
            let api = crate::codegen_mojo::parse_port_mojo(&port);
            std::fs::write(&glue, mojo_door::glue_mojo(&entry, &api))?;
            format.push(glue_file.clone());
        }
    }
    match previous {
        Some(i) => state.units[i] = entry,
        None => state.units.push(entry),
    }
    std::fs::write(
        app_dir.join("units.mojo"),
        mojo_door::units_mojo(&state, false),
    )?;
    if mojo_door::port_modules(&unit_dir)
        .iter()
        .any(|m| m == "json")
    {
        mojo_door::add_json_dependency(&app_dir)?;
    }
    let format: Vec<&str> = format.iter().map(String::as_str).collect();
    mojo_door::mojo_format(&app_dir, &format);
    state.save(repo)?;
    let glue_pending = is_stub(&std::fs::read_to_string(&glue)?);
    let replay = if opts.check {
        Some(build_and_replay(repo, &state)?)
    } else {
        None
    };
    Ok(WireOutcome {
        shadow: None,
        unit: name,
        crate_dir: unit_dir,
        commands,
        routes: Vec::new(),
        switch,
        glue,
        glue_pending,
        gate,
        replay,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wire_refuses_a_mojo_unit_clearly() {
        let repo =
            std::env::temp_dir().join(format!("mojo-anything-wire-mojo-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&repo);
        for (dir, kind, lang, unit) in [
            ("mojo/text-mojo", "c-abi", "c", "text.c"),
            ("mojo/colorsys-mojo", "mojo-py", "python", "colorsys.py"),
        ] {
            let unit_dir = repo.join(dir);
            std::fs::create_dir_all(&unit_dir).unwrap();
            std::fs::write(
                unit_dir.join(crate::bridge::MANIFEST),
                format!(
                    r#"{{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "{unit}", "language": "{lang}", "kind": "{kind}", "crate_name": "x-mojo", "exports": []}}"#
                ),
            )
            .unwrap();
            for given in [dir, unit] {
                let err = format!("{:#}", find_unit(&repo, given).unwrap_err());
                assert!(err.contains("is a Mojo unit"), "{given}: {err}");
            }
        }
        std::fs::remove_dir_all(&repo).unwrap();
    }

    #[test]
    fn kill_switch_names_mojo_units() {
        assert_eq!(
            kill_switch("colorsys-pkg-mojo"),
            "MOJO_ANYTHING_UNIT_COLORSYS_PKG"
        );
        assert_eq!(kill_switch("textops"), "MOJO_ANYTHING_UNIT_TEXTOPS");
    }

    #[test]
    fn old_front_door_state_says_rerun() {
        let repo = crate::app::temp_dir("old-front-door").unwrap();
        let old = repo.join("rust/app");
        std::fs::create_dir_all(&old).unwrap();
        std::fs::write(
            old.join("rust-anything.json"),
            r#"{"schema": "rust-anything/front-door@1", "name": "tcli", "commands": []}"#,
        )
        .unwrap();
        let err = format!("{:#}", State::load(&repo).unwrap_err());
        assert!(err.contains("rust/app"), "{err}");
        assert!(err.contains("app front-door` again"), "{err}");

        // A state file in the new place but written by an older schema says the same.
        let app = repo.join(APP_DIR);
        std::fs::create_dir_all(&app).unwrap();
        std::fs::write(
            app.join(STATE_FILE),
            r#"{"schema": "mojo-anything/front-door@1", "name": "tcli", "commands": []}"#,
        )
        .unwrap();
        let err = format!("{:#}", State::load(&repo).unwrap_err());
        assert!(err.contains("app front-door` again"), "{err}");
        std::fs::remove_dir_all(&repo).unwrap();
    }

    fn case(args: &[&str], ok: bool) -> (Vec<String>, bool) {
        (args.iter().map(|a| a.to_string()).collect(), ok)
    }

    #[test]
    fn commands_and_flags_come_from_successful_cases() {
        let (commands, flags) = infer_cli(&[
            case(&["div", "7", "2"], true),
            case(&["show", "--json", "-v", "x"], true),
            case(&["show", "--width=3"], true),
            case(&["nope"], false),
            case(&["--help"], true),
        ]);
        assert_eq!(commands, ["div", "show"]);
        let show = &flags["show"];
        assert!(!show["json"].takes_value);
        assert!(show["width"].takes_value);
        assert_eq!(show["short-v"].short, Some('v'));
        assert!(!flags.contains_key("div") || flags["div"].is_empty());
        let (none, root) = infer_cli(&[case(&["-n", "5", "file.txt"], true)]);
        assert!(none.is_empty());
        assert!(root[""].contains_key("short-n"));
    }

    #[test]
    fn names_are_valid_rust() {
        assert_eq!(package_name("My Tool"), "my-tool");
        assert_eq!(package_name("7zip"), "app-7zip");
        assert_eq!(ident("text-kit"), "text_kit");
        assert_eq!(ident("mod"), "unit_mod");
    }
}
