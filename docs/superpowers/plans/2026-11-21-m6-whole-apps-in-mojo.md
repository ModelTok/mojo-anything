# Milestone 6: Whole apps in Mojo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `app front-door`, `app wire` and `app lift` produce Mojo: a Mojo binary at `mojo/app/` that owns a CLI's entry point, falls back to the original for everything not wired, and is lifted to a pure Mojo binary proven on the recorded cases; then libraries and servers.

**Architecture:** `app record` and `app replay` stay as they are (the program is a black box). The generators in `src/front_door.rs`, `src/front_door_http.rs`, `src/library.rs` and `src/lift.rs` that write a Cargo project under `rust/app` are replaced by generators that write a pixi project under `mojo/app`: `main.mojo` (routing), `original.mojo` (fallback: `run`, `run_with_stdin`, `report_fallbacks`), `units.mojo` (kill switches and calls into each unit's `port.mojo`) and one glue file per wired unit. The library mapping in `src/crates.toml` becomes a table of Mojo stdlib and Python-interop equivalents.

**Tech Stack:** Rust 2024 (the tool), Mojo via pixi, CPython (interop), WSL Ubuntu 24.04.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` ("Whole apps", "Phase 1 done when": one CLI lifted to a pure Mojo binary; "Calls made after the builder check": PHP and C#).

Assumes Milestones 1–5 have landed: every source language bridges to Mojo; `crate::mojo::{MOJO_VERSION, available, command, missing_message}`, `codegen_mojo::{port_mojo, parse_port_mojo, STUB_MARK}`, `gate::mojo_checks`, the JSON helper `src/mojo/json.mojo` and the C-ABI dispatcher from `src/codegen_mojo_ffi.rs` exist.

## Global Constraints

- All work and tests run in the WSL clone `~/github/mojo-anything`; Mojo comes from the pinned pixi environment (`crate::mojo::MOJO_VERSION`).
- Verify every Mojo API (process spawning, environment, stdin/stdout bytes, exit codes, sockets) against the pinned stdlib and add the confirmed spelling to `docs/mojo-notes.md` before generating code that uses it.
- Folders: front door `mojo/app/`, its state `mojo/app/mojo-anything.json`, recorded cases `mojo/app-cases/`; kill switches `MOJO_ANYTHING_UNIT_<NAME>`; fallback log `MOJO_ANYTHING_FALLBACK_LOG`; repository variable `MOJO_ANYTHING_REPO`.
- The front door builds into its own `mojo/app/.mojo-anything/build` (pitfall: two front doors overwrote each other's binary).
- Every child process goes through `crate::process` (stdin closed, time limit); no child writes to the MCP server's stdout.
- Glue that reads stdin and declines calls `original.run_with_stdin(args, input)`; `lift` refuses while any glue still contains `original.`.
- PHP and C# keep `analyze` and whole apps only (front door, wire with Mojo units from other languages, lift); no bridge for their units.
- Replays always pass `--build <front door binary>` and read the fallback line (pitfall: replay without `--build` reports the original).
- Before each commit: `cargo fmt --all`, `cargo clippy --all-targets -- -D warnings`, `cargo test`; update `docs/STATUS.md` when what works changes. Prose in UK English.

## Review Focus

1. **Binary stdin and stdout.** A CLI fed bytes that are not UTF-8 (or a NUL) must pass through the fallback and through glue unchanged; Mojo `String` must not be used for the raw streams. Test: Task 2 `fallback_passes_bytes_through`.
2. **Exit codes and signals.** The original exiting 3, or being killed by a signal, must give the same exit status from the front door. Test: Task 2 `fallback_keeps_exit_status`.
3. **Kill switch after wiring.** `MOJO_ANYTHING_UNIT_<NAME>=original` must route a wired command back to the original even after the unit's port is complete. Test: Task 3 `kill_switch_sends_command_back`.
4. **A front door started outside the repository** (from a test runner's temp directory, or through a symlinked `mojo/`) must still find the original via `MOJO_ANYTHING_REPO`. Test: Task 2 `front_door_found_through_symlink` (port of `a_front_door_in_a_symlinked_rust_dir_finds_the_original`).
5. **Config files around the input.** A CLI that reads files next to its input (pitfall: Prettier's `.prettierrc`) must have those cases fall back or match, never pass because the case was recorded in an empty directory. Test: Task 4 `cli_with_config_file_falls_back`.

---

### Task 1: Paths, names and the library table

**Files:**
- Modify: `src/front_door.rs` (`APP_DIR = "mojo/app"`, `STATE_FILE`, `KILL_SWITCH_PREFIX`, `kill_switch` strips `-mojo` instead of `-rs`), `src/app.rs` (`CASES_DIR = "mojo/app-cases"`, `CONFIG_FILE`, `FALLBACK_ENV`), `src/crates.rs` (doc comments, `CrateMatch` field renamed `crates` → `replacement`), `src/crates.toml` → renamed `src/replacements.toml`, `src/whole_app.rs` (dependency report wording)
- Test: unit tests in `src/front_door.rs` and `src/crates.rs`; `tests/analyze.rs`

**Interfaces:**
- Produces:
  - `pub fn kill_switch(unit_name: &str) -> String` — `MOJO_ANYTHING_UNIT_<NAME>`; `colorsys-pkg-mojo` → `MOJO_ANYTHING_UNIT_COLORSYS_PKG`.
  - `pub fn find(lang: &str, name: &str) -> Option<CrateMatch>` unchanged in shape; `CrateMatch.replacement` names a Mojo stdlib module, a Mojo package on pixi, or `python:<module>` for Python interop, with the same `fit` values (`good`, `partial`, `none`).
  - `State.schema = "mojo-anything/app@1"`; `State::load` of an old `rust/app/rust-anything.json` fails with a message to run `app front-door` again.

- [ ] **Step 1: Write failing tests:** `kill_switch_names_mojo_units` (the example above); `replacements_table_parses` (every entry of `replacements.toml` parses and each `fit` is one of the three); `python_yaml_maps_to_interop` (`find("python", "yaml")` gives `python:yaml`, fit `good`); `old_front_door_state_says_rerun`.
- [ ] **Step 2:** Run `cargo test kill_switch replacements python_yaml old_front_door`. Expected: FAIL.
- [ ] **Step 3:** Rewrite each `[[<lang>]]` entry of the table: a Mojo stdlib or pixi package where one does the job, otherwise `python:<module>` with fit `partial` when only CPython has it, `none` when neither does. Keep the "never guessed" rule: a library missing from the table stays `unknown`.
- [ ] **Step 4:** Run again; then the full gate. `analyze --whole-app` on `tests/fixtures/python-reqs` lists Mojo replacements.
- [ ] **Step 5: Commit** `feat: whole-app paths and the Mojo replacement table`.

### Task 2: The CLI front door in Mojo

**Files:**
- Create: `src/front_door_mojo.rs` (generators), `src/mojo/original.mojo` (template, `include_str!`)
- Modify: `src/front_door.rs` (`front_door` writes the Mojo project; `cargo_build` → `mojo_build`; `rustfmt` → `mojo format`), `src/lib.rs`
- Test: `tests/app.rs` (CLI front-door tests), `tests/app_fresh.rs`

**Interfaces:**
- Consumes: `crate::mojo::command`, `app::cases_dir`, `State`.
- Produces:
  - `pub(crate) fn main_mojo(state: &State, flags: &BTreeMap<String, BTreeMap<String, Flag>>) -> String` — reads `argv`, picks the command, calls `units.<command>` when a wired unit's switch is not `original`, else `original.run(args)`.
  - `pub(crate) fn original_mojo(run: &[String], in_root: bool) -> String` — `run(args) -> Int`, `run_with_stdin(args, input: List[UInt8]) -> Int`, `report_fallbacks()`; resolves the repository from `MOJO_ANYTHING_REPO`, then from the binary's location; appends one line per fallback to `MOJO_ANYTHING_FALLBACK_LOG`.
  - `pub(crate) fn units_mojo(state: &State, lifted: bool) -> String`.
  - `pub(crate) fn mojo_build(app_dir: &Path) -> Result<PathBuf>` — builds `mojo/app/main.mojo` into `mojo/app/.mojo-anything/build/<binary>`, returns the binary path.
  - `pub(crate) fn pixi_toml_app(name: &str) -> String`.
- Spike (Step 1) decides how `original.mojo` starts the original with inherited stdio and raw-byte stdin: the stdlib's process API if it can, else `posix_spawn`/`waitpid` through `external_call` (each call with a `# SAFETY:` comment), else Python's `subprocess` through interop. Record the choice and why in `docs/mojo-notes.md` and `DECISIONS.md`.

- [ ] **Step 1: Spike** (throwaway, in the scratch folder): a Mojo program that runs `cat` with a 3-byte non-UTF-8 stdin, forwards stdout bytes and exit status, and runs `sh -c 'exit 3'` and `sh -c 'kill -TERM $$'`. Pick the first route that passes all three.
- [ ] **Step 2: Write failing tests** in `tests/app.rs` (skip without Mojo):
  - `ts_cli_front_door_falls_back` (and `python_`, `c_`, `go_`, `ruby_`, `java_`, `php_`, `csharp_` variants via the existing `front_door_then_wire` helper): `app front-door --check` builds `mojo/app`, the replay passes every case, and the fallback count equals the case count.
  - `fallback_passes_bytes_through`: a fixture CLI that echoes stdin; a case with bytes `ff 00 fe` replays identically through the front door.
  - `fallback_keeps_exit_status`: exit 3 and a TERM kill replay with the original's status.
  - `front_door_found_through_symlink` in `tests/app_fresh.rs`: `mojo/` a symlink; replay still passes.
- [ ] **Step 3:** Run `cargo test --test app front_door fallback && cargo test --test app_fresh`. Expected: FAIL.
- [ ] **Step 4:** Implement; delete the Cargo generators for CLIs (`cargo_toml`, `main_rs`, `original_rs` CLI paths).
- [ ] **Step 5:** Run again. Expected: PASS; full gate.
- [ ] **Step 6: Commit** `feat: the CLI front door is a Mojo binary`.

### Task 3: `app wire` with Mojo units

**Files:**
- Modify: `src/front_door.rs` (`wire`), `src/front_door_mojo.rs` (`glue_mojo`)
- Test: `tests/app.rs`

**Interfaces:**
- Consumes: `WireOptions` unchanged; `gate::mojo_checks` (runs before wiring unless `skip_gate`); `codegen_mojo::parse_port_mojo` to list what the unit offers.
- Produces:
  - `pub(crate) fn glue_mojo(unit: &WiredUnit, api: &PortApi) -> String` — `mojo/app/glue/<unit>.mojo` with one `def <command>(args: List[String]) raises -> Int` stub per wired command; the stub body calls `original.run(args)` and carries `GLUE_MARKER` so `is_stub` still detects it.
  - The front door imports each wired unit's `port.mojo` as a Mojo package (path added to the app's build include list), not through its language bridge.

- [ ] **Step 1: Write failing tests:**
  - `wire_writes_mojo_glue`: after `app wire . textops-mojo --command upper`, `mojo/app/glue/textops.mojo` exists and `is_stub` is true; replay still passes with fallback unchanged.
  - `wired_command_runs_in_mojo`: with the glue filled (fixture `tests/fixtures/app-glue/textops.mojo`), the `upper` cases match and the fallback line drops by their count.
  - `kill_switch_sends_command_back`: with the same glue and `MOJO_ANYTHING_UNIT_TEXTOPS=original`, every case falls back again and still matches.
  - `glue_declines_with_stdin`: glue that reads stdin and calls `original.run_with_stdin` for one input replays that case as one fallback, the rest in Mojo.
- [ ] **Step 2:** Run `cargo test --test app wire kill_switch glue_declines`. Expected: FAIL.
- [ ] **Step 3:** Port `textops_port` (in `tests/app.rs`) to a Mojo string the tests write; implement.
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: wire Mojo units into the front door`.

### Task 4: `app lift` to a pure Mojo binary

**Files:**
- Modify: `src/lift.rs` (`lift`, `strip_unit`, checklist items), `src/front_door_mojo.rs` (`units_mojo(.., lifted: true)`)
- Test: `tests/app.rs` (`*_cli_lifts_to_pure_mojo`, renamed from `*_lifts_to_pure_rust`; `lift_strips_bridge_bindings_in_every_language`)

**Interfaces:**
- Consumes: `LiftOptions`, `LiftOutcome`, `Item`, `Mark` unchanged.
- Produces: `pub fn strip_unit(dir: &Path) -> Result<Vec<PathBuf>>` removes each unit's language bridge (`_native.mojo` and the Python package, the C-ABI dispatcher and its wrapper, the Node shim, the FFM wrapper) and keeps `port.mojo` and its tests. The lifted `mojo/app` has no `original.mojo` and no kill switches. The lift is made on a copy of `mojo/` and copied back only when every check passes.
- Checklist adds `mojo build` warnings-free, `mojo format`, every unit's `gate::mojo_checks`, `no fallback` (0 fallback lines over the whole replay), `no original.` (no glue mentions `original.`).

- [ ] **Step 1: Write failing tests:**
  - `python_cli_lifts_to_pure_mojo` (and the TS, C, Go, Ruby, Java, PHP, C# variants via `lift_end_to_end`): first `lift` is blocked with a blocker naming the unwired command; after wiring and filling glue, `lift` succeeds, the replay against the lifted binary passes every case with fallback 0, and `mojo/app` has no `original.mojo`.
  - `lift_strips_bridge_bindings_in_every_language`: after lifting, no unit folder holds a bridge file from the list above.
  - `failed_lift_leaves_repo_unchanged`: a lift blocked by a failing gate leaves `mojo/` byte-identical (compare a hash of the tree before and after).
  - `cli_with_config_file_falls_back`: a fixture CLI reading `.textopsrc` next to its input, recorded with the file present (`--inputs` with a `files` entry), replays through the front door as fallback for those cases and is listed as a lift blocker until glue handles them.
- [ ] **Step 2:** Run `cargo test --test app lift config_file`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: lift a CLI to a pure Mojo binary`.

### Task 5: One real CLI lifted

**Files:**
- Create: `demo/real-world/<cli>-mojo/` (front door, units, recorded cases; manifest `root` a placeholder)
- Modify: `docs/STATUS.md`, `docs/real-world.md` or `docs/real-world-languages.md`, `docs/whole-apps.md` (commands and folders)

- [ ] **Step 1:** Pick the CLI: the smallest CLI already used in rust-anything's real-world runs whose units are bridged in Milestones 1–5 (default: a vercel/ms CLI wrapper; if its units are not all bridged, the Python CLI fixture used for `colorsys`). State the choice in the commit.
- [ ] **Step 2:** `app record` with `--inputs` from real usage; check the case count against the input lines (pitfall: case names cut short) and that `*.out` folders are not empty for any CLI that writes files (pitfall: stale fixture).
- [ ] **Step 3:** `app front-door --check`; wire each unit; fill the glue; `app replay --build <binary>` until fallback is 0.
- [ ] **Step 4:** `app lift`. Expected: lifted; replay against the pure binary passes every case.
- [ ] **Step 5:** Record in `docs/STATUS.md`: CLI name, cases, fallback 0, Mojo version, date. Rewrite `docs/whole-apps.md` for `mojo/app` and Mojo glue; run `scripts/check-secrets.sh`.
- [ ] **Step 6: Commit** `feat: <cli> lifted to a pure Mojo binary (<n>/<n>)`.

### Task 6: Libraries

**Files:**
- Modify: `src/library.rs` (`cargo_toml`, `lib_rs`, `allow_python_symbols`, `cargo_build_lib` → Mojo equivalents), `src/front_door_mojo.rs`
- Test: `tests/library.rs`

**Interfaces:**
- Produces:
  - `pub(crate) fn lib_mojo(state: &State, lifted: bool) -> String` — `mojo/app` as a Mojo package re-exporting each wired unit's `port.mojo` under the unit's name.
  - `pub(crate) fn mojo_build_lib(app_dir: &Path) -> Result<()>` — `mojo package` of `mojo/app` into its build folder.
  - `replay`, `pending`, `original_references`, `shadow_for` keep their signatures; the shadow drop-in honours `MOJO_ANYTHING_UNIT_<NAME>`.

- [ ] **Step 1: Write failing tests** in `tests/library.rs` (skip without Mojo): `library_front_door_is_mojo_package`; `library_wire_reexports_port` (the wired unit's functions are importable from the package under the unit's name); `library_lift_needs_zero_fallback`; `library_kill_switch_uses_original`.
- [ ] **Step 2:** Run `cargo test --test library`. Expected: FAIL.
- [ ] **Step 3:** Implement; delete the Cargo library generators.
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: library front doors as Mojo packages`.

### Task 7: Server route decision (spike)

**Files:**
- Create: `docs/superpowers/specs/2026-11-21-mojo-server-route.md` (the decision record), scratch spike outside the repository
- Modify: `DECISIONS.md`, `docs/mojo-notes.md`

- [ ] **Step 1:** Take the Python server from `tests/http.rs` (`python_server`, fixture `tests/fixtures/http` Python phase) and its recorded cases.
- [ ] **Step 2:** Spike A: a Mojo proxy on libc sockets through `external_call` (`socket`, `bind`, `listen`, `accept`, `recv`, `send`, `setsockopt(TCP_NODELAY)`), forwarding every request to the original on its own port, with HTTP/1.1 keep-alive and chunked bodies.
- [ ] **Step 3:** Spike B: the same proxy using Python's `http.server` and `http.client` through interop.
- [ ] **Step 4:** For each: replay the cases (`--build` the spike), count matches, and time the handler in process next to the HTTP numbers (pitfall: a slow server row was the network). Run twice on a quiet machine; name the hardware.
- [ ] **Step 5:** Write the decision record: which route, the numbers, what each could not do. Default when both pass: A (no CPython in a lifted server). Put the one-line decision in `DECISIONS.md`.
- [ ] **Step 6: Commit** `docs: decide the Mojo server route`.

### Task 8: The HTTP front door in Mojo

**Files:**
- Modify: `src/front_door_http.rs` (every generator: `main_mojo_http`, `original_mojo_http`, `units_mojo_http`, `glue_mojo_http`, `lifted_main_mojo_http`; `check_routes` unchanged), `src/front_door.rs`, `src/lift.rs` (server lift)
- Create: `src/mojo/http.mojo` (request parsing, routing, response writing on the route chosen in Task 7, `TCP_NODELAY` set)
- Test: `tests/http.rs`

**Interfaces:**
- Consumes: Task 7's route; `State.routes`, `WiredUnit.routes`; route syntax unchanged (`METHOD /path/{param}`, `/path`, `*`).
- Produces: a front door that starts the original on a port of its own and proxies every route no unit answers; glue `def <route_fn>(req: Request, params: Dict[String, String]) raises -> Response`; the lifted server has no proxy.

- [ ] **Step 1: Write failing tests** in `tests/http.rs` (skip without Mojo): each `check_language` server (TS, Python, PHP, Ruby, C, Go, Java, C#) passes through the Mojo front door with every route proxied; `http_wire_route_in_mojo` (one route answered by glue, fallback drops by its cases); `http_lift_has_no_proxy`; the existing `http_fresh_files_and_arguments_reach_every_start` and `http_rerecord_uses_the_existing_fixed_port` against the Mojo build.
- [ ] **Step 2:** Run `cargo test --test http`. Expected: FAIL.
- [ ] **Step 3:** Implement; delete the axum generators.
- [ ] **Step 4:** Run again. Expected: PASS; full gate. `rg -n "axum|Cargo.toml|cargo build" src/front_door*.rs src/lift.rs src/library.rs` finds nothing.
- [ ] **Step 5:** Update `docs/whole-apps.md` (Servers) and `docs/STATUS.md` (front door, `wire`, `lift` rows).
- [ ] **Step 6: Commit** `feat: the HTTP front door is a Mojo server`.

### Task 9: Side effects and fresh state under the Mojo front door

**Files:**
- Modify: `src/effects.rs` only where it names the Rust front door or `rust/`
- Test: `tests/effects.rs`, `tests/app_fresh.rs`

- [ ] **Step 1: Write failing tests:** the existing `tests/effects.rs` cases (email, webhooks, SQLite rows for a CLI and a server) run with `--build` the Mojo front door and match; `cli_cases_start_from_the_fresh_snapshot` against the Mojo build.
- [ ] **Step 2:** Run `cargo test --test effects --test app_fresh`. Expected: FAIL where paths still say `rust/`.
- [ ] **Step 3:** Fix the paths and any sink variable names (`MOJO_ANYTHING_SMTP_SINK`, `MOJO_ANYTHING_HTTP_SINK`).
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `test: side effects and fresh state through the Mojo front door`.
