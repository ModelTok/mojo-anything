# Status

What works, and how each part was last checked. Updated 2026-11-21.

**Verified**: run end to end (bridge, record, port, diff, gate) on real code someone else wrote,
named below. **Tested**: covered by this repository's tests on fixtures written for them, not yet
run on a real project. **Whole apps**: `analyze` and the whole-app flow (`app record`, `app replay`,
front door); units cannot be bridged yet.

## Porting units

| Language | Status | Last real run | Result |
| --- | --- | --- | --- |
| TypeScript/JavaScript | Verified | [ESLint](real-world.md#eslint) (2026-11-21), [Prettier](real-world.md#prettier) (2026-11-18), [json-server](real-world.md#json-server) (2026-11-18), [Fuse.js](real-world.md#fusejs) (2026-11-18), [vercel/ms](real-world.md#vercelms) (2026-11-18), x18n's `packages/core` | ESLint: `eslint-stdin-rs` 10,192/10,192, gate passes, front door replay 10,585/10,585 at 3.6% fallback (CommonJS module bridged); Prettier: `doc-printer-rs` 2,848/2,848 and `js-format-rs` 15,753/15,753, gate passes on both; json-server: six units, 3,399 cases, gate passes on each; Fuse.js, vercel/ms, x18n: 3,414/3,414, 975/975 and 7,925 cases match |
| Python | Verified | `colorsys.py` from CPython 3.13: to Mojo 1.2.0 (2026-11-21) | Mojo: 2,400/2,400 against the 3.13 recording and 1,362/1,362 against a fresh 3.12 recording, gate passes (`demo/real-world/python-colorsys-mojo`) |
| Go | Tested (Mojo) | `tests/go_mojo.rs` fixture to Mojo 1.2.0 (2026-11-22): typed cgo exports and the JSON dispatcher, every case matches; `path` from Go 1.24 verified on the Rust port only (2026-11-16, 2,642/2,642), not yet on Mojo | Mojo: fixture loop, error returns, NUL and invalid UTF-8 bytes through the typed path, a scalar unit without JSON passes `gate`; Go `--batch` answers "not yet" |
| Ruby | Verified | `shellwords.rb` from Ruby 3.3 (2026-11-16) | 1,617/1,617; gate passes |
| Java | Verified | JDK 21 behind a facade (2026-11-16) | 4,492/4,492; gate passes |
| C | Verified | to Mojo 1.2.0 (2026-11-21): ffmpeg libavutil n7.1's `rational.c`, glibc behind a facade | Mojo: `rational.c` 46,764/46,764 with ffmpeg's own signatures (`demo/real-world/ffmpeg-mojo`), glibc facade 2,488/2,488 on a fresh recording and 1,859/1,859 on the Rust-era one (`demo/real-world/c-libc-mojo`), gate passes on both. The other nine ffmpeg units are Rust ports only (`demo/real-world/ffmpeg-rs`, 2026-11-20), not ported to Mojo yet |
| Kotlin | Tested | none | `analyze`, detection, JNI-shaped exports, bridge, record and diff on a Gradle fixture (`tests/loop.rs`); needs `kotlinc` on PATH, so CI skips it |
| Kotlin for Android | Tested | none | `build --profile android` builds one installed ABI per test run into `jniLibs/` with every JNI entry point and the 16 KB alignment checked; all three ABIs were also built by hand, and the `armeabi-v7a` library was loaded on an Android 11 TV and called through JNI. `record --profile android` replayed the Kotlin unit under ART on that TV (291 cases) and `diff --profile android` matched 279/291 against the Android `.so`. Needs the NDK/device, so CI skips it |
| PHP | Whole apps | none | `analyze` and whole apps only; units cannot be bridged yet |
| C# | Whole apps | none | `analyze` and whole apps only; units cannot be bridged yet |

Details of every run: [real-world.md](real-world.md) (TS/JS) and
[real-world-languages.md](real-world-languages.md) (the others).

## Commands

| Command | Status | Notes |
| --- | --- | --- |
| `analyze` | Verified | every language above, x18n's 142 units |
| `bridge`, `record`, `diff`, `gate`, `build` | Verified | the runs above; `bridge --as-json` on json-server's `paginate` |
| JSON for Mojo units (`src/mojo/json.mojo`) | Tested | EmberJson 0.5.0 plus `$num` markers: 473 V8 floats round-trip bit for bit, 64-bit integers exact, big integers and lone surrogates refused, 200 deep (`tests/mojo_json.rs`, 2026-11-22); no unit emits it yet |
| `build --profile android` | Tested | Kotlin fixture, one ABI per test run (all three built by hand), entry points and 16 KB alignment checked; `armeabi-v7a` library loaded on an Android 11 TV and called through JNI |
| `record`/`diff --profile android` | Tested | Kotlin fixture on an Android 11 TV: record 291 cases under ART, then diff against the Android `.so` (12 of them did not match yet, not investigated); guarded test `tests/android_device.rs` skips without a device |
| Types for untyped JS in `bridge` (sibling `.d.ts`/`.d.mts`/`.d.cts`, then JSDoc) | Tested | `tests/untyped_js_types.rs` |
| `bench` | Verified | the runs above; numbers in [real-world.md](real-world.md) |
| `fuzz` | Tested | TS/JS: finds a planted mismatch the recording missed, `--keep` makes `gate` fail (`tests/fuzz.rs`); other languages share the record/diff path untested |
| `record --pin-clock` | Tested | TS/JS (napi): a unit using `Date.now()` and `Math.random` recorded and matched by a Rust port (`tests/fuzz.rs`); Python driver shares the algorithm, untested on a real port |
| `record --from-tests` | Verified (TS/JS), Tested (Python) | vercel/ms's Jest suite |
| Coverage of the original in `record` and `gate` | Verified (TS/JS) | Fuse.js: cases run 81% of the lines it imports; other languages do not measure it yet |
| `--batch` | Verified | Fuse.js, vercel/ms, x18n search |
| wasm bridge (`--kind wasm`) | Verified | x18n search |
| `shadow` | Verified | x18n's `packages/core` |
| `profile` | Tested | |
| `map` | Tested | ports, upstream changes and `--crates` in `tests/port_map.rs` |
| `app record`, `app replay` | Verified (servers and CLIs) | json-server: 514 HTTP cases with `--fresh`, `--arg`, `--pace`; Prettier: 17,224 CLI cases with `--inputs`, 63 of them with config files around the input; CLIs in `tests/app.rs`, CLI `--fresh` in `tests/app_fresh.rs` |
| Side effects (`app record --effects`, `--db-reset`, `--db-dump`) | Tested | email, webhooks and SQLite rows for a CLI and a server in `tests/effects.rs` |
| Front door (`front-door`), `wire` | Verified (TS server and CLI) | Prettier: one unit wired, 17,224/17,224 at 7.9% fallback, plus 355 cases from fuzzing and mutation testing (`demo/real-world/prettier-rs/equiv`) (JS, TS, JSX, JSON, GraphQL, YAML, Markdown, CSS, SCSS and Less in Rust), glue declining per case with `original::run_with_stdin`; json-server: reads wired first (22.6% fallback), then every route (0%); a `rust/` that is a symlink in `tests/app_fresh.rs`; servers in eight languages in `tests/http.rs` |
| `lift` | Verified (TS server), Tested (CLIs) | json-server: pure Rust binary, 514/514; CLIs in all eight languages in `tests/app.rs` |
| `package` | Tested | napi and wasm demos installed from their packages on macOS arm64 (2000/2000, 2000/2000); Python units (Mojo) cannot be packaged yet; napi tarball install and fallback in `tests/package.rs`; the generated GitHub workflows have not run yet |
| MCP server (`mcp`) | Tested | protocol test in `src/mcp.rs` |
| `setup` | Tested | registers the MCP server (and the skill, where the agent reads skills) with Claude Code, Codex, Cursor, Gemini CLI and OpenCode; per-agent tests in `src/setup.rs`, read back in `src/doctor.rs` and `tests/doctor.rs`. The OpenCode entry was also confirmed by OpenCode 2.3.2 itself (`mcp.servers`, `command` as an array) |

## Where the tests run

CI installs Node, Python, Go, Ruby and Java on macOS and Windows. It does not install PHP, .NET,
Kotlin, the Android NDK or an Android device, so the PHP, C#, Kotlin and Android tests skip there
and run only on a machine that has them.
