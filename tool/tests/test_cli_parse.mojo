# clap's parsing and usage errors in Mojo, checked against every recorded case:
# each usage error the Phase 1 binary printed is printed byte for byte, and no
# other recorded command line is turned into a usage error.

from std.os import listdir
from std.testing import assert_equal, assert_false, assert_true

from mojo_anything.cli_args import ArgDef, args_of
from mojo_anything.cli_parse import (
    DECLINED,
    PARSED,
    USAGE_ERROR,
    jaro,
    parse,
    rust_float,
)
from mojo_anything.cli_spec import long_help
from mojo_anything.json import parse_json

comptime CASES = "mojo/app-cases/"


def _read(path: String) raises -> String:
    with open(path, "r") as f:
        return f.read()


def _args(toml: String) raises -> List[String]:
    var out = List[String]()
    for line in toml.splitlines():
        if line.startswith("args = "):
            var v = parse_json(String(line[byte=7:]))
            for item in v.array():
                out.append(item.string())
    return out^


def _status(toml: String) -> String:
    for line in toml.splitlines():
        if line.startswith("status.code = "):
            return String(line[byte=14:])
    return ""


def _is_usage_error(args: List[String], stderr: String) -> Bool:
    if len(args) == 0 or (len(args) == 1 and args[0] == "app"):
        return True
    return stderr.endswith("For more information, try '--help'.\n")


def _list(*items: String) -> List[String]:
    var out = List[String]()
    for s in items:
        out.append(s)
    return out^


def test_every_recorded_usage_error_matches() raises:
    var owned = 0
    var others = 0
    for name in listdir(CASES):
        if not name.endswith(".toml"):
            continue
        var base = CASES + String(name[byte = 0 : name.byte_length() - 5])
        var toml = _read(base + ".toml")
        var args = _args(toml)
        var stderr = _read(base + ".stderr")
        var r = parse(args)
        if _status(toml) == "2" and _is_usage_error(args, stderr):
            if r.kind != USAGE_ERROR:
                raise Error("not owned: " + base)
            assert_equal(r.stderr, stderr, base)
            owned += 1
        else:
            if r.kind == USAGE_ERROR:
                raise Error("a usage error clap did not give: " + base)
            others += 1
    print("  usage errors owned:", owned, "other cases:", others)
    # 46 of the 103 cases that exit 2 are clap's; the rest are the commands'
    # own errors.
    assert_equal(owned, 46)


def test_jaro_matches_strsim() raises:
    assert_equal(jaro("", ""), 1.0)
    assert_equal(jaro("a", ""), 0.0)
    # strsim's own examples.
    assert_true(
        abs(jaro("Friedrich Nietzsche", "Jean-Paul Sartre") - 0.392) < 1e-3
    )
    assert_true(abs(jaro("martha", "marhta") - 0.944) < 1e-3)
    assert_true(jaro("cobol", "c") > 0.7)


def test_rust_float_grammar() raises:
    for ok in ["1", "1.", ".5", "-1e5", "+2E-3", "inf", "-Infinity", "NaN"]:
        assert_true(rust_float(ok), ok)
    for bad in ["", "x", ".", "1e", "1e+", "0x10", "1_000", " 1"]:
        assert_false(rust_float(bad), bad)


def test_trailing_args_after_double_dash() raises:
    var r = parse(_list("app", "record", ".", "--", "python3", "cli.py", "--x"))
    assert_equal(r.kind, PARSED)
    assert_equal(r.parsed.path(), "app record")
    assert_equal(r.parsed.value("REPO").value(), ".")
    assert_equal(len(r.parsed.rest), 3)
    assert_equal(r.parsed.rest[2], "--x")


def test_values_flags_and_defaults() raises:
    var r = parse(_list("map", "--crates", "a", "--json", "--crates=b"))
    assert_equal(r.kind, PARSED)
    assert_true(r.parsed.flag("json"))
    assert_false(r.parsed.flag("write"))
    assert_equal(len(r.parsed.all("crates")), 2)
    assert_equal(r.parsed.all("crates")[1], "b")
    assert_equal(r.parsed.value("REPO").value(), ".")
    var s = parse(_list("setup", "--agent", "claude", "--agent", "codex"))
    assert_equal(s.kind, PARSED)
    assert_equal(len(s.parsed.all("agent")), 2)
    var f = parse(_list("fuzz", "--keep", "x"))
    assert_equal(f.kind, PARSED)
    assert_equal(f.parsed.value("keep").value(), "mismatches")
    assert_equal(f.parsed.value("CRATE_DIR").value(), "x")


def test_what_is_not_owned_is_declined() raises:
    # A repeated single option, conflicting flags, an extra positional, and a
    # suggestion clap would build from a subcommand's flags.
    assert_equal(parse(_list("map", "--write", "--write")).kind, DECLINED)
    assert_equal(
        parse(_list("record", "--pin-clock", "--no-pin-clock")).kind, DECLINED
    )
    assert_equal(parse(_list("doctor", "extra")).kind, DECLINED)
    assert_equal(parse(_list("--nope", "bench")).kind, DECLINED)
    assert_equal(parse(_list("analyze", ".", "--nope")).kind, DECLINED)
    # clap words these its own way: "a value is required" for an empty enum
    # value, a range message for a negative u16.
    assert_equal(parse(_list("setup", "--agent=")).kind, DECLINED)
    assert_equal(parse(_list("analyze", "--lang=")).kind, DECLINED)
    assert_equal(parse(_list("app", "replay", "--port=-1")).kind, DECLINED)
    assert_equal(parse(_list("app", "replay", "--port=x")).kind, USAGE_ERROR)


def _displays(path: String) -> List[String]:
    """The argument names in clap's long help for `path`, one per entry."""
    var out = List[String]()
    for line in long_help(path).splitlines():
        var s = String(line)
        var start: Int
        if s.startswith("      --"):
            start = 6
        elif s.startswith("  -") or s.startswith("  [") or s.startswith("  <"):
            start = 2
        else:
            continue
        var rest = String(s[byte=start:])
        var cut = rest.find("  ")
        if cut >= 0:
            var head = String(rest[byte=0:cut])
            rest = head^
        out.append(rest)
    return out^


def _help_display(d: ArgDef) -> String:
    if d.is_positional():
        var inner = d.value
        var out = "<" + inner + ">" if d.required else "[" + inner + "]"
        if d.multi or d.last:
            out += "..."
        return out
    var out = String("")
    if d.short != "":
        out = "-" + d.short + ", "
    return out + d.display()


def test_argument_table_matches_the_help() raises:
    var paths = _list(
        "analyze",
        "bridge",
        "refresh",
        "record",
        "build",
        "diff",
        "bench",
        "fuzz",
        "profile",
        "shadow",
        "gate",
        "package",
        "mcp",
        "setup",
        "map",
        "doctor",
        "app record",
        "app replay",
        "app front-door",
        "app wire",
        "app lift",
    )
    for path in paths:
        var defs = args_of(path).value().copy()
        var want = _displays(path)
        var got = List[String]()
        # The help lists positionals first, then options, then `-h`.
        for i in range(len(defs)):
            if defs[i].is_positional():
                got.append(_help_display(defs[i]))
        for i in range(len(defs)):
            if not defs[i].is_positional():
                got.append(_help_display(defs[i]))
        got.append("-h, --help")
        assert_equal(len(got), len(want), path)
        for i in range(len(got)):
            assert_equal(got[i], want[i], path)
        var text = long_help(path)
        for i in range(len(defs)):
            if defs[i].default != "":
                assert_true(
                    "[default: " + defs[i].default + "]" in text,
                    path + " " + defs[i].value,
                )
            for c in defs[i].choices:
                assert_true(
                    ", " + c in text or ": " + c in text or "- " + c in text,
                    path + " " + c,
                )


def main() raises:
    test_every_recorded_usage_error_matches()
    test_jaro_matches_strsim()
    test_rust_float_grammar()
    test_trailing_args_after_double_dash()
    test_values_flags_and_defaults()
    test_what_is_not_owned_is_declined()
    test_argument_table_matches_the_help()
    print("test_cli_parse: 7 passed")
