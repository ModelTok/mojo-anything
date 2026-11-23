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


def owned() -> List[String]:
    """The subcommands answered in Mojo. Later tasks add to it."""
    return List[String]()


def run(p: Parsed) raises -> Int:
    """Runs an owned subcommand; returns its exit code."""
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
        try:
            exit(run(outcome.parsed))
        except e:
            print("error:", e, file=stderr)
            exit(2)
    exit(fallback(args))
