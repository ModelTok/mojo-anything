# C++ to Mojo — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** C++ free functions over numbers, `bool`, `std::string` and `std::vector` of numbers are bridged, recorded, ported to Mojo and checked (`diff`, `bench`, `gate`) as C units are, and C++ callers link against the Mojo port unchanged; shown on one EnergyPlus psychrometrics routine.

**Architecture:** A C++ unit is a `c-abi` unit with `language: cpp`. `src/lang/cpp.rs` (tree-sitter-cpp) finds the exports and refuses what is outside the subset. `src/codegen_cpp.rs` writes the only C++-aware layers: `cpp/shim.cpp` (an `extern "C"` function `cpp__<ns>__<name>` per export, used to record the original) and `cpp/wrapper.cpp` (the original signatures over the Mojo exports), plus `port.mojo` stubs and `exports.mojo`. The C driver in `harness_c.rs` gains the kinds C has no equivalent for (string with a length, array of numbers, callee-allocated results, the error slot) and records and diffs both libraries.

**Tech Stack:** Rust 2024, tree-sitter 0.27 with tree-sitter-cpp, `c++` (g++ 13), CPython ctypes, Mojo 1.2.0 via pixi, WSL Ubuntu 24.04.

**Spec:** `docs/superpowers/specs/2026-11-22-cpp-to-mojo-design.md`.

## Global Constraints

- Work in the WSL worktree `~/github/mojo-anything-cpp` (branch `cpp-to-mojo`), with `CARGO_TARGET_DIR=/tmp/cpptarget`; never touch `~/github/mojo-anything`, the other worktrees, `~/github/EnergyPlus` or `~/github/EnergyPlus-fast`.
- Reuse the C path: no second driver, no second build. Only generated C++ (`cpp/shim.cpp`, `cpp/wrapper.cpp`) sees C++ types.
- The one new dependency is tree-sitter-cpp, added with `cargo add` and recorded in `DECISIONS.md`. No other installs.
- `port.mojo` holds no pointers; `exports.mojo` reads and writes them, a `# SAFETY:` comment above every `external_call` and pointer line. Generated Mojo passes `mojo format` and builds with `--Werror`.
- Generated helpers are emitted only when a unit uses them (pitfall: unused helpers failed clippy).
- Every test is seen failing before the change that makes it pass. Tests that need `c++`, Python or Mojo skip with a reason when they are missing.
- Before each commit: `cargo fmt --all`, `cargo clippy --all-targets -- -D warnings`, `cargo test --no-fail-fast` (counts in the ledger), `scripts/check-secrets.sh`, `docs/STATUS.md` updated. Commit with `git commit -F`, never push.
- Benchmark numbers are not published: the machine is shared. `bench` is run once to check it works.
- Prose in UK English.

## Review Focus

1. **Mangled names.** The wrapper must define exactly the symbols the original defines (`const std::string &` against `std::string`, `int64_t` against `long long`, nested namespaces), or C++ callers fail to link. Test: Task 5 `cpp_caller_links_against_the_wrapper`, Task 6 `cpp_gate_fails_on_changed_signature`.
2. **Exceptions at the boundary.** No exception may unwind through `extern "C"` or Mojo: the shim catches everything, the error text is `<type>: <what()>`, the wrapper rethrows the same standard type. Test: Task 3 `cpp_records_exceptions_as_errors`, Task 5 the caller's `catch`.
3. **Memory across the ABI.** Callee-allocated results are `malloc`ed by the shim and by Mojo and freed with the same `free` by the driver and the wrapper; empty strings and vectors never pass `NULL` with a length. Test: Task 4 `cpp_every_type_round_trips` (empty string, empty vector, NUL-free UTF-8, 3 MB string).
4. **Refusals are complete and say what to do.** Classes, member functions, templates, overloads, state objects, pointers, rvalue references, `inline`/`constexpr` definitions and types outside the subset each refuse with a reason naming the facade route. Test: Task 1 `refuses_everything_outside_the_subset`, Task 2 bridge notes.
5. **Bit-exact floats in the demo.** The EnergyPlus routine must match every recorded case bit for bit: no folded literals (pitfall), no fused multiply-adds the original does not do. Test: Task 7 `diff` count, every case.

---

### Task 1: The C++ language plugin

**Files:** `Cargo.toml` (tree-sitter-cpp), `src/lang/cpp.rs` (new), `src/lang/mod.rs`, `src/analyze.rs`, `src/risks.rs`, `src/whole_app.rs`, `src/error_paths.rs`, `src/profile.rs`, `tests/fixtures/cpp/` (new), `tests/analyze.rs`.

- [ ] Write failing tests: `src/lang/cpp.rs` unit tests (`reads_the_subset`, `refuses_everything_outside_the_subset`, `resolves_aliases_and_using_namespace_std`, `discovers_cpp_files_and_merges_headers`), `src/lang/mod.rs` `cpp_project_with_headers_is_cpp`, `tests/analyze.rs` `cpp_fixture_lists_units_and_refusals`.
- [ ] `cargo add tree-sitter-cpp`; `Lang::Cpp` (`cpp`, "C++"), extensions, registry, detection (`.cpp` files and no `.c` files make `.h` headers C++).
- [ ] `discover`, `scan` (includes, risks: pointers, `new`/`delete`, `throw`/`try`, templates, threads), `resolve` (`"x.hpp"` to `x.cpp`), `exports` (free functions in namespaces, the subset, every refusal) and classes as refused `ExportedClass`es.
- [ ] Fixture `tests/fixtures/cpp`: `src/kit.hpp`/`src/kit.cpp` (every subset type, a throwing function, nested namespace), `src/refused.cpp` (class, member function, template, overload, state object, pointer, rvalue reference, `inline`, `constexpr`, `std::map`), `src/main.cpp`, `CMakeLists.txt`.
- [ ] Tests pass; commit.

### Task 2: Bridge a C++ unit

**Files:** `src/codegen_cpp.rs` (new), `src/bridge.rs`, `src/lib.rs`.

- [ ] Write failing tests: `codegen_cpp` unit tests (`port_stubs_over_mojo_types`, `shim_converts_and_catches`, `wrapper_keeps_original_signatures`, `exports_mojo_emits_only_used_helpers`), `tests/cpp_mojo.rs` `cpp_bridge_writes_the_unit` (files, notes for every refusal).
- [ ] `bridge` on a C++ unit writes `port.mojo`, `exports.mojo`, `cpp/shim.cpp`, `cpp/wrapper.cpp`, `pixi.toml`, `README.md` and the manifest (`kind: c-abi`, `language: cpp`); `refresh` rewrites the generated files.
- [ ] Tests pass; commit with Task 3.

### Task 3: Record a C++ unit

**Files:** `src/harness_c.rs`.

- [ ] Write failing tests: `tests/cpp_mojo.rs` `cpp_records_every_type` (expected `ok` lines for each type) and `cpp_records_exceptions_as_errors`.
- [ ] `record` compiles the original sources (not `main`, not tests) and `cpp/shim.cpp` with `c++ -std=c++17 -shared -fPIC` plus `CXXFLAGS`; signatures for the new kinds (`utf8`, `array:<ctype>`, `retlen`, `error`, `owned:str`, `owned:array:<ctype>`); the driver passes and frees them.
- [ ] Tests pass; commit.

### Task 4: Build and diff a C++ unit

**Files:** `src/codegen_cpp.rs`, `src/harness_mojo_c.rs`, `docs/mojo-notes.md`.

- [ ] Write failing tests: `cpp_every_type_round_trips` (port with every type, every case passes), `cpp_wrong_port_mismatches` (an edited port fails the right cases), `cpp_port_errors_match` (a raising port matches the recorded exception text).
- [ ] `exports.mojo` for C++ kinds; `build` builds only the drop-in library for C++ (no shadow); notes for any Mojo API newly relied on.
- [ ] Tests pass; commit.

### Task 5: C++ callers link unchanged

**Files:** `src/codegen_cpp.rs`, `tests/cpp_mojo.rs`.

- [ ] Write failing test `cpp_caller_links_against_the_wrapper`: a caller compiled against `src/kit.hpp`, linked against the original and against `cpp/wrapper.cpp` plus the Mojo library, prints the same, an exception caught by type included.
- [ ] Fix whatever the wrapper gets wrong; tests pass; commit.

### Task 6: Gate and bench

**Files:** `src/gate.rs`, `src/harness_c.rs`, `src/harness.rs`.

- [ ] Write failing tests: `cpp_gate_passes`, `cpp_gate_fails_on_changed_signature` (`cpp api` names the symbol), `cpp_bench_runs`.
- [ ] `cpp api` check (mangled names from `nm` of the original's object and the wrapper's); size check counts the unit and its header; `bench` through the driver's bench mode.
- [ ] Tests pass; commit.

### Task 7: EnergyPlus psychrometrics demo

**Files:** `demo/real-world/energyplus-psychro-mojo/` (new).

- [ ] Clone NREL/EnergyPlus into `~/github/EnergyPlus-mojo` (branch `mojo/psychrometrics`), check the licence, pick a pure routine (or a minimal facade), copy it with its notice.
- [ ] Bridge, record, port bit for bit, `diff` (every case), `gate`, `bench` once; README with the counts, numbers pending a quiet machine; `scripts/verify.sh`.
- [ ] Commit.

### Task 8: Docs

**Files:** `docs/STATUS.md`, `docs/real-world-languages.md`, `README.md` (Languages section), `docs/how-it-works.md` if it lists languages, `DECISIONS.md`, `docs/pitfalls.md`, `CONTRIBUTING.md` (C++ in Set up).

- [ ] C++ rows, decision rows (the shim route, tree-sitter-cpp, exceptions, names, bench), pitfalls found on the way.
- [ ] Commit.
