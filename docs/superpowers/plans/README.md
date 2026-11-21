# mojo-anything plans

Implements [the design](../specs/2026-11-21-mojo-anything-design.md). Run in order; each plan
assumes the names in the Interfaces blocks of the plans before it. When one lands differently,
fix the later plans before starting them.

| # | Plan | Tasks | Ends with |
| --- | --- | --- | --- |
| 1 | [Python to Mojo](2026-11-21-m1-python-to-mojo.md) | 10 | Renamed tool, Mojo toolchain pinned, `colorsys.py` 2,400/2,400, PyO3 removed |
| 2 | [C to Mojo](2026-11-21-m2-c-to-mojo.md) | 6 | `@export` drop-ins; ffmpeg `rational.c` and the glibc facade re-verified |
| 3 | [JSON dispatcher, Go, Ruby](2026-11-21-m3-json-dispatcher.md) | 7 | `json.mojo` (`JsonValue`), `mojo_anything_call`; Go `path`, `shellwords.rb` re-verified |
| 4 | [TS/JS to Mojo](2026-11-21-m4-ts-js-to-mojo.md) | 9 | Node-API C shim, `--batch`, shadow, fuzz; vercel/ms 975/975; then `--kind wasm` |
| 5 | [Java and Kotlin](2026-11-21-m5-java-kotlin-to-mojo.md) | 7 | FFM on Java 22+; JNI, Android and `wire.rs` removed; JDK facade re-verified |
| 6 | [Whole apps](2026-11-21-m6-whole-apps-in-mojo.md) | 9 | Mojo front door, `wire`, `lift`; one CLI lifted; server route decided by a spike |
| 7 | [Packaging, docs, release](2026-11-21-m7-package-docs-release.md) | 8 | Packages per bridge, MCP/setup/docs under the new name, every number re-measured, tag `v0.1.0` (Phase 1 done) |
| 8 | [Self-port foundation](2026-11-21-m8-self-port-foundation.md) | 8 | `v0.1.0` recorded on its fixtures; Mojo front door in `tool/` with fallback; plumbing, CLI, doctor/map/setup, `app record`/`replay` in Mojo |
| 9 | [Self-port commands](2026-11-21-m9-self-port-commands.md) | 9 | Every command in Mojo, tests ported, all Rust deleted, 0% fallback (Phase 2 done) |

## Decisions the plans made that the design left open

- Bridge kinds: `mojo-py` (M1), `c-abi` kept as a name (M2), `mojo-node` and `mojo-wasm` (M4), `mojo-jvm` (M5); `--kind napi` becomes `--kind node`.
- Ruby is a magnus extension today, not Fiddle as the design assumed; M3 moves it to Fiddle over the dispatcher and benchmarks the cost.
- Go keeps typed exports beside the dispatcher (M3); Go and Ruby `--batch` say "not yet" until measured.
- Mojo has no unwinding panics: `{"panic"}` covers dispatcher failures only, and an aborting port is recorded as a crash (M3).
- The Phase 2 tool lives in `tool/`, with the `v0.1.0` binary built into `tool/fallback/` (M8).
- Release platforms: Linux x64/arm64 and macOS arm64 (M7); Phase 2 reaches users through the npm wrapper downloading the Mojo binary (M9).

## Outward-facing steps (ask the user at the time)

Creating the public repository (M1 Task 0), pushing tags and publishing packages or registry
entries (M7 Task 8).
