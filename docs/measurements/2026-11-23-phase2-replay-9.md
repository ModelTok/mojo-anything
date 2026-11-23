# Phase 2: the Mojo tool with `analyze` and `map` of Java, Go, Ruby and C# repositories

- Date: 2026-11-23
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04
- Mojo: Mojo 1.2.0, and CPython 3.12.16 with tree-sitter 0.26.1 and the grammars pinned in
  `pixi.toml`, through the repository's pixi environment
- Mojo tool: `tool/build/mojo-anything` at cde4fa8 (`pixi run build-tool`)
- Phase 1 binary: `tool/fallback/mojo-anything`, built from `v0.1.0` (e0d14c2) by
  `scripts/build-fallback.sh`
- Recording: `mojo/app-cases/`, the 524 cases of the
  [previous run](2026-11-23-phase2-replay-8.md)

This run checks correctness only and times nothing.

## Output

The Phase 1 binary replays the recording against the Mojo tool:

```text
$ tool/fallback/mojo-anything app replay . --build tool/build/mojo-anything
524/524 cases passed
Fallback rate: 44.8% (235/524)
```

The Mojo tool's own `app replay` replays the same recording against the Phase 1 binary, which
writes no fallback log:

```text
$ tool/build/mojo-anything app replay . --build tool/fallback/mojo-anything
524/524 cases passed
```

## Fallbacks by command

Counted from `app replay --json` (the names of the cases that fell back) against each case's
`args`:

| Command | Fell back | Cases |
| --- | --- | --- |
| `analyze` | 68 | 147 |
| `map` | 70 | 137 |
| `app replay` | 0 | 11 |
| `app record` | 0 | 9 |
| `setup` | 0 | 25 |
| `doctor` | 2 | 5 |
| `help`, `--help`, `-h`, `--version`, `-V`, no arguments | 0 | 28 |
| unknown commands (`nope`, `--nope`, `app nope`) and `app` alone | 0 | 7 |
| `bridge` | 32 | 38 |
| `mcp` | 27 | 30 |
| the other commands and `app` subcommands | 36 | 87 |

The previous run had `analyze` at 94 and `map` at 90. The cases now answered in Mojo are the
Java, Go, Ruby and C# workspaces with source files (`analyze`, Markdown and `--json`) and the
repositories of those languages with no port (`map`). The rate fell by commit: 281 before,
271 after Java's `analyze`, 265 after Java's `map`, 253 after Go, 239 after Ruby, 235 after C#.
`pixi run check-tool`: 23 test files, 148 tests, all passed.
