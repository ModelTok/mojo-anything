# Phase 2: how long the Mojo tool's Python-backed paths take next to the Phase 1 binary

- Date: 2026-11-25
- Machine: AMD Ryzen 9 3900X, 12 cores / 24 threads, WSL2 Ubuntu 24.04. Other jobs were running
  on the machine (other sessions' builds and this run's own gate), so the numbers are
  indicative, not a benchmark. The 1-minute load average is listed next to each row.
- Mojo: Mojo 1.2.0, CPython 3.12 through Mojo's Python interop (the repository's pixi
  environment), tree-sitter 0.26.1 and Node 24 with npm `oxc-parser` 0.158.0 from `tool/oxc`
- Mojo tool: `tool/build/mojo-anything` at 603c94c (`pixi run build-tool`)
- Phase 1 binary: `tool/fallback/mojo-anything`, built from `v0.1.0` (e0d14c2)
- Script: interleaved runs, Mojo first on even rounds and Phase 1 first on odd ones, 5 runs each,
  wall time of the whole process from Python's `time.perf_counter`; commands that write files
  ran on a fresh copy of the folder each time (the copy is not timed)

Before timing, each command ran once on each binary: stdout, stderr, the exit code and (for
commands that write) every file written agreed byte for byte, and the Mojo tool's fallback
log was empty, so every Mojo row below is the Mojo tool's own work.

## Inputs

- `py-small`: `colorsys.py` and `quopri.py` from CPython 3.12's standard library
- `py-large`: the 109 top-level modules of CPython 3.12's standard library that `analyze`
  answers in Mojo one by one (54049 lines). Every
  package folder of the standard library tried (`email`, `json`, `http`, `urllib`, `logging`,
  `xml`, `importlib`, `asyncio`) still goes to the Phase 1 binary, so no package is timed.
- `ts-large`: a copy of `tool/oxc/node_modules` (oxc-parser and its dependencies, 28 `.js`/`.ts`
  files after the native `.node` and `.wasm` files are left out), with a `package.json`
- `ts-real`: a copy of a real TypeScript project of 820 `.ts` files (15 MB without
  `node_modules`, `.git`, `dist` and `build`)
- `unit`: a Python unit of three functions (`add`, `scale`, `greet`) bridged, ported, recorded
  with `--count 200` and built by the Phase 1 binary; `diff` runs report 9 mismatches

## Results

Seconds, median / min / max of 5 runs each:

| Scenario | Command | Mojo tool | Phase 1 | Mojo / Phase 1 | Load |
| --- | --- | --- | --- | --- | --- |
| start-up | `--version` | 0.051 / 0.049 / 0.081 | 0.003 / 0.003 / 0.004 | 15.0x | 2.46 |
| start-up with Python | `analyze .` (empty folder) | 0.089 / 0.082 / 0.141 | 0.005 / 0.004 / 0.005 | 18.2x | 2.46 |
| py-small | `analyze .` | 0.219 / 0.183 / 0.280 | 0.014 / 0.011 / 0.015 | 15.3x | 2.46 |
| py-large | `analyze .` | 3.863 / 3.807 / 4.628 | 0.657 / 0.557 / 0.717 | 5.9x | 1.00 |
| py-large | `analyze . --json` | 4.491 / 4.135 / 7.527 | 0.789 / 0.539 / 0.893 | 5.7x | 1.00 |
| py-large | `map .` | 5.114 / 4.452 / 5.386 | 0.766 / 0.616 / 1.056 | 6.7x | 0.86-0.91 |
| ts-large | `analyze .` | 1.543 / 1.144 / 2.005 | 0.059 / 0.056 / 0.091 | 26.3x | 0.67-0.79 |
| unit | `bridge . mathkit.py` | 0.269 / 0.221 / 0.295 | 0.011 / 0.009 / 0.013 | 23.7x | 0.92 |
| unit | `record ... --count 20` | 0.205 / 0.184 / 0.303 | 0.067 / 0.047 / 0.068 | 3.0x | 0.85 |
| unit | `record ... --count 200` | 0.393 / 0.296 / 0.425 | 0.098 / 0.095 / 0.139 | 4.0x | 0.85-0.86 |
| unit | `diff ...` | 0.187 / 0.171 / 0.286 | 0.163 / 0.162 / 0.164 | 1.1x | 0.86 |
| unit | `diff ... --json --float-tolerance 1e-9` | 0.461 / 0.333 / 0.548 | 0.167 / 0.164 / 0.311 | 2.8x | 0.79-0.86 |

`ts-real` was timed once on each side (one run took longer than the script's per-call limit
allowed five): `analyze .` took 86.6 s in the Mojo tool and 14.7 s in the Phase 1 binary
(5.9x), with identical output, at a load average of about 0.8.

## Where the time goes

- Start-up: the Mojo binary takes 0.05 s before it does anything (`--version` loads no Python),
  where the Rust binary takes 0.003 s. Starting CPython and running the helper modules adds about
  0.04 s more (the empty `analyze` against `--version`). Every command pays both, so any command
  that takes the Rust binary a few milliseconds is 15x to 25x slower in the Mojo tool.
- `analyze` and `map` of Python: the 3 to 4 s past start-up are the Python reader (CPython's
  `ast` and the planner's helpers run in interpreted Python) and the JSON and text written back
  through the interop; the Rust binary parses with tree-sitter in native code.
- TypeScript: each run starts Node for the oxc reader (its process start and module load, then
  JSON back over a pipe) and walks the result in Python; on the 820-file project this is the
  86.6 s against 14.7 s above.
- `record` and `diff` run the same Python driver as the Rust binary; what is left is start-up
  and, for `diff --json` with a tolerance, reading the driver's `diff.json` into EmberJson values
  and comparing every mismatch in Mojo.

## Paths more than 2x slower than the Phase 1 binary

Every row but plain `diff` is. What would make each faster:

- Start-up (every command): one Python start per run is already the case; the Mojo runtime's own
  start-up is not something this repository controls. Importing only the helper module a command
  needs, instead of executing every embedded helper source, would cut part of the 0.04 s.
- `analyze`/`map` of Python and the planner: a Mojo port of the planner's scoring, waves and
  report writing (now Python helpers), and caching the parsed tree per file between `analyze` and
  `map` within one run.
- TypeScript reader: start Node once per run (if it is not already) and read oxc's JSON in
  Mojo (EmberJson) instead of handing it to Python, or porting the export walk to Mojo, removes the
  second pass.
- `bridge`: the generators run in Mojo already; the time is start-up and the Python manifest
  reader, which a Mojo reader of `mojo-anything.json` would replace.
- `record`: the case generator's Python helpers (`make_loader`, the shape reader); a Mojo port of
  the value generator would leave only the driver's own time.
- `diff --json` with a tolerance: parse `diff.json` once with a lighter reader, or compare in the
  Python process that already read it.

Not timed in this run: the tree-sitter readers of C, C++, Go, Ruby, Java, Kotlin, PHP and C#
(no realistic workspace of those languages that `analyze` answers was at hand), the Go and Ruby
recording drivers, `app record`'s effects and server sinks, and `build` (its time is pixi and
`mojo build`, the same process in both binaries).
