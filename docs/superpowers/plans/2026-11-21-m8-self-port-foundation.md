# Milestone 8: the tool in Mojo, foundation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record the tagged Phase 1 binary over the repository's own fixtures, put a Mojo `mojo-anything` front door in front of it, and move the plumbing plus `doctor`, `map`, `setup`, `app record` and `app replay` into Mojo, each proven by replaying the recording.

**Architecture:** The Mojo tool lives in `tool/` (package `tool/src/mojo_anything/`, entry `tool/src/main.mojo`, tests `tool/tests/test_*.mojo`), built with the root `pixi.toml` from M1. Its `main` parses the command line by hand; a subcommand it owns runs in Mojo, every other one execs the Phase 1 Rust binary with the same arguments, stdin and environment and logs a fallback, the same way generated front doors do (`src/front_door.rs`). Proof is `mojo-anything app replay . --build <Mojo binary>` against cases recorded from the Rust binary, reading the fallback line.

**Tech Stack:** Mojo via pixi (pinned in M1), CPython through Mojo's Python interop where the user allowed it, the Phase 1 Rust binary as the fallback and the recorder.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` (Phase 2: Method, Order steps 1–3, Libraries table, "Replay matching in Phase 2", and "What written in Mojo allows").

Follows M1–M7 (Phase 1). M9 (`2026-11-21-m9-self-port-commands.md`) moves the remaining commands and deletes the Rust.

## Global Constraints

- Work in the WSL clone `~/github/mojo-anything`; Mojo from the pinned pixi environment; check each Mojo API against the pinned stdlib and add it to `docs/mojo-notes.md` before use.
- The recording's source of truth is the binary built from the Phase 1 tag (`v0.1.0`, tagged by M7 Task 8); it is built once into `tool/fallback/` and never rebuilt during Phase 2 except by re-recording.
- Only Rust is banned in the finished tool. CPython via interop and generated C shims are allowed.
- Help text and every message the tool writes itself match byte for byte. Absolute paths, timestamps and outside tools' versions and messages are masked by recorded normalisers, each with a reason in `mojo/app-cases/NORMALISERS.md`.
- A subcommand counts as moved only when `app replay --build` passes all its cases and its fallback count is 0.
- The Rust tool stays buildable and its `cargo test` stays green until M9's last task.
- JSON is the Mojo JSON from M3 (`src/mojo/json.mojo`: exact float round trip, key order kept, no depth limit); copy it into `tool/src/mojo_anything/json.mojo` by a build step, never by hand edits that drift.
- Before each commit: `pixi run mojo format --check tool`, the Mojo build with warnings as errors, `pixi run mojo test tool/tests`, plus `cargo fmt/clippy/test` while Rust remains.

## Review Focus

1. **A fallback that hides itself.** If exec of the Rust binary fails (missing file, not executable) the front door must exit non-zero with one line naming `tool/fallback/`, never pass by printing nothing. Test: Task 2 `fallback_binary_missing`.
2. **Exit codes and stderr through the fallback.** A failing Rust subcommand's exit code and stderr reach the caller unchanged. Test: Task 2 `fallback_keeps_exit_and_stderr`.
3. **Processes that never end** (watch-mode test runners, a server that ignores SIGTERM). The Mojo `process.run` closes stdin, kills the whole process group at the limit and reports it. Test: Task 3 `kills_group_at_limit`.
4. **Paths with `..`, symlinks and spaces.** Canonical paths compare equal and print once (pitfall: coverage listed one file three times). Test: Task 4 `canonical_through_symlink_and_dotdot`.
5. **Floats on the way through JSON** in case files: `5e-324`, `-0`, `1e21`, ties. They must be written exactly as the Rust tool wrote them. Test: Task 5 `case_floats_round_trip`.

---

### Task 1: Record the Phase 1 binary

**Files:**
- Create: `tool/record/inputs.jsonl` (one line per case: `{"name", "args", "stdin", "env", "files"}`), `tool/record/make_inputs.py` (builds it from `tests/fixtures/*` and `demo/`), `mojo/app-cases/` (written by `app record`), `mojo/app-cases/NORMALISERS.md`, `scripts/build-fallback.sh`
- Modify: `.gitignore` (`tool/fallback/`)

**Interfaces:**
- Produces: `scripts/build-fallback.sh` builds the Phase 1 tag into `tool/fallback/mojo-anything` (a worktree at the tag, its own `CARGO_TARGET_DIR`: pitfall about shared target folders). The case set every later task replays.

- [ ] **Step 1:** Write `make_inputs.py`. For each subcommand in `src/main.rs` (`analyze`, `bridge`, `refresh`, `record`, `build`, `diff`, `bench`, `fuzz`, `profile`, `shadow`, `gate`, `package`, `app record|replay|front-door|wire|lift`, `mcp`, `setup`, `map`, `doctor`): `--help`, each error path (missing arguments, bad values), and runs over each fixture it accepts, with the fixture copied in through `files` (pitfall: cases run in an empty directory). Commands that regenerate files run on fixtures whose generated files are overwritten with a marker first (pitfall). `mcp` cases are scripted stdio sessions (`initialize`, `tools/list`, one call per tool). `setup` and `doctor` run with `HOME` pointed at the case directory.
- [ ] **Step 2:** `scripts/build-fallback.sh`, then `tool/fallback/mojo-anything app record . --inputs tool/record/inputs.jsonl --normalize timestamps --normalize uuids` plus `name=regex` normalisers for the repository path, the case directory, toolchain version lines and compiler diagnostics; list each with its reason in `NORMALISERS.md`.
- [ ] **Step 3:** Check the counts: every subcommand has at least its `--help` case, the total matches the line count of `inputs.jsonl`, and the `*.out` folders of file-writing commands are not empty (pitfall).
- [ ] **Step 4:** `tool/fallback/mojo-anything app replay . --build tool/fallback/mojo-anything` passes everything (the recording is stable). Run it twice.
- [ ] **Step 5: Commit** `test: record the Phase 1 binary as the Phase 2 specification`.

### Task 2: The Mojo front door

**Files:**
- Create: `tool/src/main.mojo`, `tool/src/mojo_anything/__init__.mojo`, `tool/src/mojo_anything/fallback.mojo`, `tool/tests/test_fallback.mojo`, `tests/mojo_front_door.rs` (driven from cargo while Rust remains)
- Modify: `pixi.toml` (task `build-tool` → `tool/build/mojo-anything`)

**Interfaces:**
- Produces:
  - `fn fallback(argv: List[String]) raises -> Int` in `fallback.mojo` — appends one line (the subcommand) to the file named by `MOJO_ANYTHING_FALLBACK_LOG` when set, then replaces the process with `tool/fallback/mojo-anything` and the same argv, stdin and environment (exec via libc through `external_call` with a `# SAFETY:` comment, or Python's `os.execv`; record the choice in `docs/mojo-notes.md`). The fallback path comes from `MOJO_ANYTHING_FALLBACK` or, unset, the binary's sibling `../fallback/mojo-anything`.
  - `main` dispatches on the first argument through a table `OWNED: List[String]` that later tasks extend; everything else calls `fallback`.

- [ ] **Step 1: Write failing tests** in `tests/mojo_front_door.rs`:
  - `all_cases_through_fallback`: `app replay . --build tool/build/mojo-anything` passes every case with fallback 100%.
  - `fallback_keeps_exit_and_stderr`: `mojo-anything bridge /nonexistent` exits with the Rust binary's code and the same stderr bytes.
  - `fallback_binary_missing`: with `MOJO_ANYTHING_FALLBACK=/nope`, exit is non-zero and stderr names `tool/fallback`.
- [ ] **Step 2:** Run `cargo test --test mojo_front_door`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat(tool): Mojo front door that falls back to the Phase 1 binary`.

### Task 3: Running other programs

**Files:**
- Create: `tool/src/mojo_anything/process.mojo`, `tool/tests/test_process.mojo`

**Interfaces:**
- Produces (port of `src/process.rs`):
  - `struct Output(success: Bool, code: Int, stdout: List[UInt8], stderr: List[UInt8], timed_out: Bool)` with `stdout_text()` and `stderr_text()` (lossy UTF-8, as Rust's).
  - `fn limit(default_s: Float64) -> Float64` — `MOJO_ANYTHING_COMMAND_TIMEOUT` overrides, same parsing as `process::limit`.
  - `fn output(cmd: Command, default_s: Float64) raises -> Output` and `fn status(...) raises -> Int` — stdin closed, own process group, the group killed at the limit, error text identical to the Rust one.
  - `struct Command(program, args, env: Dict, env_remove: List, cwd)`.
  The route (Python `subprocess` with `start_new_session=True` and `os.killpg`, or libc) is the implementer's, recorded in `docs/mojo-notes.md`.

- [ ] **Step 1: Write failing tests:** `captures_both_streams`, `stdin_is_closed` (`cat` returns at once with empty output), `kills_group_at_limit` (a shell that starts `sleep 100 &` then waits: returns within limit + 1 s, `timed_out`, and no `sleep` left in the group), `env_override_of_limit`.
- [ ] **Step 2:** `pixi run mojo test tool/tests/test_process.mojo`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat(tool): run outside programs with closed stdin and time limits`.

### Task 4: Paths and gitignore-aware walks

**Files:**
- Create: `tool/src/mojo_anything/walk.mojo`, `tool/tests/test_walk.mojo`

**Interfaces:**
- Produces (port of `src/walk.rs`):
  - `trait Canonical` equivalent: `fn canonical(path: String) raises -> String` (resolves `..` and symlinks; falls back to lexical clean when the path does not exist, as the Rust does).
  - `fn walk(root: String, keep: fn(String) -> Bool) raises -> List[String]` — sorted, honours `.gitignore` from the repository root down, `.git/info/exclude`, nested `.gitignore`s, negation and directory patterns, as `ignore::WalkBuilder` does with the settings `walk::builder` sets.
  - `fn ignored_files(root: String, extensions: List[String]) raises -> Int`.

- [ ] **Step 1: Write failing tests:** `canonical_through_symlink_and_dotdot`, `nested_gitignore_and_negation` (a fixture tree with `!keep.py` under an ignored folder pattern, matching what the Rust walk returns, captured once into `tool/tests/data/walk_expected.txt` by a cargo test), `ignored_count_matches_rust`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement the gitignore matcher by hand (glob segments, `**`, anchoring, trailing `/`, `!`).
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat(tool): canonical paths and gitignore-aware walks`.

### Task 5: Case files, tolerance and JS numbers

**Files:**
- Create: `tool/src/mojo_anything/json.mojo` (copied by the `build-tool` task from `src/mojo/json.mojo`), `tool/src/mojo_anything/js_number.mojo`, `tool/src/mojo_anything/tolerance.mojo`, `tool/src/mojo_anything/recording.mojo`, `tool/tests/test_cases.mojo`

**Interfaces:**
- Produces:
  - `fn js_number_to_string(x: Float64) -> String` (port of `src/js_number.rs`).
  - Tolerance: `fn within(a: JsonValue, b: JsonValue, rel: Float64) -> Bool` and line pairing for unordered output by matching lines against each other, identical first, then a search that gives a line up when another needs it — never by sorting (pitfall: "Sorting cannot pair lines that are matched loosely").
  - Recording (port of `src/recording.rs`): `fingerprint`, `save_fingerprint`, `stale`, `track`, `last_diff`, `known_diffs`, `apply_known`, same file names and JSON shapes.

- [ ] **Step 1: Write failing tests:** `js_number_matches_v8` (the table in `src/js_number.rs` tests, plus `5e-324`, `1e21`, `-0`, `0.1+0.2`), `case_floats_round_trip` (read and rewrite `demo/real-world/python-colorsys-mojo/cases.jsonl`; bytes unchanged), `deep_line_reads` (200-deep array), `unordered_pairs_loose_lines` (`10.0` pairs with `9.999999999999999`, not `2.0`), `stale_after_source_edit`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS.
- [ ] **Step 5: Commit** `feat(tool): case files, tolerance and JS number formatting`.

### Task 6: Command-line parsing and help

**Files:**
- Create: `tool/src/mojo_anything/cli.mojo`, `tool/src/mojo_anything/cli_spec.mojo` (the table of subcommands, arguments, defaults and help strings, taken from `src/main.rs`), `tool/tests/test_cli.mojo`
- Modify: `tool/src/main.mojo` (parse with `cli.mojo` before dispatch; `--help`, `--version` and usage errors owned in Mojo)

**Interfaces:**
- Produces: `struct Parsed(command: List[String], values: Dict[String, List[String]], flags: Set[String], rest: List[String])`; `fn parse(spec: CliSpec, argv: List[String]) raises CliError -> Parsed`; `fn render_help(spec, path) -> String` producing clap 4's layout (usage line, wrapped "Arguments:"/"Options:" sections, `[default: …]`, aliases) byte for byte; `CliError` renders clap's error text and exit code 2.

- [ ] **Step 1: Write failing tests:** `help_matches_recording` (every `--help` case in `mojo/app-cases/`), `usage_error_matches` (missing required argument, unknown flag, bad enum value with clap's "possible values"), `trailing_args_after_double_dash` (`app record . -- python3 cli.py`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement; add `--help`, `--version` and usage errors to `OWNED`.
- [ ] **Step 4:** `app replay . --build tool/build/mojo-anything`: all pass; every `--help` and usage-error case has no fallback.
- [ ] **Step 5: Commit** `feat(tool): hand-written CLI with clap-identical help`.

### Task 7: `doctor`, `map` and `setup`

**Files:**
- Create: `tool/src/mojo_anything/doctor.mojo`, `map.mojo`, `setup.mojo`, `report.mojo` (port of `src/report.rs`), `tool/tests/test_setup.mojo`, `tool/tests/test_map.mojo`
- Reference: `src/doctor.rs`, `src/port_map.rs`, `src/setup.rs`, `src/report.rs`

**Interfaces:**
- Consumes: Tasks 3–6.
- Produces: `fn run_doctor(p: Parsed) raises -> Int`, `fn run_map(p: Parsed) raises -> Int`, `fn run_setup(p: Parsed) raises -> Int`, `fn markdown(report: JsonValue, title: String) -> String`. TOML read through Python `tomllib`; TOML written by hand preserving the user's existing text (the Rust uses `toml_edit`; setup's Codex config must keep comments).

- [ ] **Step 1: Port each `#[test]` of the three Rust files** into the Mojo test files (same names, same assertions). Run: FAIL.
- [ ] **Step 2:** Implement; add `doctor`, `map`, `setup` to `OWNED`.
- [ ] **Step 3:** Mojo tests pass; `app replay . --build tool/build/mojo-anything` passes every case and shows 0 fallbacks for these three commands.
- [ ] **Step 4: Commit** `feat(tool): doctor, map and setup in Mojo`.

### Task 8: `app record` and `app replay`

**Files:**
- Create: `tool/src/mojo_anything/app/record.mojo`, `app/replay.mojo`, `app/cases.mojo` (trycmd files, schema `mojo-anything/app-cases@1`), `app/normalize.mojo` (built-ins `timestamps`, `uuids`, `key-order` and `name=regex` via Python `re`), `app/effects.mojo` (port of `src/effects.rs`), `app/http.mojo` (port of the replay half of `src/http.rs`), `tool/tests/test_app.mojo`
- Reference: `src/app.rs`, `src/effects.rs`, `src/http.rs`, `src/pin.rs`

**Interfaces:**
- Consumes: Tasks 3–6.
- Produces: `fn run_app_record(p: Parsed) raises -> Int`, `fn run_app_replay(p: Parsed) raises -> Int` with the same report text, JSON (`--json`) and fallback line (`Fallback { cases, total }`) as `app.rs`. HTTP replay uses Python `http.client` with `TCP_NODELAY` on (pitfall: delayed ACK).

- [ ] **Step 1: Port the `#[test]`s** of `tests/app.rs`, `tests/app_fresh.rs`, `tests/effects.rs` and the replay half of `tests/http.rs` to `tool/tests/test_app.mojo`, pointing at the Mojo binary. Run: FAIL.
- [ ] **Step 2:** Implement; add `app record` and `app replay` to `OWNED`.
- [ ] **Step 3:** Prove the new replayer with the old one and the old with the new: `tool/fallback/mojo-anything app replay . --build tool/build/mojo-anything` and `tool/build/mojo-anything app replay . --build tool/fallback/mojo-anything` both pass every case; the second reports the fallback rate of the first's binary correctly.
- [ ] **Step 4:** Mojo tests pass.
- [ ] **Step 5:** Update `docs/STATUS.md` with a "Phase 2" table: commands owned in Mojo, cases, fallback rate, date.
- [ ] **Step 6: Commit** `feat(tool): app record and app replay in Mojo`.
