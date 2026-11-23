# The case files in `mojo/app-cases/` (schema `mojo-anything/app-cases@1`):
# `mojo-anything.json` (how to run the original, the normalizers) and one
# trycmd `<name>.toml` per case with its `.stdin`, `.stdout`, `.stderr`,
# `.effects` and `.removed` files and its `.in`/`.out` folders (port of the
# reading half of src/app.rs). Anything the Mojo tool cannot read exactly as
# the Rust tool does raises `DECLINE`, and the command goes to the Phase 1
# binary before anything is run or written.

from std.collections import Dict
from std.python import Python, PythonObject

from mojo_anything.app.py import py_len, py_strings

comptime CASES_DIR = "mojo/app-cases"
comptime CONFIG_FILE = "mojo-anything.json"
comptime REPORT_FILE = "replay-report.md"
comptime SCHEMA = "mojo-anything/app-cases@1"
comptime DECLINE = "mojo-anything: handed to the Phase 1 binary"
"""The text of the error that sends the whole command to the Phase 1 binary."""

comptime EXPECT_CODE = 0
comptime EXPECT_FAILED = 1
comptime EXPECT_KILLED = 2
comptime EXPECT_SKIP = 3


def decline() -> Error:
    return Error(DECLINE)


# --- shell words --------------------------------------------------------------


@fieldwise_init
struct Tok(Copyable, Movable):
    var text: String
    var op: Bool


def _chars(line: String) -> List[String]:
    var out = List[String]()
    for c in line.codepoint_slices():
        out.append(String(c))
    return out^


def shell_tokens(line: String) -> Optional[List[Tok]]:
    """Splits a command line as a POSIX shell would, keeping operators as their
    own tokens; None for a quote left open or a command substitution."""
    var toks = List[Tok]()
    var cur = String("")
    var in_tok = False
    var cs = _chars(line)
    var i = 0
    var n = len(cs)
    while i < n:
        var c = cs[i]
        i += 1
        if c == " " or c == "\t":
            if in_tok:
                toks.append(Tok(cur, False))
                cur = ""
                in_tok = False
        elif c == "'":
            in_tok = True
            while True:
                if i >= n:
                    return None
                var x = cs[i]
                i += 1
                if x == "'":
                    break
                cur += x
        elif c == '"':
            in_tok = True
            while True:
                if i >= n:
                    return None
                var x = cs[i]
                i += 1
                if x == '"':
                    break
                if x == "\\":
                    if i >= n:
                        return None
                    var y = cs[i]
                    i += 1
                    if y == '"' or y == "\\" or y == "$" or y == "`":
                        cur += y
                    else:
                        cur += "\\" + y
                elif x == "`":
                    return None
                elif x == "$" and i < n and cs[i] == "(":
                    return None
                else:
                    cur += x
        elif c == "\\":
            in_tok = True
            if i < n:
                cur += cs[i]
                i += 1
        elif c == "|" or c == "<" or c == ">" or c == ";" or c == "&":
            if in_tok:
                toks.append(Tok(cur, False))
                cur = ""
                in_tok = False
            var op = c
            while i < n and (
                cs[i] == "|" or cs[i] == "<" or cs[i] == ">" or cs[i] == "&"
            ):
                op += cs[i]
                i += 1
            toks.append(Tok(op, True))
        elif c == "#" and not in_tok:
            break
        elif c == "`":
            return None
        elif c == "$" and i < n and cs[i] == "(":
            return None
        else:
            in_tok = True
            cur += c
    if in_tok:
        toks.append(Tok(cur, False))
    return toks^


def shell_split(line: String) raises -> List[String]:
    """Words of a command line, shell-style quoting, no shell operators."""
    var toks = shell_tokens(line)
    if not toks:
        raise Error("cannot split `" + line + "`")
    var out = List[String]()
    for t in toks.value():
        if t.op:
            raise Error(
                "`"
                + line
                + "` uses the shell operator `"
                + t.text
                + "`: put the pipeline in a script and give its path"
            )
        out.append(t.text)
    return out^


def words_quotable(h: PythonObject, words: List[String]) raises -> Bool:
    """Whether `shell_quote` can decide every word as Rust's
    `char::is_alphanumeric` would."""
    for w in words:
        if Int(py=h["word_kind"](PythonObject(w))) < 0:
            return False
    return True


def shell_quote(h: PythonObject, word: String) raises -> String:
    if Int(py=h["word_kind"](PythonObject(word))) == 1:
        return word
    return "'" + word.replace("'", "'\\''") + "'"


def shell_join(h: PythonObject, words: List[String]) raises -> String:
    var out = String("")
    for i in range(len(words)):
        if i > 0:
            out += " "
        out += shell_quote(h, words[i])
    return out


# --- mojo-anything.json ---------------------------------------------------------


struct Config(Copyable, Movable):
    var name: String
    var run: List[String]
    var normalize: List[String]
    var normalizer_names: List[String]
    var normalizer_patterns: List[String]
    var timeout_secs: Int
    var http: Bool
    var float_tolerance: Optional[Float64]
    var float_files: Bool
    var unordered: Dict[String, List[String]]
    var effects: Bool
    var fresh: List[String]

    def __init__(out self):
        self.name = "app"
        self.run = List[String]()
        self.normalize = List[String]()
        self.normalizer_names = List[String]()
        self.normalizer_patterns = List[String]()
        self.timeout_secs = 30
        self.http = False
        self.float_tolerance = None
        self.float_files = False
        self.unordered = Dict[String, List[String]]()
        self.effects = False
        self.fresh = List[String]()


def load_config(h: PythonObject, repo: String) raises -> Optional[Config]:
    """`mojo/app-cases/mojo-anything.json`, or None when there is none.
    Declines a file serde_json would read otherwise or refuse."""
    var path = repo + "/" + CASES_DIR + "/" + CONFIG_FILE
    if not Bool(py=h["exists"](PythonObject(path))):
        return None
    var r = h["read_text"](PythonObject(path))
    if String(py=r[0]) != "ok":
        raise decline()
    var parsed = h["load_config"](r[1])
    if String(py=parsed[0]) != "ok":
        raise decline()
    var c = parsed[1]
    var out = Config()
    out.name = String(py=c["name"])
    out.run = py_strings(h["config_strs"](c, PythonObject("run")))
    out.normalize = py_strings(h["config_strs"](c, PythonObject("normalize")))
    out.fresh = py_strings(h["config_strs"](c, PythonObject("fresh")))
    var pairs = h["config_map"](c, PythonObject("normalizers"))
    for i in range(py_len(pairs)):
        out.normalizer_names.append(String(py=pairs[i][0]))
        out.normalizer_patterns.append(String(py=pairs[i][1]))
    var timeout = h["config_timeout"](c)
    if Bool(py=timeout > PythonObject(Int(Int64.MAX))):
        raise decline()
    out.timeout_secs = Int(py=timeout)
    out.http = Bool(py=h["config_present"](c, PythonObject("http")))
    out.effects = Bool(py=h["config_present"](c, PythonObject("effects")))
    out.float_files = (
        py_len(h["config_map"](c, PythonObject("float_files"))) > 0
    )
    var tol = h["config_tolerance"](c)
    if Bool(py=tol[0]):
        out.float_tolerance = Float64(py=tol[1])
    var unordered = h["config_unordered"](c)
    for i in range(py_len(unordered)):
        out.unordered[String(py=unordered[i][0])] = py_strings(unordered[i][1])
    return out^


# --- <name>.toml -------------------------------------------------------------------


struct Spec(Copyable, Movable):
    """One recorded case: how to run it and what it must give."""

    var name: String
    var args: List[String]
    var stdin: PythonObject
    """bytes, or None."""
    var env_keys: List[String]
    var env_values: List[String]
    var env_remove: List[String]
    var files: PythonObject
    """The `.in` folder (or `fs.base`): relative path to bytes, sorted."""
    var remove: List[String]
    var status: Int
    var code: Int
    var has_stdout: Bool
    var stdout: PythonObject
    var has_stderr: Bool
    var stderr: PythonObject
    var has_effects: Bool
    var effects: PythonObject
    var out_dir: String
    """The `.out` folder, or ""."""
    var has_removed: Bool
    var removed: List[String]
    var binary: Bool

    def __init__(out self, name: String) raises:
        self.name = name
        self.args = List[String]()
        self.stdin = PythonObject(None)
        self.env_keys = List[String]()
        self.env_values = List[String]()
        self.env_remove = List[String]()
        self.files = Python.dict()
        self.remove = List[String]()
        self.status = EXPECT_CODE
        self.code = 0
        self.has_stdout = False
        self.stdout = PythonObject(None)
        self.has_stderr = False
        self.stderr = PythonObject(None)
        self.has_effects = False
        self.effects = PythonObject(None)
        self.out_dir = ""
        self.has_removed = False
        self.removed = List[String]()
        self.binary = False


def _side(
    h: PythonObject, doc: PythonObject, dir: String, name: String, key: String
) raises -> Tuple[Bool, PythonObject]:
    """`key` given inline in the TOML, else `<name>.<key>` beside it."""
    var inline = h["spec_str"](doc, PythonObject(key))
    if Bool(py=inline[0]):
        return (True, h["utf8"](inline[1]))
    var file = dir + "/" + name + "." + key
    if not Bool(py=h["exists"](PythonObject(file))):
        return (False, PythonObject(None))
    var r = h["read_bytes"](PythonObject(file))
    if String(py=r[0]) != "ok":
        raise decline()
    return (True, r[1])


def load_spec(h: PythonObject, dir: String, file: String) raises -> Spec:
    var name = String(file[byte = 0 : file.byte_length() - 5])
    var path = dir + "/" + file
    var r = h["read_text"](PythonObject(path))
    if String(py=r[0]) != "ok":
        raise decline()
    var parsed = h["load_toml"](r[1])
    if String(py=parsed[0]) != "ok":
        raise decline()
    var doc = parsed[1]
    var spec = Spec(name)
    spec.stdin = h["utf8"](PythonObject(""))
    var args = h["spec_args"](doc)
    var kind = String(py=args[0])
    if kind == "list":
        spec.args = py_strings(args[1])
    elif kind == "str":
        spec.args = shell_split(String(py=args[1]))
    elif kind != "none":
        raise decline()
    var stdin = _side(h, doc, dir, name, "stdin")
    if stdin[0]:
        spec.stdin = stdin[1]
    var env = h["spec_env"](doc)
    if not Bool(py=env[0]):
        # `env.inherit = false`: the program would start from an empty
        # environment, where Rust's and Python's PATH lookups differ.
        raise decline()
    for i in range(py_len(env[1])):
        spec.env_keys.append(String(py=env[1][i][0]))
        spec.env_values.append(String(py=env[1][i][1]))
    spec.env_remove = py_strings(env[2])
    var fs = h["spec_fs"](doc)
    var base = dir + "/" + name + ".in"
    if Bool(py=fs[0]):
        var b = String(py=fs[1])
        base = b if b.startswith("/") else dir + "/" + b
    if Bool(py=h["is_dir"](PythonObject(base))):
        spec.files = h["read_files"](PythonObject(base))
    spec.remove = py_strings(fs[2])
    var status = h["spec_status"](doc)
    var s = String(py=status[0])
    if s == "code":
        spec.code = Int(py=status[1])
    elif s == "success":
        spec.code = 0
    elif s == "failed":
        spec.status = EXPECT_FAILED
    elif s == "interrupted":
        spec.status = EXPECT_KILLED
    elif s == "skipped":
        spec.status = EXPECT_SKIP
    else:
        raise Error(path + ": unknown `status`")
    var out = _side(h, doc, dir, name, "stdout")
    spec.has_stdout = out[0]
    spec.stdout = out[1]
    var err = _side(h, doc, dir, name, "stderr")
    spec.has_stderr = err[0]
    spec.stderr = err[1]
    var eff = _side(h, doc, dir, name, "effects")
    spec.has_effects = eff[0]
    spec.effects = eff[1]
    var out_dir = dir + "/" + name + ".out"
    if Bool(py=h["is_dir"](PythonObject(out_dir))):
        spec.out_dir = out_dir
    var removed = _side(h, doc, dir, name, "removed")
    if removed[0]:
        spec.has_removed = True
        spec.removed = py_strings(h["lossy_lines"](removed[1]))
    spec.binary = Bool(py=h["spec_bool"](doc, PythonObject("binary"), False))
    return spec^


def load_specs(h: PythonObject, dir: String) raises -> List[Spec]:
    var none = "no cases in " + dir + ": run `mojo-anything app record` first"
    var listed = h["toml_files"](PythonObject(dir))
    if String(py=listed[0]) != "ok":
        raise Error(none + ": " + String(py=listed[1]))
    var out = List[Spec]()
    var names = listed[1]
    for i in range(py_len(names)):
        out.append(load_spec(h, dir, String(py=names[i])))
    if len(out) == 0:
        raise Error(none)
    return out^
