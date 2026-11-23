# The shape of the command-line spec (`cli_spec.mojo`, generated).


@fieldwise_init
struct Entry(Copyable, Movable):
    """One help line: what clap shows on the left (`-o, --out <OUT>`) and
    the help text on the right."""

    var display: String
    var help: String
    var below: Bool
    """The help goes on the next line, indented ten spaces (clap does this for
    a whole section whose help does not fit beside its longest entry)."""


struct CommandSpec(Copyable, Movable):
    """One (sub)command: its path (`""`, `app`, `app record`), the about text,
    the usage line, the three help sections and the text after them."""

    var path: String
    var about: String
    var usage: String
    var after_help: String
    var long_same: Bool
    """`--help` prints the same text as `-h`."""
    var commands: List[Entry]
    var arguments: List[Entry]
    var options: List[Entry]

    def __init__(
        out self,
        path: String,
        about: String,
        usage: String,
        after_help: String,
        long_same: Bool,
    ):
        self.path = path
        self.about = about
        self.usage = usage
        self.after_help = after_help
        self.long_same = long_same
        self.commands = List[Entry]()
        self.arguments = List[Entry]()
        self.options = List[Entry]()
