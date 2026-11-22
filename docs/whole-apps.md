# Port a whole app

Port a whole CLI, server or library, unit by unit, until it no longer needs the original. Back to
the [README](../README.md).

## Port a whole app

The goal is an app that behaves like the original without it: for a CLI, a pure Mojo binary.
Your agent writes the Mojo; mojo-anything orders the work, scaffolds it, and proves every step.
The [whole-app skill](../skills/rust-anything/whole-app.md) walks the agent through it, starting
with the decisions only you can make:

- **Grilling**: the agent asks in rounds, each question with its recommended answer, until every
  decision the port depends on is settled, and writes each one as an ADR in `mojo/DECISIONS.md`,
  with `mojo/GLOSSARY.md` mapping the original's terms to Mojo names.
- **Research**: background agents read each dependency's primary sources and write
  `mojo/research/<topic>.md`, with every semantic trap they found.
- **Across sessions**: `mojo/MAP.md` lists every unit with its state; a session claims one unit
  before it starts, and each checkpoint leaves a `mojo/HANDOFF.md` for the next session. Units in
  one wave can be ported in parallel by subagents.
- **Cutover**: the agent does what it can and writes `mojo/cutover.sh`, an interactive script for
  the steps only you can do (deploys, DNS, secrets), with a way back at each step.

Grilling, research and these practices are adapted from
[Matt Pocock's skills](https://github.com/mattpocock/skills).

**Checking a rewrite in any language.** `app record` and `app replay` only run programs: the
recording is what the original did from the outside (arguments, stdin, files, HTTP), and
`app replay --build "<command>"` runs any build against it. A rewrite in Go, or by hand, is
checked the same way as the Mojo front door:

```sh
mojo-anything app record . -- java -jar app.jar     # what the original does
mojo-anything app replay . --build "./app-go"       # does the rewrite do the same?
```

The unit tools (`bridge`, `record`, `diff`, `gate`) and `lift` are Mojo-specific.

### Side effects: email, webhooks and databases

A rewrite can answer with the same JSON and still send an email twice or write different rows.
`app record` can record what leaves the process too, per case, and `app replay` compares it:

```sh
mojo-anything app record . --effects http,smtp --effect-env WEBHOOK_URL=http-url \
  --db-reset "sh scripts/reset-db.sh" --db-dump "sqlite3 app.db .dump" -- python3 app.py
```

- **`--effects http`** runs a local HTTP sink that answers every request with `200 {}`, set as
  `HTTP_PROXY`, `http_proxy` and `MOJO_ANYTHING_HTTP_SINK`. Each request is recorded as method,
  URL, content type and body. HTTPS through the proxy is recorded as `CONNECT host:443` and refused,
  since the sink cannot read it: point HTTPS settings at the sink with `--effect-env` instead.
- **`--effects smtp`** runs a local mail server (`SMTP_HOST`, `SMTP_PORT`, `MOJO_ANYTHING_SMTP_SINK`)
  that accepts everything, and records sender, recipients and the message.
- **`--effect-env VAR=KIND`** points one of the app's own settings at a sink: `http-url`,
  `smtp-host`, `smtp-port` or `smtp-url`. Most apps read their webhook URL or mail host from a
  setting like this.
- **`--db-reset` and `--db-dump`** are shell commands: reset puts the database in a known state
  before each case (each start, for servers), and dump prints its state after each case (each
  request, for servers). Cases then run one at a time.

What reached the sinks is stored as `<case>.effects` next to the case and compared like stdout:
the count and order of effects matter, values that differed between the original's two runs
(dates, ids) become wildcards, and effects the original sends in varying order are compared in any
order. The settings are saved with the cases, so replay starts the same sinks for every build.

Plan first: `mojo-anything analyze . --whole-app` adds the app's shape (CLI, server or library)
and entry points, every external dependency (imported or declared) with its Mojo replacement and
fit (a Mojo stdlib module, a package on pixi, or `python:<module>` through CPython interop), the
port order as pieces (units that import each other move together), and numbered decisions with a
recommended answer: keep units, blocked units, dependencies with no or a partial replacement.

Then prove the whole program from the outside. `record` and `diff` prove one unit; `app record`
and `app replay` prove the app, for CLIs and servers in any language (the app is a black box):

```sh
mojo-anything app record . -- python3 cli.py          # the command that runs the original
mojo-anything app replay .                            # the original must pass 100%
mojo-anything app replay . --build "mojo/app/.mojo-anything/build/mytool"
```

- `app record` runs the original on the app's own documented examples (`$ mytool ...` lines in
  its Markdown and shell files, with the files they name), an `--inputs` JSONL file
  (`{"name", "args", "stdin", "env", "files"}`), and semantic traps derived from those cases
  (non-ASCII and emoji strings, negative division and modulo, overflow, large and tiny floats,
  map order, missing files; `--no-traps` leaves them out). Each case runs twice; what differs
  between the two runs becomes a `[..]` wildcard. `--normalize timestamps|uuids|key-order` or
  `--normalize name=regex` adds normalizers, saved with the cases.
- Each case runs in an empty directory holding only the files the case names. A CLI that reads
  files around its input (a `.prettierrc`, an `.editorconfig`) needs cases recorded with those
  files, or glue that hands such cases back. A CLI that writes files must be recorded from a
  fixture whose files are stale, so a build that writes nothing fails; check that the `*.out`
  folders are not empty. Compare the case count with your input lines.
- Cases are [trycmd](https://docs.rs/trycmd)-style files in `mojo/app-cases/`: `<case>.toml`
  (argv, env, exit code), `.stdin`, `.stdout`, `.stderr`, `.in/` (files in) and `.out/` (files
  written). Read and edit them by hand.
- `app replay` runs any build against the cases, prints `passed/total`, writes
  `mojo/app-cases/replay-report.md` with a diff per failing case, and exits non-zero on any
  mismatch. A build that appends to the file named by `MOJO_ANYTHING_FALLBACK_LOG` (one line per
  fallback to the original), as the front door below does, also gets its fallback rate reported.
  Without `--build` it runs the original, which always passes and reports no fallback: pass the
  front door's binary and read the fallback line.
- `app replay --case <name>` reruns one case by the name the report gives it: the fast,
  repeatable loop for fixing a mismatch before running everything again.
- The report has no timings or temporary paths: two replays of the same build write the same
  file. Commit it and run `app replay --build ...` then
  `git diff --exit-code mojo/app-cases/replay-report.md` in CI, and a half-ported app fails CI on
  any change in what passes, better or worse, until the report is updated with it.

Then move the entry point to Mojo and hand it commands one unit at a time:

```sh
mojo-anything app front-door .                            # mojo/app: every command runs the original
mojo-anything app wire . textops-mojo --command upper     # a Mojo unit: a folder with port.mojo
# write the glue in mojo/app/glue/textops.mojo, then:
mojo-anything app wire . textops-mojo                     # 100% again, lower fallback rate
```

- `app front-door` scaffolds `mojo/app`, a pixi project with a Mojo binary named after the app:
  `main.mojo` picks the command from argv, `original.mojo` runs the original with the same argv,
  stdin and environment (through `fork`, `execvp` and `waitpid`, so stdin and stdout bytes pass
  through untouched and the exit code, or the signal that killed it, comes back the same), and
  `units.mojo` routes wired commands. It builds with `mojo build --Werror` into
  `mojo/app/.mojo-anything/build/<binary>`, with the repository built in; at run time
  `MOJO_ANYTHING_REPO` wins, so a front door started from elsewhere, or through a symlinked
  `mojo/`, still finds the original. Each fallback is counted, so replaying the fresh front door
  gives 100% passed at 100% fallback (it builds and replays to show it). It never overwrites
  `mojo/app`: the code is yours from then on.
- A command goes to its unit only when every option on its command line is one the recording saw
  for it; any other option runs the original, which defines what it means.
- `app wire <repo> <unit> --command <name>` takes a Mojo unit (a folder under `mojo/` with
  `port.mojo`, made by `bridge` or by hand), runs `gate` on it (`--skip-gate` if it just passed),
  and writes `mojo/app/glue/<unit>.mojo` once for you or your agent to fill in: one
  `def <command>(args: List[String]) raises -> Int` per command, getting every argument after
  the program name and returning the exit code, with the port as `from <unit> import port`. Each
  stub returns `original.run(args)` until it is filled in. Then it routes the commands, builds and
  replays. On every build the port, and the modules beside it that it imports, are put together as
  a package under `mojo/app/.mojo-anything/build/units/<unit>/`; the unit's own folder is left as
  its bridge builds it.
- Glue that cannot answer a case yet hands it back: `original.run(args)`, or
  `original.run_with_stdin(args, input)` once it has read stdin (read stdin as bytes with
  `open("/dev/stdin", "r").read_bytes()`; write bytes with `stdout.write_bytes(...)` from
  `std.sys`). Each such call is one fallback.
- `MOJO_ANYTHING_UNIT_<NAME>=original` sends a wired unit back to the original until the lift.
  Units written in Rust (Java and Kotlin, until they move to Mojo) cannot be wired into a CLI.

Wire the app's own name as a command (`--command mytool`) for argv that names no command: no
arguments, options only, unknown commands, usage errors.

When replay passes with fallback rate 0 and every unit passes gate, make it a pure Mojo app:

```sh
mojo-anything app lift .
```

- `app lift` refuses until both hold, and says what blocks it: the cases still falling back,
  glue still a stub or still calling `original.`, units failing gate.
- On a copy of `mojo/` first, it removes `original.mojo` and the kill switches, writes a
  `main.mojo` that sends every command to its unit (when yours is still the generated one), drops
  `import original` from the glue, and strips each unit's bridge (`_native.mojo` and the Python
  package, the C exports and header, the dispatcher, the Node-API shim, addon and `index.cjs`, the
  Go and Ruby wrappers), keeping `port.mojo`, the helpers it imports and its tests.
- Then it runs the lift checklist: each unit's checks (`mojo format`, its `test_*.mojo`, no stub
  left, every unsafe line explained), `mojo format` on the app, no call into `original.`,
  `mojo build --Werror`, files read at run time and asset folders, and replay on the pure binary
  with 0 fallback lines. Only when none fails are the changes written back. The original is never
  touched. Mojo has no test runner for command lines, so CI runs
  `mojo-anything app replay . --build mojo/app/.mojo-anything/build/<binary>`.
- A lifted app has nothing left to wire, so to build it again put each unit's `port.mojo` (and
  the modules it imports) in `mojo/app/.mojo-anything/build/units/<unit>/` with an empty
  `__init__.mojo`, and run `pixi run mojo build --Werror -I .mojo-anything/build/units main.mojo`
  in `mojo/app`.

A real run: CPython's `base64` command line, recorded on 74 cases, front-doored, wired to one
hand-written unit and lifted; the pure Mojo binary passes 74/74 with the original moved away
([`demo/real-world/python-base64-mojo`](../demo/real-world/python-base64-mojo/README.md)).

### Servers

The same commands prove HTTP servers. `--http` says the command starts a server; it takes its
port from `PORT` or `{port}` in the command (`--port` for one that always listens on the same
port):

```sh
mojo-anything app record . --http -- node server.js
mojo-anything app replay .
mojo-anything app front-door .                                    # Mojo: every route proxied
mojo-anything app wire . api-mojo --route 'GET /users/{id}' --route '*'
mojo-anything app lift .
```

- Requests come from `curl` lines in the app's docs (`curl -X POST -d ... http://localhost:8080/x`),
  `--inputs` (`{"name", "method", "path", "headers", "body"}`) and traps: path segments and query
  values swapped for the same traps as CLI arguments, bodies for text and JSON traps, and an
  unknown route. Each run starts the server fresh and sends the requests in name order, so state
  between requests is kept.
- A server that keeps state in files gets a fresh copy for every start: `--fresh db.json` (a file
  or folder, repeatable) is snapshotted into `http/files/` and copied into a new working
  directory each time the original, the front door or a build starts; `--arg db.json` is an
  argument every start gets after its command, so the new binary is started as the original is.
  `--pace 50` waits 50 ms after each response, for work a server does after answering (a file
  watcher reloading what it just wrote).
- Cases are `mojo/app-cases/http/<case>.toml` (the request, the status and the headers that
  matter) and `<case>.body` (the response body, with `[..]` where two runs differed). Date, server
  and other per-response headers are left out; delete any header line you do not care about.
- The front door is a Mojo server in `mojo/app` (a pixi project: `main.mojo` accepts
  connections, `http.mojo` reads and writes HTTP/1.1 on the C library's sockets with
  `TCP_NODELAY`, keep-alive and chunked bodies, `original.mojo` starts the original on a free port
  of its own and proxies to it, `units.mojo` routes), built with `mojo build --Werror` into
  `mojo/app/.mojo-anything/build`. It answers one request at a time; an idle keep-alive
  connection is closed as soon as another client waits. The original gets SIGTERM when the front
  door ends (Linux). Why sockets and not Python's `http.server`:
  [the route decision](superpowers/specs/2026-11-21-mojo-server-route.md).
- `wire --route` takes a Mojo unit (`mojo/<name>` with `port.mojo`) and routes `METHOD
  /path/{param}`, `/files/{*rest}`, `/path` for any method, `*` for everything else. Each route
  gets a function in `mojo/app/glue/<unit>.mojo`, named after it (`GET /users/{id}` is
  `get_users_id`, `*` is `fallback`): `def get_users_id(req: http.Request, params: Dict[String,
  String]) raises -> http.Response`, with the parameters percent-decoded; answer with
  `http.text(status, body)` or `http.Response(status, content_type, body)`, or hand the request
  back with `original.proxy(req)`. Static paths are matched before paths with parameters, and
  `*` last. `MOJO_ANYTHING_UNIT_<NAME>=original` sends a unit's routes back to the original.
- `lift` removes `original.mojo` and the proxy (a route no unit answers is a 404) on a copy, as
  for a CLI; HTTP cases then run in CI with `app replay --build`.

### Libraries

A library has no process to replay: its public API is the front door, and each unit's recorded
cases are the proof.

```sh
mojo-anything app front-door .          # mojo/app: a Mojo package with the public API
# each unit through the loop: bridge, record, port, build, diff, gate; then:
mojo-anything app wire . textkit-mojo   # re-exported from mojo/app; the original imports its shadow
mojo-anything app replay .              # every wired unit's cases; fallback = exports still in the original
mojo-anything app lift .
```

- `app front-door` finds the public API (every unit's exports) when the repository has no `main`
  and no server (`--library` otherwise), and scaffolds `mojo/app` as a Mojo package: a pixi
  project whose `__init__.mojo` re-exports each wired unit's port under the unit's module name
  (`from textkit.units.textkit import port as textkit`), so a Mojo program imports
  `from textkit import textkit` and calls `textkit.slugify(...)`.
- Every build puts the package together under `mojo/app/.mojo-anything/build/src/<package>/`
  (`__init__.mojo`, and each unit's `port.mojo` with the modules it imports as
  `<package>.units.<module>`) and runs `mojo precompile --Werror` into
  `mojo/app/.mojo-anything/build/<package>.mojoc`; a Mojo program builds against it with
  `mojo build -I mojo/app/.mojo-anything/build`.
- `app wire` takes a Mojo unit made by `bridge` (`mojo/<name>` with `port.mojo` and its
  manifest), runs `gate`, and writes the unit's shadow drop-in: the original package imports it in
  place of the unit, so its callers keep the original API and reach the port.
  `MOJO_ANYTHING_UNIT_<NAME>=original` sends the unit back (C: build without the shadow's flags).
  Units bridged to Rust (Java and Kotlin, until they move to Mojo) are refused.
- `app replay` runs every wired unit's recorded cases through its bindings (build each unit with
  `mojo-anything build` first). The fallback rate is the share of public exports the port does not
  answer yet: unwired units, and exports `bridge` keeps in the original language.
- `app lift` needs fallback 0 and every unit through `gate`; on a copy, it strips the bindings,
  wrappers and shadows from the units, keeps each `port.mojo`, the helpers it imports and its
  tests, and leaves `mojo/app` as one pure Mojo package: each unit's Mojo checks, `mojo format`
  on `__init__.mojo` and `mojo precompile` must pass before it is copied back. It does not touch
  any port, so the cases that matched through the bindings still describe it; the checklist warns
  about files of the original that still import the shadows.

All five are MCP tools too: `app_record`, `app_replay`, `app_front_door`, `app_wire` and
`app_lift`.
