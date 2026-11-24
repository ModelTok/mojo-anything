//! The plugin, the npm wrapper and the MCP registry entry describe the same tool, at the crate's
//! version, under ModelTok's name; the npm launcher fetches the release asset for the platforms
//! a release builds and refuses the rest in plain words.

mod common;

use std::io::{BufRead as _, BufReader, Write as _};
use std::net::TcpListener;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::sync::atomic::{AtomicUsize, Ordering};

use serde_json::Value;

const REPOSITORY: &str = "https://github.com/ModelTok/mojo-anything";

fn root() -> &'static Path {
    Path::new(env!("CARGO_MANIFEST_DIR"))
}

fn read(path: &str) -> String {
    std::fs::read_to_string(root().join(path)).unwrap()
}

fn json(path: &str) -> Value {
    serde_json::from_str(&read(path)).unwrap()
}

/// The files that name the tool to the outside: the marketplace, plugin manifests, npm package,
/// registry entry.
const MANIFESTS: &[&str] = &[
    ".claude-plugin/marketplace.json",
    "plugin/.claude-plugin/plugin.json",
    "plugin/.codex-plugin/plugin.json",
    "directory/.claude-plugin/plugin.json",
    "npm/mojo-anything/package.json",
    "server.json",
];

#[test]
fn the_plugin_ships_the_same_skill_and_mcp_server() {
    for dir in ["plugin", "directory"] {
        for file in ["SKILL.md", "whole-app.md"] {
            assert_eq!(
                read(&format!("{dir}/skills/mojo-anything/{file}")),
                read(&format!("skills/mojo-anything/{file}")),
                "{dir}/skills/mojo-anything/{file} differs from skills/mojo-anything/{file}"
            );
        }
    }
    assert_eq!(read("plugin/.mcp.json"), read(".mcp.json"));
    let mcp = json(".mcp.json");
    assert_eq!(
        mcp["mcpServers"]["mojo-anything"]["command"],
        "mojo-anything"
    );
    assert_eq!(mcp["mcpServers"]["mojo-anything"]["args"][0], "mcp");
}

#[test]
fn the_plugin_version_is_the_crate_version() {
    assert_eq!(env!("CARGO_PKG_VERSION"), "0.1.0");
    for path in [
        "plugin/.claude-plugin/plugin.json",
        "plugin/.codex-plugin/plugin.json",
        "directory/.claude-plugin/plugin.json",
        "npm/mojo-anything/package.json",
    ] {
        assert_eq!(json(path)["version"], env!("CARGO_PKG_VERSION"), "{path}");
    }
}

#[test]
fn server_json_matches_crate() {
    let server = json("server.json");
    let version = env!("CARGO_PKG_VERSION");
    assert_eq!(server["name"], "io.github.ModelTok/mojo-anything");
    assert_eq!(server["version"], version);
    assert_eq!(server["repository"]["url"], REPOSITORY);
    assert_eq!(server["websiteUrl"], REPOSITORY);
    let packages = server["packages"].as_array().unwrap();
    assert_eq!(packages.len(), 1);
    assert_eq!(packages[0]["registryType"], "npm");
    assert_eq!(packages[0]["identifier"], "mojo-anything");
    assert_eq!(packages[0]["version"], version);
    let npm = json("npm/mojo-anything/package.json");
    assert_eq!(npm["name"], packages[0]["identifier"]);
    assert_eq!(npm["mcpName"], server["name"]);
    assert_eq!(npm["repository"]["url"], format!("git+{REPOSITORY}.git"));
}

#[test]
fn manifests_name_mojo_and_modeltok() {
    let rust = regex::Regex::new(r"(?i)\brust\b|rust-anything|erkamyaman|napi|pyo3|cargo").unwrap();
    let mut problems = Vec::new();
    for path in MANIFESTS {
        let text = read(path);
        for m in rust.find_iter(&text) {
            problems.push(format!("{path}: `{}`", m.as_str()));
        }
        if !text.contains("Mojo") {
            problems.push(format!("{path}: does not say Mojo"));
        }
    }
    let cargo = read("Cargo.toml");
    let package = cargo.split("\n[").next().unwrap();
    if !package.contains(&format!("repository = \"{REPOSITORY}\"")) {
        problems.push(format!(
            "Cargo.toml [package]: repository is not {REPOSITORY}"
        ));
    }
    // The tool is written in Rust (`rust-version` stays); what it says it does is Mojo.
    let described: String = package
        .lines()
        .filter(|l| l.starts_with("description") || l.starts_with("keywords"))
        .collect();
    for m in regex::Regex::new(r"(?i)\brust\b|erkamyaman|napi|pyo3")
        .unwrap()
        .find_iter(&described)
    {
        problems.push(format!("Cargo.toml [package]: `{}`", m.as_str()));
    }
    assert!(problems.is_empty(), "{}", problems.join("\n"));
}

fn scratch(name: &str) -> PathBuf {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let dir = std::env::temp_dir().join(format!(
        "mojo-anything-plugin-{}-{}-{name}",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// Runs the npm launcher with `process.platform` and `process.arch` replaced and `env` added;
/// the download cache is a scratch folder unless `env` names one.
fn run_launcher(platform: &str, arch: &str, args: &[&str], env: &[(&str, &str)]) -> Output {
    let dir = scratch(&format!("stub-{platform}-{arch}"));
    let stub = dir.join("stub.cjs");
    std::fs::write(
        &stub,
        format!(
            "Object.defineProperty(process, 'platform', {{ value: '{platform}' }})\n\
             Object.defineProperty(process, 'arch', {{ value: '{arch}' }})\n"
        ),
    )
    .unwrap();
    let mut cmd = Command::new("node");
    cmd.arg("--require")
        .arg(&stub)
        .arg(root().join("npm/mojo-anything/bin/mojo-anything.js"))
        .args(args)
        .env_remove("MOJO_ANYTHING_DOWNLOAD_BASE")
        .env("MOJO_ANYTHING_CACHE", dir.join("cache"));
    for (k, v) in env {
        cmd.env(k, v);
    }
    cmd.output().unwrap()
}

/// The launcher's exit code and everything it printed.
fn launcher(platform: &str, arch: &str, args: &[&str], env: &[(&str, &str)]) -> (i32, String) {
    let out = run_launcher(platform, arch, args, env);
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    (out.status.code().unwrap_or(-1), text)
}

#[test]
fn npm_launcher_rejects_windows() {
    if !common::have("node") {
        return;
    }
    let (code, text) = launcher("win32", "x64", &["--version"], &[]);
    assert_ne!(code, 0, "{text}");
    assert!(text.contains("WSL"), "{text}");
    assert!(text.contains("wsl --install"), "{text}");
    assert!(!text.contains("cargo"), "{text}");
}

#[test]
fn npm_launcher_names_the_supported_platforms() {
    if !common::have("node") {
        return;
    }
    let (code, text) = launcher("darwin", "x64", &["--version"], &[]);
    assert_ne!(code, 0, "{text}");
    for platform in ["darwin-x64", "linux-x64", "linux-arm64", "darwin-arm64"] {
        assert!(text.contains(platform), "{platform} not named: {text}");
    }
}

/// The platform key and release target the launcher downloads on this machine, if a release
/// builds one.
fn host() -> Option<(&'static str, &'static str, &'static str)> {
    match (std::env::consts::OS, std::env::consts::ARCH) {
        ("linux", "x86_64") => Some(("linux", "x64", "x86_64-unknown-linux-gnu")),
        ("linux", "aarch64") => Some(("linux", "arm64", "aarch64-unknown-linux-gnu")),
        ("macos", "aarch64") => Some(("darwin", "arm64", "aarch64-apple-darwin")),
        _ => None,
    }
}

/// A release laid out as `release.yml` uploads it (the archive and `SHA256SUMS` under
/// `<tag>/`), served on a local port; the archive holds a stand-in `mojo-anything` that prints
/// its arguments. With `bad_sum`, `SHA256SUMS` names another hash. Returns the base URL.
fn fake_release(dir: &Path, target: &str, bad_sum: bool) -> String {
    let tag = format!("v{}", env!("CARGO_PKG_VERSION"));
    let name = format!("mojo-anything-{tag}-{target}");
    let folder = dir.join("build").join(&name);
    std::fs::create_dir_all(&folder).unwrap();
    let exe = folder.join("mojo-anything");
    std::fs::write(&exe, "#!/bin/sh\necho \"stand-in mojo-anything $*\"\n").unwrap();
    let ok = Command::new("chmod").arg("755").arg(&exe).status().unwrap();
    assert!(ok.success());
    let assets = dir.join("assets").join(&tag);
    std::fs::create_dir_all(&assets).unwrap();
    let archive = format!("{name}.tar.gz");
    let ok = Command::new("tar")
        .arg("czf")
        .arg(assets.join(&archive))
        .arg("-C")
        .arg(dir.join("build"))
        .arg(&name)
        .status()
        .unwrap();
    assert!(ok.success());
    let sum = if bad_sum {
        "0".repeat(64)
    } else {
        let out = Command::new("sh")
            .arg("-c")
            .arg("sha256sum \"$1\" 2>/dev/null || shasum -a 256 \"$1\"")
            .arg("sh")
            .arg(assets.join(&archive))
            .output()
            .unwrap();
        String::from_utf8(out.stdout).unwrap()[..64].to_string()
    };
    std::fs::write(
        assets.join("SHA256SUMS"),
        format!("{}  README.md\n{sum}  {archive}\n", "1".repeat(64)),
    )
    .unwrap();
    serve(dir.join("assets"))
}

/// Serves the files under `dir` over HTTP on a free local port until the test ends.
fn serve(dir: PathBuf) -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let addr = listener.local_addr().unwrap();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let Ok(clone) = stream.try_clone() else {
                continue;
            };
            let mut reader = BufReader::new(clone);
            let mut request = String::new();
            if reader.read_line(&mut request).is_err() {
                continue;
            }
            loop {
                let mut line = String::new();
                if reader.read_line(&mut line).map_or(true, |n| n == 0) || line == "\r\n" {
                    break;
                }
            }
            let path = request.split(' ').nth(1).unwrap_or("/");
            let file = dir.join(path.trim_start_matches('/'));
            let (status, body) = match std::fs::read(&file) {
                Ok(body) if !path.contains("..") => ("200 OK", body),
                _ => ("404 Not Found", b"not found".to_vec()),
            };
            let _ = write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            );
            let _ = stream.write_all(&body);
        }
    });
    format!("http://{addr}")
}

fn cached(cache: &Path, platform: &str, arch: &str) -> PathBuf {
    cache
        .join(env!("CARGO_PKG_VERSION"))
        .join(format!("{platform}-{arch}"))
        .join("mojo-anything")
}

#[test]
fn npm_launcher_downloads_checks_and_runs_the_release_binary() {
    if !common::have("node") || !common::have("tar") {
        return;
    }
    let Some((platform, arch, target)) = host() else {
        eprintln!("skipped: a release builds no binary for this machine");
        return;
    };
    let dir = scratch("release");
    let base = fake_release(&dir, target, false);
    let cache = dir.join("cache");
    let cache_var = cache.to_str().unwrap();
    let env = [
        ("MOJO_ANYTHING_DOWNLOAD_BASE", base.as_str()),
        ("MOJO_ANYTHING_CACHE", cache_var),
    ];
    let out = run_launcher(platform, arch, &["mcp", "--x"], &env);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(out.status.success(), "{stderr}");
    // An MCP client reads stdout as JSON-RPC: only the binary writes there, the download
    // notice goes to stderr.
    assert_eq!(
        String::from_utf8_lossy(&out.stdout),
        "stand-in mojo-anything mcp --x\n"
    );
    assert!(stderr.contains("downloading"), "{stderr}");
    assert!(cached(&cache, platform, arch).is_file(), "not cached");
    // The second run uses the cached binary: nothing listens at the download base any more.
    let gone = [
        ("MOJO_ANYTHING_DOWNLOAD_BASE", "http://127.0.0.1:9"),
        ("MOJO_ANYTHING_CACHE", cache_var),
    ];
    let (code, text) = launcher(platform, arch, &["again"], &gone);
    assert_eq!(code, 0, "{text}");
    assert_eq!(text, "stand-in mojo-anything again\n");
}

#[test]
fn npm_launcher_refuses_a_bad_checksum() {
    if !common::have("node") || !common::have("tar") {
        return;
    }
    let Some((platform, arch, target)) = host() else {
        return;
    };
    let dir = scratch("badsum");
    let base = fake_release(&dir, target, true);
    let cache = dir.join("cache");
    let env = [
        ("MOJO_ANYTHING_DOWNLOAD_BASE", base.as_str()),
        ("MOJO_ANYTHING_CACHE", cache.to_str().unwrap()),
    ];
    let (code, text) = launcher(platform, arch, &["--version"], &env);
    assert_ne!(code, 0, "{text}");
    assert!(text.contains("SHA-256"), "{text}");
    assert!(!text.contains("stand-in"), "{text}");
    assert!(
        !cached(&cache, platform, arch).exists(),
        "a binary that failed its checksum was cached"
    );
}

#[test]
fn npm_launcher_says_when_the_release_is_missing() {
    if !common::have("node") {
        return;
    }
    let Some((platform, arch, _)) = host() else {
        return;
    };
    let dir = scratch("missing");
    let base = serve(dir.join("empty"));
    let env = [("MOJO_ANYTHING_DOWNLOAD_BASE", base.as_str())];
    let (code, text) = launcher(platform, arch, &["--version"], &env);
    assert_ne!(code, 0, "{text}");
    assert!(text.contains("404"), "{text}");
    assert!(
        text.contains(&format!("v{}", env!("CARGO_PKG_VERSION"))),
        "{text}"
    );
}
