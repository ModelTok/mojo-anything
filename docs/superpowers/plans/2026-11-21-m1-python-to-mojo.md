# Milestone 1: Python to Mojo, end to end — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The (still Rust) tool, renamed mojo-anything, bridges a Python unit to a Mojo port, builds it as a Python extension module, replays the recording against it and gates it; proven on CPython's `colorsys.py` (2,400/2,400).

**Architecture:** A new bridge kind `mojo-py` replaces PyO3. `bridge` writes `mojo/<unit>/` with `port.mojo` (stubs), `_native.mojo` (the Python extension built with Mojo's Python bindings), `pixi.toml` and the unchanged Python wrapper package. Recording and the Python driver stay as they are: the driver imports `_native` whether Rust or Mojo built it.

**Tech Stack:** Rust 2024 (the tool), Mojo via pixi (the ports), CPython 3.x, WSL Ubuntu 24.04.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` (Phase 1, Python row of "Bridge per source language", "build, gate, package", "Naming").

This is the first of several plans. The rest are listed under "Later plans" at the end.

## Global Constraints

- All work and tests run in the WSL clone `~/github/mojo-anything` (Ubuntu 24.04), never `/mnt/c`.
- Mojo comes from pixi, pinned in a committed `pixi.toml` and `pixi.lock`; generated units pin the same version (one constant, `crate::mojo::MOJO_VERSION`).
- Verify every Mojo API against the pinned stdlib source before using it; record the confirmed spellings in `docs/mojo-notes.md` (Task 1) and generate code only from those.
- Names: binary and package `mojo-anything`; manifest `mojo-anything.json`; schema `mojo-anything/bridge@1`; work folder `.mojo-anything`; generated folder `mojo/`; environment variables `MOJO_ANYTHING_*`.
- Before each commit: `cargo fmt --all`, `cargo clippy --all-targets -- -D warnings`, `cargo test`; update `docs/STATUS.md` when what works changes.
- Tests that need Mojo skip with a printed reason when `crate::mojo::available()` is false, as Kotlin tests do when `kotlinc` is missing.
- Generated helpers are emitted only when the unit uses them (pitfall: unused helpers failed the gate).
- Prose in UK English.

## Review Focus

1. **Python ints and floats in one parameter.** `number` in the Python dialect is int-or-float; `9007199254740992`, `-0` and int-only arithmetic must replay exactly (`{"$num": "-0"}` cases in colorsys). Test: Task 5 `py_num_keeps_int_and_float`, Task 8 the 2,400 cases.
2. **Errors raised by the port.** A recorded `{"error": ...}` names a Python exception type and message; a Mojo `raise` must surface as that type and message, not a generic `Exception`. Test: Task 6 `mojo_py_error_type_replays`.
3. **No Mojo on the machine** (native Windows, fresh WSL). `build` and `gate` must stop with one line naming the missing `pixi`/`mojo` and the WSL clone, not a spawn error. Test: Task 1 `missing_mojo_message`.
4. **Stale extension module.** After editing `port.mojo`, `build` must rebuild and `diff` must load the new `_native` (pitfall: a benchmark timed a stale binary). Test: Task 6 `mojo_py_rebuild_after_edit`.
5. **Package names with hyphens or dots** (`colorsys-pkg`). The Python package and `PyInit__native` must still match. Test: Task 5 `lib_mojo_names_for_hyphenated_unit`.

---

### Task 0: Working clone and baseline

**Files:** none in the repository.

- [ ] **Step 1:** Ask the user to confirm creating the public GitHub repository `Tokarzewski/mojo-anything` (outward-facing); on yes, `gh repo create Tokarzewski/mojo-anything --public`, set it as `origin`, keep `upstream` (erkamyaman/rust-anything), and rename the old `origin` to `fork`.
- [ ] **Step 2:** In WSL: `git clone https://github.com/Tokarzewski/mojo-anything ~/github/mojo-anything`; install rustup stable, Node, Python 3, Go, Ruby, Java 22+ (what CI installs today) and pixi.
- [ ] **Step 3:** Run `cargo test` there. Expected: passes, with only the skips already documented in `docs/STATUS.md` ("Where the tests run"). Record failures that exist before any change in the Task 0 commit message of Task 1.

### Task 1: Pinned Mojo toolchain and a probe

**Files:**
- Create: `pixi.toml`, `pixi.lock`, `src/mojo.rs`, `tests/fixtures/mojo-probe/_native.mojo`, `tests/mojo_toolchain.rs`, `docs/mojo-notes.md`
- Modify: `src/lib.rs` (add `pub mod mojo;`), `.github/workflows/*` (add a Linux job that installs pixi; drop the Windows job)

**Interfaces:**
- Produces:
  - `pub const MOJO_VERSION: &str` — the pinned version string, same as `pixi.toml`.
  - `pub fn available() -> bool` — `pixi` on PATH and `pixi run mojo --version` succeeds in the repository's environment.
  - `pub fn command(project: &Path) -> Result<Command>` — `pixi run --manifest-path <project>/pixi.toml mojo`, stdin closed via `crate::process`; errors with `missing_message()` when unavailable.
  - `pub fn missing_message() -> String` — one line: what is missing and that Mojo runs only on Linux and macOS (use the WSL clone).

- [ ] **Step 1: Write the probe.** `_native.mojo` is a Python extension module `_native` with `add(a, b)` returning their float sum and `fail(msg)` raising `ValueError(msg)`, written against the pinned stdlib's Python-bindings API.
- [ ] **Step 2: Write the failing tests** in `tests/mojo_toolchain.rs`:
  - `probe_builds_and_imports`: build the probe with `--emit shared-lib -o <tmp>/_native.so`, then `python3 -c "import _native; print(_native.add(1.5, 2))"` with `PYTHONPATH=<tmp>` prints `3.5`.
  - `probe_raises_value_error`: `_native.fail('x')` raises `ValueError` with message `x`.
  - `missing_mojo_message`: with `PATH` emptied, `command(..)` fails and the message contains `pixi` and `Linux and macOS`.
- [ ] **Step 3:** Run `cargo test --test mojo_toolchain`. Expected: FAIL (`mojo` module missing).
- [ ] **Step 4:** Implement `src/mojo.rs`; pin Mojo in `pixi.toml`.
- [ ] **Step 5:** Run again. Expected: PASS in WSL; on a machine without pixi, the two build tests print a skip and `missing_mojo_message` passes.
- [ ] **Step 6: Write `docs/mojo-notes.md`:** the confirmed spellings for the extension-module entry point, adding a function, converting `PythonObject` to and from `Float64`/`Int`/`String`/`Bool`/`List`, raising a Python exception of a given type, the build command, the format-check command, the warnings-as-errors flag and the test command — each with the stdlib file it was checked against.
- [ ] **Step 7: Commit** `feat: pin Mojo with pixi and probe the Python extension route`.

### Task 2: Rename to mojo-anything

**Files:**
- Modify: `Cargo.toml` (package and bin `mojo-anything`), `src/bridge.rs` (`MANIFEST`, `SCHEMA`), `src/harness.rs` and `src/harness_py.rs` (`WORK_DIR`), every `RUST_ANYTHING_*` name in `src/` and generated drivers, `src/mcp.rs` (server name), `src/setup.rs`, `src/doctor.rs`, `plugin/`, `skills/`, `npm/`, `server.json`, `README.md`, `CLAUDE.md`
- Delete: `docs/README_*.md` (18 translations) and the language line in `README.md`
- Test: existing tests, updated

**Interfaces:**
- Produces: the names in Global Constraints. `Manifest::load` also accepts an old `rust-anything.json` and says it was renamed, so existing demos still load until they are regenerated.

- [ ] **Step 1: Write the failing test** `version_names_the_tool` in `tests/tools.rs`: `mojo-anything --version` stdout starts with `mojo-anything `.
- [ ] **Step 2:** Run it. Expected: FAIL (binary not found).
- [ ] **Step 3:** Rename. Leave the code that generates Rust alone apart from these names; the generators are replaced one by one in this plan and the later ones.
- [ ] **Step 4:** Add `loads_old_manifest_name` in `src/bridge.rs` tests: a folder with only `rust-anything.json` loads.
- [ ] **Step 5:** `cargo fmt --all && cargo clippy --all-targets -- -D warnings && cargo test`. Expected: PASS, same skips as the baseline.
- [ ] **Step 6:** `rg -n "rust-anything|RUST_ANYTHING" src tests plugin skills npm` lists only the `loads_old_manifest_name` path and upstream links; check the remainder by hand.
- [ ] **Step 7: Commit** `chore: rename the tool to mojo-anything`.

### Task 3: The `mojo-py` kind and Mojo types

**Files:**
- Modify: `src/bridge.rs` (`Kind`, `RType`), `src/analyze.rs` (`Bridge`)
- Test: unit tests in the same files

**Interfaces:**
- Produces:
  - `Kind::MojoPy`, serialised `"mojo-py"`; `Bridge::MojoPy` shown as `Mojo (Python extension)`; `Lang::Python` maps to it.
  - `RType::mojo(&self, lang: Lang) -> String`: `Str→String`, `F64→Float64`, `Int→Int`, `Bool→Bool`, `Unit→None`, `Vec(t)→List[t]`, `Opt(t)→Optional[t]`, `Json→PythonObject`; for `Lang::Python`, `F64` (the dialect's `number`) is `PyNum`.

- [ ] **Step 1: Write failing tests** `mojo_types_from_ts` (each mapping above, including `Vec(Opt(Str))→List[Optional[String]]`) and `python_bridges_to_mojo_py` (`analyze` on `tests/fixtures/python` reports `Mojo (Python extension)`).
- [ ] **Step 2:** Run `cargo test mojo_types_from_ts python_bridges_to_mojo_py`. Expected: FAIL.
- [ ] **Step 3:** Implement. Keep `Kind::Pyo3` until Task 9.
- [ ] **Step 4:** Run again. Expected: PASS; then the full gate (fmt, clippy, test).
- [ ] **Step 5: Commit** `feat: add the mojo-py bridge kind and Mojo type mapping`.

### Task 4: `port.mojo` stubs and reading them back

**Files:**
- Create: `src/codegen_mojo.rs`
- Modify: `src/lib.rs`
- Test: unit tests in `src/codegen_mojo.rs`

**Interfaces:**
- Consumes: `Manifest`, `RType::mojo` (Task 3), `codegen::{PortApi, PortFn, PortClass}`.
- Produces:
  - `pub fn port_mojo(m: &Manifest) -> String` — one `def <name>(<params>) raises -> <ret>:` per export, body `raise Error("not ported: <name>")`; classes as `struct <Name>` with `def __init__` and methods. Helpers are private by Mojo convention (leading underscore).
  - `pub fn parse_port_mojo(source: &str) -> PortApi` — reads top-level `def`s and `struct`s without a leading underscore; `PortFn.rust_name` holds the Mojo name; `ret` is `None` for no return; `fallible` is true when the `def` has `raises`.
  - `pub const STUB_MARK: &str = "not ported: "`.

- [ ] **Step 1: Write failing tests:**
  - `stubs_round_trip`: for a manifest with `rgb_to_yiq(r: number, g: number, b: number) -> unknown`, `parse_port_mojo(&port_mojo(&m))` gives one `PortFn` named `rgb_to_yiq` with params `[("r","PyNum"),("g","PyNum"),("b","PyNum")]`, `ret == "PythonObject"`, `fallible`.
  - `private_helpers_are_not_api`: a source with `def _clamp(x: Float64) -> Float64:` and a public `def f()` yields only `f`.
  - `multiline_signature`: a `def` whose parameters span three lines parses.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement with a line-based reader (signatures only; no Mojo parser dependency).
- [ ] **Step 4:** Run. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: generate and read Mojo port stubs`.

### Task 5: The Python extension module in Mojo

**Files:**
- Create: `src/codegen_mojo_py.rs`, `src/mojo/py_num.mojo` (helper source, embedded with `include_str!`)
- Modify: `src/codegen_py.rs` (make `package_init` independent of PyO3; it already only imports `_native`)
- Test: unit tests in `src/codegen_mojo_py.rs`; `tests/mojo_py_helpers.rs`

**Interfaces:**
- Consumes: `PortApi` (Task 4), `docs/mojo-notes.md` spellings (Task 1).
- Produces:
  - `pub fn native_mojo(m: &Manifest, api: &PortApi) -> String` — `_native.mojo`: the module init for `_native`, one binding per port function that converts each `PythonObject` argument to the port's type, calls `port.<name>`, converts the result back, and maps a raised error to the Python exception type it names (`TypeError: …`, `ValueError: …`; plain message → `Exception`).
  - `pub fn pixi_toml(m: &Manifest) -> String` — pins `MOJO_VERSION`.
  - `pub const PY_NUM_MOJO: &str` — `PyNum`: an int-or-float value with Python's `+ - * / // % **`, comparisons, `min`/`max`, `-0.0` kept, ints arbitrary-size via `PythonObject` when they leave `Int`'s range. Emitted into the unit only when some parameter or return is `PyNum`.
  - `pub fn needs_py_num(api: &PortApi) -> bool`.

- [ ] **Step 1: Write failing tests:**
  - `native_names_module_and_functions`: the output defines the init for `_native` and adds `rgb_to_yiq`.
  - `lib_mojo_names_for_hyphenated_unit`: for crate name `colorsys-pkg-mojo` the Python package is `colorsys_pkg_mojo` and the module is still `_native`.
  - `py_num_only_when_used`: a unit with only `String` parameters gets no `py_num.mojo`.
  - `py_num_keeps_int_and_float` (in `tests/mojo_py_helpers.rs`, skips without Mojo): a tiny extension using `PyNum` returns `3` (an `int`) for `1 + 2`, `3.5` for `1.5 + 2`, `-0.0` for `-0.0 * 1`, and `9007199254740993` for `9007199254740992 + 1`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: generate the Mojo Python extension module`.

### Task 6: Bridge, build and diff for `mojo-py`

**Files:**
- Create: `src/harness_mojo_py.rs`
- Modify: `src/bridge.rs` (`bridge`, `refresh` write `mojo/<unit>/`), `src/harness.rs` (dispatch `Kind::MojoPy` for build and the native file), `src/main.rs` (default output folder `mojo/`)
- Test: `tests/loop.rs` (new `python_mojo_*` tests), fixture `tests/fixtures/python-mojo-port/port.mojo`

**Interfaces:**
- Consumes: Tasks 1, 4, 5; `harness_py::{record, diff, package}` unchanged.
- Produces:
  - `pub fn build(unit_dir: &Path, m: &Manifest) -> Result<PathBuf>` — writes `python/<pkg>/_native.so` (`.so` on Linux and macOS alike, as CPython's loader accepts it) by running the pinned `mojo build _native.mojo --emit shared-lib`; the build folder is the unit's own `.mojo-anything/build`.
  - Bridge output: `mojo/<unit>/{port.mojo, _native.mojo, pixi.toml, mojo-anything.json, README.md, python/<pkg>/__init__.py}` plus `py_num.mojo` when needed.

- [ ] **Step 1: Write failing tests** in `tests/loop.rs` (skip without Mojo):
  - `python_mojo_bridge_files`: `bridge tests/fixtures/python <unit>` lists exactly the files above.
  - `python_mojo_loop_matches`: bridge, `record`, copy `tests/fixtures/python-mojo-port/port.mojo` over the stubs, `build`, `diff` → every case matches.
  - `python_mojo_wrong_port_mismatches`: same with one function returning a wrong value → `diff` reports that function's cases as mismatches.
  - `mojo_py_error_type_replays`: a fixture function that raises `ValueError("bad")` in Python, ported with a Mojo raise of `ValueError: bad`, replays as matching.
  - `mojo_py_rebuild_after_edit`: after a matching diff, edit the port to return a wrong value, `build`, `diff` → mismatches appear.
- [ ] **Step 2:** Run `cargo test --test loop python_mojo mojo_py`. Expected: FAIL.
- [ ] **Step 3:** Write the fixture port and implement.
- [ ] **Step 4:** Run. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: bridge, build and diff Python units as Mojo ports`.

### Task 7: The gate for Mojo ports

**Files:**
- Modify: `src/gate.rs` (`mojo_checks`, `fix_for`, dispatch on `Kind::MojoPy`)
- Test: unit tests in `src/gate.rs`; `tests/loop.rs` `python_mojo_gate_*`

**Interfaces:**
- Consumes: `crate::mojo::command`, `STUB_MARK`, the diff from Task 6.
- Produces: `pub fn mojo_checks(unit_dir: &Path) -> Vec<Check>` with checks named `mojo format`, `mojo build` (warnings are errors), `mojo test` (runs `test_*.mojo` when present; passes with "no tests" otherwise), `ported` (no `STUB_MARK` left), `unsafe` (each `abort(`, `UnsafePointer`/pointer use or `external_call` line has a `# SAFETY:` comment on it or the line above), then the existing API and replay checks. Each failed check has a `fix` naming the exact command.

- [ ] **Step 1: Write failing tests:**
  - `mojo_stub_count`: text with two `STUB_MARK` bodies counts 2; one without counts 0.
  - `mojo_unsafe_needs_reason`: `abort()` alone fails; with `# SAFETY: unreachable, x checked above` on the line above it passes.
  - `python_mojo_gate_passes` (skips without Mojo): the Task 6 matching unit passes every check.
  - `python_mojo_gate_fails_on_stub`: a freshly bridged unit fails `ported` with a fix mentioning `port.mojo`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: gate Mojo ports`.

### Task 8: colorsys, ported to Mojo

**Files:**
- Create: `demo/real-world/python-colorsys-mojo/` (bridged from CPython 3.13 `Lib/colorsys.py` as `src/colorsys_pkg/`, the same setup as `python-colorsys-rs`; manifest `root` is a placeholder — pitfall: local paths in committed manifests)
- Modify: `docs/STATUS.md` (Python row), `docs/real-world-languages.md`

- [ ] **Step 1:** Bridge and `record` with the same inputs as the Rust demo; check the case count is 2,400.
- [ ] **Step 2:** Port the six functions in `port.mojo` with `PyNum`.
- [ ] **Step 3:** `build`, `diff`. Expected: `2400/2400`.
- [ ] **Step 4:** `gate`. Expected: every check passes.
- [ ] **Step 5:** Update `docs/STATUS.md`: Python row "Verified", `colorsys.py` from CPython 3.13 (date of the run), `2,400/2,400; gate passes`, Mojo version named. Run `scripts/check-secrets.sh`.
- [ ] **Step 6: Commit** `feat: port CPython's colorsys to Mojo (2,400/2,400)`.

### Task 9: Remove PyO3

**Files:**
- Modify: `src/bridge.rs` (drop `Kind::Pyo3`; old manifests with `"pyo3"` load with an error that says to re-bridge), `src/codegen_py.rs` (keep `package_init` and the Python codec; delete `lib_rs`, `pyconv`, `pynum`), `src/codegen.rs`, `src/harness.rs`, `src/harness_py.rs` (`build` moves to `harness_mojo_py`), `src/front_door.rs`, `src/package.rs` (`mojo-py` packaging says "not yet: see the packaging plan" and exits non-zero), `DECISIONS.md`, `docs/pitfalls.md` (anything learned in Tasks 1–8)
- Delete: `demo/real-world/python-colorsys-rs/`
- Test: existing Python tests now run on `mojo-py`

- [ ] **Step 1: Write the failing test** `pyo3_manifest_says_rebridge`: loading a manifest with `"kind": "pyo3"` fails with a message containing `bridge again`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Remove PyO3 and point every Python test at `mojo-py`.
- [ ] **Step 4:** `cargo fmt --all && cargo clippy --all-targets -- -D warnings && cargo test`. Expected: PASS; `rg -n "pyo3|PyO3" src tests` finds only the error message and its test.
- [ ] **Step 5:** Update `DECISIONS.md` (Python bridges to Mojo through an extension module; why), `docs/STATUS.md` (`package` for Python: not yet).
- [ ] **Step 6: Commit** `refactor: drop PyO3; Python units port to Mojo only`.

---

## Later plans

All written; the order and what each assumes from the ones before it are in [README.md](README.md).
Revise a later plan when an earlier one lands differently from its Interfaces blocks.
