# Whole app to a pure Mojo app

The goal: a standalone Mojo app that does what the original does, with the original kept only as
reference. The app stays runnable at every step: a Mojo **front door** owns the entry point early
and hands whatever is not ported yet to the original, units move to Mojo one at a time through
steps 1 to 5 of [SKILL.md](SKILL.md), and the **lift** at the end removes the fallback. The user
makes the decisions; you find the facts.

Everything you write for the port lives in `<repo>/mojo/`: `MAP.md`, `DECISIONS.md`,
`GLOSSARY.md`, `HANDOFF.md`, `research/`, `app-cases/`, the unit ports, and the front door
`app/`. Why this shape, with sources:
https://github.com/ModelTok/mojo-anything/blob/main/docs/research/whole-app-port.md

Front doors and lifts take CLIs, HTTP servers and libraries whose units are ported to Mojo in
TypeScript/JavaScript, Python, C, Go and Ruby. Java and Kotlin units (`mojo-jvm`) are ported and
gated one by one, but no front door wires them yet: tell the user before planning a whole-app port
of a JVM app past the front door.

## The map

A whole-app port outlasts one session, so `mojo/MAP.md` carries it between sessions: the goal,
an index of the ADRs in `DECISIONS.md`, every unit of the plan with its state (`open`,
`claimed by <session> <date>`, `done`), open questions, and what is out of scope. Write it after
the grilling and keep it current; it points to the other files and never copies them.

A session **claims** one unit in the map before it starts, ports that unit, and marks it `done`
with its gate and replay results. A claimed unit belongs to its session: pick another. A new
session starts by reading `MAP.md`, then `HANDOFF.md` when there is one.

`mojo-anything map --write` generates `mojo/PORT_MAP.md` from the ports themselves: functions in
Mojo and kept in the original, cases, last `diff`, glue that still falls back, units not ported,
and ports whose original changed upstream. Run it at each checkpoint and check `MAP.md` against
it; the generated file is the measured state, `MAP.md` is the plan and the claims.

## 1. Grill the user

Interview the user until every decision the port depends on is settled. Map them as a **design
tree**: each decision branches into the ones that hang off it. Ask in **rounds**: a round is the
whole **frontier**, every decision whose prerequisites are already settled. Number each question,
give your recommended answer, and word it so "yes" accepts the recommendation:

```
❓ **Q1** - **<title>**: <question, with the choices>

➡️ <recommended answer>
```

Wait for the answers, recompute the frontier, ask the next round. A question that depends on
another open question waits for a later round.

Facts are yours to find, never the user's: run `analyze --whole-app` and `profile`, read the code,
and send subagents for the rest. `analyze --whole-app` gives the shape and entry points, every
dependency with its Mojo replacement and fit, the pieces in port order, and a numbered list of
decisions with a recommended answer (keep units, blocked units, dependencies with no or partial
replacement, tangled units): start the tree from them. Questions downstream of a running lookup
wait; ask the rest now.

Seed branches (the tree grows from the answers):

- **Shape**: CLI, HTTP server, worker, library, desktop or UI app. Which entry points.
- **Scope**: every feature, or drop dead and deprecated ones. `keep` units (UI, editor code):
  their Mojo replacement, or the part that stays outside Mojo.
- **Equivalence bar**: byte-for-byte output, or equal after normalising (key order, float
  formatting, whitespace, error text). Exit codes, error messages, log lines. For numeric code, a
  float tolerance (`--float-tolerance` on `record` and `app record`, e.g. `1e-9`), or the same
  state after N steps.
- **Compatibility**: config files, environment variables, on-disk and wire formats, CLI flags,
  HTTP routes and status codes that must stay the same.
- **Dependencies**: a Mojo replacement for every external dependency the plan lists, most of all
  fit `none`, `partial` or `unknown`: a Mojo standard library module, a Mojo package from pixi, or
  a Python module through CPython interop (`python:<module>`), which keeps CPython a run-time
  dependency of the lifted app. HTTP and database layers.
- **Targets**: Linux and macOS only (Mojo has no native Windows build; Windows users run it in
  WSL), the Mojo version every port pins, packaging, binary size or speed goals.
- **Checkpoints**: when you stop for the user's go-ahead (default: after each wave of the plan).
- **Cutover**: switch at once, or run the Mojo app beside the original first.

Done when the frontier is empty and the user confirms you share one understanding. Write every
decision to `mojo/DECISIONS.md` as a short ADR, one section each, numbered in order and never
renumbered; it is the source of truth for the rest of the port:

```
## ADR-007: Keep the config file format
Status: accepted (2026-11-16)   (later: superseded by ADR-012)
Context: <the facts that forced the choice>
Decision: <what we do>
Consequences: <what it rules in and out>
```

A changed decision gets a new ADR that supersedes the old one. Start `mojo/GLOSSARY.md` beside it:
each of the original's domain terms, its meaning, and its name in Mojo (struct, module, function),
so every unit names the same thing the same way. Add to it as units bring new terms.

## 2. Research, in the background

For each dependency and framework decision, and each risk the plan flags as `high`, send a
background subagent to research it against **primary sources** only: the source library's own
docs and code, Mojo's documentation and standard library source (github.com/modular/modular,
at the version the ports pin), the Mojo package's repository, language specs, and mojo-anything's
[docs/mojo-notes.md](https://github.com/ModelTok/mojo-anything/blob/main/docs/mojo-notes.md) for
what has been checked against the pinned compiler. An API is usable only once the pinned compiler
accepts it: the standard library's main branch tracks the nightly. Each writes one file,
`mojo/research/<topic>.md`, citing the source of every claim and listing the semantic traps it
found.

Keep working while they read: only units that depend on a pending topic wait for it. Read a
topic's file before porting any unit it covers.

## 3. Record the whole app

Capture what the app does from the outside, so every later build is held to it:

- **CLI**: arguments, stdin and environment in; stdout, stderr, exit code and files written out.
- **HTTP server**: requests in; status, headers that matter and bodies out.
- **Library**: the public API, through `mojo-anything record` on each unit: there is no process
  to replay, so skip `app record`; the units' recorded cases are the proof.

Inputs: the app's tests, examples and real workloads, its error paths (bad input, missing files,
failed calls), and the semantic traps: non-ASCII and emoji strings, negative division and
modulo, integer overflow, large and tiny floats, map and set order, regular expressions.

Run the original twice on every case. Where its own runs disagree, the difference is **noise**,
and `app record` sorts it into three kinds, each listed by case:

- `values`: parts of lines changed (timestamps, ids). They became `[..]` wildcards.
- `order`: the same lines in another order (hash maps, concurrency). Replay compares them in any
  order, but the port must produce exactly those lines.
- `lines`: a different number of lines. That stretch became `...`, which matches anything.

Never accept noise silently: an `order` or `lines` case is exactly the behaviour that can change
for real in a port. Ask the user about each one in the grilling (is the order part of the
contract? should the output be sorted?), and narrow a `lines` wildcard by hand, or with an input
that makes the output stable, where you can. Normalise noise in the case, never in the port.
`mojo-anything app record <repo> -- <command that runs the original>` does all of this: the
app's documented examples, `--inputs` for the tests, workloads and error paths you collect, the
traps, two runs, `--normalize` for named noise. A CLI's cases are trycmd-format files in
`mojo/app-cases/`. For a server add `--http`: the command starts it, taking its port from `PORT`
or `{port}` (`--port` if it is fixed), and requests come from `curl` lines in its docs and
`--inputs` (`{"method", "path", "headers", "body"}`), stored in `mojo/app-cases/http/`. If the
app sends email, calls webhooks or APIs, or writes a database, record those too: `--effects
http,smtp` (and `--effect-env VAR=KIND` for its own URL or mail settings), `--db-reset` and
`--db-dump` for the database. Ask the user for the reset and dump commands when the database is
not a local file. Then `mojo-anything app replay <repo>`: the original must pass every case.

What the recording can miss, each seen on a real app:

- **Files around the input.** Each case runs in an empty directory, so config files the app reads
  beside its input (`.editorconfig`, a `.<app>rc`, a `package.json` key, ignore files) never
  apply, and a port that ignores them passes. Record cases with those files (`files` in
  `--inputs`, or `--fresh` for a project tree), or have the glue hand such cases back.
- **Files the app regenerates.** Recorded on a project it had just generated, every case rewrites
  files with the bytes they already hold, and a front door that writes nothing passes. Record from
  a fixture whose generated files are stale (overwrite them with a marker first), and check that
  the recorded `*.out` folders are not empty.
- **State carried between runs.** A server that rewrites its own files (a JSON database) starts
  the second run from the first one's writes: record it with `--fresh <path>`, and `--pace` when it
  does work after answering.
- **Case counts.** Check the number of recorded cases against the number of `--inputs` lines;
  names longer than 96 characters are cut and can collide.
- **Paths and the machine.** A crashing original prints its install path in the stack trace:
  record with the same copy of the original the front door will run. A Java app recorded while
  many JVMs start may print a `[warning][perf,memops]` line to stdout: run it with
  `-XX:-UsePerfData`. An app that looks up the machine's host name (mail clients do) can outlast
  the 30-second case limit on CI runners: give it `localhost` or a longer `--timeout`.

## 4. Build the front door

Create `mojo/app`, which owns the entry point from now on, with the argument handling, config
loading and server setup from `DECISIONS.md`. Everything it does not handle yet falls back to the
original:

- **CLI**: run the original with the same arguments, stdin bytes and environment, and pass its
  output and exit status through.
- **HTTP server**: proxy every route not ported yet to the original server.
- **Library**: a Mojo package with the public API; the original package keeps its callers and
  reaches each unit's Mojo through the unit's shadow drop-in.

`mojo-anything app front-door <repo>` scaffolds it and replays it: for a CLI a Mojo binary
(`main.mojo`, `original.mojo`, `units.mojo`) that routes the recorded commands and options and
runs the original through `fork`/`execvp`, for a server a Mojo server on libc sockets (with
`TCP_NODELAY`) that starts the original on a port of its own and proxies to it, for a library (no
`main`, no server, or `--library`) a Mojo package (`mojo/app/__init__.mojo`, built with
`mojo precompile`) that re-exports every wired unit. Each is built with `mojo build --Werror` (a
library with `mojo precompile --Werror`). `replay` against the front door must match every case
before any unit moves, and always give `replay` the build: without `--build` it runs the
original, which passes everything and reports no fallback rate. Count the fallbacks: the
**fallback rate** is the share of cases (for a library, of public exports) the original still
answers, and it only goes down. The code in `mojo/app` is yours once scaffolded: `front-door` never overwrites it.

A front door is written for the system it was generated on (Linux or macOS), and a binary built on
the other one stops at start and says so: generate it again there. mojo-anything tells a front
door it builds where the repository is through `MOJO_ANYTHING_REPO`; set that variable yourself
when you build or run `mojo/app` by hand.

## 5. Port every unit

Follow the plan's waves, lowest first, so every unit's dependencies are already Mojo; take a
tangled core in one large piece rather than writing glue around it. Claim the unit in `MAP.md`.
Each unit goes through steps 1 to 5 of SKILL.md, then:

1. Wire the unit into the front door, and stop falling back for what it covers:
   `mojo-anything app wire <repo> <unit> --command <name>` (the app's own name as the command
   takes argv that names no command: no arguments, unknown commands). That writes a glue stub,
   `mojo/app/glue/<unit>.mojo`, with one `def <command>(args: List[String]) raises -> Int` per
   command: parse the arguments, call the port (`from <unit> import port`), print what the
   original prints and return its exit status. Until you fill it in, the stub hands the case back
   with `original.run(args)`; glue that already read stdin hands a case back with
   `original.run_with_stdin(args, input)`, and that is how a unit that covers only part of the
   input declines the rest. For a server, `--route 'GET /users/{id}'` (`/files/{*rest}` for the
   rest of a path, `/path` for any method, `*` for every route no other unit answers); the glue
   is one `def <route_fn>(req: http.Request, params: Dict[String, String]) raises ->
   http.Response` per route, and `original.proxy(req)` hands a request back. Then run
   `app wire <repo> <unit>` again. For a library, `app wire <repo> <unit>` with no command or
   route: the unit's `port.mojo` is re-exported from `mojo/app/__init__.mojo` under the unit's
   name, and `wire` writes the unit's shadow; change the original package to import the shadow in
   place of the unit, so its callers reach the Mojo.
2. `wire` replays: every case matches again, and the fallback rate is lower.
3. Keep the **kill switch** `wire` adds: `MOJO_ANYTHING_UNIT_<NAME>=original` sends the unit back
   to the original, until the lift.

When `replay` goes red, fix one case at a time: `mojo-anything app replay <repo> --build <build>
--case <name>` reruns only the case the report names (a library: only that unit), in seconds and
the same way every time. Read its diff, form one hypothesis, change the port, rerun that case
until it is green, then run the full `replay` so the fix broke nothing else.

Units in one wave do not depend on each other, so a wave can go **in parallel**: you coordinate,
and give each unit to its own subagent with the unit id, the `MAP.md` claim, and the files to read
(`DECISIONS.md`, `GLOSSARY.md`, the unit's research, docs/mojo-notes.md). Each runs steps 1 to 5
of SKILL.md and returns its gate and diff results; you wire the units one at a time and replay
after each. Turn every mistake a subagent made into a rule for the next: an ADR, a glossary entry,
or a test, so the next unit cannot make it again.

Translate faithfully first, with the original's structure, types and error paths; make it
idiomatic only after `replay` passes, and run `replay` again. Where the original returns or throws
an error, raise an error (`raise Error("TypeName: message")`); an `abort` is for states the
original also treats as impossible, with a `# SAFETY:` comment saying why, and `gate` fails on an
error path no recorded case reaches.

Stop at the checkpoints from `DECISIONS.md`, and report the units done, gate results, `replay`
results, the fallback rate and what is left. At each checkpoint, update `MAP.md` and write
`mojo/HANDOFF.md` for a fresh session: where the port stands (fallback rate, the wave, the next
unit), what is in progress or broken, and links to `MAP.md`, the ADRs that matter now and the last
replay report, plus the skill to load next (this one). Point to files; copy nothing from them.

## 6. Lift to a pure Mojo app

When the fallback rate is zero and every unit passes `gate`, run
`mojo-anything app lift <repo>`. It refuses until both hold and lists every blocker (cases still
falling back, by name, or for a library the exports still only in the original; glue still a
stub or still calling `original.`; units failing gate). Then, on a copy of `mojo/` first, it:

1. Deletes the fallback path (`original.mojo`) and the kill switches.
2. Strips each unit's bridge (the extension module and wrapper package, the C exports and header,
   the dispatcher, the Node-API shim and `index.cjs`, the Go and Ruby wrappers) and keeps its
   `port.mojo`, the modules it imports and its `test_*.mojo` files; `mojo/app` calls each port
   through the glue (a library re-exports it).
3. Works the lift checklist: assets read at run time or asset folders not embedded (warnings to
   act on), and how CI keeps checking the app. Mojo has no test runner for recorded command lines
   or HTTP cases, so CI runs `mojo-anything app replay <repo> --build <the lifted binary>`; a
   library's cases ran through the bindings the lift removes, so turn the ones that matter into
   `test_*.mojo` files. For a library it also lists files of the original that still import the
   shadows: point them back at the original's own modules, which stay as reference.
4. Runs every unit's Mojo checks (`mojo format`, its tests, no stubs, no unexplained unsafe code)
   and checks `mojo/app` with `mojo format` and `mojo build --Werror`, then `replay` on the pure
   binary with no fallback (a library: `mojo precompile` builds it as one package, with every
   `port.mojo` as it was when its cases matched).

Only when everything passes are the changes written back; a failure leaves the repo as it was
and names the copy to look at. Fix each `warn` line and each skipped target (packaging and
release are yours), then report them to the user.

## 7. Prove the app, then cut over

`app lift` ends with `replay` against the pure Mojo app; run `mojo-anything app replay <repo>
--build <path to the binary>` again after any change, and in CI: every case matches to the bar in
`DECISIONS.md`. A library is proved before its lift: every case of every unit's `app replay`;
after it, the `test_*.mojo` files you added. A mismatch is a bug in the port, never in the cases; change a
case only with the user's approval, and record why in `DECISIONS.md`.

After the lift, the Mojo app no longer has to mirror the original's structure: the cases check
behaviour at the app's edges, not its internals. Offer the user a reshape pass (merge units that
only existed because of the old layout, replace ported workarounds with idiomatic Mojo, drop
indirection the bridge needed), one change at a time, with `app replay` passing after each.

Report to the user: replay results, gate results for every unit, speed against the original, and
every known behaviour difference. Every speed number is measured on a quiet machine, run twice,
with the hardware, core count and Mojo version beside it; for a server, time the handler in
process next to every HTTP number, so the network is not mistaken for the code. The user decides
the cutover. Leave the original in place as reference until they say otherwise.

Do every cutover step you can yourself. For the steps only the user can do (deploys, DNS, secrets,
store listings, switching production traffic, retiring the original), write `mojo/cutover.sh`: an
interactive bash script that walks them through one step at a time, says what to do and where,
waits for Enter, checks the result where a command can (the new binary answers, a health route is
up), and offers the way back at each step (the original kept beside the new app). Tell the user
to run it.
