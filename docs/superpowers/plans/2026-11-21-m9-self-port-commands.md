# Milestone 9: the tool in Mojo, every command — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move every remaining subcommand from the Phase 1 Rust binary into the Mojo tool, port the Rust tests to Mojo, then delete all Rust: 0% fallback over the whole recording, CI green on Linux and macOS.

**Architecture:** Builds on M8's `tool/` package, front door, plumbing and `app replay`. Each task moves one command group: it ports the group's Rust modules to Mojo files under `tool/src/mojo_anything/`, ports the matching `#[test]`s, adds the commands to `OWNED`, and is accepted only when `app replay . --build tool/build/mojo-anything` passes every case and the fallback line shows none for that group. Source parsing (tree-sitter and oxc today) goes through Python's `tree_sitter` bindings and grammar wheels by Mojo's Python interop.

**Tech Stack:** Mojo via pixi, CPython (`tree_sitter`, `tree-sitter-{python,typescript,javascript,c,go,ruby,java,kotlin,php,c-sharp}` wheels pinned in `pixi.toml`, `re`, `tomllib`), the Phase 1 binary as fallback until Task 9.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` (Phase 2: Order steps 4–6, Libraries table, "Phase 2 done when").

Requires M8 (`2026-11-21-m8-self-port-foundation.md`) to be complete.

## Global Constraints

- Everything in M8's Global Constraints holds.
- Port by reading the Rust module and its tests, not by script translation alone; the recording is the judge (spec anti-goal).
- Generated code the tool writes (Mojo ports, Python packages, C shims, drivers in `.py`/`.mjs`/`.go`/`.rb`/`.java`) must be byte-identical to what the Phase 1 binary writes for the same case, after the recorded normalisers.
- Each task's group must keep working with the remaining Rust fallback for the other groups; no task may change the case set except by re-recording from the Phase 1 tag with a reason in `NORMALISERS.md`.
- Pitfalls in `docs/pitfalls.md` carry over where the mechanism survives; new ones are added in the task that finds them.

## Review Focus

1. **Parser differences hidden by tolerant tests.** tree-sitter TypeScript reads some constructs differently from oxc (decorators, `satisfies`, overloads, `export { a as b }`); `analyze` and `bridge` must produce the recorded exports exactly. Test: Task 1 `ts_export_list_and_overloads` and the full `analyze`/`bridge` replay.
2. **Large inputs through Python interop.** A 10 MB source file or a 200-deep doc tree must not hit Python's recursion limit or be slow enough to time out a case. Test: Task 1 `large_file_analyzes_within_limit`.
3. **A `record` that runs the original from the wrong place.** Crate and unit paths passed to children must be absolute (pitfall: relative crate path). Test: Task 2 `record_from_other_cwd`.
4. **An MCP child writing to stdout.** Any child's stdout goes to stderr or a pipe, never the MCP stream (pitfall). Test: Task 8 `mcp_child_output_stays_off_stream`.
5. **Deleting Rust that something still calls.** After lift, no script, workflow, plugin or npm wrapper may still name `cargo`, `Cargo.toml` or `target/`. Test: Task 9 `no_rust_left`.

---

### Task 1: `analyze` (every language)

**Files:**
- Create: `tool/src/mojo_anything/syntax.mojo` (tree-sitter through interop: load grammar, parse, walk nodes, node text and ranges in UTF-8 bytes and UTF-16 units), `ts/{discover,scan,exports,deps,jsdoc,shape,tsconfig}.mojo`, `lang/{python,go,ruby,java,kotlin,c,php,csharp}.mojo`, `analyze.mojo`, `whole_app.mojo`, `risks.mojo`, `error_paths.mojo`, `crates.mojo` (+ `crates.toml` read through `tomllib`), `tool/tests/test_analyze.mojo`
- Reference: `src/ts/*.rs`, `src/lang/*.rs`, `src/analyze.rs`, `src/whole_app.rs`, `src/risks.rs`, `src/error_paths.rs`, `src/crates.rs`, `tests/analyze.rs`, `tests/untyped_js_types.rs`, `tests/go_*.rs`, `tests/java_package_declaration.rs`

**Interfaces:**
- Produces: `fn parse(lang: String, source: String) raises -> Tree`; `Node` with `kind()`, `children()`, `child_by_field(name)`, `text()`, `start_byte()`, `end_byte()`; `fn exported_functions(path, source) -> List[ExportedFn]` and `ExportedFn`/`ExportedClass`/`LocalType`/`Param` with the field names of `src/ts/exports.rs` (they are serialised into `mojo-anything.json`); `fn run_analyze(p: Parsed) raises -> Int`.

- [ ] **Step 1: Port the tests** from the reference test files and the `#[test]`s in the reference modules; add `ts_export_list_and_overloads` (`export { a, b as c }`, overloaded `function f(x: string): string; function f(x: number): number;`, a decorator, `satisfies`) and `large_file_analyzes_within_limit` (a generated 10 MB `.ts` analysed under the case time limit). Run: FAIL.
- [ ] **Step 2:** Implement `syntax.mojo` first, then TS/JS (oxc's role), then each language in `src/lang/`.
- [ ] **Step 3:** Mojo tests pass; `app replay` passes every case; no `analyze` fallback.
- [ ] **Step 4: Commit** `feat(tool): analyze in Mojo over tree-sitter`.

### Task 2: `bridge`, `refresh`, `record` (Python first, then every language)

**Files:**
- Create: `tool/src/mojo_anything/bridge.mojo`, `codegen/{mojo,mojo_py,c,ffi,go,ruby,java,ts_shim,batch}.mojo` (ports of the Phase 1 generators as they stand after M1–M5), `harness/{core,py,c,go,ruby,java,kotlin}.mojo`, `pin.mojo`, `from_tests.mojo`, embedded driver sources under `tool/src/mojo_anything/drivers/`, `tool/tests/test_bridge.mojo`, `tool/tests/test_record.mojo`
- Reference: `src/bridge.rs`, `src/codegen*.rs`, `src/harness*.rs`, `src/pin.rs`, `src/from_tests.rs`, `src/recording.rs`, `tests/loop.rs`, `tests/recording.rs`, `tests/record_cwd.rs`, `tests/record_timeout.rs`, `tests/ruby_recording.rs`, `tests/c_*.rs`, `tests/float_files.rs`

**Interfaces:**
- Consumes: Task 1's `ExportedFn` family; M8's process, walk, JSON, recording.
- Produces: `fn run_bridge`, `fn run_refresh`, `fn run_record`; `Manifest` with `load(dir)`/`save(dir)` writing the same JSON as `bridge.rs`.

- [ ] **Step 1: Port the tests**, adding `record_from_other_cwd` (run `record` with a relative unit path from a different working directory; the original still runs). Run: FAIL.
- [ ] **Step 2:** Implement for Python; move `bridge`/`refresh`/`record` to `OWNED` for Python units only (dispatch by the manifest's `language`, falling back otherwise) and replay.
- [ ] **Step 3:** Repeat Step 2 for C, Go, Ruby, TS/JS, Java and Kotlin, replaying after each.
- [ ] **Step 4:** Mojo tests pass; no fallback for these three commands.
- [ ] **Step 5: Commit** `feat(tool): bridge, refresh and record in Mojo`.

### Task 3: `build`, `diff`, `gate`

**Files:**
- Create: `tool/src/mojo_anything/{build,diff,gate}.mojo`, `tool/tests/test_gate.mojo`
- Reference: `src/gate.rs`, `src/harness.rs` (build and diff halves), `src/harness_*.rs`, `src/tolerance.rs`, `tests/native.rs`, `tests/java_replay.rs`

**Interfaces:**
- Produces: `fn run_build`, `fn run_diff`, `fn run_gate`; `Check(name, passed, detail, fix)` serialised as `gate.rs` does.

- [ ] **Step 1: Port the tests.** Run: FAIL.
- [ ] **Step 2:** Implement; move the three commands to `OWNED`.
- [ ] **Step 3:** Mojo tests pass; `app replay` shows no fallback for them.
- [ ] **Step 4: Commit** `feat(tool): build, diff and gate in Mojo`.

### Task 4: `fuzz`, `profile`, `bench`

**Files:**
- Create: `tool/src/mojo_anything/{fuzz,profile,bench}.mojo`, `tool/tests/test_fuzz.mojo`
- Reference: `src/fuzz.rs`, `src/profile.rs`, `src/harness.rs` (bench), `tests/fuzz.rs`

**Interfaces:**
- Produces: `fn run_fuzz`, `fn run_profile`, `fn run_bench`. The fuzz seed sequence must equal Rust's for a given `--seed` (port the generator exactly, not a library's).

- [ ] **Step 1: Port the tests**, adding `same_seed_same_inputs` (seed 7 gives the inputs the Rust binary recorded). Run: FAIL.
- [ ] **Step 2:** Implement; bench timing lines are masked by the recorded normalisers, counts and case names are not.
- [ ] **Step 3:** Tests pass; no fallback for the group.
- [ ] **Step 4: Commit** `feat(tool): fuzz, profile and bench in Mojo`.

### Task 5: `shadow` and `package`

**Files:**
- Create: `tool/src/mojo_anything/{shadow,package}.mojo`, `tool/tests/test_package.mojo`
- Reference: `src/shadow.rs`, `src/package.rs`, `tests/package.rs`

- [ ] **Step 1: Port the tests.** Run: FAIL.
- [ ] **Step 2:** Implement; generated workflow and package files byte-identical to the recording.
- [ ] **Step 3:** Tests pass; no fallback for the group.
- [ ] **Step 4: Commit** `feat(tool): shadow and package in Mojo`.

### Task 6: `app front-door`, `app wire`, `app lift`, libraries and servers

**Files:**
- Create: `tool/src/mojo_anything/app/{front_door,front_door_http,wire,lift,library}.mojo`, `tool/tests/test_front_door.mojo`
- Reference: `src/front_door.rs`, `src/front_door_http.rs`, `src/wire.rs`, `src/lift.rs`, `src/library.rs`, `tests/library.rs`, `tests/http.rs` (front-door half)

- [ ] **Step 1: Port the tests.** Run: FAIL.
- [ ] **Step 2:** Implement; the Mojo front doors the tool generates (from M5) are byte-identical to the recording.
- [ ] **Step 3:** Tests pass; no fallback for `app front-door`, `app wire`, `app lift`.
- [ ] **Step 4: Commit** `feat(tool): front door, wire and lift in Mojo`.

### Task 7: Port the remaining Rust tests

**Files:**
- Create: `tool/tests/test_tools.mojo`, `tool/tests/test_plugin.mojo`, `tool/tests/test_doctor_cli.mojo`
- Reference: `tests/tools.rs`, `tests/plugin.rs`, `tests/doctor.rs`, `tests/common/`, every `#[cfg(test)]` module not yet ported

- [ ] **Step 1:** List every `#[test]` in `src/` and `tests/` (`rg -n "#\[test\]"`), and every Mojo test; write the mapping to `tool/tests/PORTED.md` (Rust test → Mojo test, or "covered by app case <name>" with the case named, or "dropped: Android" for `tests/android_device.rs`).
- [ ] **Step 2:** Port each unmapped test. Run them: they pass against the Mojo binary.
- [ ] **Step 3: Commit** `test(tool): every Rust test has a Mojo counterpart`.

### Task 8: The MCP server

**Files:**
- Create: `tool/src/mojo_anything/{mcp,mcp_prompts}.mojo`, `tool/tests/test_mcp.mojo`
- Reference: `src/mcp.rs`, `src/mcp_prompts.rs`

**Interfaces:**
- Produces: `fn run_mcp() raises -> Int` — newline-delimited JSON-RPC 2.0 on stdio: `initialize`, `tools/list`, `tools/call`, `prompts/list`, `prompts/get`, `ping`, progress and cancellation, the same tool list and schemas as `mcp.rs`; each tool calls the Mojo command function in process.

- [ ] **Step 1: Port the protocol test** from `src/mcp.rs`; add `mcp_child_output_stays_off_stream` (a tool call whose child prints to stdout leaves the stream valid JSON lines only). Run: FAIL.
- [ ] **Step 2:** Implement; move `mcp` to `OWNED`.
- [ ] **Step 3:** The recorded MCP sessions replay; whole recording now shows 0 fallbacks: `app replay . --build tool/build/mojo-anything` reports `fallback 0/<total>`.
- [ ] **Step 4: Commit** `feat(tool): MCP server in Mojo; no fallback left`.

### Task 9: Lift: delete the Rust

**Files:**
- Delete: `src/`, `tests/*.rs`, `tests/common/`, `Cargo.toml`, `Cargo.lock`, `target/`, `tool/fallback/` and `scripts/build-fallback.sh`, `tool/src/mojo_anything/fallback.mojo`
- Modify: `tool/src/main.mojo` (unknown subcommand is a usage error, not a fallback), `.github/workflows/*` (Linux and macOS: pixi install, build, Mojo tests, `app replay`), `hk.pkl`, `mise.toml`, `npm/` (download the Mojo binary), `plugin/`, `skills/`, `server.json`, `scripts/`, `CLAUDE.md` (the pre-finish commands become the Mojo ones), `README.md`, `docs/STATUS.md`, `DECISIONS.md`, `docs/pitfalls.md`
- Create: `tool/tests/test_no_rust.mojo`

- [ ] **Step 1: Write the failing test** `no_rust_left`: no `*.rs`, `Cargo.toml` or `Cargo.lock` in the repository, and no file outside `docs/` and `CHANGELOG.md` names `cargo `, `Cargo.toml` or `target/`. Run: FAIL.
- [ ] **Step 2:** Delete and update the files above.
- [ ] **Step 3:** From a fresh clone in WSL: `pixi install`, `pixi run build-tool`, `pixi run mojo test tool/tests`, `tool/build/mojo-anything app replay . --build tool/build/mojo-anything` — all pass, fallback line absent or 0.
- [ ] **Step 4:** Push the branch and confirm CI passes on Linux and macOS (pushing needs the user's go-ahead).
- [ ] **Step 5:** `docs/STATUS.md` and `DECISIONS.md`: the tool is Mojo; date, Mojo version, case count, 0% fallback.
- [ ] **Step 6: Commit** `refactor: the tool is Mojo; remove the Rust`.
