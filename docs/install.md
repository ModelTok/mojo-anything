# Install, update and develop

Every way to install mojo-anything, keep it up to date, remove it, and build it from source. Back to the [README](../README.md).

## Install

mojo-anything runs on Linux (x64, arm64) and macOS (Apple silicon). Mojo has no native Windows
or Intel macOS build, so neither has mojo-anything: on Windows, use it inside WSL
(`wsl --install -d Ubuntu-24.04`). So far it has been run on x86-64 Linux only; macOS has not been
run ([Status](STATUS.md#known-gaps)).

**No release exists yet.** Until version 0.1.0 is published, the npm package and the release
archives below answer "not found"; build it [from a clone](#from-a-clone) instead.

Once 0.1.0 is published:

```sh
npm install -g mojo-anything   # a launcher; the first run downloads the release binary
```

The npm package holds only a launcher. On first run it downloads
`mojo-anything-v<version>-<target>.tar.gz` and `SHA256SUMS` from the GitHub release, checks the
archive's SHA-256, and keeps the binary in a cache folder (`MOJO_ANYTHING_CACHE`, else the
platform's cache folder); `MOJO_ANYTHING_DOWNLOAD_BASE` points it at a mirror. On Windows it
stops and names WSL. Or take the archive for your platform from the
[releases page](https://github.com/ModelTok/mojo-anything/releases) yourself, check it against
`SHA256SUMS`, and put `mojo-anything` on your `PATH`.

### What it needs

- [pixi](https://pixi.sh). Every unit mojo-anything writes has a `pixi.toml` that pins Mojo 1.2.0
  (and EmberJson where the unit uses JSON), and `build` runs Mojo through it, so Mojo is not
  installed by hand. The first build downloads it.
- The runtime of the language you port, for `record`, `diff` and `gate`, which run the original:
  Node 22.6+ for TS/JS (it runs `.ts` sources directly; the `mojo-wasm` bridge and `profile`
  need Node 24), Python 3.9+ for Python, and for C (ctypes), Go 1.21+, Ruby 3+, Java 22+ (`javac`
  and `java`) for Java and Kotlin (`kotlinc` too). C needs a C compiler.
- The `mojo-wasm` bridge also needs a checkout of [mojo-wasm](https://github.com/lee101/mojo-wasm)
  (`MOJOWASM_HOME`, else `~/github/mojo-wasm`) for its clang and wasm-ld.

`mojo-anything doctor` lists each of these with its version and the command that installs or
updates what is missing.

### From a clone

mojo-anything itself is written in Rust; building it needs a stable Rust toolchain:

```sh
git clone https://github.com/ModelTok/mojo-anything
cd mojo-anything
cargo build --release              # target/release/mojo-anything
```

Put `target/release/mojo-anything` on your `PATH`.

### Agents

`mojo-anything setup` registers everything (see the README's Quick start). The same MCP server and
skill also ship as a Codex plugin from `.agents/plugins/marketplace.json`
(`codex plugin marketplace add ModelTok/mojo-anything`, then
`codex plugin add mojo-anything@mojo-anything`). To add the MCP server to one project by hand
instead (`.mcp.json`):

```json
{ "mcpServers": { "mojo-anything": { "command": "mojo-anything", "args": ["mcp"] } } }
```

OpenCode takes a local server under `mcp.servers` and the whole argv in one `command` array, in
`~/.config/opencode/opencode.json` (an older file that lists servers directly under `mcp` keeps
that shape):

```json
{
  "mcp": {
    "servers": {
      "mojo-anything": { "type": "local", "command": ["mojo-anything", "mcp"] }
    }
  }
}
```

Its skill goes in `~/.config/opencode/skills/mojo-anything/` (`SKILL.md` and `whole-app.md` from
[`skills/mojo-anything/`](../skills/mojo-anything)).

Every tool, its parameters and what it may touch: [docs/tools.md](tools.md). The server also
offers two prompts, `port_unit` and `port_whole_app`, built from the skill.

## Development

From a clone, in Linux or WSL:

```sh
cargo test                        # unit tests, fixtures, the record/diff/gate loop per language, app record/replay
cargo clippy --all-targets -- -D warnings
cargo fmt
```

Tests that need a runtime that is missing are skipped; `MOJO_ANYTHING_REQUIRE=node,python3,go,ruby,java,cc,mojo`
makes them fail instead, as CI does. Design choices and their reasons: [DECISIONS.md](../DECISIONS.md).

## Update or remove

Once 0.1.0 is published:

```sh
npm install -g mojo-anything@latest                             # update
mojo-anything setup                                             # refresh agent settings
mojo-anything setup --remove && npm uninstall -g mojo-anything  # remove
```

From a clone: `git pull` and `cargo build --release` again.

`setup --remove` takes out only mojo-anything's entries; the copies it saved
(`<file>.mojo-anything.bak`) stay until you delete them.
