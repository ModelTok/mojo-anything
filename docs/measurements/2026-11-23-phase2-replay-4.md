# Phase 2: the Mojo tool with `app record` of CLIs

- Date: 2026-11-23
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04
- Mojo: Mojo 1.2.0, through the repository's pixi environment
- Mojo tool: `tool/build/mojo-anything` at ee3b5c4 (`pixi run build-tool`)
- Phase 1 binary: `tool/fallback/mojo-anything`, built from `v0.1.0` (e0d14c2) by
  `scripts/build-fallback.sh`
- Recording: `mojo/app-cases/`, the 524 cases of the
  [previous run](2026-11-23-phase2-replay-3.md)

This run checks correctness only and times nothing.

## Output

The Phase 1 binary replays the recording against the Mojo tool:

```text
$ tool/fallback/mojo-anything app replay . --build tool/build/mojo-anything
524/524 cases passed
Fallback rate: 71.0% (372/524)
```

The Mojo tool's own `app replay` replays the same recording against the Phase 1 binary, which
writes no fallback log, and against itself:

```text
$ tool/build/mojo-anything app replay . --build tool/fallback/mojo-anything
524/524 cases passed
$ tool/build/mojo-anything app replay . --build tool/build/mojo-anything
524/524 cases passed
Fallback rate: 71.0% (372/524)
```

## Fallbacks by command

Counted from `app replay --json` (the names of the cases that fell back) against each case's
`args`:

| Command | Fell back | Cases |
| --- | --- | --- |
| `app replay` | 0 | 11 |
| `app record` | 0 | 9 |
| `setup` | 0 | 25 |
| `doctor` | 2 | 5 |
| `help`, `--help`, `-h`, `--version`, `-V`, no arguments | 0 | 28 |
| unknown commands (`nope`, `--nope`, `app nope`) and `app` alone | 0 | 7 |
| `analyze` | 141 | 147 |
| `map` | 134 | 137 |
| `bridge` | 32 | 38 |
| `mcp` | 27 | 30 |
| the other commands and `app` subcommands | 36 | 87 |

The two `app record` cases that fell back in the previous run, the recordings of the Python
CLI fixture (`app-record-cli-python`, `app-record-json-cli-python`), are now recorded by the
Mojo tool, and their trees under `mojo/app-cases/` match the Phase 1 binary's. The two `doctor`
cases still fall back because its MCP self-test starts the Phase 1 `mcp`.
