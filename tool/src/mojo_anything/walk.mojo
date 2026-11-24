# Canonical paths and directory walks that read ignore files the way the Rust
# tool's `walk::builder` does (port of src/walk.rs and of the `ignore` crate's
# rules with the settings it sets: hidden entries skipped, `.ignore`,
# `.gitignore` and `.git/info/exclude` read, git rules only inside a git
# repository unless `require_git` is off, and `.gitignore` files in folders
# between the repository root and the walked folder applied too, but never from
# folders above the repository).

from std.ffi import external_call
from std.memory import Pointer
from std.os import listdir
from std.os.path import exists, isdir, isfile, islink

comptime _Bytes = Pointer[UInt8, MutAnyOrigin]
comptime MANIFEST = "mojo-anything.json"
comptime _NONE = 0
comptime _IGNORE = 1
comptime _WHITELIST = 2


def _cstr(s: String) -> _Bytes:
    var bytes = s.as_bytes()
    var n = len(bytes)
    # SAFETY: malloc returns `n + 1` writable bytes; `value()` aborts on NULL.
    var p = external_call["malloc", Optional[_Bytes]](n + 1).value()
    for i in range(n):
        p[unsafe_offset=i] = bytes[i]
    p[unsafe_offset=n] = 0
    return p


def _free(p: _Bytes):
    # SAFETY: `p` came from malloc and is freed once.
    external_call["free", NoneType](p)


def _from_c(p: _Bytes) -> String:
    var n = 0
    while p[unsafe_offset=n] != 0:
        n += 1
    return String(
        unsafe_from_utf8=Span[UInt8, ImmutAnyOrigin](unsafe_ptr=p, length=n)
    )


def _cwd() -> String:
    var size = 4096
    # SAFETY: room for `size` bytes; `value()` aborts on NULL.
    var buf = external_call["malloc", Optional[_Bytes]](size).value()
    var out = String("/")
    # SAFETY: `buf` holds `size` writable bytes; getcwd writes a NUL-terminated
    # path into it or returns NULL.
    var got = external_call["getcwd", Optional[_Bytes]](buf, size)
    if got:
        out = _from_c(buf)
    _free(buf)
    return out


def clean(path: String) -> String:
    """`path` made absolute (against the working folder) with `.`, `..` and
    repeated slashes taken out by its words, as a path that does not exist
    reads."""
    var full = path
    if not path.startswith("/"):
        full = _cwd() + "/" + path
    var parts = List[String]()
    for word in full.split("/"):
        var w = String(word)
        if w.byte_length() == 0 or w == ".":
            continue
        if w == "..":
            if len(parts) > 0:
                _ = parts.pop()
            continue
        parts.append(w)
    var out = String("")
    for p in parts:
        out += "/" + p
    if out.byte_length() == 0:
        return "/"
    return out


def canonical(path: String) -> String:
    """The real path: `..` and symlinks resolved, as `realpath(3)`; a path
    that does not exist is cleaned by its words instead (`clean`)."""
    var cpath = _cstr(path)
    # SAFETY: room for PATH_MAX (4096) bytes; `value()` aborts on NULL.
    var buf = external_call["malloc", Optional[_Bytes]](4096).value()
    # SAFETY: `cpath` is NUL-terminated and `buf` holds PATH_MAX bytes;
    # realpath returns `buf` or NULL.
    var got = external_call["realpath", Optional[_Bytes]](cpath, buf)
    var out: String
    if got:
        out = _from_c(buf)
    else:
        out = clean(path)
    _free(buf)
    _free(cpath)
    return out


def _dir_of(path: String) -> String:
    var slash = path.rfind("/")
    if slash <= 0:
        return "/"
    return String(path[byte=0:slash])


def _name_of(path: String) -> String:
    var slash = path.rfind("/")
    return String(path[byte = slash + 1 :])


# --- gitignore patterns ---------------------------------------------------


@fieldwise_init
struct Pattern(Copyable, Movable):
    var glob: String
    var whitelist: Bool
    var dir_only: Bool


@fieldwise_init
struct Matcher(Copyable, Movable):
    """The patterns of one ignore file, matched against paths relative to its
    folder `root`. Empty when there is no such file."""

    var root: String
    var patterns: List[Pattern]

    def __init__(out self):
        self.root = ""
        self.patterns = List[Pattern]()

    def matched(self, path: String, is_dir: Bool) -> Int:
        """`_IGNORE`, `_WHITELIST` or `_NONE` for `path` (absolute, under
        `root`): the last pattern that matches decides."""
        if len(self.patterns) == 0:
            return _NONE
        var rel = path
        if path.startswith(self.root + "/"):
            rel = String(path[byte = self.root.byte_length() + 1 :])
        var i = len(self.patterns) - 1
        while i >= 0:
            ref p = self.patterns[i]
            if (not p.dir_only or is_dir) and glob_match(p.glob, rel):
                return _WHITELIST if p.whitelist else _IGNORE
            i -= 1
        return _NONE


def _trim_trailing_spaces(line: String) -> String:
    var bytes = line.as_bytes()
    var end = len(bytes)
    while end > 0 and bytes[end - 1] == 32:
        if end >= 2 and bytes[end - 2] == 92:
            break
        end -= 1
    return String(line[byte=0:end])


def _cut(s: String, start: Int, end: Int) -> String:
    return String(s[byte=start:end])


def parse_ignore(text: String) -> List[Pattern]:
    """The patterns of a `.gitignore` text, as the `ignore` crate reads them."""
    var out = List[Pattern]()
    for raw in text.split("\n"):
        var line = String(raw)
        if line.endswith("\r"):
            line = _cut(line, 0, line.byte_length() - 1)
        if line.startswith("#"):
            continue
        line = _trim_trailing_spaces(line)
        if line.byte_length() == 0:
            continue
        var whitelist = False
        var absolute = False
        if line.startswith("\\!") or line.startswith("\\#"):
            line = _cut(line, 1, line.byte_length())
            absolute = line.startswith("/")
        else:
            if line.startswith("!"):
                whitelist = True
                line = _cut(line, 1, line.byte_length())
            if line.startswith("/"):
                line = _cut(line, 1, line.byte_length())
                absolute = True
        var dir_only = False
        if line.endswith("/"):
            dir_only = True
            line = _cut(line, 0, line.byte_length() - 1)
            if line.endswith("\\"):
                line = _cut(line, 0, line.byte_length() - 1)
        if line.byte_length() == 0:
            continue
        var glob = line
        if not absolute and line.find("/") < 0:
            if not glob.startswith("**/"):
                glob = "**/" + glob
        if glob.endswith("/**"):
            glob += "/*"
        out.append(Pattern(glob=glob, whitelist=whitelist, dir_only=dir_only))
    return out^


def _class_match(p: Span[UInt8, _], var i: Int, c: UInt8, mut end: Int) -> Bool:
    """Matches byte `c` against the class starting after `[` at `i`; sets
    `end` to the index after `]`. A class with no `]` matches nothing."""
    var negate = False
    if i < len(p) and (p[i] == 33 or p[i] == 94):
        negate = True
        i += 1
    var found = False
    var first = True
    while i < len(p) and (first or p[i] != 93):
        first = False
        var lo = p[i]
        if lo == 92 and i + 1 < len(p):
            i += 1
            lo = p[i]
        var hi = lo
        if i + 2 < len(p) and p[i + 1] == 45 and p[i + 2] != 93:
            hi = p[i + 2]
            i += 2
        if c >= lo and c <= hi:
            found = True
        i += 1
    if i >= len(p):
        end = -1
        return False
    end = i + 1
    return found != negate


def _glob(p: Span[UInt8, _], i: Int, s: Span[UInt8, _], j: Int) -> Bool:
    if i == len(p):
        return j == len(s)
    var at_segment = i == 0 or p[i - 1] == 47
    if p[i] == 42 and i + 1 < len(p) and p[i + 1] == 42 and at_segment:
        if i + 2 == len(p):
            return True
        if p[i + 2] == 47:
            # `**/`: zero or more whole folders.
            if _glob(p, i + 3, s, j):
                return True
            for k in range(j, len(s)):
                if s[k] == 47 and _glob(p, i + 3, s, k + 1):
                    return True
            return False
    if p[i] == 42:
        var next = i + 1
        while next < len(p) and p[next] == 42:
            next += 1
        var k = j
        while True:
            if _glob(p, next, s, k):
                return True
            if k >= len(s) or s[k] == 47:
                return False
            k += 1
    if j >= len(s):
        return False
    if p[i] == 63:
        return s[j] != 47 and _glob(p, i + 1, s, j + 1)
    if p[i] == 91:
        var end = 0
        if s[j] != 47 and _class_match(p, i + 1, s[j], end) and end > 0:
            return _glob(p, end, s, j + 1)
        if end < 0:
            return s[j] == 91 and _glob(p, i + 1, s, j + 1)
        return False
    if p[i] == 92 and i + 1 < len(p):
        return p[i + 1] == s[j] and _glob(p, i + 2, s, j + 1)
    return p[i] == s[j] and _glob(p, i + 1, s, j + 1)


def glob_match(pattern: String, path: String) -> Bool:
    """gitignore glob matching: `*`, `?` and classes stay within a folder
    name, `**/` spans folders, a trailing `/**` everything below."""
    return _glob(pattern.as_bytes(), 0, path.as_bytes(), 0)


def _read_matcher(dir: String, file: String) -> Matcher:
    var path = dir + "/" + file
    if not isfile(path):
        return Matcher()
    try:
        var text = open(path, "r").read()
        return Matcher(root=dir, patterns=parse_ignore(text))
    except:
        return Matcher()


# --- walks ----------------------------------------------------------------


@fieldwise_init
struct _Level(Copyable, Movable):
    var dir: String
    var has_git: Bool
    var dot_ignore: Matcher
    var git_ignore: Matcher
    var exclude: Matcher


def _level(dir: String) -> _Level:
    var has_git = exists(dir + "/.git")
    var exclude = Matcher()
    if has_git:
        exclude = _read_matcher(dir + "/.git/info", "exclude")
        exclude.root = dir
    return _Level(
        dir=dir,
        has_git=has_git,
        dot_ignore=_read_matcher(dir, ".ignore"),
        git_ignore=_read_matcher(dir, ".gitignore"),
        exclude=exclude^,
    )


@fieldwise_init
struct _Outer(Copyable, Movable):
    """`.gitignore` files in the folders between the repository root and the
    walked folder (the walk itself reads only the walked folder and below)."""

    var root: String
    var base: String
    var matchers: List[Matcher]

    def ignores(self, path: String, is_dir: Bool) -> Bool:
        var rel = String(path[byte = self.root.byte_length() :])
        var full = self.base + rel
        for m in self.matchers:
            var found = m.matched(full, is_dir)
            if found == _IGNORE:
                return True
            if found == _WHITELIST:
                return False
        return False


def _outer(root: String) -> _Outer:
    var base = canonical(root)
    var none = _Outer(root=root, base=base, matchers=List[Matcher]())
    if exists(base + "/.git"):
        return none^
    var found = False
    var d = base
    var chain = List[String]()
    while d != "/":
        d = _dir_of(d)
        chain.append(d)
        if exists(d + "/.git"):
            found = True
            break
    if not found:
        return none^
    var matchers = List[Matcher]()
    for dir in chain:
        var m = _read_matcher(dir, ".gitignore")
        if len(m.patterns) > 0:
            matchers.append(m^)
    return _Outer(root=root, base=base, matchers=matchers^)


def _git_above(root: String) -> Bool:
    var d = canonical(root)
    while d != "/":
        d = _dir_of(d)
        if exists(d + "/.git"):
            return True
    return False


def _ignored(
    levels: List[_Level],
    path: String,
    is_dir: Bool,
    require_git: Bool,
    git_above: Bool,
) -> Bool:
    var any_git = not require_git or git_above
    for lv in levels:
        if lv.has_git:
            any_git = True
    var m_ignore = _NONE
    var m_git = _NONE
    var m_exclude = _NONE
    var saw_git = False
    var k = len(levels) - 1
    while k >= 0:
        ref lv = levels[k]
        if m_ignore == _NONE:
            m_ignore = lv.dot_ignore.matched(path, is_dir)
        if any_git and not saw_git and m_git == _NONE:
            m_git = lv.git_ignore.matched(path, is_dir)
        if any_git and not saw_git and m_exclude == _NONE:
            m_exclude = lv.exclude.matched(path, is_dir)
        saw_git = saw_git or lv.has_git
        k -= 1
    var m = m_ignore
    if m == _NONE:
        m = m_git
    if m == _NONE:
        m = m_exclude
    if m == _WHITELIST:
        return False
    if m == _IGNORE:
        return True
    return _name_of(path).startswith(".")


def _sorted(var items: List[String]) -> List[String]:
    """Byte order, as Rust sorts paths here."""
    var n = len(items)
    if n < 2:
        return items^
    var mid = n // 2
    var left = List[String]()
    var right = List[String]()
    for i in range(n):
        if i < mid:
            left.append(items[i])
        else:
            right.append(items[i])
    left = _sorted(left^)
    right = _sorted(right^)
    var out = List[String](capacity=n)
    var a = 0
    var b = 0
    while a < len(left) and b < len(right):
        if right[b] < left[a]:
            out.append(right[b])
            b += 1
        else:
            out.append(left[a])
            a += 1
    while a < len(left):
        out.append(left[a])
        a += 1
    while b < len(right):
        out.append(right[b])
        b += 1
    return out^


def _entries(dir: String) -> List[String]:
    try:
        return _sorted(listdir(dir))
    except:
        return List[String]()


def _walk_into(
    mut levels: List[_Level],
    outer: _Outer,
    keep: def(String) thin -> Bool,
    require_git: Bool,
    git_above: Bool,
    mut out: List[String],
    links: Bool = False,
):
    var dir = levels[len(levels) - 1].dir
    for name in _entries(dir):
        var path = dir + "/" + name
        var link = islink(path)
        var is_dir = not link and isdir(path)
        if _ignored(levels, path, is_dir, require_git, git_above):
            continue
        if not keep(path):
            continue
        if is_dir and isfile(path + "/" + MANIFEST):
            continue
        if outer.ignores(path, is_dir):
            continue
        if is_dir:
            levels.append(_level(path))
            _walk_into(levels, outer, keep, require_git, git_above, out, links)
            _ = levels.pop()
        elif links:
            if link:
                out.append(path)
        elif not link and isfile(path):
            out.append(path)


def walk(
    root: String, keep: def(String) thin -> Bool, require_git: Bool = True
) -> List[String]:
    """The files under `root` (`root/...`, sorted) that `keep` accepts and the
    ignore rules do not exclude, as `walk::filtered(root, keep)` with hidden
    entries skipped. Symlinks are not followed."""
    var levels = List[_Level]()
    levels.append(_level(root))
    var out = List[String]()
    _walk_into(levels, _outer(root), keep, require_git, _git_above(root), out)
    return _sorted(out^)


def walk_links(
    root: String, keep: def(String) thin -> Bool, require_git: Bool = True
) -> List[String]:
    """The symlinks `walk` meets and leaves out (the same ignore rules and
    `keep`, not followed): `walk::builder` yields them as entries, and a
    reader that opens one follows it."""
    var levels = List[_Level]()
    levels.append(_level(root))
    var out = List[String]()
    _walk_into(
        levels, _outer(root), keep, require_git, _git_above(root), out, True
    )
    return _sorted(out^)


def _keep_all(path: String) -> Bool:
    return True


def _skip() -> List[String]:
    var out = List[String]()
    for n in ["node_modules", "target", "vendor", ".git", "dist", "build"]:
        out.append(n)
    return out^


def _extension(name: String) -> String:
    var dot = name.rfind(".")
    if dot <= 0:
        return ""
    return String(name[byte = dot + 1 :])


def _count_all(dir: String, extensions: List[String]) -> Int:
    var n = 0
    for name in _entries(dir):
        if name in _skip() or name.startswith("."):
            continue
        var path = dir + "/" + name
        if islink(path):
            continue
        if isdir(path):
            n += _count_all(path, extensions)
        elif isfile(path) and _extension(name) in extensions:
            n += 1
    return n


def ignored_files(root: String, extensions: List[String]) -> Int:
    """Files with one of `extensions` under `root` that ignore rules exclude,
    outside folders that never hold source (dependencies, build output,
    version control)."""
    var all = _count_all(root, extensions)
    var kept = 0
    for path in walk(root, _keep_all, False):
        var skipped = False
        for word in path.split("/"):
            if String(word) in _skip():
                skipped = True
        if not skipped and _extension(_name_of(path)) in extensions:
            kept += 1
    return max(all - kept, 0)
