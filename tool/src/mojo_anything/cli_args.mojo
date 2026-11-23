# The arguments of every subcommand, as src/main.rs declares them for clap:
# names, value names, value types, possible values, defaults, and whether an
# option repeats or takes values that start with `-`. Help text is not here
# (`cli_spec.mojo`); `tool/tests/test_cli.mojo` checks every option and
# argument below against the recorded help, so the two cannot drift apart.

comptime LANGS = "ts,python,c,go,ruby,java,kotlin,php,csharp,cpp"


@fieldwise_init
struct ArgDef(Copyable, Movable):
    var long: String
    """The long name without `--`; "" for a positional."""
    var short: String
    """The short letter, or ""."""
    var value: String
    """The value name (`OUT`, `CRATE_DIR`); "" for a flag."""
    var kind: String
    """`flag`, `string`, `usize`, `u64`, `u16`, `f64` or `enum`."""
    var choices: List[String]
    var multi: Bool
    """Repeatable (a `Vec` in main.rs)."""
    var hyphen: Bool
    """`allow_hyphen_values`: takes `--import=tsx` as its value."""
    var required: Bool
    var last: Bool
    """A positional that only takes the words after `--`."""
    var optional_value: Bool
    """`--keep[=<KEEP>]`: the value only with `=`, else `missing`."""
    var missing: String
    var default: String

    def is_positional(self) -> Bool:
        return self.long == ""

    def display(self) -> String:
        """How clap names the argument in its errors and usage lines."""
        if self.is_positional():
            if self.last or self.multi:
                return "<" + self.value + ">..."
            return "<" + self.value + ">"
        if self.value == "":
            return "--" + self.long
        if self.optional_value:
            return "--" + self.long + "[=<" + self.value + ">]"
        return "--" + self.long + " <" + self.value + ">"

    def usage(self) -> String:
        """A positional as the usage line shows it."""
        var dots = "..." if self.multi or self.last else ""
        if self.last:
            var inner = "-- <" + self.value + ">" + dots
            return inner if self.required else "[" + inner + "]"
        if self.required:
            return "<" + self.value + ">" + dots
        return "[" + self.value + "]" + dots


def _split(s: String) -> List[String]:
    var out = List[String]()
    if s == "":
        return out^
    for part in s.split(","):
        out.append(String(part))
    return out^


def flag(long: String) -> ArgDef:
    return ArgDef(
        long,
        "",
        "",
        "flag",
        List[String](),
        False,
        False,
        False,
        False,
        False,
        "",
        "",
    )


def opt(
    long: String,
    value: String,
    kind: String = "string",
    short: String = "",
    multi: Bool = False,
    hyphen: Bool = False,
    choices: String = "",
    default: String = "",
) -> ArgDef:
    return ArgDef(
        long,
        short,
        value,
        kind,
        _split(choices),
        multi,
        hyphen,
        False,
        False,
        False,
        "",
        default,
    )


def pos(
    value: String,
    required: Bool = False,
    default: String = "",
    last: Bool = False,
) -> ArgDef:
    return ArgDef(
        "",
        "",
        value,
        "string",
        List[String](),
        last,
        False,
        required,
        last,
        False,
        "",
        default,
    )


def _crate_dir() -> ArgDef:
    return pos("CRATE_DIR", default=".")


def _node_arg() -> ArgDef:
    return opt("node-arg", "NODE_ARGS", multi=True, hyphen=True)


def _profile() -> ArgDef:
    return opt("profile", "PROFILE", "enum", choices="host", default="host")


def _keep() -> ArgDef:
    var k = opt("keep", "KEEP", "enum", choices="mismatches,all")
    k.optional_value = True
    k.missing = "mismatches"
    return k^


def _timeout() -> ArgDef:
    return opt("timeout", "TIMEOUT", "u64")


def _port() -> ArgDef:
    return opt("port", "PORT", "u16")


def subcommands(path: String) -> List[String]:
    """The subcommands of `path` (with clap's `help`), or none for a leaf."""
    var out = List[String]()
    var names: String
    if path == "":
        names = (
            "analyze,bridge,refresh,record,build,diff,bench,fuzz,profile,"
            "shadow,gate,package,app,mcp,setup,map,doctor,help"
        )
    elif path == "app":
        names = "record,replay,front-door,wire,lift,help"
    else:
        return out^
    return _split(names)


def args_of(path: String) -> Optional[List[ArgDef]]:
    """The arguments of a leaf command in main.rs order, or None for a path
    that is not a leaf command."""
    var a = List[ArgDef]()
    if path == "analyze":
        a.append(pos("ROOT", default="."))
        a.append(flag("json"))
        a.append(opt("out", "OUT", short="o"))
        a.append(opt("lang", "LANG", "enum", choices=LANGS))
        a.append(flag("whole-app"))
    elif path == "bridge":
        a.append(pos("ROOT", required=True))
        a.append(pos("UNIT", required=True))
        a.append(opt("kind", "KIND", "enum", choices="node,wasm"))
        a.append(opt("out", "OUT", short="o"))
        a.append(opt("name", "NAME"))
        a.append(flag("force"))
        a.append(opt("keep", "KEEP", multi=True))
        a.append(opt("batch", "BATCH", multi=True))
        a.append(opt("as-json", "TYPE_PARAM", multi=True))
    elif path == "refresh":
        a.append(_crate_dir())
        a.append(opt("batch", "BATCH", multi=True))
    elif path == "record":
        a.append(_crate_dir())
        a.append(opt("count", "COUNT", "usize", default="200"))
        a.append(opt("inputs", "INPUTS"))
        a.append(opt("module", "MODULE"))
        a.append(opt("resolve-from", "RESOLVE_FROM"))
        a.append(_node_arg())
        a.append(opt("float-tolerance", "FLOAT_TOLERANCE", "f64"))
        a.append(flag("from-tests"))
        a.append(pos("TEST_COMMAND", last=True))
        a.append(_profile())
        a.append(flag("pin-clock"))
        a.append(flag("no-pin-clock"))
    elif path == "build":
        a.append(_crate_dir())
        a.append(_profile())
    elif path == "diff":
        a.append(_crate_dir())
        a.append(_profile())
        a.append(opt("module", "MODULE"))
        a.append(flag("ignore-key-order"))
        a.append(opt("float-tolerance", "FLOAT_TOLERANCE", "f64"))
        a.append(flag("json"))
        a.append(_node_arg())
    elif path == "bench":
        a.append(_crate_dir())
        a.append(opt("min-ms", "MIN_MS", "u64", default="200"))
        a.append(opt("resolve-from", "RESOLVE_FROM"))
        a.append(flag("json"))
        a.append(_node_arg())
    elif path == "fuzz":
        a.append(_crate_dir())
        a.append(opt("cases", "CASES", "usize", default="200"))
        a.append(opt("seed", "SEED", "u64"))
        a.append(opt("time", "SECS", "f64"))
        a.append(_keep())
        a.append(opt("resolve-from", "RESOLVE_FROM"))
        a.append(flag("json"))
        a.append(_node_arg())
    elif path == "profile":
        a.append(pos("ROOT", required=True))
        a.append(flag("json"))
        a.append(opt("lang", "LANG", "enum", choices=LANGS))
        var c = pos("COMMAND", last=True)
        c.required = True
        a.append(c^)
    elif path == "shadow":
        a.append(_crate_dir())
        a.append(opt("out", "OUT", short="o"))
    elif path == "gate":
        a.append(_crate_dir())
        a.append(flag("json"))
        a.append(_node_arg())
    elif path == "package":
        a.append(_crate_dir())
        a.append(opt("name", "NAME"))
        a.append(opt("version", "VERSION"))
        a.append(opt("out", "OUT"))
        a.append(flag("dry-run"))
        a.append(flag("json"))
    elif path == "mcp":
        pass
    elif path == "setup":
        a.append(
            opt(
                "agent",
                "AGENTS",
                "enum",
                multi=True,
                choices="claude,codex,cursor,gemini,opencode",
            )
        )
        a.append(flag("remove"))
        a.append(flag("dry-run"))
        a.append(flag("no-backup"))
        a.append(flag("json"))
    elif path == "map":
        a.append(pos("REPO", default="."))
        a.append(opt("crates", "CRATES", multi=True))
        a.append(flag("write"))
        a.append(flag("check"))
        a.append(flag("json"))
    elif path == "doctor":
        a.append(flag("json"))
    elif path == "app record":
        a.append(pos("REPO", default="."))
        a.append(opt("inputs", "INPUTS"))
        a.append(opt("normalize", "NORMALIZE", multi=True))
        a.append(opt("name", "NAME"))
        a.append(flag("no-traps"))
        a.append(_timeout())
        a.append(flag("http"))
        a.append(_port())
        a.append(opt("arg", "ARG", multi=True, hyphen=True))
        a.append(opt("fresh", "FRESH", multi=True))
        a.append(opt("pace", "MS", "u64"))
        a.append(opt("float-tolerance", "FLOAT_TOLERANCE", "f64"))
        a.append(opt("float-file", "PATH=FORMAT", multi=True))
        a.append(opt("effects", "KINDS", multi=True))
        a.append(opt("effect-env", "VAR=KIND", multi=True))
        a.append(opt("db-reset", "COMMAND"))
        a.append(opt("db-dump", "COMMAND"))
        a.append(flag("json"))
        a.append(pos("RUN", last=True))
    elif path == "app replay":
        a.append(pos("REPO", default="."))
        a.append(opt("build", "BUILD"))
        a.append(_timeout())
        a.append(_port())
        a.append(opt("case", "CASE"))
        a.append(flag("json"))
    elif path == "app front-door":
        a.append(pos("REPO", default="."))
        a.append(flag("no-check"))
        a.append(flag("library"))
        a.append(flag("json"))
    elif path == "app wire":
        a.append(pos("REPO", required=True))
        a.append(pos("UNIT", required=True))
        a.append(opt("command", "COMMANDS", multi=True))
        a.append(opt("route", "ROUTES", multi=True))
        a.append(flag("skip-gate"))
        a.append(flag("no-check"))
        a.append(flag("json"))
    elif path == "app lift":
        a.append(pos("REPO", default="."))
        a.append(flag("json"))
    else:
        return None
    return a^
