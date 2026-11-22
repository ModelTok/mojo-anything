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

## The other kinds

npm packages of Mojo ports (`mojo-node`, `mojo-wasm`), gems, Go modules, C archives and jars
come next in the packaging plan
([`docs/superpowers/plans/2026-11-21-m7-package-docs-release.md`](superpowers/plans/2026-11-21-m7-package-docs-release.md));
until then those kinds answer "not yet".

## What went before

Before mojo-anything targeted Mojo, `package` wrote maturin wheels for PyO3 crates, napi-rs's
per-platform npm packages and a one-package wasm-bindgen layout, with GitHub Actions workflows
that built them. Those bridges were removed (PyO3 in M1, napi-rs and wasm-bindgen in M4 Task 9;
see `DECISIONS.md`), and their layouts went with them. The checks they passed, on macOS arm64
(Node 24, CPython 3.9), are kept in the git history of this page (before commit "refactor: drop
napi-rs, wasm-bindgen and the binary wire").
