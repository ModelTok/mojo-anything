# Ship a port as a package

`mojo-anything package <unit>` lays out a gated port the way end users install it, with a
GitHub workflow that builds it on every supported platform. It writes files only: it builds
nothing for other platforms and never publishes. The output folder (default `<unit>/package`)
holds this machine's build; move the workflow into your repository's `.github/workflows`.
Back to the [README](../README.md).

Platforms: `linux-x64`, `linux-arm64` and `darwin-arm64`, where the pinned Mojo ships. There is
no Windows and no Intel macOS build of Mojo, so no package has one.

## The Mojo runtime

Every Mojo library needs the Mojo runtime libraries (`libKGENCompilerRTShared`,
`libAsyncRTRuntimeGlobals`, `libMSupportGlobals`) of the Mojo it was built with. No package
carries them: they are Modular's proprietary libraries, and the licence lets an application
redistribute only the components Modular's documentation names, which we could not find for
these (`DECISIONS.md` P1). Instead:

- a wheel depends on `mojo-compiler==1.2.0`, Modular's own wheel, and loads the runtime from it;
- every package's libraries look for the runtime beside themselves and on the library path,
  never in the folders of the machine that built them.

`MOJO_ANYTHING_MOJO_LIB` names a folder holding the runtime (the `lib` folder of a pixi or conda
environment with `mojo-compiler`), for a wheel installed without its dependency.

## Python (`mojo-py`)

`package` writes `python/`: a `pyproject.toml`, an in-tree build backend
(`mojo_anything_backend.py`, standard library only) and the package folder, named like the
original module (`src/textkit/` installs `textkit`), with the wrapper's `__init__.py` and the
built `_native.so`. A standard-library name (`quopri`) installs the wrapper's own name
(`quopri_mojo`) instead, since the standard library comes before site-packages; `package` says so.

```sh
mojo-anything build mojo/quopri-mojo
mojo-anything package mojo/quopri-mojo --version 1.0.0
pip wheel --no-deps --no-build-isolation mojo/quopri-mojo/package/python   # offline
```

The wheel is tagged for the Python that recorded the unit (`cp312-cp312-linux_x86_64` here) and
declares `requires-python` for that minor version only, the one the extension was checked on.
Importing it on another platform, or without `_native.so`, raises `ImportError` naming the
supported platforms; without the runtime, an `ImportError` naming `mojo-compiler==1.2.0`.

`.github/workflows/wheels.yml` builds the extension with the unit's pinned Mojo on each
platform's runner, the wheel with `pip wheel`, then runs `auditwheel repair` (Linux) or
`delocate-wheel` (macOS) told to leave the Mojo runtime out, and uploads the wheels as artifacts.

Checked (`tests/package.rs`, Mojo 1.2.0, CPython 3.12.3, x86-64 Linux, 2026-11-22): the quopri
unit's wheel, built by `pip wheel` offline and installed into a fresh venv with no pixi on
`PATH`, replays all 481 recorded cases (4 by `known-diffs.jsonl`) with the runtime named by
`MOJO_ANYTHING_MOJO_LIB`, and fails to import naming `mojo-compiler==1.2.0` without it; the
packaged `_native.so` no longer names the build's `.pixi` folder. Not run: the workflow (no
GitHub remote yet), arm64 and macOS, and installing the `mojo-compiler` wheel from PyPI.

## The native libraries (npm, gems, Go, C, jars)

Every other kind ships the unit's Mojo shared library, with its run path reset to its own
folder. These packages do not load the runtime themselves: put the runtime's folder on the
library path (`LD_LIBRARY_PATH`, `DYLD_LIBRARY_PATH` on macOS) when running, and when linking
against the library (C, Go), since the linker looks for the libraries it needs there too.
Each kind gets one workflow (`.github/workflows/<kind>.yml`) that builds the Mojo library with the
unit's pinned Mojo on each platform's runner and uploads the result; none publishes.

| Kind | `package` writes | On a platform without a build |
| --- | --- | --- |
| `mojo-node` (TS/JS) | `npm/<name>/`: a loader whose `optionalDependencies` are `<name>-linux-x64`, `-linux-arm64` and `-darwin-arm64`, and the original's npm name (the nearest `package.json` above the unit) as an optional peer; `npm/<name>-<platform>/`: `index.cjs`, the Node-API addon and the Mojo library, with `os` and `cpu` set | the loader requires the original package; with none named, it throws an error naming the supported platforms |
| `mojo-wasm` (TS/JS) | `npm/<name>/`: one package for every platform with `index.cjs`, the wasm64 module and `"engines": {"node": ">=24"}`; it needs no Mojo runtime | on Node older than 24, loading throws an error naming Node 24 |
| `ffi` (Ruby) | `gem/`: a gemspec for the one platform whose library is under `lib/<lib>/native/<platform>/`, the Fiddle wrapper; `gem/pure/`: a pure-Ruby gem holding the original's files | `require` raises `LoadError` naming the platforms; the pure gem runs the original (only the files the unit's functions are in, not files they require) |
| `ffi` (Go) | `go/`: the wrapper module, one cgo file per platform (`//go:build linux && amd64`, ...) linking `lib/<platform>/`, and `unsupported.go`; commit every platform's library | the build stops with an error naming the platforms |
| `c-abi` | `c/include/<lib>.h`, `c/lib/<platform>/lib<lib>.so` (`.dylib`), `c/lib/pkgconfig/<lib>.pc` (its `platform` variable picks the folder) | nothing to link |
| `mojo-jvm` (Java, Kotlin) | `java/`: a Maven project (`pom.xml`, Java 22) with the FFM wrappers in `src/main/java` and the library in `src/main/resources/native/<platform>/`, and `MANIFEST.MF` with `Automatic-Module-Name` and `Enable-Native-Access: ALL-UNNAMED`; the native class extracts the library to `$XDG_CACHE_HOME/mojo-anything/<name>-<version>/<platform>/` (else `~/.cache/...`) on first load, unless `mojo-anything.lib.<lib>` or `MOJO_ANYTHING_LIB` names one | loading throws `IllegalStateException` naming the platforms |

Checked (`tests/package.rs`, Mojo 1.2.0, x86-64 Linux, Node 24.22, npm, Ruby 3.3, Go 1.24, OpenJDK
25, 2026-11-22), each package built for this machine and installed into a scratch folder, with
the Mojo runtime named by `LD_LIBRARY_PATH`:

- npm: the two tarballs `npm pack` makes install offline into a scratch project and every case
  recorded from `tests/fixtures/mini` replays through the installed package; with the platform
  package removed, the package is the original; with `process.platform` set to `win32` the loader
  falls back, or names the platforms when the original has no npm name.
- wasm: the packed package replays the `tests/fixtures/wasm-floats` cases; with
  `process.versions.node` set to `22.0.0` it throws naming Node 24.
- gem: `gem build` and `gem install --local` of both gems; the platform gem replays the Ruby
  fixture's cases (all but those with integers beyond 64 bits, which the dispatcher refuses, as
  before packaging), and the pure gem runs the original.
- Go: a driver module with a `replace` to the packaged module replays every case (the plan's
  `go test` is the harness's Go driver here).
- C: every recorded case through the archive's library, and a C program built against the
  archive's header and library prints what it prints against the original `text.c`.
- jar: built with `javac` and `jar` (no Maven here), the jar replays the Java fixture's cases,
  extracting its library into the cache folder; without the library, loading names the
  platforms.

Not run: the workflows, `mvn package`, arm64, macOS, and a Kotlin jar (the same generator).

## What went before

Before mojo-anything targeted Mojo, `package` wrote maturin wheels for PyO3 crates, napi-rs's
per-platform npm packages and a one-package wasm-bindgen layout, with GitHub Actions workflows
that built them. Those bridges were removed (PyO3 in M1, napi-rs and wasm-bindgen in M4 Task 9;
see `DECISIONS.md`), and their layouts went with them. The checks they passed, on macOS arm64
(Node 24, CPython 3.9), are kept in the git history of this page (before commit "refactor: drop
napi-rs, wasm-bindgen and the binary wire").
