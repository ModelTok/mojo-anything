# `mojo-anything app record` (port of `record` in src/app.rs and its caller
# in src/main.rs) for CLIs: the checks before anything runs, the cases (the
# app's names, the shell lines in its docs, `--inputs`, semantic traps), two
# runs of the original per case, the noise between them, and the trycmd files
# in toml_edit's layout with mojo-anything.json in serde_json's. Servers,
# effects, float files, a tolerance and `key-order`, and
# anything whose bytes this port cannot be sure to write as the Rust tool
# does, go to the Phase 1 binary before anything is written.

from std.collections import Set
from std.python import Python, PythonObject

from mojo_anything.app.cases import (
    CASES_DIR,
    CONFIG_FILE,
    DECLINE,
    SCHEMA,
    Config,
    Tok,
    decline,
    join,
    load_config,
    shell_tokens,
)
from mojo_anything.app.diff import Normalizers, diff_ops, _EQUAL, _DELETE
from mojo_anything.app.py import py_helpers, py_len, py_list, py_strings
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback
from mojo_anything.json_text import write_string
from mojo_anything.walk import walk

comptime MAX_TRAPS = 300
comptime FRESH_DIR = "files"
"""The snapshot of the `fresh` paths, in mojo/app-cases."""
comptime _MAX_TIMEOUT = 2_000_000
"""Seconds: Python's `communicate` waits in `poll`, whose milliseconds stop at
INT_MAX; a longer limit goes to the Phase 1 binary."""
comptime _I128_MAX = "170141183460469231731687303715884105727"
comptime _I128_MIN = "170141183460469231731687303715884105728"

comptime NOISE_NONE = -1
comptime NOISE_VALUES = 0
comptime NOISE_ORDER = 1
comptime NOISE_LINES = 2


def _split_once(s: String, sep: String) -> Optional[Tuple[String, String]]:
    var at = s.find(sep)
    if at < 0:
        return None
    return (
        String(s[byte=0:at]),
        String(s[byte = at + sep.byte_length() :]),
    )


def _rsplit_once(s: String, sep: String) -> Optional[Tuple[String, String]]:
    var at = s.rfind(sep)
    if at < 0:
        return None
    return (
        String(s[byte=0:at]),
        String(s[byte = at + sep.byte_length() :]),
    )


def _float_width(format: String) raises:
    if format != "f32le" and format != "f64le":
        raise Error("float file format `" + format + "`: use f32le or f64le")


def _same_list(a: List[String], b: List[String]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


# --- text as Rust's str reads it ------------------------------------------------


def _ws_len(b: Span[UInt8, _], i: Int) -> Int:
    """The length of the White_Space character (`char::is_whitespace`) that
    starts at byte `i`, or 0."""
    var n = len(b)
    var c = Int(b[i])
    if c == 9 or c == 10 or c == 11 or c == 12 or c == 13 or c == 32:
        return 1
    if c == 0xC2 and i + 1 < n:
        var c1 = Int(b[i + 1])
        if c1 == 0x85 or c1 == 0xA0:
            return 2
    if i + 2 < n:
        var c1 = Int(b[i + 1])
        var c2 = Int(b[i + 2])
        if c == 0xE1 and c1 == 0x9A and c2 == 0x80:
            return 3
        if c == 0xE2 and c1 == 0x80:
            if (c2 >= 0x80 and c2 <= 0x8A) or c2 == 0xA8 or c2 == 0xA9:
                return 3
            if c2 == 0xAF:
                return 3
        if c == 0xE2 and c1 == 0x81 and c2 == 0x9F:
            return 3
        if c == 0xE3 and c1 == 0x80 and c2 == 0x80:
            return 3
    return 0


def _char_len(c: UInt8) -> Int:
    if c < 0x80:
        return 1
    if c < 0xE0:
        return 2
    if c < 0xF0:
        return 3
    return 4


def _trim(s: String) -> String:
    """`str::trim`."""
    var b = s.as_bytes()
    var n = len(b)
    var i = 0
    var start = -1
    var end = 0
    while i < n:
        var w = _ws_len(b, i)
        if w > 0:
            i += w
            continue
        if start < 0:
            start = i
        i += _char_len(b[i])
        end = i
    if start < 0:
        return ""
    return String(s[byte=start:end])


def _first_word(s: String) -> String:
    """`split_whitespace().next()`, or ""."""
    var t = _trim(s)
    var b = t.as_bytes()
    var i = 0
    while i < len(b):
        if _ws_len(b, i) > 0:
            return String(t[byte=0:i])
        i += _char_len(b[i])
    return t


def _lines(text: String) -> List[String]:
    """`str::lines`: split at `\\n`, a `\\r` before it dropped, no line after
    a final `\\n`."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == 10:
            var e = i
            if e > start and b[e - 1] == 13:
                e -= 1
            out.append(String(text[byte=start:e]))
            start = i + 1
    if start < len(b):
        out.append(String(text[byte=start:]))
    return out^


def _split_lf(text: String) -> List[String]:
    """`split('\\n')`."""
    var out = List[String]()
    var b = text.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == 10:
            out.append(String(text[byte=start:i]))
            start = i + 1
    out.append(String(text[byte=start:]))
    return out^


def _split_slash(s: String) -> List[String]:
    var out = List[String]()
    var b = s.as_bytes()
    var start = 0
    for i in range(len(b)):
        if b[i] == 47:
            out.append(String(s[byte=start:i]))
            start = i + 1
    out.append(String(s[byte=start:]))
    return out^


def _is_ascii(s: String) -> Bool:
    for b in s.as_bytes():
        if b >= 128:
            return False
    return True


def _ascii_lower(s: String) -> String:
    """ASCII letters lowered, every other byte kept (UTF-8 stays UTF-8)."""
    var b = s.as_bytes()
    var out = String("")
    var start = 0
    for i in range(len(b)):
        if b[i] >= 65 and b[i] <= 90:
            out += String(s[byte=start:i]) + chr(Int(b[i]) + 32)
            start = i + 1
    out += String(s[byte=start:])
    return out


# --- paths as Rust's Path reads them ---------------------------------------------


def _components(p: String) -> List[String]:
    """`Path::components`: `/` for the root, `.` only first, empty parts and
    later `.` dropped."""
    var out = List[String]()
    var segs = _split_slash(p)
    if p.startswith("/"):
        out.append("/")
    for k in range(len(segs)):
        if segs[k] == "":
            continue
        if segs[k] == ".":
            if k == 0:
                out.append(".")
            continue
        out.append(segs[k])
    return out^


def _same_path(a: String, b: String) -> Bool:
    return _same_list(_components(a), _components(b))


def _file_name(p: String) -> String:
    """`Path::file_name`, or "" for None."""
    var c = _components(p)
    if len(c) == 0:
        return ""
    var last = c[len(c) - 1]
    if last == "/" or last == "." or last == "..":
        return ""
    return last


def _rust_stem(word: String) -> String:
    """`Path::file_stem`, or ""."""
    var name = _file_name(word)
    var at = name.rfind(".")
    if at <= 0:
        return name
    return String(name[byte=0:at])


def _extension_lower(path: String) -> String:
    var name = _file_name(path)
    var at = name.rfind(".")
    if at <= 0:
        return ""
    return _ascii_lower(String(name[byte = at + 1 :]))


def _safe_relative(arg: String) -> Bool:
    """app.rs `safe_relative`: every component `Normal`."""
    if arg == "" or arg.startswith("-") or arg.startswith("/"):
        return False
    var segs = _split_slash(arg)
    for k in range(len(segs)):
        if segs[k] == "..":
            return False
        if segs[k] == "." and k == 0:
            return False
    return True


def _non_normal(arg: String) -> Bool:
    """A relative path a PathBuf key compares equal to another spelling of
    (`a//b`, `a/./b`, `a/`): declined, as the map would keep the key inserted
    first."""
    return (
        arg.find("//") >= 0
        or arg.find("/./") >= 0
        or arg.endswith("/")
        or arg.endswith("/.")
    )


def _pjoin(base: String, rel: String) -> String:
    """`Path::join`: an absolute `rel` replaces the base."""
    if rel.startswith("/"):
        return rel
    return join(base, rel)


def _parent(path: String) -> String:
    var at = path.rfind("/")
    if at <= 0:
        return "/"
    return String(path[byte=0:at])


# --- cases --------------------------------------------------------------------------


struct Case(Copyable, Movable):
    var args: List[String]
    var stdin: PythonObject
    """bytes, or None."""
    var env_keys: List[String]
    """Sorted, as a BTreeMap."""
    var env_values: List[String]
    var files: PythonObject
    """Relative path to bytes, in path order."""
    var file_names: List[String]
    var remove: List[String]

    def __init__(out self, var args: List[String]) raises:
        self.args = args^
        self.stdin = PythonObject(None)
        self.env_keys = List[String]()
        self.env_values = List[String]()
        self.files = Python.dict()
        self.file_names = List[String]()
        self.remove = List[String]()

    def set_env(mut self, key: String, value: String):
        for i in range(len(self.env_keys)):
            if self.env_keys[i] == key:
                self.env_values[i] = value
                return
        var at = 0
        while at < len(self.env_keys) and self.env_keys[at] < key:
            at += 1
        self.env_keys.insert(at, key)
        self.env_values.insert(at, value)

    def env_pairs(self) raises -> PythonObject:
        var out = Python.list()
        for i in range(len(self.env_keys)):
            var pair = Python.list()
            pair.append(PythonObject(self.env_keys[i]))
            pair.append(PythonObject(self.env_values[i]))
            out.append(pair)
        return out

    def add_file(
        mut self, h: PythonObject, path: String, data: PythonObject
    ) raises:
        # A fresh dict: copies of a case share the one they were made from.
        var files = h["sorted_files"](self.files)
        _ = h["put"](files, PythonObject(path), data)
        self.files = h["sorted_files"](files)
        self.file_names = py_strings(h["file_names"](self.files))

    def key(self, h: PythonObject) raises -> String:
        return String(
            py=h["case_key"](
                py_list(self.args),
                self.stdin,
                self.env_pairs(),
                self.files,
                py_list(self.remove),
            )
        )


def _not_app_names() -> List[String]:
    return [
        "node",
        "nodejs",
        "python",
        "python3",
        "py",
        "ruby",
        "java",
        "go",
        "deno",
        "bun",
        "tsx",
        "ts-node",
        "sh",
        "bash",
        "zsh",
        "cargo",
        "npx",
        "npm",
        "pnpm",
        "yarn",
        "uv",
        "poetry",
        "bundle",
        "run",
        "exec",
        "env",
        "sudo",
        "php",
        "dotnet",
    ]


def _add_name(mut names: List[String], name: String) raises:
    var n = name
    var at = n.rfind("/")
    if at >= 0:
        var tail = String(n[byte = at + 1 :])
        n = tail
    # Rust lowers with Unicode's tables; a name outside ASCII is declined.
    if not _is_ascii(n):
        raise decline()
    n = _ascii_lower(n)
    if n != "" and not (n in _not_app_names()) and not (n in names):
        names.append(n)


def _name_stem(word: String) raises -> String:
    var s = _rust_stem(word)
    if not _is_ascii(s):
        raise decline()
    return _ascii_lower(s)


def app_names(
    h: PythonObject,
    repo: String,
    run: List[String],
    explicit: Optional[String],
) raises -> List[String]:
    """Names the app is invoked by, most specific first."""
    var names = List[String]()
    if explicit:
        _add_name(names, explicit.value())
    for word in run:
        if word.startswith("-"):
            continue
        if Bool(py=h["is_dir"](PythonObject(_pjoin(repo, word)))):
            continue
        if Bool(py=h["is_dir"](PythonObject(word))):
            continue
        _add_name(names, _name_stem(word))
    var manifests: List[String] = ["package_names", "pyproject_names"]
    for kind in manifests:
        var r = h[PythonObject(kind)](PythonObject(repo))
        if String(py=r[0]) != "ok":
            raise decline()
        for n in py_strings(r[1]):
            _add_name(names, n)
    var dirs: List[String] = ["cmd", "bin", "exe"]
    for d in dirs:
        var entries = py_strings(
            h["dir_entries"](
                PythonObject(join(repo, d)), PythonObject(d == "cmd")
            )
        )
        var found = List[String]()
        for e in entries:
            found.append(_name_stem(e))
        for n in py_strings(h["sorted_strs"](py_list(found))):
            _add_name(names, n)
    return names^


def _prog_matches(prog: String, names: List[String]) raises -> Bool:
    """`names.contains(&stem(prog))` with every name ASCII: a stem outside
    ASCII lowers to ASCII only through the Kelvin sign, which is declined."""
    var s = _rust_stem(prog)
    if not _is_ascii(s):
        if s.find(chr(0x212A)) >= 0:
            raise decline()
        return False
    return _ascii_lower(s) in names


def _is_none(h: PythonObject, x: PythonObject) raises -> Bool:
    return Bool(py=h["is_none"](x))


def _lookup(
    h: PythonObject, arg: String, repo: String, doc_dir: String
) raises -> PythonObject:
    if not _safe_relative(arg):
        return PythonObject(None)
    var c = Python.list()
    c.append(PythonObject(join(repo, arg)))
    c.append(PythonObject(join(doc_dir, arg)))
    return h["read_input_file"](c)


def _words(toks: List[Tok], start: Int, end: Int) -> List[String]:
    var out = List[String]()
    for i in range(start, end):
        out.append(toks[i].text)
    return out^


def _env_name(k: String) -> Bool:
    if k == "":
        return False
    for b in k.as_bytes():
        var ok = (
            (b >= 48 and b <= 57)
            or (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or b == 95
        )
        if not ok:
            return False
    return True


def parse_example(
    h: PythonObject,
    line: String,
    names: List[String],
    repo: String,
    doc_dir: String,
) raises -> Optional[Case]:
    var parsed = shell_tokens(line)
    if not parsed:
        return None
    var toks = parsed.value().copy()
    var ops = List[Int]()
    for i in range(len(toks)):
        if toks[i].op:
            ops.append(i)
    var main: List[String]
    var stdin = PythonObject(None)
    if len(ops) == 0:
        main = _words(toks, 0, len(toks))
    elif len(ops) == 1 and toks[ops[0]].text == "|":
        var at = ops[0]
        var feed = _words(toks, 0, at)
        if len(feed) == 0:
            return None
        if feed[0] == "echo":
            var newline = not (len(feed) > 1 and feed[1] == "-n")
            var text = String("")
            var first = True
            for k in range(1, len(feed)):
                if feed[k] == "-n" or feed[k] == "-e":
                    continue
                if not first:
                    text += " "
                text += feed[k]
                first = False
            if newline:
                text += "\n"
            stdin = h["utf8"](PythonObject(text))
        elif feed[0] == "printf" and len(feed) == 2:
            var text = feed[1].replace("\\n", "\n").replace("\\t", "\t")
            stdin = h["utf8"](PythonObject(text))
        elif feed[0] == "cat" and len(feed) == 2:
            stdin = _lookup(h, feed[1], repo, doc_dir)
            if _is_none(h, stdin):
                return None
        else:
            return None
        main = _words(toks, at + 1, len(toks))
    elif len(ops) == 1 and toks[ops[0]].text == "<" and ops[0] + 2 == len(toks):
        main = _words(toks, 0, ops[0])
        stdin = _lookup(h, toks[ops[0] + 1].text, repo, doc_dir)
        if _is_none(h, stdin):
            return None
    else:
        return None
    var env_keys = List[String]()
    var env_values = List[String]()
    var rest = 0
    while rest < len(main):
        var pair = _split_once(main[rest], "=")
        if not pair:
            break
        if not _env_name(pair.value()[0]):
            break
        env_keys.append(pair.value()[0])
        env_values.append(pair.value()[1])
        rest += 1
    if rest >= len(main):
        return None
    if not _prog_matches(main[rest], names):
        return None
    var args = List[String]()
    for k in range(rest + 1, len(main)):
        args.append(main[k])
    var kase = Case(args^)
    for k in range(len(env_keys)):
        kase.set_env(env_keys[k], env_values[k])
    kase.stdin = stdin
    var words = kase.args.copy()
    for arg in words:
        var data = _lookup(h, arg, repo, doc_dir)
        if not _is_none(h, data):
            if _non_normal(arg):
                raise decline()
            kase.add_file(h, arg, data)
    return kase^


def _doc_keep(path: String) -> Bool:
    var at = path.rfind("/")
    var name = String(path[byte = at + 1 :])
    return not (
        name == "node_modules"
        or name == "target"
        or name == "vendor"
        or name == ".git"
    )


def find_examples(
    h: PythonObject, repo: String, names: List[String]
) raises -> List[Case]:
    """app.rs `find_examples` over `scan_examples`: shell lines in the
    repository's Markdown code blocks and `.sh` files, four levels deep."""
    var out = List[Case]()
    if len(names) == 0:
        return out^
    if Bool(py=h["doc_links"](PythonObject(repo))):
        raise decline()
    var found = walk(repo, _doc_keep)
    # The Rust walk sorts each folder by name, depth first: component order.
    var paths = py_strings(h["sort_paths"](py_list(found)))
    for path in paths:
        var rel = String(path[byte = repo.byte_length() + 1 :])
        if (
            rel == "rust"
            or rel.startswith("rust/")
            or rel == "mojo"
            or rel.startswith("mojo/")
        ):
            continue
        var depth = 1
        for b in rel.as_bytes():
            if b == 47:
                depth += 1
        if depth > 4:
            continue
        var ext = _extension_lower(path)
        var markdown = ext == "md" or ext == "markdown"
        if not markdown and ext != "sh":
            continue
        var r = h["read_text"](PythonObject(path))
        if String(py=r[0]) != "ok":
            continue
        var text = String(py=r[1])
        var doc_dir = _parent(path)
        var in_fence = False
        var lang = String("")
        for raw in _lines(text):
            var line = _trim(raw)
            var candidate: String
            if markdown:
                if line.startswith("```") or line.startswith("~~~"):
                    if in_fence:
                        in_fence = False
                    else:
                        in_fence = True
                        var b = line.as_bytes()
                        var k = 0
                        while k < len(b) and (b[k] == 96 or b[k] == 126):
                            k += 1
                        # Only compared with ASCII words, which no other
                        # character lowers to.
                        lang = _ascii_lower(_first_word(String(line[byte=k:])))
                    continue
                if not in_fence:
                    continue
                if line.startswith("$ "):
                    candidate = String(line[byte=2:])
                elif (
                    lang == "sh"
                    or lang == "bash"
                    or lang == "shell"
                    or lang == "zsh"
                ):
                    candidate = line
                else:
                    continue
            elif line.startswith("$ "):
                candidate = String(line[byte=2:])
            else:
                candidate = line
            var kase = parse_example(h, candidate, names, repo, doc_dir)
            if kase:
                out.append(kase.value().copy())
    return out^


@fieldwise_init
struct Given(Copyable, Movable):
    var name: Optional[String]
    var kase: Case


def read_inputs(h: PythonObject, path: String) raises -> List[Given]:
    var r = h["read_text"](PythonObject(path))
    if String(py=r[0]) == "err":
        raise Error("reading " + path + ": " + String(py=r[1]))
    if String(py=r[0]) != "ok":
        raise decline()
    var out = List[Given]()
    var lines = _lines(String(py=r[1]))
    for n in range(len(lines)):
        if _trim(lines[n]) == "":
            continue
        var v = h["input_line"](PythonObject(lines[n]))
        if _is_none(h, v):
            raise decline()
        var at = path + ":" + String(n + 1) + ": "
        var kase = Case(py_strings(v[1]))
        if not _is_none(h, v[2]):
            kase.stdin = h["utf8"](v[2])
        var env = v[3]
        for i in range(py_len(env)):
            kase.set_env(String(py=env[i][0]), String(py=env[i][1]))
        var files = v[4]
        for i in range(py_len(files)):
            var file = String(py=files[i][0])
            if not _safe_relative(file):
                raise Error(
                    at
                    + "file `"
                    + file
                    + "` must be a relative path inside the sandbox"
                )
            if _non_normal(file):
                raise decline()
            kase.add_file(h, file, h["utf8"](files[i][1]))
        for file in py_strings(v[5]):
            if not _safe_relative(file):
                raise Error(
                    at
                    + "removed `"
                    + file
                    + "` must be a relative path inside the sandbox"
                )
            kase.remove.append(file)
        var name: Optional[String] = None
        if not _is_none(h, v[0]):
            name = String(py=v[0])
        out.append(Given(name, kase^))
    return out^


# --- traps ------------------------------------------------------------------------------


def _digits(b: Span[UInt8, _], mut i: Int) -> Int:
    var start = i
    while i < len(b) and b[i] >= 48 and b[i] <= 57:
        i += 1
    return i - start


def parses_f64(s: String) -> Bool:
    """Whether `s.parse::<f64>()` succeeds (Rust's float grammar)."""
    var b = s.as_bytes()
    var i = 0
    if len(b) > 0 and (b[0] == 43 or b[0] == 45):
        i = 1
    var word = _ascii_lower(String(s[byte=i:]))
    if word == "inf" or word == "infinity" or word == "nan":
        return True
    var whole = _digits(b, i)
    var frac = 0
    if i < len(b) and b[i] == 46:
        i += 1
        frac = _digits(b, i)
    if whole + frac == 0:
        return False
    if i < len(b) and (b[i] == 101 or b[i] == 69):
        i += 1
        if i < len(b) and (b[i] == 43 or b[i] == 45):
            i += 1
        if _digits(b, i) == 0:
            return False
    return i == len(b)


def parses_i128(s: String) -> Bool:
    """Whether `s.parse::<i128>()` succeeds."""
    var b = s.as_bytes()
    var i = 0
    var negative = False
    if len(b) > 0 and (b[0] == 43 or b[0] == 45):
        negative = b[0] == 45
        i = 1
    var start = i
    if _digits(b, i) == 0 or i != len(b):
        return False
    while start < len(b) - 1 and b[start] == 48:
        start += 1
    var mag = String(s[byte=start:])
    var limit = String(_I128_MIN) if negative else String(_I128_MAX)
    if mag.byte_length() != limit.byte_length():
        return mag.byte_length() < limit.byte_length()
    return mag <= limit


def is_word(arg: String) -> Bool:
    var b = arg.as_bytes()
    if len(b) == 0:
        return False
    if not ((b[0] >= 65 and b[0] <= 90) or (b[0] >= 97 and b[0] <= 122)):
        return False
    for k in range(1, len(b)):
        var c = b[k]
        var ok = (
            (c >= 48 and c <= 57)
            or (c >= 65 and c <= 90)
            or (c >= 97 and c <= 122)
            or c == 45
            or c == 95
        )
        if not ok:
            return False
    return True


def _int_traps() -> List[String]:
    return [
        "-7",
        "0",
        "-1",
        "2147483648",
        "9007199254740993",
        "9223372036854775807",
        "-9223372036854775808",
        "18446744073709551616",
    ]


def _float_traps() -> List[String]:
    return [
        "-0.0",
        "0.1",
        "0.30000000000000004",
        "1e21",
        "1e-7",
        "5e-324",
        "1.7976931348623157e308",
    ]


def _string_traps() -> List[String]:
    var out = List[String]()
    out.append("h" + chr(0xE9) + "llo w" + chr(0xF6) + "rld")
    out.append(chr(0x1F44D) + chr(0x1F3FD) + " thumbs")
    out.append(chr(0x65E5) + chr(0x672C) + chr(0x8A9E))
    out.append("")
    out.append("e" + chr(0x301))
    out.append(chr(0x130) + "stanbul")
    out.append("stra" + chr(0xDF) + "e")
    out.append(chr(0x131) + "l" + chr(0x131) + "k " + chr(0x131) + "rmak")
    out.append(
        chr(0x1F468)
        + chr(0x200D)
        + chr(0x1F469)
        + chr(0x200D)
        + chr(0x1F467)
        + " family"
    )
    out.append("a" + chr(0xA0) + "b")
    return out^


def _stdin_traps() -> List[String]:
    var out = List[String]()
    out.append(
        "na"
        + chr(0xEF)
        + "ve caf"
        + chr(0xE9)
        + " "
        + chr(0x1F44D)
        + chr(0x1F3FD)
        + "\nsecond line\n"
    )
    out.append("")
    out.append(
        chr(0x65E5)
        + chr(0x672C)
        + chr(0x8A9E)
        + " "
        + chr(0x30C6)
        + chr(0x30AD)
        + chr(0x30B9)
        + chr(0x30C8)
        + "\r\nline two\r\n"
    )
    out.append("  spaced   out  \n\n")
    return out^


def _json_traps() -> List[String]:
    var out = List[String]()
    out.append(
        '{"zebra":1,"apple":2,"10":3,"2":4,"' + chr(0xE9) + '":5,"Apple":6}'
    )
    out.append('{"n":9007199254740993,"f":1e21,"t":0.1,"neg":-7}')
    return out^


def trap_cases(h: PythonObject, bases: List[Case]) raises -> List[Case]:
    var out = List[Case]()
    for base in bases:
        # Rust keeps the first MAX_TRAPS: no later base can add to them.
        if len(out) >= MAX_TRAPS:
            break
        for i in range(len(base.args)):
            var arg = base.args[i]
            if i == 0 and is_word(arg):
                continue
            var number = parses_f64(arg)
            if arg.startswith("-") and not number:
                continue
            var is_input = False
            for f in base.file_names:
                if _same_path(f, arg):
                    is_input = True
            var values: List[String]
            if parses_i128(arg):
                values = _int_traps()
            elif number and (
                arg.find(".") >= 0 or arg.find("e") >= 0 or arg.find("E") >= 0
            ):
                values = _float_traps()
            elif is_input:
                values = ["missing-input.txt"]
            else:
                values = _string_traps()
            for v in values:
                if v == arg:
                    continue
                var kase = base.copy()
                kase.args[i] = v
                out.append(kase^)
        if not _is_none(h, base.stdin):
            var kind = Int(py=h["json_container"](base.stdin))
            if kind < 0:
                raise decline()
            var values = _json_traps() if kind == 1 else _stdin_traps()
            for v in values:
                var kase = base.copy()
                kase.stdin = h["utf8"](PythonObject(v))
                out.append(kase^)
    while len(out) > MAX_TRAPS:
        _ = out.pop()
    return out^


# --- names ------------------------------------------------------------------------------


def slug_max(text: String, max: Int) -> String:
    var out = String("")
    for b in text.as_bytes():
        if b >= 65 and b <= 90:
            out += chr(Int(b) + 32)
        elif (b >= 48 and b <= 57) or (b >= 97 and b <= 122):
            out += chr(Int(b))
        elif not out.endswith("-") and out != "":
            out += "-"
    if out.byte_length() > max:
        var cut = String(out[byte=0:max])
        out = cut
    while out.endswith("-"):
        var cut = String(out[byte = 0 : out.byte_length() - 1])
        out = cut
    return out


def slug(text: String) -> String:
    return slug_max(text, 24)


def given_slug(text: String) -> String:
    return slug_max(text, 96)


def _pad3(n: Int) -> String:
    var s = String(n)
    while s.byte_length() < 3:
        s = "0" + s
    return s


def reserve_case_name(
    mut taken: Set[String], base: String, var suffix: Int
) -> String:
    var name = base
    while name in taken:
        name = base + "-" + String(suffix)
        suffix += 1
    taken.add(name)
    return name


@fieldwise_init
struct Planned(Copyable, Movable):
    var name: String
    var kase: Case


struct Plan(Movable):
    var cases: List[Planned]
    var seen: Set[String]
    var taken: Set[String]

    def __init__(out self):
        self.cases = List[Planned]()
        self.seen = Set[String]()
        self.taken = Set[String]()

    def push(
        mut self,
        h: PythonObject,
        prefix: String,
        n: Int,
        given: Optional[String],
        kase: Case,
    ) raises -> Bool:
        var key = kase.key(h)
        if key in self.seen:
            return False
        self.seen.add(key)
        var base: String
        if given and given_slug(given.value()) != "":
            base = given_slug(given.value())
        else:
            var s = String("")
            if len(kase.args) > 0:
                s = slug(kase.args[0])
            if s != "":
                base = prefix + "-" + _pad3(n) + "-" + s
            else:
                base = prefix + "-" + _pad3(n)
        var name = reserve_case_name(self.taken, base, n)
        self.cases.append(Planned(name, kase.copy()))
        return True


# --- two runs, settled ---------------------------------------------------------------


def _merge_line(h: PythonObject, a: String, b: String) raises -> String:
    var ta = h["merge_tokens"](PythonObject(a))
    var tb = h["merge_tokens"](PythonObject(b))
    if _is_none(h, ta) or _is_none(h, tb):
        raise decline()
    if py_len(ta) != py_len(tb):
        return "[..]"
    var out = String("")
    for i in range(py_len(ta)):
        var x = String(py=ta[i])
        if x == String(py=tb[i]):
            out += x
        elif not out.endswith("[..]"):
            out += "[..]"
    return out


def _flush(
    h: PythonObject,
    mut out: List[String],
    mut dels: List[String],
    mut ins: List[String],
) raises:
    if len(dels) == 0 and len(ins) == 0:
        return
    if len(dels) == len(ins):
        for i in range(len(dels)):
            out.append(_merge_line(h, dels[i], ins[i]))
    elif len(out) == 0 or out[len(out) - 1] != "...":
        out.append("...")
    dels.clear()
    ins.clear()


def merge_noise(h: PythonObject, a: String, b: String) raises -> String:
    """Two runs of the original: what they agree on stays, what differs
    becomes a wildcard."""
    if a == b:
        return a
    var la = _split_lf(a)
    var lb = _split_lf(b)
    var ops = diff_ops(la, lb, None, exact=True)
    var out = List[String]()
    var dels = List[String]()
    var ins = List[String]()
    for op in ops:
        if op.kind == _EQUAL:
            _flush(h, out, dels, ins)
            out.append(la[op.i])
        elif op.kind == _DELETE:
            dels.append(la[op.i])
        else:
            ins.append(lb[op.j])
    _flush(h, out, dels, ins)
    var text = String("")
    for i in range(len(out)):
        if i > 0:
            text += "\n"
        text += out[i]
    return text


def _text_lines(text: String) -> List[String]:
    """app.rs `lines`."""
    var t = text
    if t.endswith("\n"):
        var cut = String(t[byte = 0 : t.byte_length() - 1])
        t = cut
    var out = List[String]()
    if t == "":
        return out^
    for l in _split_lf(t):
        if l.endswith("\r"):
            out.append(String(l[byte = 0 : l.byte_length() - 1]))
        else:
            out.append(l)
    return out^


def _same_lines_any_order(h: PythonObject, a: String, b: String) raises -> Bool:
    var x = py_strings(h["sorted_strs"](py_list(_text_lines(a))))
    var y = py_strings(h["sorted_strs"](py_list(_text_lines(b))))
    return _same_list(x, y)


@fieldwise_init
struct Settled(Copyable, Movable):
    var data: PythonObject
    var noise: Int
    var binary: Bool


def settle_text(
    h: PythonObject, norm: Normalizers, a: PythonObject, b: PythonObject
) raises -> Settled:
    var ta = h["text_of"](a)
    var tb = h["text_of"](b)
    if Bool(py=ta[0]) and Bool(py=tb[0]):
        var x = norm.apply(h, String(py=ta[1]))
        var y = norm.apply(h, String(py=tb[1]))
        if x == y:
            return Settled(h["utf8"](PythonObject(x)), NOISE_NONE, False)
        if _same_lines_any_order(h, x, y):
            return Settled(h["utf8"](PythonObject(x)), NOISE_ORDER, False)
        var merged = merge_noise(h, x, y)
        var kind = NOISE_VALUES
        for l in _split_lf(merged):
            if l == "...":
                kind = NOISE_LINES
        return Settled(h["utf8"](PythonObject(merged)), kind, False)
    var differ = not Bool(py=h["same_bytes"](a, b))
    return Settled(a, NOISE_VALUES if differ else NOISE_NONE, True)


struct Recorded(Copyable, Movable):
    var stdout: PythonObject
    var stderr: PythonObject
    var status: String
    var code: Int
    var written: PythonObject
    var written_names: List[String]
    var removed: List[String]
    var binary: Bool
    var noise_fields: List[String]
    var noise_kinds: List[Int]
    var unstable: Bool

    def __init__(out self) raises:
        self.stdout = PythonObject(None)
        self.stderr = PythonObject(None)
        self.status = "code"
        self.code = 0
        self.written = Python.dict()
        self.written_names = List[String]()
        self.removed = List[String]()
        self.binary = False
        self.noise_fields = List[String]()
        self.noise_kinds = List[Int]()
        self.unstable = False


def _utf8_ok(h: PythonObject, b: PythonObject) raises -> Bool:
    return Bool(py=h["text_of"](b)[0])


def settle(
    h: PythonObject,
    norm: Normalizers,
    kase: Case,
    one: PythonObject,
    two: PythonObject,
) raises -> Recorded:
    var rec = Recorded()
    var binary = not (
        _utf8_ok(h, one["stdout"])
        and _utf8_ok(h, one["stderr"])
        and _utf8_ok(h, two["stdout"])
        and _utf8_ok(h, two["stderr"])
    )
    var streams: List[String] = ["stdout", "stderr"]
    var noises = List[Int]()
    for s in streams:
        var a = one[PythonObject(s)]
        var b = two[PythonObject(s)]
        var data: PythonObject
        var noise: Int
        if binary:
            data = a
            noise = NOISE_NONE if Bool(
                py=h["same_bytes"](a, b)
            ) else NOISE_VALUES
        else:
            var st = settle_text(h, norm, a, b)
            data = st.data
            noise = st.noise
        if s == "stdout":
            rec.stdout = data
        else:
            rec.stderr = data
        noises.append(noise)
        if noise != NOISE_NONE:
            rec.noise_fields.append(s)
            rec.noise_kinds.append(noise)
    var w1 = h["written"](one, kase.files)
    var w2 = h["written"](two, kase.files)
    var n1 = py_strings(h["file_names"](w1))
    var n2 = py_strings(h["file_names"](w2))
    var s1 = one["status"]
    var s2 = two["status"]
    var r1 = py_strings(one["removed"])
    var r2 = py_strings(two["removed"])
    var unstable = (
        String(py=s1[0]) != String(py=s2[0])
        or Int(py=s1[1]) != Int(py=s2[1])
        or not _same_list(r1, r2)
        or not _same_list(n1, n2)
        or (binary and (noises[0] != NOISE_NONE or noises[1] != NOISE_NONE))
    )
    for path in n1:
        var a = w1[PythonObject(path)]
        var b = h["dict_get"](w2, PythonObject(path), a)
        var st = settle_text(h, norm, a, b)
        if st.binary and st.noise != NOISE_NONE:
            unstable = True
        if st.noise != NOISE_NONE:
            rec.noise_fields.append("file " + path)
            rec.noise_kinds.append(st.noise)
        _ = h["put"](rec.written, PythonObject(path), st.data)
        rec.written_names.append(path)
    rec.status = String(py=s1[0])
    rec.code = Int(py=s1[1])
    rec.removed = r1^
    rec.binary = binary
    rec.unstable = unstable
    return rec^


# --- the files written ------------------------------------------------------------------


def _toml_string(s: String) raises -> String:
    """A TOML basic string as toml_edit writes one that needs no escape;
    one that would (a quote, a backslash, a control character) is
    declined."""
    for b in s.as_bytes():
        if b == 34 or b == 92 or b < 32 or b == 127:
            raise decline()
    return '"' + s + '"'


def _toml_key(k: String) raises -> String:
    """A bare key; one toml_edit would quote is declined."""
    if k == "":
        raise decline()
    for b in k.as_bytes():
        var ok = (
            (b >= 48 and b <= 57)
            or (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or b == 45
            or b == 95
        )
        if not ok:
            raise decline()
    return k


def _toml_array(items: List[String]) raises -> String:
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ", "
        out += _toml_string(items[i])
    return out + "]"


def case_toml(
    bin: String, name: String, kase: Case, rec: Recorded
) raises -> String:
    """`write_case`'s document, as toml_edit prints its dotted tables: in
    the order they were set."""
    var out = "bin.name = " + _toml_string(bin) + "\n"
    out += "args = " + _toml_array(kase.args) + "\n"
    for i in range(len(kase.env_keys)):
        out += (
            "env.add."
            + _toml_key(kase.env_keys[i])
            + " = "
            + _toml_string(kase.env_values[i])
            + "\n"
        )
    if rec.status == "code":
        out += "status.code = " + String(rec.code) + "\n"
    else:
        out += 'status = "interrupted"\n'
    out += "fs.sandbox = true\n"
    if len(kase.file_names) > 0:
        out += "fs.base = " + _toml_string(name + ".in") + "\n"
    if len(kase.remove) > 0:
        out += "fs.remove = " + _toml_array(kase.remove) + "\n"
    if rec.binary:
        out += "binary = true\n"
    return out


def _write(h: PythonObject, path: String, data: PythonObject) raises:
    var err = String(py=h["write_file"](PythonObject(path), data))
    if err != "":
        raise Error(err)


def write_case(
    h: PythonObject,
    dir: String,
    name: String,
    toml: String,
    kase: Case,
    rec: Recorded,
) raises:
    var base = dir + "/" + name
    var exts: List[String] = ["stdin", "stdout", "stderr", "removed", "effects"]
    for ext in exts:
        _ = h["remove_file"](PythonObject(base + "." + ext))
    var trees: List[String] = ["in", "out"]
    for ext in trees:
        _ = h["remove_tree"](PythonObject(base + "." + ext))
    _write(h, base + ".toml", h["utf8"](PythonObject(toml)))
    if not _is_none(h, kase.stdin):
        _write(h, base + ".stdin", kase.stdin)
    _write(h, base + ".stdout", rec.stdout)
    _write(h, base + ".stderr", rec.stderr)
    if len(rec.removed) > 0:
        var list = String("")
        for p in rec.removed:
            list += p + "\n"
        _write(h, base + ".removed", h["utf8"](PythonObject(list)))
    for p in kase.file_names:
        _write(h, base + ".in/" + p, kase.files[PythonObject(p)])
    for p in rec.written_names:
        _write(h, base + ".out/" + p, rec.written[PythonObject(p)])


def _strings_json(items: List[String], indent: String) -> String:
    if len(items) == 0:
        return "[]"
    var out = String("[\n")
    for i in range(len(items)):
        out += indent + "  " + write_string(items[i])
        out += ",\n" if i + 1 < len(items) else "\n"
    return out + indent + "]"


def config_json(
    config: Config,
    unordered_cases: List[String],
    unordered_fields: List[List[String]],
) -> String:
    """`Config` as serde_json's `to_string_pretty` writes it (empty and unset
    fields skipped), for a recording without servers, effects, a tolerance,
    or float files."""
    var out = String("{\n")
    out += '  "schema": ' + write_string(SCHEMA) + ",\n"
    out += '  "name": ' + write_string(config.name) + ",\n"
    out += '  "run": ' + _strings_json(config.run, "  ") + ",\n"
    if len(config.normalize) > 0:
        out += '  "normalize": ' + _strings_json(config.normalize, "  ") + ",\n"
    if len(config.normalizer_names) > 0:
        out += '  "normalizers": {\n'
        for i in range(len(config.normalizer_names)):
            out += (
                "    "
                + write_string(config.normalizer_names[i])
                + ": "
                + write_string(config.normalizer_patterns[i])
            )
            out += ",\n" if i + 1 < len(config.normalizer_names) else "\n"
        out += "  },\n"
    out += '  "timeout_secs": ' + String(config.timeout_secs)
    if len(unordered_cases) > 0:
        out += ',\n  "unordered": {\n'
        for i in range(len(unordered_cases)):
            out += (
                "    "
                + write_string(unordered_cases[i])
                + ": "
                + _strings_json(unordered_fields[i], "    ")
            )
            out += ",\n" if i + 1 < len(unordered_cases) else "\n"
        out += "  }"
    if len(config.fresh) > 0:
        out += ',\n  "fresh": ' + _strings_json(config.fresh, "  ")
    return out + "\n}\n"


# --- record -------------------------------------------------------------------------------


def _all_normal(path: String) -> Bool:
    """`is_relative()` and every component `Normal`; "" (which Rust lets
    through, to copy the whole repository) is declined by the caller."""
    if path.startswith("/"):
        return False
    var segs = _split_slash(path)
    for k in range(len(segs)):
        if segs[k] == "..":
            return False
        if segs[k] == "." and k == 0:
            return False
    return True


def snapshot_to(
    h: PythonObject, repo: String, fresh: List[String], dir: String
) raises:
    """http.rs `snapshot_to`: the `fresh` paths copied from the repository
    into `dir`, replacing the last snapshot; a path ending in `/` gives its
    contents."""
    for path in fresh:
        if path == "":
            raise decline()
    _ = h["remove_tree"](PythonObject(dir))
    for path in fresh:
        if not _all_normal(path):
            raise Error(
                "--fresh `"
                + path
                + "`: give a path inside the repository, relative to it"
            )
        var src = join(repo, path)
        if not Bool(py=h["exists"](PythonObject(src))):
            raise Error("--fresh `" + path + "`: no such file or folder")
        var to = join(dir, path)
        if path.endswith("/") and Bool(py=h["is_dir"](PythonObject(src))):
            to = dir
        var copied = h["copy_tree"](PythonObject(src), PythonObject(to))
        if _is_none(h, copied):
            raise decline()
        var err = String(py=copied)
        if err != "":
            raise Error(err)


def _kind_name(kind: Int) -> String:
    if kind == NOISE_ORDER:
        return "order"
    if kind == NOISE_LINES:
        return "lines"
    return "values"


struct Outcome(Copyable, Movable):
    var dir: String
    var run: List[String]
    var cases: Int
    var examples: Int
    var inputs: Int
    var traps: Int
    var noisy: List[String]
    var noise_cases: List[String]
    var noise_fields: List[String]
    var noise_kinds: List[Int]
    var unstable: List[String]
    var timed_out: List[String]

    def __init__(out self, dir: String, run: List[String]):
        self.dir = dir
        self.run = run.copy()
        self.cases = 0
        self.examples = 0
        self.inputs = 0
        self.traps = 0
        self.noisy = List[String]()
        self.noise_cases = List[String]()
        self.noise_fields = List[String]()
        self.noise_kinds = List[Int]()
        self.unstable = List[String]()
        self.timed_out = List[String]()


def outcome_json(o: Outcome) -> String:
    """`RecordOutcome` as serde_json's `to_string_pretty` writes it."""
    var out = String("{\n")
    out += '  "dir": ' + write_string(o.dir) + ",\n"
    out += '  "run": ' + _strings_json(o.run, "  ") + ",\n"
    out += String('  "cases": ', o.cases, ",\n")
    out += String('  "examples": ', o.examples, ",\n")
    out += String('  "inputs": ', o.inputs, ",\n")
    out += String('  "traps": ', o.traps, ",\n")
    out += '  "noisy": ' + _strings_json(o.noisy, "  ") + ",\n"
    if len(o.noise_cases) == 0:
        out += '  "noise": [],\n'
    else:
        out += '  "noise": [\n'
        for i in range(len(o.noise_cases)):
            out += "    {\n"
            out += '      "case": ' + write_string(o.noise_cases[i]) + ",\n"
            out += '      "field": ' + write_string(o.noise_fields[i]) + ",\n"
            out += (
                '      "kind": '
                + write_string(_kind_name(o.noise_kinds[i]))
                + "\n"
            )
            out += "    }"
            out += ",\n" if i + 1 < len(o.noise_cases) else "\n"
        out += "  ],\n"
    out += '  "unstable": ' + _strings_json(o.unstable, "  ") + ",\n"
    out += '  "timed_out": ' + _strings_json(o.timed_out, "  ") + "\n"
    return out + "}"


def _joined(items: List[String]) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += ", "
        out += items[i]
    return out


def say_record(o: Outcome) -> String:
    var out = String(
        "Recorded ",
        o.cases,
        " cases in ",
        o.dir,
        " (",
        o.examples,
        " from examples, ",
        o.inputs,
        " from inputs, ",
        o.traps,
        " traps)\n",
    )
    var kinds: List[Int] = [NOISE_LINES, NOISE_ORDER, NOISE_VALUES]
    var whats: List[String] = [
        (
            "Lines (a different number of lines between two runs; now `...`,"
            " which matches anything: check these first)"
        ),
        (
            "Order (the same lines in another order between two runs; replay"
            " compares them in any order)"
        ),
        (
            "Values (parts of lines differed between two runs; now `[..]`"
            " wildcards)"
        ),
    ]
    for k in range(3):
        var hits = List[String]()
        for i in range(len(o.noise_cases)):
            if o.noise_kinds[i] == kinds[k]:
                hits.append(o.noise_cases[i] + " (" + o.noise_fields[i] + ")")
        if len(hits) > 0:
            out += "Noise, " + whats[k] + ": " + _joined(hits) + "\n"
    if len(o.unstable) > 0:
        out += (
            "Unstable (exit code or files differed between runs; check them): "
            + _joined(o.unstable)
            + "\n"
        )
    if len(o.timed_out) > 0:
        out += "Timed out, not recorded: " + _joined(o.timed_out) + "\n"
    return out


def _safe_words(h: PythonObject, words: List[String]) raises -> Bool:
    for w in words:
        if not Bool(py=h["safe_word"](PythonObject(w))):
            return False
    return True


def _runnable(h: PythonObject, kase: Case) raises -> Bool:
    """What Python's subprocess refuses where Rust's Command passes it on,
    and what toml_edit would write with escapes or quotes: declined before
    anything runs."""
    if not _safe_words(h, kase.args) or not _safe_words(h, kase.env_values):
        return False
    for k in kase.env_keys:
        if not Bool(py=h["safe_env_key"](PythonObject(k))):
            return False
    try:
        _ = _toml_array(kase.args)
        _ = _toml_array(kase.env_values)
        _ = _toml_array(kase.remove)
        for k in kase.env_keys:
            _ = _toml_key(k)
    except:
        return False
    return True


def _merge_normalizers(mut config: Config, given: List[String]):
    for n in given:
        var pair = _split_once(n, "=")
        if pair:
            # A BTreeMap: one pattern per name, kept in name order.
            var name = pair.value()[0]
            var found = False
            for i in range(len(config.normalizer_names)):
                if config.normalizer_names[i] == name:
                    config.normalizer_patterns[i] = pair.value()[1]
                    found = True
            if not found:
                var at = 0
                while (
                    at < len(config.normalizer_names)
                    and config.normalizer_names[at] < name
                ):
                    at += 1
                config.normalizer_names.insert(at, name)
                config.normalizer_patterns.insert(at, pair.value()[1])
        elif not (n in config.normalize):
            config.normalize.append(n)


def record(h: PythonObject, p: Parsed) raises -> Outcome:
    """The Rust tool's `record` for a CLI: raises its errors, or `DECLINE`
    for anything this port does not reproduce byte for byte."""
    var not_ported: List[String] = [
        "effects",
        "effect-env",
        "db-reset",
        "db-dump",
    ]
    for name in not_ported:
        if len(p.all(name)) > 0:
            raise decline()
    var given = p.value("REPO")
    var repo_arg = given.value() if given else String(".")
    var canon = h["canonical"](PythonObject(repo_arg))
    if String(py=canon[0]) == "odd":
        raise decline()
    if String(py=canon[0]) != "ok":
        raise Error("no folder " + repo_arg + ": " + String(py=canon[1]))
    var repo = String(py=canon[1])
    var existing = load_config(h, repo)
    var config = existing.value().copy() if existing else Config()
    if len(p.rest) == 0 and not existing:
        raise Error(
            "give the command that runs the original after `--`, e.g."
            " `mojo-anything app record . -- python3 cli.py`"
        )
    if len(p.rest) > 0:
        config.run = p.rest.copy()
    _merge_normalizers(config, p.all("normalize"))
    if (
        p.flag("http")
        or p.value("port")
        or p.value("pace")
        or len(p.all("arg")) > 0
        or config.http
        or config.effects
    ):
        raise decline()
    var tol = p.value("float-tolerance")
    if tol:
        var t = Float64(
            py=Python.import_module("builtins").float(PythonObject(tol.value()))
        )
        if not (t >= 0.0 and t < 1.0):
            raise decline()
        if t > 0.0:
            config.float_tolerance = t
        else:
            config.float_tolerance = None
    var files = p.all("float-file")
    for spec in files:
        var pair = _rsplit_once(spec, "=")
        if not pair:
            raise Error(
                "--float-file `" + spec + "`: use PATH=f32le or PATH=f64le"
            )
        _float_width(pair.value()[1])
    var float_files = config.float_files or len(files) > 0
    if len(files) > 0:
        config.float_files = False
    # The rest of the checks are Normalizers::new's.
    var norm = Normalizers(h, config)
    # Not ported yet: a tolerance and float files (an f64 and a map in
    # mojo-anything.json).
    if config.float_tolerance or float_files:
        raise decline()
    if len(p.all("fresh")) > 0:
        config.fresh = p.all("fresh")
    var t = p.value("timeout")
    if t:
        var v = Python.import_module("builtins").int(PythonObject(t.value()))
        if Bool(py=v > PythonObject(_MAX_TIMEOUT)):
            raise decline()
        config.timeout_secs = Int(py=v)
    if config.timeout_secs == 0 or config.timeout_secs > _MAX_TIMEOUT:
        raise decline()
    var explicit = p.value("name")
    if not explicit and existing:
        explicit = existing.value().name
    var names = app_names(h, repo, config.run, explicit)
    if explicit:
        config.name = explicit.value()
    elif len(names) > 0:
        config.name = names[0]
    else:
        config.name = "app"
    if not _safe_words(h, config.run):
        raise decline()
    _ = _toml_string(config.name)

    var examples = find_examples(h, repo, names)
    var inputs = List[Given]()
    var path = p.value("inputs")
    if path:
        inputs = read_inputs(h, path.value())
    var plan = Plan()
    var bases = List[Case]()
    var counts = List[Int](length=3, fill=0)
    for kase in examples:
        if plan.push(h, "example", counts[0] + 1, None, kase):
            counts[0] += 1
            bases.append(kase.copy())
    for g in inputs:
        if plan.push(h, "input", counts[1] + 1, g.name, g.kase):
            counts[1] += 1
            bases.append(g.kase.copy())
    if len(bases) == 0:
        var kase = Case(List[String]())
        _ = plan.push(h, "example", 1, String("no-args"), kase)
        bases.append(kase^)
    if not p.flag("no-traps"):
        for kase in trap_cases(h, bases):
            if plan.push(h, "trap", counts[2] + 1, None, kase):
                counts[2] += 1

    var dir = join(repo, CASES_DIR)
    var base = PythonObject(None)
    if len(config.fresh) > 0:
        base = PythonObject(dir + "/" + FRESH_DIR)
    var jobs = Python.list()
    for pc in plan.cases:
        if not _runnable(h, pc.kase):
            raise decline()
        jobs.append(
            h["new_job"](
                py_list(config.run),
                PythonObject(repo),
                py_list(pc.kase.args),
                pc.kase.stdin,
                pc.kase.env_pairs(),
                Python.list(),
                PythonObject(config.timeout_secs),
                pc.kase.files,
                py_list(pc.kase.remove),
                base,
            )
        )
    # The snapshot is the first thing written, as in the Rust tool.
    if len(config.fresh) > 0:
        snapshot_to(h, repo, config.fresh, dir + "/" + FRESH_DIR)
    var results = h["run_pairs"](jobs)

    # Every case is settled and its TOML built before anything is written:
    # a decline after this point would leave half a recording.
    var recs = List[Recorded]()
    var tomls = List[String]()
    var error = String("")
    var stop = len(plan.cases)
    for k in range(len(plan.cases)):
        var r = results[k]
        var kind = String(py=h["pair_kind"](r))
        if kind == "odd":
            raise decline()
        if kind == "error":
            error = String(py=r["error"])
            stop = k
            break
        var one = r["one"]
        var two = r["two"]
        if (
            String(py=one["status"][0]) == "timeout"
            or String(py=two["status"][0]) == "timeout"
        ):
            recs.append(Recorded())
            tomls.append("")
            continue
        var rec = settle(h, norm, plan.cases[k].kase, one, two)
        tomls.append(
            case_toml(config.name, plan.cases[k].name, plan.cases[k].kase, rec)
        )
        recs.append(rec^)

    var outcome = Outcome(dir, config.run)
    outcome.examples = counts[0]
    outcome.inputs = counts[1]
    outcome.traps = counts[2]
    var err = String(py=h["make_dirs"](PythonObject(dir)))
    if err != "":
        raise Error("creating " + dir + ": " + err)
    var unordered_cases = List[String]()
    var unordered_fields = List[List[String]]()
    for k in range(stop):
        var name = plan.cases[k].name
        if tomls[k] == "":
            outcome.timed_out.append(name)
            continue
        write_case(h, dir, name, tomls[k], plan.cases[k].kase, recs[k])
        outcome.cases += 1
        ref rec = recs[k]
        if len(rec.noise_fields) > 0:
            outcome.noisy.append(name)
        for i in range(len(rec.noise_fields)):
            outcome.noise_cases.append(name)
            outcome.noise_fields.append(rec.noise_fields[i])
            outcome.noise_kinds.append(rec.noise_kinds[i])
            if rec.noise_kinds[i] != NOISE_ORDER:
                continue
            var found = -1
            for u in range(len(unordered_cases)):
                if unordered_cases[u] == name:
                    found = u
            if found < 0:
                var at = 0
                while at < len(unordered_cases) and unordered_cases[at] < name:
                    at += 1
                unordered_cases.insert(at, name)
                unordered_fields.insert(at, List[String]())
                found = at
            unordered_fields[found].append(rec.noise_fields[i])
        if rec.unstable:
            outcome.unstable.append(name)
    if error != "":
        raise Error(error)
    _write(
        h,
        dir + "/" + CONFIG_FILE,
        h["utf8"](
            PythonObject(config_json(config, unordered_cases, unordered_fields))
        ),
    )
    return outcome^


def run_app_record(p: Parsed, argv: List[String]) raises -> Int:
    """`mojo-anything app record` for a CLI; anything it cannot answer exactly
    runs the Phase 1 binary."""
    var h = py_helpers()
    try:
        var outcome = record(h, p)
        if p.flag("json"):
            print(outcome_json(outcome))
        else:
            print(say_record(outcome), end="")
        return 0
    except e:
        if String(e) == DECLINE:
            return fallback(argv)
        raise e
