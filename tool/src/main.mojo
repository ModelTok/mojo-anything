# mojo-anything, the Mojo tool. Phase 2 moves the Rust tool's subcommands here
# one at a time; a subcommand in `owned()` runs in Mojo, every other one runs
# the Phase 1 binary (tool/fallback/mojo-anything) in this process's place.
# `--version`, `-h` and the `--help` that matches it are answered in Mojo for
# every subcommand (`cli.mojo`), and so are clap's usage errors
# (`cli_parse.mojo`).

from std.sys import argv, exit, stderr

from mojo_anything.cli import decide
from mojo_anything.cli_parse import PARSED, USAGE_ERROR, Parsed, parse
from mojo_anything.fallback import fallback, report_owned
from mojo_anything.analyze import run_analyze
from mojo_anything.bridge import run_bridge
from mojo_anything.refresh import run_record, run_refresh
from mojo_anything.doctor import run_doctor
from mojo_anything.map import run_map
from mojo_anything.setup import run_setup
from mojo_anything.unit_commands import run_unit_command
from mojo_anything.app.commands import run_app_record, run_app_replay


def owned() -> List[String]:
    """The subcommands answered in Mojo. Later tasks add to it."""
    var out = List[String]()
    out.append("analyze")
    out.append("map")
    out.append("bridge")
    out.append("refresh")
    out.append("record")
    out.append("setup")
    out.append("doctor")
    out.append("build")
    out.append("diff")
    out.append("gate")
    out.append("bench")
    out.append("fuzz")
    out.append("app record")
    out.append("app replay")
    return out^


def run(p: Parsed, args: List[String]) raises -> Int:
    """Runs an owned subcommand; returns its exit code. A command may still
    hand a case it cannot answer exactly to the Phase 1 binary (`fallback`),
    before it has written anything."""
    if p.path() == "analyze":
        return run_analyze(p, args)
    if p.path() == "refresh":
        return run_refresh(p, args)
    if p.path() == "record":
        return run_record(p, args)
    if p.path() == "bridge":
        return run_bridge(p, args)
    if p.path() == "map":
        return run_map(p, args)
    if p.path() == "setup":
        return run_setup(p, args)
    if p.path() == "doctor":
        return run_doctor(p, args)
    if (
        p.path() == "build"
        or p.path() == "diff"
        or p.path() == "gate"
        or p.path() == "bench"
        or p.path() == "fuzz"
    ):
        return run_unit_command(p, args)
    if p.path() == "app record":
        return run_app_record(p, args)
    if p.path() == "app replay":
        return run_app_replay(p, args)
    raise Error("not owned: " + p.path())


def main():
    var raw = argv()
    var args = List[String]()
    for i in range(len(raw)):
        args.append(String(raw[i]))
    var rest = List[String]()
    for i in range(1, len(args)):
        rest.append(args[i])
    var reply = decide(rest)
    if reply.owned:
        report_owned()
        print(reply.stdout, end="")
        exit(reply.code)
    var outcome = parse(rest)
    if outcome.kind == USAGE_ERROR:
        report_owned()
        print(outcome.stderr, end="", file=stderr)
        exit(2)
    if outcome.kind == PARSED and outcome.parsed.path() in owned():
        report_owned()
        var code: Int
        try:
            code = run(outcome.parsed, args)
        except e:
            print("error:", e, file=stderr)
            code = 2
        exit(code)
    exit(fallback(args))
