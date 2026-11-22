# FAQ

Questions people ask about mojo-anything. Back to the [README](../README.md).

## FAQ

**Does it rewrite my code automatically?** No. It finds what to move, generates the bridge,
records what the original does and checks the Mojo against it. You or your agent write the Mojo
in `port.mojo`; `diff` and `gate` decide when it is right.

**Does it compare side effects, not just the output?** Stdout, stderr, the exit code, the files
the app writes and HTTP responses always. Outgoing HTTP calls (webhooks, APIs), email and the
database when you ask for them: `app record --effects http,smtp` runs local fakes and records what
reached them per case, in order; `--db-reset` and `--db-dump` reset the database before each case
and record its state after. Replay compares those too, so a rewrite that returns the same JSON but
sends an email twice, or writes different rows, fails the case. See
[Side effects](whole-apps.md#side-effects-email-webhooks-and-databases).

**Will my app's API change?** No. Callers import the same functions (or the shadow module, which
runs both and returns the original's result while you build confidence).

**Is Mojo faster?** Not measured yet for the ports here: the Mojo timings wait for a run on a
quiet machine, and nothing measured on rust-anything's Rust ports carries over. What is known
from the bridges' shape: a small function called once per item pays a bridge crossing per call,
and V8, the JVM and Go run such functions in nanoseconds, so a per-call port of a leaf can be
slower than the original. `profile` finds the loop around it, `--batch` (TS/JS) moves the whole
loop, and `bench` gives a verdict before you ship. Code already compiled by numba, Cython or JAX
runs as machine code too: `profile` and `analyze` flag it, since porting it buys little speed.

**My code is numeric; will the floats match exactly?** Often not: operation order, fused
multiply-add and the math library differ between compilers. Record with `--float-tolerance 1e-9`
(`record` or `app record`), and floats match within that share of the larger value (absolute below
1). Integers, text and structure still have to match exactly. A file of raw floats the app writes
(numpy `tofile`, `.f32` exports) is compared value by value too when you name it:
`app record --float-file out.f32=f32le` (or `f64le`).

**Can it port an app I only have as an APK, a JAR or an .exe?** No. It ports source code: it
parses the functions, records what each one does, and checks the Mojo against the running
original. A compiled app has none of that to work with, and `analyze` says so.

**Should I port battle-tested C?** Often not, and `analyze` tells you where. C that touches
hardware registers, relies on its compiler's type sizes or memory layout, or uses inline assembly
(`volatile`, bitfields, packed structs, `__asm__`, integers cast to addresses) is marked "keep in
C": a recording on your machine proves nothing about the target, and stable driver or firmware
code gains little from a rewrite. The portable logic around it (parsing, protocols, data handling)
is what moves well.

**Can it port my Electron app?** The logic, yes; the windows stay web pages. `analyze
--whole-app` spots Electron and plans the main process piece by piece while the renderer stays as
it is.

**What about C#, PHP, Kotlin or Swift?** Kotlin is ported for Gradle modules of top-level
functions and `@JvmStatic` methods; C# and PHP are supported for whole apps (record, replay and
the Mojo front door), not yet for units (see [Languages](../README.md#languages)); Swift is not
supported. Each language needs a parser, a recorder, a bridge and a replay driver, all tested end
to end. Open an issue (or upvote one) for the language you need.

**Does it run on Windows?** Inside WSL. Mojo has no native Windows build, so neither has
mojo-anything; `mojo-anything doctor` on Windows says so and points at WSL.

**Won't the Mojo be much bigger than the original?** It shouldn't be. `gate` compares the port's
lines with the original's and fails above three times the original plus 50 lines for imports and
signatures: that usually means hand-writing what a library already does, or handling cases one
by one. `analyze` lists the Mojo replacement for each library. Two of the demos fail this check
today, where the port reimplements what the original borrows ([Status](STATUS.md#known-gaps)).

**Doesn't porting piece by piece lock the Mojo into the old app's design?** Only while both run
side by side. The recordings check behaviour at the app's edges (a CLI's output, a server's
responses, a module's exported functions), not its internals. Mirror the old structure while
units still cross the bridge; once `app lift` has removed the original, restructure the Mojo
freely, and `app replay` still proves the behaviour. Nothing calls back into the original either:
the front door runs it as a separate process (or forwards HTTP to it), bridged units are called
by the original and never the other way round, and callbacks stay in the source language.

**Does my code leave my machine?** No: mojo-anything runs locally and sends none of your code
anywhere. pixi downloads Mojo and packages as usual, and your agent's model provider sees what
your agent sends it, under its own policy ([Privacy](privacy.md)).

**What does it need installed?** pixi, plus the runtime of the language you port (see
[Install](install.md#what-it-needs)).

**Is it related to rust-anything?** It is a fork of
[rust-anything](https://github.com/erkamyaman/rust-anything), which ports to Rust. The recording,
replay, front-door and agent machinery come from it; the bridges, ports and checks were rewritten
for Mojo, and no result of rust-anything's Rust ports is claimed for Mojo.

**Something broke.** Open an [issue](https://github.com/ModelTok/mojo-anything/issues) with the
command, its output, your platform and `mojo-anything --version`.
