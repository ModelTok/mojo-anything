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

## Paths more than 2x slower than the Phase 1 binary (at 603c94c)

Every row but plain `diff` is (see "After the speed work" below for what changed). What would make each faster:

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

## Profile before the speed work (fcfa619)

Measured on the same machine and inputs with the Mojo tool built at fcfa619, before any code
below changed. Other sessions' jobs ran at times (1-minute load 0.3 to 2.5). Tools, all in the
scratch folder, none committed:

- a `sitecustomize.py` on `PYTHONPATH` that times every `exec` of an embedded helper source and
  every call of a function it defines (the wrapper itself costs time: it adds most to the
  441,366 calls of `_need`), and writes the totals from a thread every 20 ms (Mojo's `exit`
  does not finalise Python, so `atexit` never runs in the tool);
- a `node` on `PATH` that times each Node run the tool starts and keeps its request on stdin;
- `node --cpu-prof` on those saved requests, summed per function (self time);
- two Mojo programs built with the repository's pixi Mojo: one that prints, one that also calls
  `Python.import_module("builtins")`; times from `date +%s%N` around 7 runs each.

| What | Measured |
| --- | --- |
| Mojo runtime start (print only) | 13 to 15 ms; the tool's `--version` 13 to 21 ms (Phase 1: 3 to 23 ms, mostly 3 to 4) |
| CPython start through Mojo's interop | 58 to 92 ms in the second program; 28 to 37 ms with `MOJO_PYTHON_LIBRARY` set |
| Finding libpython | Without `MOJO_PYTHON_LIBRARY`, Mojo runs `python3 -c <script>` (`sysconfig`'s `LIBPL`/`LIBDIR`) on every start, then sets `MOJO_PYTHON_LIBRARY` and `PYTHONEXECUTABLE` itself: about 0.03 s of every command |
| Compiling the embedded helpers (first `exec`, imports included) | `analyze`'s helpers (4 KB) 17 to 29 ms, `analyze_py.py` (49 KB) 45 to 56 ms, `analyze_tree.py` (174 KB) 107 ms, `bridge`'s helpers (16 KB) 29 ms |
| `analyze` of py-large, 4.22 s under the hooks | `read_file` 3.90 s over 109 files: `_scan` 1.09 s, `_screen` 0.90 s, `_tokens` 0.85 s, `_exports` 0.31 s, `ast.parse` and the rest about 0.7 s; everything else (start-up, the Mojo planner and report) about 0.3 s. One CPython reads one file at a time. |
| `analyze` of ts-large, 1.26 s | the Node reader 0.81 s (Node alone starts in 27 ms, loading oxc-parser takes 42 ms); in the reader, `visit` 220 ms, oxc's JSON deserialisation 112 ms, garbage collection 86 ms, a line lookup that sliced the source from its start for every export 85 ms, `children` 73 ms, `parseSync` 27 ms |
| `analyze` of ts-real, 72.2 s | the Node reader 71.6 s: `visit` 34.2 s, `stat`/`statSync` 12.5 s, `children` 7.4 s, file reads and UTF-8 decoding 6.7 s, garbage collection 2.6 s, oxc's JSON deserialisation 1.0 s. For every file with exports, `collectTypes` follows its imports four levels deep and re-read, re-stat'ed and re-scanned each imported file every time; 15 MB of source were read many times over. |
| `bridge . mathkit.py`, 0.55 s under the hooks (0.27 s without) | compiling `analyze_tree.py` 107 ms, `analyze_py.py` 56 ms and `bridge`'s helpers 29 ms; importing tree-sitter and loading the Python grammar 125 ms; finding libpython 37 ms |

So the large inputs were slow for two reasons that are not the Mojo code: one CPython read
every Python file in turn, and the TS reader repeated the same reads and scans for every file.
The small commands pay start-up: the Mojo runtime (a floor of about 13 ms that the repository
does not control), finding libpython (30 ms), and compiling up to 170 KB of embedded Python.
Moving the walk to Mojo over tree-sitter's C library (`external_call` on the grammar shared
objects in the pixi environment) was weighed and not taken: the Python reader does not use
tree-sitter at all (it reads `ast` and `tokenize`), so the move would rewrite about 6,000 lines
of Python readers (`analyze_py.py`, `analyze_tree.py`) with new chances to differ from the Rust
tool, while the per-file work is independent and spreads over forked CPython processes with
the code unchanged. The TS reader needed caching, not a new parser: Node and oxc stay.

## After the speed work

What changed (each commit on `m9-self-port-commands`):

- 91768d1: the oxc reader reads, stats and scans each file once (its answers compared byte for
  byte with the old reader's on the saved ts-large and ts-real requests: identical).
- d3a7c78: `analyze_py.py` `read_files` spreads a Python workspace of 256 KB or more over one
  forked CPython per CPU (at most 16).
- e18017b: the libpython path and the embedded helpers' bytecode are kept in
  `$XDG_CACHE_HOME/mojo-anything` (else `~/.cache/mojo-anything`); see `tool/src/mojo_anything/pycache.mojo`.
- 4152c3e: the review's fixes (a cached library no longer reaches the Phase 1 binary when a
  command hands over before Python starts; CPython's `SyntaxWarning` no longer reaches stderr;
  the workers' answers end at the first declined file).

Timed with three binaries interleaved, the order rotating every round: fcfa619 (before),
the new build, and the Phase 1 binary. Before timing, each command ran once on each binary:
stdout, stderr, the exit code and (for commands that write) every file agreed across all three,
and the Mojo builds' fallback logs were empty. Same machine (AMD Ryzen 9 3900X, 12 cores / 24
threads, WSL2 Ubuntu 24.04, Mojo 1.2.0); other sessions' jobs were running, so the load is
listed per row. Seconds, median / min / max. Caches warm (a first run on a machine pays one
`python3` probe and the helpers' compile once).

At 4152c3e, 21 runs each:

| Scenario | Command | fcfa619 | after | Phase 1 | before / Phase 1 | after / Phase 1 | Load |
| --- | --- | --- | --- | --- | --- | --- | --- |
| start-up | `--version` | 0.014 / 0.012 / 0.034 | 0.013 / 0.012 / 0.031 | 0.003 / 0.002 / 0.004 | 5.4x | 5.3x | 2.52 |
| start-up | `--help` | 0.014 / 0.012 / 0.015 | 0.014 / 0.013 / 0.017 | 0.003 / 0.002 / 0.004 | 5.4x | 5.5x | 2.40-2.52 |
| start-up | `analyze --nope` (usage error) | 0.013 / 0.012 / 0.014 | 0.013 / 0.012 / 0.016 | 0.002 / 0.002 / 0.003 | 5.5x | 5.4x | 2.40 |
| start-up with Python | `analyze .` (empty folder) | 0.070 / 0.061 / 0.107 | 0.036 / 0.033 / 0.051 | 0.003 / 0.003 / 0.004 | 20.7x | 10.8x | 2.40 |
| py-small | `analyze .` | 0.151 / 0.144 / 0.161 | 0.103 / 0.089 / 0.110 | 0.010 / 0.009 / 0.012 | 14.4x | 9.8x | 2.19-2.40 |
| unit | `bridge . mathkit.py` | 0.208 / 0.182 / 0.215 | 0.101 / 0.090 / 0.107 | 0.007 / 0.006 / 0.008 | 30.1x | 14.6x | 2.09-2.19 |
| py-large | `analyze .` | 3.126 / 2.778 / 3.217 | 0.433 / 0.376 / 0.463 | 0.508 / 0.460 / 0.530 | 6.2x | 0.9x | 1.48-2.64 |
| py-large | `map .` | 3.118 / 2.863 / 3.379 | 0.430 / 0.385 / 0.513 | 0.507 / 0.486 / 0.553 | 6.2x | 0.8x | 1.51-2.75 |
| ts-large | `analyze .` | 0.910 / 0.800 / 1.054 | 0.545 / 0.463 / 0.590 | 0.050 / 0.045 / 0.054 | 18.0x | 10.8x | 1.68-1.90 |

At e18017b (before the review's fixes, which do not touch these paths), 5 runs each:

| Scenario | Command | fcfa619 | after | Phase 1 | before / Phase 1 | after / Phase 1 | Load |
| --- | --- | --- | --- | --- | --- | --- | --- |
| py-large | `analyze . --json` | 3.613 / 3.345 / 4.308 | 0.492 / 0.476 / 0.531 | 0.551 / 0.501 / 0.694 | 6.6x | 0.9x | 2.45-3.45 |
| unit | `record ... --count 20` | 0.208 / 0.185 / 0.218 | 0.129 / 0.101 / 0.133 | 0.067 / 0.048 / 0.068 | 3.1x | 1.9x | 2.97-3.15 |
| unit | `record ... --count 200` | 0.229 / 0.222 / 0.304 | 0.131 / 0.130 / 0.137 | 0.072 / 0.071 / 0.076 | 3.2x | 1.8x | 2.97 |
| unit | `diff ...` | 0.263 / 0.184 / 0.297 | 0.157 / 0.135 / 0.245 | 0.164 / 0.162 / 0.164 | 1.6x | 1.0x | 2.82-2.97 |
| unit | `diff ... --json --float-tolerance 1e-9` | 0.208 / 0.179 / 0.328 | 0.161 / 0.134 / 0.243 | 0.163 / 0.162 / 0.164 | 1.3x | 1.0x | 2.75-2.82 |
| ts-real | `analyze .` | 62.145 / 57.314 / 70.921 | 5.707 / 4.075 / 7.139 | 12.592 / 12.146 / 13.691 | 4.9x | 0.5x | 1.07-1.48 |
| ts-real | `map .` | 63.203 / 60.899 / 65.101 | 4.607 / 4.030 / 6.391 | 13.751 / 13.194 / 14.962 | 4.6x | 0.3x | 0.95-1.22 |

The start-up rows of that 5-run pass gave `--version` 0.019 before and 0.028 after; the
21-run pass above, on a quieter machine, gives 0.014 and 0.013 (the path did not change), so
the 5-run numbers of the shortest rows are noise.

## Paths still more than 2x slower, and why

- `--version`, `--help` and usage errors (5x): answered in Mojo before CPython starts; what is
  left is the Mojo runtime's own start (a program that only prints takes 13 to 15 ms) against
  Rust's 3 ms. The repository does not control it.
- `analyze` of an empty folder (11x), of two small Python files (10x) and `bridge` of one
  Python unit (15x): the Mojo runtime plus CPython (about 30 ms together, measured with a
  program that only starts Python), then importing the standard-library modules the helpers use
  (`ast`, `tokenize`, `tomllib`, `json`, `subprocess`: about 35 ms) and, for `bridge`,
  tree-sitter and its Python grammar. The Phase 1 binary does the whole command in 3 to 10 ms,
  so no Python-backed command of that size can come within 2x.
- `analyze` of ts-large (11x): Node starts in 27 ms and loads oxc-parser in 42 ms, oxc hands
  each tree to JavaScript as JSON (about 115 ms here), and the walk runs in JavaScript; the
  Phase 1 binary does all of it in 50 ms. Spreading the files over worker threads would not get
  under 2x (Node and oxc-parser alone pass it), so it was not done. On the large TS input
  (ts-real) the Mojo tool now takes under half the Phase 1 binary's time.
- `record` sits at 1.8x to 1.9x: within 2x, the rest being the same Python driver both run.
