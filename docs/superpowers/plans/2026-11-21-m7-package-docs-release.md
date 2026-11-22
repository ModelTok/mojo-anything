# Milestone 7: Packaging, agent integration, docs and the Phase 1 release — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Gated Mojo ports become installable packages for every bridge; the MCP server, `setup`, `doctor`, plugin, skill, npm wrapper and website describe and run mojo-anything; every number in the docs is measured on Mojo; Phase 1 ends with the tag `v0.1.0`.

**Architecture:** `src/package.rs` keeps its shape (writes files and GitHub workflows, never builds for other platforms, never publishes) with one generator per Mojo bridge. Agent integration keeps the MCP protocol code and changes names, tool descriptions and prompts. Docs are rewritten from measurements taken in this milestone, not edited from rust-anything's text.

**Tech Stack:** Rust 2024 (the tool), Mojo via pixi, Python wheels (`pip wheel`, `auditwheel`/`delocate`), npm, RubyGems, Go modules, Java jars (FFM, Java 22+), GitHub Actions on Linux and macOS, the Void/Vite website in `website/`.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` ("build, gate, package", "Naming", "Non-goals": Android and native Windows; "Anti-goals": claims not measured on Mojo; "Phase 1 done when").

## Revision 2026-11-22 (after M1–M6 landed)

The plan was written before Milestones 1–6 ran. What they produced changes it as follows:

- **Starts after M5 is merged onto the M6 branch**, with the wasm bridge (`m4-wasm-bridge`) merged too. The bridge kinds then are `c-abi`, `ffi` (Go, Ruby), `mojo-py`, `mojo-node`, `mojo-wasm` and `mojo-jvm` (Java and Kotlin over FFM); JNI, Android and the binary wire are gone (M5 Task 7). Task 3 packages every one of them; the first draft had no `c-abi`, `mojo-wasm` or `mojo-jvm` package.
- **Repository and names.** The user asked (2026-11-21) for the finished repository to be pushed as a public repository in the ModelTok organisation. That replaces the spec's `Tokarzewski/mojo-anything` (spec, "Repository"): `https://github.com/ModelTok/mojo-anything`, MCP server `io.github.ModelTok/mojo-anything`. `server.json` today still names upstream's `erkamyaman`.
- **Nothing is pushed in M7.** `origin` of the WSL clone is the local Windows checkout, and the user's instruction is to publish once the whole port (M1–M9) is finished. Task 9 tags `v0.1.0` locally; pushing, the release workflow, npm and the MCP Registry wait for the final publish after M9, each asked for in chat.
- **macOS.** "Phase 1 done when" needs CI green on Linux and macOS. No macOS machine is available here, and CI needs a GitHub remote, which the point above rules out until the end. Task 1 makes the code macOS-correct by reading (the front doors use Linux-only values today); Task 9 asks the user how the macOS run happens and records the answer as a dated amendment.
- **Deferred minors.** M4 and M6 deferred 30 minors. Task 1 fixes the ones a person using a release would hit, and lists the rest as known gaps in `docs/STATUS.md`.
- **Benchmarks owed.** vercel/ms (Node addon and wasm against JS), the wasm module, the server route and the lifted quopri CLI were never benchmarked; Task 7 measures them with the rest.

## Global Constraints

- All work and tests run in the WSL clone `~/github/mojo-anything`; Mojo from the pinned pixi environment (`crate::mojo::MOJO_VERSION`).
- Platforms for every package and release asset: `linux-x64`, `linux-arm64`, `darwin-arm64` (and `darwin-x64` only if the pinned Mojo ships for it; check the pixi channel). No Windows asset; no Android.
- `package` writes files only: no build for other platforms, no publish. Publishing, pushing tags, creating the remote repository and registry submissions are outward-facing: ask the user in chat before each one and wait for a yes.
- Names: package/binary `mojo-anything`; repository `https://github.com/ModelTok/mojo-anything`; MCP server `io.github.ModelTok/mojo-anything`; skill folder `skills/mojo-anything`; package stamp `mojo-anything-package.json`, schema `mojo-anything/package@1`.
- Every number in the docs is measured in this milestone: say what was run, on what hardware with its core count (Ryzen 9 3900X, 12 cores / 24 threads, unless another machine), the Mojo version and date, the result, and the slow cases; run benchmarks twice on a quiet machine — no other agent, build or test suite running (pitfalls, "Numbers and claims"). No figure carries over from rust-anything.
- Language lines list English first; translations stay removed until the English text settles (spec Non-goals).
- Before each commit: `cargo fmt --all`, `cargo clippy --all-targets -- -D warnings`, `cargo test`; update `docs/STATUS.md` when what works changes. Prose in UK English. Run `scripts/check-secrets.sh` before every commit that touches manifests or docs.

## Review Focus

1. **A wheel installed where the pinned Mojo runtime is absent.** The Mojo extension links Mojo runtime libraries; a wheel installed into a plain CPython (no pixi) must import, or the package must declare the runtime dependency and fail with a clear message. Test: Task 2 `wheel_imports_in_clean_venv`.
2. **Platform without a binary** (Windows, Intel macOS when not shipped, Node older than 24 for wasm). The npm loader, jar and Python package must fall back to the original or say plainly what is missing, never crash on a missing file. Tests: Task 3 `npm_loader_falls_back_on_unsupported_platform`, `wasm_package_needs_node_24`, `jar_without_native_library_says_so`; Task 2 `python_package_unsupported_platform_message`.
3. **`setup` on a machine with existing agent configs.** Only `mojo-anything` entries are added or replaced; an old `rust-anything` entry is left alone (it is another tool); a file that does not parse is untouched. Test: Task 5 `setup_keeps_rust_anything_entry`.
4. **A front door on macOS.** `PR_SET_PDEATHSIG`, `/proc/self/exe` and the Linux `SOL_SOCKET`/`SO_RCVTIMEO` numbers are used unguarded today. Test: Task 1 `front_door_constants_per_os` (generated text for `macos` uses the Darwin values and no `prctl`).
5. **A docs number without a source.** Every number in `README.md`, `docs/STATUS.md`, `docs/real-world*.md` and the website must trace to a measurement log committed in this milestone. Test: Task 7 `docs_numbers_have_sources` (script).

---

### Task 1: Release blockers from the deferred minors

**Files:**
- Modify: `src/front_door_mojo.rs`, `src/mojo/original.mojo`, `src/mojo/original_http.mojo`, `src/mojo/http.mojo`, `src/lift.rs`, `src/codegen_mojo_node.rs`, `src/codegen_mojo_py.rs`, `docs/STATUS.md` ("Known gaps")
- Test: the test files of each module touched (`tests/front_door_mojo.rs`, `tests/lift.rs`, `tests/mojo_node.rs`, unit tests)

**Interfaces:**
- Produces: `front_door_mojo::os_constants(os: &str) -> OsConstants` (`sol_socket`, `so_rcvtimeo`, `timeval_size`, `has_pdeathsig`, `exe_path` strategy) used by every generated front door; generated Mojo picks values with `@parameter if CompilationTarget.is_macos()` where the stdlib offers it, otherwise the build passes `-D MOJO_ANYTHING_OS=<os>`.

Rule for every one of the 30 `minor (deferred)` lines in the M4 and M6 ledgers (and M5's, once its review lands): fix it in this task if a person using `v0.1.0` would meet it in normal use, a wrong result passes a check, or it is a denial of service on a served port; otherwise add it to `docs/STATUS.md` "Known gaps" in one line. These are fixed here, each with a test seen failing first:

- the front doors on macOS (Review Focus 4): Darwin socket constants, no `prctl` (the original is stopped by the front door's signal forwarding and a pipe it holds open), the executable path from `_NSGetExecutablePath`;
- the HTTP front door listens on `::1` as well as `127.0.0.1` (Node 17+ resolves `localhost` to `::1`): `front_door_answers_on_ipv6_localhost`;
- a request body larger than `MOJO_ANYTHING_MAX_BODY` (default 16 MiB) gets 413 without being read: `oversized_body_is_refused`;
- a library lift whose replay ran 0 of 0 cases fails instead of passing: `library_lift_with_no_cases_fails`;
- a wrong `MOJO_ANYTHING_REPO` stops with an error naming the path instead of running a same-named file from the working directory: `wrong_repo_variable_is_an_error`;
- a lone surrogate in `Optional[List[String]]` and batch fixed `String` parameters raises `TypeError`, not `MOJO_PANIC`: `lone_surrogate_in_optional_list_is_a_type_error`;
- a missing shared library is found when the wrapper loads, so the shadow's "module not loaded" fallback runs: `shadow_falls_back_when_library_is_missing`.

- [ ] **Step 1:** Write the tests above; run each and watch it fail.
- [ ] **Step 2:** Fix each; run each again. Expected: PASS.
- [ ] **Step 3:** Write the "Known gaps" list in `docs/STATUS.md` from the remaining minors, one line each, plain words.
- [ ] **Step 4:** Full gate. **Commit** `fix: release blockers from the M4–M6 reviews`.

### Task 2: Python wheels for Mojo ports

**Files:**
- Modify: `src/package.rs` (`Platform`, `PLATFORMS`, the `mojo-py` branch of `package`, `python_module`, stamp constants)
- Create: `src/package_mojo_py.rs` (pyproject, build backend config, workflow)
- Test: `tests/package.rs`

**Interfaces:**
- Consumes: `Options`, `Outcome` unchanged; `harness_mojo_py::build`; `codegen_py::package_init`.
- Produces:
  - `pub const PLATFORMS: &[Platform]` — the platforms in Global Constraints only.
  - `pub(crate) fn python_project(m: &Manifest, version: &str) -> Vec<(String, String)>` — a `pyproject.toml` (importable under the original's module name, `python_module(m)`), the package folder with `__init__.py`, `_native.so` copied from the build, and the Mojo runtime libraries the `.so` needs (found with `ldd`/`otool -L` against the pixi environment), vendored and their rpath set; declares `requires-python` from the recording's Python.
  - `pub(crate) fn wheels_workflow(m: &Manifest) -> String` — GitHub workflow building the wheel per platform with pixi, then `auditwheel repair` (Linux) or `delocate-wheel` (macOS).

- [ ] **Step 1: Write failing tests** in `tests/package.rs` (skip without Mojo):
  - `python_package_is_named_like_the_original` (replaces `python_package_is_a_maturin_project_named_like_the_original`): the project imports as the original module and lists only the supported platforms.
  - `wheel_imports_in_clean_venv`: build the host wheel with `pip wheel`, install it into a fresh `python3 -m venv` with no pixi on `PATH`, import it and replay the unit's cases: all match. Use `demo/real-world/python-quopri-mojo` as the unit (it has `bytes` parameters).
  - `python_package_unsupported_platform_message`: with `_native.so` removed, importing raises `ImportError` whose message names the supported platforms.
- [ ] **Step 2:** Run `cargo test --test package python`. Expected: FAIL.
- [ ] **Step 3:** Implement. If the Mojo runtime cannot be vendored (licence or size), declare the `max`/`mojo` runtime wheel as a dependency instead, and say which in `docs/packaging.md` and `DECISIONS.md`.
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: package Mojo Python extensions as wheels`.

### Task 3: npm (addon and wasm), gem, Go, C and jar packages

**Files:**
- Create: `src/package_mojo_ffi.rs` (npm per-platform packages with the Node-API shim and the Mojo shared library; an npm package holding the `.wasm`; a gem with the Fiddle wrapper and the shared library per platform; a Go module with the cgo wrapper and prebuilt libraries; a C tarball with the header and library; a jar with the FFM wrapper and the native library per platform)
- Modify: `src/package.rs` (dispatch per `Kind`; delete the napi-rs and wasm-bindgen generators and the `NPM_NOT_YET` refusals), `docs/packaging.md`
- Test: `tests/package.rs`

**Interfaces:**
- Produces:
  - `pub(crate) fn npm_packages(m: &Manifest, version: &str, fallback: Option<&str>) -> Vec<(String, String)>` — for `mojo-node`, a main package whose loader picks `<name>-<platform>` from `optionalDependencies` and falls back to `fallback` (the original JS) when none fits; one package per platform holding the shim `.node` and the Mojo library.
  - `pub(crate) fn npm_wasm_package(m: &Manifest, version: &str) -> Vec<(String, String)>` — for `mojo-wasm`, one platform-independent package with `index.cjs`, the `.wasm` and `"engines": {"node": ">=24"}` (memory64).
  - `pub(crate) fn gem(m: &Manifest, version: &str) -> Vec<(String, String)>` — one platform gem per platform plus a pure-Ruby gem that loads the original.
  - `pub(crate) fn go_module(m: &Manifest, version: &str) -> Vec<(String, String)>` — module with `//go:build` constraints per platform and the libraries under `lib/<platform>/`.
  - `pub(crate) fn c_archive(m: &Manifest, version: &str) -> Vec<(String, String)>` — for `c-abi`, `include/<unit>.h`, `lib/<platform>/lib<unit>.{so,dylib}` and a `pkg-config` file.
  - `pub(crate) fn jar(m: &Manifest, version: &str) -> Vec<(String, String)>` — for `mojo-jvm` (Java and Kotlin), a Maven project whose jar holds the FFM wrapper and `native/<platform>/` libraries, extracted to a cache folder on first load; `Automatic-Module-Name` set and `Enable-Native-Access: ALL-UNNAMED` in the manifest.
  - One workflow per kind, building on the supported platforms only.

- [ ] **Step 1: Write failing tests:**
  - `npm_package_installs_from_tarballs_and_falls_back_to_the_original` (kept name; now with the Mojo library): `npm pack` each package, install the tarballs into a scratch project, replay the cases: all match; uninstall the platform package: calls reach the original.
  - `npm_loader_falls_back_on_unsupported_platform`: loader run with `process.platform` stubbed to `win32` loads the fallback, and without a fallback throws an error naming the supported platforms (replaces `napi_package_without_a_fallback_says_so`).
  - `wasm_package_replays` and `wasm_package_needs_node_24`: the packed wasm package replays the `tests/fixtures/wasm-floats` cases on Node 24; with `process.versions.node` stubbed to `22.0.0` loading throws an error naming Node 24.
  - `gem_installs_and_replays`: `gem build`, `gem install --local`, replay the Ruby unit's cases.
  - `go_module_replays`: `go test` in a scratch module with a `replace` to the package folder runs the Go unit's cases.
  - `c_archive_links_and_replays`: compile the C fixture's original test program against the archive's header and library: its cases match.
  - `jar_replays` and `jar_without_native_library_says_so`: `mvn -o package` (or `jar` + `javac` when Maven is absent), run the Java unit's cases on Java 22+; with the platform folder removed, loading throws an error naming the supported platforms.
- [ ] **Step 2:** Run `cargo test --test package npm wasm gem go_module c_archive jar`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: package Mojo ports for npm, RubyGems, Go, C and Maven`.

### Task 4: MCP server and prompts

**Files:**
- Modify: `src/mcp.rs` (`TOOL_META` descriptions, server info, `FAILURES` fixes that name cargo/clippy), `src/mcp_prompts.rs` (`SKILL`, `WHOLE_APP` from `skills/mojo-anything/`), `skills/mojo-anything/SKILL.md`, `skills/mojo-anything/whole-app.md` (rewritten for Mojo: `port.mojo`, `mojo/app`, `mojo_checks`, `docs/mojo-notes.md`)
- Test: unit tests in `src/mcp.rs`; `tests/plugin.rs`

**Interfaces:**
- Produces: `tools/list` returns the same tool names (`analyze`, `bridge`, `record`, `build`, `diff`, `gate`, `bench`, `fuzz`, `profile`, `shadow`, `package`, `map`, `refresh`, `app_record`, `app_replay`, `app_front_door`, `app_wire`, `app_lift`); no description or prompt mentions Rust, cargo, clippy, napi, PyO3, JNI or `port.rs`.

- [ ] **Step 1: Write failing tests:** `tool_descriptions_name_mojo` (no tool description matches `(?i)\b(rust|cargo|clippy|napi|pyo3|jni|port\.rs)\b`; each porting tool mentions Mojo); `prompts_come_from_mojo_skill` (`prompts/get` of the skill prompt returns text starting with the first line of `skills/mojo-anything/SKILL.md`); `initialize_names_server` (`serverInfo.name == "mojo-anything"`).
- [ ] **Step 2:** Run `cargo test mcp`. Expected: FAIL.
- [ ] **Step 3:** Rewrite descriptions, failure fixes and the skill. Keep every pitfall-derived rule in the skill that still applies to Mojo; drop those about cargo, clippy and Android.
- [ ] **Step 4:** Run again; regenerate `docs/tools.md` (`UPDATE_TOOLS_DOC=1 cargo test --test tools`); drive the server once over stdio (`initialize`, `tools/list`, `tools/call analyze` on `tests/fixtures/python`) and check stdout holds only JSON-RPC lines (pitfall: child output corrupted the stream).
- [ ] **Step 5: Commit** `feat: the MCP server and skill speak Mojo`.

### Task 5: `setup` and `doctor`

**Files:**
- Modify: `src/setup.rs` (`NAME`, `SKILL`), `src/doctor.rs` (checks: `pixi`, the pinned Mojo, CPython, each language runtime with Java ≥ 22 and Node ≥ 24 for wasm, the agent setups, the MCP server; drop cargo-as-required, Visual Studio Build Tools, the NDK)
- Test: unit tests in `src/setup.rs`, `src/doctor.rs`; `tests/doctor.rs`

**Interfaces:**
- Produces:
  - `pub const NAME: &str = "mojo-anything"`.
  - `doctor` `Check` rows named `pixi`, `mojo`, `python`, `node`, `go`, `ruby`, `java`, `kotlinc`, `php`, `dotnet`, `mcp`, and one per agent; `mojo` is required, language runtimes optional; on Windows (`cfg!(windows)`), `pixi` and `mojo` fail with fix `use the WSL clone: wsl -d Ubuntu-24.04 --cd ~/github/mojo-anything`; a `node` older than 24 is a warning that names the wasm bridge.
  - `parse_java_version` grading uses minimum `Version(22, 0, 0)` (reuse M5's `require_java` constant).

- [ ] **Step 1: Write failing tests:**
  - `setup_keeps_rust_anything_entry`: a Claude config holding a `rust-anything` MCP entry gets a `mojo-anything` entry added and the `rust-anything` one unchanged; `--remove` removes only `mojo-anything`.
  - `doctor_on_windows_points_at_wsl`: the check builder called with `windows = true` returns failed `pixi` and `mojo` rows whose fix contains `wsl -d Ubuntu-24.04`.
  - `java_21_is_too_old`: `grade(true, Some(Version(21,0,4)), Some(Version(22,0,0)))` is a failure with a fix naming Java 22.
  - `node_22_warns_about_wasm`.
  - `doctor_json_lists_every_check_with_a_fix_for_each_problem` (kept) with the new row names.
- [ ] **Step 2:** Run `cargo test setup doctor && cargo test --test doctor`. Expected: FAIL.
- [ ] **Step 3:** Implement; make the platform a parameter of the check builder so the Windows path is testable on Linux.
- [ ] **Step 4:** Run again. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: setup and doctor for mojo-anything`.

### Task 6: Plugin, npm wrapper, MCP registry entry and workflows

**Files:**
- Modify: `plugin/` (skill path `plugin/skills/mojo-anything`, MCP command), `npm/mojo-anything/` (`package.json`, `bin/` launcher downloading the release asset for the supported platforms from `ModelTok/mojo-anything` releases, clear error elsewhere), `server.json` (name `io.github.ModelTok/mojo-anything`, repository and website `https://github.com/ModelTok/mojo-anything`, description without "Rust", npm identifier `mojo-anything`, version), `.github/workflows/release.yml` (matrix: the platforms in Global Constraints; no Windows), `.github/workflows/ci.yml` (Linux and macOS jobs with pixi, JDK 22+, Node 24; the Windows job removed), `Cargo.toml` version `0.1.0`
- Delete: `npm/rust-anything/`
- Test: `tests/plugin.rs`; `tests/tools.rs`

- [ ] **Step 1: Write failing tests:** `the_plugin_ships_the_same_skill_and_mcp_server` and `the_plugin_version_is_the_crate_version` (kept, new paths); `server_json_matches_crate` (name, version and npm identifier agree with `Cargo.toml`; no `erkamyaman` or `rust-anything` in it); `npm_launcher_rejects_windows` (the launcher run with `process.platform = 'win32'` exits non-zero with a message naming WSL).
- [ ] **Step 2:** Run `cargo test --test plugin --test tools`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run again; `actionlint` on the workflows if installed; run the Linux CI job's commands locally in the WSL clone. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `chore: plugin, npm wrapper, registry entry and workflows for mojo-anything`.

### Task 7: Measured docs

**Files:**
- Create: `docs/measurements/2026-<mm>-<dd>-<run>.md` (one log per measured run: command, hardware and cores, Mojo version, date, output), `scripts/check-doc-numbers.py`
- Modify: `README.md`, `docs/STATUS.md`, `docs/real-world.md`, `docs/real-world-languages.md`, `docs/how-it-works.md`, `docs/whole-apps.md`, `docs/packaging.md`, `docs/install.md`, `docs/faq.md`, `docs/tools.md`, `docs/examples.md`, `docs/privacy.md`, `CONTRIBUTING.md`, `SECURITY.md`, `CHANGELOG.md`; delete `docs/assets/prettier.gif` and the Rust crab logo (replace with a plain text heading until there is art)
- Test: `scripts/check-doc-numbers.py` run by `cargo test` through `tests/tools.rs`

- [ ] **Step 1: Write the failing check** `docs_numbers_have_sources`: `scripts/check-doc-numbers.py` lists every number with a unit or ratio (`x faster`, `ms`, `%`, `n/n`, `req/s`, MB, KB) in the files above and fails unless the same paragraph links a file under `docs/measurements/`. Wire it into `tests/tools.rs`.
- [ ] **Step 2:** Run `cargo test --test tools docs_numbers`. Expected: FAIL (rust-anything numbers have no logs).
- [ ] **Step 3:** Re-run on Mojo, twice each on a quiet machine (no other agent, build or suite running; check with `uptime` before each run and record the load average): `diff` counts and `bench` for colorsys, Go `path`, shellwords, the ffmpeg unit, vercel/ms on `mojo-node` and on `mojo-wasm` (Node 24) against the original JS, and quopri; the lifted quopri CLI against `python3 -m quopri`; the server route with in-process handler time beside req/s; wasm module sizes; compile times cold and after an edit (mojo-wasm-build skill, "Benchmarking"). Commit each log.
- [ ] **Step 4:** Rewrite the docs from the logs: what works, how it was checked, the slow cases. Remove every rust-anything claim not re-measured. `README.md` says Linux and macOS (Windows through WSL) and states which platforms were actually run.
- [ ] **Step 5:** Run the check again. Expected: PASS; full gate; `rg -n -i "rust-anything|cargo add|clippy|napi|pyo3|jni|crate" README.md docs/*.md` finds only history notes in `CHANGELOG.md` and upstream credit lines.
- [ ] **Step 6: Commit** `docs: rewrite for Mojo from measured runs`.

### Task 8: Website

**Files:**
- Modify: `website/pages/en/**`, `website/pages/layout.tsx`, `website/content/cli-help.json` (regenerated from `mojo-anything --help` of every subcommand), `website/components/**` where they name rust-anything, `.github/workflows/website.yml` (deploy target only after the user names it)
- Delete: `website/pages/{az,de,fr,ja,kk,ko,ky,pt,ru,tk,tr,tt,ug,uk,uz,zh,zh-tw}/`
- Test: `cd website && npm ci && npm run build`

- [ ] **Step 1: Write the failing check** in `tests/tools.rs` `cli_help_json_is_current`: `website/content/cli-help.json` equals the help text the binary prints for every subcommand.
- [ ] **Step 2:** Run it. Expected: FAIL.
- [ ] **Step 3:** Regenerate the help file; rewrite the English pages from the Task 7 docs (no number that `check-doc-numbers.py` would reject); delete translated pages.
- [ ] **Step 4:** `npm run build` in `website/`. Expected: exit 0. Open the built pages in the browser pane and check every page renders and links resolve.
- [ ] **Step 5: Commit** `docs: website for mojo-anything`.

### Task 9: DECISIONS, pitfalls and the Phase 1 tag

**Files:**
- Modify: `DECISIONS.md` (every decision of the spec and Milestones 1–7 with its reason; superseded rust-anything entries marked so), `docs/pitfalls.md` (rules that only apply to Rust or Android removed; Mojo pitfalls from Milestones 1–7 present), `CHANGELOG.md` (`0.1.0`), `docs/STATUS.md` ("Phase 1 complete" line with date), the spec (a dated amendment for the repository name and for the macOS check, quoting the user's words)

- [ ] **Step 1:** Check the spec's "Phase 1 done when": every source language's fixture loop passes with Mojo ports; `colorsys.py`, Go `path`, `shellwords.rb`, one ffmpeg unit and vercel/ms re-verified (Task 7 logs); one CLI lifted (quopri). Run the Linux CI job locally and read its result. For macOS, ask the user once how it is checked (a CI run needs a GitHub remote, which this plan does not create) and record the answer; until then macOS is listed as not run. List anything missing as a blocker and stop if any.
- [ ] **Step 2:** Update the files above.
- [ ] **Step 3:** Full gate; `scripts/check-secrets.sh`; `git diff --cached` checked for `/Users/` and `/home/`.
- [ ] **Step 4: Commit** `chore: release 0.1.0` and tag `v0.1.0` locally (annotated). Do not push.
- [ ] **Step 5:** Record `refs/tags/v0.1.0` and its commit hash in `docs/STATUS.md` as the binary Phase 2 records (spec, "Where the work happens"). Creating `ModelTok/mojo-anything`, pushing `main` and the tag, the release workflow, npm and the MCP Registry wait for the publish after M9, each asked for in chat.
