# mojo-anything, the Mojo tool. Phase 2 moves the Rust tool's subcommands here
# one at a time; a subcommand in `owned()` runs in Mojo, every other one runs
# the Phase 1 binary (tool/fallback/mojo-anything) in this process's place.

from std.sys import argv, exit

from mojo_anything.fallback import fallback, report_owned


def owned() -> List[String]:
    """The subcommands answered in Mojo. Later tasks add to it."""
    return List[String]()


def main():
    var raw = argv()
    var args = List[String]()
    for i in range(len(raw)):
        args.append(String(raw[i]))
    var command = String("")
    if len(args) > 1:
        command = args[1]
    if command in owned():
        report_owned()
        exit(0)
    exit(fallback(args))
