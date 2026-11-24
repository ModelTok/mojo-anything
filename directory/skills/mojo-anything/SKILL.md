---
name: mojo-anything
description: Port TypeScript/JavaScript, Python, C, C++, Go, Ruby, Java or Kotlin to Mojo with the mojo-anything CLI or MCP tools, from one hot function up to a whole app rewritten as a pure Mojo app - profile, plan, bridge one unit at a time, record the original's behaviour, port it in port.mojo, diff, bench, shadow and gate. Use when asked to rewrite, port or migrate code or an app to Mojo, to plan such a migration, or to make slow code faster with Mojo.
---

# Migration to Mojo with mojo-anything

mojo-anything gives you ground truth; you write the Mojo. Port one unit at a time, even when the
goal is the whole app, and call a port done only when `gate` passes.

**Whole app to a pure Mojo app** (the user wants the app rewritten in Mojo, with the original kept
only as reference): read [whole-app.md](whole-app.md) first and follow it. It grills the user on
the decisions, researches the dependencies, records the whole app, puts a Mojo front door
(`mojo/app`) in front of the original, runs the steps below for every unit, then lifts the app to
a standalone Mojo binary (or, for a library, one Mojo package). CLIs, HTTP servers and libraries.

Languages: TypeScript/JavaScript, Python, C, C++, Go, Ruby, Java, Kotlin. The language is detected;
`--lang` overrides it. The steps are the same everywhere; only the bridge differs, and the
original's callers keep their API:

| Source | Bridge kind | What the callers load |
| --- | --- | --- |
| TS/JS | `mojo-node` (default), `mojo-wasm` (`--kind wasm`) | `index.cjs` over a Node-API addon, or over a wasm64 module (Node 24+) |
| Python | `mojo-py` | a wrapper package over a Mojo extension module |
| C | `c-abi` | a shared library exporting the original names, with the original header |
| C++ | `c-abi` (`language: cpp`) | `cpp/wrapper.cpp`, the original functions over the `extern "C"` symbols the Mojo library exports |
| Go, Ruby | `ffi` | a cgo or Fiddle wrapper over the Mojo library's JSON dispatcher |
| Java, Kotlin | `mojo-jvm` | Java classes with the original signatures, calling Mojo through the Foreign Function & Memory API (Java 22+) |

For PHP and C#: `analyze`, and for a whole app `app record`, `app replay` and `app front-door`
(PHP servers run with `php -S 127.0.0.1:{port} router.php`; C# apps are recorded built,
`dotnet out/app.dll`, servers with `--urls http://127.0.0.1:{port}`); `bridge` does not take PHP
or C# units yet, so tell the user before planning such a port past the front door.

Mojo runs on Linux and macOS only. On Windows, work in WSL with the repository cloned inside it,
not under `/mnt/c`. Each port pins its Mojo in its own `pixi.toml`; run Mojo there with
`pixi run --manifest-path <port>/pixi.toml mojo ...`. The Mojo APIs the generated code relies on,
each checked against the pinned compiler, are in mojo-anything's
[docs/mojo-notes.md](https://github.com/ModelTok/mojo-anything/blob/main/docs/mojo-notes.md):
read it before writing Mojo that touches strings, bytes, JSON, C memory or processes.

Tools: the `mojo-anything` CLI, or the same steps as MCP tools (`mojo-anything mcp`): `profile`,
`analyze`, `bridge`, `refresh`, `record`, `build`, `diff`, `bench`, `fuzz`, `shadow`, `gate`,
`map`, and for a whole app `app_record`, `app_replay`, `app_front_door`, `app_wire`, `app_lift`.
If the MCP tools are not available, use the CLI; if `mojo-anything` is not installed, ask the user
to install it
([install guide](https://github.com/ModelTok/mojo-anything/blob/main/docs/install.md)) and run
`mojo-anything setup`, then restart the agent. When a step fails because Mojo, pixi, a runtime,
the agent setup or the MCP server is missing or out of date, run `mojo-anything doctor`: it checks
each one and prints the command that fixes it.

## 0. Profile: find what is worth moving

When the goal is speed, measure before choosing anything:

```sh
mojo-anything profile <repo> -- node bench.mjs      # or: python3 bench.py, ruby bench.rb,
                                                    #     java -cp out Main, go test -run X -bench . ./pkg
```

It runs a real workload under the runtime's own profiler and lists hot functions with their
callers and advice. Go profiles only through `go test`; C is not supported (use `perf`).

- A small function called once per item is **not** worth porting alone: one call into Mojo costs
  more than its work (about a microsecond per crossing from the JVM), and JITs (V8, the JVM, Go)
  run it in nanoseconds. Port it together with its callers, or batch it (step 2b). The advice line
  says which, with the exact command.
- Code that is already compiled (numba `@njit`, Cython, `@jax.jit`) runs as machine code: a Mojo
  port gains little speed. `profile` lists it under "Already compiled" and says so in the advice of
  every hot function that calls it; tell the user before porting it for speed.
- Profile before blaming the algorithm: a slow port is often slow at its edges (how it reads its
  input, a table rebuilt per call), not in its logic.
- If the user only wants a migration, skip to step 1.

## 1. Plan, then stop

```sh
mojo-anything analyze <repo> -o plan.md        # people
mojo-anything analyze <repo> --json            # you: schema mojo-anything/analyze@1
```

- Present the `start_here` units (best first ports) and the order by package and wave.
- Call out `keep` units (UI, editor code: they stay in the source language), `blocked` units and
  their reason, and dependencies whose Mojo replacement has fit `none`, `partial` or `unknown`. A
  replacement written `python:<module>` runs that Python module through CPython interop: the port
  then needs CPython at run time, so say so. Do not hand-roll a missing library silently: flag it.
- **Wait for the user's approval of the plan and of the first unit.**

## 2. Port one unit

```sh
mojo-anything bridge <repo> <unit-id>          # port in <repo>/mojo/<name>; never overwrites
mojo-anything record <port>                    # the original's behaviour on edge-case inputs -> cases.jsonl
```

- If the original has tests, record their calls too: `record <port> --from-tests -- npx jest`
  (TS/JS, any runner) or `-- pytest` (Python). Every call the suite makes to the unit's exported
  functions becomes a case; the source is restored afterwards. Exports that are not function
  declarations (`export const f = () => ...`) are listed as not captured. Run a test runner once,
  never in watch mode (`vitest run`, not `vitest`): a watcher never ends and is stopped at the
  time limit.
- Add real-world inputs with `--inputs cases.jsonl` (`{"fn": name, "args": [...]}` per line) when
  the generated ones cannot reach the interesting paths (structured arguments, domain strings).
  Check the case count after recording against the number of input lines: a count that is too
  low means inputs were dropped, and a check that skips them proves nothing about them.
- TS that cannot run directly in Node (extensionless imports, path aliases): record from built
  output with `--module dist/x.mjs`, or pass `--node-arg=--import=tsx`.
- If the original has no tests, `record` is the characterisation suite: keep `cases.jsonl`.

Write the port in `port.mojo` only; the dispatcher, the wrappers, `index.cjs`, the extension
module and the Java classes are generated. After changing a signature in `port.mojo`, run
`mojo-anything refresh <port>`. Mojo 1.2 spells functions `def` and type aliases `comptime`.

- Read each risk the plan lists for the unit, at its `file:line`, before writing code.
- Errors: where the original throws or raises, `raise Error("TypeName: message")`. It becomes that
  exception in Python and Ruby, the named class in Java and Kotlin, `TypeError`, `RangeError` and
  the other built-in error classes in JS (anything else is an `Error` with the whole text), and the
  `error` text in Go. A Mojo `abort` or a crash never matches a recorded error.
- Strings: a Mojo `String` is UTF-8. JS and Java index UTF-16 code units, so offsets, lengths and
  slices the original computes count a character above U+FFFF as two: do that arithmetic in
  UTF-16 units. A Mojo `String` cannot hold a lone surrogate; `index.cjs` refuses one with a
  `TypeError` before the port is called, and in a Java or Kotlin argument it ends in a panic
  answer, which never matches.
- Case and letters: `String.upper()` maps the full Unicode case from older tables than Java's
  (90 code points differ from Java 25's `toUpperCase`), and no Mojo test is Java's
  `Character.isLetterOrDigit` or Python's `str.isalpha`. Match the original's rule by general
  category, and record the characters it treats differently.
- Integer division: Mojo's `//` and `%` on `Int` floor, as Python's and Ruby's do. JS, Java, C and
  Go truncate: write a truncating division for signed operands that can be negative.
- Numbers in Python and Ruby: ints that the original passes through must come back as ints; in
  Python ports use `PyNum` (`from py_num import PyNum`) for int-or-float. Ruby integers beyond 64
  bits are refused by name, not rounded.
- Structured values (objects, arrays, mixed types) cross as JSON: `JsonValue` from `json.mojo`.
  Objects keep their key order; where the original's map or set order reaches the output, keep
  that order in the port. Nesting is limited to 1024 levels.
- C: inputs recorded as `crash:` are undefined behaviour; any result passes. Check that the C
  project's originals compile (with its `CFLAGS`) before reading anything into a failed `record`.
- C units port to Mojo: `port.mojo` holds no pointers (`gate` checks), `exports.mojo` reads and
  writes them. A `const char *` is `Optional[Span[UInt8, ImmutAnyOrigin]]` (`None` for `NULL`),
  a byte pointer with a length parameter is `Span[UInt8, ImmutAnyOrigin]` (`MutAnyOrigin` when
  the function writes it, with the length folded in), a pointer to one scalar is
  `mut x: Optional[T]`, and a returned pointer into a parameter is its offset (`Optional[Int]`).
  In `--inputs`, give buffers as hex text (a number means that many zero bytes, `null` is
  `NULL`) and leave length parameters out; recorded results then hold the return value and what
  the function wrote. A struct of scalar fields passed or returned by value is a struct in
  `c_structs.mojo` (`AVRational`), and an object of its fields in cases. A `char **` /
  `const char **` the function points into the first `char` string argument is
  `mut x: Optional[Int]` (the offset into it); in cases give the starting offset, `true` for a
  `NULL` start, or `null` for a `NULL` `**`. Contexts, other structs and other `**` stay blocked:
  bridge a small wrapper with plain arguments, and say so. Pass the project's build flags in
  `CFLAGS` (`-DHAVE_CONFIG_H`, `-I<root>`) when its sources need them.
- C integers wrap in two's complement in Mojo as in C, but `//` and `%` floor where C's `/` and
  `%` truncate (see above).
- Regular expressions: Mojo's standard library has none. `analyze` names the replacement
  (`python:re` or `python:regex` through CPython interop, fit partial): either call it, or write
  the matching by hand. Either way, `\w`, `\b`, `\d` and case-insensitive matching treat
  non-ASCII text differently from the source language's engine: passing the recorded cases is not
  enough. `record` adds regex traps (Turkish i, Kelvin sign, joiners, non-ASCII digits and spaces)
  to functions in files that use regexes; ask the user for real text the patterns see, record it
  with `--inputs`, and spell out ASCII classes (`[A-Za-z0-9_]`) where the original's `\w` is
  ASCII-only (JS without `u`, Java).
- Build anything expensive once, not per call: a lookup table, a parsed pattern, a prepared
  string. Look at the slowest cases of every `bench`, not only the mean.
- Unsafe code: `abort`, raw pointers and `external_call` in `port.mojo` need a `# SAFETY:`
  comment on the line or just above saying why; prefer none.
- Add Mojo tests for the cases you reason about in `test_<name>.mojo` files beside `port.mojo`,
  with `std.testing` asserts (Mojo 1.2 has no `mojo test`; `gate` runs each with `mojo run`).
  Tests passing with no tests prove nothing: the recorded cases are the proof.
- `mojo build --Werror` rejects a value assigned and then overwritten before use: declare it as
  `var s: String` instead of `var s = String()`. Branch on `comptime` constants with
  `comptime if`, not a plain `if`.

## 2b. Batch a hot loop

For a TS/JS function called over many items (search, scoring, formatting a list):

```sh
mojo-anything bridge <repo> <unit> --batch fn:param    # or: mojo-anything refresh <port> --batch fn:param
```

This adds a class to `index.cjs` that checks and encodes the `param` values once:
`new FnBatch(items)`. Per query, `run(<other args>)` sends them in one call and returns every
result as one array, and for numeric results `rank(<other args>, min)` returns the item indexes
whose result is at least `min`, best first, ties in item order. Errors are the original's.
`free()` drops the items.

- Make the caller build the batch once, not per query. Map returned indexes back to items with a
  plain loop; in JS, `Array.from(order, fn)` costs far more.
- The port still runs once per item on one thread: a batch saves the crossings, not the per-item
  work. Against a JIT the port itself must be fast: handle ASCII without Unicode tables, build each
  result in one pre-sized `String`, avoid intermediate copies. Keep `diff` passing.
- Items and other arguments: numbers, booleans and strings; results: numbers, booleans or
  strings. Go, Ruby, Java and Kotlin units answer "not yet"; Python, C and C++ units have no batches.

## 3. Prove it

```sh
mojo-anything build <port>
mojo-anything diff <port>                      # must be N/N
mojo-anything bench <port>                     # original vs Mojo, bridge included, with a verdict
```

A mismatch is a behaviour difference: fix the port, never the recording. If the difference is
intended (the user wants the port to fix a bug of the original), ask the user first, then add one
line per case to `<port>/known-diffs.jsonl`: `{"fn", "args", "actual", "reason"}`, with `fn`,
`args` and `actual` copied from `diff --json`. That case then passes only with exactly that result,
and `gate` fails once it no longer differs, so remove the line then. If `gate` says the recording
is stale, the original changed: record again before porting further. After pulling upstream
changes, run `mojo-anything map` (the `map` tool): every port marked changed needs `record`, then
`diff`, and the new mismatches are what changed upstream.

When `diff` says the port is stalled (its `trend.stalled`: three changes to `port.mojo` in a row
gained no matching case), stop editing. Show the user the remaining mismatches and ask: they may
know the rule you are missing, or decide to keep those functions in the original for now. Each
failed `gate` check carries a `fix`: run that first. To see why a case differs, write the expected
and actual output to files and diff them whole; a filter on the diff can hide the one line that
differs.

Numeric code (physics, statistics, graphics) rarely gives bit-identical floats once ported:
operation order, fused multiply-add and the math library differ. When the user accepts that,
record with `--float-tolerance 1e-9` (their number): floats then match within that share of the
larger value (absolute below 1), and `diff` and `gate` use it. Integers, strings and the same
value written differently (`3` and `3.0`) still must match exactly. Never widen a tolerance to make
a mismatch go away: a difference beyond it is a bug in the port.

Follow `bench`'s verdict: ship, keep the slower functions in the source language, or port a
bigger unit (batch or include the callers). Do not ship a port that makes callers slower without
saying so. Every number you report is measured: run `bench` on a quiet machine (no build or test
suite running), twice, and give the hardware, core count and Mojo version with it, slow functions
included. When you script a benchmark, check the build step's own exit status
(`set -o pipefail`) and that the timed run covered every input, so a stale binary is not timed.

## 4. Ship it safely

```sh
mojo-anything shadow <port>                    # drop-in with the original's API
```

Load the shadow where the app loaded the original. `MOJO_ANYTHING_MODE=shadow` (default) returns
the original's results and reports Mojo mismatches; `new` switches to Mojo; `old` turns Mojo off.
The public API does not change. If the port's library cannot be loaded, the shadow says "Mojo
module not loaded" and runs the original alone.

## 5. Done means gate passes

```sh
mojo-anything gate <port>
```

`port.mojo` formatted as `mojo format` writes it, every `test_*.mojo` passing, no function still
a stub, `abort`, raw pointers and `external_call` only with a `# SAFETY:` comment (a `c-abi` port:
no pointers in `port.mojo` at all), every place the original fails on purpose (`throw`, `raise`,
an `error` result) reached by a recorded failing case (add one with `record --inputs` when gate
names it), the port at most three times the original's lines plus 50 for imports and signatures
(over that, use the replacements `analyze` lists and fold repeated code; C that calls the C
library is not compared, since its lines say nothing about the `strtol` a port reimplements),
`mojo build --Werror`, every export
present (for `c-abi` the exported symbols, for `mojo-jvm` every public member of each replaced
class, checked with `javap`), and every recorded case matching. `gate`'s stub and unsafe
checks read `port.mojo` only: when the port spreads over other modules, check those yourself.

Then report to the user, and **wait for their go-ahead before the next unit**:

- what changed (files, functions, bridge kind, batches),
- gate output, diff counts and bench numbers,
- behaviour differences or risks left (e.g. error messages differ, a lone surrogate is refused
  where the original accepted it), and what is left in the plan.
