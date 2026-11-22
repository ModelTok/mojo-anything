# Glue for the unit `b64codec`: the command line of CPython's `base64.main()`
# (getopt with "hdeu", then one file or stdin) in front of the port.
#
# A failure the original reports with a Python traceback (a missing file, bad
# padding) ends here with the traceback's last line on stderr and exit 1: the
# rest of a traceback names where Python is installed, so no such case was
# recorded.

from std.os.path import exists
from std.sys import argv, stderr, stdout

from b64codec import port


def _usage() -> String:
    var program = String(argv()[0])
    return String(
        "usage: ",
        program,
        " [-h|-d|-e|-u] [file|-]\n",
        "        -h: print this help message and exit\n",
        "        -d, -u: decode\n",
        "        -e: encode (default)",
    )


def _write(data: List[UInt8]):
    var out = stdout
    out.write_bytes(Span(data))


def _read(path: String) raises -> List[UInt8]:
    return open(path, "r").read_bytes()


def base64(args: List[String]) raises -> Int:
    # getopt.getopt(args, "hdeu"): options until the first other argument or
    # `--`; `-` alone is an argument.
    var decode = False
    var help = False
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "--":
            i += 1
            break
        if not arg.startswith("-") or arg == "-":
            break
        if arg.startswith("--"):
            var end = arg.byte_length()
            var eq = arg.find("=")
            if eq >= 0:
                end = eq
            var name = String(arg[byte=2:end])
            print(String("option --", name, " not recognized"), file=stderr)
            print(_usage(), file=stderr)
            return 2
        for c in String(arg[byte=1:]).codepoint_slices():
            var o = String(c)
            if o == "d" or o == "u":
                decode = True
            elif o == "e":
                decode = False
            elif o == "h":
                help = True
            else:
                print(String("option -", o, " not recognized"), file=stderr)
                print(_usage(), file=stderr)
                return 2
        i += 1
    # The original runs the options in order and stops at `-h`; only the help
    # is printed then, whatever came before it.
    if help:
        print(_usage())
        return 0
    var data: List[UInt8]
    if i < len(args) and args[i] != "-":
        var path = args[i]
        if not exists(path):
            print(
                String(
                    "FileNotFoundError: [Errno 2] No such file or directory: '",
                    path,
                    "'",
                ),
                file=stderr,
            )
            return 1
        try:
            data = _read(path)
        except e:
            print(String("OSError: ", e), file=stderr)
            return 1
    else:
        data = open("/dev/stdin", "r").read_bytes()
    if not decode:
        _write(port.encode(data))
        return 0
    var out = List[UInt8]()
    try:
        port.decode(data, out)
    except e:
        _write(out)
        print(String("binascii.Error: ", e), file=stderr)
        return 1
    _write(out)
    return 0
