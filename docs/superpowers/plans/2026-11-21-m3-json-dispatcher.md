# Milestone 3: The JSON dispatcher, Go and Ruby — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Go and Ruby units are ported to Mojo and reached through one C-ABI JSON dispatcher (plus typed C exports for Go's scalar functions), proven on Go's `path` (2,642/2,642) and Ruby's `shellwords.rb` (1,617/1,617); the Rust dispatcher, magnus extension and Rust cgo exports are gone.

**Architecture:** A Mojo JSON reader and writer (`json.mojo`) is emitted into every unit whose API carries structured values. The `ffi` kind keeps its name; its unit is now Mojo: `dispatcher.mojo` exports `mojo_anything_call(name, args_json) -> answer_json` and `mojo_anything_free(answer)`, and for Go also one typed `mojo_anything_t_<name>` per function whose parameters and result are scalars or strings (today's status protocol: 0 ok, 1 error, 2 the string result needs `*out_len` bytes). The Go cgo wrapper and the Ruby Fiddle wrapper keep the original APIs and call these symbols; the Go and Ruby drivers stay as they are.

**Tech Stack:** Rust 2024 (the tool), Mojo via pixi, Go 1.24 with cgo, Ruby 3.3 with Fiddle, WSL Ubuntu 24.04.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` (Phase 1: Go/Ruby row of "Bridge per source language", the JSON rules under it, "Dropped from Phase 1").

Assumes Milestones 1 and 2 have landed: `crate::mojo::{MOJO_VERSION, available, command, missing_message}`, `codegen_mojo::{port_mojo, parse_port_mojo, STUB_MARK}`, `gate::mojo_checks`, `RType::mojo`, `docs/mojo-notes.md` (with its "C ABI" section) and the mojo-anything names.

## Global Constraints

- All work and tests run in the WSL clone `~/github/mojo-anything` (Ubuntu 24.04), never `/mnt/c`.
- Mojo comes from pixi at `crate::mojo::MOJO_VERSION`; generated units pin the same version.
- Verify every Mojo API against the pinned stdlib source; record new spellings in `docs/mojo-notes.md`.
- JSON rules (from the spec): every float survives a write and read bit for bit; floats are written with the shortest digits that read back to the same value, choosing the closest on ties as V8 does; object key order is kept; input depth is unlimited (no recursion limit).
- Value markers are those of the record codec in `src/harness.rs` and the wrappers' codecs: `{"$num": "NaN" | "Infinity" | "-Infinity" | "-0"}`, `{"$undefined": true}`, `{"$tuple": [...]}`, `{"$utf16": [...]}`, and the Ruby codec's markers in `codegen_ruby.rs` `CODEC_RB`. The Mojo reader turns `$num` markers into floats; other markers reach the port as JSON objects, unchanged.
- Symbol names: `mojo_anything_call`, `mojo_anything_free`, `mojo_anything_t_<name>`; answers are `{"ok": value}`, `{"error": message}` or `{"panic": message}`.
- Dropped in this milestone, per the spec: the binary wire (`wire.rs`, `codegen_go::wire_rs`) and the native batch classes (`codegen_batch_native.rs` for Go and Ruby); `bridge --batch` for Go and Ruby answers "not yet: batches for Go and Ruby come after correctness" and exits non-zero.
- Before each commit: `cargo fmt --all`, `cargo clippy --all-targets -- -D warnings`, `cargo test`; update `docs/STATUS.md` when what works changes.
- Tests that need Mojo, Go or Ruby skip with a printed reason when the tool is missing.
- `json.mojo` is emitted only into units that use it (pitfall: unused helpers failed the gate); bridge a Go unit with only scalar functions and build it to check.
- Prose in UK English.

## Review Focus

1. **Float ties and extremes.** `5e-324`, `1.7976931348623157e308`, `0.1 + 0.2`, `2^53 + 1` as a float, and a value whose shortest digits tie (`...812` against `...813`, the Prettier pitfall) must write the same digits V8 writes. Test: Task 1 `json_float_corpus`.
2. **Deep input.** A 200-deep array or object must parse and write back (pitfall: 128-level limit). Test: Task 1 `json_200_deep`.
3. **Integers beyond 64 bits and `-0`.** Ruby's bignums and Go's `uint64` maximum arrive as JSON integers; they must reach the port without turning into floats, and `{"$num": "-0"}` must stay negative zero. Test: Task 1 `json_big_ints_exact`, `json_markers`.
4. **A port error versus a broken call.** A port that raises answers `{"error": message}` and Go returns it as an `error`, Ruby raises the named class (`ArgumentError: …`); a call with an unknown name or arguments that do not match answers `{"panic": …}` and does not crash the process. Test: Task 3 `dispatcher_error_and_panic`.
5. **Strings with NUL bytes or invalid UTF-8.** Go strings can hold both; they must cross as the same bytes, through the typed path's lengths and the JSON path's escapes. Test: Task 4 `go_string_bytes_survive`.

---

### Task 1: `json.mojo`, the reader and writer

**Files:**
- Create: `src/mojo/json.mojo` (embedded with `include_str!` as `codegen_mojo::JSON_MOJO`), `tests/fixtures/mojo-json/test_json.mojo`, `tests/fixtures/mojo-json/floats.txt`, `tests/mojo_json.rs`
- Modify: `src/codegen_mojo.rs` (`pub const JSON_MOJO: &str`), `docs/mojo-notes.md`

**Interfaces:**
- Produces (Mojo, in `json.mojo`):
  - `struct JsonValue` — null, bool, number (kept as `Int64` when the text is an integer that fits, `Float64` when it has a fraction or exponent, or the original digit text when it is an integer outside 64 bits), string, array (`List[JsonValue]`), object (keys and values in insertion order).
  - `def parse_json(text: StringSlice) raises -> JsonValue` — iterative (an explicit stack, no recursion), decodes `$num` markers.
  - `def write_json(value: JsonValue) -> String` — compact, no spaces; non-finite floats and `-0.0` as `$num` markers.
  - Accessors the generated code uses: `as_float() raises -> Float64`, `as_int() raises -> Int64`, `as_string() raises -> String`, `as_bool() raises -> Bool`, `as_list() raises -> List[JsonValue]`, `get(key) raises -> JsonValue`, and constructors from each Mojo type.

- [ ] **Step 1: Write `floats.txt`:** one float per line as V8's `String(x)` prints it, covering `5e-324`, `2.2250738585072014e-308`, `1.7976931348623157e308`, `0.30000000000000004`, `9007199254740993` read as a float, `1e21`, `1e-7`, `123456789012345680000`, and at least 20 tie cases produced with Node (`node -e` over random bit patterns, keeping those where a naïve shortest-digits routine and V8 differ) — record the Node version in the file's first line.
- [ ] **Step 2: Write the failing tests** in `test_json.mojo`, run by `tests/mojo_json.rs` with the pinned `mojo test` (skip without Mojo):
  - `json_float_corpus`: for every line, `write_json(parse_json(line))` equals the line, with the number formatted as V8 does for JSON (exponent form `1e+21`, `1e-7`).
  - `json_200_deep`: `[[[…]]]` 200 deep, and an object 200 deep, round-trip unchanged.
  - `json_key_order`: `{"b":1,"a":2}` writes back as `{"b":1,"a":2}`.
  - `json_big_ints_exact`: `18446744073709551615` and `-123456789012345678901234567890` round-trip as integers with the same digits.
  - `json_markers`: `{"$num":"-0"}` reads as `-0.0` (sign bit set), `NaN` and both infinities read as such and write back as the same markers.
  - `json_strings`: escapes `\u0000`, `😀`, `\"`, `\\` round-trip; a lone surrogate `\ud800` reads without error and writes back as `\ud800`.
  - `json_rejects`: `[1,]`, `{"a"}`, `01`, trailing text each raise with the byte offset in the message.
- [ ] **Step 3:** Run `cargo test --test mojo_json`. Expected: FAIL.
- [ ] **Step 4:** Implement. First check the pinned stdlib's `Float64` formatting and parsing against `floats.txt`; use it where every line passes, and otherwise write shortest-digit formatting from the raw bits with exact big-integer arithmetic for the tie decision (the `mojo-wasm-build` skill notes the same approach). Record which route was taken, and why, in `docs/mojo-notes.md`.
- [ ] **Step 5:** Run. Expected: PASS.
- [ ] **Step 6: Commit** `feat: a Mojo JSON reader and writer with exact float round trips`.

### Task 2: Structured types for Go and Ruby ports

**Files:**
- Modify: `src/bridge.rs` (`RType::mojo` for `Lang::Go` and `Lang::Ruby`), `src/codegen_mojo.rs` (`port_mojo` emits `from json import JsonValue` and `json.mojo` only when needed)
- Test: unit tests in `src/bridge.rs` and `src/codegen_mojo.rs`

**Interfaces:**
- Consumes: Task 1 `JSON_MOJO`.
- Produces:
  - `RType::Json.mojo(Lang::Go | Lang::Ruby) == "JsonValue"`; Go's `int` → `Int`, `int64` → `Int64`, `uint64` → `UInt64`, `float64` → `Float64`, `string` → `String` (bytes kept: see Task 4), `[]string` → `List[String]`; Ruby's dynamic values → `JsonValue`.
  - `pub fn needs_json_mojo(api: &PortApi) -> bool` — true when any parameter or result is `JsonValue`, or when the unit is reached through the dispatcher (Ruby always; Go when some function is not typed-eligible).

- [ ] **Step 1: Write failing tests:**
  - `go_mojo_types`: each Go mapping above.
  - `scalar_go_unit_has_no_json`: a Go unit with only `func Clean(path string) string` gets no `json.mojo` and no dispatcher.
  - `ruby_unit_has_json`: any Ruby unit gets `json.mojo`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: Mojo types for Go and Ruby ports`.

### Task 3: `dispatcher.mojo`

**Files:**
- Modify: `src/codegen_ffi.rs` (replace `lib_rs` and `cargo_toml` with `dispatcher_mojo` and the unit's `pixi.toml`; `java_native_class` stays for Milestone 5)
- Create: `tests/fixtures/mojo-dispatcher/` (a two-function port and a C caller), `tests/mojo_dispatcher.rs`

**Interfaces:**
- Consumes: Task 1, `docs/mojo-notes.md` "C ABI".
- Produces:
  - `pub fn dispatcher_mojo(m: &Manifest, api: &PortApi) -> String` — exports `mojo_anything_call(name: const char *, args: const char *) -> char *` and `mojo_anything_free(char *)`. `args` is a JSON array; the answer is allocated by the dispatcher and freed only by `mojo_anything_free` (`NULL` ignored). A port that raises answers `{"error": message}`; an unknown name, a wrong argument count or a value that does not convert answers `{"panic": message}`.
  - Decision recorded here: Mojo has no unwinding panics, so `{"panic"}` covers the dispatcher's own failures only; a port that aborts ends the process, and the drivers already run each case so that a crash is recorded as a crash.

- [ ] **Step 1: Write failing tests** (skip without Mojo or a C compiler):
  - `dispatcher_ok`: the C caller calls `add` with `[1.5, 2]` and reads `{"ok":3.5}`.
  - `dispatcher_error_and_panic`: a port raising `ArgumentError: bad` answers `{"error":"ArgumentError: bad"}`; name `nope` answers `{"panic":"unknown function: nope"}`; `[1]` for a two-argument function answers a `panic` naming the expected count; the process exits 0 after all three.
  - `dispatcher_free_null`: `mojo_anything_free(NULL)` returns.
  - `dispatcher_many_calls_no_growth`: 100,000 call-and-free rounds keep the resident set within 10 MB of the first 1,000 (checked from `/proc/self/status`).
- [ ] **Step 2:** Run `cargo test --test mojo_dispatcher`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: the Mojo JSON dispatcher over the C ABI`.

### Task 4: Go over the Mojo unit

**Files:**
- Modify: `src/codegen_go.rs` (`wrapper` calls `mojo_anything_*`; replace `typed_rs` with `typed_mojo`; delete `wire_rs`), `src/harness_go.rs` (build the Mojo library and point cgo at it), `src/bridge.rs` (Go writes `mojo/<unit>/`)
- Test: `tests/go_module_paths.rs`, `tests/go_internal_packages.rs`, `tests/go_mod_directives.rs`, `tests/go_record_cgo.rs` (switched to Mojo ports), fixture ports under `tests/fixtures/go-mojo-ports/`

**Interfaces:**
- Consumes: Tasks 2 and 3; `codegen_go::{results, used_types, package_name, driver}` unchanged.
- Produces:
  - `pub fn typed_mojo(m: &Manifest, api: &PortApi) -> String` — one `@export("mojo_anything_t_<name>")` per typed-eligible function (all parameters and results scalars or strings, at most one result plus `error`), with today's protocol: strings in as pointer plus length, string results written into a caller buffer with `*out_len`, status 0/1/2, error text freed with `mojo_anything_free`.
  - The wrapper uses the typed symbol where one exists and the dispatcher otherwise, as today.
  - `harness_go::build(unit_dir, m) -> Result<PathBuf>` builds `lib<lib>.so` (macOS `.dylib`) and writes the cgo `#cgo LDFLAGS` with its absolute path (pitfall: relative paths break in child processes).

- [ ] **Step 1: Write failing tests** (skip without Mojo or Go):
  - `go_mojo_loop_matches`: bridge the Go fixture, `record`, copy the fixture port, `build`, `diff` → every case matches.
  - `go_string_bytes_survive`: a fixture `func Echo(s string) string` matches on cases with `"\x00"`, `"\xff\xfe"` and a 1 MB string (exercising status 2).
  - `go_error_returned`: a fixture returning `errors.New("bad")` for one input matches with a Mojo port that raises `bad`.
  - `go_scalar_unit_builds_without_json`: the Task 2 scalar unit builds and passes `gate`.
  - The four existing Go test files pass with Mojo ports.
- [ ] **Step 2:** Run `cargo test --test go_module_paths --test go_internal_packages --test go_mod_directives --test go_record_cgo`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: Go units port to Mojo through typed exports and the dispatcher`.

### Task 5: Ruby over the dispatcher

**Files:**
- Modify: `src/codegen_ruby.rs` (`native` loads the Mojo library with Fiddle and calls `mojo_anything_call` with the existing `CODEC_RB`; delete `lib_rs`, `cargo_toml`, `RBCONV_RS`), `src/harness_ruby.rs` (build the Mojo library), `src/bridge.rs` (Ruby writes `mojo/<unit>/`)
- Test: `tests/ruby_recording.rs`, `tests/loop.rs` Ruby tests (switched to Mojo ports), fixture ports under `tests/fixtures/ruby-mojo-ports/`

**Interfaces:**
- Consumes: Task 3, `codegen_ruby::{wrapper, driver, camel, targets, CODEC_RB}`.
- Produces: the Ruby wrapper keeps the original module functions, defaults and keywords; each encodes its arguments with `CODEC_RB`, calls `mojo_anything_call`, frees the answer, and returns the value, raises the class named before `: ` in an `error` (falling back to `RuntimeError`), or raises `RuntimeError` with a `panic`'s message.
- Decision recorded here: the magnus extension (direct values, no JSON) is dropped for the dispatcher the spec names; Ruby calls get slower, and `docs/STATUS.md` says by how much once Task 6 measures it.

- [ ] **Step 1: Write failing tests** (skip without Mojo or Ruby):
  - `ruby_mojo_loop_matches`: bridge the Ruby fixture, `record`, port, `build`, `diff` → every case matches.
  - `ruby_error_class_raised`: a port raising `ArgumentError: bad` replays a recorded `ArgumentError` as matching.
  - `ruby_symbols_and_hashes`: cases with symbols and non-string hash keys (the `CODEC_RB` markers) match with a port that passes the value through.
  - `ruby_recording_fails_on_unencodable_results_and_preserves_cases` still passes.
- [ ] **Step 2:** Run `cargo test --test ruby_recording` and `cargo test --test loop ruby`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full gate.
- [ ] **Step 5: Commit** `feat: Ruby units port to Mojo through the dispatcher`.

### Task 6: Re-verify Go `path` and `shellwords.rb`

**Files:**
- Create: `demo/real-world/go-path-mojo/`, `demo/real-world/ruby-shellwords-mojo/` (bridged from Go 1.24's `path` and Ruby 3.3's `shellwords.rb` with the inputs of the Rust demos; manifest `root` placeholders)
- Modify: `docs/STATUS.md` (Go and Ruby rows), `docs/real-world-languages.md`

- [ ] **Step 1:** Bridge and `record` Go `path` with `go-path-rs/inputs.jsonl` and Go's own test tables; check 2,642 cases. Port the seven functions; `diff` → `2642/2642`; `gate` passes.
- [ ] **Step 2:** Bridge and `record` `shellwords.rb` with `ruby-shellwords-rs/inputs.jsonl`; check 1,617 cases (446 raise). Port; `diff` → `1617/1617`; `gate` passes.
- [ ] **Step 3:** `bench` both on a quiet machine, twice, naming the hardware and core count (pitfall); record the per-call cost of the typed path and the dispatcher next to the Rust numbers, slow rows included.
- [ ] **Step 4:** Update `docs/STATUS.md` and `docs/real-world-languages.md` with dates, counts, Mojo version and the bench numbers. Run `scripts/check-secrets.sh`.
- [ ] **Step 5: Commit** `feat: port Go's path and Ruby's shellwords to Mojo`.

### Task 7: Remove the Rust dispatcher and natives

**Files:**
- Modify: `src/codegen_ffi.rs`, `src/codegen_go.rs`, `src/codegen_ruby.rs`, `src/harness_go.rs`, `src/harness_ruby.rs` (no Rust generation or cargo builds left), `src/bridge.rs` (an `ffi` unit folder with a `Cargo.toml` fails with "bridge again"; `--batch` for Go and Ruby fails with the Global Constraints message), `src/codegen_batch_native.rs` (keep only what Java needs until Milestone 5, behind `Lang::Java | Lang::Kotlin`), `src/wire.rs` (Go removed; Java stays until Milestone 5), `DECISIONS.md`, `docs/pitfalls.md`
- Delete: `demo/real-world/go-path-rs/`, `demo/real-world/ruby-shellwords-rs/`
- Test: existing Go and Ruby tests

- [ ] **Step 1: Write failing tests** `rust_ffi_unit_says_rebridge` (a Go unit folder with `Cargo.toml` fails with `bridge again`) and `go_batch_not_yet` (`bridge --batch Clean:path` on a Go fixture exits non-zero with `not yet`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Remove.
- [ ] **Step 4:** `cargo fmt --all && cargo clippy --all-targets -- -D warnings && cargo test`. Expected: PASS; `rg -n "rust_anything_call|rust_anything_t_|magnus" src` finds nothing.
- [ ] **Step 5:** Update `DECISIONS.md` (one dispatcher for Go and Ruby; typed exports kept for Go; why magnus and the binary wire went) and `docs/pitfalls.md`.
- [ ] **Step 6: Commit** `refactor: drop the Rust dispatcher, magnus and Go's binary wire`.
