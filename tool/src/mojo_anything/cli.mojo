# The command line answered in Mojo: `--version`, `-h`, and the `--help` (or
# `help <command>`) whose text is the same as `-h`. The layout is clap 4's, as
# the Phase 1 binary prints it: each section's left column is padded to its
# longest entry plus two spaces, and nothing is wrapped. Anything else (real
# work, errors, clap's long help) is not owned, and main.mojo hands it to the
# Phase 1 binary.

from mojo_anything.cli_spec import VERSION, long_help, spec
from mojo_anything.cli_types import CommandSpec, Entry


@fieldwise_init
struct Reply(Copyable, Movable):
    var owned: Bool
    """False: the Phase 1 binary answers this command line."""
    var stdout: String
    var code: Int


def _section(title: String, entries: List[Entry]) -> String:
    if len(entries) == 0:
        return ""
    var width = 0
    for i in range(len(entries)):
        width = max(width, len(entries[i].display.codepoints()))
    var out = String("\n") + title + "\n"
    for i in range(len(entries)):
        out += "  " + entries[i].display
        if entries[i].below:
            # An empty help still gets its line of ten spaces.
            out += "\n          " + entries[i].help + "\n"
            continue
        # clap pads an entry with no help text too (`--json` + spaces).
        for _ in range(width - len(entries[i].display.codepoints()) + 2):
            out += " "
        out += entries[i].help + "\n"
    return out


def render_help(c: CommandSpec) -> String:
    """`-h` for one command, as clap prints it."""
    var out = c.about + "\n\nUsage: " + c.usage + "\n"
    out += _section("Commands:", c.commands)
    out += _section("Arguments:", c.arguments)
    out += _section("Options:", c.options)
    if c.after_help != "":
        out += "\n" + c.after_help + "\n"
    return out


def _not_owned() -> Reply:
    return Reply(False, "", 0)


def _help(path: String, long: Bool) -> Reply:
    if long:
        var text = long_help(path)
        if text == "":
            return _not_owned()
        return Reply(True, text, 0)
    var all = spec()
    for i in range(len(all)):
        if all[i].path == path:
            return Reply(True, render_help(all[i]), 0)
    return _not_owned()


def _is_help(flag: String) -> Int:
    """0: not a help flag, 1: `-h`, 2: `--help`."""
    if flag == "-h":
        return 1
    if flag == "--help":
        return 2
    return 0


def _join(args: List[String], start: Int, end: Int) -> String:
    var out = String("")
    for i in range(start, end):
        if i > start:
            out += " "
        out += args[i]
    return out


def decide(args: List[String]) -> Reply:
    """What to answer for `args` (without the program name), or not owned.
    Only a command path followed by one help flag, `help <path>` and a lone
    `--version` are owned; a path the spec does not know is not."""
    var n = len(args)
    if n == 0:
        return _not_owned()
    if n == 1 and (args[0] == "--version" or args[0] == "-V"):
        return Reply(True, VERSION + "\n", 0)
    var last = _is_help(args[n - 1])
    if last != 0 and args[0] != "help":
        if n > 3 or (n == 3 and args[0] != "app"):
            return _not_owned()
        return _help(_join(args, 0, n - 1), last == 2)
    if args[0] == "help":
        if n > 3 or (n == 3 and args[1] != "app"):
            return _not_owned()
        return _help(_join(args, 1, n), True)
    return _not_owned()
