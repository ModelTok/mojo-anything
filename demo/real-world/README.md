# Real-world ports

The crates mojo-anything produced in the runs described in
[`docs/real-world-languages.md`](../../docs/real-world-languages.md): each holds the port
(`port.mojo` in the `-mojo` folders, `src/port.rs` in the Rust ones from before mojo-anything
targeted Mojo), the generated bridge, `cases.jsonl` (the recorded behavior of the original) and,
where used, `inputs.jsonl` (extra inputs passed to `mojo-anything record --inputs`).

| Crate | Original | Where it came from |
| --- | --- | --- |
| `go-path-mojo` | Go's `path` package, ported to Mojo | the same tree as `go-path-rs`; build it in Linux or macOS (Mojo 1.2.0 and EmberJson 0.5.0 from its `pixi.toml`) |
| `ruby-shellwords-mojo` | Ruby's `shellwords.rb`, ported to Mojo | the same project as `ruby-shellwords-rs`; build it in Linux or macOS (Mojo 1.2.0 and EmberJson 0.5.0 from its `pixi.toml`) |
| `go-path-rs` | Go's `path` package | `$(go env GOROOT)/src/path` (Go 1.24), as module `example.com/gopath`, with `internal/bytealg` calls replaced by their `strings` equivalents |
| `ruby-shellwords-rs` | Ruby's `shellwords.rb` | `RbConfig::CONFIG["rubylibdir"]/shellwords.rb` (Ruby 3.3), as `lib/shellwords.rb` of a project with a `Gemfile` |
| `python-colorsys-mojo` | Python's `colorsys.py`, ported to Mojo | CPython 3.13's `Lib/colorsys.py`, as `src/colorsys_pkg/colorsys.py` of a project with a `pyproject.toml`; its `cases.jsonl` was recorded from CPython 3.13; build it in Linux or macOS (Mojo 1.2.0 from its `pixi.toml`) |
| `java-jdk-rs` | JDK 21 behind `original/Jdk.java` | `original/Jdk.java` in `src/main/java/com/example/jdk/` of a project with a `pom.xml` |
| `c-libc-mojo` | glibc behind `original/facade.c`, ported to Mojo | `original/facade.c` in `src/` of a project with a `Makefile`; its `cases.jsonl` was recorded from glibc 2.39; build it in Linux or macOS (Mojo 1.2.0 from its `pixi.toml`) |
| `vercel-ms-rs` | [vercel/ms](https://github.com/vercel/ms) (MIT) | a clone at commit `4ff48ce`, with the crate at `rust/index-rs` (where `bench_batch.mjs` finds `src/index.ts`) |
| `fuse-rs` | [Fuse.js](https://github.com/krisk/Fuse) (Apache-2.0) | a clone at commit `edf2fb6` with `adapter/relevance.ts` copied to `src/rust/relevance.ts`, bundled by `esbuild src/rust/relevance.ts --bundle --format=esm --platform=node --outfile=build/relevance.mjs` and recorded with `--module build/relevance.mjs`; `bench.mjs` also needs Fuse bundled to `build/fuse.mjs` |
| `json-server-rs` | [json-server](https://github.com/typicode/json-server) (MIT) | a clone at commit `89a34a4`, `pnpm install --frozen-lockfile --ignore-scripts`, with this folder at `rust/` and `adapter/*.ts` copied to `src/rust/`; not a single crate but the whole lifted app (see its README) |
| `prettier-rs` | [Prettier](https://github.com/prettier/prettier) (MIT) | a clone at tag `3.6.2` (commit `7a8b05f`), `corepack yarn build --no-minify`, with this folder at `rust/`; recorded from a scratch folder holding `dist/prettier` as `node_modules/prettier` (see its README) |
| `eslint-rs` | [ESLint](https://github.com/eslint/eslint) (MIT) | `scripts/setup.sh` clones tag `v10.15.0` (commit `a2101d9`), installs its production dependencies, builds the app folder (ESLint as `node_modules/eslint`) and generates the inputs; the front door and the port crates are here, no cases (see its README) |
| `ffmpeg-rs` | [FFmpeg](https://ffmpeg.org)'s `libavutil` (LGPL-2.1+) | `scripts/prepare.sh` clones tag `n7.1` (commit `b08d796`), builds `libavutil.a` and assembles the tree the crates record from; `scripts/verify.sh` records, diffs and gates every crate (no cases are kept here; see its README) |
| `ffmpeg-mojo` | `libavutil`'s `rational.c`, ported to Mojo (LGPL-2.1+) | the tree `ffmpeg-rs/scripts/prepare.sh` assembles; `scripts/verify.sh` records, builds, diffs and gates each unit (no cases are kept here; see its README) |

The originals are not copied here: the standard-library sources keep their own licenses, and the
ports name theirs in `src/port.rs`. To rerun one, put the original in place as described, point
`mojo-anything.json`'s `root` at that project, and run:

```sh
mojo-anything record <crate> --inputs <crate>/inputs.jsonl   # or keep the recorded cases.jsonl
mojo-anything gate <crate>
mojo-anything bench <crate>
```
