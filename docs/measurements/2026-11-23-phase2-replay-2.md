# Phase 2: the Mojo tool with usage errors, setup and doctor

- Date: 2026-11-23
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04
- Mojo: Mojo 1.2.0, through the repository's pixi environment
- Mojo tool: `tool/build/mojo-anything` at 7ac61f8 (`pixi run build-tool`)
- Phase 1 binary (the fallback and the replayer): `tool/fallback/mojo-anything`, built from
  `v0.1.0` (e0d14c2) by `scripts/build-fallback.sh`
- Recording: `mojo/app-cases/`, 524 cases of the Phase 1 binary (`tool/record/record.sh`); the
  519 of the [first run](2026-11-23-phase2-replay.md) and `-h` for the five `app` subcommands

This run checks correctness only and times nothing.

## Output

```text
$ tool/fallback/mojo-anything app replay . --build tool/build/mojo-anything
524/524 cases passed
Fallback rate: 73.7% (386/524)
```

## Fallbacks by command

Counted from `app replay --json` (the names of the cases that fell back) against each case's
`args`:

| Command | Fell back | Cases |
| --- | --- | --- |
| `setup` | 0 | 25 |
| `doctor` | 2 | 5 |
| `help`, `--help`, `-h`, `--version`, `-V`, no arguments | 0 | 28 |
| unknown commands (`nope`, `--nope`, `app nope`) and `app` alone | 0 | 7 |
| `analyze` | 141 | 147 |
| `map` | 134 | 137 |
| `bridge` | 32 | 38 |
| `mcp` | 27 | 30 |
| the other commands and `app` subcommands | 50 | 107 |

The cases of a command that do not fall back are its help and its usage errors. The two
`doctor` cases that fall back are `doctor` and `doctor --json`: doctor runs in Mojo, but its
MCP self-test starts `mojo-anything mcp`, which the Mojo tool hands to the Phase 1 binary and
logs as a fallback.
