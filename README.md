<p align="center">
  <img src="docs/assets/logo-mojo.svg" width="160" height="160" alt="mojo-anything: a flame with a check mark">
</p>

<h1 align="center">mojo-anything</h1>

<p align="center"><b>Rewrite your app in Mojo, and prove it still behaves the same.</b><br>
Point it at your app: it records what the original does, your coding agent writes the Mojo one piece at a time,<br>
and every piece is checked against that recording before it moves on. It doesn't translate code; it proves the rewrite.</p>

<p align="center"><b><a href="#quick-start">Install</a></b> · <a href="docs/real-world-languages.md">Real code, ported</a> · <a href="docs/how-it-works.md#how-it-works">How it works</a> · <a href="docs/whole-apps.md#port-a-whole-app">Whole apps</a> · <a href="docs/STATUS.md">Status</a> · <a href="docs/faq.md#faq">FAQ</a> · <a href="LICENSE">MIT</a></p>

<table>
  <tr>
    <td width="25%" valign="top">
      <b>Record</b><br>
      <code>record</code> runs the original on generated edge cases, semantic traps and your own inputs, and saves what it returns or throws.
    </td>
    <td width="25%" valign="top">
      <b>Port</b><br>
      <code>bridge</code> generates the Mojo unit and the bindings, so callers keep the original API. You or your agent write <code>port.mojo</code>.
    </td>
    <td width="25%" valign="top">
      <b>Check</b><br>
      <code>diff</code> replays every recorded case against the Mojo, and nothing ships until they all match and <code>gate</code> passes.
    </td>
    <td width="25%" valign="top">
      <b>Lift</b><br>
      When replay passes with no fallback and every unit passes gate, <code>app lift</code> makes it a pure Mojo app. The original is never touched.
    </td>
  </tr>
</table>

**Rewrite your app in Mojo, one piece at a time.** mojo-anything records what your Node.js
(TypeScript/JavaScript), Python, C, Go, Ruby, Java or Kotlin code does today, then checks every
piece of the Mojo rewrite against that recording before it moves on. CLIs, HTTP servers and
libraries; your coding agent (or you) writes the Mojo. Each port is called from the original
language through a bridge mojo-anything generates (a Node-API addon or a wasm module, a Python
extension, a C ABI library, a JSON dispatcher for Go and Ruby, Java's Foreign Function & Memory
API); mojo-anything decides what to move and proves it matches. It can only catch what the
recording covers: see [What it can't catch](docs/how-it-works.md#what-it-cant-catch).

It runs on Linux and macOS (on Windows, inside WSL). Every test and every run below was on
x86-64 Linux; macOS has not been run yet ([Status](docs/STATUS.md#known-gaps)).

### Real code, ported to Mojo

Each unit below was ported to Mojo 1.2.0 and checked again on 2026-11-22 by `build`, `diff`
and `gate` on a copy of its demo folder; each row links the log of that run.

| Real code | Bridge | Recorded cases matched | `gate` | Log |
| --- | --- | ---: | --- | --- |
| [vercel/ms](docs/real-world.md#vercelms-on-mojo) | Node-API addon | 1,128/1,128 | passes | [log](docs/measurements/2026-11-22-vercel-ms-node.md) |
| vercel/ms | wasm module (Node 24) | 1,128/1,128 | passes | [log](docs/measurements/2026-11-22-vercel-ms-wasm.md) |
| CPython 3.13's [`colorsys`](docs/real-world-languages.md) | Python extension | 2,400/2,400 | passes | [log](docs/measurements/2026-11-22-colorsys.md) |
| CPython 3.12's [`quopri`](docs/real-world-languages.md#a-whole-cli-lifted-to-mojo-cpythons-quopri) (unit) | Python extension | 481/481 (4 by `known-diffs.jsonl`) | passes | [log](docs/measurements/2026-11-22-quopri.md) |
| `python3 -m quopri`, lifted to a pure Mojo binary | none left | 163/163 CLI cases, original moved away | - | [log](docs/measurements/2026-11-22-quopri.md) |
| Go 1.24's `path` | JSON dispatcher over cgo | 2,042/2,042 | passes | [log](docs/measurements/2026-11-22-go-path.md) |
| Ruby 3.3's `shellwords` | JSON dispatcher over Fiddle | 1,626/1,626 | passes | [log](docs/measurements/2026-11-22-shellwords.md) |
| OpenJDK 25 behind a facade | Foreign Function & Memory API | 4,782/4,782 | passes | [log](docs/measurements/2026-11-22-jdk-facade.md) |
| ffmpeg n7.1's `rational.c` | C ABI, ffmpeg's own signatures | 46,764/46,764 | passes | [log](docs/measurements/2026-11-22-ffmpeg-rational.md) |
| glibc behind a facade | C ABI | 2,488/2,488 | passes (`size` not compared: the C calls glibc) | [log](docs/measurements/2026-11-22-glibc-facade.md) |

How fast the Mojo ports are against their originals is not published yet: the timings wait for
a run on a quiet machine, and no speed figure carries over from rust-anything, whose Rust ports
these are not.

> [!WARNING]
> `record` and `app record` run your original code, calling each function (or the whole app) on
> many generated inputs, and `app record` runs every case twice. `diff`, `gate` and `app replay`
> run the same cases again, on the port or the original. Code that writes files, talks to a
> database or calls the network does that once per case. Run them on a copy of the project, with a
> test database and no production credentials in the environment.

## Quick start

**No release exists yet.** Version 0.1.0 is not published, so the two install paths below
answer "not found" until it is; until then, build mojo-anything from a clone
([Install](docs/install.md#from-a-clone)).

Once 0.1.0 is published, on Linux (x64, arm64) or macOS (Apple silicon):

```sh
npm install -g mojo-anything   # a launcher that downloads the release binary on first run
mojo-anything setup            # registers it with Claude Code, Codex, Cursor, Gemini CLI and OpenCode
mojo-anything doctor           # what is installed, and the command for what is missing
```

or unpack `mojo-anything-v0.1.0-<target>.tar.gz` from the
[GitHub release](https://github.com/ModelTok/mojo-anything/releases) (checked against its
`SHA256SUMS`) and put `mojo-anything` on your `PATH`. On Windows, use it inside WSL. Mojo itself
comes from [pixi](https://pixi.sh): every unit pins Mojo 1.2.0 in its own `pixi.toml`, so there
is nothing else to install for Mojo.

Paste this into Claude Code, Codex, Cursor, Gemini CLI or OpenCode and let your agent install it:

```text
Install mojo-anything: run `npm install -g mojo-anything`, then `mojo-anything setup`.
Tell me when to restart you.
```

In Claude Code you can also install it as a plugin (the MCP server and the skill; the CLI above
must be on your `PATH`):

```text
/plugin install mojo-anything --marketplace ModelTok/mojo-anything
```

In Codex, from the agents marketplace in this repository (`.agents/plugins/marketplace.json`, the
same plugin under `plugin/`, with the skill and MCP server):

```sh
codex plugin marketplace add ModelTok/mojo-anything
codex plugin add mojo-anything@mojo-anything
```

`setup` adds the MCP server to each agent it finds and installs the workflow skill where the agent
reads skills. It keeps your other settings, is safe to run again, and `--remove` undoes it.
Then ask your agent, for example:

- *"Rewrite this CLI in Mojo with mojo-anything, end to end, and prove it behaves the same."*
- *"Plan a migration of `src/parser/` to Mojo with mojo-anything; port the first unit and prove it."*
- *"Port `colorsys.py` to Mojo with mojo-anything and run gate on it."*

### Works with

| Agent | `mojo-anything setup` adds |
| --- | --- |
| Claude Code | MCP server in `~/.claude.json`, skill in `~/.claude/skills/` |
| Codex | MCP server in `~/.codex/config.toml`, skill in `~/.codex/skills/` |
| Cursor | MCP server in `~/.cursor/mcp.json` |
| Gemini CLI | MCP server in `~/.gemini/settings.json` |
| OpenCode | MCP server in `~/.config/opencode/opencode.json` (`mcp.servers`), skill in `~/.config/opencode/skills/` |
| Any other MCP client | add `mojo-anything mcp` as a stdio server by hand (see [Install](docs/install.md#agents)) |

Before changing a file that exists, `setup` saves a copy beside it (`<file>.mojo-anything.bak`);
`--no-backup` skips the copy.

Or run the steps yourself:

```sh
mojo-anything analyze .                                 # units, port order, risks, Mojo replacements
mojo-anything bridge . src/colorsys.py                  # mojo/colorsys-mojo: bindings and port.mojo stubs
mojo-anything record mojo/colorsys-mojo                 # what the original does
# write port.mojo (or let your agent), then:
mojo-anything build mojo/colorsys-mojo
mojo-anything diff mojo/colorsys-mojo                   # every recorded case must match
mojo-anything fuzz mojo/colorsys-mojo --time 60 --keep  # fresh inputs: what the recording missed
mojo-anything gate mojo/colorsys-mojo                   # done means this passes
```

mojo-anything does not translate code: your coding agent (Claude Code, Codex, Cursor, OpenCode,
...) or you write the Mojo. mojo-anything supplies what an agent cannot guess reliably: what to
port first and in which order, a bridge so the rest of the code calls the Mojo with its API
unchanged, the exact behaviour the port must match, a safe way to ship it, and a gate that says
when a port is done.

## Languages

| Language | Unit | Bridge | Recorded and replayed by |
| --- | --- | --- | --- |
| TypeScript/JavaScript | folder or file | `mojo-node`: a Node-API addon over the Mojo port (the default); `mojo-wasm`: the port compiled to a wasm64 module, Node 24+ | Node, running the `.ts` sources |
| Python | package or module | `mojo-py`: a Python extension module built by Mojo, typed exceptions | Python, importing the original |
| C | `.c` file | `c-abi`: functions with the original names and signatures, and a header | the original compiled to a shared library, called through ctypes, one fork per case |
| Go | package | `ffi`: cgo calls into a JSON dispatcher, in a package with the original API | a generated Go driver, built as its own module |
| Ruby | file or folder of module functions | `ffi`: Fiddle calls into a JSON dispatcher, under the original modules | a generated Ruby driver |
| Java | package of `public static` methods | `mojo-jvm`: wrapper classes with the original methods, calling the port's JSON dispatcher through the Foreign Function & Memory API (Java 22+) | a generated reflection driver |
| Kotlin | Gradle module of top-level functions and `@JvmStatic` methods | `mojo-jvm`, with the Java wrapper classes named for the JVM owners (`<File>Kt`, the `@JvmStatic` class) | a generated reflection driver, with the Kotlin sources compiled by `kotlinc` |
| PHP | folder of functions and `public static` methods | none yet | whole apps today: `app record`, `app replay` and the Mojo front door, for CLIs and servers (`php -S`) |
| C# | folder of `public static` methods | none yet | whole apps today: `app record`, `app replay` and the Mojo front door, for CLIs and ASP.NET servers (`dotnet <app>.dll`) |

TypeScript/JavaScript units also get batch classes (`--batch`): the items cross once and stay on
the Mojo side, and each call runs the port over all of them. Other languages answer "not yet".

The language is detected from the repository (`go.mod`, `pom.xml`, `build.gradle`/`build.gradle.kts`,
a `.csproj` or `.sln`, `pyproject.toml`, `Gemfile`, `composer.json`, `package.json`, else the most
common source files); a Gradle module with `.kt` sources and no `.java` sources is Kotlin, mixed
modules stay Java. `--lang` overrides it. Types come from the source: TS types, Python hints, C, Go,
Java, Kotlin and C# signatures, Ruby YARD tags, PHP types and phpdoc; untyped parameters used as
numbers are inferred as numbers. `analyze` names a Mojo replacement for each library the code
imports: a Mojo standard-library module, a Mojo package on pixi, or a Python module called through
CPython interop.

## Learn more

- [How it works](docs/how-it-works.md): the loop, what `bridge` and `analyze` decide, batches, what it can't catch, and keeping up with the original (`map`)
- [Port a whole app](docs/whole-apps.md): servers, CLIs and libraries, from the front door to `app lift`
- [Real code in six languages](docs/real-world-languages.md) and [real-world runs](docs/real-world.md): what was ported to Mojo, and how it was checked
- [Ship a port as a package](docs/packaging.md): wheels, npm packages, gems, Go modules, C archives and jars of Mojo ports
- [Install, update and develop](docs/install.md) · [Examples](docs/examples.md) · [FAQ](docs/faq.md) · [Status](docs/STATUS.md) · [MCP tools](docs/tools.md) · [Privacy](docs/privacy.md)

## Credits

mojo-anything is a fork of [rust-anything](https://github.com/erkamyaman/rust-anything) by
[Erkam Yaman](https://github.com/erkamyaman), which records, bridges and gates ports to Rust; the
recording, replay, front-door and agent machinery come from it, and the bridges, ports and gates
were rewritten for Mojo. Thanks to Erkam and to rust-anything's sponsors and contributors, whose
support built what this fork starts from. mojo-anything is an independent project, not
affiliated with or endorsed by Modular or the rust-anything project.

## Contributing

Issues and pull requests are welcome; [CONTRIBUTING.md](./CONTRIBUTING.md) covers the setup, where
tests go, and how to add a language. Design choices and their reasons are in
[DECISIONS.md](./DECISIONS.md). Case studies of real ports are especially welcome. Please report
security problems privately ([SECURITY.md](./SECURITY.md)), and see the
[code of conduct](./CODE_OF_CONDUCT.md).

## License

[MIT](./LICENSE), keeping rust-anything's copyright notice. Ports and generated code in your
repository are yours.
