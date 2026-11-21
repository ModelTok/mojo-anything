# Milestone 4: TS/JS to Mojo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** TS/JS units bridge to Mojo ports reached from Node through a generated Node-API C shim over the M3 JSON dispatcher, with `--batch`, `shadow` and `fuzz` working, vercel/ms re-verified at 975/975, and then `--kind wasm` through Mojo-to-wasm; the napi-rs and wasm-bindgen generators and `codegen_tswire.rs` are removed.

**Architecture:** A new kind `mojo-node`. `bridge` writes `mojo/<unit>/` with `port.mojo`, `dispatch.mojo` (M3's dispatcher, built as a shared library), `node_shim.c` (a Node-API addon that loads the library and forwards `call(name, argsJson)` to `mojo_anything_call`), `binding.gyp` and `index.cjs`. `index.cjs` keeps today's codec (`$undefined`, `$num`, `$map`, `$utf16`, ...) and error mapping, so recorded cases and callers see JS values exactly as before. Structured and plain values all cross as JSON text; speed comes back in `--batch`, where items stay on the Mojo side.

**Tech Stack:** Rust 2024 (the tool), Mojo via pixi, C (Node-API, node-gyp), Node 22+, mojowasm for the wasm kind.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` (Phase 1, TS/JS row of "Bridge per source language", the dispatcher's JSON rules, "Dropped from Phase 1", "Calls made after the builder check": `--batch` and `--kind wasm`).

## Global Constraints

- Everything in M1's Global Constraints holds (WSL clone, pixi-pinned Mojo, `docs/mojo-notes.md` spellings only, names, the Rust gate before each commit, Mojo tests skip when `crate::mojo::available()` is false, helpers emitted only when used, UK English).
- Node-API tests also skip without `node` and a C compiler (`cc`), with a printed reason.
- The Node shim uses only Node-API (`node_api.h`, version 8 or lower), no C++ and no `node-addon-api`, so one build works across Node 22+.
- JS values cross with the existing codec markers; the dispatcher's JSON writer gives V8's shortest digits and rounds ties as V8 does (pitfall: number formatting picked the wrong digit on ties).
- JSON input has no depth limit (pitfall: deep JSON stopped at 128 levels).
- The wasm kind builds with `pixi run python -m mojowasm build`, uses typed errors (`raises String`), never calls `String(Float64)` on wasm32 (it hangs), and uses `UInt64` for values that can pass 2^31.

## Review Focus

1. **JS errors keep their class.** A port raising `TypeError: empty` must reject in JS as a `TypeError` with message `empty`, and async exports must return a rejected promise, not throw synchronously. Test: Task 3 `node_errors_keep_their_class_and_async_rejects`.
2. **Values JSON cannot carry.** `undefined`, `NaN`, `-0`, `BigInt`, `Date`, `Map`, `Set`, `Uint8Array` and lone surrogates must round-trip through the shim. Test: Task 3 `node_carries_markers_through_mojo`.
3. **Paths with spaces and non-ASCII** in the unit folder: the shim must still find the Mojo library next to it. Test: Task 3 `node_addon_loads_from_unicode_path`.
4. **A panic in the port** (Mojo `abort` or an out-of-range index) must not kill Node silently; the dispatcher's `{"panic"}` becomes a thrown `Error` naming the function. Test: Task 2 `shim_turns_panic_into_error`.
5. **wasm32 floats.** A wasm port returning `0.1 + 0.2` or `-0` must replay exactly without calling `String(Float64)`. Test: Task 8 `wasm_float_results_replay`.

---

### Task 1: The `mojo-node` kind

**Files:**
- Modify: `src/bridge.rs` (`Kind::MojoNode` serialised `"mojo-node"`; TS/JS maps to it), `src/analyze.rs` (`Bridge::MojoNode`, shown as `Mojo (Node-API)`), `src/main.rs` (`KindArg::Node` replaces `KindArg::Napi`), `src/mcp.rs` (`"node"` in place of `"napi"`)
- Test: unit tests in `src/bridge.rs`, `src/analyze.rs`

**Interfaces:**
- Consumes: M1 `RType::mojo`.
- Produces: `Kind::MojoNode`; `RType::mojo(Lang::TypeScript)` maps `F64→Float64`, `Int→Int`, `Json→JsonValue` (M3's Mojo JSON value type from `src/mojo/json.mojo`).

- [ ] **Step 1: Write failing tests** `ts_bridges_to_mojo_node` (`analyze` on `tests/fixtures/mini` reports `Mojo (Node-API)`) and `node_kind_round_trips` (`"mojo-node"` serialises and loads).
- [ ] **Step 2:** Run `cargo test ts_bridges_to_mojo_node node_kind_round_trips`. Expected: FAIL.
- [ ] **Step 3:** Implement. Keep `Kind::Napi` and `Kind::Wasm` until Task 9.
- [ ] **Step 4:** Run again. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: add the mojo-node bridge kind`.

### Task 2: The Node-API shim

**Files:**
- Create: `src/codegen_mojo_node.rs`, `src/mojo/node_shim.c` (embedded with `include_str!`; the unit's library name is the only substitution)
- Modify: `src/lib.rs`
- Test: unit tests in `src/codegen_mojo_node.rs`; `tests/mojo_node_shim.rs`

**Interfaces:**
- Consumes: M3 `codegen_mojo_ffi::dispatcher_mojo(m: &Manifest, api: &PortApi) -> String`, `src/mojo/json.mojo`; `crate::mojo::command`.
- Produces:
  - `pub fn node_shim_c(m: &Manifest) -> String` — an addon exporting `call(name: string, argsJson: string): string` that `dlopen`s `lib<lib>_mojo.so` (`.dylib` on macOS) from the addon's own directory, calls `mojo_anything_call`, copies the result into a JS string and calls `mojo_anything_free`.
  - `pub fn binding_gyp(m: &Manifest) -> String`.
  - `pub fn index_cjs_mojo(m: &Manifest, api: &PortApi) -> String` — today's `CODEC_CJS` and `GUARD_CJS` from `src/codegen.rs`, then one export per port function: `encode` the arguments as an array, `native.call(name, json)`, `decode` the reply; `{"error": "TypeError: x"}` throws that class (the `JS_ERRORS` pattern), other errors throw `Error`; `{"panic": m}` throws `Error("panic in <name>: <m>")`; async exports wrap the same call in `Promise.resolve().then(...)`.

- [ ] **Step 1: Write failing tests:**
  - `shim_names_library`: `node_shim_c` for crate `ms-mojo` loads `libms_mojo_mojo` and exports `call`.
  - `index_keeps_codec`: `index_cjs_mojo` contains `$undefined`, `$utf16` and the `JS_ERRORS` pattern.
  - `shim_turns_panic_into_error` (in `tests/mojo_node_shim.rs`; skips without Mojo, node or cc): a one-function unit whose port aborts throws in Node with a message starting `panic in`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Move `CODEC_CJS`, `GUARD_CJS` and `WRAP_CJS` out of `src/codegen.rs` into `src/codegen_js.rs` so they outlive the napi generator.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: generate a Node-API shim over the Mojo dispatcher`.

### Task 3: Bridge, build and diff for `mojo-node`

**Files:**
- Create: `src/harness_mojo_node.rs`
- Modify: `src/bridge.rs` (`bridge` and `refresh` for `Kind::MojoNode`), `src/harness.rs` (`build` and the native-file match dispatch `Kind::MojoNode`)
- Test: `tests/native.rs` (new `node_*` tests beside the napi ones), `tests/loop.rs` (`ts_mojo_*`), fixture `tests/fixtures/mini-mojo-port/port.mojo`

**Interfaces:**
- Consumes: Tasks 1–2; `harness::record` and the Node diff driver unchanged (they `require` the unit's `index.cjs`).
- Produces:
  - `pub fn build(unit_dir: &Path, m: &Manifest) -> Result<PathBuf>` — builds `dispatch.mojo` with `--emit shared-lib` into `build/lib<lib>_mojo.so`, then the shim with `node-gyp rebuild` (or `cc -shared` against Node's headers from `node -p process.config` when node-gyp is missing), copies both next to `index.cjs`, and returns the `.node` path.
  - Bridge output: `mojo/<unit>/{port.mojo, dispatch.mojo, json.mojo, node_shim.c, binding.gyp, index.cjs, pixi.toml, mojo-anything.json, README.md}`.

- [ ] **Step 1: Write failing tests** (skip without Mojo, node or cc):
  - `ts_mojo_bridge_files`: the file list above.
  - `ts_mojo_loop_matches`: bridge `tests/fixtures/mini`, `record`, copy the fixture port, `build`, `diff` → every case matches.
  - `node_errors_keep_their_class_and_async_rejects`: the `src/guard.ts` project from `napi_errors_keep_their_class_and_async_exports_reject`, ported to Mojo; `check('')` throws `TypeError` `empty`, `later('x')` returns a promise resolving `'x'`.
  - `node_carries_markers_through_mojo`: an identity port over `unknown` returns each marker value unchanged (`Object.is` for `-0` and `NaN`).
  - `node_addon_loads_from_unicode_path`: the loop in a folder named `node path with spaces ünïcøde`.
- [ ] **Step 2:** Run `cargo test --test native node_` and `cargo test --test loop ts_mojo`. Expected: FAIL.
- [ ] **Step 3:** Write the fixture port and implement.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: bridge, build and diff TS/JS units as Mojo ports`.

### Task 4: `--batch` for Mojo

**Files:**
- Modify: `src/codegen_batch.rs` (Mojo index stubs and the JS batch class over the dispatcher), `src/bridge.rs` (`add_batches` for `Kind::MojoNode`; drop the allocator option for Mojo units)
- Test: `tests/native.rs` `node_batches_*`, unit tests in `src/codegen_batch.rs`

**Interfaces:**
- Consumes: `Batch { function, param }` (`Batch::parse`), `pascal`.
- Produces:
  - `pub fn index_mojo(m: &Manifest, b: &Batch) -> String` — a stub `struct <Pascal>Index` with `def __init__(out self, items: List[<item>])` and `def run(self, <other params>) raises -> List[<ret>]`, plus `def rank(self, <params>, min: Float64) raises -> List[Int]` when the port defines `rank`.
  - Dispatcher entries `<Pascal>Batch.new`, `.run`, `.rank`, `.free` keyed by an integer handle the Mojo side keeps in a table; `index.cjs` exposes `class <Pascal>Batch` with `run`, `rank` and an explicit `free()` plus a `FinalizationRegistry` fallback.
  - String items cross once as one joined string and an `ends` array (the `from_joined` shape today), not one JSON string each.

- [ ] **Step 1: Write failing tests:**
  - `batch_index_stub_shape`: `index_mojo` for `parse:text` declares `struct ParseIndex` with `run` returning `List[Float64]` for a `number` result.
  - `node_batches_take_structured_parameters` and `node_string_batches_cross_joined`: the napi tests of the same names, against a Mojo port.
  - `node_batch_handle_freed`: after `free()`, calling `run` throws `Error` naming the batch.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement. Multi-core batches are not required here; note in `DECISIONS.md` that Mojo batches run on one thread until `parallelize` is measured.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: batch classes for Mojo ports`.

### Task 5: `shadow` and `fuzz` on Mojo ports

**Files:**
- Modify: `src/shadow.rs` (the TS path loads the Mojo `index.cjs`; mode variable `MOJO_ANYTHING_MODE`), `src/fuzz.rs` (no change expected beyond build dispatch; fix what the tests show)
- Test: `tests/fuzz.rs` (switch its helper from napi to `mojo-node`), `tests/loop.rs` `ts_mojo_shadow_*`

**Interfaces:**
- Consumes: `shadow::shadow(crate_dir, out) -> Result<ShadowOutcome>`, `fuzz::fuzz(&FuzzOptions) -> Result<FuzzOutcome>`, Task 3 build.

- [ ] **Step 1: Write failing tests:**
  - `ts_mojo_shadow_reports_mismatch`: a shadow module over a port with one wrong function returns the original's value and logs one mismatch; with `MOJO_ANYTHING_MODE=new` it returns the port's value.
  - The two existing `tests/fuzz.rs` tests (planted mismatch found; `--keep` makes `gate` fail; `--pin-clock` with `Date.now()` and `Math.random`), with Mojo ports.
- [ ] **Step 2:** Run `cargo test --test fuzz` and `cargo test --test loop ts_mojo_shadow`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: shadow and fuzz Mojo ports of TS/JS units`.

### Task 6: The gate for `mojo-node`

**Files:**
- Modify: `src/gate.rs` (dispatch `Kind::MojoNode` to `mojo_checks`, plus the coverage check that today reads the original's import closure)
- Test: `tests/loop.rs` `ts_mojo_gate_*`

**Interfaces:**
- Consumes: M1 `gate::mojo_checks(unit_dir: &Path) -> Vec<Check>`.
- Produces: no new names; `gate` on a `mojo-node` unit runs `mojo_checks`, the API check (every export in `index.cjs` exists and is a function or class), coverage, and the replay against the built addon.

- [ ] **Step 1: Write failing tests** `ts_mojo_gate_passes` (the Task 3 matching unit) and `ts_mojo_gate_fails_on_missing_export` (an export deleted from `index.cjs` fails the API check with a fix naming `mojo-anything refresh`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: gate Mojo ports of TS/JS units`.

### Task 7: vercel/ms, ported to Mojo

**Files:**
- Create: `demo/real-world/vercel-ms-mojo/` (vercel/ms at commit `4ff48ce`, unit `src/index.ts`; manifest `root` a placeholder)
- Modify: `docs/STATUS.md` (TS/JS row), `docs/real-world.md` (vercel/ms section rewritten for Mojo)

- [ ] **Step 1:** `bridge`, then `record --from-tests -- jest` with the inputs of `demo/real-world/vercel-ms-rs/inputs.jsonl` and `test-inputs.jsonl`. Expected: 975 cases; check the count before porting (pitfall: case names collided).
- [ ] **Step 2:** Port `ms`, `parse`, `parseStrict` and `format`, matching units by hand, ASCII-only case folding (the Rust port's lesson: `/.../i` without `u` folds only ASCII).
- [ ] **Step 3:** `build`, `diff`. Expected: `975/975`.
- [ ] **Step 4:** `gate`. Expected: every check passes.
- [ ] **Step 5:** `bench` twice on a quiet machine; record per-call and `parse` ×100,000 batch numbers with the hardware and core count (pitfalls on benchmarks). Write them in `docs/real-world.md`, including the rows slower than JS.
- [ ] **Step 6:** `scripts/check-secrets.sh`; update `docs/STATUS.md`.
- [ ] **Step 7: Commit** `feat: port vercel/ms to Mojo (975/975)`.

### Task 8: `--kind wasm` through Mojo-to-wasm

**Files:**
- Create: `src/harness_mojo_wasm.rs`, `src/mojo/wasm_runtime.c` (the allocator and libc stubs mojowasm needs, routed through Mojo's allocator), `src/mojo/f64_format.mojo` (shortest round-trip digits from the raw bits, no `String(Float64)`)
- Modify: `src/bridge.rs` (`Kind::MojoWasm` serialised `"mojo-wasm"`), `src/main.rs` (`KindArg::Wasm` maps to it), `src/codegen_mojo_node.rs` (`index_cjs_mojo` gains a wasm loader: instantiate, write the name and arguments into linear memory, call the export, read the result back)
- Test: `tests/mojo_wasm.rs`

**Interfaces:**
- Consumes: M3 `dispatcher_mojo` (exported as `mojo_anything_call`/`mojo_anything_free` with `abi("C")`), Task 2 `index_cjs_mojo`.
- Produces:
  - `Kind::MojoWasm`; `pub fn build(unit_dir: &Path, m: &Manifest) -> Result<PathBuf>` writing `<lib>.wasm` next to `index.cjs` via `pixi run python -m mojowasm build dispatch.mojo -o <lib>.wasm`, failing unless the tool's output names both exports.
  - The dispatcher on wasm32 raises `String`, not `Error` (pitfall from the mojo-wasm-build notes: `raises Error` fails to link).

- [ ] **Step 1: Write failing tests** (skip without mojowasm):
  - `wasm_loop_matches`: the Task 3 loop with `--kind wasm`.
  - `wasm_float_results_replay`: a port returning `0.1 + 0.2`, `-0.0`, `5e-324` and `1.7976931348623157e308` replays exactly, each case under a 5 s limit.
  - `wasm_large_offsets`: a string argument of 3 MB round-trips (offsets past 2^21 and lengths in `UInt64`).
- [ ] **Step 2:** Run `cargo test --test mojo_wasm`. Expected: FAIL.
- [ ] **Step 3:** Implement. Check `f64_format.mojo` against `js_number::number_to_string` on 100,000 random bit patterns, ties included, in a unit test.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5:** Re-run the x18n search wasm demo with a Mojo port if its sources are at hand; otherwise mark the wasm row "Tested" in `docs/STATUS.md`.
- [ ] **Step 6: Commit** `feat: wasm bridge through Mojo-to-wasm`.

### Task 9: Remove napi-rs, wasm-bindgen and the binary wire

**Files:**
- Modify: `src/bridge.rs` (drop `Kind::Napi`, `Kind::Wasm`, `Allocator`; old manifests with `"napi"` or `"wasm"` fail with a message saying to bridge again), `src/codegen.rs` (delete `lib_rs`, `NAPI_RUN*`, `index_cjs`, `JS_RS` and the Rust helpers, `required_deps`, `cargo_toml`, `ensure_deps`; keep `PortApi`, `PortFn`, `PortClass`, `wire` only if Go/Java still read them), `src/codegen_batch.rs` (delete `js_rs`, `py_rs`, `needs_rayon`), `src/harness.rs` (`build` napi/wasm arms), `src/package.rs` (npm packaging for `mojo-node`: "not yet: see the packaging plan"), `src/shadow.rs`, `DECISIONS.md`, `docs/pitfalls.md`
- Delete: `src/codegen_tswire.rs`, `demo/fuzzy-napi/`, `demo/fuzzy-rs/`, `demo/real-world/vercel-ms-rs/`, napi tests in `tests/native.rs` and `tests/loop.rs` that the `node_*`/`ts_mojo_*` tests replace
- Test: existing TS/JS tests now on `mojo-node`

- [ ] **Step 1: Write the failing test** `napi_manifest_says_rebridge`: a manifest with `"kind": "napi"` fails to load with a message containing `bridge again`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Remove the code and demos above.
- [ ] **Step 4:** `cargo fmt --all && cargo clippy --all-targets -- -D warnings && cargo test`. Expected: PASS; `rg -n "napi|wasm_bindgen|wasm-bindgen|tswire" src tests` finds only the rebridge message, its test and the Node-API shim.
- [ ] **Step 5:** Update `DECISIONS.md` (TS/JS reach Mojo through a Node-API C shim over the dispatcher; why not napi-rs; the binary wire deferred), `docs/STATUS.md` (rows for `bridge`, `--batch`, wasm bridge, `shadow`, `fuzz`, `record --pin-clock`), and any pitfall learned.
- [ ] **Step 6: Commit** `refactor: drop napi-rs, wasm-bindgen and the binary wire`.
