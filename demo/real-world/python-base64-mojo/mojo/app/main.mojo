# `base64`, lifted by mojo-anything: every command is answered by a unit.

from std.sys import argv, exit, stderr

import units

comptime ROOT = "base64"


def _commands() -> List[String]:
    """The commands the app answers."""
    return List[String]()


def main() raises:
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    var command = String(ROOT)
    if len(args) > 0 and args[0] in _commands():
        command = args[0]
    var code = units.dispatch(command, args)
    if code:
        exit(code.value())
    print(String(ROOT, ": no unit answers `", command, "`"), file=stderr)
    exit(2)
