#!/usr/bin/env python3
"""Build tool/record/inputs.jsonl: the cases the Phase 1 binary is recorded on.

Each line is one `app record --inputs` case: {"name", "args", "stdin", "env", "files"}. Every
case runs in an empty directory (docs/pitfalls.md), so a fixture a command reads is copied in
through `files`. Files a command regenerates are present with a stale marker first, so a run that
writes nothing cannot pass (docs/pitfalls.md). `setup` and `doctor` run with HOME=".", the case's
own directory, so they never read or write the real home.

Usage: python3 tool/record/make_inputs.py [--fallback tool/fallback/mojo-anything]
It runs the fallback binary to find unit ids and to pre-record the CLI fixture whose cases
`app replay` and `app front-door` read. The output is sorted and deterministic.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.join(REPO, "tool", "record", "inputs.jsonl")
MAX_FILE = 100_000
MAX_CASE = 150_000
# Lock files are large and no recorded command reads them; leaving them out keeps the case
# folders small (every case holds its own copy of its fixture).
LEFT_OUT = {"pixi.lock", "Cargo.lock", "package-lock.json"}
# The files `refresh` rewrites in each port it is recorded on (from its own "Regenerated" line).
REFRESHED = {
    "demo/real-world/psychrometrics-mojo/psychrometrics-mojo": ["exports.mojo", "cpp/shim.cpp", "cpp/wrapper.cpp"],
    "demo/real-world/vercel-ms-mojo": ["pixi.toml", "json.mojo", "dispatcher.mojo", "node_shim.c", "binding.gyp", "index.cjs"],
}
STALE = "stale: mojo-anything must regenerate this file\n"

SUBCOMMANDS = [
    "analyze", "bridge", "refresh", "record", "build", "diff", "bench", "fuzz", "profile",
    "shadow", "gate", "package", "app", "mcp", "setup", "map", "doctor",
]
APP_SUBCOMMANDS = ["record", "replay", "front-door", "wire", "lift"]

cases = []
skipped = []


def case(name, args, stdin=None, env=None, files=None):
    line = {"name": name, "args": args}
    if stdin is not None:
        line["stdin"] = stdin
    if env:
        line["env"] = env
    if files:
        line["files"] = files
    cases.append(line)


def tracked(rel):
    out = subprocess.run(
        ["git", "ls-files", "-z", "--", rel], cwd=REPO, capture_output=True, check=True
    ).stdout.decode()
    return sorted(p for p in out.split("\0") if p)


def fixture(rel, under=""):
    """The fixture's tracked text files, keyed relative to the fixture (prefixed by `under`),
    or None when it holds too much to copy into every case."""
    files = {}
    total = 0
    for path in tracked(rel):
        full = os.path.join(REPO, path)
        if os.path.islink(full) or not os.path.isfile(full):
            continue
        if os.path.basename(path) in LEFT_OUT or path.endswith(".rust-era.jsonl"):
            continue
        size = os.path.getsize(full)
        if size > MAX_FILE:
            continue
        try:
            text = open(full, encoding="utf-8").read()
        except UnicodeDecodeError:
            continue
        total += size
        files[under + os.path.relpath(path, rel)] = text
    if total > MAX_CASE:
        skipped.append(f"{rel}: {total} bytes")
        return None
    return files


def slug(rel):
    return rel.replace("tests/fixtures/", "").replace("demo/", "demo-").replace("/", "-")


def run_fallback(fallback, args, files, cwd_files_out=None):
    """Run the fallback binary in a scratch copy of `files`; return (stdout, the folder's files)."""
    tmp = tempfile.mkdtemp(prefix="mojo-anything-inputs-")
    try:
        for path, text in files.items():
            target = os.path.join(tmp, path)
            os.makedirs(os.path.dirname(target), exist_ok=True)
            with open(target, "w", encoding="utf-8") as f:
                f.write(text)
        done = subprocess.run(
            [fallback] + args, cwd=tmp, capture_output=True, stdin=subprocess.DEVNULL, timeout=300
        )
        written = {}
        if cwd_files_out:
            base = os.path.join(tmp, cwd_files_out)
            for root, _, names in os.walk(base):
                for n in names:
                    full = os.path.join(root, n)
                    try:
                        written[os.path.relpath(full, tmp)] = open(full, encoding="utf-8").read()
                    except UnicodeDecodeError:
                        pass
        return done, written
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def first_unit(fallback, files):
    done, _ = run_fallback(fallback, ["analyze", ".", "--json"], files)
    if done.returncode != 0:
        return None
    report = json.loads(done.stdout)
    for unit in report.get("units", []):
        uid = unit if isinstance(unit, str) else unit.get("id")
        if uid:
            return uid
    return None


def help_and_usage():
    for args, name in [
        ([], "no-args"), (["--help"], "help"), (["-h"], "help-short"), (["--version"], "version"),
        (["-V"], "version-short"), (["help"], "help-subcommand"), (["nope"], "unknown-subcommand"),
        (["--nope"], "unknown-flag"),
    ]:
        case(f"top-{name}", args)
    for sub in SUBCOMMANDS:
        case(f"{sub}-help", [sub, "--help"])
        case(f"{sub}-help-short", [sub, "-h"])
        case(f"help-{sub}", ["help", sub])
        case(f"{sub}-unknown-flag", [sub, "--nope"])
    case("app-no-subcommand", ["app"])
    case("app-unknown-subcommand", ["app", "nope"])
    for sub in APP_SUBCOMMANDS:
        case(f"app-{sub}-help", ["app", sub, "--help"])
        case(f"app-{sub}-help-short", ["app", sub, "-h"])
        case(f"help-app-{sub}", ["help", "app", sub])
        case(f"app-{sub}-unknown-flag", ["app", sub, "--nope"])


def error_paths():
    errors = {
        "analyze": [["missing-dir"], [".", "--lang", "cobol"], ["--out"], [".", "--json", "--out"]],
        "bridge": [[], ["."], ["missing-dir", "unit"], [".", "nope"], [".", "unit", "--kind", "jvm"]],
        "refresh": [[], ["missing-dir"]],
        "record": [[], ["missing-dir"], ["--count", "many"], [".", "--profile", "android"]],
        "build": [[], ["missing-dir"], ["--profile", "android"]],
        "diff": [[], ["missing-dir"], ["--float-tolerance", "x"]],
        "bench": [[], ["missing-dir"], ["--min-ms", "-1"]],
        "fuzz": [[], ["missing-dir"], ["--keep=some"], ["--seed", "x"]],
        "profile": [[], ["."], [".", "--", "true"], [".", "--lang", "cobol", "--", "true"]],
        "shadow": [[], ["missing-dir"]],
        "gate": [[], ["--json"], ["missing-dir"]],
        "package": [[], ["--dry-run"], ["missing-dir", "--dry-run", "--json"]],
        "map": [["missing-dir"], [], ["--json"], ["--check"]],
        "setup": [["--agent", "nope"], ["--remove", "--json", "--dry-run"]],
    }
    for sub, variants in errors.items():
        for i, rest in enumerate(variants, 1):
            env = {"HOME": "."} if sub == "setup" else None
            case(f"{sub}-error-{i:02}", [sub] + rest, env=env)
    app_errors = {
        "record": [[], ["missing-dir", "--", "true"], [".", "--float-file", "x", "--", "true"],
                   [".", "--normalize", "nope", "--", "true"]],
        "replay": [[], ["missing-dir"], [".", "--build", ""]],
        "front-door": [[], ["missing-dir"]],
        "wire": [[], ["."], [".", "nope"]],
        "lift": [[], ["missing-dir"]],
    }
    for sub, variants in app_errors.items():
        for i, rest in enumerate(variants, 1):
            case(f"app-{sub}-error-{i:02}", ["app", sub] + rest)


def fixture_runs(fallback):
    roots = sorted(
        p for p in (
            [os.path.join("tests/fixtures", d) for d in os.listdir(os.path.join(REPO, "tests/fixtures"))]
            + [os.path.join("demo/fixtures", d) for d in os.listdir(os.path.join(REPO, "demo/fixtures"))]
            + [os.path.join("demo/real-world", d) for d in os.listdir(os.path.join(REPO, "demo/real-world"))]
        ) if os.path.isdir(os.path.join(REPO, p))
    )
    for rel in roots:
        files = fixture(rel)
        if not files:
            continue
        s = slug(rel)
        case(f"analyze-{s}", ["analyze", "."], files=files)
        case(f"analyze-json-{s}", ["analyze", ".", "--json"], files=files)
        case(f"map-{s}", ["map", "."], files=files)
        case(f"map-json-{s}", ["map", ".", "--json"], files=files)
        if rel.startswith("tests/fixtures/"):
            unit = first_unit(fallback, files)
            if unit:
                case(f"bridge-{s}", ["bridge", ".", unit], files=files)
    for rel in sorted(os.listdir(os.path.join(REPO, "tests/fixtures/cli"))):
        files = fixture(os.path.join("tests/fixtures/cli", rel))
        case(f"analyze-whole-app-cli-{rel}", ["analyze", ".", "--whole-app"], files=files)
        case(f"analyze-whole-app-json-cli-{rel}", ["analyze", ".", "--whole-app", "--json"], files=files)
    # Port commands that need no Mojo build: build, diff, bench, fuzz and gate build the port in
    # a fresh pixi environment per case and are recorded through their error paths only.
    for rel in ["demo/real-world/psychrometrics-mojo/psychrometrics-mojo", "demo/real-world/vercel-ms-mojo"]:
        files = fixture(rel)
        if not files:
            continue
        s = slug(rel)
        case(f"package-dry-run-{s}", ["package", ".", "--dry-run"], files=files)
        case(f"package-dry-run-json-{s}", ["package", ".", "--dry-run", "--json"], files=files)
        case(f"shadow-{s}", ["shadow", "."], files=files)
        # refresh regenerates the bindings: start from stale copies of them.
        stale = dict(files)
        for path in REFRESHED.get(rel, []):
            stale[path] = STALE
        case(f"refresh-{s}", ["refresh", "."], files=stale)
    # map --write regenerates mojo/PORT_MAP.md: start from a stale one.
    for rel in ["tests/fixtures/go-mojo-ports", "tests/fixtures/ruby-mojo-ports", "demo/real-world/vercel-ms-mojo"]:
        files = fixture(rel)
        if files:
            stale = dict(files)
            stale["mojo/PORT_MAP.md"] = STALE
            case(f"map-write-{slug(rel)}", ["map", ".", "--write"], files=stale)
            case(f"map-check-{slug(rel)}", ["map", ".", "--check"], files=files)


def app_runs(fallback):
    cli = fixture("tests/fixtures/cli/python")
    record = ["app", "record", ".", "--no-traps", "--", "python3", "tcli.py"]
    case("app-record-cli-python", record, files=cli)
    case("app-record-json-cli-python", record[:3] + ["--json"] + record[3:], files=cli)
    # The cases `app replay` and `front-door` read: recorded once by the fallback.
    done, recorded = run_fallback(fallback, record, cli, cwd_files_out="mojo/app-cases")
    if done.returncode != 0:
        sys.exit(f"pre-recording the CLI fixture failed:\n{done.stderr.decode()}")
    with_cases = dict(cli)
    with_cases.update(recorded)
    with_cases["mojo/app-cases/replay-report.md"] = STALE
    case("app-replay-cli-python", ["app", "replay", "."], files=with_cases)
    case("app-replay-json-cli-python", ["app", "replay", ".", "--json"], files=with_cases)
    first = sorted(p for p in recorded if p.endswith(".toml"))[0]
    one = os.path.splitext(os.path.basename(first))[0]
    case("app-replay-one-case-cli-python", ["app", "replay", ".", "--case", one], files=with_cases)
    case("app-replay-no-such-case-cli-python", ["app", "replay", ".", "--case", "nope"], files=with_cases)
    case("app-replay-build-fails-cli-python", ["app", "replay", ".", "--build", "false"], files=with_cases)
    # `app front-door` installs a pixi environment in mojo/app even with --no-check (about
    # 900 MB per case): recorded through its help and error paths only, like `build`.
    case("app-lift-no-front-door-cli-python", ["app", "lift", "."], files=with_cases)
    case("app-wire-no-front-door-cli-python", ["app", "wire", ".", "textops-mojo"], files=with_cases)


def setup_runs():
    home = {"HOME": "."}
    for agent in ["claude", "codex", "cursor", "gemini", "opencode"]:
        case(f"setup-{agent}", ["setup", "--agent", agent], env=home)
        case(f"setup-{agent}-dry-run", ["setup", "--agent", agent, "--dry-run"], env=home)
        case(f"setup-{agent}-json", ["setup", "--agent", agent, "--json", "--no-backup"], env=home)
    case("setup-no-agent", ["setup"], env=home)
    case("setup-dry-run", ["setup", "--dry-run"], env=home)
    # Codex's config keeps the user's own text and comments.
    codex = {".codex/config.toml": "# my settings\nmodel = \"o3\"  # keep this\n\n[mcp_servers.other]\ncommand = \"other\"\n"}
    case("setup-codex-keeps-comments", ["setup", "--agent", "codex"], env=home, files=codex)
    claude = {".claude.json": "{\n  \"theme\": \"dark\",\n  \"mcpServers\": {\n    \"other\": {\"command\": \"other\"}\n  }\n}\n"}
    case("setup-claude-keeps-settings", ["setup", "--agent", "claude"], env=home, files=claude)
    case("setup-claude-remove-nothing", ["setup", "--agent", "claude", "--remove"], env=home, files=claude)
    # `go version` writes dated telemetry counters under the config folder; a relative
    # XDG_CONFIG_HOME is refused by Go, so it writes none.
    doctor_env = {"HOME": ".", "XDG_CONFIG_HOME": ".no-config"}
    case("doctor", ["doctor"], env=doctor_env)
    case("doctor-json", ["doctor", "--json"], env=doctor_env)


def mcp_runs():
    def session(*messages):
        return "".join(json.dumps(m) + "\n" for m in messages)

    init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "record", "version": "1"}}}
    note = {"jsonrpc": "2.0", "method": "notifications/initialized"}
    case("mcp-initialize", ["mcp"], stdin=session(init))
    case("mcp-tools-list", ["mcp"], stdin=session(init, note, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}))
    case("mcp-prompts-list", ["mcp"], stdin=session(init, {"jsonrpc": "2.0", "id": 2, "method": "prompts/list"}))
    case("mcp-ping-and-unknown", ["mcp"], stdin=session(
        init, {"jsonrpc": "2.0", "id": 2, "method": "ping"}, {"jsonrpc": "2.0", "id": 3, "method": "nope"}))
    case("mcp-not-json", ["mcp"], stdin="not json\n")
    case("mcp-empty", ["mcp"], stdin="")
    tools = ["analyze", "bridge", "refresh", "record", "build", "diff", "profile", "bench", "fuzz",
             "shadow", "map", "package", "gate", "app_record", "app_replay", "app_front_door",
             "app_wire", "app_lift", "nope"]
    for i, tool in enumerate(tools):
        call = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": {}}}
        case(f"mcp-call-{tool.replace('_', '-')}-no-arguments", ["mcp"], stdin=session(init, call))
    mini = fixture("tests/fixtures/python")
    for tool, args in [("analyze", {"root": "."}), ("map", {"repo": "."})]:
        call = {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": tool, "arguments": args}}
        case(f"mcp-call-{tool}-python", ["mcp"], stdin=session(init, call), files=mini)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--fallback", default=os.path.join(REPO, "tool", "fallback", "mojo-anything"))
    opts = parser.parse_args()
    fallback = os.path.abspath(opts.fallback)
    if not os.access(fallback, os.X_OK):
        sys.exit(f"no fallback binary at {fallback}: run scripts/build-fallback.sh")
    help_and_usage()
    error_paths()
    fixture_runs(fallback)
    app_runs(fallback)
    setup_runs()
    mcp_runs()
    names = [c["name"] for c in cases]
    dupes = sorted({n for n in names if names.count(n) > 1})
    if dupes:
        sys.exit(f"duplicate case names: {dupes}")
    with open(OUT, "w", encoding="utf-8") as f:
        for c in cases:
            f.write(json.dumps(c, ensure_ascii=False, sort_keys=True) + "\n")
    print(f"wrote {len(cases)} cases to {os.path.relpath(OUT, REPO)}")
    for s in skipped:
        print(f"skipped (too large to copy into every case): {s}")


if __name__ == "__main__":
    main()
