# How it works

How mojo-anything checks a port, what its commands decide, and where its limits are. Back to the [README](../README.md).

## How it works

```
analyze ──> bridge ──> record ──> port.mojo ──> build ──> diff ──> shadow ──> gate
 what to     the Mojo   what the    you or        the       every     both side   done means
 port first  unit and   original    your agent    bindings  recorded  by side in  this passes
             bindings   does        write it                case      the app
```

The original stays the source of truth: `record` runs it on edge cases (and your own inputs) and
saves what it returns or throws; `diff` replays every case against the Mojo; nothing ships until
they all match and `gate` passes. Callers keep the original API throughout.

A whole app goes through the same loop unit by unit, inside a frame that proves the whole
program ([Port a whole app](whole-apps.md#port-a-whole-app)):

```
analyze --whole-app ──> app record ──> app front-door ──> per unit: the loop above, then app wire ──> app lift
 shape, every           what the app    Mojo owns the       gate passes, so the unit answers in         pure Mojo,
 dependency, the        does from the   entry point; the     Mojo: replay passes, fewer cases fall      proved by
 decisions to make      outside         original answers     back to the original                       replay
```

## The loop

| Step | Command | What it does |
| --- | --- | --- |
| 0. Profile | `mojo-anything profile <repo> -- node bench.mjs` | Runs a real workload under the language's profiler (node, cProfile, `go test` pprof, JFR, a Ruby tracer): hot functions by inclusive time, their callers, and which loops to batch; flags code that is already compiled (numba, Cython, JAX), where a port gains little |
| 1. Plan | `mojo-anything analyze <repo>` | Units, port order, risks with `file:line`, bridge per unit, the Mojo replacement for each dependency, best first ports; `--whole-app` adds entry points and shape, every dependency (imported or declared), pieces (units that import each other move together) and numbered decisions with a recommended answer |
| 2. Bridge | `mojo-anything bridge <repo> <unit>` | `mojo/<unit>-mojo`: the bindings the source language loads (see [Languages](../README.md#languages)), the manifest `mojo-anything.json`, a `pixi.toml` pinning Mojo, and `port.mojo` with a stub per function; `--batch fn:param` (TS/JS) adds a class that keeps many `param` values on the Mojo side; `--as-json T` bridges a type parameter the app only fills with data as JSON values |
| 3. Record | `mojo-anything record <unit>` | Runs the original on generated edge cases (non-ASCII, emoji, `-0`, `NaN`, ints where floats are expected, ...) and on every semantic trap in every parameter (string length and case, signed division, overflow edges, float printing, map and sort order), and saves `cases.jsonl`; `--from-tests -- npx jest` (or `-- pytest`) also records every call the original's own test suite makes; `--float-tolerance 1e-9` lets floats match within that share for numeric code; `--pin-clock` (TS/JS, Python) fixes the clock and random numbers during record and diff, and `pinned.mojo` gives the port the same ones |
| 3. Build | `mojo-anything build <unit>` | Builds the Mojo side with the unit's pinned Mojo: a Node-API addon or a wasm module, a Python extension module, or a shared library |
| 3. Diff | `mojo-anything diff <unit>` | Replays the recorded cases against the Mojo, called the way the original's callers call it; lists mismatches |
| 3. Fuzz | `mojo-anything fuzz <unit>` | Fresh inputs from a new seed (`--seed`, `--cases`, `--time`) through the original and the Mojo; reports what the recording missed, and `--keep` adds those cases to it |
| 3. Bench | `mojo-anything bench <unit>` | Times the recorded cases on the original and on the Mojo, bridge included, and gives a verdict |
| 4. Shadow | `mojo-anything shadow <unit>` | Drop-in that runs both, returns the original's result, reports mismatches; `MOJO_ANYTHING_MODE=old\|shadow\|new` |
| 5. Gate | `mojo-anything gate <unit>` | `mojo format`, the unit's `test_*.mojo`, nothing left unported, no unexplained `abort`, pointer or `external_call` (each needs a `# SAFETY:` comment), a recorded failing case for every error path of the original, size (at most three times the original's lines, plus an allowance), build, API, behaviour; Java and Kotlin units also `java api` |
| Agents | `mojo-anything setup` | Registers the MCP server (`mojo-anything mcp`, every step as a tool) and the workflow skill ([`skills/mojo-anything/SKILL.md`](../skills/mojo-anything/SKILL.md)) with your coding agents |

## Hot paths: batches

A port called once per item pays the bridge once per item, and a JIT runs a small function in
nanoseconds, so a per-call port of a leaf function is often slower than the original. What can
win is moving the loop: `profile` finds it, and `--batch` (TS/JS units on `mojo-node`) generates a
class that takes the items once and runs the port over all of them per call.

```sh
mojo-anything profile . -- node --experimental-strip-types bench.ts
# -> fuzzyScore: a quarter of the run, called per key by `matched`: batch it
mojo-anything bridge . src/fuzzy.ts --batch fuzzyScore:text
```

```js
const search = new FuzzyScoreBatch(keys)          // once
const order = search.rank(query, 0)               // per call: indexes, best first
```

On Mojo a batch runs the port per item on one thread, and `rank` sorts in JS; Go, Ruby, Java and
Kotlin units answer "not yet". No batch has been timed on Mojo: `bench` numbers wait for a run on
a quiet machine, and the batch speed-ups measured on rust-anything's Rust ports are
[history](real-world.md#rust-anything-history-rust-ports-not-mojo), not a promise for Mojo.

## What `bridge` decides

- Exports that cannot cross a bridge stay in the source language, with the reason, and the shadow
  module re-exports the original. For TS: functions that take or return functions, generators and
  iterators, RegExp, `instanceof` checks, classes, generics (`--as-json T` bridges one the app
  only fills with data), and values whose types (followed through imports, re-exports and
  `extends`) hold functions. `--keep "name: reason"` keeps more, e.g. code that depends on `Intl`
  data.
- TS types map to Mojo types, with type aliases resolved through imports and parameter types
  inferred from default values; structured values cross as JSON (`JsonValue` in the port, on
  EmberJson).
- JSON cannot express `undefined`, NaN, Infinity, -0 or lone surrogates: structured values carry
  markers (`{"$undefined": true}`, `{"$num": "NaN"}`, `{"$utf16": [...]}`) that the generated
  `index.cjs` translates. A Mojo `String` is UTF-8 and cannot hold a lone surrogate; JS string
  offsets count UTF-16 units, so a port that slices or measures strings has to count the same way.

`record` runs TS sources as they are: a Node resolve hook follows bundler-style imports
(`./errors` to `./errors.ts`), `--resolve-from` supplies npm packages when the repository has none
installed, and TS that needs transforming (enums, parameter properties) is retried with
`--experimental-transform-types`.

## What `analyze` looks at

- Packages (`package.json`, `pyproject.toml`, `go.mod`, ...) and source files; skips
  `node_modules`, build output, fixtures, playgrounds, tool configs. Vue/Svelte/Astro `<script>`
  blocks are parsed for imports.
- **Units**: a folder of source files, or a file at a package's source root.
- **Waves**: a unit's imports come in earlier waves; import cycles are ported together.
- **Bridge**: for TS/JS, `mojo-node` (a Node-API addon) by default and `mojo-wasm` on request;
  keep in the original for UI and editor code, and C that touches hardware.
- **Dependencies**: each library the code imports gets its Mojo replacement and how well it fits:
  a Mojo standard-library module, a Mojo package on pixi (EmberJson for JSON), or a Python module
  through CPython interop, which a lifted binary then still needs.
- **Readiness** (how safe) and **priority** (safe and worth it: loops and string work, tests, size).

| Risk | Severity | Example |
| --- | --- | --- |
| String offsets | high | `slice`, `indexOf`, `matchAll`, the `d` flag: UTF-16 against Mojo's UTF-8 |
| Regex syntax | high | lookaround, backreferences, `y`: the Mojo standard library has no regex |
| Dynamic regex | high | `new RegExp(userPattern)`: JS syntax at runtime |
| Dynamic code | high | `eval`, `new Function`, computed `import()` |
| Dynamic typing | medium | `any`, `'key' in value` |
| Ordered collections | medium | `Map`, `Set`, `Object.keys`: insertion order |
| Async, generators | medium | promise and generator boundaries |
| Class inheritance, reflection | medium | `extends`, `Proxy`, `Reflect`, `Symbol` |
| Callback-shaped APIs | medium | function-typed params and methods: chatty bridges |
| Clock and random numbers | low | `Date.now()`, `Math.random`: record with `--pin-clock` |
| Exceptions, numbers, JSON | low | `throw`, bitwise ops, `JSON.stringify` order |

## What it can't catch

Passing means the Mojo matches every case that was recorded, nothing more. What bites rewrites
usually lives outside the recording, so know where the edges are:

- **Inputs nobody recorded.** The generated cases, the traps, the original's test suite
  (`record --from-tests`) and your own `--inputs` are the ceiling. Add real inputs (production
  samples, bug reports); the user input that breaks production is rarely one a generator thinks
  of.
- **An original that moved on.** `record` saves a fingerprint of the unit's files
  (`recorded-from.json`); when the original changes later, `diff` warns and `gate` fails until you
  record again, instead of passing against what the original used to do.
- **Regexes.** Mojo's standard library has no regex engine, so a pattern is either rewritten by
  hand or run through Python's `re` over CPython interop, and both can treat `\w`, `\b`, `\d` and
  case-insensitive matching on non-ASCII text differently from JS, Python or Java while passing
  every recorded case. `record` adds regex traps (the Turkish dotless `ı`, zero-width joiners,
  the Kelvin sign, long s, Arabic-Indic digits, line separators, final sigma) to every function in
  a file that uses regexes, but fuzz your real patterns against real text too.
- **What changes between runs.** `record` runs the original twice and sorts out what differed:
  changed values (times, ids) become wildcards; the same lines in another order (hash maps,
  concurrency) are compared in any order, so a port still has to produce exactly those lines; a
  different number of lines becomes `...`, which matches anything. `record` lists each kind:
  look at every one, since a hash-order or concurrency difference is exactly what can change for
  real in a port.
- **Floats.** Number-to-text formatting differs between languages (`1e21`, `-0`, digit counts).
  The traps include those values, and they must match exactly; `--float-tolerance` forgives
  rounding only, never formatting.
- **Anything not in the output.** Timing, memory and concurrency under load are not compared.
  Side effects beyond stdout, stderr, exit codes, written files and HTTP responses are compared
  only when you record them: `app record --effects http,smtp` catches outgoing HTTP calls and
  email, and `--db-reset`/`--db-dump` the database's state after each case
  ([Side effects](whole-apps.md#side-effects-email-webhooks-and-databases)). HTTPS calls through
  the proxy show only the host, and anything the app reaches some other way (a message queue,
  signals) is still not compared.
- **Other platforms.** A recording proves behaviour on the machine that ran it. C whose results
  depend on type sizes, endianness or the compiler can behave differently on the target; `analyze`
  keeps hardware-facing C in C for that reason. Everything so far ran on x86-64 Linux; macOS has
  not been run.

## What a real port takes

A small module is the loop above, once. A real application is not one command: it is many units
in an order, and most of the work is in behaviour the original never wrote down. CPython's
`quopri` command line ([report](real-world-languages.md#a-whole-cli-lifted-to-mojo-cpythons-quopri))
took one bridged unit, a recording of the command line, a front door, glue for `main()` and a lift
before it was one Mojo binary; what decided the port was not Mojo but `binascii`'s C behaviour
behind `quopri.py`, and a usage error the first front door could never hand to the glue. Both were
found by recorded cases, not by reading the code.

What helps:

- **Expect milestones, not a switch.** The front door starts with every case falling back to the
  original, and every wired unit lowers that. A port that is half done still answers every case,
  through the original where Mojo is missing, so it can ship at every step.
- **Give it real inputs.** Generated cases find edge cases; `--inputs` with real traffic or real
  files finds what users actually send.
- **Keep a map** (`mojo-anything map`, below) so a long port can stop and resume, and so you can
  see what is left.

## Keep the original's shape

A port keeps the original's units, names and public API: one Mojo unit per unit of the original,
the same exported functions, the same arguments and errors. The front door keeps the original's
commands and flags. That is what lets callers switch without changes, lets `diff` compare
function by function, and lets the original's maintainers read the Mojo next to the code they
know. Change the design after the port matches, not during it.

## Keep up with the original

The original keeps changing after a port starts. `record` saves a fingerprint of the unit's
files; when they change, `diff` reports a stale recording (and exits non-zero) and `gate` fails,
so an upstream change cannot pass silently.

`mojo-anything map` shows the whole port at once: every unit of the original, the Mojo unit that
ports it, the functions in Mojo and kept in the original, the cases and the last `diff`, the
whole app's glue (Mojo only, or still handing cases to the original), the units not ported yet,
and every port whose original changed since it was recorded. `map --write` saves it as
`mojo/PORT_MAP.md`; committed, it shows each upstream change as a diff. `map --check` exits 1
while any recording is stale, for CI.

After an upstream change: pull it, run `map`, and for each port marked **changed** run `record`
again, then `diff`. The new mismatches are exactly what changed upstream; port those.
