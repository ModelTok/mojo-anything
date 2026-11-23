# Codex's `config.toml` edited as text, with the result toml_edit (which the
# Rust tool uses) gives: `[mcp_servers.mojo-anything]` is added after the
# table toml_edit would put it after, updated in place or removed with the
# comments and blank lines above its header, and every other line stays as it
# was. Shapes whose toml_edit output this does not reproduce (an inline or
# dotted `mojo-anything` entry, subtables of it, arrays of tables, multi-line
# strings, CR LF line ends, a command that needs escaping) are reported as
# unsupported, and `setup` hands the command to the Phase 1 binary.

comptime NAME = "mojo-anything"
comptime SERVERS = "mcp_servers"

comptime _BLANK = 0
comptime _COMMENT = 1
comptime _HEADER = 2
comptime _KV = 3
comptime _CONT = 4


struct CodexEdit(Copyable, Movable):
    var supported: Bool
    var text: String
    var inline_servers: Bool
    """`mcp_servers = { ... }` at the top: toml_edit's "not a table"."""
    var action: String
    """Set by `setup`: what the edit does."""

    def __init__(out self, supported: Bool, text: String):
        self.supported = supported
        self.text = text
        self.inline_servers = False
        self.action = ""


@fieldwise_init
struct _Key(Copyable, Movable):
    var parts: List[String]
    var end: Int
    """The byte offset after the key."""
    var ok: Bool


def _is_bare(b: UInt8) -> Bool:
    return (
        (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
        or (b >= 48 and b <= 57)
        or b == 45
        or b == 95
    )


def _skip_ws(s: Span[UInt8, _], var i: Int) -> Int:
    while i < len(s) and (s[i] == 32 or s[i] == 9):
        i += 1
    return i


def _key(line: String, start: Int) -> _Key:
    """A dotted key from `start`: bare, "basic" or 'literal' parts."""
    var s = line.as_bytes()
    var parts = List[String]()
    var i = _skip_ws(s, start)
    while True:
        if i >= len(s):
            return _Key(parts^, i, False)
        if s[i] == 34 or s[i] == 39:
            var q = s[i]
            var j = i + 1
            while j < len(s) and s[j] != q:
                if q == 34 and s[j] == 92:
                    # Escapes are not decoded: a key that needs them is
                    # compared by its text, which only matters for keys
                    # spelled two ways.
                    j += 1
                j += 1
            if j >= len(s):
                return _Key(parts^, j, False)
            parts.append(String(line[byte = i + 1 : j]))
            i = j + 1
        else:
            var j = i
            while j < len(s) and _is_bare(s[j]):
                j += 1
            if j == i:
                return _Key(parts^, i, False)
            parts.append(String(line[byte=i:j]))
            i = j
        i = _skip_ws(s, i)
        if i < len(s) and s[i] == 46:
            i = _skip_ws(s, i + 1)
            continue
        return _Key(parts^, i, True)


@fieldwise_init
struct _Scan(Copyable, Movable):
    var depth: Int
    var multiline: Bool
    """A multi-line string started: not supported."""
    var bad: Bool


def _scan_value(line: String, start: Int, depth: Int) -> _Scan:
    """Brackets still open after a value's text on this line."""
    var s = line.as_bytes()
    var d = depth
    var i = start
    while i < len(s):
        var b = s[i]
        if b == 35:
            break
        if b == 34 or b == 39:
            if i + 2 < len(s) and s[i + 1] == b and s[i + 2] == b:
                return _Scan(d, True, False)
            var j = i + 1
            while j < len(s) and s[j] != b:
                if b == 34 and s[j] == 92:
                    j += 1
                j += 1
            if j >= len(s):
                return _Scan(d, False, True)
            i = j + 1
            continue
        if b == 91 or b == 123:
            d += 1
        elif b == 93 or b == 125:
            d -= 1
        i += 1
    return _Scan(d, False, False)


@fieldwise_init
struct _Line(Copyable, Movable):
    var kind: Int
    var path: List[String]
    """A header's table path, or a key-value's key."""
    var eq: Int
    """For a key-value: the byte offset of its `=`."""
    var end: Int
    """For a key-value: its last line."""


@fieldwise_init
struct _Node(Copyable, Movable):
    var key: String
    var children: List[Int]
    var header: Int
    """The line of its `[header]`, or -1 for an implicit table."""


def _child(mut nodes: List[_Node], parent: Int, key: String) -> Int:
    for c in nodes[parent].children:
        if nodes[c].key == key:
            return c
    nodes.append(_Node(key, List[Int](), -1))
    var n = len(nodes) - 1
    nodes[parent].children.append(n)
    return n


def _descend(
    mut nodes: List[_Node], start: Int, path: List[String], upto: Int
) -> Int:
    var n = start
    for i in range(upto):
        n = _child(nodes, n, path[i])
    return n


def _dfs(
    nodes: List[_Node], n: Int, target: Int, mut last: Int, mut found: Int
):
    """toml_edit's table order: depth first in key order; a table without a
    position takes the position of the last one visited."""
    if found != -2:
        return
    if nodes[n].header >= 0:
        last = nodes[n].header
    if n == target:
        found = last
        return
    for c in nodes[n].children:
        _dfs(nodes, c, target, last, found)


def _repr(command: String) -> Optional[String]:
    for b in command.as_bytes():
        if b == 34 or b == 92 or b < 32 or b == 127:
            return None
    return '"' + command + '"'


def _is_name_path(path: List[String]) -> Bool:
    return len(path) >= 2 and path[0] == SERVERS and path[1] == NAME


def codex_edit(text: String, command: String, action: String) -> CodexEdit:
    """`text` with `action` (`added`, `updated`, `removed`; anything else
    leaves it) applied to `[mcp_servers.mojo-anything]`."""
    var unsupported = CodexEdit(False, text)
    if "\r" in text:
        return unsupported^
    var lines = List[String]()
    var last_nl = text.endswith("\n")
    if text != "":
        var body = String(
            text[byte = 0 : text.byte_length() - 1]
        ) if last_nl else text
        for l in body.split("\n"):
            lines.append(String(l))
    # Classify every line.
    var info = List[_Line]()
    var depth = 0
    var i = 0
    while i < len(lines):
        ref line = lines[i]
        var s = line.as_bytes()
        var at = _skip_ws(s, 0)
        if depth > 0:
            var sc = _scan_value(line, 0, depth)
            if sc.multiline or sc.bad:
                return unsupported^
            depth = sc.depth
            info.append(_Line(_CONT, List[String](), -1, -1))
            i += 1
            continue
        if at >= len(s):
            info.append(_Line(_BLANK, List[String](), -1, -1))
        elif s[at] == 35:
            info.append(_Line(_COMMENT, List[String](), -1, -1))
        elif s[at] == 91:
            if at + 1 < len(s) and s[at + 1] == 91:
                return unsupported^
            var k = _key(line, at + 1)
            if not k.ok or k.end >= len(s) or s[k.end] != 93:
                return unsupported^
            var rest = _skip_ws(s, k.end + 1)
            if rest < len(s) and s[rest] != 35:
                return unsupported^
            info.append(_Line(_HEADER, k.parts.copy(), -1, -1))
        else:
            var k = _key(line, at)
            if not k.ok or k.end >= len(s) or s[k.end] != 61:
                return unsupported^
            var sc = _scan_value(line, k.end + 1, 0)
            if sc.multiline or sc.bad:
                return unsupported^
            depth = sc.depth
            info.append(_Line(_KV, k.parts.copy(), k.end, i))
        i += 1
    if depth != 0:
        return unsupported^
    # Each key-value's last line.
    for j in range(len(info)):
        if info[j].kind == _KV:
            var e = j
            while e + 1 < len(info) and info[e + 1].kind == _CONT:
                e += 1
            info[j].end = e
    # The table tree, and where `mojo-anything` is defined.
    var nodes = List[_Node]()
    nodes.append(_Node("", List[Int](), -1))
    var table = 0
    var table_path = List[String]()
    var ours = -1
    for j in range(len(info)):
        if info[j].kind == _HEADER:
            ref path = info[j].path
            if _is_name_path(path):
                if len(path) > 2 or ours >= 0:
                    return unsupported^
                ours = j
            table = _descend(nodes, 0, path, len(path))
            nodes[table].header = j
            table_path = path.copy()
        elif info[j].kind == _KV:
            var full = table_path.copy()
            for p in info[j].path:
                full.append(p)
            if len(table_path) == 0 and len(full) == 1 and full[0] == SERVERS:
                var r = CodexEdit(False, text)
                r.inline_servers = True
                return r^
            if _is_name_path(full) and len(table_path) < 2:
                # An inline or dotted entry.
                return unsupported^
            if len(table_path) == 0 and len(full) > 1 and full[0] == SERVERS:
                return unsupported^
            if len(info[j].path) > 1:
                _ = _descend(nodes, table, info[j].path, len(info[j].path) - 1)
    if action != "added" and action != "updated" and action != "removed":
        return CodexEdit(True, text)
    var cmd = _repr(command)
    if not cmd:
        return unsupported^
    # toml_edit ends every key-value and header line with a newline; only
    # the comments and blank lines after the last one keep the file's end.
    var tail_nl = last_nl
    if len(info) > 0 and info[len(info) - 1].kind != _BLANK:
        if info[len(info) - 1].kind != _COMMENT:
            tail_nl = True
    var out = List[String]()
    if action == "added":
        if ours >= 0:
            return unsupported^
        var servers = _child(nodes, 0, SERVERS)
        var target = _child(nodes, servers, NAME)
        var last = -1
        var found = -2
        _dfs(nodes, 0, target, last, found)
        # After the content of the table it takes the position of.
        var after: Int
        var first = False
        if found < 0:
            after = -1
            for j in range(len(info)):
                if info[j].kind == _HEADER:
                    break
                if info[j].kind == _KV:
                    after = info[j].end
            first = after < 0
        else:
            after = found
            var j = found + 1
            while j < len(info) and info[j].kind != _HEADER:
                if info[j].kind == _KV:
                    after = info[j].end
                j += 1
        for j in range(after + 1):
            out.append(lines[j])
        if not first:
            out.append("")
        out.append("[mcp_servers.mojo-anything]")
        out.append("command = " + cmd.value())
        out.append('args = ["mcp"]')
        for j in range(after + 1, len(lines)):
            out.append(lines[j])
        last_nl = True if after + 1 == len(lines) else tail_nl
    else:
        if ours < 0:
            return unsupported^
        # The header's own lines: the comments and blank lines above it.
        var top = ours
        while top > 0 and (
            info[top - 1].kind == _BLANK or info[top - 1].kind == _COMMENT
        ):
            top -= 1
        var end = ours
        var j = ours + 1
        while j < len(info) and info[j].kind != _HEADER:
            if info[j].kind == _KV:
                end = info[j].end
            j += 1
        for k in range(top):
            out.append(lines[k])
        if action == "updated":
            for k in range(top, ours + 1):
                out.append(lines[k])
            var have_command = False
            var have_args = False
            var k = ours + 1
            var pending = List[String]()
            while k <= end:
                if info[k].kind == _KV:
                    var key = info[k].path.copy()
                    var single = len(key) == 1
                    if single and key[0] == "command":
                        for p in pending:
                            out.append(p)
                        var head = String(lines[k][byte = 0 : info[k].eq + 1])
                        out.append(head + " " + cmd.value())
                        have_command = True
                    elif single and key[0] == "args":
                        for p in pending:
                            out.append(p)
                        var head = String(lines[k][byte = 0 : info[k].eq + 1])
                        out.append(head + ' ["mcp"]')
                        have_args = True
                    elif single and key[0] == "url":
                        pass
                    else:
                        for p in pending:
                            out.append(p)
                        for m in range(k, info[k].end + 1):
                            out.append(lines[m])
                    pending.clear()
                    k = info[k].end + 1
                    continue
                pending.append(lines[k])
                k += 1
            if not have_command:
                out.append("command = " + cmd.value())
            if not have_args:
                out.append('args = ["mcp"]')
        for k in range(end + 1, len(lines)):
            out.append(lines[k])
        last_nl = True if end + 1 == len(lines) else tail_nl
    var result = String("")
    for k in range(len(out)):
        if k > 0:
            result += "\n"
        result += out[k]
    if last_nl and len(out) > 0:
        result += "\n"
    return CodexEdit(True, result)
