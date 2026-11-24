# Real-world ports

The ports produced in the runs described in
[`docs/real-world-languages.md`](../../docs/real-world-languages.md): each folder is a Mojo unit (or a
lifted Mojo app) made by mojo-anything. The Rust crates rust-anything made before it targeted Mojo
(Fuse.js, json-server, Prettier, ESLint, ffmpeg's `libavutil`, x18n) are in
[rust-anything's `demo/`](https://github.com/erkamyaman/rust-anything/tree/main/demo). Each folder holds the port (`port.mojo`), the
generated bridge, `cases.jsonl` (the recorded behavior of the original) and,
where used, `inputs.jsonl` (extra inputs passed to `mojo-anything record --inputs`).

| Folder | Original | Where it came from |
| --- | --- | --- |
| `go-path-mojo` | Go's `path` package, ported to Mojo | `$(go env GOROOT)/src/path` (Go 1.24), as `path/` of module `example.com/gopath`, with `internal/bytealg` calls replaced by their `strings` equivalents; `cases.rust-era.jsonl` is the recording the Rust port passed; build it in Linux or macOS (Mojo 1.2.0 and EmberJson 0.5.0 from its `pixi.toml`) |
| `ruby-shellwords-mojo` | Ruby's `shellwords.rb`, ported to Mojo | `RbConfig::CONFIG["rubylibdir"]/shellwords.rb` (Ruby 3.3), as `lib/shellwords.rb` of a project with a `Gemfile`; `cases.rust-era.jsonl` is the recording the Rust port passed; build it in Linux or macOS (Mojo 1.2.0 and EmberJson 0.5.0 from its `pixi.toml`) |
| `python-colorsys-mojo` | Python's `colorsys.py`, ported to Mojo | CPython 3.13's `Lib/colorsys.py`, as `src/colorsys_pkg/colorsys.py` of a project with a `pyproject.toml`; its `cases.jsonl` was recorded from CPython 3.13; build it in Linux or macOS (Mojo 1.2.0 from its `pixi.toml`) |
| `python-quopri-mojo` | CPython's `quopri` command line, lifted to a pure Mojo binary through a bridged unit | CPython 3.12.3's `Lib/quopri.py` (Ubuntu 24.04) copied as `quopri.py` into an empty folder and run as `python3 quopri.py`; not a unit but the whole lifted app (`mojo/app`, the bridged unit `mojo/quopri-mojo` with its manifest and 481 cases, and 163 recorded CLI cases in `mojo/app-cases`; see its README) |
| `java-jdk-mojo` | The JDK behind `original/Jdk.java`, ported to Mojo | `original/Jdk.java` in `src/main/java/com/example/jdk/` of a project with a `pom.xml`; its `cases.jsonl` was recorded from OpenJDK 25, and `cases.rust-era.jsonl` is the JDK 21 recording the Rust port passed; build it in Linux or macOS with Java 22 or newer (Mojo 1.2.0 and EmberJson 0.5.0 from its `pixi.toml`) |
| `c-libc-mojo` | glibc behind `original/facade.c`, ported to Mojo | `original/facade.c` in `src/` of a project with a `Makefile`; its `cases.jsonl` was recorded from glibc 2.39; build it in Linux or macOS (Mojo 1.2.0 from its `pixi.toml`) |
| `vercel-ms-mojo` | [vercel/ms](https://github.com/vercel/ms) (MIT), ported to Mojo | a clone at commit `4ff48ce`, with the unit at `mojo/index-mojo`; `cases.rust-era.jsonl` is the recording the Rust port (the removed `vercel-ms-rs`, a napi-rs crate) passed (`record --from-tests -- jest`); build it in Linux or macOS with Node 22+, a C compiler, and Mojo 1.2.0 and EmberJson 0.5.0 from its `pixi.toml` |
| `ffmpeg-mojo` | `libavutil`'s `rational.c`, ported to Mojo (LGPL-2.1+) | `scripts/prepare.sh` clones tag `n7.1` (commit `b08d796`), builds `libavutil.a` and assembles the tree; `scripts/verify.sh` records, builds, diffs and gates each unit (no cases are kept here; see its README) |
| `psychrometrics-mojo` | three psychrometric routines of [EnergyPlus](https://github.com/NREL/EnergyPlus) 27.1.0 (development, commit `7ab256b`; its BSD-style licence in the folder), behind a free-function facade, ported to Mojo through the C++ shim | the facade is in `facade/` and the unit's `root` points at it; `scripts/verify.sh` checks the facade's statements against `Psychrometrics.hh` (`EP=<EnergyPlus checkout>`), records, builds, diffs and gates (no cases are kept here; see its README) |

The originals are not copied here: the standard-library sources keep their own licenses, and the
ports name theirs in `port.mojo`. To rerun a Mojo unit, put the
original in place as described, point `mojo-anything.json`'s `root` at that project, and run:

```sh
mojo-anything record <unit> --inputs <unit>/inputs.jsonl   # or keep the recorded cases.jsonl
mojo-anything gate <unit>
mojo-anything bench <unit>
```
