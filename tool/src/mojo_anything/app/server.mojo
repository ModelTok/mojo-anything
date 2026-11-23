# `mojo-anything app record` and `app replay` of servers (port of
# src/http.rs): the requests are the curl lines of the repository's docs, an
# `--inputs` file and traps on their paths, queries and bodies; the server
# starts on a port of its own (py_server.mojo), every request goes to it in
# order, twice when recording, and the answers are settled, written in
# toml_edit's layout and compared as the Rust tool does. Anything this port
# cannot reproduce byte for byte goes to the Phase 1 binary: decided before
# the server starts, or, for an answer only the run shows, before anything is
# written.

from std.collections import Set
from std.python import Python, PythonObject

from mojo_anything.app.canon import _trim
from mojo_anything.app.cases import (
    CASES_DIR,
    CONFIG_FILE,
    REPORT_FILE,
    Config,
    decline,
    join,
    shell_tokens,
    words_quotable,
)
from mojo_anything.app.diff import Normalizers, compare
from mojo_anything.app.py import py_len, py_list, py_strings
from mojo_anything.app.record import (
    MAX_TRAPS,
    NOISE_NONE,
    NOISE_ORDER,
    NOISE_VALUES,
    Outcome,
    RecordSetup,
    _ascii_lower,
    _float_traps,
    _int_traps,
    _is_none,
    _json_traps,
    _lines,
    _merge_line,
    _pad3,
    _pjoin,
    _safe_words,
    _split_once,
    _split_slash,
    _stdin_traps,
    _string_traps,
    _write,
    config_json,
    doc_lines,
    given_slug,
    parses_f64,
    parses_i128,
    reserve_case_name,
    settle_text,
    slug,
    snapshot_to,
)
from mojo_anything.app.replay import (
    Failure,
    Problem,
    ReplaySetup,
    _comparable,
    report_markdown,
)
from mojo_anything.app.replay import Outcome as ReplayOutcome
from mojo_anything.cli_parse import Parsed
from mojo_anything.json_text import write_string
from mojo_anything.tolerance import line_matches_within

comptime HTTP_DIR = "http"
comptime FILES_DIR = "files"
comptime _MAX_PACE = 1_000_000_000
"""Milliseconds: a longer pace than Python's `sleep` is sure to take goes to
the Phase 1 binary."""


def _skip_header(k: String) -> Bool:
    """http.rs `SKIP_HEADERS`: never recorded or compared."""
    return (
        k == "date"
        or k == "host"
        or k == "server"
        or k == "connection"
        or k == "keep-alive"
        or k == "transfer-encoding"
        or k == "content-length"
        or k == "x-powered-by"
        or k == "etag"
        or k == "last-modified"
        or k == "age"
        or k == "via"
    )


def _ascii_eq_ignore_case(a: String, b: String) -> Bool:
    var x = a.as_bytes()
    var y = b.as_bytes()
    if len(x) != len(y):
        return False
    for i in range(len(x)):
        var p = x[i]
        var q = y[i]
        if p >= 65 and p <= 90:
            p += 32
        if q >= 65 and q <= 90:
            q += 32
        if p != q:
            return False
    return True


def _joined(parts: List[String], sep: String) -> String:
    var out = String("")
    for i in range(len(parts)):
        if i > 0:
            out += sep
        out += parts[i]
    return out


# --- a request ----------------------------------------------------------------------


struct Req(Copyable, Movable):
    """http.rs `Req`: headers as a BTreeMap, sorted by key."""

    var method: String
    var path: String
    var keys: List[String]
    var values: List[String]
    var has_body: Bool
    var body: String

    def __init__(out self, method: String, path: String):
        self.method = method
        self.path = path
        self.keys = List[String]()
        self.values = List[String]()
        self.has_body = False
        self.body = ""

    def find(self, k: String) -> Int:
        for i in range(len(self.keys)):
            if self.keys[i] == k:
                return i
        return -1

    def set(mut self, k: String, v: String):
        var at = self.find(k)
        if at >= 0:
            self.values[at] = v
            return
        at = 0
        while at < len(self.keys) and self.keys[at] < k:
            at += 1
        self.keys.insert(at, k)
        self.values.insert(at, v)

    def set_default(mut self, k: String, v: String):
        if self.find(k) < 0:
            self.set(k, v)

    def key(self) -> String:
        """The same text for requests serde_json serialises alike."""
        var out = write_string(self.method) + "," + write_string(self.path)
        for i in range(len(self.keys)):
            out += (
                ",h" + write_string(self.keys[i]) + write_string(self.values[i])
            )
        if self.has_body:
            out += ",b" + write_string(self.body)
        return out

    def py(self) raises -> PythonObject:
        var pairs = Python.list()
        for i in range(len(self.keys)):
            var pair = Python.list()
            pair.append(PythonObject(self.keys[i]))
            pair.append(PythonObject(self.values[i]))
            pairs.append(pair)
        var out = Python.list()
        out.append(PythonObject(self.method))
        out.append(PythonObject(self.path))
        out.append(pairs)
        out.append(
            PythonObject(self.body) if self.has_body else PythonObject(None)
        )
        return out


def _is_local(host: String) -> Bool:
    return (
        host == "localhost"
        or host == "127.0.0.1"
        or host == "0.0.0.0"
        or host == "[::1]"
    )


def _short_flags(arg: String) -> Bool:
    """`-sS`, `-fsSL`: curl's flags without a value, combined."""
    if not arg.startswith("-") or arg.startswith("--"):
        return False
    var b = arg.as_bytes()
    if len(b) < 2:
        return False
    for i in range(1, len(b)):
        var c = b[i]
        if not (
            c == 115
            or c == 83
            or c == 105
            or c == 118
            or c == 76
            or c == 102
            or c == 107
        ):
            return False
    return True


def _curl_file(
    h: PythonObject, name: String, repo: String, doc_dir: String
) raises -> Optional[String]:
    var rel = String(name[byte=1:])
    var c = Python.list()
    c.append(PythonObject(_pjoin(repo, rel)))
    c.append(PythonObject(_pjoin(doc_dir, rel)))
    var r = h["curl_file"](c)
    if _is_none(h, r):
        return None
    return String(py=r)


def _strip_crlf_nul(s: String) -> String:
    var out = String("")
    for c in s.codepoint_slices():
        var ch = String(c)
        if ch == "\r" or ch == "\n" or ch == chr(0):
            continue
        out += ch
    return out


def parse_curl(
    h: PythonObject, line: String, repo: String, doc_dir: String
) raises -> Optional[Req]:
    """http.rs `parse_curl`: a curl command line to a local server as a
    request, or None."""
    var parsed = shell_tokens(line)
    if not parsed:
        return None
    var toks = parsed.value().copy()
    for t in toks:
        if t.op:
            return None
    if len(toks) == 0 or toks[0].text != "curl":
        return None
    var args = List[String]()
    for i in range(1, len(toks)):
        args.append(toks[i].text)
    var method: Optional[String] = None
    var req = Req("", "")
    var data = List[String]()
    var url: Optional[String] = None
    var i = 0
    while i < len(args):
        var arg = args[i]
        if arg == "-X" or arg == "--request":
            i += 1
            if i >= len(args):
                return None
            method = args[i]
        elif arg == "-H" or arg == "--header":
            i += 1
            if i >= len(args):
                return None
            var kv = _split_once(args[i], ":")
            if not kv:
                return None
            req.set(_trim(kv.value()[0]), _trim(kv.value()[1]))
        elif (
            arg == "-d"
            or arg == "--data"
            or arg == "--data-raw"
            or arg == "--data-binary"
            or arg == "--data-ascii"
        ):
            i += 1
            if i >= len(args):
                return None
            var d = args[i]
            if d.startswith("@") and arg != "--data-raw":
                var contents = _curl_file(h, d, repo, doc_dir)
                if not contents:
                    return None
                var text = contents.value()
                if arg != "--data-binary":
                    text = _strip_crlf_nul(text)
                data.append(text)
            else:
                data.append(d)
        elif arg == "--json":
            i += 1
            if i >= len(args):
                return None
            var d = args[i]
            if d.startswith("@"):
                var contents = _curl_file(h, d, repo, doc_dir)
                if not contents:
                    return None
                data.append(contents.value())
            else:
                data.append(d)
            req.set_default("Content-Type", "application/json")
            req.set_default("Accept", "application/json")
        elif arg == "-A" or arg == "--user-agent":
            i += 1
            if i >= len(args):
                return None
            req.set("User-Agent", args[i])
        elif arg == "-b" or arg == "--cookie":
            i += 1
            if i >= len(args):
                return None
            req.set("Cookie", args[i])
        elif arg == "-e" or arg == "--referer":
            i += 1
            if i >= len(args):
                return None
            req.set("Referer", args[i])
        elif (
            arg == "-o"
            or arg == "--output"
            or arg == "-w"
            or arg == "--write-out"
            or arg == "-m"
            or arg == "--max-time"
            or arg == "--connect-timeout"
        ):
            i += 1
            if i >= len(args):
                return None
        elif (
            arg == "--silent"
            or arg == "--show-error"
            or arg == "--include"
            or arg == "--verbose"
            or arg == "--location"
            or arg == "--fail"
            or arg == "--insecure"
            or arg == "--no-progress-meter"
        ):
            pass
        elif arg.startswith("-X") and arg.byte_length() > 2:
            method = String(arg[byte=2:])
        elif arg.startswith("-H") and arg.byte_length() > 2:
            var kv = _split_once(String(arg[byte=2:]), ":")
            if not kv:
                return None
            req.set(_trim(kv.value()[0]), _trim(kv.value()[1]))
        elif _short_flags(arg):
            pass
        elif arg.startswith("-"):
            return None
        else:
            url = arg
        i += 1
    if not url:
        return None
    var scheme = String("http")
    var rest = url.value()
    var sp = _split_once(rest, "://")
    if sp:
        scheme = sp.value()[0]
        rest = sp.value()[1]
    if scheme != "http" and scheme != "https":
        return None
    var hash = rest.find("#")
    if hash >= 0:
        var cut_rest = String(rest[byte=0:hash])
        rest = cut_rest
    var cut = rest.byte_length()
    var rb = rest.as_bytes()
    for k in range(len(rb)):
        if rb[k] == 47 or rb[k] == 63:
            cut = k
            break
    var host = String(rest[byte=0:cut])
    var target = String(rest[byte=cut:])
    var path = target if target.startswith("/") else "/" + target
    if host.startswith("["):
        var close = host.find("]")
        if close >= 0:
            var cut_host = String(host[byte = 0 : close + 1])
            host = cut_host
    else:
        var colon = host.find(":")
        if colon >= 0:
            var cut_host = String(host[byte=0:colon])
            host = cut_host
    if not _is_local(host):
        return None
    var out = Req("", path)
    out.keys = req.keys.copy()
    out.values = req.values.copy()
    if len(data) > 0:
        out.has_body = True
        out.body = _joined(data, "&")
        var typed = False
        for k in out.keys:
            if _ascii_eq_ignore_case(k, "content-type"):
                typed = True
        if not typed:
            out.set("Content-Type", "application/x-www-form-urlencoded")
    if method:
        out.method = method.value()
    else:
        out.method = "POST" if out.has_body else "GET"
    return out^


@fieldwise_init
struct GivenReq(Copyable, Movable):
    var name: Optional[String]
    var req: Req


def read_inputs(h: PythonObject, path: String) raises -> List[GivenReq]:
    """http.rs `read_inputs`: one JSON request per line."""
    var r = h["read_text"](PythonObject(path))
    if String(py=r[0]) == "err":
        raise Error("reading " + path + ": " + String(py=r[1]))
    if String(py=r[0]) != "ok":
        raise decline()
    var out = List[GivenReq]()
    var lines = _lines(String(py=r[1]))
    for n in range(len(lines)):
        if _trim(lines[n]) == "":
            continue
        var v = h["http_input_line"](PythonObject(lines[n]))
        if _is_none(h, v):
            raise decline()
        var req = Req(String(py=v[1]), String(py=v[2]))
        var pairs = v[3]
        for k in range(py_len(pairs)):
            req.set(String(py=pairs[k][0]), String(py=pairs[k][1]))
        if Bool(py=v[4]):
            req.has_body = True
            req.body = String(py=v[5])
        if not req.path.startswith("/"):
            raise Error(
                path + ":" + String(n + 1) + ": `path` must start with /"
            )
        var name: Optional[String] = None
        if not _is_none(h, v[0]):
            name = String(py=v[0])
        out.append(GivenReq(name, req^))
    return out^


# --- traps --------------------------------------------------------------------------


def percent_encode(text: String) -> String:
    var hex = "0123456789ABCDEF".as_bytes()
    var out = String("")
    for b in text.as_bytes():
        var keep = (
            (b >= 48 and b <= 57)
            or (b >= 65 and b <= 90)
            or (b >= 97 and b <= 122)
            or b == 45
            or b == 46
            or b == 95
            or b == 126
        )
        if keep:
            out += chr(Int(b))
        else:
            out += "%" + chr(Int(hex[Int(b >> 4)])) + chr(Int(hex[Int(b & 15)]))
    return out


def _trap_values(raw: String) -> List[String]:
    if parses_i128(raw):
        return _int_traps()
    if parses_f64(raw) and (
        raw.find(".") >= 0 or raw.find("e") >= 0 or raw.find("E") >= 0
    ):
        return _float_traps()
    return _string_traps()


def traps(h: PythonObject, bases: List[Req]) raises -> List[Req]:
    """http.rs `traps`: each path segment after the first, each query value
    and each body replaced by the trap values of its kind."""
    var out = List[Req]()
    for base in bases:
        var path = base.path
        var query: Optional[String] = None
        var sp = _split_once(base.path, "?")
        if sp:
            path = sp.value()[0]
            query = sp.value()[1]
        var segs = _split_slash(path)
        for i in range(2, len(segs)):
            var raw = String(py=h["percent_decode"](PythonObject(segs[i])))
            for v in _trap_values(raw):
                if v == raw:
                    continue
                var parts = segs.copy()
                parts[i] = percent_encode(v)
                var r = base.copy()
                r.path = _joined(parts, "/")
                if query:
                    r.path += "?" + query.value()
                out.append(r^)
        if query:
            var pairs = List[String]()
            var qb = query.value().as_bytes()
            var start = 0
            for k in range(len(qb) + 1):
                if k == len(qb) or qb[k] == 38:
                    pairs.append(String(query.value()[byte=start:k]))
                    start = k + 1
            for i in range(len(pairs)):
                var kv = _split_once(pairs[i], "=")
                if not kv:
                    continue
                var raw = String(
                    py=h["percent_decode"](PythonObject(kv.value()[1]))
                )
                for v in _trap_values(raw):
                    if v == raw:
                        continue
                    var new = pairs.copy()
                    new[i] = kv.value()[0] + "=" + percent_encode(v)
                    var r = base.copy()
                    r.path = path + "?" + _joined(new, "&")
                    out.append(r^)
        if base.has_body:
            var kind = Int(
                py=h["json_container"](h["utf8"](PythonObject(base.body)))
            )
            if kind < 0:
                raise decline()
            var values = _json_traps() if kind == 1 else _stdin_traps()
            for v in values:
                var r = base.copy()
                r.has_body = True
                r.body = v
                out.append(r^)
    out.append(Req("GET", "/mojo-anything-missing"))
    while len(out) > MAX_TRAPS:
        _ = out.pop()
    return out^


def case_slug(req: Req) -> String:
    var first = String("root")
    var b = req.path.as_bytes()
    var start = 0
    for k in range(len(b) + 1):
        if k == len(b) or b[k] == 47 or b[k] == 63:
            if k > start:
                first = String(req.path[byte=start:k])
                break
            start = k + 1
    return slug(req.method + " " + first)


struct Plan(Movable):
    var names: List[String]
    var reqs: List[Req]
    var seen: Set[String]
    var taken: Set[String]
    var counts: List[Int]

    def __init__(out self):
        self.names = List[String]()
        self.reqs = List[Req]()
        self.seen = Set[String]()
        self.taken = Set[String]()
        self.counts = List[Int](length=3, fill=0)

    def push(mut self, kind: Int, given: Optional[String], req: Req) -> Bool:
        var key = req.key()
        if key in self.seen:
            return False
        self.seen.add(key)
        self.counts[kind] += 1
        var prefixes: List[String] = ["example", "input", "trap"]
        var name: String
        if given and given_slug(given.value()) != "":
            name = given_slug(given.value())
        else:
            name = (
                prefixes[kind]
                + "-"
                + _pad3(self.counts[kind])
                + "-"
                + case_slug(req)
            )
        name = reserve_case_name(self.taken, name, self.counts[kind])
        self.names.append(name)
        self.reqs.append(req.copy())
        return True

    def sort(mut self):
        """By name, as `sort_by` on the names (all distinct)."""
        for i in range(1, len(self.names)):
            var k = i
            while k > 0 and self.names[k] < self.names[k - 1]:
                var n = self.names[k]
                self.names[k] = self.names[k - 1]
                self.names[k - 1] = n
                var r = self.reqs[k].copy()
                self.reqs[k] = self.reqs[k - 1].copy()
                self.reqs[k - 1] = r^
                k -= 1


# --- the case files -------------------------------------------------------------------


comptime _BARE = 0
comptime _LITERAL = 1
comptime _BASIC = 2
comptime _ML_LITERAL = 3
comptime _ML_BASIC = 4


def _bare_byte(b: Byte) -> Bool:
    """toml_writer `is_bare_key_byte`: A-Z a-z 0-9 - _."""
    return (
        (b >= 48 and b <= 57)
        or (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
        or b == 45
        or b == 95
    )


def _toml_write(
    decoded: String, encoding: Int, subset: Bool, newline: Bool
) -> String:
    """A port of toml_writer 1.2.0's `write_toml_value` (string.rs), which
    toml_edit 0.25 calls for every key and string value."""
    var delimiter = String("")
    if encoding == _LITERAL:
        delimiter = "'"
    elif encoding == _BASIC:
        delimiter = '"'
    elif encoding == _ML_LITERAL:
        delimiter = "'''"
    elif encoding == _ML_BASIC:
        delimiter = '"""'
    if subset:
        return delimiter + decoded + delimiter
    var escaped = encoding == _BASIC or encoding == _ML_BASIC
    var is_ml = encoding == _ML_LITERAL or encoding == _ML_BASIC
    var out = delimiter
    if newline and is_ml:
        out += "\n"
    if not escaped:
        return out + decoded + delimiter
    var hex = "0123456789ABCDEF".as_bytes()
    var max_seq = 2 if is_ml else 0
    var b = decoded.as_bytes()
    var start = 0
    while start < len(b):
        var end = start
        var esc = String("")
        var has_esc = False
        var seq = 0
        var stop = False
        for i in range(start, len(b)):
            var c = b[i]
            if c == 34:
                seq += 1
                if max_seq < seq:
                    esc = '\\"'
                    has_esc = True
                    break
            else:
                seq = 0
            if c == 8:
                esc = "\\b"
                has_esc = True
                break
            elif c == 9:
                esc = "\\t"
                has_esc = True
                break
            elif c == 10:
                if not is_ml:
                    esc = "\\n"
                    has_esc = True
                    break
            elif c == 12:
                esc = "\\f"
                has_esc = True
                break
            elif c == 13:
                esc = "\\r"
                has_esc = True
                break
            elif c == 92:
                esc = "\\\\"
                has_esc = True
                break
            elif c != 34 and (c <= 0x1F or c == 0x7F):
                stop = True
                break
            end = i + 1
        out += String(decoded[byte=start:end]) + esc
        start = end + (1 if has_esc else 0)
        if stop and start < len(b):
            var c = b[start]
            out += (
                "\\u00"
                + chr(Int(hex[Int(c >> 4)]))
                + chr(Int(hex[Int(c & 15)]))
            )
            start += 1
    return out + delimiter


def toml_value(value: String) -> String:
    """A string value as toml_edit writes it: toml_writer's
    `TomlStringBuilder::as_default` (ValueMetrics, then the first of basic,
    literal, multi-line basic and multi-line literal that fits, else basic
    or multi-line basic with escapes)."""
    var b = value.as_bytes()
    var subset = True
    for c in b:
        if not (_bare_byte(c) or c == 46 or c == 47 or c == 32 or c == 58):
            subset = False
            break
    if subset:
        return _toml_write(value, _BASIC, True, False)
    var singles = 0
    var doubles = 0
    var max_singles = 0
    var max_doubles = 0
    var codes = False
    var backslash = False
    var newline = False
    for c in b:
        if c == 39:
            singles += 1
            max_singles = max(max_singles, singles)
        else:
            singles = 0
        if c == 34:
            doubles += 1
            max_doubles = max(max_doubles, doubles)
        else:
            doubles = 0
        if c == 92:
            backslash = True
        elif c == 9:
            pass
        elif c == 10:
            newline = True
        elif c <= 0x1F or c == 0x7F:
            codes = True
    if not codes and not backslash and max_doubles == 0 and not newline:
        return _toml_write(value, _BASIC, False, newline)
    if not codes and max_singles == 0 and not newline:
        return _toml_write(value, _LITERAL, False, newline)
    if not codes and not backslash and max_doubles <= 2:
        return _toml_write(value, _ML_BASIC, False, newline)
    if not codes and max_singles <= 2:
        return _toml_write(value, _ML_LITERAL, False, newline)
    if newline:
        return _toml_write(value, _ML_BASIC, False, newline)
    return _toml_write(value, _BASIC, False, newline)


def _toml_key(k: String) -> String:
    """A key as toml_edit writes it: toml_writer's
    `TomlKeyBuilder::as_default` (bare, then basic, literal, else basic with
    escapes)."""
    var bare = k != ""
    var singles = False
    var doubles = False
    var codes = False
    var backslash = False
    for c in k.as_bytes():
        if not _bare_byte(c):
            bare = False
        if c == 39:
            singles = True
        elif c == 34:
            doubles = True
        elif c == 92:
            backslash = True
        elif c == 9:
            pass
        elif c <= 0x1F or c == 0x7F:
            codes = True
    if bare:
        return _toml_write(k, _BARE, False, False)
    if not codes and not backslash and not doubles:
        return _toml_write(k, _BASIC, False, False)
    if not codes and not singles:
        return _toml_write(k, _LITERAL, False, False)
    return _toml_write(k, _BASIC, False, False)


def _table(keys: List[String], values: List[String]) raises -> String:
    var out = String("")
    for i in range(len(keys)):
        out += _toml_key(keys[i]) + " = " + toml_value(values[i]) + "\n"
    return out


def request_toml(req: Req) raises -> String:
    var out = "[request]\nmethod = " + toml_value(req.method) + "\n"
    out += "path = " + toml_value(req.path) + "\n"
    if req.has_body:
        out += "body = " + toml_value(req.body) + "\n"
    if len(req.keys) > 0:
        out += "\n[request.headers]\n" + _table(req.keys, req.values)
    return out


def response_toml(
    status: Int, binary: Bool, keys: List[String], values: List[String]
) raises -> String:
    var out = String("\n[response]\nstatus = ", status, "\n")
    if binary:
        out += "binary = true\n"
    if len(keys) > 0:
        out += "\n[response.headers]\n" + _table(keys, values)
    return out


# --- record ---------------------------------------------------------------------------


def _run(
    h: PythonObject,
    config: Config,
    command: List[String],
    repo: String,
    files: PythonObject,
    port: Optional[Int],
    reqs: PythonObject,
    timeout: Int,
) raises -> PythonObject:
    """`run_all`: the answers, the Rust tool's error, or a decline."""
    var p = PythonObject(port.value()) if port else h["free_port"]()
    var pace = PythonObject(
        config.http_pace.value()
    ) if config.http_pace else PythonObject(None)
    var r = h["run_server"](
        py_list(command),
        py_list(config.http_args),
        files,
        pace,
        config.effects_job(),
        PythonObject(repo),
        p,
        reqs,
        PythonObject(timeout),
    )
    var kind = String(py=r[0])
    if kind == "odd":
        raise decline()
    if kind == "error":
        raise Error(String(py=r[1]))
    return r[1]


def _launchable(h: PythonObject, config: Config) raises:
    """What Python's subprocess or `sleep` refuses where Rust passes it on,
    declined before the server starts."""
    if not _safe_words(h, config.http_args):
        raise decline()
    if config.http_pace and config.http_pace.value() > _MAX_PACE:
        raise decline()


@fieldwise_init
struct _Headers(Copyable, Movable):
    var keys: List[String]
    var values: List[String]
    var noisy: Bool


def _pairs(pairs: PythonObject) raises -> Tuple[List[String], List[String]]:
    var keys = List[String]()
    var values = List[String]()
    for i in range(py_len(pairs)):
        keys.append(String(py=pairs[i][0]))
        values.append(String(py=pairs[i][1]))
    return (keys^, values^)


def settle_headers(
    h: PythonObject, norm: Normalizers, a: PythonObject, b: PythonObject
) raises -> _Headers:
    var pa = _pairs(a)
    var pb = _pairs(b)
    var out = _Headers(List[String](), List[String](), False)
    for i in range(len(pa[0])):
        var k = pa[0][i]
        if _skip_header(k):
            continue
        var at = -1
        for j in range(len(pb[0])):
            if pb[0][j] == k:
                at = j
        if at < 0:
            out.noisy = True
            continue
        var va = norm.apply(h, pa[1][i])
        var vb = norm.apply(h, pb[1][at])
        out.keys.append(k)
        if va == vb:
            out.values.append(va)
        else:
            out.noisy = True
            out.values.append(_merge_line(h, va, vb))
    for j in range(len(pb[0])):
        var k = pb[0][j]
        if _skip_header(k):
            continue
        var found = False
        for i in range(len(pa[0])):
            if pa[0][i] == k:
                found = True
        if not found:
            out.noisy = True
    return out^


def record(h: PythonObject, p: Parsed, s: RecordSetup) raises -> Outcome:
    """http.rs `record`, then the settings: raises the Rust tool's errors, or
    `DECLINE`."""
    var repo = s.repo
    var config = s.config.copy()
    ref norm = s.norm
    var examples = List[Req]()
    for dl in doc_lines(h, repo):
        var r = parse_curl(h, dl.line, repo, dl.dir)
        if r:
            examples.append(r.value().copy())
    var inputs = List[GivenReq]()
    var given = p.value("inputs")
    if given:
        inputs = read_inputs(h, given.value())
    var plan = Plan()
    var bases = List[Req]()
    for req in examples:
        if plan.push(0, None, req):
            bases.append(req.copy())
    for g in inputs:
        if plan.push(1, g.name, g.req):
            bases.append(g.req.copy())
    if len(bases) == 0:
        var root = Req("GET", "/")
        _ = plan.push(0, None, root)
        bases.append(root^)
    if not p.flag("no-traps"):
        for req in traps(h, bases):
            _ = plan.push(2, None, req)
    plan.sort()

    # Before the server starts: what this port could not write or send.
    _launchable(h, config)
    var heads = List[String]()
    var reqs = Python.list()
    for req in plan.reqs:
        heads.append(request_toml(req))
        reqs.append(req.py())
    var dir = join(repo, CASES_DIR) + "/" + HTTP_DIR
    var files = PythonObject(None)
    if len(config.http_fresh) > 0:
        snapshot_to(h, repo, config.http_fresh, dir + "/" + FILES_DIR)
        files = PythonObject(dir + "/" + FILES_DIR)
    var one = _run(
        h,
        config,
        config.run,
        repo,
        files,
        config.http_port,
        reqs,
        config.timeout_secs,
    )
    var two = _run(
        h,
        config,
        config.run,
        repo,
        files,
        config.http_port,
        reqs,
        config.timeout_secs,
    )

    # Every case is settled and its TOML built before anything is written.
    var tomls = List[String]()
    var bodies = List[PythonObject]()
    var effects = List[PythonObject]()
    var noise_fields = List[List[String]]()
    var noise_kinds = List[List[Int]]()
    var unstable = List[Bool]()
    for k in range(len(plan.names)):
        var a = one[k]["resp"]
        var b = two[k]["resp"]
        var fields = List[String]()
        var kinds = List[Int]()
        if String(py=a[0]) != "ok" or String(py=b[0]) != "ok":
            tomls.append("")
            bodies.append(PythonObject(None))
            effects.append(PythonObject(None))
            noise_fields.append(fields^)
            noise_kinds.append(kinds^)
            unstable.append(False)
            continue
        var body = settle_text(h, norm, a[3], b[3])
        var heads2 = settle_headers(h, norm, a[2], b[2])
        var status = Int(py=a[1])
        tomls.append(
            heads[k]
            + response_toml(status, body.binary, heads2.keys, heads2.values)
        )
        bodies.append(body.data)
        if body.noise != NOISE_NONE:
            fields.append("body")
            kinds.append(body.noise)
        if heads2.noisy:
            fields.append("headers")
            kinds.append(NOISE_VALUES)
        var fa = one[k]["effects"]
        var fb = two[k]["effects"]
        if not _is_none(h, fa) and not _is_none(h, fb):
            var fx = settle_text(h, norm, fa, fb)
            effects.append(fx.data)
            if fx.noise != NOISE_NONE:
                fields.append("effects")
                kinds.append(fx.noise)
        else:
            effects.append(PythonObject(None))
        unstable.append(
            status != Int(py=b[1]) or (body.binary and body.noise != NOISE_NONE)
        )
        noise_fields.append(fields^)
        noise_kinds.append(kinds^)

    var outcome = Outcome(dir, config.run)
    outcome.examples = plan.counts[0]
    outcome.inputs = plan.counts[1]
    outcome.traps = plan.counts[2]
    var err = String(py=h["make_dirs"](PythonObject(dir)))
    if err != "":
        raise Error("creating " + dir + ": " + err)
    var unordered_cases = List[String]()
    var unordered_fields = List[List[String]]()
    for k in range(len(plan.names)):
        var name = plan.names[k]
        if tomls[k] == "":
            outcome.timed_out.append(name)
            continue
        _write(h, dir + "/" + name + ".toml", h["utf8"](PythonObject(tomls[k])))
        _write(h, dir + "/" + name + ".body", bodies[k])
        _ = h["remove_file"](PythonObject(dir + "/" + name + ".effects"))
        if not _is_none(h, effects[k]):
            _write(h, dir + "/" + name + ".effects", effects[k])
        outcome.cases += 1
        if len(noise_fields[k]) > 0:
            outcome.noisy.append(name)
        for i in range(len(noise_fields[k])):
            outcome.noise_cases.append(name)
            outcome.noise_fields.append(noise_fields[k][i])
            outcome.noise_kinds.append(noise_kinds[k][i])
            if noise_kinds[k][i] != NOISE_ORDER:
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
            unordered_fields[found].append(noise_fields[k][i])
        if unstable[k]:
            outcome.unstable.append(name)
    _write(
        h,
        join(repo, CASES_DIR) + "/" + CONFIG_FILE,
        h["utf8"](
            PythonObject(config_json(config, unordered_cases, unordered_fields))
        ),
    )
    return outcome^


# --- replay ---------------------------------------------------------------------------


struct Spec(Copyable, Movable):
    var name: String
    var req: Req
    var status: Int
    var keys: List[String]
    var values: List[String]
    var has_body: Bool
    var body: PythonObject
    var binary: Bool
    var has_effects: Bool
    var effects: PythonObject

    def __init__(out self, name: String) raises:
        self.name = name
        self.req = Req("GET", "/")
        self.status = 0
        self.keys = List[String]()
        self.values = List[String]()
        self.has_body = False
        self.body = PythonObject(None)
        self.binary = False
        self.has_effects = False
        self.effects = PythonObject(None)


def _read(h: PythonObject, path: String) raises -> PythonObject:
    var r = h["read_bytes"](PythonObject(path))
    if String(py=r[0]) != "ok":
        raise Error(String(py=r[1]))
    return r[1]


def load_spec(h: PythonObject, dir: String, file: String) raises -> Spec:
    var name = String(file[byte = 0 : file.byte_length() - 5])
    var path = dir + "/" + file
    var r = h["read_text"](PythonObject(path))
    if String(py=r[0]) == "err":
        raise Error("reading " + path + ": " + String(py=r[1]))
    if String(py=r[0]) != "ok":
        raise decline()
    var parsed = h["load_toml"](r[1])
    if String(py=parsed[0]) != "ok":
        raise decline()
    var d = h["http_spec"](parsed[1])
    if not Bool(py=d["has_request"]):
        raise Error("no [request]")
    if not Bool(py=d["has_response"]):
        raise Error("no [response]")
    var spec = Spec(name)
    var fx = dir + "/" + name + ".effects"
    if Bool(py=h["exists"](PythonObject(fx))):
        spec.effects = _read(h, fx)
        spec.has_effects = True
    if _is_none(h, d["path"]):
        raise Error(path + ": no request.path")
    spec.req = Req(String(py=d["method"]), String(py=d["path"]))
    var hp = _pairs(d["headers"])
    spec.req.keys = hp[0].copy()
    spec.req.values = hp[1].copy()
    if not _is_none(h, d["body"]):
        spec.req.has_body = True
        spec.req.body = String(py=d["body"])
    if _is_none(h, d["status"]):
        raise Error(path + ": no response.status")
    spec.status = Int(py=d["status"])
    var rp = _pairs(d["resp_headers"])
    spec.keys = rp[0].copy()
    spec.values = rp[1].copy()
    var body = dir + "/" + name + ".body"
    if Bool(py=h["exists"](PythonObject(body))):
        spec.body = _read(h, body)
        spec.has_body = True
    spec.binary = Bool(py=d["binary"])
    return spec^


def load_specs(h: PythonObject, dir: String) raises -> List[Spec]:
    var listed = h["toml_files"](PythonObject(dir))
    if String(py=listed[0]) != "ok":
        raise Error(
            "no HTTP cases in "
            + dir
            + ": run `mojo-anything app record` first: "
            + String(py=listed[1])
        )
    var names = listed[1]
    if not Bool(py=h["names_plain"](names)):
        raise decline()
    var out = List[Spec]()
    for i in range(py_len(names)):
        out.append(load_spec(h, dir, String(py=names[i])))
    if len(out) == 0:
        raise Error("no HTTP cases in " + dir)
    return out^


def _check(
    h: PythonObject, norm: Normalizers, spec: Spec, answer: PythonObject
) raises -> List[Problem]:
    var problems = List[Problem]()
    var resp = answer["resp"]
    if String(py=resp[0]) != "ok":
        problems.append(
            Problem("response", "no response: " + String(py=resp[1]) + "\n")
        )
    else:
        var status = Int(py=resp[1])
        if status != spec.status:
            problems.append(
                Problem(
                    "status",
                    String("expected ", spec.status, ", got ", status, "\n"),
                )
            )
        var got = _pairs(resp[2])
        for i in range(len(spec.keys)):
            var k = spec.keys[i]
            var field = "header " + k
            var lower = _ascii_lower(k)
            var at = -1
            for j in range(len(got[0])):
                if got[0][j] == lower:
                    at = j
            if at < 0:
                problems.append(
                    Problem(field, "- " + spec.values[i] + "\n(missing)\n")
                )
                continue
            var e = norm.apply(h, spec.values[i])
            var a = norm.apply(h, got[1][at])
            if not line_matches_within(e, a, None):
                problems.append(Problem(field, "- " + e + "\n+ " + a + "\n"))
        if spec.has_body:
            var d = compare(
                h,
                norm,
                spec.body,
                resp[3],
                spec.binary,
                norm.is_unordered(spec.name, "body"),
            )
            if d:
                problems.append(Problem("body", d.value()))
    if spec.has_effects:
        var fx = answer["effects"]
        var d = compare(
            h,
            norm,
            spec.effects,
            h["utf8"](PythonObject("")) if _is_none(h, fx) else fx,
            False,
            norm.is_unordered(spec.name, "effects"),
        )
        if d:
            problems.append(Problem("effects", d.value()))
    return problems^


comptime _MAX_TIMEOUT = 2_000_000


def replay(
    h: PythonObject,
    s: ReplaySetup,
    port: Optional[Int],
    only: Optional[String],
) raises -> ReplayOutcome:
    """http.rs `replay`."""
    ref config = s.config
    ref norm = s.norm
    var dir = join(s.repo, CASES_DIR)
    var all = load_specs(h, dir + "/" + HTTP_DIR)
    var specs = List[Spec]()
    if only:
        var names = String("")
        for i in range(len(all)):
            if i > 0:
                names += ", "
            names += all[i].name
            if all[i].name == only.value():
                specs.append(all[i].copy())
        if len(specs) == 0:
            raise Error(
                "no case named " + only.value() + "; the cases are: " + names
            )
    else:
        specs = all^
    var chosen = port if port else config.http_port
    var files = PythonObject(None)
    if len(config.http_fresh) > 0:
        var fd = dir + "/" + HTTP_DIR + "/" + FILES_DIR
        if not Bool(py=h["is_dir"](PythonObject(fd))):
            raise Error(
                "no " + fd + ": record again to snapshot the fresh files"
            )
        files = PythonObject(fd)
    # Before the build starts: what this port could not send, compare or
    # report as the Rust tool would.
    if s.timeout <= 0 or s.timeout > _MAX_TIMEOUT:
        raise decline()
    if not _safe_words(h, s.command) or not words_quotable(h, s.command):
        raise decline()
    _launchable(h, config)
    var reqs = Python.list()
    for spec in specs:
        var args: List[String] = [spec.req.method, spec.req.path]
        if not words_quotable(h, args):
            raise decline()
        for v in spec.values:
            _ = norm.apply(h, v)
        if spec.has_body and not _comparable(h, norm, spec.body, spec.binary):
            raise decline()
        if spec.has_effects and not _comparable(h, norm, spec.effects, False):
            raise decline()
        reqs.append(spec.req.py())
    var answers = _run(
        h, config, s.command, s.repo, files, chosen, reqs, s.timeout
    )
    var outcome = ReplayOutcome(s.command.copy(), dir + "/" + REPORT_FILE)
    for i in range(len(specs)):
        ref spec = specs[i]
        var answer = answers[i]
        outcome.total += 1
        var fell = answer["fallback"]
        if not _is_none(h, fell):
            outcome.reported = True
            if Bool(py=fell):
                outcome.fell_back.append(spec.name)
        var problems = _check(h, norm, spec, answer)
        if len(problems) == 0:
            outcome.passed += 1
        else:
            var args: List[String] = [spec.req.method, spec.req.path]
            outcome.failures.append(Failure(spec.name, args^, problems^))
    var text = report_markdown(h, outcome)
    var err = String(
        py=h["write_bytes"](
            PythonObject(outcome.report), h["utf8"](PythonObject(text))
        )
    )
    if err != "":
        raise Error("writing " + outcome.report + ": " + err)
    return outcome^
