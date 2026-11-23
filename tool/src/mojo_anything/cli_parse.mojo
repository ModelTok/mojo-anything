# Parsing the command line the way the Phase 1 binary's clap 4 does, and
# clap's usage errors byte for byte (exit code 2). The parser owns only what
# it can answer exactly as clap would; anything else (a smart usage line built
# from several used arguments, a repeated single option, conflicting flags, an
# unknown positional) is declined, and main.mojo hands the command line to the
# Phase 1 binary.

from std.collections import Dict, Set

from mojo_anything.cli_args import ArgDef, args_of, subcommands
from mojo_anything.cli_spec import long_help, spec
from mojo_anything.cli import render_help

comptime PARSED = 0
comptime USAGE_ERROR = 1
comptime DECLINED = 2
comptime MORE_INFO = "For more information, try '--help'.\n"


struct Parsed(Copyable, Movable):
    """A command line clap accepts: the subcommand path, each option's values
    (by long name, positionals by value name, defaults filled in), the flags
    given, and the words after `--`."""

    var command: List[String]
    var values: Dict[String, List[String]]
    var flags: Set[String]
    var rest: List[String]

    def __init__(out self):
        self.command = List[String]()
        self.values = Dict[String, List[String]]()
        self.flags = Set[String]()
        self.rest = List[String]()

    def path(self) -> String:
        var out = String("")
        for i in range(len(self.command)):
            if i > 0:
                out += " "
            out += self.command[i]
        return out

    def flag(self, name: String) -> Bool:
        return name in self.flags

    def value(self, name: String) -> Optional[String]:
        """The last value of `name`, or None."""
        var v = self.values.get(name)
        if v and len(v.value()) > 0:
            return v.value()[len(v.value()) - 1]
        return None

    def all(self, name: String) -> List[String]:
        var v = self.values.get(name)
        if v:
            return v.value().copy()
        return List[String]()


struct Outcome(Copyable, Movable):
    """`PARSED` with `parsed`, `USAGE_ERROR` with clap's text for stderr, or
    `DECLINED`: the Phase 1 binary answers."""

    var kind: Int
    var parsed: Parsed
    var stderr: String

    def __init__(out self, kind: Int, var parsed: Parsed, stderr: String):
        self.kind = kind
        self.parsed = parsed^
        self.stderr = stderr


def _declined() -> Outcome:
    return Outcome(DECLINED, Parsed(), "")


def _error(text: String) -> Outcome:
    return Outcome(USAGE_ERROR, Parsed(), text)


def jaro(a: String, b: String) -> Float64:
    """strsim's `jaro`, which clap's suggestions use (on bytes: every name
    and value here is ASCII)."""
    var x = a.as_bytes()
    var y = b.as_bytes()
    var n = len(x)
    var m = len(y)
    if n == 0 and m == 0:
        return 1.0
    if n == 0 or m == 0:
        return 0.0
    var reach = max(n, m) // 2
    reach = reach - 1 if reach > 0 else 0
    var a_flags = List[Bool](length=n, fill=False)
    var b_flags = List[Bool](length=m, fill=False)
    var matches = 0
    for i in range(n):
        var lo = i - reach if i > reach else 0
        var hi = min(m, i + reach + 1)
        for j in range(lo, hi):
            if x[i] == y[j] and not b_flags[j]:
                a_flags[i] = True
                b_flags[j] = True
                matches += 1
                break
    if matches == 0:
        return 0.0
    var transpositions = 0
    var k = 0
    for i in range(n):
        if not a_flags[i]:
            continue
        while not b_flags[k]:
            k += 1
        if x[i] != y[k]:
            transpositions += 1
        k += 1
    transpositions //= 2
    var mf = Float64(matches)
    return (
        mf / Float64(n) + mf / Float64(m) + (mf - Float64(transpositions)) / mf
    ) / 3.0


def did_you_mean(v: String, candidates: List[String]) -> Optional[String]:
    """clap's pick: the most similar candidate above 0.7, the later one on a
    tie (a stable sort by confidence, then the last)."""
    var best: Optional[String] = None
    var score = 0.7
    for i in range(len(candidates)):
        var c = jaro(v, candidates[i])
        if c > 0.7 and c >= score:
            best = candidates[i]
            score = c
    return best


def usage_line(path: String) -> String:
    """`mojo-anything <path> ...` from the help clap printed for `path`."""
    var text = long_help(path)
    var at = text.find("\nUsage: ")
    if at < 0:
        return ""
    var start = at + 8  # "\nUsage: "
    var end = text.find("\n", start)
    return String(text[byte=start:end])


def _longs(defs: List[ArgDef]) -> List[String]:
    """The long names clap's keymap holds, in order, with its own `help`."""
    var out = List[String]()
    for i in range(len(defs)):
        if not defs[i].is_positional():
            out.append(defs[i].long)
    out.append("help")
    return out^


def _has_positionals(defs: List[ArgDef]) -> Bool:
    for i in range(len(defs)):
        if defs[i].is_positional():
            return True
    return False


def _has_last(defs: List[ArgDef]) -> Bool:
    for i in range(len(defs)):
        if defs[i].is_positional() and defs[i].last:
            return True
    return False


def _unknown(
    arg: String, tip: Optional[String], trailing_tip: Bool, usage: String
) -> String:
    var out = String("error: unexpected argument '") + arg + "' found\n\n"
    var tips = False
    if tip:
        out += "  tip: a similar argument exists: '" + tip.value() + "'\n"
        tips = True
    if trailing_tip:
        out += "  tip: to pass '" + arg + "' as a value, use '-- " + arg + "'\n"
        tips = True
    if tips:
        out += "\n"
    return out + "Usage: " + usage + "\n\n" + MORE_INFO


def _is_digit(b: UInt8) -> Bool:
    return b >= 48 and b <= 57


def rust_float(s: String) -> Bool:
    """Whether Rust's `str::parse::<f64>` accepts `s`."""
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    if i < n and (b[i] == 43 or b[i] == 45):
        i += 1
    var word = String(s[byte=i:]).lower()
    if word == "inf" or word == "infinity" or word == "nan":
        return True
    var digits = 0
    while i < n and _is_digit(b[i]):
        i += 1
        digits += 1
    if i < n and b[i] == 46:
        i += 1
        while i < n and _is_digit(b[i]):
            i += 1
            digits += 1
    if digits == 0:
        return False
    if i < n and (b[i] == 101 or b[i] == 69):
        i += 1
        if i < n and (b[i] == 43 or b[i] == 45):
            i += 1
        var e = 0
        while i < n and _is_digit(b[i]):
            i += 1
            e += 1
        if e == 0:
            return False
    return i == n


comptime _VALID = 0
comptime _INVALID = 1
comptime _UNSURE = 2


def _check(value: String, d: ArgDef, mut text: String) -> Int:
    """Whether `d` accepts `value`; on `_INVALID`, `text` is clap's error.
    `_UNSURE`: clap words the error in a way not owned here (an empty number,
    one too large for its type)."""
    var head = (
        String("error: invalid value '") + value + "' for '" + d.display() + "'"
    )
    if d.kind == "enum":
        if value == "":
            # clap says "a value is required" for an empty enum value.
            return _UNSURE
        for i in range(len(d.choices)):
            if d.choices[i] == value:
                return _VALID
        text = head + "\n  [possible values: "
        for i in range(len(d.choices)):
            if i > 0:
                text += ", "
            text += d.choices[i]
        text += "]\n\n"
        var tip = did_you_mean(value, d.choices)
        if tip:
            text += "  tip: a similar value exists: '" + tip.value() + "'\n\n"
        text += MORE_INFO
        return _INVALID
    if d.kind == "usize" or d.kind == "u64" or d.kind == "u16":
        var bytes = value.as_bytes()
        if d.kind == "u16" and len(bytes) > 0 and bytes[0] == 45:
            # clap reads a u16 as an i64 in a range: `-1 is not in 0..=65535`.
            return _UNSURE
        var start = 1 if len(bytes) > 0 and bytes[0] == 43 else 0
        if start == len(bytes):
            return _UNSURE
        for i in range(start, len(bytes)):
            if not _is_digit(bytes[i]):
                text = head + ": invalid digit found in string\n\n" + MORE_INFO
                return _INVALID
        var digits = len(bytes) - start
        if digits > 19 or (d.kind == "u16" and digits > 18):
            return _UNSURE
        if d.kind == "u16":
            # An i64 in 0..=65535; clap's text for one beyond is not built.
            var n = 0
            for i in range(start, len(bytes)):
                n = n * 10 + Int(bytes[i]) - 48
            if n > 65535:
                return _UNSURE
        return _VALID
    if d.kind == "f64":
        if rust_float(value):
            return _VALID
        if value == "":
            return _UNSURE
        text = head + ": invalid float literal\n\n" + MORE_INFO
        return _INVALID
    return _VALID


def _find_long(defs: List[ArgDef], name: String) -> Int:
    for i in range(len(defs)):
        if not defs[i].is_positional() and defs[i].long == name:
            return i
    return -1


def _find_short(defs: List[ArgDef], c: String) -> Int:
    for i in range(len(defs)):
        if defs[i].short != "" and defs[i].short == c:
            return i
    return -1


def _parent(path: String, args: List[String], start: Int) -> Outcome:
    """A command with subcommands (`mojo-anything`, `mojo-anything app`)."""
    var subs = subcommands(path)
    var usage = usage_line(path)
    if start == len(args):
        # clap prints the short help to stderr when the subcommand is missing.
        var all = spec()
        for i in range(len(all)):
            if all[i].path == path:
                return _error(render_help(all[i]))
        return _declined()
    var a = args[start]
    if a.startswith("--") and a != "--":
        if "=" in a:
            return _declined()
        var name = String(a[byte=2:])
        var longs = List[String]()
        longs.append("help")
        if path == "":
            longs.append("version")
        if did_you_mean(name, longs):
            return _declined()
        # clap also suggests a subcommand's flag, when that subcommand is
        # named later on the command line: not owned.
        for i in range(start + 1, len(args)):
            if args[i] in subs:
                return _declined()
        return _error(_unknown(a, None, False, usage))
    if a.startswith("-"):
        return _declined()
    if a in subs:
        if a == "help":
            return _declined()
        var sub = a if path == "" else path + " " + a
        if a == "app":
            return _parent(sub, args, start + 1)
        return _leaf(sub, args, start + 1)
    if did_you_mean(a, subs):
        return _declined()
    return _error(
        String("error: unrecognized subcommand '")
        + a
        + "'\n\nUsage: "
        + usage
        + "\n\n"
        + MORE_INFO
    )


def _add(mut p: Parsed, name: String, value: String):
    var v = p.values.get(name)
    var list = v.value().copy() if v else List[String]()
    list.append(value)
    p.values[name] = list^


def _positional_usage(path: String, defs: List[ArgDef], lead: String) -> String:
    var usage = "mojo-anything " + path + lead
    for j in range(len(defs)):
        if defs[j].is_positional():
            usage += " " + defs[j].usage()
    return usage


def _leaf(path: String, args: List[String], start: Int) -> Outcome:
    var found = args_of(path)
    if not found:
        return _declined()
    var defs = found.value().copy()
    var p = Parsed()
    for w in path.split(" "):
        p.command.append(String(w))
    var matched = False
    var options_used = False
    var next_pos = 0
    var seen = Set[String]()
    var trailing = False
    var i = start
    var n = len(args)
    while i < n:
        var a = args[i]
        if trailing:
            p.rest.append(a)
            i += 1
            continue
        if a == "--":
            if not _has_last(defs):
                return _declined()
            trailing = True
            i += 1
            continue
        if a == "-h" or a == "--help":
            return _declined()
        if a.startswith("--"):
            var eq = a.find("=")
            var name = String(a[byte=2:]) if eq < 0 else String(a[byte=2:eq])
            var k = _find_long(defs, name)
            if k < 0:
                if eq >= 0 or matched:
                    return _declined()
                var tip = did_you_mean(name, _longs(defs))
                var tip_text: Optional[String] = None
                var usage = usage_line(path)
                if tip:
                    var t = _find_long(defs, tip.value())
                    if t < 0 or defs[t].short != "":
                        # `--help`, or an argument with a short form: the
                        # usage line clap builds for it is not owned.
                        return _declined()
                    tip_text = "--" + tip.value()
                    usage = _positional_usage(
                        path, defs, " " + defs[t].display()
                    )
                var trailing_tip = (
                    not tip or _has_last(defs)
                ) and _has_positionals(defs)
                return _error(_unknown(a, tip_text, trailing_tip, usage))
            var d = defs[k].copy()
            if d.long in seen and not d.multi:
                return _declined()
            seen.add(d.long)
            if "pin-clock" in seen and "no-pin-clock" in seen:
                return _declined()
            matched = True
            options_used = True
            if d.kind == "flag":
                if eq >= 0:
                    return _declined()
                p.flags.add(d.long)
                i += 1
                continue
            var value: String
            if eq >= 0:
                value = String(a[byte = eq + 1 :])
                i += 1
            elif d.optional_value:
                value = d.missing
                i += 1
            elif i + 1 < n:
                var nxt = args[i + 1]
                if nxt.startswith("-") and nxt != "-" and not d.hyphen:
                    if nxt.startswith("--") or nxt.byte_length() < 2:
                        return _declined()
                    # clap reads it as a new argument: an unknown short is
                    # reported as such, anything else is not owned.
                    var c = String(nxt[byte=1:2])
                    if _find_short(defs, c) >= 0 or c == "h":
                        return _declined()
                    return _error(
                        _unknown(
                            "-" + c,
                            None,
                            _has_positionals(defs),
                            usage_line(path),
                        )
                    )
                value = nxt
                i += 2
            else:
                if d.kind == "enum":
                    return _declined()
                return _error(
                    String("error: a value is required for '")
                    + d.display()
                    + "' but none was supplied\n\n"
                    + MORE_INFO
                )
            var text = String("")
            var verdict = _check(value, d, text)
            if verdict == _UNSURE:
                return _declined()
            if verdict == _INVALID:
                return _error(text)
            _add(p, d.long, value)
            continue
        if a.startswith("-") and a != "-":
            var c = String(a[byte=1:2])
            var k = _find_short(defs, c)
            if k < 0:
                if c == "h":
                    return _declined()
                return _error(
                    _unknown(
                        "-" + c, None, _has_positionals(defs), usage_line(path)
                    )
                )
            var d = defs[k].copy()
            if d.long in seen and not d.multi:
                return _declined()
            seen.add(d.long)
            matched = True
            options_used = True
            var value: String
            if a.byte_length() > 2:
                value = String(a[byte=2:])
                if value.startswith("="):
                    var bare = String(value[byte=1:])
                    value = bare^
                i += 1
            elif i + 1 < n and not args[i + 1].startswith("-"):
                value = args[i + 1]
                i += 2
            else:
                return _declined()
            var text = String("")
            if _check(value, d, text) != _VALID:
                return _declined()
            _add(p, d.long, value)
            continue
        # A positional.
        var placed = False
        while next_pos < len(defs):
            if defs[next_pos].is_positional() and not defs[next_pos].last:
                _add(p, defs[next_pos].value, a)
                if not defs[next_pos].multi:
                    next_pos += 1
                placed = True
                break
            next_pos += 1
        if not placed:
            return _declined()
        matched = True
        i += 1
    # Required arguments that are missing.
    var missing = List[String]()
    for j in range(len(defs)):
        if not defs[j].is_positional() or not defs[j].required:
            continue
        if defs[j].last:
            if len(p.rest) == 0:
                missing.append(defs[j].display())
        elif defs[j].value not in p.values:
            missing.append(defs[j].display())
    if len(missing) > 0:
        if options_used or trailing:
            return _declined()
        var out = String(
            "error: the following required arguments were not provided:\n"
        )
        for j in range(len(missing)):
            out += "  " + missing[j] + "\n"
        return _error(
            out
            + "\nUsage: "
            + _positional_usage(path, defs, "")
            + "\n\n"
            + MORE_INFO
        )
    # Defaults.
    for j in range(len(defs)):
        var key = defs[j].value if defs[j].is_positional() else defs[j].long
        if defs[j].default != "" and key not in p.values:
            _add(p, key, defs[j].default)
    return Outcome(PARSED, p^, "")


def parse(args: List[String]) -> Outcome:
    """`args` without the program name."""
    return _parent("", args, 0)
