<p align="center">
  <img src="docs/assets/logo-mojo.svg" width="160" height="160" alt="mojo-anything: a flame with a check mark">
</p>

<h1 align="center">mojo-anything</h1>

<p align="center"><b>Port your app to Mojo, and prove it still behaves the same.</b><br>
It records what the original does, your coding agent writes the Mojo one piece at a time,<br>
and every piece is checked against that recording before it moves on. It doesn't translate code; it proves the port.</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-555" alt="MIT license"></a>
  <img src="https://img.shields.io/badge/Linux-checked-2563EB" alt="Checked on Linux">
  <img src="https://img.shields.io/badge/macOS-not%20checked%20yet-8A8A8A" alt="macOS not checked yet">
  <img src="https://img.shields.io/badge/Windows-through%20WSL-8A8A8A" alt="Windows through WSL">
  <img src="https://img.shields.io/badge/status-pre--release-E8361C" alt="Pre-release">
</p>

<p align="center"><b><a href="#quick-start">Install</a></b> · <a href="docs/STATUS.md">What works today</a> · <a href="docs/real-world.md">Real-world ports</a> · <a href="docs/faq.md#faq">FAQ</a><br>
<sub><a href="#languages">Languages</a> · <a href="docs/how-it-works.md#how-it-works">How it works</a> · <a href="docs/whole-apps.md#port-a-whole-app">Whole apps</a> · <a href="LICENSE">MIT</a></sub><br>
A fork of <a href="https://github.com/erkamyaman/rust-anything">rust-anything</a> by Erkam Yaman, retargeted from Rust to Mojo.</p>

<p align="center"><sub>Pre-release: no version has been tagged yet. Units written in Python, C, Go, Ruby, TypeScript/JavaScript, Java and Kotlin port to Mojo; PHP and C# record and replay only. The docs are still being re-measured on Mojo, and some figures in them still come from rust-anything. See <a href="docs/STATUS.md">STATUS</a>.</sub></p>

<table>
  <tr>
    <td width="25%" valign="top">
      <b>Record</b><br>
      <code>record</code> runs the original on generated edge cases, semantic traps and your own inputs, and saves what it returns or throws.
    </td>
    <td width="25%" valign="top">
      <b>Port</b><br>
      <code>bridge</code> generates a Mojo port to fill in and a wrapper, so callers keep the original API. You or your agent write the Mojo.
    </td>
    <td width="25%" valign="top">
      <b>Check</b><br>
      <code>diff</code> replays every recorded case against the Mojo port, and nothing ships until they all match and <code>gate</code> passes.
    </td>
    <td width="25%" valign="top">
      <b>Lift</b><br>
      When replay passes with no fallback and every unit passes gate, <code>app lift</code> makes it a pure Mojo app. The original is never touched.
    </td>
  </tr>
</table>

**Port your whole app to Mojo, one piece at a time.** mojo-anything records what your
Node.js (TypeScript/JavaScript), Python, C, Go, Ruby, Java or Kotlin code does today, then checks every
piece of the Mojo port against that recording before it moves on, until the app is pure Mojo. CLIs,
HTTP servers and libraries; your coding agent (or you) writes the Mojo. Calls reach the port through
a generated CPython extension (Python), a Node-API shim or a WebAssembly module (Node), the Java
Foreign Function & Memory API on Java 22+ (Java and Kotlin), or a C ABI with a JSON dispatcher (C, Go,
Ruby); mojo-anything decides what to move and proves it matches. It can only catch what the recording
covers: see [What it can't catch](docs/how-it-works.md#what-it-cant-catch).
The speed-ups rust-anything measured for its Rust ports are kept in
[Real-world ports](docs/real-world.md) as history; they are not Mojo results. What the Mojo
ports match and how fast they run so far is in [STATUS](docs/STATUS.md).

> mojo-anything is an independent project, not affiliated with or endorsed by Modular Inc.
> "Mojo" and "Modular" are trademarks of Modular Inc.

> [!WARNING]
> `record` and `app record` run your original code, calling each function (or the whole app) on
> many generated inputs, and `app record` runs every case twice. `diff`, `gate` and `app replay`
> run the same cases again, on the port or the original. Code that writes files, talks to a
> database or calls the network does that once per case. Run them on a copy of the project, with a
> test database and no production credentials in the environment.

## Quick start

Paste this into Claude Code, Codex, Cursor, Gemini CLI or OpenCode and let your agent install it:

```text
Install mojo-anything: run `cargo install mojo-anything`, then `mojo-anything setup`.
Tell me when to restart you.
```

Or yourself:

```sh
cargo install mojo-anything   # from crates.io
mojo-anything setup           # registers it with Claude Code, Codex, Cursor, Gemini CLI and OpenCode
```

No Rust toolchain yet? Prebuilt binaries for macOS, Linux and Windows are attached to each
[GitHub release](https://github.com/erkamyaman/rust-anything/releases), and for JavaScript
projects `npm install -g mojo-anything` installs the same binary.

In Claude Code you can also install it as a plugin (the MCP server and the skill; the CLI above
must be on your `PATH`):

```text
/plugin install mojo-anything --marketplace erkamyaman/mojo-anything
```

In Codex, from the agents marketplace in this repo (`.agents/plugins/marketplace.json`, the same
plugin under `plugin/`, with the skill and MCP server):

```sh
codex plugin marketplace add erkamyaman/mojo-anything
codex plugin add mojo-anything@mojo-anything
```

`setup` adds the MCP server to each agent it finds and installs the workflow skill where the agent
reads skills. It keeps your other settings, is safe to run again, and `--remove` undoes it.
Then ask your agent, for example:

- *"Rewrite this CLI in Rust with mojo-anything, end to end, and prove it behaves the same."*
- *"This search feels slow. Profile it with mojo-anything and move the hot loop to Rust."*
- *"Plan a migration of `src/parser/` to Rust with mojo-anything; port the first unit and prove it."*
- *"Bench the Rust port in `rust/text-rs` against the original and tell me whether to ship it."*

### Works with

| Agent | `mojo-anything setup` adds |
| --- | --- |
| Claude Code | MCP server in `~/.claude.json`, skill in `~/.claude/skills/` |
| Codex | MCP server in `~/.codex/config.toml`, skill in `~/.codex/skills/` |
| Cursor | MCP server in `~/.cursor/mcp.json` |
| Gemini CLI | MCP server in `~/.gemini/settings.json` |
| OpenCode | MCP server in `~/.config/opencode/opencode.json` (`mcp.servers`), skill in `~/.config/opencode/skills/` |
| Any other MCP client | add `mojo-anything mcp` as a stdio server by hand (see [Install](docs/install.md#install)) |

Before changing a file that exists, `setup` saves a copy beside it (`<file>.mojo-anything.bak`); `--no-backup` skips the copy.

To wire OpenCode up by hand, put the server in `~/.config/opencode/opencode.json` (`command` is
the whole argv) and copy [`skills/mojo-anything/`](./skills/mojo-anything) to
`~/.config/opencode/skills/mojo-anything/`:

```json
{
  "mcp": {
    "servers": {
      "mojo-anything": { "type": "local", "command": ["mojo-anything", "mcp"] }
    }
  }
}
```

Or run the steps yourself:

```sh
mojo-anything profile . -- node bench.mjs              # what is hot, and who calls it
mojo-anything bridge . src/fuzzy.ts --batch fuzzyScore:text
# write src/port.rs (or let your agent), then:
mojo-anything record rust/fuzzy-rs && mojo-anything build rust/fuzzy-rs
mojo-anything diff rust/fuzzy-rs                       # every recorded case must match
mojo-anything fuzz rust/fuzzy-rs --time 60 --keep      # fresh inputs: what the recording missed
mojo-anything bench rust/fuzzy-rs                      # faster? the verdict says
mojo-anything gate rust/fuzzy-rs                       # done means this passes
```

mojo-anything does not translate code: your coding agent (Claude Code, Codex, Cursor, OpenCode, ...) or you write
the Rust. mojo-anything supplies what an agent cannot guess reliably: where the time goes, what to port
first and in which order, a bridge so the rest of the code calls the Rust with its API unchanged,
the exact behavior the port must match, a safe way to ship it, and a gate that says when a port is
done.

Same output is not enough. Record what the app sends too, and a rewrite that mails twice fails:

<p align="center">
  <img src="docs/assets/effects.gif" alt="app record with --effects smtp records one welcome email per signup; app replay of a rewrite that prints the same output but mails twice reports 0/2 cases passed, failing on effects, and the report shows the extra email." width="820">
  <br>
  <sub>A real run of <code>app record --effects</code> and <code>app replay</code>. See <a href="docs/whole-apps.md#side-effects-email-webhooks-and-databases">Side effects</a>.</sub>
</p>

## Languages

| Language | Unit | Bridge | Recorded and replayed by |
| --- | --- | --- | --- |
| TypeScript/JavaScript | folder or file | napi-rs or wasm-bindgen with a generated binary wire; classes and async included | Node, running the `.ts` sources |
| Python | package or module | PyO3 (abi3), direct conversion, typed exceptions | Python, importing the original |
| C | `.c` file | `extern "C"` functions with the original names and a header | the original compiled to a shared library, called through ctypes, one fork per case |
| Go | package | typed cgo calls and a generated binary wire, in a package with the original API | a generated Go driver, built as its own module |
| Ruby | file or folder of module functions | a magnus extension under the original modules | a generated Ruby driver |
| Java | package of `public static` methods | a Mojo port behind the JSON dispatcher, called through the Foreign Function & Memory API (Java 22+) from wrapper classes with the original methods | a generated reflection driver |
| Kotlin | Gradle module of top-level functions and `@JvmStatic` methods | the Java bridge: Java wrapper classes named for the JVM owners (`<File>Kt`, the `@JvmStatic` class) over the same Mojo port | a generated reflection driver, with the Kotlin sources compiled by `kotlinc` |
| PHP | folder of functions and `public static` methods | coming next: PHP FFI over a C ABI | whole apps today: `app record`, `app replay` and the front door, for CLIs and servers (`php -S`) |
| C++ | `.cpp`/`.cc`/`.cxx` file of free functions (namespaced or not) over numbers, `bool`, `std::string` and `std::vector` of numbers; classes, templates, overloads and state objects stay in C++ with the reason | `extern "C"` symbols the Mojo library exports, and a generated `cpp/wrapper.cpp` that defines the original functions over them | the original and a generated `extern "C"` shim compiled with `c++` to a shared library, called through ctypes, one fork per case; exceptions are recorded as `<type>: <what()>` |
| C# | folder of `public static` methods | coming next: P/Invoke over a C ABI | whole apps today: `app record`, `app replay` and the front door, for CLIs and ASP.NET servers (`dotnet <app>.dll`) |

Every language except C and C++ also gets batch classes (`--batch`): the items cross once and stay in
Rust, and each call runs over all of them on all cores.

The language is detected from the repository (`go.mod`, `pom.xml`, `build.gradle`/`build.gradle.kts`,
a `.csproj` or `.sln`, `pyproject.toml`, `Gemfile`, `composer.json`, `package.json`, else the most
common source files); a Gradle module with `.kt` sources and no `.java` sources is Kotlin, mixed
modules stay Java. `--lang` overrides it. Types come from the source: TS types, Python hints, C, Go,
Java, Kotlin and C# signatures, Ruby YARD tags, PHP types and phpdoc; untyped parameters used as
numbers are inferred as numbers.

For PHP, `analyze` plans a PHP app (Composer packages and PSR-4 autoloading, risks
such as loose comparison and integer overflow into floats, Composer packages mapped to crates),
and a PHP CLI or server can be recorded, replayed and put behind a Rust front door. Porting its
units into Rust through PHP's FFI is the next step ([issue #2](https://github.com/erkamyaman/rust-anything/issues/2)).

C# works the same way: `analyze` reads `.csproj` projects and their NuGet packages
(mapped to crates), resolves `using` directives to folders, and flags what C# does differently
(`decimal`, `dynamic`, LINQ's deferred queries, `Task`, `lock`, reflection). A C# CLI or ASP.NET
server can be recorded, replayed and put behind a Rust front door; porting units through P/Invoke
comes next.

## Learn more

- [How it works](docs/how-it-works.md): the loop, what `bridge` and `analyze` decide, hot paths, what it can't catch, what a real port takes, and keeping up with the original (`map`)
- [Ship a port as a package](docs/packaging.md): not yet; npm packages of Mojo ports and Python wheels come with the packaging plan
- [Port a whole app](docs/whole-apps.md): servers, CLIs and libraries, from the front door to `app lift`
- [Examples and case studies](docs/examples.md): x18n, and real code in six languages
- [Real-world ports](docs/real-world.md): json-server, Fuse.js, vercel/ms, with benchmarks
- [Install, update and develop](docs/install.md): every install method, Windows, and building from source
- [FAQ](docs/faq.md) · [Status](docs/STATUS.md) · [MCP tools](docs/tools.md)

## Sponsors

<p align="center">
  <a href="https://github.com/erkamyaman/rust-anything">mojo-anything</a> is free and open source. If it helps your work, please consider sponsoring it.<br>
  Your support keeps development going.
</p>

<p align="center">
  <a href="https://coderabbit.link/erkamyaman">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/assets/sponsors/company-dark.svg">
      <img src="docs/assets/sponsors/company-light.svg" width="800" alt="Company sponsor: CodeRabbit">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://github.com/sponsors/erkamyaman">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="docs/assets/sponsors/sponsors-dark.svg">
      <img src="docs/assets/sponsors/sponsors-light.svg" width="800" alt="Sponsors: Santosh Yadav, Hakan Soytürk, Ali Yilmaz, Ashley Hunter, Fatih Uzuntaş">
    </picture>
  </a>
</p>

<p align="center">
  <a href="https://github.com/sponsors/erkamyaman"><img src="https://img.shields.io/badge/Become_a_sponsor-%E2%9D%A4-db61a2?style=for-the-badge&logo=githubsponsors&logoColor=white" alt="Become a sponsor"></a>
  <a href="https://buymeacoffee.com/erkamyaman"><img src="https://img.shields.io/badge/Buy_me_a_coffee-%E2%98%95-FFDD00?style=for-the-badge&logo=buymeacoffee&logoColor=black" alt="Buy me a coffee"></a>
</p>

## Contributing

Issues and pull requests are welcome; [CONTRIBUTING.md](./CONTRIBUTING.md) covers the setup, where
tests go, and how to add a language. Design choices and their reasons are in
[DECISIONS.md](./DECISIONS.md). Case studies of real ports are especially welcome. Please report
security problems privately ([SECURITY.md](./SECURITY.md)), and see the
[code of conduct](./CODE_OF_CONDUCT.md).

## License

[MIT](./LICENSE) © [Erkam Yaman](https://github.com/erkamyaman). Ports and generated code in your repository are yours.
