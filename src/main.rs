use mojo_anything::walk::Canonical;
use std::io::Write as _;
use std::path::PathBuf;
use std::process::ExitCode;

/// `println!` that stops quietly when stdout is closed (`mojo-anything ... | head`).
macro_rules! say {
    ($($arg:tt)*) => {{
        let _ = writeln!(std::io::stdout().lock(), $($arg)*);
    }};
}

macro_rules! say_raw {
    ($($arg:tt)*) => {{
        let _ = write!(std::io::stdout().lock(), $($arg)*);
    }};
}

use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use mojo_anything::{analyze, app, bridge, front_door, gate, harness, lift, mcp, report, shadow};

#[derive(Parser)]
#[command(
    name = "mojo-anything",
    version,
    about = "Rewrite TypeScript/JavaScript, Python, C, Go, Ruby, Java or Kotlin apps in Mojo, one verified piece at a time",
    after_help = "Loop per unit: analyze -> bridge -> record -> port port.mojo -> build -> diff -> shadow -> gate"
)]
struct Cli {
    #[command(subcommand)]
    command: Cmd,
}

#[derive(Clone, Copy, ValueEnum)]
enum KindArg {
    /// A Mojo port behind a Node-API addon.
    Node,
    /// A Mojo port compiled to a WebAssembly module (wasm64), loaded by `index.cjs`.
    Wasm,
}

/// Where `record`, `build` and `diff` run. Only this machine: the Android profile went with
/// the Rust JNI crates.
#[derive(Clone, Copy, PartialEq, Eq, ValueEnum)]
enum Profile {
    /// This machine.
    Host,
}

#[derive(Subcommand)]
enum Cmd {
    /// 1. Map a repository and write a ranked, ordered migration plan.
    Analyze {
        /// Repository root.
        #[arg(default_value = ".")]
        root: PathBuf,
        /// Print the machine-readable report (schema `mojo-anything/analyze@1`) instead of Markdown.
        #[arg(long)]
        json: bool,
        /// Write to this file instead of stdout.
        #[arg(long, short)]
        out: Option<PathBuf>,
        /// Source language; detected from the repository when omitted.
        #[arg(long, value_enum)]
        lang: Option<mojo_anything::lang::Lang>,
        /// Plan a whole-app port: entry points and shape, every dependency (imported or
        /// declared) with its crate, pieces in port order, and decisions for the user.
        #[arg(long)]
        whole_app: bool,
    },
    /// 2. Scaffold the port of one unit, with the bindings its callers need.
    Bridge {
        /// Repository root.
        root: PathBuf,
        /// Unit id, as `analyze` lists it.
        unit: String,
        /// Bridge to generate; defaults to the plan's choice.
        #[arg(long, value_enum)]
        kind: Option<KindArg>,
        /// Port folder; defaults to `<root>/mojo/<name>`.
        #[arg(long, short)]
        out: Option<PathBuf>,
        /// Port name; defaults to `<unit>-mojo`.
        #[arg(long)]
        name: Option<String>,
        /// Bridge a unit the plan marks blocked or keep.
        #[arg(long)]
        force: bool,
        /// Keep an export in TS: `name` or `"name: reason"`. Repeatable.
        #[arg(long)]
        keep: Vec<String>,
        /// Add a batch class: `function:param` runs `function` over many `param` values kept on
        /// the native side (what `profile` recommends for leaves called in loops).
        #[arg(long)]
        batch: Vec<String>,
        /// Bridge a type parameter as JSON values (`--as-json T`) when the app only fills it
        /// with data, instead of keeping the generic export in TS. Repeatable.
        #[arg(long, value_name = "TYPE_PARAM")]
        as_json: Vec<String>,
    },
    /// 2b. Regenerate the bindings from the signatures in the port (`port.mojo`).
    Refresh {
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        /// Add a batch class: `function:param` runs `function` over many `param` values kept on
        /// the native side. Repeat for more.
        #[arg(long)]
        batch: Vec<String>,
    },
    /// 3a. Record what the TS functions return on generated and given inputs.
    Record {
        /// Crate folder made by `bridge`.
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        /// Generated cases per function.
        #[arg(long, default_value_t = 200)]
        count: usize,
        /// Extra cases: JSONL of `{"fn": name, "args": [...]}`.
        #[arg(long)]
        inputs: Option<PathBuf>,
        /// Import the original from this JS module (e.g. built output) instead of the TS source.
        #[arg(long)]
        module: Option<PathBuf>,
        /// Resolve npm packages from this folder's `node_modules` (when the repo has none installed).
        #[arg(long)]
        resolve_from: Option<PathBuf>,
        /// Extra arguments for node, e.g. `--node-arg=--import=tsx`.
        #[arg(long = "node-arg", allow_hyphen_values = true)]
        node_args: Vec<String>,
        /// Floats match when they differ by at most this times the larger magnitude (absolute
        /// below 1), e.g. 1e-9 for numeric code. Saved with the crate for diff and gate; 0 removes it.
        #[arg(long)]
        float_tolerance: Option<f64>,
        /// Also record every call the original's own test suite makes to the unit's functions:
        /// `--from-tests -- npx jest` (TS/JS, any runner) or `-- pytest` (Python).
        #[arg(long)]
        from_tests: bool,
        /// The test command for `--from-tests`, after `--`; it runs in the original's folder.
        #[arg(last = true)]
        test_command: Vec<String>,
        /// Target: this machine.
        #[arg(long, value_enum, default_value_t = Profile::Host)]
        profile: Profile,
        /// Pin the clock and random numbers while recording and diffing (TS/JS with the node
        /// bridge, Python): `Date.now()`, `new Date()` and `Math.random` (`time.time`,
        /// `datetime.now` and `random`) get fixed values, saved in `pinned.json`, and the port
        /// reads them from `pinned.mojo`. Kept for later
        /// runs until `--no-pin-clock`.
        #[arg(long, conflicts_with = "no_pin_clock")]
        pin_clock: bool,
        /// Stop pinning the clock and random numbers.
        #[arg(long)]
        no_pin_clock: bool,
    },
    /// 3b. Build the port (Node-API addon, Python extension, shared library).
    Build {
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        /// Target: this machine.
        #[arg(long, value_enum, default_value_t = Profile::Host)]
        profile: Profile,
    },
    /// 3c. Replay recorded cases against the built Mojo port.
    Diff {
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        /// Target: this machine.
        #[arg(long, value_enum, default_value_t = Profile::Host)]
        profile: Profile,
        /// Test this JS module instead of the crate's `index.cjs`.
        #[arg(long)]
        module: Option<PathBuf>,
        /// Compare objects regardless of key order.
        #[arg(long)]
        ignore_key_order: bool,
        /// Floats match within this tolerance for this run (the one saved by `record` otherwise).
        #[arg(long)]
        float_tolerance: Option<f64>,
        #[arg(long)]
        json: bool,
        #[arg(long = "node-arg", allow_hyphen_values = true)]
        node_args: Vec<String>,
    },
    /// 3d. Time the recorded cases on the original and on the Mojo port, bridge included.
    Bench {
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        /// Minimum measured time per function and side, in milliseconds.
        #[arg(long, default_value_t = 200)]
        min_ms: u64,
        /// Resolve npm packages the original imports from this folder's `node_modules`.
        #[arg(long)]
        resolve_from: Option<PathBuf>,
        #[arg(long)]
        json: bool,
        #[arg(long = "node-arg", allow_hyphen_values = true)]
        node_args: Vec<String>,
    },
    /// 3e. Run fresh inputs from a new seed through the original and the port and report where
    /// they differ: what the recorded cases did not cover.
    Fuzz {
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        /// Fresh cases per function (and scenarios per class) in each round.
        #[arg(long, default_value_t = 200)]
        cases: usize,
        /// Seed of the first round; random (and printed) when omitted. Later rounds count up.
        #[arg(long)]
        seed: Option<u64>,
        /// Keep running new rounds until this many seconds have passed (one round otherwise).
        #[arg(long, value_name = "SECS")]
        time: Option<f64>,
        /// Append the mismatching cases (`--keep`) or every fresh case (`--keep=all`) to
        /// `cases.jsonl`, so the next diff and gate check them.
        #[arg(long, value_enum, num_args = 0..=1, require_equals = true, default_missing_value = "mismatches")]
        keep: Option<mojo_anything::fuzz::Keep>,
        /// Resolve npm packages the original imports from this folder's `node_modules`.
        #[arg(long)]
        resolve_from: Option<PathBuf>,
        #[arg(long)]
        json: bool,
        #[arg(long = "node-arg", allow_hyphen_values = true)]
        node_args: Vec<String>,
    },
    /// Run a real workload under the language's profiler and say what to port: hot functions,
    /// their callers, and loops to batch. `mojo-anything profile <repo> -- node bench.mjs` (also
    /// `python3 x.py`, `go test -bench . ./pkg`, `java ...`, `ruby x.rb`)
    Profile {
        /// Repository root.
        root: PathBuf,
        #[arg(long)]
        json: bool,
        /// Source language; detected from the repository when omitted.
        #[arg(long, value_enum)]
        lang: Option<mojo_anything::lang::Lang>,
        /// The workload, after `--`.
        #[arg(last = true, required = true)]
        command: Vec<String>,
    },
    /// 4. Generate a drop-in module that runs the original and the Mojo port side by side.
    Shadow {
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        /// Where to write the module; defaults to `<crate>/shadow/<name>.shadow.ts`.
        #[arg(long, short)]
        out: Option<PathBuf>,
    },
    /// 5. Check the definition of done for a port.
    Gate {
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        #[arg(long)]
        json: bool,
        #[arg(long = "node-arg", allow_hyphen_values = true)]
        node_args: Vec<String>,
    },
    /// 6. Lay out installable packages and a CI workflow for every platform; never publishes.
    Package {
        #[arg(default_value = ".", value_parser = absolute)]
        crate_dir: PathBuf,
        /// Package name on npm or PyPI; defaults to the crate name.
        #[arg(long)]
        name: Option<String>,
        /// Package version; defaults to the original package's.
        #[arg(long)]
        version: Option<String>,
        /// Output folder; defaults to `<crate>/package`.
        #[arg(long, value_parser = absolute)]
        out: Option<PathBuf>,
        /// List the files, write nothing.
        #[arg(long)]
        dry_run: bool,
        #[arg(long)]
        json: bool,
    },
    /// Record the whole app's behavior and replay any build against it (CLIs).
    App {
        #[command(subcommand)]
        command: AppCmd,
    },
    /// Serve every step as MCP tools over stdio.
    Mcp,
    /// Register mojo-anything with your coding agents (Claude Code, Codex, Cursor, Gemini CLI,
    /// OpenCode): the MCP server and, where the agent reads skills, the workflow skill. Keeps your
    /// other settings; run it again any time.
    Setup {
        /// Agents to set up (repeatable); every agent found by default.
        #[arg(long = "agent", value_enum)]
        agents: Vec<mojo_anything::setup::Agent>,
        /// Take the mojo-anything entries out again.
        #[arg(long)]
        remove: bool,
        /// Show what would change, write nothing.
        #[arg(long)]
        dry_run: bool,
        /// Change settings files in place without saving a `.mojo-anything.bak` copy first.
        #[arg(long)]
        no_backup: bool,
        #[arg(long)]
        json: bool,
    },
    /// Map the port: every unit of the original, the crate that ports it, its cases and last
    /// diff, the whole app's glue, and which recordings the original changed past since they
    /// were made. Commit the map (`--write`) to see upstream changes in it.
    Map {
        /// Repository root.
        #[arg(default_value = ".")]
        repo: PathBuf,
        /// Also look for crates in this folder (crates kept outside the repository).
        #[arg(long = "crates")]
        crates: Vec<PathBuf>,
        /// Write the map to mojo/PORT_MAP.md in the repository instead of printing it.
        #[arg(long)]
        write: bool,
        /// Exit 1 when the original changed since any port was recorded.
        #[arg(long)]
        check: bool,
        #[arg(long)]
        json: bool,
    },
    /// Check pixi and the pinned Mojo, the language runtimes, the agent setup and the MCP
    /// server, with the command that fixes each problem. Exits 1 when something required is
    /// missing.
    Doctor {
        #[arg(long)]
        json: bool,
    },
}

#[derive(Subcommand)]
#[allow(clippy::large_enum_variant)]
enum AppCmd {
    /// Run the original CLI on cases (its own examples, `--inputs`, semantic traps), twice
    /// each, and store them as trycmd files in `<repo>/mojo/app-cases/`.
    /// `mojo-anything app record . -- python3 cli.py`
    Record {
        /// Repository root.
        #[arg(default_value = ".")]
        repo: PathBuf,
        /// Extra cases: JSONL of `{"name", "args": [...], "stdin", "env": {...}, "files": {path: text}}`.
        #[arg(long)]
        inputs: Option<PathBuf>,
        /// Normalizer: `timestamps`, `uuids`, `key-order`, or `name=regex` for your own. Repeatable;
        /// saved with the cases.
        #[arg(long)]
        normalize: Vec<String>,
        /// The name the app is invoked by in its docs (found from the command and manifests when omitted).
        #[arg(long)]
        name: Option<String>,
        /// Leave out the semantic-trap inputs.
        #[arg(long)]
        no_traps: bool,
        /// Seconds before a run is killed (default 30).
        #[arg(long)]
        timeout: Option<u64>,
        /// The app is a server: the command starts it, taking its port from PORT or `{port}`;
        /// cases are requests (curl lines in its docs, `--inputs`, traps), kept in `http/`.
        #[arg(long)]
        http: bool,
        /// A port the server always listens on (implies --http).
        #[arg(long)]
        port: Option<u16>,
        /// An argument every server start gets after its command, the original's and every
        /// build's (`{port}` is the port each one is given: the front door's public port, and
        /// its original's own), so a build is started as the original is (`--arg db.json`).
        /// Repeatable; implies --http; saved with the cases.
        #[arg(long = "arg", value_name = "ARG", allow_hyphen_values = true)]
        server_args: Vec<String>,
        /// A file or folder of the repository the app reads or writes (a project tree, a
        /// database file, a public folder): snapshotted into `files/` (`http/files/` for a
        /// server) and copied into a fresh working directory before every case (CLIs) or start
        /// (servers). A CLI's written files are what differs from it afterwards, and the files
        /// it removed are compared too. Repeatable; saved with the cases.
        #[arg(long)]
        fresh: Vec<String>,
        /// Milliseconds to wait after each response before the next request, for work a server
        /// does after answering (a file watcher reloading what it just wrote). Implies --http;
        /// saved with the cases and used by replay; 0 removes it.
        #[arg(long, value_name = "MS")]
        pace: Option<u64>,
        /// Numbers in the output match when they differ by at most this times the larger
        /// magnitude (absolute below 1), e.g. 1e-9 for numeric code. Saved with the cases; 0
        /// removes it.
        #[arg(long)]
        float_tolerance: Option<f64>,
        /// A written file of raw floats, compared value by value within --float-tolerance
        /// instead of byte for byte: `PATH=f32le` or `PATH=f64le`. Repeatable; saved with the
        /// cases.
        #[arg(long = "float-file", value_name = "PATH=FORMAT")]
        float_files: Vec<String>,
        /// Record what leaves the process too: `http` runs a local sink that answers every
        /// request (set as HTTP_PROXY, http_proxy and MOJO_ANYTHING_HTTP_SINK), `smtp` a local
        /// mail server (SMTP_HOST, SMTP_PORT). Each case stores what reached them, in order,
        /// and replay compares it. Comma-separated or repeated. Saved with the cases.
        #[arg(long, value_name = "KINDS")]
        effects: Vec<String>,
        /// Point one of the app's own settings at a sink: VAR=http-url, VAR=smtp-host,
        /// VAR=smtp-port or VAR=smtp-url (e.g. WEBHOOK_URL=http-url). Implies that effect.
        #[arg(long, value_name = "VAR=KIND")]
        effect_env: Vec<String>,
        /// A shell command run before each case (CLIs) or each start (servers) that resets the
        /// database to a known state. Cases then run one at a time.
        #[arg(long, value_name = "COMMAND")]
        db_reset: Option<String>,
        /// A shell command that prints the database's state (e.g. `sqlite3 app.db .dump`), run
        /// after each case or request; its output is recorded with the effects.
        #[arg(long, value_name = "COMMAND")]
        db_dump: Option<String>,
        #[arg(long)]
        json: bool,
        /// The command that runs the original, after `--`; paths are relative to the repository.
        /// Taken from the saved cases when omitted.
        #[arg(last = true)]
        run: Vec<String>,
    },
    /// Run a build against `<repo>/mojo/app-cases/`, print passed/total, write a report with a
    /// diff per failing case; exits non-zero on any mismatch.
    Replay {
        /// Repository root.
        #[arg(default_value = ".")]
        repo: PathBuf,
        /// Command line of the build to test (the original, the front door, the final binary);
        /// the original when omitted.
        #[arg(long)]
        build: Option<String>,
        /// Seconds before a run is killed.
        #[arg(long)]
        timeout: Option<u64>,
        /// Servers: the port the build always listens on; otherwise it gets a free one through
        /// PORT and `{port}`.
        #[arg(long)]
        port: Option<u16>,
        /// Replay only this case, by the name the report gives it (a library: only this unit).
        /// The fast, repeatable loop for fixing one mismatch.
        #[arg(long)]
        case: Option<String>,
        #[arg(long)]
        json: bool,
    },
    /// Scaffold `<repo>/mojo/app`, the Mojo binary that owns the CLI's entry point: it routes the
    /// recorded commands and options, every command running the original until a unit is wired.
    /// Builds it and replays the cases (100% passed, 100% fallback).
    FrontDoor {
        /// Repository root.
        #[arg(default_value = ".")]
        repo: PathBuf,
        /// Only write the files; skip the build and replay.
        #[arg(long)]
        no_check: bool,
        /// Treat the repository as a library even if it has a `main`: the front door is a Mojo
        /// package with the public API (found by default when there is no main and no server).
        #[arg(long)]
        library: bool,
        #[arg(long)]
        json: bool,
    },
    /// Hand commands to a unit's port (after it passes gate): adds the unit to `mojo/app`, a
    /// glue file to write once (a CLI), the routing and a kill switch
    /// (`MOJO_ANYTHING_UNIT_<NAME>=original`), then builds and replays. A CLI or a library takes
    /// a Mojo unit (`mojo/<name>` with `port.mojo`); a server takes one for each route.
    Wire {
        /// Repository root.
        repo: PathBuf,
        /// The unit: its folder, its name under `mojo/`, or the unit id it was bridged from.
        unit: String,
        /// A command the unit answers. Repeatable; kept from the last wire when omitted.
        #[arg(long = "command")]
        commands: Vec<String>,
        /// Servers: a route the unit answers (`GET /users/{id}`, `/files/{*rest}`, `/path` for
        /// any method, `*` for everything else). Repeatable; kept from the last wire when omitted.
        #[arg(long = "route")]
        routes: Vec<String>,
        /// Do not run gate on the unit first (it just passed).
        #[arg(long)]
        skip_gate: bool,
        /// Only write the files; skip the build and replay.
        #[arg(long)]
        no_check: bool,
        #[arg(long)]
        json: bool,
    },
    /// Make `mojo/app` a pure app (a Mojo binary for a CLI), once replay passes with fallback
    /// rate 0 and every unit passes gate: removes the fallback and the kill switches, strips the
    /// units' bridges, runs the lift checklist and replays the pure binary. Checked on a copy
    /// first; the original stays in place.
    Lift {
        /// Repository root.
        #[arg(default_value = ".")]
        repo: PathBuf,
        #[arg(long)]
        json: bool,
    },
}

fn say_replay(replay: &app::ReplayOutcome) {
    say!("{}/{} cases passed", replay.passed, replay.total);
    if let Some(f) = &replay.fallback {
        say!(
            "Fallback rate: {:.1}% ({}/{})",
            f.rate * 100.0,
            f.cases,
            f.total
        );
    }
    for f in replay.failures.iter().take(20) {
        let fields: Vec<&str> = f.problems.iter().map(|p| p.field.as_str()).collect();
        say!("- {}: {}", f.case, fields.join(", "));
    }
    if replay.failures.len() > 20 {
        say!("- ... and {} more", replay.failures.len() - 20);
    }
    say!("Report: {}", replay.report.display());
}

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(e) => {
            eprintln!("error: {e:#}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<ExitCode> {
    match Cli::parse().command {
        Cmd::Analyze {
            root,
            json,
            out,
            lang,
            whole_app,
        } => {
            let lang = lang.unwrap_or_else(|| mojo_anything::lang::Lang::detect(&root));
            let mut report = analyze::analyze_lang(&root, lang)
                .with_context(|| format!("analyzing {}", root.display()))?;
            if whole_app {
                report.whole_app = Some(mojo_anything::whole_app::whole_app(&root, &report));
            }
            let text = if json {
                serde_json::to_string_pretty(&report)? + "\n"
            } else {
                let title = root
                    .canonical()
                    .ok()
                    .and_then(|p| p.file_name().map(|n| n.to_string_lossy().into_owned()))
                    .unwrap_or_else(|| root.display().to_string());
                report::markdown(&report, &title)
            };
            match out {
                Some(path) => std::fs::write(&path, text)
                    .with_context(|| format!("writing {}", path.display()))?,
                None => say_raw!("{text}"),
            }
        }
        Cmd::Bridge {
            root,
            unit,
            kind,
            out,
            name,
            force,
            keep,
            batch,
            as_json,
        } => {
            let outcome = bridge::bridge(&bridge::Options {
                root: &root,
                unit: &unit,
                kind: kind.map(|k| match k {
                    KindArg::Node => bridge::Kind::MojoNode,
                    KindArg::Wasm => bridge::Kind::MojoWasm,
                }),
                out,
                name,
                force,
                keep,
                lang: None,
                batch,
                as_json,
            })?;
            say!(
                "Created {} ({:?}) for {}",
                outcome.crate_dir.display(),
                outcome.kind,
                outcome.exports.join(", ")
            );
            for file in &outcome.files {
                say!("  {file}");
            }
            for note in &outcome.notes {
                say!("- {note}");
            }
        }
        Cmd::Record {
            crate_dir,
            count,
            inputs,
            module,
            resolve_from,
            node_args,
            float_tolerance,
            from_tests,
            test_command,
            profile,
            pin_clock,
            no_pin_clock,
        } => {
            anyhow::ensure!(
                from_tests || test_command.is_empty(),
                "a command after `--` is the test suite for `--from-tests`; add the flag"
            );
            let inputs = if from_tests {
                let c = mojo_anything::from_tests::capture(&crate_dir, &test_command)?;
                say!(
                    "Captured {} call(s) from the tests{}:",
                    c.per_function.values().sum::<usize>(),
                    if c.tests_passed {
                        ""
                    } else {
                        " (the test command failed; calls made before that are kept)"
                    }
                );
                for (name, n) in &c.per_function {
                    say!("  {name}: {n}");
                }
                for s in &c.skipped {
                    say!("  not captured: {s}");
                }
                Some(mojo_anything::from_tests::with_own_inputs(
                    &crate_dir,
                    inputs.as_deref(),
                    &c.inputs,
                )?)
            } else {
                inputs
            };
            if let Some(t) = float_tolerance {
                let mut manifest = bridge::Manifest::load(&crate_dir)?;
                manifest.float_tolerance = (mojo_anything::tolerance::check(t)? > 0.0).then_some(t);
                manifest.save(&crate_dir)?;
            }
            if (pin_clock || no_pin_clock)
                && let Some(helper) = mojo_anything::pin::set(&crate_dir, pin_clock)?
            {
                say!(
                    "Wrote {}: import it in port.mojo (`from pinned import now_ms, random`) and call \
                     `now_ms()` and `random()` where the original reads the clock or draws a number",
                    helper.display()
                );
            }
            let opts = harness::RecordOptions {
                crate_dir: &crate_dir,
                count,
                inputs: inputs.as_deref(),
                module: module.as_deref(),
                resolve_from: resolve_from.as_deref(),
                node_args: &node_args,
            };
            let outcome = match profile {
                Profile::Host => harness::record(&opts)?,
            };
            say!(
                "Recorded {} cases ({} threw) in {}",
                outcome.cases,
                outcome.errors,
                outcome.path.display()
            );
            for (name, n) in &outcome.per_function {
                say!("  {name}: {n}");
            }
            if let Some(pin) = &outcome.pinned {
                say!(
                    "Clock pinned at {} ms (UTC), random numbers from seed {} ({})",
                    pin.now_ms,
                    pin.seed,
                    mojo_anything::pin::FILE
                );
            }
            if !outcome.regex_functions.is_empty() {
                say!(
                    "Regex traps (non-ASCII \\w, \\b and case folding) added for: {}",
                    outcome.regex_functions.join(", ")
                );
            }
            if !outcome.timed_out.is_empty() {
                say!(
                    "Left out {} input(s) the original ran too long on (over the per-case limit, \
                     MOJO_ANYTHING_CASE_TIMEOUT seconds, 10 by default). The original does this \
                     itself, so the port need not match it there:",
                    outcome.timed_out.len()
                );
                for c in &outcome.timed_out {
                    say!("  {}({})", c["fn"].as_str().unwrap_or("?"), c["args"]);
                }
            }
            if let Some(line) = outcome
                .coverage
                .as_ref()
                .and_then(mojo_anything::recording::coverage_line)
            {
                say!("Coverage: {line}");
            }
        }
        Cmd::Refresh { crate_dir, batch } => {
            let r = if batch.is_empty() {
                bridge::refresh(&crate_dir)?
            } else {
                bridge::add_batches(&crate_dir, &batch)?
            };
            say!(
                "Regenerated {} for {}",
                r.files.join(", "),
                r.functions.join(", ")
            );
        }
        Cmd::Build { crate_dir, profile } => match profile {
            Profile::Host => say!("Built {}", harness::build(&crate_dir)?.display()),
        },
        Cmd::Diff {
            crate_dir,
            profile,
            module,
            ignore_key_order,
            float_tolerance,
            json,
            node_args,
        } => {
            let opts = harness::DiffOptions {
                crate_dir: &crate_dir,
                module: module.as_deref(),
                ignore_key_order,
                node_args: &node_args,
                float_tolerance,
            };
            let d = match profile {
                Profile::Host => harness::diff(&opts)?,
            };
            let stale = mojo_anything::bridge::Manifest::load(&crate_dir)
                .ok()
                .and_then(|m| mojo_anything::recording::stale(&crate_dir, &m));
            if json {
                say!("{}", serde_json::to_string_pretty(&d)?);
            } else {
                if let Some(why) = &stale {
                    say!("Stale recording: {why}");
                }
                if d.accepted > 0 {
                    say!(
                        "{}/{} cases match ({} by {})",
                        d.passed,
                        d.total,
                        d.accepted,
                        mojo_anything::recording::KNOWN_DIFFS
                    );
                } else {
                    say!("{}/{} cases match", d.passed, d.total);
                }
                if let Some(t) = d.trend.as_ref().filter(|t| t.stalled) {
                    let shown: Vec<String> = t.passed.iter().map(ToString::to_string).collect();
                    say!(
                        "Stalled: the last {} changes to the port gained no matching case ({} of {}). \
                         Stop and look at the remaining mismatches with a person, or keep these \
                         functions in the original for now.",
                        mojo_anything::recording::STALL_AFTER,
                        shown.join(", "),
                        t.total
                    );
                }
                for e in &d.stale_known {
                    say!(
                        "Known diff no longer happens, remove it from {}: {}({})",
                        mojo_anything::recording::KNOWN_DIFFS,
                        e["fn"].as_str().unwrap_or_default(),
                        e["args"]
                    );
                }
                if !d.missing.is_empty() {
                    say!("Missing exports: {}", d.missing.join(", "));
                }
                for m in &d.mismatches {
                    say!(
                        "- {}({}): expected {}, got {}",
                        m["fn"].as_str().unwrap_or_default(),
                        m["args"]
                            .as_array()
                            .map(|a| a
                                .iter()
                                .map(ToString::to_string)
                                .collect::<Vec<_>>()
                                .join(", "))
                            .unwrap_or_default(),
                        m["expected"],
                        m["actual"]
                    );
                }
            }
            if d.failed > 0 || stale.is_some() {
                return Ok(ExitCode::FAILURE);
            }
        }
        Cmd::Fuzz {
            crate_dir,
            cases,
            seed,
            time,
            keep,
            resolve_from,
            json,
            node_args,
        } => {
            let time = time
                .map(|t| {
                    anyhow::ensure!(t.is_finite() && t >= 0.0, "`--time` takes seconds");
                    Ok(std::time::Duration::from_secs_f64(t))
                })
                .transpose()?;
            let f = mojo_anything::fuzz::fuzz(&mojo_anything::fuzz::FuzzOptions {
                crate_dir: &crate_dir,
                cases,
                seed,
                time,
                keep,
                resolve_from: resolve_from.as_deref(),
                node_args: &node_args,
            })?;
            if json {
                say!("{}", serde_json::to_string_pretty(&f)?);
            } else {
                say!("Seed {} (replay with --seed {})", f.seed, f.seed);
                say!(
                    "{}/{} fresh cases match ({} round{})",
                    f.passed,
                    f.cases,
                    f.rounds,
                    if f.rounds == 1 { "" } else { "s" }
                );
                if !f.missing.is_empty() {
                    say!("Missing exports: {}", f.missing.join(", "));
                }
                for m in &f.mismatches {
                    say!(
                        "- {}({}): expected {}, got {}",
                        m["fn"].as_str().unwrap_or_default(),
                        m["args"]
                            .as_array()
                            .map(|a| a
                                .iter()
                                .map(ToString::to_string)
                                .collect::<Vec<_>>()
                                .join(", "))
                            .unwrap_or_default(),
                        m["expected"],
                        m["actual"]
                    );
                }
                if f.kept > 0 {
                    say!(
                        "Kept {} case(s) in {}: the next diff and gate check them",
                        f.kept,
                        f.recording.display()
                    );
                }
            }
            if f.failed > 0 {
                return Ok(ExitCode::FAILURE);
            }
        }
        Cmd::Bench {
            crate_dir,
            min_ms,
            resolve_from,
            json,
            node_args,
        } => {
            let rows = harness::bench(&harness::BenchOptions {
                crate_dir: &crate_dir,
                min_ms,
                resolve_from: resolve_from.as_deref(),
                node_args: &node_args,
            })?;
            if json {
                say!("{}", serde_json::to_string_pretty(&rows)?);
            } else {
                say!(
                    "{:<24} {:>6} {:>12} {:>12} {:>9}",
                    "function",
                    "cases",
                    "orig ns/call",
                    "port ns/call",
                    "speedup"
                );
                for r in &rows {
                    say!(
                        "{:<24} {:>6} {:>12.0} {:>12.0} {:>8.2}x",
                        r.name,
                        r.cases,
                        r.original_ns,
                        r.rust_ns,
                        r.speedup
                    );
                }
                let lang = bridge::Manifest::load(&crate_dir)
                    .map(|m| m.language)
                    .unwrap_or_default();
                let v = harness::verdict(&rows, lang);
                say!(
                    "\nTimed as callers call it, crossing included. Overall {:.2}x (geometric mean); {} of {} functions at least 1.1x faster.",
                    v.speedup,
                    v.faster.len(),
                    rows.len()
                );
                say!("{}", v.advice);
            }
        }
        Cmd::Profile {
            root,
            json,
            lang,
            command,
        } => {
            let report = mojo_anything::profile::profile(&root, &command, lang)?;
            if json {
                say!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                say!("{}", mojo_anything::profile::markdown(&report));
            }
        }
        Cmd::Shadow { crate_dir, out } => {
            let outcome = shadow::shadow(&crate_dir, out.as_deref())?;
            say!(
                "Wrote {} ({})",
                outcome.path.display(),
                outcome.exports.join(", ")
            );
            if outcome.path.extension().is_some_and(|e| e == "java") {
                say!(
                    "Call the <Class>Shadow classes in place of the originals; compile them with the originals and java/mojo-anything. -Dmojo-anything.mode=old|shadow|new switches at runtime."
                );
            } else if outcome.path.extension().is_some_and(|e| e == "rb") {
                say!(
                    "Require it after the original files. MOJO_ANYTHING_MODE=old|shadow|new switches at runtime."
                );
            } else if outcome.path.extension().is_some_and(|e| e == "go") {
                say!(
                    "Import it in place of the original package (require and replace both modules in go.mod). MOJO_ANYTHING_MODE=old|shadow|new switches at runtime."
                );
            } else if outcome.path.extension().is_some_and(|e| e == "c") {
                say!(
                    "Compile the original with the -D flags in shadow/flags.txt, build the crate with --features shadow, and link all three."
                );
            } else {
                say!(
                    "Import it in place of the original. MOJO_ANYTHING_MODE=old|shadow|new switches at runtime."
                );
            }
        }
        Cmd::Package {
            crate_dir,
            name,
            version,
            out,
            dry_run,
            json,
        } => {
            let outcome = mojo_anything::package::package(&mojo_anything::package::Options {
                crate_dir: &crate_dir,
                name,
                version,
                out,
                dry_run,
            })?;
            if json {
                say!("{}", serde_json::to_string_pretty(&outcome)?);
            } else {
                say!(
                    "{} {} {}@{} in {}:",
                    if outcome.dry_run {
                        "Would write"
                    } else {
                        "Wrote"
                    },
                    outcome.files.len(),
                    outcome.name,
                    outcome.version,
                    outcome.out.display()
                );
                for file in &outcome.files {
                    say!("  {file}");
                }
                for note in &outcome.notes {
                    say!("{note}");
                }
            }
        }
        Cmd::Gate {
            crate_dir,
            json,
            node_args,
        } => {
            let outcome = gate::gate(&crate_dir, &node_args)?;
            if json {
                say!("{}", serde_json::to_string_pretty(&outcome)?);
            } else {
                for check in &outcome.checks {
                    let mark = if check.passed { "pass" } else { "FAIL" };
                    let first = check.detail.lines().next().unwrap_or_default();
                    say!("{mark}  {:<10} {first}", check.name);
                    if !check.passed {
                        for line in check.detail.lines().skip(1) {
                            say!("            {line}");
                        }
                        if let Some(fix) = &check.fix {
                            say!("            fix: {fix}");
                        }
                    }
                }
                say!(
                    "{}",
                    if outcome.passed {
                        "Gate passed."
                    } else {
                        "Gate failed."
                    }
                );
            }
            if !outcome.passed {
                return Ok(ExitCode::FAILURE);
            }
        }
        Cmd::App { command } => return run_app(command),
        Cmd::Mcp => mcp::serve()?,
        Cmd::Setup {
            agents,
            remove,
            dry_run,
            no_backup,
            json,
        } => {
            let home = mojo_anything::setup::home()?;
            let command = std::env::current_exe()
                .and_then(|p| p.canonical())
                .context("finding the mojo-anything executable")?;
            let report = mojo_anything::setup::setup(&mojo_anything::setup::Options {
                home: &home,
                agents,
                command,
                remove,
                dry_run,
                backup: !no_backup,
            })?;
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print!("{}", mojo_anything::setup::text(&report));
            }
        }
        Cmd::Map {
            repo,
            crates,
            write,
            check,
            json,
        } => {
            let map = mojo_anything::port_map::map(&repo, &crates)?;
            if json {
                say!("{}", serde_json::to_string_pretty(&map)?);
            } else if write {
                let path = map.root.join(mojo_anything::port_map::MAP_FILE);
                if let Some(dir) = path.parent() {
                    std::fs::create_dir_all(dir)?;
                }
                std::fs::write(&path, mojo_anything::port_map::markdown(&map))?;
                say!("Wrote {}", path.display());
            } else {
                say_raw!("{}", mojo_anything::port_map::markdown(&map));
            }
            if check && map.changed() > 0 {
                return Ok(ExitCode::FAILURE);
            }
        }
        Cmd::Doctor { json } => {
            let report = mojo_anything::doctor::run();
            if json {
                say!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                say_raw!("{}", mojo_anything::doctor::text(&report));
            }
            if !report.ok() {
                return Ok(ExitCode::FAILURE);
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

fn run_app(command: AppCmd) -> Result<ExitCode> {
    match command {
        AppCmd::Record {
            repo,
            inputs,
            normalize,
            name,
            no_traps,
            timeout,
            http,
            port,
            server_args,
            fresh,
            pace,
            float_tolerance,
            float_files,
            effects,
            effect_env,
            db_reset,
            db_dump,
            json,
            run,
        } => {
            let effects = mojo_anything::effects::EffectsConfig::from_args(
                &effects,
                &effect_env,
                db_reset.as_deref(),
                db_dump.as_deref(),
            )?;
            let outcome = app::record(&app::RecordOptions {
                repo: &repo,
                run: &run,
                inputs: inputs.as_deref(),
                normalize: &normalize,
                name: name.as_deref(),
                traps: !no_traps,
                timeout_secs: timeout,
                http,
                port,
                server_args: &server_args,
                fresh: &fresh,
                pace_ms: pace,
                float_tolerance,
                float_files: &float_files,
                effects,
            })?;
            if json {
                say!("{}", serde_json::to_string_pretty(&outcome)?);
                return Ok(ExitCode::SUCCESS);
            }
            say!(
                "Recorded {} cases in {} ({} from examples, {} from inputs, {} traps)",
                outcome.cases,
                outcome.dir.display(),
                outcome.examples,
                outcome.inputs,
                outcome.traps
            );
            for (kind, what) in [
                (
                    app::NoiseKind::Lines,
                    "Lines (a different number of lines between two runs; now `...`, which matches anything: check these first)",
                ),
                (
                    app::NoiseKind::Order,
                    "Order (the same lines in another order between two runs; replay compares them in any order)",
                ),
                (
                    app::NoiseKind::Values,
                    "Values (parts of lines differed between two runs; now `[..]` wildcards)",
                ),
            ] {
                let hits: Vec<String> = outcome
                    .noise
                    .iter()
                    .filter(|n| n.kind == kind)
                    .map(|n| format!("{} ({})", n.case, n.field))
                    .collect();
                if !hits.is_empty() {
                    say!("Noise, {what}: {}", hits.join(", "));
                }
            }
            if !outcome.unstable.is_empty() {
                say!(
                    "Unstable (exit code or files differed between runs; check them): {}",
                    outcome.unstable.join(", ")
                );
            }
            if !outcome.timed_out.is_empty() {
                say!("Timed out, not recorded: {}", outcome.timed_out.join(", "));
            }
        }
        AppCmd::Replay {
            repo,
            build,
            timeout,
            port,
            case,
            json,
        } => {
            let outcome = app::replay(&app::ReplayOptions {
                repo: &repo,
                build: build.as_deref(),
                timeout_secs: timeout,
                port,
                case: case.as_deref(),
            })?;
            if json {
                say!("{}", serde_json::to_string_pretty(&outcome)?);
            } else {
                say_replay(&outcome);
            }
            if !outcome.failures.is_empty() {
                return Ok(ExitCode::FAILURE);
            }
        }
        AppCmd::FrontDoor {
            repo,
            no_check,
            library,
            json,
        } => {
            let outcome = front_door::front_door(&front_door::FrontDoorOptions {
                repo: &repo,
                library,
                check: !no_check,
            })?;
            if json {
                say!("{}", serde_json::to_string_pretty(&outcome)?);
            } else {
                say!(
                    "Created {} ({} `{}`), {}",
                    outcome.dir.display(),
                    if outcome.api.is_empty() {
                        "binary"
                    } else {
                        "crate"
                    },
                    outcome.binary,
                    if !outcome.api.is_empty() {
                        format!(
                            "a library; public API: {}",
                            outcome
                                .api
                                .iter()
                                .map(|a| format!("{} ({} exports)", a.unit, a.exports.len()))
                                .collect::<Vec<_>>()
                                .join(", ")
                        )
                    } else if !outcome.routes.is_empty() {
                        format!("requests recorded: {}", outcome.routes.join(", "))
                    } else if outcome.commands.is_empty() {
                        "commands: none (one root command)".to_string()
                    } else {
                        format!("commands: {}", outcome.commands.join(", "))
                    }
                );
                for file in &outcome.files {
                    say!("  {file}");
                }
                if let Some(replay) = &outcome.replay {
                    say_replay(replay);
                }
                if !outcome.api.is_empty() {
                    say!(
                        "Every export is still only in the original. After a unit's crate (from `bridge`) passes gate: mojo-anything app wire {} <unit crate>",
                        repo.display()
                    );
                } else if outcome.routes.is_empty() {
                    say!(
                        "Every command runs the original. After a unit passes gate: mojo-anything app wire {} <unit> --command <name>",
                        repo.display()
                    );
                } else {
                    say!(
                        "Every request goes to the original. After a unit passes gate: mojo-anything app wire {} <unit> --route 'GET /path/{{param}}'",
                        repo.display()
                    );
                }
            }
            if outcome
                .replay
                .as_ref()
                .is_some_and(|r| !r.failures.is_empty())
            {
                return Ok(ExitCode::FAILURE);
            }
        }
        AppCmd::Wire {
            repo,
            unit,
            commands,
            routes,
            skip_gate,
            no_check,
            json,
        } => {
            let outcome = front_door::wire(&front_door::WireOptions {
                repo: &repo,
                unit: &unit,
                commands: &commands,
                routes: &routes,
                skip_gate,
                check: !no_check,
            })?;
            if json {
                say!("{}", serde_json::to_string_pretty(&outcome)?);
            } else {
                say!(
                    "Wired {} ({}) to {}; {}=original sends it back to the original",
                    outcome.unit,
                    outcome.crate_dir.display(),
                    if outcome.shadow.is_some() {
                        "the public API".to_string()
                    } else if outcome.routes.is_empty() {
                        outcome.commands.join(", ")
                    } else {
                        outcome.routes.join(", ")
                    },
                    outcome.switch
                );
                if let Some(shadow) = &outcome.shadow {
                    say!(
                        "The original package imports {} in place of the unit until the lift.",
                        shadow.display()
                    );
                    if shadow.extension().is_some_and(|e| e == "c") {
                        say!(
                            "C switches at build time: compile without the -D flags in shadow/flags.txt to send it back."
                        );
                    }
                }
                if outcome.glue_pending {
                    say!(
                        "Write the glue in {}, then run this again.",
                        outcome.glue.display()
                    );
                }
                if let Some(replay) = &outcome.replay {
                    say_replay(replay);
                }
            }
            if outcome
                .replay
                .as_ref()
                .is_some_and(|r| !r.failures.is_empty())
            {
                return Ok(ExitCode::FAILURE);
            }
        }
        AppCmd::Lift { repo, json } => {
            let outcome = lift::lift(&lift::LiftOptions { repo: &repo })?;
            if json {
                say!("{}", serde_json::to_string_pretty(&outcome)?);
            } else {
                for item in &outcome.checklist {
                    let mark = match item.mark {
                        lift::Mark::Pass => "pass",
                        lift::Mark::Warn => "warn",
                        lift::Mark::Fail => "FAIL",
                        lift::Mark::Skip => "skip",
                    };
                    let mut lines = item.detail.lines();
                    say!(
                        "{mark}  {:<24} {}",
                        item.name,
                        lines.next().unwrap_or_default()
                    );
                    if item.mark == lift::Mark::Fail {
                        for line in lines {
                            say!("      {line}");
                        }
                    }
                }
                if outcome.lifted {
                    say!(
                        "Lifted: {} no longer needs the original ({}). Removed {} generated files; the original is untouched.",
                        repo.join(front_door::APP_DIR).display(),
                        outcome
                            .binary
                            .as_ref()
                            .map(|b| b.display().to_string())
                            .unwrap_or_default(),
                        outcome.removed.len()
                    );
                } else {
                    say!("Not lifted:");
                    for b in &outcome.blockers {
                        say!("- {b}");
                    }
                    if let Some(stage) = &outcome.stage {
                        say!("The lifted copy is in {} for a look.", stage.display());
                    }
                }
            }
            if !outcome.lifted {
                return Ok(ExitCode::FAILURE);
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

/// A path argument made absolute: the tools run compilers and cargo from scratch folders, where
/// a relative crate path points nowhere.
fn absolute(arg: &str) -> Result<PathBuf, String> {
    std::path::absolute(arg).map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `--profile` keeps only `host`: the Android build, record and diff went with JNI.
    #[test]
    fn android_profile_is_gone() {
        for step in ["build", "record", "diff"] {
            let Err(err) =
                Cli::try_parse_from(["mojo-anything", step, "--profile", "android", "."])
            else {
                panic!("{step} accepted --profile android");
            };
            assert_eq!(
                err.kind(),
                clap::error::ErrorKind::InvalidValue,
                "{step}: {err}"
            );
            assert!(err.to_string().contains("invalid value"), "{step}: {err}");
        }
    }

    /// `--help` describes the Mojo tool, not the Rust one it was forked from.
    #[test]
    fn help_names_mojo() {
        use clap::CommandFactory;
        let help = Cli::command().render_long_help().to_string();
        assert!(help.contains("Mojo"), "{help}");
        assert!(!help.contains("Rust"), "{help}");
        assert!(!help.contains("port.rs"), "{help}");
    }
}
