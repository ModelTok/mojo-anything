# Milestone 5: Java and Kotlin to Mojo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Java and Kotlin units bridge to Mojo ports that the original classes call through the Foreign Function & Memory API (Java 22+) over the M3 JSON dispatcher; the JDK facade is re-verified on Java 22+; JNI generation, Android support and the binary wire are removed.

**Architecture:** A new kind `mojo-jvm`. `bridge` writes `mojo/<unit>/` with `port.mojo`, `dispatch.mojo` (M3's dispatcher, built as a shared library) and generated Java sources: `mojoanything/MojoAnythingJson.java` (today's dependency-free codec, renamed), `mojoanything/<Lib>Native.java` (one `MethodHandle` for `mojo_anything_call` and one for `mojo_anything_free`, found with `SymbolLookup.libraryLookup` and `Linker.nativeLinker()`), and wrapper classes with the original names and static-method signatures. The reflection driver for record, diff and bench stays; it is compiled against the originals to record and against the wrappers to diff. Kotlin reuses the Java artefacts, in the Java shape the Kotlin compiler emits (`<File>Kt`, `@JvmStatic` members).

**Tech Stack:** Rust 2024 (the tool), Mojo via pixi, Java 22+ (`java.lang.foreign`), kotlinc for Kotlin units.

**Spec:** `docs/superpowers/specs/2026-11-21-mojo-anything-design.md` (Phase 1, Java/Kotlin row of "Bridge per source language"; "Non-goals": Android; "Dropped from Phase 1": `wire.rs`; "Decided by the user": FFM, Java 22+).

## Global Constraints

- Everything in M1's Global Constraints holds (WSL clone, pixi-pinned Mojo, `docs/mojo-notes.md` spellings only, names, the Rust gate before each commit, Mojo tests skip when `crate::mojo::available()` is false, helpers emitted only when used, UK English).
- Java/Kotlin units require Java 22 or newer. `bridge`, `record` and `build` check `java -version` and `javac -version` and stop with one line naming the version found and the minimum, 22.
- Generated Java uses no preview features and no `--enable-preview`; it calls `java.lang.foreign` only. Drivers and wrappers run with `--enable-native-access=ALL-UNNAMED` so Java 22+ prints no restricted-method warning to stdout or stderr that could reach a recording.
- JVMs started by the tool keep `-XX:-UsePerfData` (pitfall: a JVM warning failed a case).
- Kotlin owners follow the JVM shape: top-level functions on `<File>Kt`, `@JvmStatic` members on the enclosing class (pitfall: Kotlin's JVM owner is not the file name).
- Strings cross as UTF-8 with an explicit length; Java `String`s holding lone surrogates use the codec's `$utf16` marker, never a lossy encode.

## Review Focus

1. **A rejected argument is not `null`.** A wrapper must distinguish a port returning `null` from one raising `IllegalArgumentException` (today's `java_replay_distinguishes_null_from_a_rejected_argument`). Test: Task 3 `jvm_replay_distinguishes_null_from_a_rejected_argument`.
2. **Exception types survive.** `{"error": "java.lang.NumberFormatException: For input string: \"x\""}` must throw that class with that message, through the generated `MojoAnythingError` mapping, falling back to `RuntimeException` for classes that cannot be constructed from a message. Test: Task 2 `error_maps_to_declared_exception`.
3. **Old JDK on PATH.** With Java 21 first on `PATH`, `bridge` and `build` stop before generating or compiling anything, naming 22. Test: Task 1 `java_21_is_refused`.
4. **Calls from many threads.** Wrappers called from 8 threads at once must not share a native buffer or free a result twice. Test: Task 3 `jvm_parallel_calls_match`.
5. **Kotlin top-level functions and companion objects** in one unit: both owners resolve and replay. Test: Task 4 `kotlin_top_level_and_companion_replay`.

---

### Task 1: The `mojo-jvm` kind and the Java version check

**Files:**
- Modify: `src/bridge.rs` (`Kind::MojoJvm` serialised `"mojo-jvm"`; Java and Kotlin map to it), `src/analyze.rs` (`Bridge::MojoJvm`, shown as `Mojo (Java FFM)`), `src/doctor.rs` (report the Java version and the 22 minimum)
- Create: `src/jvm.rs`
- Test: unit tests in `src/jvm.rs`, `src/analyze.rs`; `tests/jvm_version.rs`

**Interfaces:**
- Consumes: M1 `RType::mojo`.
- Produces:
  - `Kind::MojoJvm`.
  - `pub const MIN_JAVA: u32 = 22;`
  - `pub fn java_major(version_output: &str) -> Option<u32>` — reads `java -version` / `javac -version` output (`"22.0.1"`, `"1.8.0_402"` → 8, `"23-ea"` → 23).
  - `pub fn require_java() -> Result<()>` — runs both tools through `crate::process`; errors with `Java 22 or newer is needed for Java and Kotlin units; found <n> (<path>)`.

- [ ] **Step 1: Write failing tests:**
  - `java_major_reads_versions`: the three strings above.
  - `java_bridges_to_mojo_jvm`: `analyze` on `tests/fixtures/java` reports `Mojo (Java FFM)`.
  - `java_21_is_refused` (in `tests/jvm_version.rs`): with a fake `java`/`javac` on `PATH` printing `21.0.2` (written with `cp` from a text fixture, pitfall: "Text file busy"), `bridge` fails and the message contains `22`, and no `mojo/` folder is written.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement; call `require_java` at the start of `bridge`, `record` and `build` for Java and Kotlin units.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: add the mojo-jvm bridge kind and require Java 22`.

### Task 2: Generated Java over the dispatcher

**Files:**
- Create: `src/codegen_mojo_jvm.rs`
- Modify: `src/codegen_java.rs` (keep `JSON_JAVA`, `DRIVER_JAVA`, `ERROR_JAVA`, `wrappers`, `targets`, `shadows`, renamed into package `mojoanything`; delete nothing yet), `src/lib.rs`
- Test: unit tests in `src/codegen_mojo_jvm.rs`; `tests/jvm_codegen.rs`

**Interfaces:**
- Consumes: M3 `codegen_mojo_ffi::dispatcher_mojo(m: &Manifest, api: &PortApi) -> String`, `src/mojo/json.mojo`; `codegen_java::{wrappers, JSON_JAVA, ERROR_JAVA}`; `lang::java::receiver`.
- Produces:
  - `pub fn native_class_ffm(m: &Manifest) -> String` — `mojoanything.<Lib>Native` with `static String call(String name, String argsJson)`: allocates the two UTF-8 arguments in a confined `Arena` per call, invokes `mojo_anything_call`, copies the returned C string into a Java `String`, calls `mojo_anything_free`. The library is found next to the classes (`<lib>_mojo` via `System.mapLibraryName`) or from `MOJO_ANYTHING_LIB`.
  - `pub fn wrappers_ffm(m: &Manifest, api: &PortApi) -> Vec<(String, String)>` — today's `wrappers` with the JNI call replaced by `<Lib>Native.call` plus codec encode/decode; `{"error"}` goes through `MojoAnythingError.raise`, `{"panic"}` throws `IllegalStateException("panic in <name>: ...")`.
  - `MojoAnythingError` (renamed `ERROR_JAVA`) keeps resolving exception constructors with plain reflection.

- [ ] **Step 1: Write failing tests:**
  - `native_class_uses_foreign_api`: the output imports `java.lang.foreign`, looks up `mojo_anything_call` and `mojo_anything_free`, and has no `native` method and no `System.loadLibrary`.
  - `wrapper_keeps_original_signature`: for the `tests/fixtures/java` unit, the wrapper for each export has the original class, name, parameter and return types.
  - `error_maps_to_declared_exception` (in `tests/jvm_codegen.rs`; needs `javac` 22+): compile `MojoAnythingError` alone and check that `raise("java.lang.NumberFormatException: For input string: \"x\"")` throws `NumberFormatException` with that message, and an unknown class throws `RuntimeException` carrying the whole text.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: generate Java wrappers over the Mojo dispatcher with FFM`.

### Task 3: Bridge, build and diff for Java

**Files:**
- Create: `src/harness_mojo_jvm.rs`
- Modify: `src/bridge.rs` (`bridge` and `refresh` for `Kind::MojoJvm`), `src/harness.rs` (`build` dispatch), `src/harness_java.rs` (`compile(crate_dir, m, rust: bool)` becomes `compile(unit_dir, m, against: Against)` with `Against::{Original, Port}`; driver flags add `--enable-native-access=ALL-UNNAMED`)
- Test: `tests/java_replay.rs` (switched to `mojo-jvm`), `tests/loop.rs` `java_mojo_*`, fixture `tests/fixtures/java-mojo-port/port.mojo`

**Interfaces:**
- Consumes: Tasks 1–2; `harness_java::{record, diff, bench}`.
- Produces:
  - `pub enum Against { Original, Port }`.
  - `pub fn build(unit_dir: &Path, m: &Manifest) -> Result<PathBuf>` — builds `dispatch.mojo` with `--emit shared-lib` into the unit's `build/` and returns the library path; Java sources compile in `diff`, as today.
  - Bridge output: `mojo/<unit>/{port.mojo, dispatch.mojo, json.mojo, java/mojoanything/*.java, java/<original packages>/*.java, pixi.toml, mojo-anything.json, README.md}`.

- [ ] **Step 1: Write failing tests** (skip without Mojo or Java 22+):
  - `java_mojo_bridge_files`: the file list above.
  - `java_mojo_loop_matches`: bridge `tests/fixtures/java`, `record`, copy the fixture port, `build`, `diff` → every case matches.
  - `jvm_replay_distinguishes_null_from_a_rejected_argument`: the existing `tests/java_replay.rs` case on `mojo-jvm`.
  - `jvm_parallel_calls_match`: a generated test class calls one wrapper from 8 threads, 10,000 calls each, and every result equals the single-threaded result.
  - `java_mojo_rebuild_after_edit`: edit the port to a wrong value, `build`, `diff` → mismatches.
- [ ] **Step 2:** Run `cargo test --test java_replay` and `cargo test --test loop java_mojo`. Expected: FAIL.
- [ ] **Step 3:** Write the fixture port and implement.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: bridge, build and diff Java units as Mojo ports`.

### Task 4: Kotlin

**Files:**
- Modify: `src/codegen_kotlin.rs` (point at the FFM artefacts), `src/harness_kotlin.rs` (`compile` with `Against`, remove `needs_android_sdk` and `android_classes`), `src/lang/kotlin.rs` (exports keep the JVM owner; drop Android-only detection)
- Test: `tests/loop.rs` (`kotlin_functions_bridge_record_and_diff` on `mojo-jvm`), new `kotlin_top_level_and_companion_replay`, fixture `tests/fixtures/kotlin-mojo-port/port.mojo`

**Interfaces:**
- Consumes: Tasks 2–3 (`wrappers_ffm`, `native_class_ffm`, `Against`).
- Produces: no new names; Kotlin units bridge with `Kind::MojoJvm` and diff through Java wrappers named for `<File>Kt` and `@JvmStatic` owners.

- [ ] **Step 1: Write failing tests** (skip without Mojo, kotlinc or Java 22+):
  - `kotlin_functions_bridge_record_and_diff`: the existing test, with the Mojo fixture port, every case matching.
  - `kotlin_top_level_and_companion_replay`: a fixture file `Text.kt` with a top-level `fun slug(s: String): String` and `class Units { companion object { @JvmStatic fun parse(s: String): Long } }` bridges both (owners `TextKt` and `Units`), and both replay.
- [ ] **Step 2:** Run `cargo test --test loop kotlin_`. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: Kotlin units port to Mojo through the Java wrappers`.

### Task 5: The gate for `mojo-jvm`

**Files:**
- Modify: `src/gate.rs` (dispatch `Kind::MojoJvm` to `mojo_checks`, plus an API check that compiles the wrappers against the original call sites)
- Test: `tests/loop.rs` `java_mojo_gate_*`

**Interfaces:**
- Consumes: M1 `gate::mojo_checks(unit_dir: &Path) -> Vec<Check>`, Task 3 `Against`.
- Produces: no new names; the API check is named `java api` and fails with a fix naming `mojo-anything refresh`.

- [ ] **Step 1: Write failing tests** `java_mojo_gate_passes` (the Task 3 matching unit) and `java_mojo_gate_fails_on_changed_signature` (a wrapper whose return type was edited from `long` to `int` fails `java api`).
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** Run. Expected: PASS; full Rust gate.
- [ ] **Step 5: Commit** `feat: gate Mojo ports of Java and Kotlin units`.

### Task 6: The JDK facade on Java 22+, ported to Mojo

**Files:**
- Create: `demo/real-world/java-jdk-mojo/` (the facade from `demo/real-world/java-jdk-rs/original`: `Integer`, `Long`, `Math`, `Double.toString`, `URLEncoder`, `Base64`, `toUpperCase`; inputs from its `inputs.jsonl`; manifest `root` a placeholder)
- Modify: `docs/STATUS.md` (Java and Kotlin rows), `docs/real-world-languages.md` (Java row: Java version, case count, result)

- [ ] **Step 1:** Bridge and `record` on Java 22+. Expected: about 4,492 cases; any count other than the Rust demo's is explained in `docs/real-world-languages.md` (JDK 22 behaviour changes), not hidden.
- [ ] **Step 2:** Port the 11 functions. `Double.toString` follows Java's algorithm (Java 19+ shortest digits, Raffaello Giulietti's), not JS's: test ties and the `1.0E10` exponent form explicitly.
- [ ] **Step 3:** `build`, `diff`. Expected: every case matches.
- [ ] **Step 4:** `gate`. Expected: every check passes.
- [ ] **Step 5:** `bench` twice on a quiet machine; record per-call numbers with hardware and core count, including the rows slower than Java.
- [ ] **Step 6:** `scripts/check-secrets.sh`; update `docs/STATUS.md`.
- [ ] **Step 7: Commit** `feat: port the JDK facade to Mojo on Java 22+`.

### Task 7: Remove JNI, Android and the binary wire

**Files:**
- Delete: `src/android.rs`, `src/android_device.rs`, `tests/android_device.rs`, `src/wire.rs` (and whatever of it M3 left for Go), `demo/real-world/java-jdk-rs/`
- Modify: `src/codegen_java.rs` (delete `native_class`, `typed_rs`, `wire_rs`, `WIRE_JAVA`, `mangle_jni_component`), `src/codegen_ffi.rs` (drop `java_native_class` if unused), `src/codegen_batch_native.rs` (drop the JNI batch path), `src/harness.rs` (`record_android`, `build_android`, `diff_android`), `src/main.rs` (`--profile android`, `--device`, `--abi`, `--api`, `--ndk`, `--jni-libs`; `Profile::Android`), `src/mcp.rs`, `src/doctor.rs`, `src/crates.rs` and `src/crates.toml` (Android entries), `src/whole_app.rs`, `src/bridge.rs` (`"kind": "ffi"` manifests for Java fail with "bridge again"), `docs/pitfalls.md` (move the Android and JNI entries under a "Removed" heading with one line each on why they no longer apply), `DECISIONS.md`
- Test: existing Java and Kotlin tests now on `mojo-jvm`

- [ ] **Step 1: Write failing tests** `android_profile_is_gone` (`mojo-anything build --profile android .` exits non-zero with clap's "invalid value" message) and `java_ffi_manifest_says_rebridge`.
- [ ] **Step 2:** Run. Expected: FAIL.
- [ ] **Step 3:** Remove the code above.
- [ ] **Step 4:** `cargo fmt --all && cargo clippy --all-targets -- -D warnings && cargo test`. Expected: PASS; `rg -n -i "jni|android|ndk|wire_rs" src tests` finds only the rebridge message, its test and the removed-pitfalls note.
- [ ] **Step 5:** Update `DECISIONS.md` (Java and Kotlin reach Mojo through FFM, Java 22+; Android removed because Mojo does not target it; the binary wire deferred) and `docs/STATUS.md` (drop the two Android rows, the Android CI note and the JNI numbers in `docs/real-world-languages.md`).
- [ ] **Step 6: Commit** `refactor: drop JNI, Android and the binary wire`.
