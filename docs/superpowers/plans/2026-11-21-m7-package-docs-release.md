# Milestone 7: Packaging, agent integration, docs and the Phase 1 release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gated Mojo ports become installable packages for every bridge; the MCP server, `setup`, `doctor`, plugin, skill, npm wrapper and website describe and run mojo-anything; every number in the docs is measured on Mojo; Phase 1 ends with the tag `v0.1.0`.

**Architecture:** `src/package.rs` keeps its shape (writes files and GitHub workflows, never builds for other platforms, never publishes) with one generator per Mojo bridge. Agent integration keeps the MCP protocol code and changes names, tool descriptions and prompts. Docs are rewritten from measurements taken in this milestone, not edited from rust-anything's text.

**Tech Stack:** Rust 2024 (the tool), Mojo via pixi, Python wheels (`pip wheel`, `auditwheel`/`delocate`), npm, RubyGems, Go modules, GitHub Actions on Linux and macOS, the Void/Vite website in `website/`.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` ("build, gate, package", "Naming", "Non-goals": Android and native Windows; "Anti-goals": claims not measured on Mojo; "Decided by the user": public repository).

Assumes Milestones 1–6 have landed: every source language bridges to Mojo, whole apps front-door, wire and lift in Mojo, `crate::mojo::{MOJO_VERSION, available, command, missing_message}` and `gate::mojo_checks` exist.

## Global Constraints

- All work and tests run in the WSL clone `~/github/mojo-anything`; Mojo from the pinned pixi environment (`crate::mojo::MOJO_VERSION`).
- Platforms for every package and release asset: `linux-x64`, `linux-arm64`, `darwin-arm64` (and `darwin-x64` only if the pinned Mojo ships for it; check the pixi channel). No Windows asset; no Android.
- `package` writes files only: no build for other platforms, no publish. Publishing, pushing tags and registry submissions are outward-facing: ask the user in chat before each one and wait for a yes.
- Names: package/binary `mojo-anything`; MCP server `io.github.tokarzewski/mojo-anything`; skill folder `skills/mojo-anything`; package stamp `mojo-anything-package.json`, schema `mojo-anything/package@1`.
- Every number in the docs is measured in this milestone: say what was run, on what hardware with its core count, the Mojo version and date, the result, and the slow cases; run benchmarks twice on a quiet machine (pitfalls, "Numbers and claims"). No figure carries over from rust-anything.
- Language lines list English first; translations stay removed until the English text settles (spec Non-goals).
- Before each commit: `cargo fmt --all`, `cargo clippy --all-targets -- -D warnings`, `cargo test`; update `docs/STATUS.md` when what works changes. Prose in UK English. Run `scripts/check-secrets.sh` before every commit that touches manifests or docs.

## Review Focus

1. **A wheel installed where the pinned Mojo runtime is absent.** The Mojo extension links Mojo runtime libraries; a wheel installed into a plain CPython (no pixi) must import, or the package must declare the runtime dependency and fail with a clear message. Test: Task 1 `wheel_imports_in_clean_venv`.
2. **Platform without a binary** (Windows, Intel macOS when not shipped). The npm loader and Python package must fall back to the original or say plainly that the platform is not supported, never crash on a missing file. Test: Task 2 `npm_loader_falls_back_on_unsupported_platform`, Task 1 `python_package_unsupported_platform_message`.
3. **`setup` on a machine with existing agent configs.** Only `mojo-anything` entries are added or replaced; an old `rust-anything` entry is left alone (it is another tool); a file that does not parse is untouched. Test: Task 4 `setup_keeps_rust_anything_entry`.
4. **`doctor` on native Windows.** It must report that Mojo needs Linux or macOS and point at WSL, as one failed check with a fix, not crash looking for `pixi`. Test: Task 4 `doctor_on_windows_points_at_wsl`.
5. **A docs number without a source.** Every number in `README.md`, `docs/STATUS.md`, `docs/real-world*.md` and the website must trace to a measurement log committed in this milestone. Test: Task 6 `docs_numbers_have_sources` (script).

---

### Task 1: Python wheels for Mojo ports

**Files:**
- Modify: `src/package.rs` (`Platform`, `PLATFORMS`, the `mojo-py` branch of `package`, `python_module`, stamp constants)
- Create: `src/package_mojo_py.rs` (pyproject, build backend config, workflow), `.github/` template string inside it
- Test: `tests/package.rs`

**Interfaces:**
- Consumes: `Options`, `Outcome` unchanged; `harness_mojo_py::build`; `codegen_py::package_init`.
- Produces:
  - `pub const PLATFORMS: &[Platform]` — the platforms in Global Constraints only.
  - `pub(crate) fn python_project(m: &Manifest, version: &str) -> Vec<(String, String)>` — a `pyproject.toml` (importable under the original's module name, `python_module(m)`), the package folder with `__init__.py`, `_native.so` copied from the build, and the Mojo runtime libraries the `.so` needs (found with `ldd`/`otool -L` against the pixi environment), vendored and their rpath set; declares `requires-python` from the recording's Python.
  - `pub(crate) fn wheels_workflow(m: &Manifest) -> String` — GitHub workflow building the wheel per platform with pixi, then `auditwheel repair` (Linux) or `delocate-wheel` (macOS).

- [ ] **Step 1: Write failing tests** in `tests/package.rs` (skip without Mojo):
  - `python_package_is_named_like_the_original` (replaces `python_package_is_a_maturin_project_named_like_the_original`): the project imports as the original module and lists only the supported platforms.
  - `wheel_imports_in_clean_venv`: build the host wheel with `pip wheel`, install it into a fresh `python3 -m venv` with no pixi on `PATH`, import it and replay the unit's cases: all match.
  - `python_package_unsupported_platform_message`: with `_native.so` removed, importing raises `ImportError` whose message names the supported platforms.
- [ ] **Step 2:** Run `cargo test --test package python`. Expected: FAIL.
- [ ] **Step 3:** Implement. If the Mojo runtime cannot be vendored (licence or size), declare the `max`/`mojo` runtime wheel as a dependency instead, and say which in `docs/packaging.md` and `DECISIONS.md`.
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: package Mojo Python extensions as wheels`.

### Task 2: npm, gem and Go packages

**Files:**
- Create: `src/package_mojo_ffi.rs` (npm per-platform packages with the Node-API shim and the Mojo shared library; gem with the Fiddle wrapper and the shared library per platform; Go module with the cgo wrapper and prebuilt libraries)
- Modify: `src/package.rs` (dispatch per `Kind`; delete the napi-rs and wasm-bindgen generators), `docs/packaging.md`
- Test: `tests/package.rs`

**Interfaces:**
- Produces:
  - `pub(crate) fn npm_packages(m: &Manifest, version: &str, fallback: Option<&str>) -> Vec<(String, String)>` — a main package whose loader picks `<name>-<platform>` from `optionalDependencies` and falls back to `fallback` (the original JS) when none fits; one package per platform holding the shim `.node` and the Mojo library.
  - `pub(crate) fn gem(m: &Manifest, version: &str) -> Vec<(String, String)>` — one platform gem per platform plus a pure-Ruby gem that loads the original.
  - `pub(crate) fn go_module(m: &Manifest, version: &str) -> Vec<(String, String)>` — module with `//go:build` constraints per platform and the libraries under `lib/<platform>/`.
  - One workflow per kind, building on the supported platforms only.

- [ ] **Step 1: Write failing tests:**
  - `npm_package_installs_from_tarballs_and_falls_back_to_the_original` (kept name; now with the Mojo library): `npm pack` each package, install the tarballs into a scratch project, replay the cases: all match; uninstall the platform package: calls reach the original.
  - `npm_loader_falls_back_on_unsupported_platform`: loader run with `process.platform` stubbed to `win32` loads the fallback, and without a fallback throws an error naming the supported platforms (replaces `napi_package_without_a_fallback_says_so`).
  - `gem_installs_and_replays`: `gem build`, `gem install --local`, replay the Ruby unit's cases.
  - `go_module_replays`: `go test` in a scratch module with a `replace` to the package folder runs the Go unit's cases.
- [ ] **Step 2:** Run `cargo test --test package npm gem go_module`. Expected: FAIL.
- [ ] **Step 3:** Implement; remove `wasm_package_needs_a_build` and the wasm generator unless Milestone 4 retargeted `--kind wasm` (then keep it, packaging the Mojo wasm).
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: package Mojo ports for npm, RubyGems and Go`.

### Task 3: MCP server and prompts

**Files:**
- Modify: `src/mcp.rs` (`TOOL_META` descriptions, server info, `FAILURES` fixes that name cargo/clippy), `src/mcp_prompts.rs` (`SKILL`, `WHOLE_APP` from `skills/mojo-anything/`), `skills/mojo-anything/SKILL.md`, `skills/mojo-anything/whole-app.md` (rewritten for Mojo: `port.mojo`, `mojo/app`, `mojo_checks`, `docs/mojo-notes.md`)
- Test: unit tests in `src/mcp.rs`; `tests/plugin.rs`

**Interfaces:**
- Produces: `tools/list` returns the same tool names (`analyze`, `bridge`, `record`, `build`, `diff`, `gate`, `bench`, `fuzz`, `profile`, `shadow`, `package`, `map`, `refresh`, `app_record`, `app_replay`, `app_front_door`, `app_wire`, `app_lift`); no description or prompt mentions Rust, cargo, clippy, napi, PyO3 or `port.rs`.

- [ ] **Step 1: Write failing tests:** `tool_descriptions_name_mojo` (no tool description matches `(?i)\b(rust|cargo|clippy|napi|pyo3|port\.rs)\b`; each porting tool mentions Mojo); `prompts_come_from_mojo_skill` (`prompts/get` of the skill prompt returns text starting with the first line of `skills/mojo-anything/SKILL.md`); `initialize_names_server` (`serverInfo.name == "mojo-anything"`).
- [ ] **Step 2:** Run `cargo test mcp`. Expected: FAIL.
- [ ] **Step 3:** Rewrite descriptions, failure fixes and the skill. Keep every pitfall-derived rule in the skill that still applies to Mojo; drop those about cargo, clippy and Android.
- [ ] **Step 4:** Run again; drive the server once over stdio (`initialize`, `tools/list`, `tools/call analyze` on `tests/fixtures/python`) and check stdout holds only JSON-RPC lines (pitfall: child output corrupted the stream).
- [ ] **Step 5: Commit** `feat: the MCP server and skill speak Mojo`.

### Task 4: `setup` and `doctor`

**Files:**
- Modify: `src/setup.rs` (`NAME`, `SKILL`), `src/doctor.rs` (checks: `pixi`, the pinned Mojo, CPython, each language runtime with Java ≥ 22, the agent setups, the MCP server; drop cargo-as-required, Visual Studio Build Tools, the NDK)
- Test: unit tests in `src/setup.rs`, `src/doctor.rs`; `tests/doctor.rs`

**Interfaces:**
- Produces:
  - `pub const NAME: &str = "mojo-anything"`.
  - `doctor` `Check` rows named `pixi`, `mojo`, `python`, `node`, `go`, `ruby`, `java`, `kotlinc`, `php`, `dotnet`, `mcp`, and one per agent; `mojo` is required, language runtimes optional; on Windows (`cfg!(windows)`), `pixi` and `mojo` fail with fix `use the WSL clone: wsl -d Ubuntu-24.04 --cd ~/github/mojo-anything`.
  - `parse_java_version` grading uses minimum `Version(22, 0, 0)`.

- [ ] **Step 1: Write failing tests:**
  - `setup_keeps_rust_anything_entry`: a Claude config holding a `rust-anything` MCP entry gets a `mojo-anything` entry added and the `rust-anything` one unchanged; `--remove` removes only `mojo-anything`.
  - `doctor_on_windows_points_at_wsl`: the check builder called with `windows = true` returns failed `pixi` and `mojo` rows whose fix contains `wsl -d Ubuntu-24.04`.
  - `java_21_is_too_old`: `grade(true, Some(Version(21,0,4)), Some(Version(22,0,0)))` is a failure with a fix naming Java 22.
  - `doctor_json_lists_every_check_with_a_fix_for_each_problem` (kept) with the new row names.
- [ ] **Step 2:** Run `cargo test setup doctor && cargo test --test doctor`. Expected: FAIL.
- [ ] **Step 3:** Implement; make the platform a parameter of the check builder so the Windows path is testable on Linux.
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: setup and doctor for mojo-anything`.

### Task 5: Plugin, npm wrapper, MCP registry entry and release workflow

**Files:**
- Modify: `plugin/` (skill path `plugin/skills/mojo-anything`, MCP command), `npm/mojo-anything/` (renamed from `npm/rust-anything/`: `package.json`, `bin/` launcher downloading the release asset for the supported platforms, clear error elsewhere), `server.json` (name `io.github.tokarzewski/mojo-anything`, repository `https://github.com/Tokarzewski/mojo-anything`, npm identifier `mojo-anything`, version), `.github/workflows/release.yml` (matrix: the platforms in Global Constraints; no Windows), `.github/workflows/ci.yml` (Linux and macOS jobs with pixi; the Windows job removed), `Cargo.toml` version `0.1.0`
- Test: `tests/plugin.rs`; `tests/tools.rs`

- [ ] **Step 1: Write failing tests:** `the_plugin_ships_the_same_skill_and_mcp_server` and `the_plugin_version_is_the_crate_version` (kept, new paths); `server_json_matches_crate` (name, version and npm identifier agree with `Cargo.toml`); `npm_launcher_rejects_windows` (the launcher run with `process.platform = 'win32'` exits non-zero with a message naming WSL).
- [ ] **Step 2:** Run `cargo test --test plugin --test tools`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again; `actionlint` on the two workflows if installed. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `chore: plugin, npm wrapper, registry entry and workflows for mojo-anything`.

### Task 6: Measured docs

**Files:**
- Create: `docs/measurements/2026-<mm>-<dd>-<run>.md` (one log per measured run: command, hardware and cores, Mojo version, date, output), `scripts/check-doc-numbers.py`
- Modify: `README.md`, `docs/STATUS.md`, `docs/real-world.md`, `docs/real-world-languages.md`, `docs/how-it-works.md`, `docs/whole-apps.md`, `docs/packaging.md`, `docs/install.md`, `docs/faq.md`, `docs/tools.md`, `docs/examples.md`, `docs/privacy.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`; delete `docs/assets/prettier.gif` and the Rust crab logo (replace with a plain text heading until there is art)
- Test: `scripts/check-doc-numbers.py` run by `cargo test` through `tests/tools.rs`

- [ ] **Step 1: Write the failing check** `docs_numbers_have_sources`: `scripts/check-doc-numbers.py` lists every number with a unit or ratio (`x faster`, `ms`, `%`, `n/n`, `req/s`, MB) in the files above and fails unless the same paragraph links a file under `docs/measurements/`. Wire it into `tests/tools.rs`.
- [ ] **Step 2:** Run `cargo test --test tools docs_numbers`. Expected: FAIL (rust-anything numbers have no logs).
- [ ] **Step 3:** Re-run on Mojo, twice each on a quiet machine: every real-world unit verified in Milestones 1–6 (`diff` counts), `bench` for each, the lifted CLI from Milestone 6, the server numbers from Milestone 6's spike with in-process handler time beside them. Commit each log.
- [ ] **Step 4:** Rewrite the docs from the logs: what works, how it was checked, the slow cases. Remove every rust-anything claim not re-measured. `README.md` says Linux and macOS (Windows through WSL).
- [ ] **Step 5:** Run the check again. Expected: PASS; full gate; `rg -n -i "rust-anything|cargo add|clippy|napi|pyo3|crate" README.md docs/*.md` finds only history notes in `CHANGELOG.md` and upstream credit lines.
- [ ] **Step 6: Commit** `docs: rewrite for Mojo from measured runs`.

### Task 7: Website

**Files:**
- Modify: `website/pages/en/**`, `website/pages/layout.tsx`, `website/content/cli-help.json` (regenerated from `mojo-anything --help` of every subcommand), `website/components/**` where they name rust-anything, `.github/workflows/website.yml` (deploy target only after the user names it)
- Delete: `website/pages/{az,de,fr,ja,kk,ko,ky,pt,ru,tk,tr,tt}/` and any other translated page folders
- Test: `cd website && npm ci && npm run build`

- [ ] **Step 1: Write the failing check** in `tests/tools.rs` `cli_help_json_is_current`: `website/content/cli-help.json` equals the help text the binary prints for every subcommand.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Regenerate the help file; rewrite the English pages from the Task 6 docs (no number that `check-doc-numbers.py` would reject); delete translated pages.
- [ ] **Step 4:** `npm run build` in `website/`. Expected: exit 0. Open the built pages in the browser pane and check every page renders and links resolve.
- [ ] **Step 5: Commit** `docs: website for mojo-anything`.

### Task 8: DECISIONS, pitfalls and the Phase 1 tag

**Files:**
- Modify: `DECISIONS.md` (every decision of the spec and Milestones 1–7 with its reason; superseded rust-anything entries marked so), `docs/pitfalls.md` (rules that only apply to Rust or Android removed; Mojo pitfalls from Milestones 1–7 present), `CHANGELOG.md` (`0.1.0`), `docs/STATUS.md` ("Phase 1 complete" line with date)

- [ ] **Step 1:** Check the spec's "Phase 1 done when": every source language's fixture loop passes with Mojo ports on Linux and macOS CI; `colorsys.py`, Go `path`, `shellwords.rb`, one ffmpeg unit and vercel/ms re-verified; one CLI lifted. Run the full CI workflow on the branch and read its result; list anything missing as a blocker and stop if any.
- [ ] **Step 2:** Update the four files.
- [ ] **Step 3:** Full gate; `scripts/check-secrets.sh`; `git diff --cached` checked for `/Users/` and `/home/`.
- [ ] **Step 4: Commit** `chore: release 0.1.0`.
- [ ] **Step 5:** Ask the user in chat to approve, one at a time: pushing `main` and tag `v0.1.0` to `origin`; letting the release workflow publish the binaries and the npm package; submitting `server.json` to the MCP Registry. Do each only after its yes, then report what was published and where.
- [ ] **Step 6:** Record `refs/tags/v0.1.0` and its commit hash in `docs/STATUS.md` as the binary Phase 2 records (spec, "Where the work happens").
