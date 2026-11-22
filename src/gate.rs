//! Step 5: the definition of done for one port.
//!
//! fmt, clippy (warnings are errors), cargo tests, no unexplained `unsafe`, every function
//! ported, the built module exposes the original API, and the recorded behavior replays cleanly.

use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::Result;
use serde::Serialize;

use crate::bridge::Manifest;
use crate::harness::{self, CASES, DiffOptions};

#[derive(Debug, Serialize)]
pub struct Check {
    pub name: &'static str,
    pub passed: bool,
    pub detail: String,
    /// The next command or edit that clears a failed check.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fix: Option<String>,
}

/// The fix for a failed check, by its name.
fn fix_for(check: &Check, crate_dir: &Path) -> Option<String> {
    let c = crate_dir.display();
    let manifest = format!("--manifest-path {c}/Cargo.toml");
    Some(match check.name {
        "fmt" => format!("cargo fmt {manifest}"),
        "clippy" => {
            format!("cargo clippy --all-targets {manifest} -- -D warnings, then fix each warning")
        }
        "cargo test" => format!("cargo test {manifest}"),
        "unsafe" => "add a `// SAFETY:` comment above each listed `unsafe`, or remove it".into(),
        "ported" => {
            "port the functions still stubbed in src/port.rs, then `mojo-anything gate` again"
                .into()
        }
        "size" => "use the crates `mojo-anything analyze` lists and fold repeated code".into(),
        "build" => format!("fix the compile error above, then `mojo-anything build {c}`"),
        "recording" => format!("mojo-anything record {c}"),
        "behavior" if check.detail.contains("no recorded cases") => {
            format!("mojo-anything record {c}")
        }
        "behavior" => format!(
            "mojo-anything diff {c} to see each mismatch; fix the port, or list an intended difference in {}",
            crate::recording::KNOWN_DIFFS
        ),
        "known diffs" => format!(
            "remove the entries that no longer happen from {c}/{}",
            crate::recording::KNOWN_DIFFS
        ),
        "api" if crate_dir.join("port.mojo").is_file() => format!(
            "define the missing functions in port.mojo, then `mojo-anything refresh {c}` to \
             regenerate index.cjs and the dispatcher"
        ),
        "api" => {
            format!("export the missing functions from src/port.rs, then `mojo-anything build {c}`")
        }
        "java api" => format!(
            "mojo-anything refresh {c} writes the wrappers in java/ again with the original \
             signatures (they are generated: do not edit them by hand)"
        ),
        "error cases" | "panics" => {
            format!("mojo-anything diff {c} to see the cases where the port's errors differ")
        }
        _ => return None,
    })
}

/// Bindings `bridge` writes into `src/`; everything else there is the port.
const GENERATED: [&str; 8] = [
    "lib.rs",
    "js.rs",
    "pinned.rs",
    "pyconv.rs",
    "pynum.rs",
    "rbconv.rs",
    "utf16.rs",
    "wire.rs",
];

/// How many times the source's lines the port may take before `gate` calls it bloated, plus a
/// fixed allowance for the imports and signatures every port has.
pub const MAX_GROWTH: f64 = 3.0;
const ALLOWANCE: f64 = 50.0;

fn code_lines(text: &str, comment: &[&str]) -> usize {
    text.lines()
        .map(str::trim)
        .filter(|l| !l.is_empty() && !comment.iter().any(|c| l.starts_with(c)))
        .count()
}

fn files_under(path: &Path, extensions: &[&str]) -> Vec<std::path::PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    crate::walk::builder(path)
        .build()
        .flatten()
        .map(ignore::DirEntry::into_path)
        .filter(|p| {
            p.extension()
                .is_some_and(|e| extensions.contains(&e.to_string_lossy().as_ref()))
        })
        .collect()
}

/// Lines of Rust in the port against lines of the source unit: a port several times larger
/// usually re-implements what a crate already does.
/// The unit's files and the repository files they import, directly or not: a port stands in
/// for all of them.
pub(crate) fn with_local_imports(root: &Path, files: Vec<PathBuf>) -> Vec<PathBuf> {
    const TRIES: &[&str] = &[
        "",
        ".ts",
        ".tsx",
        ".mts",
        ".cts",
        ".js",
        ".mjs",
        ".cjs",
        "/index.ts",
        "/index.tsx",
        "/index.js",
        "/index.mjs",
    ];
    let resolve = |from: &Path, spec: &str| -> Option<PathBuf> {
        let base = from.parent()?.join(spec);
        let stem = base.with_extension("");
        let js_to_ts = matches!(
            base.extension().and_then(|e| e.to_str()),
            Some("js" | "mjs" | "cjs")
        );
        TRIES
            .iter()
            .map(|t| PathBuf::from(format!("{}{t}", base.display())))
            .chain(js_to_ts.then(|| stem.with_extension("ts")))
            .find(|p| p.is_file())
    };
    let mut seen: std::collections::BTreeSet<PathBuf> = files.into_iter().collect();
    let mut todo: Vec<PathBuf> = seen.iter().cloned().collect();
    while let Some(file) = todo.pop() {
        let Ok(text) = std::fs::read_to_string(&file) else {
            continue;
        };
        for import in crate::ts::scan::scan(&file.to_string_lossy(), &text).imports {
            if !import.specifier.starts_with('.') || import.type_only {
                continue;
            }
            if let Some(found) = resolve(&file, &import.specifier)
                && found.starts_with(root)
                && !found.components().any(|c| c.as_os_str() == "node_modules")
                && seen.insert(found.clone())
            {
                todo.push(found);
            }
        }
    }
    seen.into_iter().collect()
}

/// Mojo files `bridge`, `refresh`, `shadow` and `--pin-clock` write next to `port.mojo`.
const GENERATED_MOJO: [&str; 8] = [
    "_native.mojo",
    "c_structs.mojo",
    "dispatcher.mojo",
    "exports.mojo",
    "exports_shadow.mojo",
    "json.mojo",
    "pinned.mojo",
    "py_num.mojo",
];

/// The Mojo files of a port: those in the unit's folder that no command generated, tests aside.
fn mojo_port_files(unit_dir: &Path) -> Vec<PathBuf> {
    let mut files: Vec<PathBuf> = std::fs::read_dir(unit_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.extension().is_some_and(|x| x == "mojo")
                && p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| !n.starts_with("test_") && !GENERATED_MOJO.contains(&n))
        })
        .collect();
    files.sort();
    files
}

fn size_check(crate_dir: &Path, manifest: &Manifest) -> Option<Check> {
    let source_comments: &[&str] = match manifest.language {
        crate::lang::Lang::Python | crate::lang::Lang::Ruby => &["#"],
        crate::lang::Lang::Php => &["//", "#", "/*", "*"],
        _ => &["//", "/*", "*"],
    };
    let mut files = files_under(
        &manifest.root.join(&manifest.unit),
        manifest.language.extensions(),
    );
    if manifest.language == crate::lang::Lang::Ts {
        files = with_local_imports(&manifest.root, files);
    }
    if manifest.language == crate::lang::Lang::C {
        let ported: Vec<&str> = manifest.exports.iter().map(|f| f.name.as_str()).collect();
        files.extend(crate::lang::c::called_implementations(
            &manifest.root,
            &manifest.unit,
            &ported,
        ));
    }
    let source: usize = files
        .iter()
        .filter_map(|p| std::fs::read_to_string(p).ok())
        .map(|t| code_lines(&t, source_comments))
        .sum();
    if source == 0 {
        return None;
    }
    let mojo = crate::bridge::mojo_unit(manifest.kind, manifest.language);
    let rust: usize = if mojo {
        mojo_port_files(crate_dir)
            .iter()
            .filter_map(|p| std::fs::read_to_string(p).ok())
            .map(|t| code_lines(&t, &["#"]))
            .sum()
    } else {
        files_under(&crate_dir.join("src"), &["rs"])
            .iter()
            .filter(|p| {
                p.file_name()
                    .is_none_or(|n| !GENERATED.contains(&n.to_string_lossy().as_ref()))
            })
            .filter_map(|p| std::fs::read_to_string(p).ok())
            .map(|t| code_lines(&t, &["//"]))
            .sum()
    };
    let port_language = if mojo { "Mojo" } else { "Rust" };
    let growth = rust as f64 / source as f64;
    let passed = rust as f64 <= MAX_GROWTH * source as f64 + ALLOWANCE;
    Some(Check {
        fix: None,
        name: "size",
        passed,
        detail: format!(
            "{rust} lines of {port_language} for {source} lines of {} ({growth:.1}x){}",
            manifest.language.name(),
            if passed {
                String::new()
            } else {
                format!(
                    "; over {MAX_GROWTH}x usually means code a crate already provides, or a case \
                     handled one by one: use the crates `analyze` lists and fold repeated code"
                )
            }
        ),
    })
}

#[derive(Debug, Serialize)]
pub struct GateOutcome {
    pub passed: bool,
    pub checks: Vec<Check>,
}

pub fn gate(crate_dir: &Path, node_args: &[String]) -> Result<GateOutcome> {
    let manifest = Manifest::load(crate_dir)?;
    if crate::jvm::is_jvm(manifest.language) {
        crate::jvm::require_java()?;
    }
    let mojo = crate::bridge::mojo_unit(manifest.kind, manifest.language);
    let mut checks = if mojo {
        let mut checks = mojo_checks(crate_dir);
        if manifest.kind == crate::bridge::Kind::CAbi {
            checks.push(c_pointers_check(crate_dir));
        }
        // The recorded error paths apply to any port; the panics check reads Rust only.
        checks.extend(
            crate::error_paths::checks(crate_dir, &manifest)
                .into_iter()
                .filter(|c| c.name != "panics"),
        );
        checks.extend(size_check(crate_dir, &manifest));
        checks
    } else {
        let lockfile = lockfile_check(crate_dir);
        let mut checks = rust_checks(crate_dir, &crate_dir.join("target"));
        checks.extend(lockfile);
        checks.extend(advisories_check(crate_dir));
        checks.push(ported_check(crate_dir));
        checks.extend(size_check(crate_dir, &manifest));
        checks.extend(crate::error_paths::checks(crate_dir, &manifest));
        checks
    };
    let built = harness::build(crate_dir);
    let built_ok = built.is_ok();
    let library = built.as_ref().ok().cloned();
    checks.push(Check {
        fix: None,
        name: "build",
        passed: built_ok,
        detail: match built {
            Ok(path) => format!("built {}", path.display()),
            Err(e) => last_lines(&format!("{e:#}"), 15),
        },
    });
    if manifest.kind == crate::bridge::Kind::CAbi
        && let Some(lib) = &library
    {
        checks.push(c_exports_check(lib, &manifest));
    }
    if manifest.kind == crate::bridge::Kind::MojoJvm {
        checks.push(java_api_check(crate_dir, &manifest));
    }

    if let Some(why) = crate::recording::stale(crate_dir, &manifest) {
        checks.push(Check {
            fix: None,
            name: "recording",
            passed: false,
            detail: why,
        });
    }

    if let Some(line) = crate::recording::saved_coverage(crate_dir)
        .and_then(|c| crate::recording::coverage_line(&c))
    {
        checks.push(Check {
            fix: None,
            name: "coverage",
            passed: true,
            detail: line,
        });
    }

    if !crate_dir.join(CASES).exists() {
        checks.push(Check {
            fix: None,
            name: "behavior",
            passed: false,
            detail: "no recorded cases: run `mojo-anything record` first".into(),
        });
    } else if built_ok {
        match harness::diff(&DiffOptions {
            crate_dir,
            module: None,
            ignore_key_order: false,
            float_tolerance: None,
            node_args,
        }) {
            Ok(d) => {
                checks.push(Check {
                    fix: None,
                    name: "api",
                    passed: d.missing.is_empty(),
                    detail: if d.missing.is_empty() {
                        format!(
                            "exports {}",
                            manifest
                                .exports
                                .iter()
                                .map(|f| f.name.clone())
                                .chain(manifest.classes.iter().map(|c| format!("class {}", c.name)))
                                .collect::<Vec<_>>()
                                .join(", ")
                        )
                    } else {
                        format!("missing exports: {}", d.missing.join(", "))
                    },
                });
                checks.push(Check {
                    fix: None,
                    name: "behavior",
                    passed: d.failed == 0,
                    detail: if d.accepted > 0 {
                        format!(
                            "{}/{} recorded cases match ({} by {})",
                            d.passed,
                            d.total,
                            d.accepted,
                            crate::recording::KNOWN_DIFFS
                        )
                    } else {
                        format!("{}/{} recorded cases match", d.passed, d.total)
                    },
                });
                if !d.stale_known.is_empty() {
                    checks.push(Check {
                        fix: None,
                        name: "known diffs",
                        passed: false,
                        detail: format!(
                            "{} entr{} of {} no longer differ{}: remove {}",
                            d.stale_known.len(),
                            if d.stale_known.len() == 1 { "y" } else { "ies" },
                            crate::recording::KNOWN_DIFFS,
                            if d.stale_known.len() == 1 { "s" } else { "" },
                            d.stale_known
                                .iter()
                                .map(|e| format!(
                                    "{}({})",
                                    e["fn"].as_str().unwrap_or("?"),
                                    e["args"]
                                ))
                                .collect::<Vec<_>>()
                                .join(", ")
                        ),
                    });
                }
            }
            Err(e) => checks.push(Check {
                fix: None,
                name: "behavior",
                passed: false,
                detail: format!("{e:#}"),
            }),
        }
    }

    for check in checks.iter_mut().filter(|c| !c.passed && c.fix.is_none()) {
        check.fix = fix_for(check, crate_dir);
    }
    Ok(GateOutcome {
        passed: checks.iter().all(|c| c.passed),
        checks,
    })
}

fn lockfile_check(crate_dir: &Path) -> Option<Check> {
    if !crate_dir.join("Cargo.lock").exists() {
        return Some(Check {
            fix: None,
            name: "lockfile",
            passed: true,
            detail: "warning: no Cargo.lock yet; keep the one the build writes, so builds are reproducible".into(),
        });
    }
    let mut cmd = Command::new("cargo");
    cmd.args([
        "metadata",
        "--locked",
        "--offline",
        "--format-version",
        "1",
        "--manifest-path",
    ])
    .arg(crate_dir.join("Cargo.toml"));
    let out = crate::process::output(&mut cmd, crate::process::BUILD).ok()?;
    let stderr = String::from_utf8_lossy(&out.stderr);
    let stale = !out.status.success() && stderr.contains("--locked");
    Some(Check {
        fix: None,
        name: "lockfile",
        passed: true,
        detail: if stale {
            "warning: Cargo.lock is out of date with Cargo.toml; keep the refreshed one the build wrote".into()
        } else {
            "Cargo.lock matches Cargo.toml".into()
        },
    })
}

fn advisories_check(crate_dir: &Path) -> Option<Check> {
    let manifest = crate_dir.join("Cargo.toml");
    let attempts: [(&str, Vec<std::ffi::OsString>); 2] = [
        (
            "cargo-deny",
            vec![
                "deny".into(),
                "--manifest-path".into(),
                manifest.clone().into(),
                "check".into(),
                "advisories".into(),
            ],
        ),
        (
            "cargo-audit",
            vec![
                "audit".into(),
                "--file".into(),
                crate_dir.join("Cargo.lock").into(),
            ],
        ),
    ];
    for (tool, args) in attempts {
        if !crate::setup::on_path(tool) {
            continue;
        }
        let mut cmd = Command::new("cargo");
        cmd.args(&args);
        let out = crate::process::output(&mut cmd, crate::process::BUILD).ok()?;
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        return Some(Check {
            fix: None,
            name: "advisories",
            passed: true,
            detail: if out.status.success() {
                format!("no known advisories ({tool})")
            } else {
                format!(
                    "warning: {tool} reports advisories\n{}",
                    last_lines(&text, 15)
                )
            },
        });
    }
    None
}

/// The checks that hold for any Rust crate, bindings or not: fmt, clippy (warnings are errors),
/// cargo test, and `unsafe` only with a `// SAFETY:` comment.
pub fn rust_checks(crate_dir: &Path, target_dir: &Path) -> Vec<Check> {
    let cargo = |args: &[&str]| -> (bool, String) {
        let mut cmd = Command::new("cargo");
        cmd.args(args)
            .arg("--manifest-path")
            .arg(crate_dir.join("Cargo.toml"))
            .env("CARGO_TARGET_DIR", target_dir);
        // Lint arguments go after `--`, so the manifest path must come before them.
        match crate::process::output(&mut cmd, crate::process::BUILD) {
            Ok(o) => (
                o.status.success(),
                last_lines(&String::from_utf8_lossy(&o.stderr), 15),
            ),
            Err(e) => (false, e.to_string()),
        }
    };
    let mut checks = Vec::new();

    let (ok, out) = cargo(&["fmt", "--check"]);
    checks.push(Check {
        fix: None,
        name: "fmt",
        passed: ok,
        detail: if ok {
            "formatted".into()
        } else {
            format!("run `cargo fmt`\n{out}")
        },
    });

    let mut clippy = Command::new("cargo");
    clippy
        .args(["clippy", "--all-targets", "--manifest-path"])
        .arg(crate_dir.join("Cargo.toml"))
        .args(["--", "-D", "warnings"])
        .env("CARGO_TARGET_DIR", target_dir);
    let (ok, out) = match crate::process::output(&mut clippy, crate::process::BUILD) {
        Ok(o) => (
            o.status.success(),
            last_lines(&String::from_utf8_lossy(&o.stderr), 15),
        ),
        Err(e) => (false, e.to_string()),
    };
    checks.push(Check {
        fix: None,
        name: "clippy",
        passed: ok,
        detail: if ok { "no warnings".into() } else { out },
    });

    let (ok, out) = cargo(&["test", "--quiet"]);
    checks.push(Check {
        fix: None,
        name: "cargo test",
        passed: ok,
        detail: if ok { "passed".into() } else { out },
    });

    let (unexplained, explained) = unsafe_blocks(&crate_dir.join("src"));
    checks.push(Check {
        fix: None,
        name: "unsafe",
        passed: unexplained.is_empty(),
        detail: if unexplained.is_empty() {
            format!("{explained} unsafe uses, each with a `// SAFETY:` comment")
        } else {
            format!(
                "unsafe without a `// SAFETY:` comment: {}",
                unexplained.join(", ")
            )
        },
    });

    checks
}

/// No function in `src/port.rs` is still `unimplemented!`.
pub fn ported_check(crate_dir: &Path) -> Check {
    let path = crate_dir.join("src/port.rs");
    let port = match std::fs::read_to_string(&path) {
        Ok(port) => port,
        Err(error) => {
            return Check {
                fix: None,
                name: "ported",
                passed: false,
                detail: format!("cannot read {}: {error}", path.display()),
            };
        }
    };
    let todo = stubs(&port);
    Check {
        fix: None,
        name: "ported",
        passed: todo == 0,
        detail: if todo == 0 {
            "nothing in port.rs is `unimplemented!`, `todo!` or only a `panic!`".into()
        } else {
            format!(
                "{todo} place(s) in port.rs still `unimplemented!`, `todo!` or a function that only panics"
            )
        },
    }
}

/// Stubs left in a port: `unimplemented!`, `todo!`, and functions whose whole body is a `panic!`.
fn stubs(port: &str) -> usize {
    let code: String = port
        .lines()
        .map(|l| l.split("//").next().unwrap_or_default())
        .collect::<Vec<_>>()
        .join("\n");
    let macros = code.matches("unimplemented!(").count() + code.matches("todo!(").count();
    let panics = regex::Regex::new(r"\bfn\s+\w+[^{;]*\{\s*panic!\([^;{}]*\)\s*;?\s*\}")
        .map(|re| re.find_iter(&code).count())
        .unwrap_or(0);
    macros + panics
}

/// `unsafe` uses in Rust sources, split into those without and with a `// SAFETY:` comment just above.
fn unsafe_blocks(src: &Path) -> (Vec<String>, usize) {
    let mut unexplained = Vec::new();
    let mut explained = 0;
    let mut stack = vec![src.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                stack.push(path);
                continue;
            }
            if path.extension().is_none_or(|e| e != "rs") {
                continue;
            }
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            let lines: Vec<&str> = text.lines().collect();
            for (i, line) in lines.iter().enumerate() {
                let code = line.split("//").next().unwrap_or("");
                let uses_unsafe = code
                    .split(|c: char| !(c.is_alphanumeric() || c == '_'))
                    .any(|word| word == "unsafe");
                if !uses_unsafe {
                    continue;
                }
                let has_safety = lines[..i]
                    .iter()
                    .rev()
                    .take_while(|l| l.trim_start().starts_with("//"))
                    .any(|l| l.contains("SAFETY:"));
                if has_safety {
                    explained += 1;
                } else {
                    unexplained.push(format!("{}:{}", path.display(), i + 1));
                }
            }
        }
    }
    (unexplained, explained)
}

// ---- Mojo ports ------------------------------------------------------------------------------

/// How many stubs `port.mojo` still has.
pub fn mojo_stubs(port: &str) -> usize {
    port.matches(crate::codegen_mojo::STUB_MARK).count()
}

/// Lines (1-based) of `port.mojo` that use `abort`, raw pointers or `external_call` without a
/// `# SAFETY:` comment on the line or the line above.
pub fn unexplained_unsafe(port: &str) -> Vec<usize> {
    const RISKY: &[&str] = &["abort(", "UnsafePointer", "external_call", "unsafe_"];
    let lines: Vec<&str> = port.lines().collect();
    lines
        .iter()
        .enumerate()
        .filter(|(_, l)| {
            let code = l.split('#').next().unwrap_or("");
            // A stub's `abort` is counted by the `ported` check instead.
            RISKY.iter().any(|r| code.contains(r)) && !code.contains(crate::codegen_mojo::STUB_MARK)
        })
        .filter(|(i, l)| {
            let here = l.contains("# SAFETY:");
            // The comment block right above may spread its reason over several lines.
            let above = lines[..*i]
                .iter()
                .rev()
                .map(|l| l.trim_start())
                .take_while(|l| l.starts_with('#'))
                .any(|l| l.starts_with("# SAFETY:"));
            !here && !above
        })
        .map(|(i, _)| i + 1)
        .collect()
}

/// Lines (1-based) of a C unit's `port.mojo` that name a pointer type: pointers belong in the
/// generated exports, which hand the port spans and optional values.
pub fn c_port_pointers(port: &str) -> Vec<usize> {
    port.lines()
        .enumerate()
        .filter(|(_, l)| l.split('#').next().unwrap_or("").contains("Pointer"))
        .map(|(i, _)| i + 1)
        .collect()
}

fn c_pointers_check(unit_dir: &Path) -> Check {
    let port = std::fs::read_to_string(unit_dir.join("port.mojo")).unwrap_or_default();
    let lines = c_port_pointers(&port);
    Check {
        name: "pointers",
        passed: lines.is_empty(),
        detail: if lines.is_empty() {
            "port.mojo uses no pointers".into()
        } else {
            format!(
                "port.mojo lines {} use pointers",
                lines
                    .iter()
                    .map(ToString::to_string)
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        },
        fix: (!lines.is_empty()).then(|| "move pointer handling to exports.mojo".into()),
    }
}

/// The names in `names` that `nm` output does not list as defined text symbols (`T`).
pub fn missing_exports(nm: &str, names: &[String]) -> Vec<String> {
    let defined: std::collections::BTreeSet<&str> = nm
        .lines()
        .filter_map(|l| {
            let mut parts = l.split_whitespace().rev();
            let name = parts.next()?;
            let kind = parts.next()?;
            (kind == "T").then(|| name.trim_start_matches('_'))
        })
        .collect();
    names
        .iter()
        .filter(|n| !defined.contains(n.as_str()))
        .cloned()
        .collect()
}

/// Every manifest function is exported from the built drop-in library under its C name.
fn c_exports_check(lib: &Path, manifest: &Manifest) -> Check {
    let mut cmd = std::process::Command::new("nm");
    if cfg!(target_os = "macos") {
        cmd.arg("-gU");
    } else {
        cmd.args(["-D", "--defined-only"]);
    }
    cmd.arg(lib);
    let names: Vec<String> = manifest.exports.iter().map(|f| f.name.clone()).collect();
    match crate::process::output(&mut cmd, crate::process::QUICK) {
        Ok(out) if out.success() => {
            let missing = missing_exports(&out.stdout_text(), &names);
            Check {
                name: "exports",
                passed: missing.is_empty(),
                detail: if missing.is_empty() {
                    format!("{} exports {}", lib.display(), names.join(", "))
                } else {
                    format!("{} does not export {}", lib.display(), missing.join(", "))
                },
                fix: (!missing.is_empty())
                    .then(|| "check the `@export` names in exports.mojo".into()),
            }
        }
        Ok(out) => Check {
            name: "exports",
            passed: false,
            detail: format!("nm failed: {}", out.stderr_text()),
            fix: None,
        },
        Err(e) => Check {
            name: "exports",
            passed: false,
            detail: format!("could not run nm: {e:#}"),
            fix: None,
        },
    }
}

/// A `mojo-jvm` unit's wrappers against the original classes: a wrapper replaces the whole
/// class, so every public member of the original (and of its public nested classes) must keep
/// its declaration and JVM descriptor, or callers compiled against the original break.
fn java_api_check(unit_dir: &Path, manifest: &Manifest) -> Check {
    match crate::harness_mojo_jvm::api_check(unit_dir, manifest) {
        Ok(api) if api.different.is_empty() && api.dropped.is_empty() => Check {
            name: "java api",
            passed: true,
            detail: format!(
                "the wrappers keep every public member of the original classes: {}",
                api.same.join(", ")
            ),
            fix: None,
        },
        Ok(api) => Check {
            name: "java api",
            passed: false,
            detail: api
                .different
                .iter()
                .chain(&api.dropped)
                .cloned()
                .collect::<Vec<_>>()
                .join("\n"),
            // A dropped member is not fixed by `refresh`: the wrapper never had it.
            fix: (!api.dropped.is_empty()).then(|| {
                format!(
                    "the wrappers in {}/java replace the whole class, so callers lose every member \
                     they do not have: port each dropped member to Mojo (bridged as an export of \
                     the unit) or move it out of the class into one the unit does not replace",
                    unit_dir.display()
                )
            }),
        },
        Err(e) => Check {
            name: "java api",
            passed: false,
            detail: last_lines(&format!("{e:#}"), 15),
            fix: None,
        },
    }
}

/// The checks for a Mojo port's own sources: format, tests, stubs and unexplained unsafe code.
/// The build (warnings are errors) and the replay are the shared checks in [`gate`].
pub fn mojo_checks(unit_dir: &Path) -> Vec<Check> {
    mojo_checks_in(unit_dir, unit_dir)
}

/// [`mojo_checks`] with Mojo from the pixi project in `env_dir` (a staged copy of a unit has no
/// environment of its own).
pub fn mojo_checks_in(unit_dir: &Path, env_dir: &Path) -> Vec<Check> {
    let port = std::fs::read_to_string(unit_dir.join("port.mojo")).unwrap_or_default();
    let mut checks = vec![
        mojo_format_check(unit_dir, env_dir, &port),
        mojo_test_check(unit_dir, env_dir),
    ];
    let stubs = mojo_stubs(&port);
    checks.push(Check {
        name: "ported",
        passed: stubs == 0,
        detail: if stubs == 0 {
            "every function in port.mojo is ported".into()
        } else {
            format!(
                "{stubs} function(s) in port.mojo still raise `{}`",
                crate::codegen_mojo::STUB_MARK
            )
        },
        fix: (stubs > 0).then(|| {
            "port the functions still stubbed in port.mojo, then `mojo-anything gate` again".into()
        }),
    });
    let unsafe_lines = unexplained_unsafe(&port);
    checks.push(Check {
        name: "unsafe",
        passed: unsafe_lines.is_empty(),
        detail: if unsafe_lines.is_empty() {
            "no unexplained abort, pointer or external_call".into()
        } else {
            format!(
                "port.mojo lines {} need a `# SAFETY:` comment saying why",
                unsafe_lines
                    .iter()
                    .map(|l| l.to_string())
                    .collect::<Vec<_>>()
                    .join(", ")
            )
        },
        fix: (!unsafe_lines.is_empty()).then(|| {
            "add a `# SAFETY:` comment above each listed line, or remove the unsafe code".into()
        }),
    });
    checks
}

/// `mojo format` has no check mode: format a copy and compare.
fn mojo_format_check(unit_dir: &Path, env_dir: &Path, port: &str) -> Check {
    let fix = Some(format!(
        "pixi run --manifest-path {}/pixi.toml mojo format port.mojo",
        unit_dir.display()
    ));
    let scratch = unit_dir.join(".mojo-anything/format");
    let copy = scratch.join("port.mojo");
    let result = std::fs::create_dir_all(&scratch)
        .and_then(|()| std::fs::write(&copy, port))
        .map_err(anyhow::Error::from)
        .and_then(|()| {
            let mut cmd = crate::mojo::command(env_dir)?;
            cmd.arg("format").arg("--quiet").arg(&copy);
            crate::process::output(&mut cmd, crate::process::QUICK)
        });
    match result {
        Ok(out) if out.success() => {
            let formatted = std::fs::read_to_string(&copy).unwrap_or_default();
            let passed = formatted == port;
            Check {
                name: "mojo format",
                passed,
                detail: if passed {
                    "port.mojo is formatted".into()
                } else {
                    "port.mojo is not formatted as `mojo format` writes it".into()
                },
                fix: (!passed).then_some(fix).flatten(),
            }
        }
        Ok(out) => Check {
            name: "mojo format",
            passed: false,
            detail: last_lines(&out.stderr_text(), 15),
            fix,
        },
        Err(e) => Check {
            name: "mojo format",
            passed: false,
            detail: format!("{e:#}"),
            fix: None,
        },
    }
}

/// Runs every `test_*.mojo` in the unit with `mojo run` (Mojo 1.2 has no `mojo test`).
fn mojo_test_check(unit_dir: &Path, env_dir: &Path) -> Check {
    let mut tests: Vec<PathBuf> = std::fs::read_dir(unit_dir)
        .into_iter()
        .flatten()
        .flatten()
        .map(|e| e.path())
        .filter(|p| {
            p.extension().is_some_and(|x| x == "mojo")
                && p.file_name()
                    .and_then(|n| n.to_str())
                    .is_some_and(|n| n.starts_with("test_"))
        })
        .collect();
    tests.sort();
    if tests.is_empty() {
        return Check {
            name: "mojo test",
            passed: true,
            detail: "no test_*.mojo files".into(),
            fix: None,
        };
    }
    for test in &tests {
        let result = crate::mojo::command(env_dir).and_then(|mut cmd| {
            cmd.current_dir(unit_dir).arg("run").arg(test);
            crate::process::output(&mut cmd, crate::process::TESTS)
        });
        let failed = match result {
            Ok(out) if out.success() => continue,
            Ok(out) => last_lines(&format!("{}{}", out.stdout_text(), out.stderr_text()), 15),
            Err(e) => format!("{e:#}"),
        };
        let name = test.file_name().unwrap_or_default().to_string_lossy();
        return Check {
            name: "mojo test",
            passed: false,
            detail: format!("{name} failed:\n{failed}"),
            fix: Some(format!("pixi run mojo run {name}, then fix the failure")),
        };
    }
    Check {
        name: "mojo test",
        passed: true,
        detail: format!("{} test file(s) pass", tests.len()),
        fix: None,
    }
}

fn last_lines(text: &str, n: usize) -> String {
    let lines: Vec<&str> = text.lines().filter(|l| !l.trim().is_empty()).collect();
    lines[lines.len().saturating_sub(n)..].join("\n")
}

#[cfg(test)]
mod tests {
    use super::{
        Check, c_port_pointers, fix_for, missing_exports, mojo_stubs, stubs, unexplained_unsafe,
        unsafe_blocks,
    };

    #[test]
    fn mojo_stub_count() {
        let stub = |n: &str| {
            format!(
                "def {n}() raises:
    raise Error(\"not ported: {n}\")
"
            )
        };
        assert_eq!(mojo_stubs(&(stub("a") + &stub("b"))), 2);
        assert_eq!(
            mojo_stubs(
                "def ok() -> Int:
    return 1
"
            ),
            0
        );
    }

    #[test]
    fn c_exports_check_lists_missing() {
        let nm =
            "0000000000001130 T av_add_q\n0000000000001150 T av_sub_q\n                 U abort\n";
        let names: Vec<String> = ["av_add_q", "av_mul_q", "av_sub_q"]
            .iter()
            .map(ToString::to_string)
            .collect();
        assert_eq!(missing_exports(nm, &names), ["av_mul_q"]);
        // macOS `nm -gU` prefixes an underscore.
        assert!(missing_exports("0000000000003f20 T _av_mul_q\n", &names[1..2]).is_empty());
    }

    #[test]
    fn c_port_without_pointers() {
        let port = "from std.os import abort\n\n\ndef f(p: Pointer[Int8, MutAnyOrigin]) -> Int32:\n    # a Pointer in a comment is fine\n    return 0\n";
        assert_eq!(c_port_pointers(port), [4]);
        assert!(c_port_pointers("def f(s: Span[UInt8, ImmutAnyOrigin]) -> Int32:\n").is_empty());
    }

    #[test]
    fn mojo_unsafe_needs_reason() {
        assert_eq!(
            unexplained_unsafe(
                "def f():
    abort()
"
            ),
            [2]
        );
        assert!(
            unexplained_unsafe(
                "def f():
    # SAFETY: unreachable, x checked above
    abort()
"
            )
            .is_empty()
        );
        assert!(
            unexplained_unsafe(
                "# abort() in a comment is fine
"
            )
            .is_empty()
        );
        // A reason may take several comment lines, as long as they sit right above.
        assert!(
            unexplained_unsafe(
                "def f():
    # SAFETY: the bytes come from a String,
    # cut only at ASCII.
    return String(unsafe_from_utf8=b)
"
            )
            .is_empty()
        );
        assert_eq!(
            unexplained_unsafe(
                "def f():
    # SAFETY: about something else
    var x = 1
    return String(unsafe_from_utf8=b)
"
            ),
            [4]
        );
    }

    #[test]
    fn counts_every_kind_of_stub() {
        let port = "pub fn a() -> u8 { todo!() }\n\
                    pub fn b() -> u8 { unimplemented!(\"later\") }\n\
                    pub fn c(x: u8) -> u8 {\n    panic!(\"not ported\")\n}\n\
                    pub fn d(x: u8) -> u8 { if x > 1 { panic!(\"big\") } x }\n\
                    // todo!() in a comment\n";
        assert_eq!(stubs(port), 3);
        assert_eq!(stubs("pub fn ok() -> u8 { 1 }"), 0);
    }

    #[test]
    fn generated_mojo_names_every_bridge_file() {
        for name in [
            format!("{}.mojo", crate::codegen_mojo_py::NATIVE),
            format!("{}.mojo", crate::codegen_mojo_c::C_STRUCTS),
            crate::harness_mojo_c::EXPORTS.to_string(),
            crate::harness_mojo_c::EXPORTS_SHADOW.to_string(),
        ] {
            assert!(super::GENERATED_MOJO.contains(&name.as_str()), "{name}");
        }
    }

    #[test]
    fn failed_checks_say_what_to_run() {
        let check = |name, detail: &str| Check {
            fix: None,
            name,
            passed: false,
            detail: detail.into(),
        };
        let dir = std::path::Path::new("port");
        assert_eq!(
            fix_for(&check("recording", "changed"), dir).as_deref(),
            Some("mojo-anything record port")
        );
        assert_eq!(
            fix_for(&check("behavior", "no recorded cases: run"), dir).as_deref(),
            Some("mojo-anything record port")
        );
        assert!(fix_for(&check("fmt", ""), dir).is_some_and(|f| f.starts_with("cargo fmt")));
        assert_eq!(fix_for(&check("coverage", ""), dir), None);
    }

    #[test]
    fn requires_safety_comments() {
        let dir = std::env::temp_dir().join(format!("mojo-anything-gate-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join("a.rs"),
            "#![forbid(unsafe_code)]\n// SAFETY: checked above\nunsafe { x() }\nlet y = unsafe { z() };\n// unsafe in a comment\n",
        )
        .unwrap();
        let (unexplained, explained) = unsafe_blocks(&dir);
        std::fs::remove_dir_all(&dir).unwrap();
        assert_eq!(explained, 1);
        assert_eq!(unexplained.len(), 1);
        assert!(unexplained[0].ends_with("a.rs:4"));
    }

    #[test]
    fn missing_port_source_fails_the_ported_check() {
        let dir = crate::app::temp_dir("gate-port").unwrap();
        let check = super::ported_check(&dir);
        std::fs::remove_dir(dir).unwrap();
        assert!(!check.passed);
        assert!(check.detail.contains("cannot read"));
        assert!(check.detail.contains("port.rs"));
    }
}
