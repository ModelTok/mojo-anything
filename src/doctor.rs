//! `doctor`: check pixi and the pinned Mojo, the language runtimes, the agent setup and the MCP
//! server on this machine, and say the command that fixes each problem.
//!
//! Language runtimes are optional: each matters only for the languages being ported. pixi, the
//! pinned Mojo, the MCP server and the setup of every agent found on the machine are required.
//! Mojo builds only on Linux and macOS, so on Windows the pixi and Mojo rows point at WSL.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{Value, json};

use crate::setup::{self, Agent, NAME, SKILL_FILES};
use crate::walk::Canonical;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Ok,
    Missing,
    Outdated,
    /// Something named mojo-anything is there, but it is not ours.
    Foreign,
}

impl Status {
    fn label(self) -> &'static str {
        match self {
            Status::Ok => "ok",
            Status::Missing => "missing",
            Status::Outdated => "outdated",
            Status::Foreign => "foreign",
        }
    }
}

#[derive(Debug, Serialize)]
pub struct Check {
    pub name: String,
    pub status: Status,
    /// A problem here makes `doctor` exit 1; optional checks only matter for some languages.
    pub required: bool,
    pub detail: String,
    pub fix: Option<String>,
}

#[derive(Debug, Serialize)]
pub struct Report {
    pub checks: Vec<Check>,
}

impl Report {
    /// Whether every required check passed.
    pub fn ok(&self) -> bool {
        self.checks
            .iter()
            .all(|c| !c.required || c.status == Status::Ok)
    }
}

/// A version as `major.minor.patch`.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Version(pub u32, pub u32, pub u32);

impl std::fmt::Display for Version {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}.{}.{}", self.0, self.1, self.2)
    }
}

/// The first `N[.N[.N]]` in a version banner (`v24.1.0`, `go version go1.22.3 ...`,
/// `openjdk version "21.0.2"`, `ruby 2.6.10p210`).
pub fn parse_version(text: &str) -> Option<Version> {
    let start = text.find(|c: char| c.is_ascii_digit())?;
    let mut parts = text[start..]
        .split(|c: char| !c.is_ascii_digit() && c != '.')
        .next()?
        .split('.')
        .map(|p| p.parse::<u32>().ok());
    let major = parts.next()??;
    let minor = parts.next().flatten().unwrap_or(0);
    let patch = parts.next().flatten().unwrap_or(0);
    Some(Version(major, minor, patch))
}

/// Java's version, reading the old `1.8.0` scheme as 8.
pub fn parse_java_version(text: &str) -> Option<Version> {
    parse_version(text).map(|v| match v {
        Version(1, minor, patch) => Version(minor, patch, 0),
        v => v,
    })
}

/// A runtime's status from whether it ran, its version and the oldest version that works.
pub fn grade(ran: bool, version: Option<Version>, minimum: Option<Version>) -> Status {
    match (ran, version, minimum) {
        (false, _, _) => Status::Missing,
        (true, Some(v), Some(min)) if v < min => Status::Outdated,
        _ => Status::Ok,
    }
}

/// The state of something `setup` installs: an MCP entry or the skill.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Install {
    Missing,
    Current,
    Outdated,
    Foreign,
}

impl From<Install> for Status {
    fn from(i: Install) -> Status {
        match i {
            Install::Missing => Status::Missing,
            Install::Current => Status::Ok,
            Install::Outdated => Status::Outdated,
            Install::Foreign => Status::Foreign,
        }
    }
}

/// An agent's `mojo-anything` MCP server entry, as read from its settings.
#[derive(Debug, Default)]
pub struct Entry {
    pub command: Option<String>,
    pub args: Vec<String>,
    pub url: bool,
    /// OpenCode keeps a configured server out of the way with `disabled`; never set elsewhere.
    pub disabled: bool,
}

/// Ours and current when it runs `<exe> mcp`; outdated when it runs `mcp` on another binary.
pub fn entry_state(entry: Option<&Entry>, exe: &Path) -> Install {
    let Some(entry) = entry else {
        return Install::Missing;
    };
    let Some(command) = entry.command.as_deref() else {
        return Install::Foreign;
    };
    if entry.url || entry.args != ["mcp"] {
        return Install::Foreign;
    }
    if entry.disabled {
        return Install::Outdated;
    }
    let path = Path::new(command);
    if path == exe || path.canonical().is_ok_and(|p| p == exe) {
        Install::Current
    } else {
        Install::Outdated
    }
}

/// The installed skill files, in `SKILL_FILES` order, against the embedded copies.
pub fn skill_state(installed: &[Option<String>]) -> Install {
    let Some(main) = installed.first().and_then(Option::as_deref) else {
        return if installed.iter().all(Option::is_none) {
            Install::Missing
        } else {
            Install::Outdated
        };
    };
    if installed
        .iter()
        .zip(SKILL_FILES)
        .all(|(have, (_, want))| have.as_deref() == Some(*want))
    {
        Install::Current
    } else if main
        .lines()
        .take_while(|l| !l.is_empty())
        .any(|l| l.trim() == format!("name: {NAME}"))
    {
        Install::Outdated
    } else {
        Install::Foreign
    }
}

pub fn run() -> Report {
    let exe = std::env::current_exe()
        .and_then(|p| p.canonical())
        .unwrap_or_else(|_| PathBuf::from(NAME));
    let mut checks: Vec<Check> = std::thread::scope(|s| {
        let toolchain = s.spawn(|| mojo_toolchain(Platform::HERE));
        let probes: Vec<_> = RUNTIMES.iter().map(|r| s.spawn(|| runtime(r))).collect();
        let mcp = s.spawn(|| mcp_self_test(&exe));
        let mut checks = toolchain.join().expect("the Mojo probe panicked");
        checks.extend(
            probes
                .into_iter()
                .map(|p| p.join().expect("a runtime probe panicked")),
        );
        checks.push(mcp.join().expect("the MCP self-test panicked"));
        checks
    });
    checks.extend(agents(&exe));
    Report { checks }
}

struct Runtime {
    name: &'static str,
    program: &'static str,
    args: &'static [&'static str],
    minimum: Option<Version>,
    java: bool,
    /// Fix commands: macOS, then Linux (which Windows runs in WSL).
    fix: [&'static str; 2],
}

/// Where mojo-anything runs on Windows: Mojo builds only on Linux and macOS.
const WSL: &str = "wsl -d Ubuntu-24.04 --cd ~/github/mojo-anything";
/// pixi's own installer, for Linux and macOS; it puts pixi in `~/.pixi/bin`.
const PIXI_INSTALL: &str = "curl -fsSL https://pixi.sh/install.sh | sh";
/// How long `pixi exec` may take to get the pinned Mojo: the first run downloads it.
const MOJO_PROBE: Duration = Duration::from_secs(300);

const RUNTIMES: &[Runtime] = &[
    Runtime {
        name: "python",
        program: "python3",
        args: &["--version"],
        minimum: Some(Version(3, 9, 0)),
        java: false,
        fix: ["brew install python@3.13", "sudo apt install python3"],
    },
    Runtime {
        name: "node",
        program: "node",
        args: &["--version"],
        minimum: Some(Version(24, 0, 0)),
        java: false,
        fix: ["brew install node@24", "fnm install 24 && fnm default 24"],
    },
    Runtime {
        name: "cc",
        program: "cc",
        args: &["--version"],
        minimum: None,
        java: false,
        fix: ["xcode-select --install", "sudo apt install build-essential"],
    },
    Runtime {
        name: "go",
        program: "go",
        args: &["version"],
        minimum: Some(Version(1, 22, 0)),
        java: false,
        fix: ["brew install go", "install Go 1.22+ from https://go.dev/dl"],
    },
    Runtime {
        name: "ruby",
        program: "ruby",
        args: &["--version"],
        minimum: Some(Version(3, 0, 0)),
        java: false,
        fix: [
            "brew install ruby && export PATH=\"$(brew --prefix ruby)/bin:$PATH\"",
            "sudo apt install ruby-full",
        ],
    },
    Runtime {
        name: "java",
        program: "java",
        args: &["-version"],
        minimum: Some(Version(crate::jvm::MIN_JAVA, 0, 0)),
        java: true,
        fix: ["brew install openjdk", "sudo apt install openjdk-25-jdk"],
    },
    Runtime {
        name: "javac",
        program: "javac",
        args: &["-version"],
        minimum: Some(Version(crate::jvm::MIN_JAVA, 0, 0)),
        java: true,
        fix: ["brew install openjdk", "sudo apt install openjdk-25-jdk"],
    },
    Runtime {
        name: "kotlinc",
        program: "kotlinc",
        args: &["-version"],
        minimum: None,
        java: false,
        fix: ["brew install kotlin", "sdk install kotlin"],
    },
    Runtime {
        name: "php",
        program: "php",
        args: &["--version"],
        minimum: Some(Version(8, 0, 0)),
        java: false,
        fix: ["brew install php", "sudo apt install php-cli"],
    },
    Runtime {
        name: "dotnet",
        program: "dotnet",
        args: &["--version"],
        minimum: None,
        java: false,
        fix: [
            "brew install --cask dotnet-sdk",
            "install the .NET SDK from https://dotnet.microsoft.com/download",
        ],
    },
];

/// Where a check runs; a parameter of the checks so that each platform's rows can be tested
/// anywhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Platform {
    MacOs,
    Windows,
    Other,
}

impl Platform {
    const HERE: Platform = if cfg!(target_os = "macos") {
        Platform::MacOs
    } else if cfg!(windows) {
        Platform::Windows
    } else {
        Platform::Other
    };

    /// The fix for this platform: on Windows the Linux command, run in WSL, where Mojo builds.
    fn pick(self, fix: &[&'static str; 2]) -> String {
        match self {
            Platform::MacOs => fix[0].to_string(),
            Platform::Other => fix[1].to_string(),
            Platform::Windows => format!("in WSL ({WSL}): {}", fix[1]),
        }
    }
}

/// The commands that install or update `r` on `platform`, one per line, to run in order; `None`
/// when it is fine.
fn runtime_fix(r: &Runtime, status: Status, platform: Platform) -> Option<String> {
    if status == Status::Ok {
        return None;
    }
    let mut fix = platform.pick(&r.fix);
    if r.java {
        fix.push_str(&format!(
            "\n(Java and Kotlin units need Java {} or newer, for the Foreign Function & Memory API)",
            crate::jvm::MIN_JAVA
        ));
    }
    Some(fix)
}

/// The program's banner (stdout, else stderr), or `None` when it did not run.
fn probe(program: impl AsRef<std::ffi::OsStr>, args: &[&str]) -> Option<String> {
    let out =
        crate::process::output(Command::new(program).args(args), crate::process::QUICK).ok()?;
    if !out.success() {
        return None;
    }
    let text = out.stdout_text();
    let text = if text.trim().is_empty() {
        out.stderr_text()
    } else {
        text
    };
    Some(text.lines().next().unwrap_or_default().trim().to_string())
}

fn which(program: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(program))
        .find(|p| p.is_file())
}

/// The row for `r` from its banner (`None` when it did not run).
fn assess(r: &Runtime, banner: Option<String>, platform: Platform) -> Check {
    let version = banner.as_deref().and_then(if r.java {
        parse_java_version
    } else {
        parse_version
    });
    let status = grade(banner.is_some(), version, r.minimum);
    let outdated = status == Status::Outdated;
    let detail = match (&banner, r.minimum) {
        (None, _) => format!("`{}` not found or did not run", r.program),
        (Some(b), Some(min)) if outdated && r.java => format!(
            "{b}; Java and Kotlin units need Java {}+ (the Foreign Function & Memory API)",
            min.0
        ),
        (Some(b), Some(_)) if outdated && r.name == "node" => {
            if version.is_some_and(|v| v < Version(22, 6, 0)) {
                format!(
                    "{b}; TS and JS units need Node 22.6+, and the wasm bridge (`mojo-wasm`) and \
                     `profile` need Node 24+"
                )
            } else {
                format!(
                    "{b}; TS and JS units work, but the wasm bridge (`mojo-wasm`) and `profile` \
                     need Node 24+"
                )
            }
        }
        (Some(b), Some(min)) if outdated => {
            format!("{b}; mojo-anything needs {}.{}+", min.0, min.1)
        }
        (Some(b), Some(min)) if r.java => format!("{b} (Java and Kotlin units need {}+)", min.0),
        (Some(b), _) => b.clone(),
    };
    Check {
        name: r.name.to_string(),
        status,
        required: false,
        detail,
        fix: runtime_fix(r, status, platform),
    }
}

fn runtime(r: &Runtime) -> Check {
    let mut check = assess(r, probe(r.program, r.args), Platform::HERE);
    if r.name == "ruby"
        && check.status == Status::Outdated
        && Platform::HERE == Platform::MacOs
        && which("ruby").is_some_and(|p| p.starts_with("/usr/bin"))
    {
        check.detail.push_str("; this is macOS's system Ruby");
    }
    check
}

/// `pixi exec` arguments that run the pinned Mojo's `mojo --version`, from the channels every
/// generated unit lists.
fn pinned_mojo_args() -> Vec<String> {
    let mut args = vec!["exec".to_string()];
    for channel in crate::mojo::CHANNELS {
        args.push("-c".into());
        args.push((*channel).into());
    }
    args.push("--spec".into());
    args.push(format!("mojo=={}", crate::mojo::MOJO_VERSION));
    args.push("mojo".into());
    args.push("--version".into());
    args
}

/// The `pixi` and `mojo` rows. Both are required; on Windows both fail and point at WSL.
fn mojo_toolchain(platform: Platform) -> Vec<Check> {
    let version = crate::mojo::MOJO_VERSION;
    if platform == Platform::Windows {
        let fix = format!("use the WSL clone: {WSL}");
        return vec![
            Check {
                name: "pixi".into(),
                status: Status::Missing,
                required: true,
                detail:
                    "Mojo builds only on Linux and macOS: on Windows, mojo-anything runs in WSL"
                        .into(),
                fix: Some(fix.clone()),
            },
            Check {
                name: "mojo".into(),
                status: Status::Missing,
                required: true,
                detail: format!("Mojo {version} runs only on Linux and macOS"),
                fix: Some(fix),
            },
        ];
    }
    let pixi = crate::mojo::find_pixi(
        std::env::var_os("PATH"),
        std::env::var_os("HOME").map(PathBuf::from),
    );
    let banner = pixi.as_ref().and_then(|p| probe(p, &["--version"]));
    let pixi_row = Check {
        name: "pixi".into(),
        status: if banner.is_some() {
            Status::Ok
        } else {
            Status::Missing
        },
        required: true,
        detail: match (&pixi, &banner) {
            (Some(p), Some(b)) => format!("{b} ({})", p.display()),
            (Some(p), None) => format!("`{} --version` did not run", p.display()),
            (None, _) => "`pixi` is not on PATH or in ~/.pixi/bin".into(),
        },
        fix: banner.is_none().then(|| PIXI_INSTALL.to_string()),
    };
    let mojo_row = match pixi.filter(|_| banner.is_some()) {
        None => Check {
            name: "mojo".into(),
            status: Status::Missing,
            required: true,
            detail: format!("pixi runs the pinned Mojo {version}, and pixi is missing"),
            fix: Some(format!("{PIXI_INSTALL}\n(then run doctor again)")),
        },
        Some(pixi) => pinned_mojo(&pixi, version),
    };
    vec![pixi_row, mojo_row]
}

/// Runs the pinned Mojo through `pixi exec`, the way every generated unit gets it.
fn pinned_mojo(pixi: &Path, version: &str) -> Check {
    let args = pinned_mojo_args();
    let by_hand = format!("{} {}", quoted(pixi), args.join(" "));
    let out = crate::process::output(
        Command::new(pixi)
            .args(&args)
            .current_dir(std::env::temp_dir()),
        MOJO_PROBE,
    );
    let (status, detail) = match out {
        Err(e) => (
            Status::Missing,
            format!("pixi did not get Mojo {version}: {e:#} (the first run downloads it)"),
        ),
        Ok(out) if !out.success() => {
            let err = out.stderr_text();
            let last = err.lines().rev().find(|l| !l.trim().is_empty());
            (
                Status::Missing,
                format!(
                    "pixi could not run Mojo {version}: {}",
                    last.unwrap_or("no message").trim()
                ),
            )
        }
        Ok(out) => {
            let text = out.stdout_text();
            let banner = text.lines().next().unwrap_or_default().trim().to_string();
            if parse_version(&banner) == parse_version(version) {
                (
                    Status::Ok,
                    format!("{banner}, through pixi (the Mojo every unit pins)"),
                )
            } else {
                (
                    Status::Outdated,
                    format!("pixi ran `{banner}`, not the pinned Mojo {version}"),
                )
            }
        }
    };
    Check {
        name: "mojo".into(),
        status,
        required: true,
        detail,
        fix: (status != Status::Ok).then(|| format!("{by_hand}\n(run it to see the whole error)")),
    }
}

/// How mojo-anything itself is installed: the npm wrapper, which downloads the release binary,
/// or that binary's archive from the GitHub release (`.github/workflows/release.yml`).
const INSTALL: &str = "`npm install -g mojo-anything` (Linux x64/arm64, macOS arm64), \
                       or the archive for your platform from https://github.com/ModelTok/mojo-anything/releases";

/// Starts `<exe> mcp`, asks for `initialize` and `tools/list`, and expects both answers in 10 s.
fn mcp_self_test(exe: &Path) -> Check {
    let (status, detail) = match talk_to_mcp(exe, Duration::from_secs(10)) {
        Ok(tools) => (
            Status::Ok,
            format!("`{} mcp` answered with {tools} tools", exe.display()),
        ),
        Err(e) => (Status::Missing, format!("`{} mcp`: {e}", exe.display())),
    };
    Check {
        name: "mcp".into(),
        status,
        required: true,
        detail,
        fix: (status != Status::Ok).then(|| {
            format!(
                "run `{} mcp` by hand and look at what it prints; reinstall with {INSTALL}",
                quoted(exe)
            )
        }),
    }
}

fn talk_to_mcp(exe: &Path, limit: Duration) -> Result<usize, String> {
    let mut child = Command::new(exe)
        .arg("mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("could not start: {e}"))?;
    let requests = [
        json!({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "mojo-anything-doctor", "version": env!("CARGO_PKG_VERSION")}}}),
        json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        json!({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}),
    ];
    if let Some(mut stdin) = child.stdin.take() {
        for r in &requests {
            let _ = writeln!(stdin, "{r}");
        }
    }
    let (tx, rx) = mpsc::channel();
    if let Some(stdout) = child.stdout.take() {
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
    }
    let deadline = Instant::now() + limit;
    let mut init = None;
    let mut list = None;
    let outcome = loop {
        if let (Some(_), Some(_)) = (&init, &list) {
            break Ok(());
        }
        let left = deadline.saturating_duration_since(Instant::now());
        match rx.recv_timeout(left) {
            Ok(line) => {
                let Ok(reply) = serde_json::from_str::<Value>(&line) else {
                    break Err(format!("printed a line that is not JSON: {line}"));
                };
                match reply["id"].as_i64() {
                    Some(1) => init = Some(reply),
                    Some(2) => list = Some(reply),
                    _ => {}
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {
                break Err(format!("no answer within {}s", limit.as_secs()));
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => {
                break Err("exited before answering".to_string());
            }
        }
    };
    let _ = child.kill();
    let _ = child.wait();
    outcome?;
    let init = init.unwrap_or_default();
    let list = list.unwrap_or_default();
    if !init["result"]["protocolVersion"].is_string() {
        return Err(format!("`initialize` gave no protocol version: {init}"));
    }
    match list["result"]["tools"].as_array() {
        Some(tools) if !tools.is_empty() => Ok(tools.len()),
        _ => Err(format!("`tools/list` listed no tools: {list}")),
    }
}

fn quoted(path: &Path) -> String {
    let text = path.display().to_string();
    if text.contains(' ') {
        format!("\"{text}\"")
    } else {
        text
    }
}

fn slug(agent: Agent) -> &'static str {
    match agent {
        Agent::Claude => "claude",
        Agent::Codex => "codex",
        Agent::Cursor => "cursor",
        Agent::Gemini => "gemini",
        Agent::OpenCode => "opencode",
    }
}

fn agents(exe: &Path) -> Vec<Check> {
    let home = match setup::home() {
        Ok(h) => h,
        Err(e) => {
            return vec![Check {
                name: "agents".into(),
                status: Status::Missing,
                required: false,
                detail: format!("{e:#}"),
                fix: Some("set HOME".into()),
            }];
        }
    };
    let found: Vec<Agent> = Agent::ALL
        .into_iter()
        .filter(|a| a.present(&home))
        .collect();
    if found.is_empty() {
        return vec![Check {
            name: "agents".into(),
            status: Status::Missing,
            required: false,
            detail: "no coding agent found (Claude Code, Codex, Cursor, Gemini CLI, OpenCode); the CLI works without one".into(),
            fix: Some(format!("{} setup --agent claude", quoted(exe))),
        }];
    }
    let setup_fix = |agent: Agent| format!("{} setup --agent {}", quoted(exe), slug(agent));
    let mut checks = Vec::new();
    for agent in found {
        let config = agent.config(&home);
        let (state, detail) = match read_entry(agent, &config) {
            Err(e) => (Install::Foreign, e),
            Ok(entry) => {
                let state = entry_state(entry.as_ref(), exe);
                let detail = match (state, &entry) {
                    (Install::Missing, _) => format!("no `{NAME}` server in {}", config.display()),
                    (_, Some(Entry { disabled: true, .. })) => {
                        format!("`{NAME}` in {} is disabled", config.display())
                    }
                    (
                        _,
                        Some(Entry {
                            command: Some(c), ..
                        }),
                    ) => {
                        format!("{} runs `{c}`", config.display())
                    }
                    _ => format!(
                        "`{NAME}` in {} is not `{} mcp`",
                        config.display(),
                        exe.display()
                    ),
                };
                (state, detail)
            }
        };
        checks.push(Check {
            name: format!("{} mcp", agent.name()),
            status: state.into(),
            required: true,
            detail,
            fix: match state {
                Install::Current => None,
                Install::Missing | Install::Outdated => Some(setup_fix(agent)),
                Install::Foreign => Some(format!(
                    "fix or remove the `{NAME}` entry in {}, then run `{}`",
                    config.display(),
                    setup_fix(agent)
                )),
            },
        });
        if let Some(dir) = agent.skill_dir(&home) {
            let installed: Vec<Option<String>> = SKILL_FILES
                .iter()
                .map(|(name, _)| std::fs::read_to_string(dir.join(name)).ok())
                .collect();
            let state = skill_state(&installed);
            let skill_md = dir.join("SKILL.md");
            checks.push(Check {
                name: format!("{} skill", agent.name()),
                status: state.into(),
                required: true,
                detail: match state {
                    Install::Missing => format!("{} not installed", skill_md.display()),
                    Install::Current => format!("{} matches this version", skill_md.display()),
                    Install::Outdated => {
                        format!("{} is from another version", skill_md.display())
                    }
                    Install::Foreign => {
                        format!("{} is not mojo-anything's skill", skill_md.display())
                    }
                },
                fix: match state {
                    Install::Current => None,
                    Install::Missing | Install::Outdated => Some(setup_fix(agent)),
                    Install::Foreign => Some(format!(
                        "move {} aside, then run `{}`",
                        dir.display(),
                        setup_fix(agent)
                    )),
                },
            });
        }
    }
    checks
}

/// The agent's `mojo-anything` entry; `Err` when the settings file cannot be read as settings.
fn read_entry(agent: Agent, path: &Path) -> Result<Option<Entry>, String> {
    let text = match std::fs::read_to_string(path) {
        Ok(t) => t,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("reading {}: {e}", path.display())),
    };
    if text.trim().is_empty() {
        return Ok(None);
    }
    if agent == Agent::Codex {
        let doc: toml_edit::DocumentMut = text
            .parse()
            .map_err(|_| format!("{} is not valid TOML", path.display()))?;
        let Some(server) = doc
            .get("mcp_servers")
            .and_then(|s| s.get(NAME))
            .and_then(toml_edit::Item::as_table_like)
        else {
            return Ok(None);
        };
        return Ok(Some(Entry {
            command: server
                .get("command")
                .and_then(|c| c.as_str())
                .map(String::from),
            args: server
                .get("args")
                .and_then(|a| a.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|v| v.as_str().map(String::from))
                        .collect()
                })
                .unwrap_or_default(),
            url: server.get("url").is_some(),
            disabled: false,
        }));
    }
    if agent == Agent::OpenCode {
        let doc: Value = serde_json::from_str(&text)
            .map_err(|_| format!("{} is not valid JSON", path.display()))?;
        // Current OpenCode keeps servers under `mcp.servers`; older files list them in `mcp`.
        let mcp = &doc["mcp"];
        let servers = if mcp.get("servers").is_some() {
            &mcp["servers"]
        } else {
            mcp
        };
        let Some(server) = servers.get(NAME) else {
            return Ok(None);
        };
        // OpenCode's local server takes the whole argv in `command`.
        let mut argv = server["command"]
            .as_array()
            .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)));
        return Ok(Some(Entry {
            command: argv.as_mut().and_then(|a| a.next()),
            args: argv.into_iter().flatten().collect(),
            url: server.get("url").is_some(),
            disabled: server["disabled"].as_bool() == Some(true),
        }));
    }
    let doc: Value =
        serde_json::from_str(&text).map_err(|_| format!("{} is not valid JSON", path.display()))?;
    let Some(server) = doc["mcpServers"].get(NAME) else {
        return Ok(None);
    };
    Ok(Some(Entry {
        command: server["command"].as_str().map(String::from),
        args: server["args"]
            .as_array()
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default(),
        url: server.get("url").is_some(),
        disabled: false,
    }))
}

/// The report for people: one line per check, the fix under each problem.
pub fn text(r: &Report) -> String {
    let mut out = String::new();
    let width = r.checks.iter().map(|c| c.name.len()).max().unwrap_or(0);
    for c in &r.checks {
        let optional = if c.required || c.status == Status::Ok {
            ""
        } else {
            " (optional)"
        };
        out.push_str(&format!(
            "{:<9} {:<width$}  {}{optional}\n",
            c.status.label(),
            c.name,
            c.detail
        ));
        if let Some(fix) = &c.fix {
            // Further lines of a fix line up under the first.
            for (i, line) in fix.lines().enumerate() {
                let label = if i == 0 { "fix:" } else { "" };
                out.push_str(&format!("{:<9} {:<width$}  {label:<4} {line}\n", "", ""));
            }
        }
    }
    out.push_str(if r.ok() {
        "\nEverything required is in place. Language runtimes are optional: each matters only for the languages you port.\n"
    } else {
        "\nSomething required is missing: pixi or the pinned Mojo, the MCP server, or the setup of an agent found here. Run the fix commands above.\n"
    });
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn versions_are_read_from_every_banner() {
        let cases = [
            ("v24.1.0", Version(24, 1, 0)),
            ("Python 3.12.1", Version(3, 12, 1)),
            ("go version go1.22.3 darwin/arm64", Version(1, 22, 3)),
            (
                "ruby 2.6.10p210 (2022-04-12 revision 67958) [universal.arm64e-darwin26]",
                Version(2, 6, 10),
            ),
            ("openjdk version \"21.0.8\" 2025-07-15", Version(21, 0, 8)),
            ("javac 17", Version(17, 0, 0)),
            ("PHP 8.3.4 (cli) (built: Mar 12 2024)", Version(8, 3, 4)),
            ("cargo 1.97.0 (abcdef 2026-01-01)", Version(1, 97, 0)),
            ("8.0.100", Version(8, 0, 100)),
        ];
        for (text, want) in cases {
            assert_eq!(parse_version(text), Some(want), "{text}");
        }
        assert_eq!(parse_version("no digits"), None);
        assert_eq!(
            parse_java_version("java version \"1.8.0_281\""),
            Some(Version(8, 0, 0))
        );
        assert_eq!(
            parse_java_version("openjdk version \"17.0.2\""),
            Some(Version(17, 0, 2))
        );
    }

    #[test]
    fn java_and_javac_need_java_22() {
        for name in ["java", "javac"] {
            let r = RUNTIMES.iter().find(|r| r.name == name).unwrap();
            assert_eq!(r.minimum, Some(Version(22, 0, 0)), "{name}");
            let banner = Some(Version(21, 0, 2));
            assert_eq!(grade(true, banner, r.minimum), Status::Outdated, "{name}");
        }
    }

    #[test]
    fn doctor_on_windows_points_at_wsl() {
        let checks = mojo_toolchain(Platform::Windows);
        let names: Vec<&str> = checks.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["pixi", "mojo"]);
        for c in &checks {
            assert_ne!(c.status, Status::Ok, "{c:?}");
            assert!(c.required, "{c:?}");
            let fix = c.fix.as_deref().unwrap_or_default();
            assert!(fix.contains("wsl -d Ubuntu-24.04"), "{c:?}");
        }
    }

    #[test]
    fn java_21_is_too_old() {
        let status = grade(true, Some(Version(21, 0, 4)), Some(Version(22, 0, 0)));
        assert_eq!(status, Status::Outdated);
        let java = runtime_named("java");
        let c = assess(
            java,
            Some("openjdk version \"21.0.4\" 2024-07-16".into()),
            Platform::Other,
        );
        assert_eq!(c.status, Status::Outdated, "{c:?}");
        assert!(!c.required, "{c:?}");
        let fix = c.fix.unwrap_or_default();
        assert!(fix.contains("Java 22"), "{fix}");
    }

    #[test]
    fn node_22_warns_about_wasm() {
        let node = runtime_named("node");
        let c = assess(node, Some("v22.12.0".into()), Platform::Other);
        assert_eq!(c.status, Status::Outdated, "{c:?}");
        assert!(!c.required, "{c:?}");
        assert!(c.detail.contains("mojo-wasm"), "{c:?}");
        assert!(c.fix.is_some(), "{c:?}");
        let ok = assess(node, Some("v24.1.0".into()), Platform::Other);
        assert_eq!(ok.status, Status::Ok, "{ok:?}");
        assert!(ok.fix.is_none(), "{ok:?}");
    }

    #[test]
    fn rows_are_the_mojo_toolchain_and_the_runtimes() {
        let names: Vec<&str> = RUNTIMES.iter().map(|r| r.name).collect();
        for name in [
            "python", "node", "go", "ruby", "java", "kotlinc", "php", "dotnet",
        ] {
            assert!(names.contains(&name), "no {name} in {names:?}");
        }
        assert!(!names.contains(&"cargo"), "{names:?}");
        for r in RUNTIMES {
            assert!(!assess(r, None, Platform::Other).required, "{}", r.name);
            for status in [Status::Missing, Status::Outdated] {
                for platform in [Platform::MacOs, Platform::Windows, Platform::Other] {
                    let fix = runtime_fix(r, status, platform).unwrap();
                    assert!(!fix.contains("winget"), "{}: {fix}", r.name);
                    assert!(!fix.contains("rustup"), "{}: {fix}", r.name);
                }
            }
        }
    }

    #[test]
    fn runtimes_are_graded_against_their_minimum() {
        let min = Some(Version(3, 0, 0));
        assert_eq!(grade(false, None, min), Status::Missing);
        assert_eq!(grade(true, Some(Version(2, 6, 10)), min), Status::Outdated);
        assert_eq!(grade(true, Some(Version(3, 0, 0)), min), Status::Ok);
        assert_eq!(grade(true, Some(Version(3, 4, 1)), min), Status::Ok);
        assert_eq!(grade(true, None, min), Status::Ok);
        assert_eq!(grade(true, Some(Version(1, 0, 0)), None), Status::Ok);
        assert!(Version(22, 6, 0) > Version(22, 5, 9));
    }

    #[test]
    fn install_states_map_to_statuses() {
        assert_eq!(Status::from(Install::Missing), Status::Missing);
        assert_eq!(Status::from(Install::Current), Status::Ok);
        assert_eq!(Status::from(Install::Outdated), Status::Outdated);
        assert_eq!(Status::from(Install::Foreign), Status::Foreign);
        assert_eq!(
            serde_json::to_value(Status::Outdated).unwrap(),
            json!("outdated")
        );
    }

    #[test]
    fn mcp_entries_are_ours_only_when_they_run_this_binary() {
        let exe = Path::new("/opt/bin/mojo-anything");
        let entry = |command: &str, args: &[&str], url: bool| Entry {
            command: Some(command.into()),
            args: args.iter().map(|a| a.to_string()).collect(),
            url,
            disabled: false,
        };
        assert_eq!(entry_state(None, exe), Install::Missing);
        assert_eq!(
            entry_state(Some(&entry("/opt/bin/mojo-anything", &["mcp"], false)), exe),
            Install::Current
        );
        assert_eq!(
            entry_state(Some(&entry("/old/mojo-anything", &["mcp"], false)), exe),
            Install::Outdated
        );
        assert_eq!(
            entry_state(
                Some(&entry("/opt/bin/mojo-anything", &["serve"], false)),
                exe
            ),
            Install::Foreign
        );
        assert_eq!(
            entry_state(Some(&entry("/opt/bin/mojo-anything", &["mcp"], true)), exe),
            Install::Foreign
        );
        assert_eq!(entry_state(Some(&Entry::default()), exe), Install::Foreign);
        // A server OpenCode keeps disabled is not current.
        let mut disabled = entry("/opt/bin/mojo-anything", &["mcp"], false);
        disabled.disabled = true;
        assert_eq!(entry_state(Some(&disabled), exe), Install::Outdated);
    }

    #[test]
    fn opencode_entries_come_from_mcp_servers() {
        let home = std::env::temp_dir().join(format!(
            "mojo-anything-doctor-opencode-{}",
            std::process::id()
        ));
        let _ = std::fs::remove_dir_all(&home);
        std::fs::create_dir_all(home.join(".config/opencode")).unwrap();
        let config = home.join(".config/opencode/opencode.json");
        std::fs::write(
            &config,
            r#"{"mcp":{"servers":{"mojo-anything":{"type":"local","command":["/opt/bin/mojo-anything","mcp"]}}}}"#,
        )
        .unwrap();
        let exe = Path::new("/opt/bin/mojo-anything");
        let entry = read_entry(Agent::OpenCode, &config).unwrap();
        assert_eq!(entry_state(entry.as_ref(), exe), Install::Current);
        assert_eq!(
            entry_state(entry.as_ref(), Path::new("/elsewhere/mojo-anything")),
            Install::Outdated
        );
        std::fs::write(
            &config,
            r#"{"mcp":{"servers":{"mojo-anything":{"type":"local","command":["/opt/bin/mojo-anything","mcp"],"disabled":true}}}}"#,
        )
        .unwrap();
        let entry = read_entry(Agent::OpenCode, &config).unwrap();
        assert_eq!(entry_state(entry.as_ref(), exe), Install::Outdated);
        // Older files list servers in `mcp` itself.
        std::fs::write(
            &config,
            r#"{"mcp":{"mojo-anything":{"type":"local","command":["/opt/bin/mojo-anything","mcp"]}}}"#,
        )
        .unwrap();
        let entry = read_entry(Agent::OpenCode, &config).unwrap();
        assert_eq!(entry_state(entry.as_ref(), exe), Install::Current);
        std::fs::remove_dir_all(&home).unwrap();
    }

    #[test]
    fn skills_are_current_outdated_or_foreign() {
        let ours: Vec<Option<String>> = SKILL_FILES
            .iter()
            .map(|(_, t)| Some(t.to_string()))
            .collect();
        assert_eq!(skill_state(&ours), Install::Current);
        assert_eq!(
            skill_state(&vec![None; SKILL_FILES.len()]),
            Install::Missing
        );
        let mut old = ours.clone();
        old[0] = Some(format!(
            "---\nname: {NAME}\ndescription: old\n---\n\n# Old\n"
        ));
        assert_eq!(skill_state(&old), Install::Outdated);
        let mut partial = ours.clone();
        partial[1] = None;
        assert_eq!(skill_state(&partial), Install::Outdated);
        let mut foreign = ours;
        foreign[0] = Some("---\nname: something-else\n---\n".into());
        assert_eq!(skill_state(&foreign), Install::Foreign);
    }

    #[test]
    fn only_required_problems_fail_the_report() {
        let check = |status, required| Check {
            name: "x".into(),
            status,
            required,
            detail: String::new(),
            fix: None,
        };
        let optional = Report {
            checks: vec![check(Status::Ok, true), check(Status::Missing, false)],
        };
        assert!(optional.ok());
        let required = Report {
            checks: vec![check(Status::Outdated, true)],
        };
        assert!(!required.ok());
    }

    fn runtime_named(name: &str) -> &'static Runtime {
        RUNTIMES.iter().find(|r| r.name == name).unwrap()
    }

    #[test]
    fn fixes_follow_the_platform() {
        let cc = runtime_named("cc");
        let fix = |platform| runtime_fix(cc, Status::Missing, platform);
        assert_eq!(
            fix(Platform::MacOs).as_deref(),
            Some("xcode-select --install")
        );
        assert_eq!(
            fix(Platform::Windows),
            Some(format!("in WSL ({WSL}): sudo apt install build-essential"))
        );
        assert_eq!(
            fix(Platform::Other).as_deref(),
            Some("sudo apt install build-essential")
        );
        assert_eq!(runtime_fix(cc, Status::Ok, Platform::Windows), None);
    }

    #[test]
    fn the_pinned_mojo_comes_from_the_units_channels() {
        let args = pinned_mojo_args();
        let line = args.join(" ");
        assert_eq!(
            line,
            format!(
                "exec -c https://conda.modular.com/max -c conda-forge --spec mojo=={} mojo --version",
                crate::mojo::MOJO_VERSION
            )
        );
    }

    #[test]
    fn fixes_of_several_lines_line_up() {
        let report = Report {
            checks: vec![Check {
                name: "mojo".into(),
                status: Status::Missing,
                required: true,
                detail: "not found".into(),
                fix: Some("first\nsecond".into()),
            }],
        };
        let out = text(&report);
        let lines: Vec<_> = out.lines().collect();
        assert!(lines[1].trim_start().starts_with("fix: first"), "{out}");
        assert_eq!(lines[1].find("first"), lines[2].find("second"), "{out}");
    }

    #[test]
    fn mcp_fix_points_at_the_npm_wrapper_and_the_release() {
        let check = mcp_self_test(Path::new("/nonexistent/mojo-anything"));
        assert_eq!(check.status, Status::Missing);
        let fix = check.fix.unwrap();
        assert!(fix.contains("npm install -g mojo-anything"), "{fix}");
        assert!(
            fix.contains("https://github.com/ModelTok/mojo-anything/releases"),
            "{fix}"
        );
        assert!(!fix.contains("cargo"), "{fix}");
    }
}
