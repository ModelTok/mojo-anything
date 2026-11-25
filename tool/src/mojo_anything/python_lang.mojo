# Python for `analyze` (port of src/lang/python.rs's resolution, STDLIB,
# `to_ts_type` and the bridge rules `analyze` applies to its exports, and of
# bridge::js_only_reason for exports without local types). What tree-sitter
# reads from a file (risks, imports, loops, exported functions and classes)
# comes from analyze_py.py through CPython's `ast`; a file it declines sends
# the whole command to the Phase 1 binary.

from std.python import Python, PythonObject


from mojo_anything.pycache import py_exec
from mojo_anything.embedded import analyze_py_source
from mojo_anything.risks import RISK_COUNT, risk_index

comptime FILE = 0
comptime EXTERNAL = 1
comptime STDLIB = 2
comptime UNRESOLVED = 3
comptime WORKSPACE = 4
comptime PLATFORM_NODE = 1
comptime PLATFORM_BROWSER = 2
comptime PLATFORM_EDITOR = 4
comptime PLATFORM_UI = 8


def py_helpers() raises -> PythonObject:
    var scope = Python.dict()
    py_exec(analyze_py_source(), scope)
    return scope


struct Facts(Copyable, Movable):
    """FileFacts of one file, and its exports as check_bridgeable counts
    them; `readable` is False where read_to_string fails (no facts)."""

    var readable: Bool
    var loc: Int
    var specs: List[String]
    var type_only: List[Bool]
    var risks: List[List[Int]]
    """Lines of each risk, by risk index, in tree order."""
    var loops: Int
    var exports: Int
    var bridgeable: Int
    var parse_errors: Int
    """oxc's diagnostics (TS); the other readers decline on an error."""
    var platforms: Int
    """The runtimes the file uses directly (TS): a set of PLATFORM_* bits."""
    var platform: List[Bool]
    """Per import (TS): scan::platform_of names a runtime."""
    var package: List[String]
    """Per import (TS): deps::package_name."""
    var aliases: List[List[String]]
    """Per import (TS): the tsconfig `paths` candidates, empty for none."""

    def __init__(out self):
        self.readable = False
        self.loc = 0
        self.specs = List[String]()
        self.type_only = List[Bool]()
        self.risks = List[List[Int]]()
        for _ in range(RISK_COUNT):
            self.risks.append(List[Int]())
        self.loops = 0
        self.exports = 0
        self.bridgeable = 0
        self.parse_errors = 0
        self.platforms = 0
        self.platform = List[Bool]()
        self.package = List[String]()
        self.aliases = List[List[String]]()


def _len(x: PythonObject) raises -> Int:
    return Int(py=Python.import_module("builtins").len(x))


def read_facts(
    py: PythonObject, path: String, rel: String, mut declined: Bool
) raises -> Facts:
    """The facts of the file at `path` (`rel` from the root); `declined` is
    set when `ast` may read it otherwise than tree-sitter."""
    return facts_of(
        py["read_file"](PythonObject(path), PythonObject(rel)), declined
    )


def facts_of(r: PythonObject, mut declined: Bool) raises -> Facts:
    """The facts in one answer of analyze_py.py `read_file` (or of
    `read_files`, which reads a workspace's files in worker processes)."""
    var out = Facts()
    var status = String(py=r[0])
    if status == "unreadable":
        return out^
    if status != "ok":
        declined = True
        return out^
    out.readable = True
    out.loc = Int(py=r[1])
    var imports = r[2]
    for i in range(_len(imports)):
        out.specs.append(String(py=imports[i][0]))
        out.type_only.append(Bool(py=imports[i][1]))
    var risks = r[3]
    for i in range(_len(risks)):
        var k = risk_index(String(py=risks[i][0]))
        if k < 0:
            declined = True
            return out^
        var lines = risks[i][1]
        for j in range(_len(lines)):
            out.risks[k].append(Int(py=lines[j]))
    out.loops = Int(py=r[4])
    var functions = r[5]
    for i in range(_len(functions)):
        var f = functions[i]
        out.exports += 1
        var types = List[String]()
        var given = f[2]
        for j in range(_len(given)):
            var hint = String(py=given[j])
            if hint.byte_length() > 0:
                types.append(to_ts_type(hint))
        var ret = String(py=f[3])
        if ret.byte_length() > 0:
            types.append(to_ts_type(ret))
        if not Bool(py=f[0]) and not Bool(py=f[1]) and not _js_shaped(types):
            out.bridgeable += 1
    var classes = r[6]
    for i in range(_len(classes)):
        var c = classes[i]
        out.exports += 1
        var blocked = Bool(py=c[0])
        var name = String(py=c[1])
        var returns = c[2]
        for j in range(_len(returns)):
            var ts = String("unknown")
            var hint = String(py=returns[j])
            if hint.byte_length() > 0:
                ts = to_ts_type(hint)
            for w in _words(ts, False):
                if w == name or w == "Self":
                    blocked = True
        if not blocked:
            out.bridgeable += 1
    return out^


# ---- bridge::js_only_reason --------------------------------------------------


def _is_word(b: UInt8, dollar: Bool) -> Bool:
    return (
        (b >= 48 and b <= 57)
        or (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
        or b == 95
        or (dollar and b == 36)
        or b >= 128
    )


def _words(t: String, dollar: Bool) -> List[String]:
    """`t` split at every character that is not alphanumeric, `_` (or `$`):
    the texts here are ASCII (analyze_py.py declines others)."""
    var out = List[String]()
    var bytes = t.as_bytes()
    var start = -1
    for i in range(len(bytes)):
        if _is_word(bytes[i], dollar):
            if start < 0:
                start = i
        elif start >= 0:
            out.append(String(t[byte=start:i]))
            start = -1
    if start >= 0:
        out.append(String(t[byte=start:]))
    return out^


def _js_shaped(types: List[String]) -> Bool:
    """js_only_reason's checks on the parameter and return types of a
    function with no blocker, no generator, no `instanceof`, no type
    parameters and no local types."""
    for t in types:
        if "=>" in t:
            return True
    for t in types:
        for w in _words(t, True):
            if (
                w == "RegExp"
                or w == "Generator"
                or w == "Iterator"
                or w == "IterableIterator"
                or w == "AsyncGenerator"
                or w == "AsyncIterable"
                or w == "Function"
            ):
                return True
    return False


def js_shaped(types: List[String]) -> Bool:
    return _js_shaped(types)


# ---- to_ts_type --------------------------------------------------------------


def _is_space(b: UInt8) -> Bool:
    return b == 32 or (b >= 9 and b <= 13)


def _trim(s: String) -> String:
    var bytes = s.as_bytes()
    var a = 0
    var b = len(bytes)
    while a < b and _is_space(bytes[a]):
        a += 1
    while b > a and _is_space(bytes[b - 1]):
        b -= 1
    return String(s[byte=a:b])


def _trim_quotes(s: String) -> String:
    var bytes = s.as_bytes()
    var a = 0
    var b = len(bytes)
    while a < b and (bytes[a] == 34 or bytes[a] == 39):
        a += 1
    while b > a and (bytes[b - 1] == 34 or bytes[b - 1] == 39):
        b -= 1
    return String(s[byte=a:b])


def _strip_typing(s: String) -> String:
    if s.startswith("typing."):
        return String(s[byte=7:])
    return s


def _split_top(text: String, sep: UInt8) -> List[String]:
    var out = List[String]()
    var depth = 0
    var bytes = text.as_bytes()
    var start = 0
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == 91 or c == 40:
            depth += 1
        elif c == 93 or c == 41:
            depth -= 1
        if c == sep and depth == 0:
            out.append(_trim(String(text[byte=start:i])))
            start = i + 1
    var last = _trim(String(text[byte=start:]))
    if last.byte_length() > 0:
        out.append(last)
    return out^


def _wrap(ts: String) -> String:
    if "|" in ts:
        return "(" + ts + ")"
    return ts


def _join(items: List[String], sep: String) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += sep
        out += items[i]
    return out^


def to_ts_type(given: String) -> String:
    """A Python type hint in the TS-like dialect (python.rs `to_ts_type`)."""
    var hint = _strip_typing(_trim_quotes(_trim(given)))
    var top = _split_top(hint, 124)
    if len(top) > 1:
        var parts = List[String]()
        for p in top:
            parts.append(to_ts_type(p))
        return _join(parts, " | ")
    var head = hint
    var args = List[String]()
    var open = hint.find("[")
    if open >= 0 and hint.endswith("]"):
        head = String(hint[byte=0:open])
        args = _split_top(
            String(hint[byte = open + 1 : hint.byte_length() - 1]), 44
        )
    head = _strip_typing(_trim(head))
    var a0 = String("unknown")
    var a1 = String("unknown")
    if len(args) > 0:
        a0 = to_ts_type(args[0])
    if len(args) > 1:
        a1 = to_ts_type(args[1])
    if head == "str":
        return "string"
    if head == "int":
        return "int"
    if head == "float":
        return "number"
    if head == "bool":
        return "boolean"
    if head == "None" or head == "NoneType":
        return "undefined"
    if (
        head == "list"
        or head == "List"
        or head == "Sequence"
        or head == "Iterable"
        or head == "MutableSequence"
        or head == "Collection"
    ):
        return _wrap(a0) + "[]"
    if head == "Optional":
        return a0 + " | undefined"
    if head == "Union":
        var parts = List[String]()
        for a in args:
            parts.append(to_ts_type(a))
        return _join(parts, " | ")
    if (
        head == "dict"
        or head == "Dict"
        or head == "Mapping"
        or head == "MutableMapping"
    ) and a0 == "string":
        return "Record<string, " + a1 + ">"
    if head == "Literal":
        var parts = List[String]()
        for a in args:
            parts.append(_trim(a).replace('"', "'"))
        return _join(parts, " | ")
    if head == "Callable":
        return "(...args: unknown[]) => unknown"
    if head == "Any" or head == "object":
        return "unknown"
    return head


# ---- resolution --------------------------------------------------------------


@fieldwise_init
struct Resolution(Copyable, Movable):
    var kind: Int
    var file: Int
    var name: String


def _try_module(base: String, index: Dict[String, Int]) raises -> Int:
    var bytes = base.as_bytes()
    var lo = 0
    var hi = len(bytes)
    while lo < hi and bytes[lo] == 47:
        lo += 1
    while hi > lo and bytes[hi - 1] == 47:
        hi -= 1
    var b = String(base[byte=lo:hi])
    var one = b + ".py"
    if one in index:
        return index[one]
    var two = b + "/__init__.py"
    if two in index:
        return index[two]
    return -1


def resolve(
    from_path: String,
    spec: String,
    index: Dict[String, Int],
    paths: List[String],
    roots: List[String],
) raises -> Resolution:
    """Where an import points (python.rs `resolve`); `roots` are the
    packages' source roots and "", sorted and deduplicated."""
    if spec.startswith("."):
        var bytes = spec.as_bytes()
        var dots = 0
        while dots < len(bytes) and bytes[dots] == 46:
            dots += 1
        var dir = List[String]()
        for p in from_path.split("/"):
            dir.append(String(p))
        if len(dir) > 0:
            _ = dir.pop()
        for _ in range(1, dots):
            if len(dir) > 0:
                _ = dir.pop()
        var rest = String(spec[byte=dots:]).replace(".", "/")
        var base = _join(dir, "/")
        if rest.byte_length() > 0:
            base = base + "/" + rest
        var i = _try_module(base, index)
        if i >= 0:
            return Resolution(FILE, i, "")
        return Resolution(UNRESOLVED, -1, "")
    var path = spec.replace(".", "/")
    for root in roots:
        var base = path
        if root.byte_length() > 0:
            base = root + "/" + path
        var i = _try_module(base, index)
        if i >= 0:
            return Resolution(FILE, i, "")
    var top = spec
    var dot = spec.find(".")
    if dot >= 0:
        top = String(spec[byte=0:dot])
    if top in stdlib():
        return Resolution(STDLIB, -1, "")
    for p in paths:
        if p.startswith(top + "/") or ("/" + top + "/") in p:
            return Resolution(UNRESOLVED, -1, "")
    return Resolution(EXTERNAL, -1, top.lower().replace("_", "-"))


def stdlib() -> List[String]:
    """python.rs STDLIB."""
    return [
        "__future__",
        "__main__",
        "_abc",
        "_aix_support",
        "_ast",
        "_asyncio",
        "_bisect",
        "_blake2",
        "_bz2",
        "_codecs",
        "_codecs_cn",
        "_codecs_hk",
        "_codecs_iso2022",
        "_codecs_jp",
        "_codecs_kr",
        "_codecs_tw",
        "_collections",
        "_collections_abc",
        "_compat_pickle",
        "_compression",
        "_contextvars",
        "_crypt",
        "_csv",
        "_ctypes",
        "_curses",
        "_curses_panel",
        "_datetime",
        "_dbm",
        "_decimal",
        "_elementtree",
        "_frozen_importlib",
        "_frozen_importlib_external",
        "_functools",
        "_gdbm",
        "_hashlib",
        "_heapq",
        "_imp",
        "_io",
        "_json",
        "_locale",
        "_lsprof",
        "_lzma",
        "_markupbase",
        "_md5",
        "_msi",
        "_multibytecodec",
        "_multiprocessing",
        "_opcode",
        "_operator",
        "_osx_support",
        "_overlapped",
        "_pickle",
        "_posixshmem",
        "_posixsubprocess",
        "_py_abc",
        "_pydatetime",
        "_pydecimal",
        "_pyio",
        "_pylong",
        "_queue",
        "_random",
        "_scproxy",
        "_sha1",
        "_sha2",
        "_sha3",
        "_signal",
        "_sitebuiltins",
        "_socket",
        "_sqlite3",
        "_sre",
        "_ssl",
        "_stat",
        "_statistics",
        "_string",
        "_strptime",
        "_struct",
        "_symtable",
        "_thread",
        "_threading_local",
        "_tkinter",
        "_tokenize",
        "_tracemalloc",
        "_typing",
        "_uuid",
        "_warnings",
        "_weakref",
        "_weakrefset",
        "_winapi",
        "_wmi",
        "_zoneinfo",
        "abc",
        "aifc",
        "antigravity",
        "argparse",
        "array",
        "ast",
        "asyncio",
        "atexit",
        "audioop",
        "base64",
        "bdb",
        "binascii",
        "bisect",
        "builtins",
        "bz2",
        "calendar",
        "cgi",
        "cgitb",
        "chunk",
        "cmath",
        "cmd",
        "code",
        "codecs",
        "codeop",
        "collections",
        "colorsys",
        "compileall",
        "concurrent",
        "configparser",
        "contextlib",
        "contextvars",
        "copy",
        "copyreg",
        "cProfile",
        "crypt",
        "csv",
        "ctypes",
        "curses",
        "dataclasses",
        "datetime",
        "dbm",
        "decimal",
        "difflib",
        "dis",
        "doctest",
        "email",
        "encodings",
        "ensurepip",
        "enum",
        "errno",
        "faulthandler",
        "fcntl",
        "filecmp",
        "fileinput",
        "fnmatch",
        "fractions",
        "ftplib",
        "functools",
        "gc",
        "genericpath",
        "getopt",
        "getpass",
        "gettext",
        "glob",
        "graphlib",
        "grp",
        "gzip",
        "hashlib",
        "heapq",
        "hmac",
        "html",
        "http",
        "idlelib",
        "imaplib",
        "imghdr",
        "importlib",
        "inspect",
        "io",
        "ipaddress",
        "itertools",
        "json",
        "keyword",
        "lib2to3",
        "linecache",
        "locale",
        "logging",
        "lzma",
        "mailbox",
        "mailcap",
        "marshal",
        "math",
        "mimetypes",
        "mmap",
        "modulefinder",
        "msilib",
        "msvcrt",
        "multiprocessing",
        "netrc",
        "nis",
        "nntplib",
        "nt",
        "ntpath",
        "nturl2path",
        "numbers",
        "opcode",
        "operator",
        "optparse",
        "os",
        "ossaudiodev",
        "pathlib",
        "pdb",
        "pickle",
        "pickletools",
        "pipes",
        "pkgutil",
        "platform",
        "plistlib",
        "poplib",
        "posix",
        "posixpath",
        "pprint",
        "profile",
        "pstats",
        "pty",
        "pwd",
        "py_compile",
        "pyclbr",
        "pydoc",
        "pydoc_data",
        "pyexpat",
        "queue",
        "quopri",
        "random",
        "re",
        "readline",
        "reprlib",
        "resource",
        "rlcompleter",
        "runpy",
        "sched",
        "secrets",
        "select",
        "selectors",
        "shelve",
        "shlex",
        "shutil",
        "signal",
        "site",
        "smtplib",
        "sndhdr",
        "socket",
        "socketserver",
        "spwd",
        "sqlite3",
        "sre_compile",
        "sre_constants",
        "sre_parse",
        "ssl",
        "stat",
        "statistics",
        "string",
        "stringprep",
        "struct",
        "subprocess",
        "sunau",
        "symtable",
        "sys",
        "sysconfig",
        "syslog",
        "tabnanny",
        "tarfile",
        "telnetlib",
        "tempfile",
        "termios",
        "test",
        "textwrap",
        "this",
        "threading",
        "time",
        "timeit",
        "tkinter",
        "token",
        "tokenize",
        "tomllib",
        "trace",
        "traceback",
        "tracemalloc",
        "tty",
        "turtle",
        "turtledemo",
        "types",
        "typing",
        "typing_extensions",
        "unicodedata",
        "unittest",
        "urllib",
        "uu",
        "uuid",
        "venv",
        "warnings",
        "wave",
        "weakref",
        "webbrowser",
        "winreg",
        "winsound",
        "wsgiref",
        "xdrlib",
        "xml",
        "xmlrpc",
        "zipapp",
        "zipfile",
        "zipimport",
        "zlib",
        "zoneinfo",
    ]
