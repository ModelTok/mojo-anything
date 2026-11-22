# Tools

Generated from the MCP server's tool list by `tests/tools.rs`; do not edit by hand (`UPDATE_TOOLS_DOC=1 cargo test --test tools` rewrites it). Every tool is also a CLI command with the same options.

## Analyze repository

Tool `analyze` · CLI `mojo-anything analyze`

Map a repository (TypeScript/JavaScript, Python, C, Go, Ruby, Java or Kotlin; PHP and C# for whole apps) for a port to Mojo: units, port order (waves), risks with file:line, the Mojo bridge per unit, what replaces each dependency in Mojo (a stdlib module, a pixi package or a Python module through CPython interop) with its fit, and `start_here`: the best first ports.

Read-only.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `root` | string | yes | Repository root. |
| `lang` | string |  | Source language; detected from the repository when omitted. |
| `whole_app` | boolean |  | Plan a whole-app port: entry points and shape (cli, server, library), every dependency imported or declared with its Mojo replacement and fit, pieces in port order (units that import each other together), and numbered decisions with a recommended answer for the grilling round. |

## Scaffold Mojo unit

Tool `bridge` · CLI `mojo-anything bridge`

Scaffold the Mojo port of one unit in <root>/mojo/<name>: stubs to port in port.mojo and the generated layers its callers need, so they keep the original's API: a Python extension module and wrapper package (mojo-py), C exports with the original names (c-abi), a JSON dispatcher behind a Go cgo or Ruby Fiddle wrapper (ffi), a Node-API addon or a wasm64 module behind index.cjs for TS/JS (mojo-node, mojo-wasm), Java classes over the Foreign Function & Memory API for Java and Kotlin (mojo-jvm). Never overwrites an existing folder.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `root` | string | yes |  |
| `unit` | string | yes | Unit id from analyze. |
| `kind` | string |  | Defaults to the plan's bridge. TS/JS: node (a Mojo port behind a Node-API addon) or wasm (the Mojo port compiled to a wasm64 module that index.cjs loads; needs mojo-wasm's toolchain). |
| `out` | string |  | Port folder; defaults to <root>/mojo/<name>. |
| `name` | string |  | Port name; defaults to `<unit>-mojo`. |
| `force` | boolean |  | Bridge a unit the plan marks blocked or keep. |
| `keep` | string[] |  | Exports to keep in the source language: `name` or `name: reason`. |
| `batch` | string[] |  | Batch classes, `function:param`: the function runs over many `param` values kept on the native side, in one call. |
| `as_json` | string[] |  | Type parameters the app only fills with data (`T` in `paginate<T>(items: T[])`): bridged as JSON values instead of keeping the export in TS. |

## Regenerate generated layers

Tool `refresh` · CLI `mojo-anything refresh`

Regenerate a Mojo port's generated layers (dispatcher, wrappers, index.cjs, Java classes) from the signatures in port.mojo, after changing them, adding any new batch classes. Never touches port.mojo.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |
| `batch` | string[] |  | Batch classes to add, `function:param`: the function runs over many `param` values kept on the native side, in one call. |

## Record original behavior

Tool `record` · CLI `mojo-anything record`

Run the original functions on generated edge-case inputs (non-ASCII, emoji, -0, NaN, ...) plus optional extra inputs, and save the results as cases.jsonl: the behavior the port must match.

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |
| `count` | integer |  | Generated cases per function (default 200). |
| `inputs` | string |  | JSONL file of extra cases: {"fn": name, "args": [...]}. |
| `module` | string |  | JS only: import the original from this JS module instead of the TS source. |
| `resolve_from` | string |  | Resolve npm packages from this folder's node_modules. |
| `float_tolerance` | number |  | Numeric code: floats match when they differ by at most this times the larger magnitude (absolute below 1), e.g. 1e-9. Saved with the port for diff and gate; 0 removes it. |
| `node_args` | string[] |  | Extra arguments for node, e.g. ["--import=tsx"]. |
| `test_command` | string[] |  | TS/JS or Python: also record every call the original's own test suite makes to the unit's functions, e.g. ["npx", "jest"] or ["pytest"]. Runs in the original's folder. |
| `pin_clock` | boolean |  | TS/JS (node) and Python: true pins the clock and random numbers while recording and diffing (`Date.now()`, `new Date()`, `Math.random`; `time.time`, `datetime.now`, `random`) to the values in pinned.json, and writes pinned.mojo for the port to read them (`from pinned import now_ms, random` in port.mojo). Kept for later runs; false stops pinning. |

## Build Mojo port

Tool `build` · CLI `mojo-anything build`

Build the Mojo port with mojo build --Werror: the Python extension (mojo-py), the shared library (c-abi, ffi, mojo-jvm), the shared library and its Node-API addon (mojo-node), or the wasm64 module (mojo-wasm).

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |

## Diff port against recording

Tool `diff` · CLI `mojo-anything diff`

Replay cases.jsonl against the built Mojo port, through the same layer the original's callers use, and list mismatches.

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |
| `ignore_key_order` | boolean |  |  |
| `module` | string |  | Test this JS module instead of the port's `index.cjs`. |
| `node_args` | string[] |  | Extra arguments for node, e.g. ["--import=tsx"]. |
| `float_tolerance` | number |  | Floats match within this tolerance for this run (the one saved by record otherwise). |

## Profile workload

Tool `profile` · CLI `mojo-anything profile`

Run a real workload (a command: node or python3 script, `go test -bench`, java, ruby) under the language's profiler and rank the repository's hot functions by inclusive time, with their callers, call counts and advice: what to port together, and which loops to batch (`bridge` with `batch`). Profile before porting: a small function called one item at a time gets slower once ported, since every call crosses into Mojo.

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `root` | string | yes |  |
| `command` | string[] | yes | The workload, run in root: ["node", "bench.mjs"]. |
| `lang` | string |  | Detected from the repository when omitted. |

## Benchmark Mojo port

Tool `bench` · CLI `mojo-anything bench`

Time the recorded cases on the original and on the built Mojo port, bridge included; speedup below 1 means the port is slower as its callers call it. Returns the rows and a verdict with advice: ship, keep the slower functions, or port a bigger unit.

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |
| `resolve_from` | string |  |  |
| `min_ms` | integer |  | Minimum measured time per function and side, in milliseconds (default 200). |
| `node_args` | string[] |  | Extra arguments for node, e.g. ["--import=tsx"]. |

## Fuzz port against original

Tool `fuzz` · CLI `mojo-anything fuzz`

Live differential test: generate fresh inputs from a new seed (the record generator, without the cases already recorded), run them through the original and the built Mojo port, and report mismatches the recording missed. Returns the seed to replay, counts and the first mismatches; `keep` appends mismatching (or all) fresh cases to cases.jsonl so the next diff and gate check them. Works wherever record and diff do on this machine (TS/JS, Python, C, Go, Ruby, Java, Kotlin).

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |
| `cases` | integer |  | Fresh cases per function (and scenarios per class) in each round (default 200). |
| `seed` | integer |  | Seed of the first round; random when omitted (returned as `seed`). Later rounds count up from it. |
| `time` | number |  | Keep running new rounds until this many seconds have passed; one round when omitted. |
| `keep` | string |  | Append the mismatching fresh cases, or all of them, to cases.jsonl. |
| `resolve_from` | string |  | Resolve npm packages the original imports from this folder's node_modules. |
| `node_args` | string[] |  | Extra arguments for node, e.g. ["--import=tsx"]. |

## Generate shadow module

Tool `shadow` · CLI `mojo-anything shadow`

Generate a drop-in shadow (a TS or Python module, Go package, Ruby file, Java classes or C file) that runs the original and the Mojo port side by side and reports mismatches; MOJO_ANYTHING_MODE=old|shadow|new switches at runtime.

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |
| `out` | string |  |  |

## Map the port

Tool `map` · CLI `mojo-anything map`

Port map of a repository: each unit of the original with the Mojo port of it, its functions in Mojo and kept in the original, its cases and last diff, the whole app's glue (Mojo only, or still handing cases to the original), the units not ported yet in the order analyze suggests, and every port whose original changed since it was recorded (`changed_upstream`: re-record it and diff). Read-only; the CLI's `map --write` saves it as mojo/PORT_MAP.md.

Read-only.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `repo` | string | yes | Repository root. |
| `crates` | string[] |  | Folders of Mojo ports kept outside the repository. |

## Lay out packages

Tool `package` · CLI `mojo-anything package`

Lay out installable packages for a gated Mojo port; writes files only, never builds other platforms or publishes. Python units get a wheel project that depends on mojo-compiler==1.2.0 for the Mojo runtime; TS/JS units npm packages (a main package with a Node-API addon per platform, or one wasm package that needs Node 24); Ruby a platform gem and a pure-Ruby gem; Go a module; C a header, libraries and a pkg-config file; Java and Kotlin a jar. Each comes with a workflow for linux-x64, linux-arm64 and darwin-arm64. No package bundles the Mojo runtime: outside a wheel it must be on LD_LIBRARY_PATH or DYLD_LIBRARY_PATH.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |
| `name` | string |  | Package name on npm or PyPI; defaults to the port's name. |
| `version` | string |  | Package version; defaults to the original package's. |
| `out` | string |  | Output folder; defaults to <port>/package. |
| `dry_run` | boolean |  | List the files, write nothing. |

## Check definition of done

Tool `gate` · CLI `mojo-anything gate`

Definition of done for a Mojo port: port.mojo formatted as mojo format writes it, every test_*.mojo passes under mojo run, no function still a stub, abort, raw pointers and external_call only with a # SAFETY: comment (c-abi: no pointers in port.mojo at all), every place the original fails on purpose reached by a recorded failing case, the port at most 3x the original's lines plus 50, mojo build --Werror, every export present (C exports for c-abi, the original classes' public members for mojo-jvm), recorded behaviour matches.

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `crate` | string | yes | The Mojo port's folder (holds mojo-anything.json and port.mojo). |
| `node_args` | string[] |  | Extra arguments for node, e.g. ["--import=tsx"]. |

## Record whole app

Tool `app_record` · CLI `mojo-anything app record`

Record the whole CLI app's behavior: run the original on its own documented examples, an inputs file and semantic traps (non-ASCII and emoji, negative division, overflow, float extremes, map order), twice each. What differs between runs is reported by kind in `noise`: values (now [..] wildcards), order (lines compared in any order) and lines (a ... that matches anything): show every one to the user. Cases are trycmd files in <repo>/mojo/app-cases/ (argv, stdin, env, files in; stdout, stderr, exit code, files out).

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `repo` | string | yes | Repository root. |
| `run` | string[] |  | Command that runs the original, paths relative to repo: ["python3", "cli.py"]. Optional after the first record. |
| `inputs` | string |  | JSONL of extra cases: {"name", "args": [...], "stdin", "env": {...}, "files": {path: text}}. |
| `normalize` | string[] |  | Normalizers: timestamps, uuids, key-order, or name=regex. |
| `name` | string |  | Name the app is invoked by in its docs. |
| `timeout` | integer |  | Seconds before a run is killed (default 30). |
| `traps` | boolean |  | Add semantic-trap cases (default true). |
| `http` | boolean |  | The app is a server: `run` starts it (it takes its port from PORT or {port}); cases are requests from curl lines in its docs, `inputs` ({"name", "method", "path", "headers", "body"}) and traps. |
| `port` | integer |  | A port the server always listens on (implies http). |
| `effects` | string[] |  | Record what leaves the process: "http" (a local sink set as HTTP_PROXY, http_proxy and MOJO_ANYTHING_HTTP_SINK) and "smtp" (a local mail server, SMTP_HOST and SMTP_PORT). Each case stores what reached them, in order, and replay compares it. |
| `effect_env` | string[] |  | Point the app's own settings at a sink: VAR=http-url, VAR=smtp-host, VAR=smtp-port or VAR=smtp-url. |
| `db_reset` | string |  | Shell command that resets the database before each case (each start for servers); cases then run one at a time. |
| `db_dump` | string |  | Shell command that prints the database's state (e.g. `sqlite3 app.db .dump`), run after each case or request and recorded with the effects. |
| `args` | string[] |  | Servers: arguments every start gets after its command, the original's and every build's (["db.json"]). Implies http; saved. |
| `fresh` | string[] |  | Repository files or folders the app reads or writes (a project tree, a database file), snapshotted and copied into a fresh working directory before every case (CLIs) or start (servers); a CLI's removed files are compared too. Saved. |
| `pace` | integer |  | Servers: milliseconds to wait after each response, for work the server does after answering (a file watcher). Implies http; saved and used by replay; 0 removes it. |
| `float_tolerance` | number |  | Numeric output: numbers match when they differ by at most this times the larger magnitude (absolute below 1), e.g. 1e-9. Saved with the cases; 0 removes it. |
| `float_file` | string[] |  | Written files of raw floats, compared value by value within float_tolerance: `PATH=f32le` or `PATH=f64le`. Saved with the cases. |

## Replay app cases

Tool `app_replay` · CLI `mojo-anything app replay`

Replay <repo>/mojo/app-cases/ against a build (the original, the Mojo front door, the lifted Mojo binary): passed/total, fallback rate when the build reports it, and a report with a diff per failing case (mojo/app-cases/replay-report.md).

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `repo` | string | yes | Repository root. |
| `build` | string |  | Command line of the build to test; the original when omitted. |
| `port` | integer |  | Servers: the port the build always listens on; otherwise it gets a free one through PORT and {port}. |
| `timeout` | integer |  | Seconds before a run is killed (default 30). |
| `case` | string |  | Replay only this case, by the name the report gives it (a library: only this unit): the fast loop for fixing one mismatch. |

## Scaffold front door

Tool `app_front_door` · CLI `mojo-anything app front-door`

Scaffold <repo>/mojo/app, the Mojo binary that owns the CLI's entry point: it routes the recorded commands and options, every command running the original with the same argv, stdin bytes, env and exit status (each fallback counted). For a server: a Mojo server (libc sockets, TCP_NODELAY) that starts the original on a port of its own and proxies every route no unit answers. Builds it and replays the cases: 100% passed at 100% fallback. Needs app_record first; never overwrites mojo/app.

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `repo` | string | yes | Repository root. |
| `check` | boolean |  | Build and replay (default true). |
| `library` | boolean |  | Treat the repository as a library even if it has a main: the front door is a Mojo package with the public API (mojo/app/__init__.mojo, built with mojo precompile), re-exporting each wired unit's port.mojo under the unit's name. Found by default when there is no main and no server. |

## Wire unit into app

Tool `app_wire` · CLI `mojo-anything app wire`

After a unit passes gate, hand its commands to its port. A CLI takes a Mojo unit (a folder under mojo/ with port.mojo): writes a glue stub mojo/app/glue/<unit>.mojo, one `def <command>(args: List[String]) raises -> Int` per command (yours to write: parse args, call `port` from `from <unit> import port`, print what the original prints; `original.run(args)` or `original.run_with_stdin(args, input)` hands a case back), regenerates the routing with a kill switch MOJO_ANYTHING_UNIT_<NAME>=original, then builds and replays. A library takes a Mojo unit `bridge` made: it is re-exported from mojo/app/__init__.mojo and its shadow drop-in is written for the original package. A server takes a Mojo unit too: one `def <route_fn>(req: http.Request, params: Dict[String, String]) raises -> http.Response` per route in mojo/app/glue/<unit>.mojo (`original.proxy(req)` hands a request back). Run it again after writing the glue: 100% passed and a lower fallback rate.

Runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `repo` | string | yes | Repository root. |
| `unit` | string | yes | The unit: its folder, its name under mojo/, or the unit id it was bridged from. |
| `commands` | string[] |  | Commands the unit answers; kept from the last wire when omitted. |
| `routes` | string[] |  | Servers: routes the unit answers: "GET /users/{id}", "/files/{*rest}", "/path" for any method, "*" for everything else; kept from the last wire when omitted. |
| `skip_gate` | boolean |  | Do not run gate on the unit first. |
| `check` | boolean |  | Build and replay (default true). |

## Lift to pure Mojo app

Tool `app_lift` · CLI `mojo-anything app lift`

Make mojo/app a pure app. Refuses (and lists every blocker) unless replay passes with fallback rate 0 and every unit passes gate. Then, on a copy of mojo/ first: removes the fallback and kill switches and strips each unit's bridge, keeping its port. A CLI or a server becomes a pure Mojo binary: original.mojo goes, every unit passes its Mojo checks, the app passes mojo format and mojo build --Werror, no glue calls original., and the pure binary replays with 0 fallback. A library becomes a pure Mojo package: every unit passes its Mojo checks, __init__.mojo passes mojo format, and mojo precompile builds it. Copies back only when nothing fails; never touches the original.

May overwrite files, runs the original's code or commands.

| Parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `repo` | string | yes | Repository root. |
