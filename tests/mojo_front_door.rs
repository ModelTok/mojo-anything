//! The Mojo tool (`tool/`) in front of the Phase 1 binary: every subcommand it does not own runs
//! the binary in `tool/fallback/` with the same arguments, stdin and environment, and replaying
//! the recording in `mojo/app-cases/` through it passes every case.

mod common;

use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::OnceLock;

fn repo() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

fn pixi() -> PathBuf {
    std::env::var_os("PATH")
        .and_then(|paths| {
            std::env::split_paths(&paths)
                .map(|p| p.join("pixi"))
                .find(|p| p.is_file())
        })
        .or_else(|| {
            std::env::var_os("HOME")
                .map(|h| PathBuf::from(h).join(".pixi/bin/pixi"))
                .filter(|p| p.is_file())
        })
        .expect("pixi is on PATH or in ~/.pixi/bin")
}

fn fallback_binary() -> PathBuf {
    repo().join("tool/fallback/mojo-anything")
}

/// Builds the Phase 1 binary (once per checkout) and the Mojo tool (once per test run).
fn mojo_tool() -> &'static Path {
    static BUILT: OnceLock<PathBuf> = OnceLock::new();
    BUILT.get_or_init(|| {
        if !fallback_binary().is_file() {
            let status = Command::new("bash")
                .arg(repo().join("scripts/build-fallback.sh"))
                .current_dir(repo())
                .env_remove("CARGO_TARGET_DIR")
                .status()
                .expect("scripts/build-fallback.sh runs");
            assert!(status.success(), "scripts/build-fallback.sh failed");
        }
        let out = Command::new(pixi())
            .args(["run", "--manifest-path"])
            .arg(repo().join("pixi.toml"))
            .arg("build-tool")
            .current_dir(repo())
            .output()
            .expect("pixi runs");
        assert!(
            out.status.success(),
            "pixi run build-tool failed:\n{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        repo().join("tool/build/mojo-anything")
    })
}

fn run(binary: &Path, args: &[&str], env: &[(&str, &str)]) -> Output {
    let mut cmd = Command::new(binary);
    cmd.args(args).current_dir(repo());
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.output().expect("the binary runs")
}

#[test]
fn all_cases_pass_with_help_in_mojo() {
    if !common::have_mojo() {
        return;
    }
    let tool = mojo_tool();
    let out = run(
        &fallback_binary(),
        &["app", "replay", ".", "--build", &tool.to_string_lossy()],
        &[],
    );
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(
        out.status.success(),
        "{stdout}{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let first = stdout.lines().next().unwrap_or_default();
    let (passed, total) = first
        .trim_end_matches(" cases passed")
        .split_once('/')
        .expect("a passed/total line");
    assert_eq!(passed, total, "{stdout}");
    assert!(total.parse::<usize>().unwrap_or(0) > 500, "{stdout}");
    // Help and version, clap's usage errors, setup, app record and app replay
    // are answered in Mojo, and doctor in Mojo but for its `mcp` self-test; the
    // other cases' commands still fall back (372 of 524 measured), so the rate
    // is reported and below 100%.
    let rate = stdout
        .lines()
        .find_map(|l| l.strip_prefix("Fallback rate: "))
        .unwrap_or_else(|| panic!("no fallback rate:\n{stdout}"));
    let (fell_back, of) = rate
        .split_once('(')
        .and_then(|(_, r)| r.trim_end_matches(')').split_once('/'))
        .unwrap_or_else(|| panic!("a (fallbacks/total) rate:\n{stdout}"));
    assert_eq!(of, total, "{stdout}");
    let fell_back: usize = fell_back.parse().unwrap_or(usize::MAX);
    let total: usize = total.parse().unwrap_or(0);
    assert!(fell_back <= 372 && fell_back < total, "{stdout}");
}

#[test]
fn help_and_version_do_not_fall_back() {
    if !common::have_mojo() {
        return;
    }
    let tool = mojo_tool();
    for args in [
        &["--version"][..],
        &["-h"],
        &["analyze", "--help"],
        &["app", "record", "--help"],
    ] {
        let log = std::env::temp_dir().join(format!(
            "mojo-front-door-owned-{}-{}",
            std::process::id(),
            args.join("_")
        ));
        let _ = std::fs::remove_file(&log);
        let mojo = run(
            tool,
            args,
            &[("MOJO_ANYTHING_FALLBACK_LOG", &log.to_string_lossy())],
        );
        let rust = run(&fallback_binary(), args, &[]);
        let logged = std::fs::read_to_string(&log);
        let _ = std::fs::remove_file(&log);
        assert_eq!(logged.ok().as_deref(), Some(""), "{args:?}");
        assert_eq!(mojo.status.code(), rust.status.code(), "{args:?}");
        assert_eq!(mojo.stdout, rust.stdout, "{args:?}");
    }
}

#[test]
fn fallback_keeps_exit_and_stderr() {
    if !common::have_mojo() {
        return;
    }
    let tool = mojo_tool();
    let args = ["bridge", "/nonexistent"];
    let mojo = run(tool, &args, &[]);
    let rust = run(&fallback_binary(), &args, &[]);
    assert_ne!(rust.status.code(), Some(0));
    assert_eq!(mojo.status.code(), rust.status.code());
    assert_eq!(
        String::from_utf8_lossy(&mojo.stderr),
        String::from_utf8_lossy(&rust.stderr)
    );
    assert_eq!(mojo.stdout, rust.stdout);
}

#[test]
fn fallback_binary_missing() {
    if !common::have_mojo() {
        return;
    }
    let tool = mojo_tool();
    let out = run(
        tool,
        &["analyze", "."],
        &[("MOJO_ANYTHING_FALLBACK", "/nope")],
    );
    assert_ne!(out.status.code(), Some(0));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(stderr.contains("tool/fallback"), "{stderr}");
    assert_eq!(stderr.lines().count(), 1, "{stderr}");
}

#[test]
fn fallback_is_logged_once_per_run() {
    if !common::have_mojo() {
        return;
    }
    let tool = mojo_tool();
    let log = std::env::temp_dir().join(format!("mojo-front-door-log-{}", std::process::id()));
    let _ = std::fs::remove_file(&log);
    let out = run(
        tool,
        &["diff", "/nonexistent"],
        &[("MOJO_ANYTHING_FALLBACK_LOG", &log.to_string_lossy())],
    );
    assert_eq!(out.status.code(), Some(2));
    let logged = std::fs::read_to_string(&log).unwrap_or_default();
    let _ = std::fs::remove_file(&log);
    assert_eq!(logged.lines().count(), 1, "{logged}");
}

/// clap's usage errors are answered in Mojo, byte for byte, without the fallback.
#[test]
fn usage_errors_do_not_fall_back() {
    if !common::have_mojo() {
        return;
    }
    let tool = mojo_tool();
    for args in [
        &["analyze", "--nope"][..],
        &["nope"],
        &["fuzz", "--seed", "x"],
        &["app", "wire"],
    ] {
        let log = std::env::temp_dir().join(format!(
            "mojo-front-door-usage-{}-{}",
            std::process::id(),
            args.join("_")
        ));
        let _ = std::fs::remove_file(&log);
        let mojo = run(
            tool,
            args,
            &[("MOJO_ANYTHING_FALLBACK_LOG", &log.to_string_lossy())],
        );
        let rust = run(&fallback_binary(), args, &[]);
        let logged = std::fs::read_to_string(&log);
        let _ = std::fs::remove_file(&log);
        assert_eq!(logged.ok().as_deref(), Some(""), "{args:?}");
        assert_eq!(mojo.status.code(), Some(2), "{args:?}");
        assert_eq!(mojo.status.code(), rust.status.code(), "{args:?}");
        assert_eq!(mojo.stderr, rust.stderr, "{args:?}");
    }
}

/// `setup` through the Mojo tool registers the Mojo tool, not the Phase 1 binary it would
/// otherwise exec into. The recording cannot catch this: its `binary` normaliser masks both
/// `tool/build/` and `tool/fallback/`.
#[test]
fn setup_registers_the_mojo_binary() {
    if !common::have_mojo() {
        return;
    }
    let tool = mojo_tool();
    let home = std::env::temp_dir().join(format!("mojo-front-door-setup-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(&home).unwrap();
    let out = run(
        tool,
        &["setup", "--agent", "cursor", "--json", "--no-backup"],
        &[("HOME", &home.to_string_lossy())],
    );
    let text = std::fs::read_to_string(home.join(".cursor/mcp.json")).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&home);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let config: serde_json::Value = serde_json::from_str(&text).unwrap();
    let want = std::fs::canonicalize(tool).unwrap();
    assert_eq!(
        config["mcpServers"]["mojo-anything"]["command"],
        want.to_string_lossy().as_ref(),
        "{text}"
    );
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(report["command"], want.to_string_lossy().as_ref());
}

/// A `setup` the Mojo tool hands over (a settings file it cannot rewrite byte for byte)
/// registers the Phase 1 binary; the Mojo `doctor` reads that entry as current, so the fix it
/// would print cannot loop.
#[test]
fn a_handed_over_setup_reads_as_current_in_doctor() {
    if !common::have_mojo() {
        return;
    }
    let tool = mojo_tool();
    let home = std::env::temp_dir().join(format!("mojo-front-door-doctor-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join(".cursor")).unwrap();
    // `-0` is a number serde_json reads otherwise than Python: setup goes to the Phase 1 binary.
    std::fs::write(home.join(".cursor/mcp.json"), "{\"x\": -0}\n").unwrap();
    let log = home.join("fallback.log");
    let vars = [
        ("HOME", home.to_string_lossy().into_owned()),
        (
            "MOJO_ANYTHING_FALLBACK_LOG",
            log.to_string_lossy().into_owned(),
        ),
    ];
    let env: Vec<(&str, &str)> = vars.iter().map(|(k, v)| (*k, v.as_str())).collect();
    let out = run(tool, &["setup", "--agent", "cursor", "--no-backup"], &env);
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let handed = std::fs::read_to_string(&log).unwrap_or_default();
    let _ = std::fs::remove_file(&log);
    let text = std::fs::read_to_string(home.join(".cursor/mcp.json")).unwrap_or_default();
    let out = run(tool, &["doctor", "--json"], &env);
    let doctor_log = std::fs::read_to_string(&log).unwrap_or_default();
    let _ = std::fs::remove_dir_all(&home);
    assert!(
        handed.starts_with("setup"),
        "setup was not handed over: {handed:?}"
    );
    let config: serde_json::Value = serde_json::from_str(&text).unwrap();
    let phase1 = std::fs::canonicalize(fallback_binary()).unwrap();
    assert_eq!(
        config["mcpServers"]["mojo-anything"]["command"],
        phase1.to_string_lossy().as_ref(),
        "{text}"
    );
    assert!(
        !doctor_log.lines().any(|l| l.starts_with("doctor")),
        "doctor itself fell back: {doctor_log:?}"
    );
    let report: serde_json::Value = serde_json::from_slice(&out.stdout).unwrap();
    let row = report["checks"]
        .as_array()
        .and_then(|c| {
            c.iter().find(|c| {
                c["detail"]
                    .as_str()
                    .is_some_and(|d| d.contains(".cursor/mcp.json"))
                    && c["name"].as_str().is_some_and(|n| n.ends_with(" mcp"))
            })
        })
        .cloned()
        .unwrap_or_default();
    assert_eq!(row["status"], "ok", "{row}");
}
