# Ship a port as a package

`mojo-anything package <port>` is meant to lay out a gated port the way end users install it:
an npm package for a TS/JS unit's Node-API addon, a wheel for a Python extension, and so on. It
writes files only, never builds for other platforms and never publishes. Back to the
[README](../README.md).

Not yet: every kind answers "not yet" today. A `mojo-node` unit gets

```
not yet: npm packages of Mojo ports come with the packaging plan (M7, docs/superpowers/plans/2026-11-21-m7-package-docs-release.md)
```

and the other kinds say they are not supported yet. The packaging plan
([`docs/superpowers/plans/2026-11-21-m7-package-docs-release.md`](superpowers/plans/2026-11-21-m7-package-docs-release.md))
adds Python wheels first, then npm packages of Mojo ports.

## What went before

Before mojo-anything targeted Mojo, `package` wrote maturin wheels for PyO3 crates, napi-rs's
per-platform npm packages and a one-package wasm-bindgen layout, with GitHub Actions workflows
that built them. Those bridges were removed (PyO3 in M1, napi-rs and wasm-bindgen in M4 Task 9;
see `DECISIONS.md`), and their layouts went with them. The checks they passed, on macOS arm64
(Node 24, CPython 3.9), are kept in the git history of this page (before commit "refactor: drop
napi-rs, wasm-bindgen and the binary wire").
