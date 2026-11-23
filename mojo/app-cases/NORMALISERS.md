# Normalisers of the Phase 2 recording

These cases are the Phase 1 binary (`v0.1.0`, built by `scripts/build-fallback.sh` into
`tool/fallback/mojo-anything`) recorded on `tool/record/inputs.jsonl` by `tool/record/record.sh`.
Help text and every message the tool writes itself match byte for byte; only the text below is
masked, each part replaced by `[..]` in the recording and in every replay. The rules live in
`mojo-anything.json` (`normalize` and `normalizers`).

| Name | Masks | Why |
| --- | --- | --- |
| `timestamps` (built-in) | dates and times | none of the tool's own output carries one, but files a command copies or writes may |
| `uuids` (built-in) | UUIDs | the same, for ids |
| `binary` | the absolute path of `tool/fallback/mojo-anything` or `tool/build/mojo-anything` | `setup`, `doctor` and the MCP checks print the running binary's own path, which depends on where the repository is checked out, and differs between the Phase 1 binary and the Mojo one |
| `pixi-path` | the absolute path of `.pixi/bin/pixi` | `doctor` names where it found pixi, under the user's home |
| `scratch` | `/tmp/mojo-anything-...` folders | temporary folders the tool creates are named after its process id |
| `pixi-version` | `pixi X.Y.Z` | an outside tool's version: `doctor` reports the installed pixi |
| `tool-version` | the version lines of Python, Node, cc, Go, Ruby, Java, javac and kotlinc | outside tools' versions, in `doctor`'s text and JSON reports |

Not masked, on purpose:

- The pinned Mojo's version (`Mojo 1.2.0 (2016d0cd)`): it is pinned by `pixi.toml`, and a
  different one is a finding.
- The case directory: `app record` already writes it as `[CWD]`.
- Which optional runtimes `doctor` finds (`missing php`): the recording is made on the machine
  the replays run on; re-record on another machine.
