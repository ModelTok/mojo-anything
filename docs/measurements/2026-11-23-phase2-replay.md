# Phase 2: the Mojo tool against the Phase 1 recording

- Date: 2026-11-23
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04
- Mojo: Mojo 1.2.0, through the repository's pixi environment
- Mojo tool: `tool/build/mojo-anything` at 9457176 (`pixi run build-tool`)
- Phase 1 binary (the fallback and the replayer): `tool/fallback/mojo-anything`, built from
  `v0.1.0` (e0d14c2) by `scripts/build-fallback.sh`
- Recording: `mojo/app-cases/`, 519 cases of the Phase 1 binary (`tool/record/record.sh`)

This run checks correctness only and times nothing.

## Output

```text
$ tool/fallback/mojo-anything app replay . --build tool/build/mojo-anything
519/519 cases passed
Fallback rate: 87.3% (453/519)
```

The 66 cases that did not fall back are the help and version cases (`*help*` and
`*version*`), each checked by running the Mojo tool with `MOJO_ANYTHING_FALLBACK_LOG` set and
finding the log empty. The 453 that fell back are every other subcommand and every usage error.
