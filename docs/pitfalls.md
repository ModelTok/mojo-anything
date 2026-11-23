# Pitfalls

Mistakes already made in this repository, each with the rule that prevents it. Add one in the
same change whenever a mistake is worth not repeating.

## Generated code and bridges

**A helper in `port.rs` became part of the bridged API.** Making `parse_options` `pub` exported it
through the bridge. Keep helpers private: in `port.mojo` a helper's name starts with `_`, and
only the unit's exports do not.

**A refreshed Go unit lost its JSON support.** A Go unit whose port no longer matched the typed
shape, or whose `port.mojo` had a public helper, lost `json.mojo` and EmberJson on `refresh`, and
the build failed. Only exported functions are generated, and JSON support is added whenever the
dispatcher is used (`needs_json_mojo`). After changing codegen, `refresh` and build a unit that
uses the dispatcher and one that does not.

**Generated code that nothing read failed the build.** A unit exporting only classes got a
dispatcher with `ref a = args.array()` and nothing reading it, which `mojo build --Werror`
refuses; rust-anything's helpers unused by a crate failed clippy the same way. Emit each binding
and helper only when something uses it, and build a unit that uses none (a dispatcher with no
functions).

**Number formatting picked the wrong digit on ties.** A hand-written shortest-digits routine gave
`...813` where V8 gives `...812`. Take digits from `serde_json` (zmij), which rounds to the closest
value as V8 does, and test ties.

**Two front doors overwrote each other's binary.** With `CARGO_TARGET_DIR` set, every app built
into the same `target/`, so replays ran another app's binary. The Mojo front door builds into its
own `mojo/app/.mojo-anything/build`, and a unit into its own `.mojo-anything/build`; keep every
build's output inside the app or unit it belongs to, and run `cargo test` with the variable set
after touching a build.

**Glue could not hand a single case back.** A wired unit that covers only part of the input (a
formatter with unported syntax) had no way to decline after reading stdin. Glue calls
`original.run_with_stdin(args, input)` to pass the case and the bytes it already read; `lift`
refuses to finish while any glue still calls into `original.`.

**Deep JSON stopped recording at 128 levels.** serde_json's recursion limit rejected Prettier's
doc trees. The harness reads case and input lines with `unbounded_depth` and the limit disabled,
and `json.mojo` is checked 200 levels deep (`tests/mojo_json.rs`); EmberJson itself stops at
1024 levels.

**Characters beyond U+1FFFF reached the port on the wrong plane.** EmberJson joins an escaped
surrogate pair with `| 0x10000` instead of `+ 0x10000`, so `"𠈀"` (U+20200) read as
U+10200, on planes 2, 4, ... 16 only; emoji (plane 1) passed, and so did every recorded case. The
Java codec escaped every surrogate. Send whole pairs to EmberJson as UTF-8, escape only lone
halves, and check string ports on every code point, not on the recorded traps alone.

**A replaced class lost the members callers link to.** A Java wrapper takes the original class's
fully qualified name, so it replaces the whole class: Kotlin callers of a companion object's
`@JvmStatic` member read `Units.Companion` and call `Units$Companion.parse`, and failed with
`NoSuchFieldError` against a wrapper that had only the static method, while `gate` compared the
exports alone and passed; constants and members the bridge left out vanished the same way. A
replaced class must keep every public member a caller can link to: `java api` compares all of
them (fields, constructors and public nested classes too), and a test runs a caller compiled
against the original on the wrappers.

**A bridge found no functions in a module that exports a list.** `export { a, b as c }` was not
read. `ts/exports.rs` reads export lists; check `bridge` on a unit written that way.

**A Python name broke the Mojo build.** Parameters named `out`, `match` or `type` came out
as Rust raw identifiers (`r#type`) or Mojo keywords, and one named `port` hid the port module
inside the binding. Names go through `codegen_mojo::mojo_ident` (a `_` after the keywords a
probe build rejected), and binding parameters carry a `p_` prefix; check a new name in
`tests/fixtures/python-mojo-names`.

**The Mojo wrapper converted anything it was given.** `String(py=v)` calls `str()`, and a
`List` takes any iterable, so `lookup(5)` looked up `"5"`. Converters check `isinstance` first
and raise a TypeError.

**A two-line `# SAFETY:` reason failed `gate`.** The unsafe check looked only at the line right
above, so a reason continued on a second comment line was not seen. It now reads the whole
comment block above; keep the reason in that block, touching the line it explains.

**`mojo build` rejected raising a call result.** `raise _no_method(...)` failed with "aliasing
values passed mutably to '__error__'". Bind the error first (`var e = f(...)`, then `raise e^`).

**A unit in a folder with spaces could not build EmberJson.** pixi builds EmberJson from git
inside the unit's `.pixi/bld`, and its build script passes that path to `mojo` unquoted ("too many
inputs"). `crate::mojo::command` runs such a unit's environment from a copy of its `pixi.toml` in
a space-free cache folder; test a new Mojo dependency from a path with spaces.

**A Python unit of bytes had no type to port to.** Unhinted parameters stub as `PythonObject`,
and `List[UInt8]` could not cross the bindings, so `quopri.encodestring` could only be ported
with Python in the port. A bytes parameter or result is `List[UInt8]` in `port.mojo`; after
changing a stub's types, run `refresh` before `build`, or the old bindings fail to compile.

**Usage errors in the recording kept a CLI from lifting.** The front door took the options it
lets through from successful cases only, so a recorded `-x` (exit 2) always went to the original
and the fallback never reached 0. Options from every recorded case count; record a CLI's usage
errors when they name no machine path, and check that `main.mojo` lists their options.

**A wasm module of 864 bytes linked cleanly and did nothing.** Mojo IR for the host CPU holds SSE
intrinsics (`llvm.x86.ssse3.pshuf.b.128`); retargeted to wasm, clang folded the dispatcher into an
endless loop and wasm-ld found nothing undefined. Emit IR with `--target-cpu x86-64`, refuse IR
that names `llvm.x86.`, and check a module's exports and imports, not only that it linked.

**Mojo's `Variant` breaks on 32-bit targets.** Built for riscv32, i686 or x32, a
`Variant[Int64, String]` is sized 16 bytes but laid out with its tag past them, so a growing `List`
of JSON values lost its tags (`["a","bb"]` came back as `[97,25186]`). The wasm kind compiles
64-bit IR to wasm64 instead; probe `List[Variant]` growth before trusting any new target.

**Mojo's LLVM writes float constants clang 22 cannot read.** `double +qnan`, `double -inf`,
`double f0x7FEFFFFFFFFFFFFF`, and NaNs with a payload, `double +nan(0x7FFFFFFFFFFFF)` (quiet) and
`double -snan(0x1)` (signalling), fail with "expected value token"; `harness_mojo_wasm` rewrites
them to the old hex form. The payload is the significand without its quiet bit (a probe of
`bitcast` constants gave `+nan(0x7FFFFFFFFFFFF)` for the bits `0x7FFFFFFFFFFFFFFF`); a `float`
NaN's old form is the `double` with its significand moved up 29 bits. An operand after the
instruction's type has none of its own (`fmul double %a, +inf`, `phi double [ +inf, %bb ]`), so
the rewrite takes the type named last on the line, and leaves quoted text alone. A unit with no
float parameters hid this in the spike, and vercel/ms only failed on a payload NaN after the
first fix: test floats in and out, and check a rewrite's bits by compiling it with clang.

**`0.1 + 0.2` in a Mojo port is 0.3.** Float literals are exact until they become `Float64`, so
the sum of two literals folds to 0.3, where JS gives 0.30000000000000004. Add as `Float64` values
(`var a: Float64 = 0.1`) when the original adds literals.

**`String(Float64)` hung on wasm32 and picks other digits than V8.** On mojo-wasm's wasm32 route
the call never returned; on native it gave other digits than V8 in 154 of 473 probe floats and
failed to round-trip 7 of 20,003. Floats that cross as JSON go through EmberJson's writer (NaN,
the infinities and -0 as `$num` markers), never through `String(Float64)`, and the wasm kind
builds for wasm64, where the call returns.

**Plain `char` was taken as signed everywhere.** It is unsigned on Linux arm, PowerPC, RISC-V and
s390x, so a C unit there needs `UInt8` and ctypes `c_ubyte`, not `Int8`. Map `char` by the host,
and check any C type whose signedness the standard leaves open.

**Go's JSON path replaced invalid UTF-8 without a word.** A Go string holding bytes that are not
UTF-8 reached the port with U+FFFD in their place, and the result looked like an answer. The
wrapper now panics naming the argument; refuse what a bridge cannot carry instead of changing it.

**A typed string result was sliced past its buffer.** A Go result that outgrew the buffer a second
time was read past the end. The wrapper retries until the result fits; test a result larger than
two retries' worth (`tests/go_mojo.rs` has a 1 MB one).

**A void result reached JS as `null`.** A Mojo function returning nothing, or an empty `Optional`,
came back as `null` where the original gives `undefined`. Both answer with the `$undefined`
marker; check `Object.is` on `undefined`, `null`, `-0` and `NaN` through each bridge.

**A lone surrogate deep in a parameter aborted the port.** `index.cjs` checked top-level strings
only, so a lone surrogate inside an `Optional[List[String]]` or a batch's fixed `String` reached
Mojo, which cannot hold one, and ended as `MOJO_PANIC`. Check every string at every depth before
the library is called, and raise the `TypeError` the codec raises elsewhere.

**Mojo's case tables are not the JDK's.** `String.upper()` maps the full Unicode case but from
tables older than Unicode 16, and sends the Greek ypogegrammeni letters to title case: 90 code
points differ from Java 25's `toUpperCase`, and no recorded case hit them. Check case mapping, and
any other table-driven function, on every code point against the original.

**A rebuilt library could change under a running process.** Writing the new library over the old
file changes what a running Node process has mapped. `build` writes beside it and renames it into
place; do the same for any file a process may have loaded.

**EmberJson from conda did not load.** The conda package (0.4.0) was precompiled for Mojo 1.1, and
a `.mojoc` only loads under the compiler that wrote it. Take a Mojo dependency at the release that
pins the same Mojo (EmberJson's git tag `0.5.0`, built by pixi-build), and check that it builds
under the pinned Mojo before using it.

**The forked child allocated.** The CLI front door's child built its error message and called
`perror` after `fork`; neither allocation nor `perror` is safe between `fork` and `exec`.
The child makes only async-signal-safe calls, with its failure message made before `fork`
(`front_door_mojo::tests::the_forked_child_allocates_nothing`).

**One silent client stopped the server front door.** It serves one request at a time, so a client
that connected and sent nothing blocked every other. Accepted connections time reads out after
5 seconds; test a second client while a first sends nothing.

**The server front door did not answer `localhost` from Node.** It listened on `127.0.0.1` only,
and Node 17+ resolves `localhost` to `::1`. It listens on both
(`front_door_answers_on_ipv6_localhost`).

**A wrong `MOJO_ANYTHING_REPO` ran another program.** Given a repository that did not hold the
recorded command's files, the front door ran a same-named file from the working directory. It
stops with exit 125 naming the path (`wrong_repo_variable_is_an_error`); a front door must never
look for the original outside the repository it was told.

**Rust names left in lookups hid Mojo results.** `diff` tracked changes to `src/port.rs` only, so
a Mojo port never got a trend and `map` showed its last diff as "not run"; the MCP server
reported a failed build as `build_failed` only for `cargo build`. When a file or command is
renamed for Mojo, search the code for the old name, not only the generators.

## Recording

**A copied Mojo unit would not build.** `cp -r` of a unit took its `.pixi/` environment along,
whose paths name the original folder, and `mojo build` in the copy failed. Copy a unit without
`.pixi/` (pixi recreates it), as with `target/` for a Rust crate.

**Capture code tripped the project's coverage threshold.** Code `record --from-tests` appends to
the original counted against Jest's limit. Wrap anything added to user files in
`/* c8 ignore start */` and `/* istanbul ignore next */`.

**A test command's output corrupted the MCP stream.** The child wrote to the server's stdout.
Send every child's stdout to stderr or a pipe, never to the MCP server's stdout.

**A project header shadowed the C library's.** ffmpeg ships `libavutil/time.h`, and with that
folder on the `-I` path, `#include <time.h>` in `parseutils.c` found it instead of the system's.
A header folder holding a file named like a C standard header goes on `-iquote`; check that a
C project's originals compile before reading anything into a failed `record`.

**A relative crate path pointed nowhere.** The compiler and cargo run in a scratch folder, so
`rust-anything build .` looked for `./Cargo.toml` there. The CLI makes crate paths absolute;
anything new that passes a path to a child process should take it absolute too.

**A test runner in watch mode never ends.** Run every outside program through `crate::process`,
which closes stdin and stops it at a time limit; `from_tests` also sets `CI=1`.

**Coverage listed one file three times.** Paths from import walking kept `..` segments. Compare
and print canonical paths.

**A CLI's recorded writes were invisible because the fixture already held them.** A CLI that
regenerates project files was recorded on a project it had just generated, so every case rewrote
files with the bytes they already had, and a front door that wrote nothing passed. Record such
CLIs from a fixture whose generated files are stale (overwrite them with a marker first), and
check that the `*.out` folders are not empty.

**A front door could not find the original through a symlinked `rust/`.** The generated
`original.rs` resolved the repository as `CARGO_MANIFEST_DIR/../..`, which is the link target's
parent. A generated Mojo front door is told the repository at build time
(`-D MOJO_ANYTHING_REPO=<repo>`), and `$MOJO_ANYTHING_REPO` wins at run time; set the variable
yourself when you build a front door by hand with `mojo build`, since without either it finds
itself through `/proc/self/exe`, which resolves the link.

**A server's recording carried state from its previous run.** json-server rewrites its database
on every POST, so the second recording run started from the first one's writes. Record servers
that write files with `--fresh <path>`, and `--pace` when they do work after answering.

**Mail cases timed out on macOS CI.** Python's `smtplib` looks up the machine's full host name
for its greeting, and on GitHub's macOS runners that lookup outlasted the 30-second case limit.
Test apps that send mail pass `local_hostname="localhost"`; an app under test that hangs the same
way needs it too, or a longer `--timeout`.

**Recorded case names were cut to 24 characters.** Hundreds of `--inputs` names shared a prefix
and collided. Given names keep 96 characters (`given_slug`); look at the case count after
recording against the number of input lines.

**A Java case failed on a JVM warning.** With many JVMs starting at once, one found its
`/tmp/hsperfdata_<user>/<pid>` file locked and printed `[warning][perf,memops] Cannot use file`
to stdout, so the replay's stdout differed. Java test apps run with `-XX:-UsePerfData`; an app
recorded on a busy machine needs it too.

**Undefined behaviour was recorded from a different compiler.** `av_q2intfloat` overflows on
`INT_MIN`; the Rust port matched clang -O3 on macOS, and the Mojo port's recording (gcc 13,
`-O1`, which `record` uses) answered differently on 75 cases. A port follows the recording it
is diffed against; say which compiler made it, and expect such cases to move when it changes.

**ffmpeg's tree did not link on Linux.** `random_seed.c` calls `avpriv_fopen_utf8`, which lives
in `file_open.c`, and `record` loads the original with every symbol resolved, so the recording
failed before the first case. `prepare.sh` now copies `file_open.c`; ffmpeg's configure also needs
`nasm`. When `record` reports an undefined symbol, add the file that defines it to the tree.

**An unported Mojo stub matched every case where the original throws.** The TS driver only
refused errors starting with napi-rs's `Rust panic:`, so once TS/JS units moved to Mojo, a stub
raising `not ported: <name>` agreed with all 33 thrown cases of `fs.ts`. The driver now refuses
`not ported: ` and `panic in <name>: ` answers; when a bridge changes how it reports stubs or
panics, run `unported_stubs_never_match_*` on that kind.

## Numbers and claims

**Benchmarks taken while other builds ran were off by a wide margin.** Run `bench` on a quiet
machine, run it twice, and name the hardware and core count next to every published number.

**A slow server row was the network, not the code.** json-server's lifted binary served a large
list at 33 req/s while the same handler took 7 ms in process: no `TCP_NODELAY`, so the second
write of each response waited for a delayed ACK. Time the handler in process next to every HTTP
number; generated servers set `TCP_NODELAY`.

**Every number in the docs is measured.** Say what was run, on what, and the result, including the
slow cases (the single-call row is slower than JS on some units). No rounding up for a headline.

**Recorded CLI cases never saw a config file.** `app record` runs each case in an empty
directory, so Prettier's `.prettierrc`, `.editorconfig`, `package.json` `"prettier"` key and
`.gitignore`/`.prettierignore` never applied, and a front door that ignored them passed every
case; run from inside a project it formatted differently from Prettier. A CLI that reads files
around its input needs cases recorded with those files, or glue that sends such cases back.

**A replay reported the original, not the front door.** `app replay` without `--build` runs the
recorded command (the Node CLI), passes everything, and prints no fallback rate; `app wire
--no-check` replays nothing. Pass `--build <front door binary>` and read the fallback line.

**A front door replay measured the original.** A server recorded with `--arg=--port
--arg={port}` was replayed with `--port P`; the Mojo front door passed its own arguments on to
the original, which then bound the public port P before the front door could, and the replay
talked to the original directly: 100% passed at 0% fallback while the front door served nothing.
The original gets only the recorded arguments with its own private port, and the front door logs
every request it reads (`<fallback log>.served`): a replay fails each answer the front door did
not read. A fallback rate means nothing unless the build being measured answered the requests.

**`gate` checked less than it seemed for a split port.** In rust-anything its unwrap, panic and
size checks read `port.rs` only, while the port lived in a dependency crate. On Mojo the `ported`
and `unsafe` checks still read `port.mojo` only, not the helper `.mojo` files it imports. When a
port is split over modules, search the helpers for stubs, `abort(`, pointer types and
`external_call` without a `# SAFETY:` comment yourself.

**A port followed the wrong path key.** Prettier's `path.match(...)` gives predicate *i* the node
*i* levels up and the key under which the level below sits. Port the semantics and test a
`needs-parens` case before reusing it.

**A port compiled its regexes on every call.** Prettier's `printNumber` is four regex replaces;
ported with `Regex::new` inside the function, an array of 100 numbers took 23 ms instead of 0.7.
Compile a pattern once, not on every call, or rewrite a fixed pattern by hand as `analyze`'s
regex advice says, and look at the slowest cases of every bench, not only the mean.

**A benchmark timed a stale binary.** `cargo build --example bench | tail -1 && run` took the
pipe's status from `tail`, so a missing example went unnoticed and the old binary skipped every
CSS file (`total_us 0`). Check the build's own exit status (`set -o pipefail`) and that the
timed run covered as many files as the list it was given.

**A filter hid real cases from a count.** The corpus checker skipped every name containing
`config-` to leave out the config cases, and four real files (`vitest.config.ts`, ...) went with
them. Match the exact prefix you mean, and check a group's total against the corpus.

**A harvester dropped whole rules.** ESLint's tests for no-unused-vars, prefer-const and
no-useless-assignment give their `RuleTester` a test-only plugin, and the script that turned
RuleTester cases into CLI runs skipped every case of a tester with plugins: 715 cases of three
of the most used rules were missing, and the rules showed "0 cases" instead of an error. Skip
only the cases that use what you cannot express, and check every unit's case count after
harvesting.

**A grep hid the bug it was meant to show.** Filtering diffs with a pattern that drops comment-like
lines removed the one line that differed (`/* name */ value`). Write the expected and actual
output to files and diff them whole.

**An exhaustive check covered a different input set from the one the port builds.** The Prettier
doc printer was checked on every doc up to size 5, read from JSON through `from_value`, which
turns `align: ""` into a no-op as Prettier does. The YAML and Markdown printers build
`Align::Text("")` directly, and the printer indented for it. Enumerate the values the code really
passes (native `Doc` values), not a serialised form of them.

**Recorded crash messages held Prettier's install path.** Prettier prints a stack trace when it
crashes, so cases recorded with one copy of Prettier fail when the front door falls back to
another. Record with the copy the front door's `ROOT` resolves to.

**Sorting cannot pair lines that are matched loosely.** An `unordered` output was compared by
sorting both sides as text and pairing the lines by position, while the lines were then matched
within `float_tolerance`: `10.0` sorts before `2.0`, so it met `2.0` instead of the
`9.999999999999999` it matched, and the weaker check failed output the ordered one accepted.
Sorting by value instead only moved the problem -- `[..]` and `2` against `2.0` then paired wrong,
because a loose match is not transitive and no order agrees with it. Pair the lines against each
other (identical ones first, then a search that gives a line up when another needs it), and keep
the sort for showing the diff.

## Language plugins

**A tree-sitter supertype never appears in the tree.** `tree-sitter-kotlin-ng` lists
`class_member_declaration` as a child of `class_body`, but it is a hidden supertype: the tree
holds the concrete `function_declaration` directly. Filter on the concrete kind you parse, and
check a small fixture's S-expression before trusting `node-types.json` child lists.

**Kotlin's JVM owner is not the file name.** A top-level function compiles to a static method on
`<File>Kt` (`NativeLib.kt` → `NativeLibKt`); only `@JvmStatic` members of an `object` or
`companion object` live on the enclosing class, and an `object` declared inside a class is
`Outer$Inner`. Emit prototypes in that Java shape, or the generated wrappers and the reflection
driver look for a class that does not exist.

## Repository

**A local path reached a committed manifest.** Demo manifests keep a placeholder `root`; check
`git diff --cached` for `/Users/` and `/home/` before committing (`scripts/check-secrets.sh`
does this in the pre-commit hook).

**A new translation was listed right after English.** Language lines list English, Türkçe,
Українська first, then the other existing languages in their order, then new ones at the end (see
CONTRIBUTING.md).

**Two sessions edited one checkout.** When another agent is working in the repository, work in
a separate worktree and bring the change over when its files do not overlap.

**Tests that need Mojo skipped without a word.** A suite whose toolchain was missing passed by
running nothing. Tests that need Mojo go through `common::have_mojo()`, which prints why it
skips and fails when `MOJO_ANYTHING_REQUIRE` names `mojo`; CI sets the variable for every
toolchain it installs, so a language suite that stops running fails.

**A test failed on Linux CI with "Text file busy".** It wrote a fake `nm` script and ran it while
other tests were starting processes; a child forked during the write still held the file open for
writing, so exec failed. Write a script that a test runs from a separate process (`cp` from a text
file) and never rewrite one that already ran.

## Removed

Entries about code that is gone, one line each on why they no longer apply. Android support
(`build`, `record` and `diff --profile android`) went with the Rust JNI crates in M5: Mojo does
not target Android, and `--profile` takes only `host`.

Rust ports, crates and the Rust bridges (napi-rs, wasm-bindgen, PyO3, magnus, JNI) went in
Milestones 1 to 5: nothing mojo-anything generates is Rust.

- **Wiring every napi function broke crates without `serde_json`**: no crate is generated, and
  `required_deps` is gone; the Mojo form of the mistake is "A refreshed Go unit lost its JSON
  support" above.
- **Generated helpers unused by a crate failed clippy**: `JOINED_IN_RS` and `JOINED_OUT_RS` are
  gone with the napi generator; the rule lives on in "Generated code that nothing read failed the
  build".
- **A port read its AST through hashed maps**: it was Cargo unifying serde_json's
  `preserve_order` across a Rust port's binary; no port is Rust.
- **A copy of a crate built into the same target folder replaced it**: ports are Mojo units,
  each built into its own `.mojo-anything/build` (and see "A copied Mojo unit would not build").
- **Mutation jobs tested each other's binaries**: cargo-mutants ran on Rust ports, and none are
  generated.
- **The Ruby tests failed on a clean macOS shell**: it was rb-sys's stable API under Ruby 2.6;
  Ruby reaches Mojo through Fiddle, and magnus and rb-sys are gone.

Android:

- **The generated Java runtime needs API 26, not API 21**: no library is built for Android.
- **ART is not a desktop JVM**: the driver is no longer dexed or run with `app_process`.
- **On-device recording needs Android SDK build-tools**: there is no on-device recording.
- **NDK discovery must ignore half-installed NDKs**: nothing looks for an NDK.
