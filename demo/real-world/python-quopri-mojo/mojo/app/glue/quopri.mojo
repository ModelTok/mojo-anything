# Glue for the unit `quopri`: the command line of CPython's `quopri.main()`
# (getopt with "td", then each file, or stdin for `-` and for none) in front of
# the port. `main()` calls `encode` and `decode`, which read the whole input and
# hand it to binascii, so each input is one `encodestring` or `decodestring`.

from std.os.path import exists, isdir
from std.sys import stderr, stdout

from quopri import port


def _usage_error(message: String) -> Int:
    # main() points sys.stdout at sys.stderr, prints the getopt error and the
    # usage, and exits with 2.
    print(message, file=stderr)
    print("usage: quopri [-t | -d] [file] ...", file=stderr)
    print("-t: quote tabs", file=stderr)
    print("-d: decode; default encode", file=stderr)
    return 2


def _hex(value: Int, width: Int) -> String:
    var digits = String("0123456789abcdef")
    var out = String()
    for shift in range(width - 1, -1, -1):
        var d = (value >> (shift * 4)) & 15
        out += String(digits[byte = d : d + 1])
    return out


def _unprintable(cp: Int) -> Bool:
    """The code points Python's `repr` escapes: controls, and the separators and
    format characters found in file names (a zero-width joiner in an emoji)."""
    return (
        cp < 32
        or (cp >= 127 and cp <= 160)
        or cp == 173
        or (cp >= 0x200B and cp <= 0x200F)
        or (cp >= 0x2028 and cp <= 0x202F)
        or (cp >= 0x2060 and cp <= 0x2064)
        or cp == 0xFEFF
    )


def _repr(text: String) -> String:
    """`repr()` of a str, as an OSError message names its file."""
    var quote = String("'")
    if "'" in text and not ('"' in text):
        quote = '"'
    var out = quote
    for c in text.codepoints():
        var cp = Int(c.to_u32())
        var s = String(c)
        if s == "\\":
            out += "\\\\"
        elif s == quote:
            out += "\\" + quote
        elif s == "\n":
            out += "\\n"
        elif s == "\r":
            out += "\\r"
        elif s == "\t":
            out += "\\t"
        elif _unprintable(cp):
            if cp < 0x100:
                out += "\\x" + _hex(cp, 2)
            elif cp < 0x10000:
                out += "\\u" + _hex(cp, 4)
            else:
                out += "\\U" + _hex(cp, 8)
        else:
            out += s
    return out + quote


def _write(data: List[UInt8]):
    var out = stdout
    out.write_bytes(Span(data))


def quopri(args: List[String]) raises -> Int:
    # getopt.getopt(args, "td"): options until the first other argument or
    # `--`; `-` alone is an argument, and an unknown option ends the run.
    var tabs = False
    var deco = False
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
            return _usage_error(
                String("option --", String(arg[byte=2:end]), " not recognized")
            )
        for c in String(arg[byte=1:]).codepoint_slices():
            var o = String(c)
            if o == "t":
                tabs = True
            elif o == "d":
                deco = True
            else:
                return _usage_error(String("option -", o, " not recognized"))
        i += 1
    if tabs and deco:
        print("-t and -d are mutually exclusive", file=stderr)
        return 2
    var files = List[String]()
    for j in range(i, len(args)):
        files.append(args[j])
    if len(files) == 0:
        files.append("-")
    var status = 0
    # sys.stdin.buffer is read to its end once; a second `-` reads nothing.
    var stdin_read = False
    for file in files:
        var data: List[UInt8]
        if file == "-":
            if stdin_read:
                data = List[UInt8]()
            else:
                data = open("/dev/stdin", "r").read_bytes()
                stdin_read = True
        else:
            var why: String
            if not exists(file):
                why = "[Errno 2] No such file or directory: "
            elif isdir(file):
                why = "[Errno 21] Is a directory: "
            else:
                why = ""
            if why:
                print(
                    String(file, ": can't open (", why, _repr(file), ")"),
                    file=stderr,
                )
                status = 1
                continue
            try:
                data = open(file, "r").read_bytes()
            except e:
                print(String(file, ": can't open (", e, ")"), file=stderr)
                status = 1
                continue
        if deco:
            _write(port.decodestring(data, False))
        else:
            _write(port.encodestring(data, tabs, False))
    return status
