"""What `analyze` reads from a source file through tree-sitter, for the languages the Rust
tool reads with tree-sitter grammars (src/lang/*.rs `scan`, `exports` and the manifest
readers of `discover`).

The grammars are the pixi environment's Python packages at the versions Cargo.lock pins
(DECISIONS.md F19), so the trees are the ones the Rust modules walk; the Python bindings'
core is 0.26 where the Rust core is 0.27, which shows only in error recovery: a tree with an
error or a missing node is declined, and the whole command goes to the Phase 1 binary before
anything is written.

Embedded into the Mojo tool by tool/embedded.py; the planner, the report and the bridge rules
are Mojo (analyze.mojo, tree_lang.mojo, plan.mojo, python_lang.mojo).
"""

import importlib
import os
import sys

_LANGUAGES = {}

# The grammar module of each language, and the function giving its language.
_GRAMMARS = {
    "java": ("tree_sitter_java", "language"),
    "go": ("tree_sitter_go", "language"),
    "ruby": ("tree_sitter_ruby", "language"),
    "csharp": ("tree_sitter_c_sharp", "language"),
    "kotlin": ("tree_sitter_kotlin", "language"),
    "php": ("tree_sitter_php", "language_php"),
    "c": ("tree_sitter_c", "language"),
    "cpp": ("tree_sitter_cpp", "language"),
    # `bridge` reads a Python unit's exports as python.rs `exports` does (analyze reads
    # Python through `ast`, analyze_py.py).
    "python": ("tree_sitter_python", "language"),
}


class Decline(Exception):
    pass


_SITE = []


def _pinned(module):
    """Whether a module was loaded from the pixi environment, whose versions pixi.lock pins
    to the grammar crates in Cargo.lock."""
    f = getattr(module, "__file__", None)
    if not _SITE or not f:
        return False
    return os.path.realpath(f).startswith(os.path.join(_SITE[0], ""))


def find_bindings(repo):
    """1 when tree-sitter's bindings import from the repository's pixi environment, which goes
    first on the path (the Mojo tool's CPython is the first `python3` on PATH, which outside
    `pixi run` is not the environment's, and another copy of the bindings may come earlier);
    0 otherwise (every file declines)."""
    v = "python%d.%d" % sys.version_info[:2]
    site = os.path.join(repo, ".pixi", "envs", "default", "lib", v, "site-packages")
    if not os.path.isdir(site):
        return 0
    site = os.path.realpath(site)
    sys.path[:] = [site] + [p for p in sys.path if not p or os.path.realpath(p) != site]
    del _SITE[:]
    _SITE.append(site)
    try:
        import tree_sitter
    except ImportError:
        return 0
    return 1 if _pinned(tree_sitter) else 0


def _language(lang):
    if lang not in _LANGUAGES:
        if lang not in _GRAMMARS:
            raise Decline("no grammar for " + lang)
        try:
            import tree_sitter

            module, function = _GRAMMARS[lang]
            m = importlib.import_module(module)
            if not (_pinned(tree_sitter) and _pinned(m)):
                raise Decline("the bindings are not the pinned ones")
            _LANGUAGES[lang] = tree_sitter.Language(getattr(m, function)())
        except Decline:
            raise
        except Exception as e:  # noqa: BLE001 - a grammar that does not load sends the case back
            raise Decline("the grammar does not load: " + str(e))
    return _LANGUAGES[lang]


def _parse(lang, data):
    import tree_sitter

    return tree_sitter.Parser(_language(lang)).parse(data)


# char::is_whitespace (White_Space), for str::trim.
_WS = set(
    "\t\n\x0b\x0c\r \x85\xa0          "
    "      　"
)


def trim(s):
    i, j = 0, len(s)
    while i < j and s[i] in _WS:
        i += 1
    while j > i and s[j - 1] in _WS:
        j -= 1
    return s[i:j]


def _trim_start_matches(s, prefix):
    while prefix and s.startswith(prefix):
        s = s[len(prefix) :]
    return s


def _trim_end_matches(s, suffix):
    while suffix and s.endswith(suffix):
        s = s[: -len(suffix)]
    return s


def _lines(text):
    """str::lines."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [l[:-1] if l.endswith("\r") else l for l in lines]


def loc(text):
    """syntax::loc: lines that are not blank."""
    return sum(1 for l in _lines(text) if any(c not in _WS for c in l))


def _text(node):
    return node.text.decode("utf-8")


def _line(node):
    return node.start_point[0] + 1


def _walk(root):
    """syntax::walk: every node, named and anonymous, depth first."""
    stack = [root]
    while stack:
        node = stack.pop()
        yield node
        stack.extend(reversed(node.children))


def _named(node):
    return list(node.named_children)


def regex_needs_fancy(pattern, flags):
    """risks.rs regex_needs_fancy."""
    if "y" in flags:
        return True
    if any(n in pattern for n in ("(?=", "(?!", "(?<=", "(?<!", "\\k<")):
        return True
    b = pattern.encode("utf-8")
    in_class = False
    i = 0
    while i < len(b):
        c = b[i]
        if c == 0x5C:
            if not in_class and i + 1 < len(b) and 0x31 <= b[i + 1] <= 0x39:
                return True
            i += 1
        elif c == 0x5B:
            in_class = True
        elif c == 0x5D:
            in_class = False
        i += 1
    return False


# ---- Java (src/lang/java.rs) -------------------------------------------------------------


def java_dependencies(text):
    """java.rs `dependencies`: (deps, dev) of a pom's <dependency> blocks and Gradle lines."""
    deps, dev = [], []
    for block in text.split("<dependency>")[1:]:
        block = block.split("</dependency>")[0]

        def tag(t):
            parts = block.split("<" + t + ">")
            if len(parts) < 2:
                return ""
            return trim(parts[1].split("</" + t + ">")[0])

        name = tag("groupId") + ":" + tag("artifactId")
        (dev if tag("scope") == "test" else deps).append(name)
    for line in _lines(text):
        line = trim(line)
        cut = [i for i in (line.find("("), line.find(" ")) if i >= 0]
        if not cut:
            continue
        config, rest = line[: min(cut)], line[min(cut) + 1 :]
        pieces = rest.replace("'", '"').split('"')
        if len(pieces) < 2 or pieces[1].count(":") < 1:
            continue
        name = ":".join(pieces[1].split(":")[:2])
        if config in ("implementation", "api", "compile", "compileOnly", "runtimeOnly"):
            deps.append(name)
        elif config in ("testImplementation", "testCompile", "testRuntimeOnly"):
            dev.append(name)
    return deps, dev


def java_manifest(path):
    """(has_artifact, artifact, deps and dev_deps) of a pom.xml or
    build.gradle(.kts), read as read_to_string(...).unwrap_or_default()."""
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        text = ""
    deps, dev = java_dependencies(text)
    parts = text.split("<artifactId>")
    if len(parts) < 2:
        return (0, "", deps + dev)
    return (1, parts[1].split("</artifactId>")[0], deps + dev)


_JAVA_STRING_OFFSETS = ("substring", "charAt", "indexOf", "lastIndexOf", "codePointAt", "length")
_JAVA_REFLECTION = ("getClass", "forName", "getDeclaredMethod", "invoke", "newInstance")
_JAVA_REGEX = ("matches", "replaceAll", "replaceFirst", "split", "compile")


def _java_scan(root):
    risks = {}
    imports = []
    loops = 0

    def add(risk, node):
        risks.setdefault(risk, []).append(_line(node))

    for node in _walk(root):
        kind = node.type
        if kind == "import_declaration":
            spec = trim(_trim_start_matches(_text(node), "import"))
            spec = trim(_trim_end_matches(_trim_start_matches(spec, "static "), ";"))
            if spec.startswith("java.lang.reflect"):
                add("reflection", node)
            elif spec.startswith("java.util.concurrent"):
                add("concurrency", node)
            elif spec.startswith("java.util.regex"):
                add("regex-syntax", node)
            elif spec in ("java.util.HashMap", "java.util.HashSet"):
                add("unordered-iteration", node)
            imports.append(spec)
        elif kind == "synchronized_statement":
            add("concurrency", node)
        elif kind == "modifiers" and ("synchronized" in _text(node) or "volatile" in _text(node)):
            add("concurrency", node)
        elif kind == "null_literal":
            add("null-references", node)
        elif kind in ("instanceof_expression", "cast_expression"):
            add("dynamic-typing", node)
        elif kind in ("lambda_expression", "method_reference"):
            add("callbacks", node)
        elif kind in ("throw_statement", "try_statement", "catch_clause"):
            add("exceptions", node)
        elif kind in ("superclass", "super_interfaces"):
            add("class-inheritance", node)
        elif kind == "binary_expression":
            o = node.child_by_field_name("operator")
            op = _text(o) if o is not None else ""
            if op in ("/", "%"):
                add("division-semantics", node)
            elif op in ("<<", ">>", ">>>", "*"):
                add("integer-semantics", node)
        elif kind == "method_invocation":
            n = node.child_by_field_name("name")
            name = _text(n) if n is not None else ""
            if name in _JAVA_STRING_OFFSETS:
                add("string-offsets", node)
            elif name in _JAVA_REFLECTION:
                add("reflection", node)
            elif name in _JAVA_REGEX:
                a = node.child_by_field_name("arguments")
                first = _named(a)[0] if a is not None and _named(a) else None
                p = _text(first) if first is not None else None
                if p is not None and p.startswith('"'):
                    if regex_needs_fancy(p.strip('"').replace("\\\\", "\\"), ""):
                        add("regex-syntax", node)
                else:
                    add("dynamic-regex", node)
            elif name == "hashCode":
                add("integer-semantics", node)
        elif kind in ("for_statement", "enhanced_for_statement", "while_statement", "do_statement"):
            loops += 1
    return imports, list(risks.items()), loops


class _NotBridgeable(Exception):
    pass


def _split_top(text):
    out = []
    depth = 0
    current = ""
    for c in text:
        if c == "<":
            depth += 1
        elif c == ">":
            depth -= 1
        elif c == "," and depth == 0:
            out.append(trim(current))
            current = ""
            continue
        current += c
    if trim(current):
        out.append(trim(current))
    return out


def java_to_ts(t):
    """java.rs `java_to_ts`; raises _NotBridgeable where it returns Err."""
    t = trim(t)
    if t.endswith("[]"):
        return java_to_ts(t[:-2]) + "[]"
    i = t.find("<")
    if i >= 0 and t.endswith(">"):
        head, args = t[:i], _split_top(t[i + 1 : -1])
    else:
        head, args = t, []
    head = trim(head).split(".")[-1]

    def arg(k):
        if k >= len(args):
            raise _NotBridgeable("raw")
        return java_to_ts(args[k])

    if head in ("String", "CharSequence"):
        return "string"
    if head in ("int", "long", "short", "byte", "Integer", "Long", "Short", "Byte"):
        return "int"
    if head in ("double", "float", "Double", "Float"):
        return "number"
    if head in ("boolean", "Boolean"):
        return "boolean"
    if head in ("void", "Void"):
        return "void"
    if head in ("List", "ArrayList", "Collection", "Iterable", "LinkedList"):
        inner = arg(0)
        return "(" + inner + ")[]" if " " in inner else inner + "[]"
    if head in ("Map", "LinkedHashMap", "TreeMap", "HashMap"):
        if arg(0) != "string":
            raise _NotBridgeable("keys")
        return "Record<string, " + arg(1) + ">"
    if head == "Optional":
        return arg(0) + " | undefined"
    if head in ("OptionalInt", "OptionalLong"):
        return "int | undefined"
    if head == "OptionalDouble":
        return "number | undefined"
    raise _NotBridgeable(head)


def _modifiers(node):
    for c in _named(node):
        if c.type == "modifiers":
            return _text(c)
    return ""


def _java_exports(root):
    """java.rs `exports`: (blocked, types) of each `public static` method of the file's public
    top-level classes, in order."""
    out = []
    for cls in _named(root):
        if cls.type != "class_declaration":
            continue
        if "public" not in _modifiers(cls).split():
            continue
        if cls.child_by_field_name("name") is None:
            continue
        body = cls.child_by_field_name("body")
        if body is None:
            continue
        for method in _named(body):
            if method.type != "method_declaration":
                continue
            words = _modifiers(method).split()
            if not ("public" in words and "static" in words):
                continue
            n = method.child_by_field_name("name")
            if n is None:
                continue
            name = _text(n)
            blocked = method.child_by_field_name("type_parameters") is not None
            types = []
            params = method.child_by_field_name("parameters")
            for p in _named(params) if params is not None else []:
                if p.type == "formal_parameter":
                    t = p.child_by_field_name("type")
                    ty = _text(t) if t is not None else ""
                elif p.type == "spread_parameter":
                    blocked = True
                    continue
                else:
                    continue
                try:
                    types.append(java_to_ts(ty))
                except _NotBridgeable:
                    blocked = True
                    types.append("unknown")
            r = method.child_by_field_name("type")
            try:
                types.append(java_to_ts(_text(r) if r is not None else "void"))
            except _NotBridgeable:
                blocked = True
                types.append("unknown")
            out.append([name, blocked, types])
    # Every export sharing a name is overloaded.
    names = [f[0] for f in out]
    for f in out:
        if names.count(f[0]) > 1:
            f[1] = True
    return [(f[1], f[2]) for f in out]


# ---- Go (src/lang/go.rs) -----------------------------------------------------------------


def _split_ws(s):
    """str::split_whitespace (White_Space)."""
    out, cur = [], ""
    for c in s:
        if c in _WS:
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += c
    if cur:
        out.append(cur)
    return out


def _mod_directive(text, directive):
    for line in _lines(text):
        words = _split_ws(line)
        if not words or words[0] != directive:
            continue
        if len(words) < 2 or words[1].startswith("//"):
            return None
        return words[1]
    return None


def _go_requirements(text):
    out = []
    in_block = False
    for line in _lines(text):
        line = trim(line)
        if line.startswith("require ("):
            in_block = True
            continue
        if in_block and line == ")":
            in_block = False
            continue
        if in_block:
            spec = line
        elif line.startswith("require "):
            spec = line[len("require ") :]
        else:
            spec = None
        if spec is not None and "// indirect" not in line:
            words = _split_ws(spec)
            if words and not words[0].startswith("//"):
                out.append(words[0])
    return out


def go_manifest(path):
    """(has_module, module path, requirements) of a go.mod, read as
    read_to_string(...).unwrap_or_default()."""
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        text = ""
    m = _mod_directive(text, "module")
    if m is None:
        return (0, "", _go_requirements(text))
    return (1, m.strip('"'), _go_requirements(text))


_GO_CONVERSIONS = ("int", "int32", "int64", "uint", "uint32", "uint64", "uint8", "byte", "float64")


def _go_scan(root):
    risks = {}
    imports = []
    loops = 0

    def add(risk, node):
        risks.setdefault(risk, []).append(_line(node))

    for node in _walk(root):
        kind = node.type
        if kind == "import_spec":
            p = node.child_by_field_name("path")
            if p is not None:
                spec = _text(p).strip('"`')
                if spec == "unsafe":
                    add("pointers", node)
                elif spec == "reflect":
                    add("reflection", node)
                elif spec in ("sync", "sync/atomic"):
                    add("concurrency", node)
                elif spec == "regexp":
                    add("regex-syntax", node)
                elif spec == "encoding/json":
                    add("json", node)
                imports.append(spec)
        elif kind in ("go_statement", "channel_type", "send_statement", "select_statement"):
            add("concurrency", node)
        elif kind in ("pointer_type", "unary_expression") and _text(node).startswith("&"):
            add("pointers", node)
        elif kind == "pointer_type":
            add("pointers", node)
        elif kind == "slice_expression":
            add("string-offsets", node)
        elif kind == "binary_expression":
            o = node.child_by_field_name("operator")
            op = _text(o) if o is not None else ""
            if op in ("/", "%"):
                add("division-semantics", node)
            elif op in ("<<", ">>"):
                add("integer-semantics", node)
        elif kind == "type_conversion_expression":
            add("integer-semantics", node)
        elif kind == "call_expression":
            f = node.child_by_field_name("function")
            callee = _text(f) if f is not None else ""
            if callee in ("panic", "recover"):
                add("exceptions", node)
            elif callee in _GO_CONVERSIONS:
                add("integer-semantics", node)
        elif kind == "nil":
            add("null-references", node)
        elif kind in ("interface_type", "type_switch_statement", "type_assertion_expression"):
            add("dynamic-typing", node)
        elif kind in ("func_literal", "function_type"):
            add("callbacks", node)
        elif kind == "defer_statement":
            add("exceptions", node)
        elif kind == "range_clause":
            loops += 1
            r = node.child_by_field_name("right")
            if r is not None and "map" in _text(r):
                add("unordered-iteration", node)
        elif kind == "for_statement":
            loops += 1
    return imports, list(risks.items()), loops


_GO_BUILTIN = {
    "string": "string",
    "bool": "boolean",
    "float32": "number",
    "float64": "number",
}
for _t in ("int", "int8", "int16", "int32", "int64", "uint", "uint8", "uint16", "uint32", "uint64",
           "uintptr", "byte", "rune"):
    _GO_BUILTIN[_t] = "int"


def _upper_first(s):
    """starts_with(char::is_uppercase), for ASCII; a first character outside ASCII declines
    (Rust's Unicode tables decide it)."""
    if not s:
        return False
    if not s[0].isascii():
        raise Decline("a name outside ASCII")
    return "A" <= s[0] <= "Z"


def _go_structs(root):
    out = {}
    for decl in _named(root):
        if decl.type != "type_declaration":
            continue
        for spec in _named(decl):
            if spec.type != "type_spec":
                continue
            name = spec.child_by_field_name("name")
            ty = spec.child_by_field_name("type")
            if name is None or ty is None or ty.type != "struct_type":
                continue
            fields = []
            ok = True
            lists = [n for n in _named(ty) if n.type == "field_declaration_list"]
            decls = [f for f in _named(lists[0]) if f.type == "field_declaration"] if lists else []
            for n in decls:
                t = n.child_by_field_name("type")
                field_type = _text(t) if t is not None else ""
                g = n.child_by_field_name("tag")
                tag = _text(g) if g is not None else ""
                parts = tag.split('json:"')
                json_name = parts[1].split('"')[0].split(",")[0] if len(parts) > 1 else None
                names = [_text(f) for f in n.children_by_field_name("name")]
                if not names:
                    ok = False
                for field in names:
                    if not _upper_first(field) or json_name == "-":
                        continue
                    try:
                        ts = go_to_ts(field_type, {})
                    except _NotBridgeable:
                        ok = False
                        continue
                    key = json_name if json_name else field
                    fields.append(key + ": " + ts)
            if ok:
                out[_text(name)] = "{ " + "; ".join(fields) + " }"
    return out


def go_to_ts(t, structs):
    """go.rs `go_to_ts`; raises _NotBridgeable where it returns Err."""
    t = trim(t)
    if t in _GO_BUILTIN:
        return _GO_BUILTIN[t]
    if t.startswith("[]"):
        i = go_to_ts(t[2:], structs)
        return "(" + i + ")[]" if (" " in i or "|" in i) else i + "[]"
    if t.startswith("map["):
        rest = t[4:]
        depth = 1
        close = None
        for i, c in enumerate(rest):
            if c == "[":
                depth += 1
            elif c == "]":
                depth -= 1
            if depth == 0:
                close = i
                break
        if close is not None:
            if trim(rest[:close]) != "string":
                raise _NotBridgeable("`" + t + "`: JSON object keys are strings")
            return "Record<string, " + go_to_ts(rest[close + 1 :], structs) + ">"
    if t.startswith("*"):
        raise _NotBridgeable("takes or returns a pointer (`" + t + "`)")
    if t.startswith("func"):
        raise _NotBridgeable("takes or returns a function")
    if t.startswith("chan") or t.startswith("<-chan"):
        raise _NotBridgeable("takes or returns a channel")
    if t == "any" or t.startswith("interface"):
        raise _NotBridgeable("`" + t + "`: values of any type")
    if t.startswith("["):
        raise _NotBridgeable("`" + t + "`: fixed-size array")
    if t == "error":
        raise _NotBridgeable("takes an `error` value")
    if "." in t:
        raise _NotBridgeable("uses `" + t + "` from another package")
    if not _upper_first(t):
        raise _NotBridgeable("uses the unexported type `" + t + "`")
    return structs.get(t, "unknown")


_ASCII_WS = "\t\n\x0b\x0c\r "


def _ascii_tree(v):
    if isinstance(v, str):
        return v.isascii()
    if isinstance(v, dict):
        return all(_ascii_tree(x) for x in v.values())
    if isinstance(v, (list, tuple)):
        return all(_ascii_tree(x) for x in v)
    return True


def _param(name, ts_type, optional=False, default=None, keyword_only=False, native_type=None):
    return {
        "name": name,
        "ts_type": ts_type,
        "optional": optional,
        "rest": False,
        "default": default,
        "keyword_only": keyword_only,
        "native_type": native_type,
    }


def _export(name, path, line, params, returns, blocker, native_return=None, prototype=None):
    return {
        "name": name,
        "file": path,
        "line": line,
        "params": params,
        "returns": returns,
        "blocker": blocker,
        "native_return": native_return,
        "prototype": prototype,
    }


def _go_functions(root, data, path):
    """go.rs `exports` over one parsed file, with Rust's reasons."""
    structs = _go_structs(root)
    out = []
    for node in _named(root):
        if node.type != "function_declaration":
            continue
        n = node.child_by_field_name("name")
        name = _text(n) if n is not None else ""
        if not _upper_first(name):
            continue
        blocker = None
        if node.child_by_field_name("type_parameters") is not None:
            blocker = "generic: Go instantiates it per type"
        params = []
        plist = node.child_by_field_name("parameters")
        for i, p in enumerate(_named(plist) if plist is not None else []):
            if p.type == "variadic_parameter_declaration" and blocker is None:
                blocker = "is variadic"
            t = p.child_by_field_name("type")
            go_type = _text(t) if t is not None else ""
            try:
                ts = go_to_ts(go_type, structs)
            except _NotBridgeable as e:
                if blocker is None:
                    blocker = str(e)
                ts = "unknown"
            names = [_text(x) for x in p.children_by_field_name("name")]
            if not names:
                names = ["arg%d" % i]
            for pn in names:
                if pn == "_":
                    pn = "arg%d" % len(params)
                params.append(_param(pn, ts, native_type=go_type))
        results = []
        r = node.child_by_field_name("result")
        if r is not None:
            if r.type == "parameter_list":
                for p in _named(r):
                    t = p.child_by_field_name("type")
                    count = max(1, len(p.children_by_field_name("name")))
                    results.extend([_text(t) if t is not None else ""] * count)
            else:
                results.append(_text(r))
        fallible = bool(results) and results[-1] == "error"
        if fallible:
            results.pop()
        dialect = []
        for x in results:
            try:
                dialect.append(go_to_ts(x, structs))
            except _NotBridgeable as e:
                if blocker is None:
                    blocker = str(e)
                dialect.append("unknown")
        if not dialect:
            returns = "void"
        elif len(dialect) == 1:
            returns = dialect[0]
        else:
            returns = "[" + ", ".join(dialect) + "]"
        body = node.child_by_field_name("body")
        if body is None:
            signature = _text(node)
        else:
            signature = data[node.start_byte : body.start_byte].decode("utf-8")
        tail = ""
        if fallible:
            tail = "error" if not results else ", error"
        out.append(
            _export(
                name,
                path,
                _line(node),
                params,
                returns,
                blocker,
                "(" + ", ".join(results) + tail + ")",
                " ".join(_split_ws(signature)),
            )
        )
    return out


def go_bridge_exports(root, files):
    """bridge's reading of a Go unit (go.rs `exports` over each file): ("ok", functions) or
    ("decline",) when a file does not read as UTF-8 (bridge's `reading <file>` error is not
    reproduced), a tree has an error, or any name, type or prototype is outside ASCII."""
    out = []
    try:
        for rel in files:
            if rel.endswith((".vue", ".svelte", ".astro")):
                continue
            try:
                with open(os.path.join(root, rel), "rb") as f:
                    data = f.read()
                data.decode("utf-8")
            except (OSError, UnicodeError):
                return ("decline",)
            if not rel.endswith(".go") or rel.endswith("_test.go"):
                continue
            tree = _parse("go", data)
            if tree.root_node.has_error:
                return ("decline",)
            out.extend(_go_functions(tree.root_node, data, rel))
    except (Decline, RecursionError, ValueError):
        return ("decline",)
    if not _ascii_tree(out):
        return ("decline",)
    return ("ok", out)


def go_unit_sources(root, unit):
    """codegen_go `unit_sources` and `package_name`: ("ok", package, sources) where sources
    may be empty; ("decline",) for a unit path Rust would join otherwise or a name outside
    ASCII."""
    if unit.startswith("/"):
        return ("decline",)
    d = os.path.join(root, _trim_end_matches(unit, "/"))
    if os.path.isfile(d):
        d = os.path.dirname(d)
    try:
        names = os.listdir(d)
    except OSError:
        names = []
    picked = []
    for name in names:
        if not name.isascii():
            return ("decline",)
        if name.endswith(".go") and len(name) > 3 and not name.endswith("_test.go"):
            picked.append(name)
    picked.sort(key=lambda n: n.encode())
    sources = []
    for name in picked:
        try:
            with open(os.path.join(d, name), "rb") as f:
                sources.append(f.read().decode("utf-8"))
        except (OSError, UnicodeError):
            continue
    package = "port"
    for s in sources:
        hit = None
        for l in _lines(s):
            tl = trim(l)
            if tl.startswith("package "):
                words = _split_ws(tl[len("package ") :])
                hit = words[0] if words else ""
                break
        if hit is not None:
            package = hit
            break
    if not package.isascii():
        return ("decline",)
    return ("ok", package, sources)


def go_type_decls(sources, names):
    """go.rs `type_decls`: the `type` declarations named `names`, as written."""
    out = []
    try:
        for source in sources:
            tree = _parse("go", source.encode("utf-8"))
            if tree.root_node.has_error:
                return None
            for decl in _named(tree.root_node):
                if decl.type != "type_declaration":
                    continue
                for spec in _named(decl):
                    if spec.type != "type_spec":
                        continue
                    n = spec.child_by_field_name("name")
                    if n is not None and _text(n) in names:
                        out.append("type " + _text(spec))
    except (Decline, RecursionError):
        return None
    return out


def _go_exports(root):
    structs = _go_structs(root)
    out = []
    for node in _named(root):
        if node.type != "function_declaration":
            continue
        n = node.child_by_field_name("name")
        name = _text(n) if n is not None else ""
        if not _upper_first(name):
            continue
        blocked = node.child_by_field_name("type_parameters") is not None
        types = []
        params = node.child_by_field_name("parameters")
        for p in _named(params) if params is not None else []:
            if p.type == "variadic_parameter_declaration":
                blocked = True
            t = p.child_by_field_name("type")
            try:
                ts = go_to_ts(_text(t) if t is not None else "", structs)
            except _NotBridgeable:
                blocked = True
                ts = "unknown"
            count = max(1, len(p.children_by_field_name("name")))
            types.extend([ts] * count)
        results = []
        r = node.child_by_field_name("result")
        if r is not None:
            if r.type == "parameter_list":
                for p in _named(r):
                    t = p.child_by_field_name("type")
                    results.extend([_text(t) if t is not None else ""] * max(1, len(p.children_by_field_name("name"))))
            else:
                results.append(_text(r))
        if results and results[-1] == "error":
            results.pop()
        dialect = []
        for x in results:
            try:
                dialect.append(go_to_ts(x, structs))
            except _NotBridgeable:
                blocked = True
                dialect.append("unknown")
        if not dialect:
            returns = "void"
        elif len(dialect) == 1:
            returns = dialect[0]
        else:
            returns = "[" + ", ".join(dialect) + "]"
        types.append(returns)
        out.append((blocked, types))
    return out


# ---- Ruby (src/lang/ruby.rs) -------------------------------------------------------------


def _ruby_quoted(rest):
    s = trim(rest)
    while s.startswith("("):
        s = s[1:]
    pieces = s.replace("'", '"').split('"')
    return [pieces[1]] if len(pieces) > 1 else []


_RUBY_DEPS = ("spec.add_dependency", "spec.add_runtime_dependency", "s.add_dependency", "gem ")
_RUBY_DEV = ("spec.add_development_dependency", "s.add_development_dependency")


def ruby_gem_names(text):
    """ruby.rs `gem_names`: (deps, dev) of `spec.add_dependency "name"` and `gem "name"`."""
    deps, dev = [], []
    for line in _lines(text):
        line = trim(line)
        hit = next((p for p in _RUBY_DEPS if line.startswith(p)), None)
        if hit is not None:
            deps.extend(_ruby_quoted(line[len(hit) :]))
            continue
        hit = next((p for p in _RUBY_DEV if line.startswith(p)), None)
        if hit is not None:
            dev.extend(_ruby_quoted(line[len(hit) :]))
    return deps, dev


def ruby_manifest(path):
    """The gem names of a .gemspec or Gemfile (deps then dev_deps), read as
    read_to_string(...).unwrap_or_default()."""
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        text = ""
    deps, dev = ruby_gem_names(text)
    return deps + dev


_RUBY_CORE = (
    "String", "Array", "Hash", "Integer", "Float", "Numeric", "Object", "Kernel", "Symbol",
    "NilClass", "Comparable", "Enumerable", "Module", "Class", "Time", "Range", "Proc",
)

_RUBY_META = (
    "define_method", "method_missing", "respond_to_missing?", "instance_variable_set",
    "instance_variable_get", "class_eval", "module_eval", "instance_eval", "const_set",
    "remove_method", "alias_method", "prepend", "refine",
)

_RUBY_LOOPS = (
    "each", "map", "each_with_index", "times", "each_char", "select", "reduce", "inject",
    "each_with_object", "flat_map",
)

_RUBY_REFLECTION = (
    "send", "public_send", "__send__", "method", "const_get", "respond_to?", "is_a?",
    "kind_of?", "instance_of?",
)


def _ruby_scan(root):
    risks = {}
    imports = []
    loops = 0

    def add(risk, node):
        risks.setdefault(risk, []).append(_line(node))

    for node in _walk(root):
        kind = node.type
        if kind == "call":
            m = node.child_by_field_name("method")
            method = _text(m) if m is not None else ""
            receiver = node.child_by_field_name("receiver")
            if method in ("require", "require_relative", "load") and receiver is None:
                a = node.child_by_field_name("arguments")
                first = _named(a)[0] if a is not None and _named(a) else None
                if first is not None and first.type == "string" and "#{" not in _text(first):
                    spec = _text(first).strip("\"'")
                    imports.append("./" + spec if method == "require_relative" else spec)
                else:
                    add("dynamic-code", node)
            elif method in ("eval", "instance_exec", "class_exec"):
                add("dynamic-code", node)
            elif method in _RUBY_REFLECTION:
                add("reflection", node)
            elif method in _RUBY_META:
                add("monkeypatching", node)
            elif method in _RUBY_LOOPS:
                loops += 1
            elif method in ("sort_by", "sort", "uniq", "group_by", "tally"):
                add("ordered-collections", node)
            elif method == "new" and receiver is not None and _text(receiver) in ("Thread", "Mutex", "Queue", "Ractor"):
                add("concurrency", node)
            elif method == "new" and receiver is not None and _text(receiver) == "Regexp":
                add("dynamic-regex", node)
            elif method in ("to_json", "parse", "generate") and "JSON" in _text(node):
                add("json", node)
            elif method in ("raise", "fail"):
                add("exceptions", node)
        elif kind in ("class", "module"):
            if node.child_by_field_name("superclass") is not None:
                add("class-inheritance", node)
            n = node.child_by_field_name("name")
            name = _text(n) if n is not None else ""
            parent = node.parent
            if name in _RUBY_CORE and parent is not None and parent.type == "program":
                add("monkeypatching", node)
        elif kind == "singleton_class":
            add("monkeypatching", node)
        elif kind == "regex":
            pattern = _text(node)
            body = pattern
            if pattern.startswith("/") and "/" in pattern[1:]:
                body = pattern[1:].rsplit("/", 1)[0]
            if regex_needs_fancy(body, "") or "\\h" in body:
                add("regex-syntax", node)
        elif kind == "element_reference":
            add("string-offsets", node)
        elif kind == "binary":
            o = node.child_by_field_name("operator")
            op = _text(o) if o is not None else ""
            if op in ("/", "%"):
                add("division-semantics", node)
            elif op in ("**", "<<"):
                add("integer-semantics", node)
        elif kind in ("rescue", "ensure"):
            add("exceptions", node)
        elif kind in ("block", "do_block", "lambda", "block_parameter"):
            add("callbacks", node)
        elif kind == "yield":
            add("generators", node)
        elif kind == "nil":
            add("null-references", node)
        elif kind == "hash":
            add("ordered-collections", node)
        elif kind in ("while", "until", "for"):
            loops += 1
        elif kind in ("method", "singleton_method"):
            add("dynamic-typing", node)
    return imports, list(risks.items()), loops


def _ruby_method(node):
    """Whether method_fn gives an export (it has a name) and whether it is blocked. The
    parameter and return types it reads from YARD tags, defaults and arithmetic are always
    ones js_only_reason passes (string, int, number, boolean, undefined, unknown, arrays,
    records and unions of them), so they do not change what counts as bridgeable."""
    n = node.child_by_field_name("name")
    if n is None:
        return None
    name = _text(n)
    first = name[:1]
    if first and not first.isascii():
        raise Decline("a method name outside ASCII")
    blocked = name.endswith("=") or name.endswith("!") or not (first and ("a" <= first <= "z" or first == "_"))
    params = node.child_by_field_name("parameters")
    for p in _named(params) if params is not None else []:
        if p.type in ("identifier", "optional_parameter", "keyword_parameter"):
            continue
        blocked = True
    body = node.child_by_field_name("body")
    if body is not None and any(x.type == "yield" for x in _walk(body)):
        blocked = True
    return (name, node.start_point[0], blocked)


def _ruby_namespace(node, out):
    """ruby.rs `namespace`: the module functions of one module or class and the namespaces
    nested in it, as (name, row, blocked)."""
    if node.child_by_field_name("name") is None:
        return
    is_module = node.type == "module"
    module_function = False
    private = False
    hidden = []
    found = []
    instance = []
    body = node.child_by_field_name("body")
    for item in _named(body) if body is not None else []:
        kind = item.type
        t = _text(item)
        if kind == "identifier" and t == "module_function" and is_module:
            module_function = True
        elif kind == "identifier" and t in ("private", "protected"):
            private = True
        elif kind == "call" and t.startswith("private_class_method"):
            hidden.append(t)
        elif kind == "call" and is_module and t.startswith("module_function"):
            for m in instance:
                mn = m.child_by_field_name("name")
                if ":" + (_text(mn) if mn is not None else "") in t:
                    f = _ruby_method(m)
                    if f is not None:
                        found.append(f)
        elif kind == "singleton_method" and item.child_by_field_name("object") is not None and _text(item.child_by_field_name("object")) == "self":
            f = _ruby_method(item)
            if f is not None:
                found.append(f)
        elif kind == "method" and module_function and not private:
            f = _ruby_method(item)
            if f is not None:
                found.append(f)
        elif kind == "method" and not private:
            instance.append(item)
        elif kind == "singleton_class":
            private_here = False
            sb = item.child_by_field_name("body")
            for m in _named(sb) if sb is not None else []:
                if m.type == "identifier" and _text(m) == "private":
                    private_here = True
                if m.type == "method" and not private_here:
                    f = _ruby_method(m)
                    if f is not None:
                        found.append(f)
        elif kind in ("module", "class"):
            _ruby_namespace(item, out)
    out.extend(f for f in found if not any(":" + f[0] in h for h in hidden))


def _ruby_exports(root):
    out = []
    for child in _named(root):
        if child.type in ("module", "class"):
            _ruby_namespace(child, out)
    return [(f[2], []) for f in out]


def _ruby_split_top(text, sep):
    """ruby.rs `split_top`."""
    out = []
    depth = 0
    cur = ""
    for c in text:
        if c in "<{([":
            depth += 1
        elif c in ">})]":
            depth -= 1
        elif c == sep and depth == 0:
            out.append(trim(cur))
            cur = ""
            continue
        cur += c
    if trim(cur):
        out.append(trim(cur))
    return out


def yard_to_ts(types):
    """ruby.rs `yard_to_ts`."""
    parts = _ruby_split_top(types, ",")
    if len(parts) > 1:
        return " | ".join(yard_to_ts(p) for p in parts)
    t = trim(types)
    if t.startswith("Array<") and t.endswith(">") and len(t) >= 7:
        inner = yard_to_ts(t[6:-1])
        return "(" + inner + ")[]" if " " in inner else inner + "[]"
    if t.startswith("Hash{") and t.endswith("}") and len(t) >= 6 and "=>" in t[5:-1]:
        k, v = t[5:-1].split("=>", 1)
        if yard_to_ts(k) == "string":
            return "Record<string, " + yard_to_ts(v) + ">"
        return "unknown"
    return {
        "String": "string",
        "Integer": "int",
        "Fixnum": "int",
        "Bignum": "int",
        "Float": "number",
        "Numeric": "number",
        "Boolean": "boolean",
        "TrueClass": "boolean",
        "FalseClass": "boolean",
        "true": "boolean",
        "false": "boolean",
        "Bool": "boolean",
        "nil": "undefined",
        "NilClass": "undefined",
        "void": "undefined",
        "Array": "unknown[]",
        "Symbol": "string",
    }.get(t, "unknown")


def _parses_i64(v):
    """str::parse::<i64>."""
    s = v[1:] if v[:1] in ("+", "-") else v
    if not s or not all("0" <= c <= "9" for c in s):
        return False
    # Past 19 significant digits it is out of range; int() would also refuse
    # more than 4300 digits.
    digits = s.lstrip("0") or "0"
    if len(digits) > 19:
        return False
    n = -int(digits) if v.startswith("-") else int(digits)
    return -(2**63) <= n <= 2**63 - 1


def _parses_f64(v):
    """str::parse::<f64> (ASCII)."""
    s = v[1:] if v[:1] in ("+", "-") else v
    if s.lower() in ("inf", "infinity", "nan"):
        return True
    i, n = 0, len(s)
    digits = 0
    while i < n and "0" <= s[i] <= "9":
        i += 1
        digits += 1
    if i < n and s[i] == ".":
        i += 1
        while i < n and "0" <= s[i] <= "9":
            i += 1
            digits += 1
    if digits == 0:
        return False
    if i < n and s[i] in "eE":
        i += 1
        if i < n and s[i] in "+-":
            i += 1
        e = 0
        while i < n and "0" <= s[i] <= "9":
            i += 1
            e += 1
        if e == 0:
            return False
    return i == n


def _literal_type(value):
    """ruby.rs `literal_type`."""
    v = trim(value)
    if v.startswith('"') or v.startswith("'"):
        return "string"
    if v in ("true", "false"):
        return "boolean"
    if not v.isascii():
        return None
    if _parses_i64(v):
        return "int"
    if _parses_f64(v):
        return "number"
    return None


def _doc_above(lines, row):
    out = []
    i = row
    while i > 0:
        i -= 1
        l = trim(lines[i]) if i < len(lines) else ""
        if l.startswith("#"):
            out.append(trim(l[1:]))
        else:
            break
    out.reverse()
    return out


def _ruby_method_fn(path, module, node, lines):
    """ruby.rs `method_fn`."""
    n = node.child_by_field_name("name")
    if n is None:
        return None
    name = _text(n)
    doc = _doc_above(lines, node.start_point[0])

    def yard_param(p):
        for l in doc:
            if not l.startswith("@param "):
                continue
            rest = l[len("@param ") :]
            if " " not in rest:
                continue
            pname, rest = rest.split(" ", 1)
            if _trim_end_matches(_trim_start_matches(pname, ":"), ":") != p:
                continue
            rest = trim(rest)
            if not rest.startswith("["):
                continue
            return yard_to_ts(rest[1:].split("]")[0])
        return None

    returns = "unknown"
    for l in doc:
        if not l.startswith("@return "):
            continue
        rest = trim(l[len("@return ") :])
        if not rest.startswith("["):
            continue
        returns = yard_to_ts(rest[1:].split("]")[0])
        break
    blocker = None
    first = name[:1]
    if first and not first.isascii():
        raise Decline("a method name outside ASCII")
    if name.endswith("=") or name.endswith("!") or not (first and ("a" <= first <= "z" or first == "_")):
        blocker = "`" + name + "` is not a plain method name"
    params = []
    signature = ""
    plist = node.child_by_field_name("parameters")
    if plist is not None:
        s = _text(plist)
        i, j = 0, len(s)
        while i < j and s[i] in "()":
            i += 1
        while j > i and s[j - 1] in "()":
            j -= 1
        signature = s[i:j]
        for p in _named(plist):
            pn = p.child_by_field_name("name")
            pname = _text(pn) if pn is not None else _text(p)
            v = p.child_by_field_name("value")
            value = _text(v) if v is not None else None
            kind = p.type
            if kind == "identifier":
                keyword_only, optional = False, False
            elif kind == "optional_parameter":
                keyword_only, optional = False, True
            elif kind == "keyword_parameter":
                keyword_only, optional = True, value is not None
            elif kind == "splat_parameter":
                if blocker is None:
                    blocker = "takes `*args`"
                keyword_only, optional = False, True
            elif kind == "hash_splat_parameter":
                if blocker is None:
                    blocker = "takes `**options`"
                keyword_only, optional = False, True
            elif kind == "block_parameter":
                if blocker is None:
                    blocker = "takes a block"
                continue
            else:
                if blocker is None:
                    blocker = "parameter `" + _text(p) + "`"
                continue
            ts = yard_param(pname)
            if ts is None and value is not None:
                ts = _literal_type(value)
            if ts is None:
                ts = "unknown"
            if value == "nil" and "undefined" not in ts:
                ts = ts + " | undefined"
            params.append(_param(pname, ts, optional, value, keyword_only))
    body = node.child_by_field_name("body")
    if body is not None:
        numeric = []
        for b in _walk(body):
            if b.type != "binary":
                continue
            o = b.child_by_field_name("operator")
            op = _text(o) if o is not None else ""
            left = b.child_by_field_name("left")
            right = b.child_by_field_name("right")
            if left is None or right is None:
                continue
            literal = left.type in ("integer", "float") or right.type in ("integer", "float")
            if op in ("-", "*", "/", "**") or (op in ("+", "%", "<", ">", "<=", ">=") and literal):
                for side in (left, right):
                    if side.type == "identifier":
                        numeric.append(_text(side))
        for p in params:
            if p["ts_type"] == "unknown" and p["name"] in numeric:
                p["ts_type"] = "number"
        if blocker is None and any(x.type == "yield" for x in _walk(body)):
            blocker = "yields to a block"
    return _export(
        name, path, _line(node), params, returns, blocker, None, module + "." + _text(n) + "(" + signature + ")"
    )


def _ruby_namespace_fns(path, node, lines, scope, out):
    """ruby.rs `namespace`."""
    n = node.child_by_field_name("name")
    if n is None:
        return
    scope.append(_text(n))
    receiver = "::".join(scope)
    is_module = node.type == "module"
    module_function = False
    private = False
    hidden = []
    found = []
    instance = []
    body = node.child_by_field_name("body")

    def add(m):
        f = _ruby_method_fn(path, receiver, m, lines)
        if f is not None:
            found.append(f)

    for item in _named(body) if body is not None else []:
        kind = item.type
        t = _text(item)
        if kind == "identifier" and t == "module_function" and is_module:
            module_function = True
        elif kind == "identifier" and t in ("private", "protected"):
            private = True
        elif kind == "call" and t.startswith("private_class_method"):
            hidden.append(t)
        elif kind == "call" and is_module and t.startswith("module_function"):
            for m in instance:
                mn = m.child_by_field_name("name")
                if ":" + (_text(mn) if mn is not None else "") in t:
                    add(m)
        elif (
            kind == "singleton_method"
            and item.child_by_field_name("object") is not None
            and _text(item.child_by_field_name("object")) == "self"
        ):
            add(item)
        elif kind == "method" and module_function and not private:
            add(item)
        elif kind == "method" and not private:
            instance.append(item)
        elif kind == "singleton_class":
            private_here = False
            sb = item.child_by_field_name("body")
            for m in _named(sb) if sb is not None else []:
                if m.type == "identifier" and _text(m) == "private":
                    private_here = True
                if m.type == "method" and not private_here:
                    add(m)
        elif kind in ("module", "class"):
            _ruby_namespace_fns(path, item, lines, scope, out)
    found = [f for f in found if not any(":" + f["name"] in h for h in hidden)]
    found.sort(key=lambda f: f["line"])
    out.extend(found)
    scope.pop()


def ruby_bridge_exports(root, files):
    """bridge's reading of a Ruby unit (ruby.rs `exports` over each file): ("ok", functions)
    or ("decline",) when a file does not read as UTF-8, a tree has an error, or any name, type,
    default or prototype is outside ASCII."""
    out = []
    try:
        for rel in files:
            if rel.endswith((".vue", ".svelte", ".astro")):
                continue
            try:
                with open(os.path.join(root, rel), "rb") as f:
                    data = f.read()
                text = data.decode("utf-8")
            except (OSError, UnicodeError):
                return ("decline",)
            if not rel.endswith(".rb"):
                continue
            tree = _parse("ruby", data)
            if tree.root_node.has_error:
                return ("decline",)
            lines = _lines(text)
            found = []
            for child in _named(tree.root_node):
                if child.type in ("module", "class"):
                    _ruby_namespace_fns(rel, child, lines, [], found)
            found.sort(key=lambda f: f["line"])
            out.extend(found)
    except (Decline, RecursionError, ValueError):
        return ("decline",)
    if not _ascii_tree(out):
        return ("decline",)
    return ("ok", out)


# ---- C# (src/lang/csharp.rs) -------------------------------------------------------------


def _without_xml_comments(text):
    """syntax::without_xml_comments."""
    out = ""
    rest = text
    while True:
        start = rest.find("<!--")
        if start < 0:
            break
        out += rest[:start]
        end = rest.find("-->", start)
        if end < 0:
            rest = ""
            break
        rest = rest[end + 3 :]
    return out + rest


def _cs_attribute(tag, name):
    at = tag.find(name + '="')
    if at < 0:
        return None
    start = at + len(name) + 2
    end = tag.find('"', start)
    if end < 0:
        return None
    return tag[start:end]


def _cs_package_references(text):
    text = _without_xml_comments(text)
    out = []
    for tag in text.split("<PackageReference")[1:]:
        a = _cs_attribute(tag.split(">")[0], "Include")
        if a is not None:
            out.append(a)
    return out


def _cs_element(text, tag):
    parts = text.split("<" + tag + ">")
    if len(parts) < 2:
        return None
    value = trim(parts[1].split("</" + tag + ">")[0])
    return value if value else None


_CS_TEST_PACKAGES = ("xunit", "NUnit", "MSTest.TestFramework", "Microsoft.NET.Test.Sdk")


def csharp_manifest(path, stem):
    """(name, is_test, deps) of a .csproj, read as read_to_string(...).unwrap_or_default()."""
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        text = ""
    deps = _cs_package_references(text)
    clean = _without_xml_comments(text)
    is_test = any(d.startswith(t) for d in _cs_package_references(clean) for t in _CS_TEST_PACKAGES)
    is_test = is_test or _cs_element(clean, "IsTestProject") == "true"
    name = _cs_element(text, "AssemblyName")
    return (stem if name is None else name, 1 if is_test else 0, deps)


def _cs_pattern_risk(pattern):
    if pattern is not None and pattern.type == "string_literal":
        literal = _text(pattern).strip('"').replace("\\\\", "\\")
    elif pattern is not None and pattern.type == "verbatim_string_literal":
        literal = _text(pattern).lstrip("@").strip('"')
    else:
        return "dynamic-regex"
    return "regex-syntax" if regex_needs_fancy(literal, "") else None


def _nth_named(node, n):
    if node is None:
        return None
    kids = _named(node)
    return kids[n] if len(kids) > n else None


_CS_OFFSETS = ("Substring", "IndexOf", "LastIndexOf", "Remove", "Insert", "PadLeft", "PadRight")
_CS_REFLECTION = ("GetType", "GetMethod", "GetProperty", "Invoke", "CreateInstance")


def _cs_scan(root):
    risks = {}
    imports = []
    loops = 0

    def add(risk, node):
        risks.setdefault(risk, []).append(_line(node))

    for node in _walk(root):
        kind = node.type
        if kind == "using_directive":
            names = [c for c in _named(node) if c.type in ("qualified_name", "identifier")]
            if not names:
                continue
            spec = _text(names[-1])
            is_static = "using static" in _text(node)
            if spec.startswith("System.Reflection"):
                add("reflection", node)
            elif spec.startswith("System.Threading"):
                add("concurrency", node)
            elif spec.startswith("System.Text.RegularExpressions"):
                add("regex-syntax", node)
            if not is_static or "." in spec:
                imports.append(spec)
        elif kind == "lock_statement":
            add("concurrency", node)
        elif kind == "modifier" and _text(node) == "volatile":
            add("concurrency", node)
        elif kind == "modifier" and _text(node) == "async":
            add("async", node)
        elif kind == "modifier" and _text(node) == "unsafe":
            add("pointers", node)
        elif kind in ("unsafe_statement", "pointer_type", "fixed_statement"):
            add("pointers", node)
        elif kind == "await_expression":
            add("async", node)
        elif kind in ("yield_statement", "query_expression"):
            add("generators", node)
        elif kind == "null_literal":
            add("null-references", node)
        elif kind in ("is_pattern_expression", "is_expression", "as_expression", "cast_expression"):
            add("dynamic-typing", node)
        elif kind == "identifier" and _text(node) == "dynamic":
            add("dynamic-typing", node)
        elif kind == "predefined_type" and _text(node) == "decimal":
            add("number-semantics", node)
        elif kind in ("lambda_expression", "anonymous_method_expression"):
            add("callbacks", node)
        elif kind in ("throw_statement", "throw_expression", "try_statement", "catch_clause"):
            add("exceptions", node)
        elif kind == "base_list":
            add("class-inheritance", node)
        elif kind == "binary_expression":
            o = node.child_by_field_name("operator")
            op = _text(o) if o is not None else ""
            if op in ("/", "%"):
                add("division-semantics", node)
            elif op in ("<<", ">>", ">>>", "*"):
                add("integer-semantics", node)
        elif kind == "object_creation_expression":
            t = node.child_by_field_name("type")
            ty = _text(t) if t is not None else ""
            if ty == "Regex":
                pattern = _nth_named(_nth_named(node.child_by_field_name("arguments"), 0), 0)
                risk = _cs_pattern_risk(pattern)
                if risk is not None:
                    add(risk, node)
            elif ty in ("HashSet", "Dictionary") or ty.startswith("HashSet<") or ty.startswith("Dictionary<"):
                add("unordered-iteration", node)
        elif kind == "invocation_expression":
            f = node.child_by_field_name("function")
            callee = _text(f) if f is not None else ""
            if callee.startswith("Regex.") and any(
                callee.endswith("." + m) for m in ("IsMatch", "Match", "Matches", "Replace", "Split")
            ):
                pattern = _nth_named(_nth_named(node.child_by_field_name("arguments"), 1), 0)
                risk = _cs_pattern_risk(pattern)
                if risk is not None:
                    add(risk, node)
                continue
            method = callee.split(".")[-1]
            if method in _CS_OFFSETS:
                add("string-offsets", node)
            elif method in _CS_REFLECTION:
                add("reflection", node)
            elif method == "GetHashCode":
                add("integer-semantics", node)
        elif kind in ("for_statement", "foreach_statement", "while_statement", "do_statement"):
            loops += 1
    return imports, list(risks.items()), loops


def _cs_split_top(text):
    out = []
    depth = 0
    current = ""
    for c in text:
        if c in "<(":
            depth += 1
        elif c in ">)":
            depth -= 1
        elif c == "," and depth == 0:
            out.append(trim(current))
            current = ""
            continue
        current += c
    if trim(current):
        out.append(trim(current))
    return out


_CS_INTS = ("int", "long", "short", "byte", "sbyte", "uint", "ushort", "Int32", "Int64", "Int16",
            "Byte", "SByte", "UInt32", "UInt16")


def csharp_to_ts(t):
    """csharp.rs `csharp_to_ts`; raises _NotBridgeable where it returns Err."""
    t = trim(t)
    if t.endswith("?"):
        return csharp_to_ts(t[:-1]) + " | undefined"
    if t.endswith("[]"):
        i = csharp_to_ts(t[:-2])
        return "(" + i + ")[]" if " " in i else i + "[]"
    if t.startswith("("):
        raise _NotBridgeable("tuple")
    i = t.find("<")
    if i >= 0 and t.endswith(">"):
        head, args = t[:i], _cs_split_top(t[i + 1 : -1])
    else:
        head, args = t, []
    head = trim(head).split(".")[-1]

    def arg(k):
        if k >= len(args):
            raise _NotBridgeable("raw")
        return csharp_to_ts(args[k])

    if head in ("string", "String"):
        return "string"
    if head in _CS_INTS:
        return "int"
    if head in ("double", "float", "Double", "Single"):
        return "number"
    if head in ("bool", "Boolean"):
        return "boolean"
    if head == "void":
        return "void"
    if head in ("List", "IList", "IReadOnlyList", "ICollection", "IReadOnlyCollection", "IEnumerable",
                "HashSet", "ISet"):
        inner = arg(0)
        return "(" + inner + ")[]" if " " in inner else inner + "[]"
    if head in ("Dictionary", "IDictionary", "IReadOnlyDictionary", "SortedDictionary"):
        if arg(0) != "string":
            raise _NotBridgeable("keys")
        return "Record<string, " + arg(1) + ">"
    if head == "Nullable":
        return arg(0) + " | undefined"
    raise _NotBridgeable(head)


def _cs_modifiers(node):
    return [_text(c) for c in _named(node) if c.type == "modifier"]


def _cs_method(method, out):
    mods = _cs_modifiers(method)
    if not ("public" in mods and "static" in mods):
        return
    n = method.child_by_field_name("name")
    if n is None:
        return
    name = _text(n)
    blocked = method.child_by_field_name("type_parameters") is not None
    types = []
    params = method.child_by_field_name("parameters")
    for p in _named(params) if params is not None else []:
        if p.type != "parameter":
            blocked = True
            continue
        words = _split_ws(_text(p))
        if words and words[0] in ("ref", "out", "in", "params"):
            blocked = True
        t = p.child_by_field_name("type")
        try:
            types.append(csharp_to_ts(_text(t) if t is not None else ""))
        except _NotBridgeable:
            blocked = True
            types.append("unknown")
    r = method.child_by_field_name("returns")
    try:
        types.append(csharp_to_ts(_text(r) if r is not None else "void"))
    except _NotBridgeable:
        blocked = True
        types.append("unknown")
    # A later declaration of a name already exported is an overload (the first one is not
    # blocked by it).
    if any(f[0] == name for f in out):
        blocked = True
    out.append((name, blocked, types))


def _cs_collect(node, namespace, out):
    for child in _named(node):
        if child.type == "file_scoped_namespace_declaration":
            n = child.child_by_field_name("name")
            namespace = _text(n) if n is not None else ""
        elif child.type == "namespace_declaration":
            body = child.child_by_field_name("body")
            if body is not None:
                _cs_collect(body, namespace, out)
        elif child.type == "class_declaration":
            if "public" not in _cs_modifiers(child):
                continue
            if child.child_by_field_name("name") is None:
                continue
            body = child.child_by_field_name("body")
            for member in _named(body) if body is not None else []:
                if member.type == "method_declaration":
                    _cs_method(member, out)


def _cs_exports(root):
    out = []
    _cs_collect(root, "", out)
    return [(f[1], f[2]) for f in out]


# ---- Kotlin (src/lang/kotlin.rs) ---------------------------------------------------------


def kotlin_manifest(path):
    """kotlin.rs `dependencies` of a pom.xml or build.gradle(.kts), read as
    read_to_string(...).unwrap_or_default(): deps then dev_deps."""
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        text = ""
    deps, dev = [], []
    for line in _lines(text):
        line = trim(line)
        cut = [i for i in (line.find("("), line.find(" ")) if i >= 0]
        if not cut:
            continue
        config, rest = line[: min(cut)], line[min(cut) + 1 :]
        pieces = rest.replace("'", '"').split('"')
        if len(pieces) < 2 or pieces[1].count(":") < 1:
            continue
        name = ":".join(pieces[1].split(":")[:2])
        config = trim(config)
        if config in ("implementation", "api", "compile", "compileOnly", "runtimeOnly"):
            deps.append(name)
        elif config in (
            "testImplementation",
            "testCompile",
            "testRuntimeOnly",
            "androidTestImplementation",
        ):
            dev.append(name)
    return deps + dev


_KT_CALL_RISKS = (
    ("substring", "string-offsets"),
    ("charAt", "string-offsets"),
    ("indexOf", "string-offsets"),
    ("toInt(", "integer-semantics"),
    ("toLong(", "integer-semantics"),
    ("getClass", "reflection"),
    ("javaClass", "reflection"),
    ("forName", "reflection"),
    ("getDeclaredMethod", "reflection"),
    ("newInstance", "reflection"),
    ("::class", "reflection"),
    ("synchronized(", "concurrency"),
)


def _kt_scan(root):
    risks = {}
    imports = []
    loops = 0

    def add(risk, node):
        risks.setdefault(risk, []).append(_line(node))

    for node in _walk(root):
        kind = node.type
        if kind == "import" and node.is_named:
            spec = trim(_trim_start_matches(_text(node), "import"))
            if not spec.isascii():
                # resolve trims the alias off with Rust's whitespace tables.
                raise Decline("an import outside ASCII")
            if spec.startswith("kotlinx.coroutines"):
                add("concurrency", node)
            elif spec.startswith("kotlin.reflect"):
                add("reflection", node)
            elif spec.startswith("java.util.regex") or spec.startswith("kotlin.text.Regex"):
                add("regex-syntax", node)
            elif "HashMap" in spec or "HashSet" in spec:
                add("unordered-iteration", node)
            imports.append(spec)
        elif kind == "nullable_type":
            add("null-references", node)
        elif kind in ("throw_expression", "try_expression"):
            add("exceptions", node)
        elif kind in ("is_expression", "type_test", "as_expression"):
            add("dynamic-typing", node)
        elif kind == "lambda_parameters":
            add("callbacks", node)
        elif kind == "delegation_specifiers":
            add("class-inheritance", node)
        elif kind == "annotation":
            a = _text(node)
            if "Synchronized" in a or "Volatile" in a:
                add("concurrency", node)
        elif kind == "binary_expression":
            o = node.child_by_field_name("operator")
            op = _text(o) if o is not None else ""
            if op in ("/", "%"):
                add("division-semantics", node)
            elif op in ("<<", ">>", ">>>", "*"):
                add("integer-semantics", node)
        elif kind in ("for_statement", "while_statement", "do_while_statement"):
            loops += 1
        elif kind == "call_expression":
            callee = _text(node)
            for needle, risk in _KT_CALL_RISKS:
                if needle in callee:
                    add(risk, node)
            if "Regex(" in callee:
                if regex_needs_fancy(callee.split("Regex(")[1], ""):
                    add("regex-syntax", node)
    return imports, list(risks.items()), loops


def kotlin_to_ts(t):
    """kotlin.rs `kotlin_to_ts`; raises _NotBridgeable where it returns Err."""
    t = trim(t)
    if t.endswith("?"):
        return kotlin_to_ts(t[:-1]) + " | undefined"
    if t.endswith("[]"):
        return kotlin_to_ts(t[:-2]) + "[]"
    i = t.find("<")
    if i >= 0 and t.endswith(">"):
        head, args = t[:i], _split_top(t[i + 1 : -1])
    else:
        head, args = t, []
    head = trim(head).split(".")[-1]

    def arg(k):
        if k >= len(args):
            raise _NotBridgeable("raw")
        return kotlin_to_ts(args[k])

    if head in ("String", "CharSequence"):
        return "string"
    if head in ("Int", "Long", "Short", "Byte"):
        return "int"
    if head in ("Float", "Double"):
        return "number"
    if head == "Boolean":
        return "boolean"
    if head in ("Unit", "Nothing"):
        return "void"
    arrays = {"IntArray": "int", "LongArray": "int", "DoubleArray": "number", "BooleanArray": "boolean"}
    if head in ("List", "MutableList", "Collection", "Iterable", "Array") or head in arrays:
        inner = arrays[head] if head in arrays else arg(0)
        return "(" + inner + ")[]" if " " in inner else inner + "[]"
    if head in ("Map", "MutableMap", "LinkedHashMap"):
        if arg(0) != "string":
            raise _NotBridgeable("keys")
        return "Record<string, " + arg(1) + ">"
    raise _NotBridgeable(head)


_KT_BOXED = {
    "int": "Integer",
    "long": "Long",
    "short": "Short",
    "byte": "Byte",
    "float": "Float",
    "double": "Double",
    "boolean": "Boolean",
    "char": "Character",
}

_KT_JAVA = {
    "String": "String",
    "CharSequence": "String",
    "Int": "int",
    "Long": "long",
    "Short": "short",
    "Byte": "byte",
    "Float": "float",
    "Double": "double",
    "Boolean": "boolean",
    "Unit": "void",
    "Nothing": "void",
    "IntArray": "int[]",
    "LongArray": "long[]",
    "ShortArray": "short[]",
    "ByteArray": "byte[]",
    "FloatArray": "float[]",
    "DoubleArray": "double[]",
    "BooleanArray": "boolean[]",
}


def kotlin_to_java(t):
    """kotlin.rs `kotlin_to_java` (None where it returns None)."""
    t = trim(t)

    def boxed(s):
        return _KT_BOXED.get(s, s)

    if t.endswith("?"):
        inner = kotlin_to_java(t[:-1])
        return None if inner is None else boxed(inner)
    if t.endswith("[]"):
        inner = kotlin_to_java(t[:-2])
        return None if inner is None else boxed(inner) + "[]"
    i = t.find("<")
    if i >= 0 and t.endswith(">"):
        head, args = t[:i], _split_top(t[i + 1 : -1])
    else:
        head, args = t, []
    head = trim(head).split(".")[-1]

    def arg(k):
        if k >= len(args):
            return None
        a = kotlin_to_java(args[k])
        return None if a is None else boxed(a)

    if head in _KT_JAVA:
        return _KT_JAVA[head]
    if head in ("List", "MutableList", "Collection", "Iterable"):
        a = arg(0)
        return None if a is None else "List<" + a + ">"
    if head in ("Map", "MutableMap", "LinkedHashMap"):
        a = arg(1)
        return None if a is None else "Map<String, " + a + ">"
    if head == "Array":
        a = arg(0)
        return None if a is None else a + "[]"
    return None


_KT_MODIFIER_KINDS = (
    "modifiers",
    "annotation",
    "function_modifier",
    "member_modifier",
    "visibility_modifier",
    "class_modifier",
    "parameter_modifier",
)

_KT_TYPE_KINDS = (
    "type",
    "user_type",
    "nullable_type",
    "non_nullable_type",
    "parenthesized_type",
    "function_type",
)


def _kt_modifiers(node):
    return " ".join(_text(c) for c in _named(node) if c.type in _KT_MODIFIER_KINDS)


def _kt_modifier_words(mods):
    """kotlin.rs `modifier_words`: words outside parentheses."""
    out, cur, depth = [], "", 0
    for c in mods:
        if c == "(":
            depth += 1
        elif c == ")":
            depth = max(0, depth - 1)
        if c in _WS or c == "(" or c == ")" or depth > 0:
            if cur:
                out.append(cur)
            cur = ""
        else:
            cur += c
    if cur:
        out.append(cur)
    return out


def _kt_type_text(node):
    return _text(node).replace(" ", "")


def _kt_collect(container, data, owner, default_static, out):
    """kotlin.rs `collect`: [name, blocked, types, owner] of each export."""
    if container.type == "function_declaration":
        candidates = [container]
    else:
        candidates = [
            m
            for n in _named(container)
            if n.type == "class_body"
            for m in _named(n)
            if m.type == "function_declaration"
        ]
    for function in candidates:
        mods = _kt_modifiers(function)
        words = _kt_modifier_words(mods)
        if "private" in words or "protected" in words or "internal" in words:
            continue
        if not default_static and "@JvmStatic" not in words:
            continue
        name_node = function.child_by_field_name("name")
        if name_node is None:
            continue
        name = _text(name_node)
        head = data[function.start_byte : name_node.start_byte].decode("utf-8")
        blocked = trim(head).endswith(".")
        split = _split_ws(mods)
        if "suspend" in split or "inline" in split or "JvmName" in mods:
            blocked = True
        if any(n.type == "type_parameters" for n in _named(function)):
            blocked = True
        types = []
        for child in _named(function):
            if child.type != "function_value_parameters":
                continue
            for p in _named(child):
                if p.type != "parameter":
                    continue
                pmods = _kt_modifiers(p)
                if "vararg" in pmods or "noinline" in pmods:
                    blocked = True
                found = [n for n in _named(p) if n.type in _KT_TYPE_KINDS]
                ptype = _kt_type_text(found[0]) if found else "Any"
                try:
                    types.append(kotlin_to_ts(ptype))
                except _NotBridgeable:
                    blocked = True
                    types.append("unknown")
                if kotlin_to_java(ptype) is None:
                    blocked = True
        found = [
            n
            for n in _named(function)
            if n.start_byte > name_node.end_byte and n.type in _KT_TYPE_KINDS
        ]
        if found:
            ret = _kt_type_text(found[0])
        else:
            rest = data[name_node.end_byte : function.end_byte].decode("utf-8")
            if trim(rest).startswith("="):
                blocked = True
            ret = "Unit"
        try:
            types.append(kotlin_to_ts(ret))
        except _NotBridgeable:
            blocked = True
            types.append("unknown")
        if kotlin_to_java(ret) is None:
            blocked = True
        out.append([name, blocked, types, owner])


def _kt_java_identifier(name):
    if not name:
        return False
    first = name[0]
    if not (first.isascii() and (first.isalpha() or first in "_$")):
        return False
    return all(c.isascii() and (c.isalnum() or c in "_$") for c in name[1:])


def _kt_exports(root, data, path):
    package = None
    for n in _named(root):
        if n.type == "package_header":
            for q in _named(n):
                if q.type == "qualified_identifier":
                    package = _text(q).replace(" ", "")
                    break
            break
    stem = _trim_end_matches(path.split("/")[-1], ".kt")
    top = None
    for n in _named(root):
        if n.type != "file_annotation":
            continue
        t = _text(n)
        at = t.find("JvmName")
        if at < 0:
            continue
        rest = t[at:]
        start = rest.find('"')
        if start < 0:
            continue
        end = rest.find('"', start + 1)
        if end < 0:
            continue
        top = rest[start + 1 : end]
        break
    if top is None:
        if stem and not stem[0].isascii():
            raise Decline("a file name outside ASCII")
        top = stem[:1].upper() + stem[1:] + "Kt"

    def owner(cls):
        return package + "." + cls if package is not None else cls

    out = []
    for child in _named(root):
        if child.type == "function_declaration":
            _kt_collect(child, data, owner(top), True, out)
        elif child.type == "object_declaration":
            n = child.child_by_field_name("name")
            if n is not None:
                _kt_collect(child, data, owner(_text(n)), False, out)
        elif child.type == "class_declaration":
            n = child.child_by_field_name("name")
            if n is None:
                continue
            class_owner = owner(_text(n))
            for member in _named(child):
                if member.type != "class_body":
                    continue
                for decl in _named(member):
                    if decl.type == "object_declaration":
                        nested = decl.child_by_field_name("name")
                        if nested is not None:
                            _kt_collect(decl, data, class_owner + "$" + _text(nested), False, out)
                    elif decl.type == "companion_object":
                        _kt_collect(decl, data, class_owner, False, out)
    names = [f[0] for f in out]
    for f in out:
        if names.count(f[0]) > 1:
            f[1] = True
        # java.rs `receiver`: the class before the last `.` of the prototype's head.
        head = (f[3] + "." + f[0]).split("(")[0]
        cls = head.rsplit(".", 1)[0] if "." in head else ""
        if not _kt_java_identifier(cls.split(".")[-1]):
            f[1] = True
    return [(f[1], f[2]) for f in out]


# ---- the entry point ---------------------------------------------------------------------


# ---- PHP (src/lang/php.rs) ---------------------------------------------------------------


def _php_is_platform(name):
    return name == "php" or name.startswith("ext-") or name.startswith("lib-") or "/" not in name


def php_manifest(path):
    """php.rs `composer` and `own_namespaces` of a composer.json the caller screened as one
    serde_json reads as Python's json does: (name or None, require and require-dev names,
    the first PSR-4 folder or None, the PSR-4 namespaces)."""
    import json

    with open(path, "rb") as f:
        doc = json.loads(f.read().decode("utf-8"))

    def obj(v, *keys):
        for k in keys:
            if not isinstance(v, dict):
                return None
            v = v.get(k)
        return v if isinstance(v, dict) else None

    def names(key):
        o = obj(doc, key)
        return [k for k in o if not _php_is_platform(k)] if o is not None else []

    src = None
    psr4 = obj(doc, "autoload", "psr-4")
    if psr4 is not None:
        for v in psr4.values():
            if isinstance(v, str):
                src = _trim_end_matches(v, "/")
                break
            if isinstance(v, list) and v and isinstance(v[0], str):
                src = _trim_end_matches(v[0], "/")
                break
    name = doc.get("name") if isinstance(doc, dict) else None
    if not isinstance(name, str):
        name = None
    spaces = []
    for key in ("autoload", "autoload-dev"):
        o = obj(doc, key, "psr-4")
        if o is None:
            continue
        for ns in o:
            ns = ns.strip("\\")
            if ns:
                spaces.append(ns)
    return (name, names("require") + names("require-dev"), src, spaces)


def _php_pcre_body(literal):
    s = literal.strip("'\"")
    if not s:
        return None
    o = s[0]
    if not o.isascii():
        raise Decline("a regex delimiter outside ASCII")
    close = {"(": ")", "{": "}", "[": "]", "<": ">"}.get(o)
    if close is None:
        if o.isalnum() or o == "\\" or o in " \t\n\x0b\x0c\r":
            return None
        close = o
    end = s.rfind(close)
    return s[1:end] if end > 0 else None


def _php_include_target(arg):
    def literal(n):
        if n.type not in ("string", "encapsed_string"):
            return None
        s = _text(n).strip("'\"")
        return None if "$" in s else s

    s = literal(arg)
    if s is not None:
        return s if s.startswith("/") or s.startswith(".") else "./" + s
    if arg.type == "binary_expression":
        left = arg.child_by_field_name("left")
        right = arg.child_by_field_name("right")
        if left is None or right is None:
            return None
        if _text(left) == "__DIR__":
            s = literal(right)
            return None if s is None else "." + s
    return None


def _php_operator(node):
    o = node.child_by_field_name("operator")
    if o is not None:
        return _text(o)
    for c in node.children:
        if not c.is_named:
            return _text(c)
    return ""


_PHP_REFLECTION = (
    "method_exists",
    "property_exists",
    "function_exists",
    "class_exists",
    "get_class",
    "get_object_vars",
    "call_user_func",
    "call_user_func_array",
    "is_callable",
    "func_get_args",
    "compact",
    "extract",
)

_PHP_CALLS = {}
for _n in (
    "substr", "strpos", "strrpos", "strlen", "str_pad", "substr_replace", "mb_substr",
    "mb_strpos", "mb_strlen", "ucfirst", "strtoupper", "strtolower", "str_split", "wordwrap",
):
    _PHP_CALLS[_n] = "string-offsets"
for _n in ("intdiv", "fmod"):
    _PHP_CALLS[_n] = "division-semantics"
for _n in ("json_encode", "json_decode", "serialize", "unserialize"):
    _PHP_CALLS[_n] = "json"
for _n in ("pcntl_fork", "proc_open", "curl_multi_exec"):
    _PHP_CALLS[_n] = "concurrency"
for _n in ("class_alias", "runkit_function_redefine", "uopz_set_return"):
    _PHP_CALLS[_n] = "monkeypatching"
for _n in ("sort", "asort", "ksort", "array_unique", "array_keys", "array_values"):
    _PHP_CALLS[_n] = "ordered-collections"
_PHP_LOOP_CALLS = ("array_map", "array_filter", "array_walk", "array_reduce", "usort", "uasort", "uksort")


def _php_scan(root):
    risks = {}
    imports = []
    loops = 0

    def add(risk, node):
        risks.setdefault(risk, []).append(_line(node))

    for node in _walk(root):
        kind = node.type
        if kind in (
            "require_expression",
            "require_once_expression",
            "include_expression",
            "include_once_expression",
        ):
            named = _named(node)
            spec = _php_include_target(named[0]) if named else None
            if spec is not None:
                imports.append(spec)
            else:
                add("dynamic-code", node)
        elif kind == "namespace_use_clause":
            first = node.named_child(0)
            name = _text(first) if first is not None else _text(node)
            prefix = ""
            parent = node.parent
            if parent is not None and parent.type == "namespace_use_group":
                d = parent.parent
                if d is not None:
                    for n in _named(d):
                        if n.type == "namespace_name":
                            prefix = _text(n) + "\\"
                            break
            imports.append(prefix + name.lstrip("\\"))
        elif kind == "function_call_expression":
            f = node.child_by_field_name("function")
            callee = (_text(f) if f is not None else "").lstrip("\\")
            if callee in ("eval", "create_function", "assert"):
                add("dynamic-code", node)
            elif callee in _PHP_REFLECTION:
                add("reflection", node)
            elif callee.startswith("preg_"):
                pattern = None
                a = node.child_by_field_name("arguments")
                if a is not None:
                    named = _named(a)
                    if named:
                        pattern = named[0].named_child(0)
                if pattern is None or pattern.type not in ("string", "encapsed_string"):
                    add("dynamic-regex", node)
                elif "$" in _text(pattern):
                    add("dynamic-regex", node)
                else:
                    b = _php_pcre_body(_text(pattern))
                    if b is not None and (
                        regex_needs_fancy(b, "") or "(?>" in b or "\\K" in b
                    ):
                        add("regex-syntax", node)
            elif callee in _PHP_CALLS:
                add(_PHP_CALLS[callee], node)
            elif callee in _PHP_LOOP_CALLS:
                loops += 1
                add("callbacks", node)
        elif kind == "object_creation_expression":
            c = _text(node)
            if "Reflection" in c:
                add("reflection", node)
            elif "Fiber" in c or "parallel\\" in c:
                add("concurrency", node)
        elif kind == "dynamic_variable_name":
            add("reflection", node)
        elif kind == "method_declaration":
            n = node.child_by_field_name("name")
            if (_text(n) if n is not None else "") in (
                "__call",
                "__callStatic",
                "__get",
                "__set",
                "__isset",
                "__unset",
            ):
                add("reflection", node)
        elif kind in ("class_declaration", "interface_declaration", "trait_declaration"):
            if any(c.type == "base_clause" for c in _named(node)):
                add("class-inheritance", node)
        elif kind == "use_declaration":
            add("class-inheritance", node)
        elif kind == "binary_expression":
            op = _php_operator(node)
            if op == "/":
                add("number-semantics", node)
            elif op == "%":
                add("division-semantics", node)
            elif op in ("**", "<<", "*"):
                add("integer-semantics", node)
            elif op in ("==", "!=", "<>", "<=>"):
                add("dynamic-typing", node)
        elif kind == "array_creation_expression":
            add("ordered-collections", node)
        elif kind in ("throw_expression", "try_statement"):
            add("exceptions", node)
        elif kind == "yield_expression":
            add("generators", node)
        elif kind in ("anonymous_function", "anonymous_function_creation_expression", "arrow_function"):
            add("callbacks", node)
        elif kind == "null":
            add("null-references", node)
        elif kind in ("foreach_statement", "for_statement", "while_statement", "do_statement"):
            loops += 1
    return imports, list(risks.items()), loops


def _php_function_blocked(node):
    """php.rs `function_fn`'s blocker (the types it maps never make js_only_reason refuse:
    php_to_ts gives only string, int, number, boolean, undefined, unknown, arrays, records and
    their unions); None when the node has no name (no export)."""
    n = node.child_by_field_name("name")
    if n is None:
        return None
    blocked = _text(n).startswith("__")
    params = node.child_by_field_name("parameters")
    for p in _named(params) if params is not None else []:
        if p.type != "simple_parameter":
            blocked = True
            continue
        if any(c.type == "reference_modifier" for c in _named(p)) or "&$" in _text(p):
            blocked = True
        t = p.child_by_field_name("type")
        if t is not None and ("callable" in _text(t) or "Closure" in _text(t)):
            blocked = True
    body = node.child_by_field_name("body")
    if body is not None and any(x.type == "yield_expression" for x in _walk(body)):
        blocked = True
    return blocked


def _php_exports(root):
    out = []

    def visit(items):
        for item in items:
            if item.type == "function_definition":
                b = _php_function_blocked(item)
                if b is not None:
                    out.append((b, []))
            elif item.type == "class_declaration":
                if any(c.type == "abstract_modifier" for c in _named(item)):
                    continue
                if item.child_by_field_name("name") is None:
                    continue
                body = item.child_by_field_name("body")
                for m in _named(body) if body is not None else []:
                    if m.type != "method_declaration":
                        continue
                    mods = [_text(c) for c in _named(m) if c.type.endswith("_modifier")]
                    public = not any(x in ("private", "protected") for x in mods)
                    if public and "static" in mods:
                        b = _php_function_blocked(m)
                        if b is not None:
                            out.append((b, []))

    for item in _named(root):
        body = item.child_by_field_name("body") if item.type == "namespace_definition" else None
        if body is not None:
            visit(_named(body))
        else:
            visit([item])
    return out


# ---- C (src/lang/c.rs) -------------------------------------------------------------------

_C_CALLS = {}
for _n in ("malloc", "calloc", "realloc", "free", "memcpy", "memmove"):
    _C_CALLS[_n] = "pointers"
for _n in ("strlen", "strcpy", "strncpy", "strcat", "strcmp", "strchr", "strstr", "sprintf", "snprintf"):
    _C_CALLS[_n] = "string-offsets"
for _n in ("pthread_create", "pthread_mutex_lock", "atomic_fetch_add"):
    _C_CALLS[_n] = "concurrency"
for _n in ("setjmp", "longjmp", "signal", "exit", "abort"):
    _C_CALLS[_n] = "exceptions"

_C_ATTRIBUTES = ("packed", "aligned", "section", "interrupt", "naked")


def _trim_start(s):
    i = 0
    while i < len(s) and s[i] in _WS:
        i += 1
    return s[i:]


def _c_scan(root):
    risks = {}
    imports = []
    loops = 0

    def add(risk, node):
        risks.setdefault(risk, []).append(_line(node))

    for node in _walk(root):
        kind = node.type
        if kind == "preproc_include":
            path = node.child_by_field_name("path")
            if path is not None:
                raw = _text(path)
                if raw.startswith('"'):
                    imports.append(raw.strip('"'))
                else:
                    imports.append("<" + raw.strip("<>") + ">")
        elif kind in ("pointer_expression", "pointer_declarator"):
            add("pointers", node)
        elif kind == "call_expression":
            f = node.child_by_field_name("function")
            callee = _text(f) if f is not None else ""
            if callee in _C_CALLS:
                add(_C_CALLS[callee], node)
        elif kind == "binary_expression":
            o = node.child_by_field_name("operator")
            op = _text(o) if o is not None else ""
            if op in ("/", "%"):
                add("division-semantics", node)
            elif op in ("<<", ">>"):
                add("integer-semantics", node)
        elif kind == "cast_expression":
            add("integer-semantics", node)
            value = node.child_by_field_name("value")
            t = node.child_by_field_name("type")
            ty = _text(t) if t is not None else ""
            if "*" in ty and value is not None and value.type == "number_literal":
                add("platform-specific", node)
        elif kind in ("gnu_asm_expression", "bitfield_clause", "ms_declspec_modifier"):
            add("platform-specific", node)
        elif kind == "type_qualifier":
            if _text(node) == "volatile":
                add("platform-specific", node)
        elif kind in ("attribute_specifier", "attribute_declaration"):
            if any(a in _text(node) for a in _C_ATTRIBUTES):
                add("platform-specific", node)
        elif kind == "preproc_call":
            t = _text(node)
            if _trim_start(t).startswith("#pragma") and "pack" in t:
                add("platform-specific", node)
        elif kind == "null":
            add("null-references", node)
        elif kind == "preproc_function_def":
            add("reflection", node)
        elif kind in ("for_statement", "while_statement", "do_statement"):
            loops += 1
    return imports, list(risks.items()), loops


_C_SCALARS = {
    "int": "int", "signed int": "int", "signed": "int",
    "unsigned": "int", "unsigned int": "int",
    "short": "int", "short int": "int", "signed short": "int",
    "unsigned short": "int", "unsigned short int": "int",
    "long": "int", "long int": "int", "signed long": "int",
    "unsigned long": "int", "unsigned long int": "int",
    "long long": "int", "long long int": "int", "signed long long": "int",
    "unsigned long long": "int", "unsigned long long int": "int",
    "char": "int", "signed char": "int", "unsigned char": "int",
    "int8_t": "int", "int16_t": "int", "int32_t": "int", "int64_t": "int",
    "uint8_t": "int", "uint16_t": "int", "uint32_t": "int", "uint64_t": "int",
    "size_t": "int", "ssize_t": "int", "ptrdiff_t": "int", "intptr_t": "int",
    "float": "number", "double": "number",
    "bool": "boolean", "_Bool": "boolean",
    "void": "void",
}


def _c_bare(c):
    return " ".join(w for w in _split_ws(c) if w != "const")


def c_scalar(c):
    """c.rs `scalar`'s dialect type (the char signedness changes only the Rust types), or
    None."""
    return _C_SCALARS.get(_c_bare(c))


def _c_rstrip_stars(s):
    while s and s[-1] in "* ":
        s = s[:-1]
    return s


def _c_declared(node, base):
    ty = base
    current = node
    name = None
    while current is not None:
        k = current.type
        if k in ("pointer_declarator", "abstract_pointer_declarator"):
            ty += "*"
            current = current.child_by_field_name("declarator")
        elif k == "identifier":
            name = _text(current)
            current = None
        elif k == "array_declarator":
            ty += "[]"
            current = current.child_by_field_name("declarator")
        elif k == "function_declarator":
            ty += "(fn)"
            current = current.child_by_field_name("declarator")
        else:
            current = current.child_by_field_name("declarator")
    return ty, name


_C_BASE_KINDS = (
    "type_qualifier",
    "primitive_type",
    "sized_type_specifier",
    "type_identifier",
    "struct_specifier",
    "enum_specifier",
    "union_specifier",
)


def _c_base_type(node):
    return " ".join(_text(c) for c in _named(node) if c.type in _C_BASE_KINDS)


def _c_typedefs_in(root, out):
    for node in _walk(root):
        if node.type != "type_definition":
            continue
        d = node.child_by_field_name("declarator")
        if d is None or d.type != "type_identifier":
            continue
        ty = node.child_by_field_name("type")
        if ty is None:
            continue
        if ty.type == "enum_specifier":
            underlying = "int"
        elif ty.type in ("primitive_type", "sized_type_specifier", "type_identifier"):
            underlying = " ".join(_split_ws(_text(ty)))
        else:
            continue
        out.append((_text(d), underlying))


def _c_struct_fields(spec):
    body = spec.child_by_field_name("body")
    if body is None:
        return None
    fields = []
    for field in _named(body):
        if field.type == "comment":
            continue
        if field.type != "field_declaration":
            return None
        if any(c.type == "bitfield_clause" for c in _named(field)):
            return None
        ty = field.child_by_field_name("type")
        if ty is None or ty.type not in ("primitive_type", "sized_type_specifier", "type_identifier"):
            return None
        ty = _c_base_type(field)
        names = field.children_by_field_name("declarator")
        if not names:
            return None
        for n in names:
            if n.type != "field_identifier":
                return None
            fields.append((ty, _text(n)))
    return fields if fields else None


def _c_structs_in(root):
    """collect_structs for one file: (bodies, opaque, aliases) in the order they are met."""
    bodies, opaque, aliases = [], [], []
    for node in _walk(root):
        if node.type == "struct_specifier" and node.child_by_field_name("body") is not None:
            tag = node.child_by_field_name("name")
            if tag is not None:
                name = "struct " + _text(tag)
                f = _c_struct_fields(node)
                (bodies.append((name, f)) if f is not None else opaque.append(name))
        elif node.type == "type_definition":
            d = node.child_by_field_name("declarator")
            ty = node.child_by_field_name("type")
            if d is None or ty is None:
                continue
            if d.type != "type_identifier" or ty.type != "struct_specifier":
                continue
            name = _text(d)
            if ty.child_by_field_name("body") is not None:
                f = _c_struct_fields(ty)
                (bodies.append((name, f)) if f is not None else opaque.append(name))
            else:
                tag = ty.child_by_field_name("name")
                if tag is not None:
                    aliases.append((name, "struct " + _text(tag)))
    return bodies, opaque, aliases


_C_TYPES = [{}, {}]


def c_use_types(root, rels):
    """use_typedefs: the project's scalar typedefs and structs of scalars from every `.h` and
    `.c` file the walk keeps (`rels`); 1 when read, 0 when the result could depend on the
    walk's order (a name defined in two files, or twice in one, with different meanings) or
    a file's tree has an error."""
    raw = {}
    per_name = {}
    alias_of = {}
    try:
        for rel in rels:
            try:
                with open(os.path.join(root, rel), "rb") as f:
                    data = f.read()
                data.decode("utf-8")
            except (OSError, UnicodeError):
                continue
            tree = _parse("c", data)
            if tree.root_node.has_error:
                return 0
            pairs = []
            _c_typedefs_in(tree.root_node, pairs)
            for name, underlying in pairs:
                if raw.get(name, underlying) != underlying:
                    return 0
                raw[name] = underlying
            bodies, opaque, aliases = _c_structs_in(tree.root_node)
            seen = {}
            for name, fields in bodies:
                seen.setdefault(name, []).append(fields)
            for name in opaque:
                seen.setdefault(name, []).append(None)
            for name, got in seen.items():
                if per_name.get(name, got[0]) != got[0] or any(g != got[0] for g in got):
                    return 0
                per_name[name] = got[0]
            for name, target in aliases:
                if alias_of.get(name, target) != target:
                    return 0
                alias_of[name] = target
    except Decline:
        return 0
    except RecursionError:
        return 0
    out = {}
    for name in raw:
        ty = raw[name]
        for _ in range(8):
            if ty in raw:
                ty = raw[ty]
            else:
                break
        if c_scalar(ty) is not None:
            out[name] = ty

    def field_type(ty):
        bare = _c_bare(ty)
        resolved = out.get(bare, bare)
        d = c_scalar(resolved)
        return resolved if d is not None and d != "void" else None

    structs = {}
    for name, fields in per_name.items():
        if fields is None:
            continue
        typed = []
        for ty, field in fields:
            t = field_type(ty)
            if t is None:
                typed = None
                break
            typed.append((t, field))
        if typed is not None:
            structs[name] = typed
    for name, target in alias_of.items():
        if target in structs and name not in structs:
            structs[name] = structs[target]
    _C_TYPES[0] = out
    _C_TYPES[1] = structs
    return 1


def _c_struct_type(c_type):
    if "*" in c_type or "[]" in c_type or "(fn)" in c_type:
        return None
    bare = _c_bare(c_type)
    fields = _C_TYPES[1].get(bare)
    if fields is None:
        return None
    return "struct:" + bare + ":" + ",".join(t + " " + n for t, n in fields)


def _c_resolve_type(c_type):
    stars = c_type.count("*")
    base = trim(_c_rstrip_stars(c_type))
    is_const = "const" in _split_ws(base)
    bare = _c_bare(base)
    resolved = "int" if bare.startswith("enum ") else _C_TYPES[0].get(bare, bare)
    return ("const " if is_const else "") + resolved + "*" * stars


_C_BYTE_TYPES = ("uint8_t", "unsigned char", "char", "signed char", "int8_t", "void")


def _c_pointee(c_type):
    normalized = c_type.replace("char const", "const char")
    if normalized.count("*") != 1 or "(fn)" in normalized:
        return None
    base = trim(_c_rstrip_stars(normalized))
    return (_c_bare(base), "const" in _split_ws(base))


def _c_is_integer(c_type):
    return "*" not in c_type and c_scalar(c_type) == "int"


def _c_is_char_pointer_pointer(c_type):
    normalized = c_type.replace("char const", "const char")
    t = normalized
    while t and t[-1] in _WS:
        t = t[:-1]
    if not t.endswith("*"):
        return False
    p = _c_pointee(t[:-1])
    return p is not None and p[0] == "char"


def _c_classify(c_type):
    """c.rs `classify`: (ok, dialect type or the reason it cannot cross)."""
    if "(fn)" in c_type:
        return (False, "takes a function pointer")
    if "*" in c_type or "[]" in c_type:
        return (False, "passes a pointer (`%s`): ownership must be designed" % c_type)
    ts = _c_struct_type(c_type)
    if ts is not None:
        return (True, ts)
    d = c_scalar(c_type)
    if d is not None:
        return (True, d)
    if c_type.startswith("struct") or c_type.startswith("union"):
        return (False, "passes `%s` by value, and not all of its fields are scalars" % c_type)
    return (False, "uses `%s`, which is not a C scalar the bridge knows" % c_type)


def _c_classify_params(types):
    n = len(types)
    out = [None] * n

    def lens(i):
        return out[i] is None and _c_is_integer(types[i][0])

    for i, (ty, _) in enumerate(types):
        p = _c_pointee(ty)
        if p is not None and p[1] and p[0] == "char":
            out[i] = (True, "string")
    for i, (ty, _) in enumerate(types):
        if out[i] is not None:
            continue
        p = _c_pointee(ty)
        if p is None or not p[1]:
            continue
        if p[0] in _C_BYTE_TYPES and i + 1 < n and lens(i + 1):
            out[i] = (True, "bytes")
            out[i + 1] = (True, "len:%d" % i)
    for i, (ty, _) in enumerate(types):
        if out[i] is not None:
            continue
        p = _c_pointee(ty)
        if p is None or p[1]:
            continue
        if p[0] not in _C_BYTE_TYPES:
            continue

        def sized(j):
            name = types[j][1]
            if name is None:
                return False
            # str::to_ascii_lowercase
            low = "".join(c.lower() if "A" <= c <= "Z" else c for c in name)
            return "size" in low or "len" in low or low == "n" or low == "cap"

        partner = None
        if i + 1 < n and lens(i + 1):
            partner = i + 1
        else:
            for j in range(n):
                if j != i and lens(j) and sized(j):
                    partner = j
                    break
        if partner is not None:
            out[i] = (True, "buffer")
            out[partner] = (True, "len:%d" % i)
    for i, (ty, _) in enumerate(types):
        if out[i] is not None or not _c_is_char_pointer_pointer(ty):
            continue
        target = None
        for j in range(n):
            k = out[j]
            if k is not None and k[0] and k[1] in ("string", "bytes", "buffer"):
                pj = _c_pointee(types[j][0])
                if pj is not None and pj[0] == "char":
                    target = j
                    break
        out[i] = (
            (True, "outptr:%d" % target)
            if target is not None
            else (
                False,
                "passes a pointer to a pointer (`%s`) with no `char *` parameter it could point into"
                % ty,
            )
        )
    result = []
    for (ty, _), done in zip(types, out):
        if done is not None:
            result.append(done)
            continue
        p = _c_pointee(ty)
        if p is not None and p[1] and p[0] in _C_BYTE_TYPES:
            result.append((False, "passes a pointer (`%s`) with no length parameter after it" % ty))
        elif p is not None and not p[1] and p[0] in _C_BYTE_TYPES:
            result.append((False, "writes to a buffer (`%s`) whose size is not a parameter" % ty))
        elif p is not None and not p[1] and c_scalar(p[0]) not in (None, "void"):
            result.append((True, "out"))
        else:
            result.append(_c_classify(ty))
    return result


def _c_allocates(body):
    for n in _walk(body):
        if n.type == "call_expression":
            f = n.child_by_field_name("function")
            callee = _text(f) if f is not None else ""
            if "alloc" in callee or "dup" in callee or "printf" in callee:
                return True
    return False


def _c_functions(root, path):
    """c.rs `exports`: the non-static function definitions of a `.c` file, as ExportedFn
    dicts (name, file, line, params with their C types, returns, native_return, prototype,
    blocker)."""
    out = []
    for node in _named(root):
        if node.type != "function_definition":
            continue
        if any(c.type == "storage_class_specifier" and _text(c) == "static" for c in _named(node)):
            continue
        base = _c_base_type(node)
        declarator = node.child_by_field_name("declarator")
        if declarator is None:
            continue
        ret = base
        function = declarator
        while function.type == "pointer_declarator":
            ret += "*"
            inner = function.child_by_field_name("declarator")
            if inner is None:
                break
            function = inner
        if function.type != "function_declarator":
            continue
        n = function.child_by_field_name("declarator")
        name = _text(n) if n is not None else ""
        if name == "main":
            continue
        blocker = None
        declared = []
        params = function.child_by_field_name("parameters")
        for i, p in enumerate(_named(params) if params is not None else []):
            if p.type == "variadic_parameter":
                blocker = "is variadic"
                continue
            if p.type != "parameter_declaration":
                continue
            pbase = _c_base_type(p)
            d = p.child_by_field_name("declarator")
            c_type, pname = _c_declared(d, pbase) if d is not None else (pbase, None)
            if c_type == "void" and pname is None:
                continue
            declared.append((_c_resolve_type(c_type), pname if pname is not None else "arg%d" % i))
        kinds = _c_classify_params([(t, nm) for t, nm in declared])
        ps = []
        for (c_type, pname), (ok, t) in zip(declared, kinds):
            if not ok:
                if blocker is None:
                    blocker = t
                t = "unknown"
            ps.append({"name": pname, "ts_type": t, "native_type": c_type})
        r = _c_resolve_type(ret)
        if r == "void":
            returns = "void"
        elif "*" in r:
            into = None
            pr = _c_pointee(r)
            if pr is not None:
                for k, p in enumerate(ps):
                    if p["ts_type"] in ("string", "bytes", "buffer"):
                        pk = _c_pointee(p["native_type"])
                        if pk is not None and pk[0] == pr[0]:
                            into = k
                            break
            body = node.child_by_field_name("body")
            allocates = body is not None and _c_allocates(body)
            if into is not None and not allocates:
                returns = "ptr:%d" % into
            else:
                if blocker is None:
                    blocker = "returns a pointer (`%s`): who frees it must be designed" % r
                returns = "unknown"
        else:
            ok, t = _c_classify(r)
            if ok:
                returns = t
            else:
                if blocker is None:
                    blocker = t
                returns = "unknown"
        out.append(
            {
                "name": name,
                "file": path,
                "line": _line(node),
                "params": ps,
                "returns": returns,
                "native_return": r,
                "prototype": " ".join(_split_ws(base + " " + _text(declarator))),
                "blocker": blocker,
            }
        )
    return out


def _c_exports(root):
    """c.rs `exports` for analyze: (blocked, the dialect types) of each function."""
    return [
        (f["blocker"] is not None, [p["ts_type"] for p in f["params"]] + [f["returns"]])
        for f in _c_functions(root, "")
    ]


def c_bridge_exports(root, files):
    """bridge's reading of a C unit (c.rs `exports` over each file, after `use_types`):
    ("ok", functions) or ("decline",) when a file does not read as UTF-8 (bridge's
    `reading <file>` error is not reproduced), a `.c` tree has an error, or any name or type
    is outside ASCII."""
    out = []
    try:
        for rel in files:
            if rel.endswith((".vue", ".svelte", ".astro")):
                continue
            try:
                with open(os.path.join(root, rel), "rb") as f:
                    data = f.read()
                data.decode("utf-8")
            except (OSError, UnicodeError):
                return ("decline",)
            if not rel.endswith(".c"):
                continue
            tree = _parse("c", data)
            if tree.root_node.has_error:
                return ("decline",)
            out.extend(_c_functions(tree.root_node, rel))
    except (Decline, RecursionError):
        return ("decline",)

    def ascii(v):
        if isinstance(v, str):
            return v.isascii()
        if isinstance(v, dict):
            return all(ascii(x) for x in v.values())
        if isinstance(v, list):
            return all(ascii(x) for x in v)
        return True

    if not ascii(out):
        return ("decline",)
    return ("ok", out)


# ---- C++ (src/lang/cpp.rs) ---------------------------------------------------------------

_CPP_SOURCES = ("cpp", "cc", "cxx")
_CPP_HEADERS = ("h", "hpp", "hh", "hxx")


def _cpp_extension(name):
    i = name.rfind(".")
    return name[i + 1 :] if i >= 0 else ""


def cpp_is_source(name):
    return 1 if _cpp_extension(name) in _CPP_SOURCES else 0


def cpp_is_header(name):
    return 1 if _cpp_extension(name) in _CPP_HEADERS else 0


_CPP_POINTER_CALLS = ("malloc", "calloc", "realloc", "free", "memcpy", "memmove")
_CPP_OFFSET_CALLS = ("strlen", "strcpy", "strcmp", "sprintf", "snprintf", "substr")
_CPP_EXIT_CALLS = ("setjmp", "longjmp", "exit", "abort", "terminate")


def _cpp_scan(root):
    risks = {}
    imports = []
    loops = 0

    def add(risk, node):
        risks.setdefault(risk, []).append(_line(node))

    # syntax::walk visits anonymous tokens too, so a kind matched here that is
    # also a token's (`nullptr`) counts for both, as in Rust.
    for node in _walk(root):
        kind = node.type
        if kind == "preproc_include":
            path = node.child_by_field_name("path")
            if path is not None:
                raw = _text(path)
                if raw.startswith('"'):
                    imports.append(raw.strip('"'))
                else:
                    imports.append("<" + raw.strip("<>") + ">")
        elif kind in ("pointer_expression", "pointer_declarator", "new_expression", "delete_expression"):
            add("pointers", node)
        elif kind in ("throw_statement", "try_statement"):
            add("exceptions", node)
        elif kind == "template_declaration":
            add("dynamic-typing", node)
        elif kind == "base_class_clause":
            add("class-inheritance", node)
        elif kind == "call_expression":
            f = node.child_by_field_name("function")
            callee = _text(f) if f is not None else ""
            bare = callee.split("::")[-1]
            if bare in _CPP_POINTER_CALLS:
                add("pointers", node)
            elif bare in _CPP_OFFSET_CALLS:
                add("string-offsets", node)
            elif bare in _CPP_EXIT_CALLS:
                add("exceptions", node)
        elif kind in ("qualified_identifier", "qualified_type_identifier"):
            t = _text(node)
            if any(t.startswith(p) for p in ("std::thread", "std::mutex", "std::atomic", "std::async")):
                add("concurrency", node)
            elif any(t.startswith(p) for p in ("std::unordered_map", "std::unordered_set")):
                add("unordered-iteration", node)
        elif kind == "binary_expression":
            o = node.child_by_field_name("operator")
            op = _text(o) if o is not None else ""
            if op in ("/", "%"):
                add("division-semantics", node)
        elif kind == "cast_expression":
            add("integer-semantics", node)
        elif kind in ("gnu_asm_expression", "ms_declspec_modifier"):
            add("platform-specific", node)
        elif kind in ("null", "nullptr"):
            add("null-references", node)
        elif kind == "preproc_function_def":
            add("reflection", node)
        elif kind in ("for_statement", "for_range_loop", "while_statement", "do_statement"):
            loops += 1
    return imports, list(risks.items()), loops


def _cpp_scalar_spelling(t):
    """A scalar type's words with `std::` and `const` dropped."""
    return " ".join(w[5:] if w.startswith("std::") else w for w in _split_ws(t) if w != "const")


# The project's scalar aliases (resolved) and the names of its classes, structs and unions.
_CPP_TYPES = [{}, set()]


def cpp_use_types(root, rels):
    """use_typedefs over every C++ file the unfiltered walk keeps (`rels`); 1 when read, 0
    when the result could depend on the walk's order (an alias given two spellings: Rust's
    map keeps the last one met) or a file's tree has an error."""
    raw = {}
    classes = set()
    try:
        for rel in rels:
            try:
                with open(os.path.join(root, rel), "rb") as f:
                    data = f.read()
                data.decode("utf-8")
            except (OSError, UnicodeError):
                continue
            tree = _parse("cpp", data)
            if tree.root_node.has_error:
                return 0
            for node in _walk(tree.root_node):
                kind = node.type
                name = ty = None
                if kind == "alias_declaration":
                    name = node.child_by_field_name("name")
                    ty = node.child_by_field_name("type")
                elif kind == "type_definition":
                    name = node.child_by_field_name("declarator")
                    ty = node.child_by_field_name("type")
                    if name is not None and name.type != "type_identifier":
                        name = None
                elif kind in ("class_specifier", "struct_specifier", "union_specifier"):
                    n = node.child_by_field_name("name")
                    if n is not None:
                        classes.add(_text(n))
                    continue
                if name is None or ty is None:
                    continue
                key = _text(name)
                value = _cpp_scalar_spelling(_text(ty))
                if raw.get(key, value) != value:
                    return 0
                raw[key] = value
    except Decline:
        return 0
    except RecursionError:
        return 0
    aliases = {}
    for name in raw:
        ty = raw[name]
        for _ in range(8):
            if ty in raw:
                ty = raw[ty]
            else:
                break
        if c_scalar(ty) is not None:
            aliases[name] = ty
    _CPP_TYPES[0] = aliases
    _CPP_TYPES[1] = classes
    return 1


def _cpp_scalar(s):
    s = _cpp_scalar_spelling(s)
    s = _CPP_TYPES[0].get(s, s)
    d = c_scalar(s)
    return s if d is not None and d != "void" else None


def _cpp_template(t):
    name = t.child_by_field_name("name")
    args = t.child_by_field_name("arguments")
    if name is None or args is None:
        return None
    kids = _named(args)
    if not kids:
        return None
    return (_text(name), kids[0])


def _cpp_named(node, using_std):
    """`named`: ("scalar", s), ("str", None), ("vec", s), or ("other", written)."""
    written = " ".join(_split_ws(_text(node)))
    other = ("other", written)

    def scalar():
        s = _cpp_scalar(written)
        return ("scalar", s) if s is not None else other

    def vector_of(arg):
        inner = arg.child_by_field_name("type")
        if inner is None:
            inner = arg
        r = _cpp_named(inner, using_std)
        if r[0] == "scalar" and r[1] != "bool":
            return ("vec", r[1])
        return other

    kind = node.type
    if kind in ("primitive_type", "sized_type_specifier"):
        return scalar()
    if kind == "type_identifier":
        if using_std and written == "string":
            return ("str", None)
        return scalar()
    if kind == "template_type" and using_std:
        t = _cpp_template(node)
        if t is not None and t[0] == "vector":
            return vector_of(t[1])
        return other
    if kind in ("qualified_identifier", "qualified_type_identifier"):
        scope = node.child_by_field_name("scope")
        scope = _text(scope) if scope is not None else ""
        name = node.child_by_field_name("name")
        if name is None or scope != "std":
            return other
        if name.type == "type_identifier" and _text(name) == "string":
            return ("str", None)
        if name.type == "type_identifier":
            return scalar()
        if name.type == "template_type":
            t = _cpp_template(name)
            if t is not None and t[0] == "vector":
                return vector_of(t[1])
            return other
        return other
    return other


def _cpp_dialect(named):
    if named[0] == "scalar":
        return c_scalar(named[1])
    if named[0] == "str":
        return "string"
    return c_scalar(named[1]) + "[]"


_CPP_FACADE = "write a free function with plain arguments over it (a facade) and bridge that"
_CPP_SUBSET = (
    "which the C++ subset does not take (integers, floating-point numbers, `bool`, "
    "`std::string`, `std::vector` of numbers)"
)


def _trim_end(s):
    """str::trim_end."""
    j = len(s)
    while j > 0 and s[j - 1] in _WS:
        j -= 1
    return s[:j]


def _cpp_spelled(named, by_ref):
    """Crossing::spelled."""
    if named[0] == "scalar":
        base = named[1]
    elif named[0] == "str":
        base = "std::string"
    else:
        base = "std::vector<%s>" % named[1]
    return "const %s &" % base if by_ref else base


def _cpp_unwrap(node):
    """`unwrap`: how a declarator wraps its name (the outermost wrapping), and the name."""
    wrap = "value"
    name = None
    while node is not None:
        kind = node.type
        if kind in ("reference_declarator", "abstract_reference_declarator"):
            if wrap == "value":
                wrap = "rref" if _trim_start(_text(node)).startswith("&&") else "ref"
            kids = _named(node)
            node = kids[0] if kids else None
        elif kind in ("pointer_declarator", "abstract_pointer_declarator"):
            if wrap == "value":
                wrap = "pointer"
            node = node.child_by_field_name("declarator")
        elif kind in ("array_declarator", "abstract_array_declarator"):
            if wrap == "value":
                wrap = "array"
            node = node.child_by_field_name("declarator")
        elif kind in ("function_declarator", "abstract_function_declarator"):
            if wrap == "value":
                wrap = "function"
            node = node.child_by_field_name("declarator")
        elif kind in ("identifier", "field_identifier"):
            name = _text(node)
            node = None
        else:
            node = None
    return wrap, name


def _cpp_param(p, using_std):
    """`param_crossing`: (True, dialect, spelled, name) or (False, reason)."""
    is_const = False
    other = None
    for child in _named(p):
        if child.type == "type_qualifier":
            if _text(child) == "const":
                is_const = True
            else:
                other = _text(child)
    ty = p.child_by_field_name("type")
    if ty is None:
        return (False, "has a parameter without a type")
    wrap, name = _cpp_unwrap(p.child_by_field_name("declarator"))
    written = " ".join(_split_ws(_text(p)))
    if name is not None:
        if written.endswith(name):
            written = written[: len(written) - len(name)]
        written = _trim_end(written)
    if other is not None:
        return (False, "takes a `%s` parameter (`%s`); %s" % (other, written, _CPP_FACADE))
    named = _cpp_named(ty, using_std)
    if named[0] == "other":
        t = named[1]
        cls = t.split("::")[-1] in _CPP_TYPES[1]
        if wrap == "ref" and not is_const:
            why = (
                "takes `%s`, a state object by non-const reference, which the C ABI shim "
                "cannot pass; %s" % (written, _CPP_FACADE)
            )
        elif wrap == "pointer" and cls:
            why = (
                "takes `%s`, a pointer to a state object, which the C ABI shim cannot pass; %s"
                % (written, _CPP_FACADE)
            )
        elif wrap in ("pointer", "array"):
            why = "takes a pointer (`%s`), which the C ABI shim does not pass; %s" % (
                written,
                _CPP_FACADE,
            )
        elif "vector<bool>" in t:
            why = "uses `%s`, which stores bits, not `bool`s; %s over `std::vector<int>`" % (
                t,
                _CPP_FACADE,
            )
        elif t == "long double":
            why = "uses `long double`, which Mojo cannot pass; %s" % _CPP_FACADE
        else:
            why = "uses `%s`, %s; %s" % (t, _CPP_SUBSET, _CPP_FACADE)
        return (False, why)
    if wrap == "value":
        by_ref = False
    elif wrap == "ref" and is_const:
        by_ref = True
    elif wrap == "ref":
        return (
            False,
            "writes through a non-const reference (`%s`); %s (one that returns the value)"
            % (written, _CPP_FACADE),
        )
    elif wrap == "rref":
        return (
            False,
            "takes an rvalue reference (`%s`); %s (one that takes it by value)"
            % (written, _CPP_FACADE),
        )
    elif wrap in ("pointer", "array"):
        return (
            False,
            "takes a pointer (`%s`), which the C ABI shim does not pass; %s"
            % (written, _CPP_FACADE),
        )
    else:
        return (False, "takes a function (`%s`); %s" % (written, _CPP_FACADE))
    return (True, _cpp_dialect(named), _cpp_spelled(named, by_ref), name)


def _cpp_without_comments(head):
    out = ""
    rest = head
    while "/*" in rest:
        start = rest.find("/*")
        out += rest[:start]
        end = rest[start:].find("*/")
        rest = "" if end < 0 else rest[start + end + 2 :]
    out += rest
    joined = " ".join(l.split("//")[0] for l in _lines(out))
    return " ".join(_split_ws(joined)).replace("( ", "(").replace(" )", ")")


def _cpp_fn(name, path, node, blocker, params=None, returns="unknown", native=None, proto=None):
    return {
        "name": name,
        "file": path,
        "line": _line(node),
        "params": params or [],
        "returns": returns,
        "native_return": native,
        "prototype": proto,
        "blocker": blocker,
    }


def _cpp_function(node, data, path, namespaces, using_std, refused):
    """`function`: an ExportedFn dict, or None (internal linkage, not a function, an
    operator, `main`)."""
    blocker = refused
    for spec in _named(node):
        word = _text(spec)
        if spec.type == "storage_class_specifier" and word == "static":
            return None
        if spec.type == "storage_class_specifier" and word == "inline":
            if blocker is None:
                blocker = (
                    "is `inline`, so its file need not emit a symbol the shim could call; "
                    "drop `inline` or %s" % _CPP_FACADE
                )
        elif spec.type == "type_qualifier" and word in ("constexpr", "consteval"):
            if blocker is None:
                blocker = (
                    "is `%s` (implicitly inline), so its file need not emit a symbol the "
                    "shim could call; %s" % (word, _CPP_FACADE)
                )
    function = node.child_by_field_name("declarator")
    if function is None:
        return None
    indirect = None
    while function.type in ("pointer_declarator", "reference_declarator"):
        if indirect is None:
            indirect = "pointer" if function.type == "pointer_declarator" else "reference"
        inner = function.child_by_field_name("declarator")
        if inner is None:
            kids = _named(function)
            if not kids:
                return None
            inner = kids[0]
        function = inner
    if function.type != "function_declarator":
        return None
    ident = function.child_by_field_name("declarator")
    if ident is None:
        return None
    qualified = list(namespaces)
    if ident.type == "qualified_identifier":
        full = "".join(_split_ws(_text(ident)))
        if "::" not in full:
            return None
        scope, name = full.rsplit("::", 1)
        parts = scope.split("::")
        class_scope = next((s for s in parts if s in _CPP_TYPES[1]), None)
        member = class_scope is not None or any(
            c.type == "type_qualifier" for c in _named(function)
        )
        qualified.extend(parts)
        qualified.append(name)
        if member:
            owner = class_scope if class_scope is not None else scope
            f = _cpp_fn(
                "::".join(qualified),
                path,
                node,
                "is a member function of `%s`: only free functions cross the C ABI shim; %s"
                % (owner, _CPP_FACADE),
            )
            f["member"] = True
            return f
    elif ident.type == "identifier":
        qualified.append(_text(ident))
    else:
        return None
    name = "::".join(qualified)
    if name == "main":
        return None
    params = []
    plist = function.child_by_field_name("parameters")
    if plist is not None:
        if any(c.type in ("...", "variadic_parameter") for c in plist.children):
            if blocker is None:
                blocker = "is variadic; %s" % _CPP_FACADE
        for i, p in enumerate(_named(plist)):
            if p.type in ("variadic_parameter_declaration", "variadic_parameter"):
                if blocker is None:
                    blocker = "is variadic; %s" % _CPP_FACADE
                continue
            if p.type not in ("parameter_declaration", "optional_parameter_declaration"):
                continue
            if trim(_text(p)) == "void":
                continue
            r = _cpp_param(p, using_std)
            if r[0]:
                params.append(
                    {"name": r[3] if r[3] is not None else "arg%d" % i, "ts_type": r[1], "native_type": r[2]}
                )
            else:
                if blocker is None:
                    blocker = r[1]
                params.append({"name": "arg%d" % i, "ts_type": "unknown", "native_type": None})
    ret = node.child_by_field_name("type")
    if ret is None:
        return None
    if indirect is not None:
        if blocker is None:
            head = trim(data[node.start_byte : function.start_byte].decode("utf-8"))
            blocker = (
                "returns a %s (`%s`): who owns it must be designed; %s (one that returns a copy)"
                % (indirect, head, _CPP_FACADE)
            )
        returns, native = "unknown", None
    elif ret.type == "placeholder_type_specifier":
        if blocker is None:
            blocker = "deduces its return type (`auto`): write the type out"
        returns, native = "unknown", None
    elif ret.type == "primitive_type" and _text(ret) == "void":
        returns, native = "void", "void"
    else:
        named = _cpp_named(ret, using_std)
        if named[0] == "other":
            if blocker is None:
                blocker = "returns `%s`, %s; %s" % (named[1], _CPP_SUBSET, _CPP_FACADE)
            returns, native = "unknown", None
        else:
            returns, native = _cpp_dialect(named), _cpp_spelled(named, False)
    body = node.child_by_field_name("body")
    if body is None:
        head = _text(node)
    else:
        head = data[node.start_byte : body.start_byte].decode("utf-8")
    return _cpp_fn(name, path, node, blocker, params, returns, native, _cpp_without_comments(head))


def _cpp_class(node, path, namespaces, template):
    """`class`: a class or struct with member functions (or a template), which stays in
    C++, as an ExportedClass dict; None otherwise."""
    body = node.child_by_field_name("body")
    if body is None:
        return None
    has_methods = False
    for m in _named(body):
        if m.type in ("function_definition", "template_declaration"):
            has_methods = True
        elif m.type in ("field_declaration", "declaration"):
            d = m.child_by_field_name("declarator")
            if d is not None and _cpp_unwrap(d)[0] == "function":
                has_methods = True
    if not has_methods and not template:
        return None
    n = node.child_by_field_name("name")
    name = _text(n) if n is not None else "(anonymous)"
    return {
        "name": "::".join(list(namespaces) + [name]),
        "file": path,
        "line": _line(node),
        "blocker": "is a %sclass: member functions do not cross the C ABI shim; %s"
        % ("template " if template else "", _CPP_FACADE),
    }


def _cpp_visit(node, data, path, namespaces, using_std, functions, classes):
    for child in _named(node):
        kind = child.type
        if kind == "namespace_definition":
            # An anonymous namespace has internal linkage: nothing in it is exported.
            name = child.child_by_field_name("name")
            if name is None:
                continue
            inner = list(namespaces) + [trim(s) for s in _text(name).split("::") if trim(s)]
            body = child.child_by_field_name("body")
            if body is not None:
                _cpp_visit(body, data, path, inner, using_std, functions, classes)
        elif kind == "function_definition":
            f = _cpp_function(child, data, path, namespaces, using_std, None)
            if f is not None:
                functions.append(f)
        elif kind == "template_declaration":
            for inner in _named(child):
                if inner.type == "function_definition":
                    f = _cpp_function(
                        inner,
                        data,
                        path,
                        namespaces,
                        using_std,
                        "is a template: the C ABI shim needs one concrete signature; %s for "
                        "each type you use" % _CPP_FACADE,
                    )
                    if f is not None:
                        functions.append(f)
                elif inner.type in ("class_specifier", "struct_specifier"):
                    c = _cpp_class(inner, path, namespaces, True)
                    if c is not None:
                        classes.append(c)
        elif kind == "linkage_specification":
            body = child.child_by_field_name("body")
            if body is not None:
                if body.type == "function_definition":
                    defs = [body]
                else:
                    defs = [n for n in _named(body) if n.type == "function_definition"]
                for d in defs:
                    f = _cpp_function(
                        d,
                        data,
                        path,
                        namespaces,
                        using_std,
                        'has C linkage (`extern "C"`): it is already a C function; move it '
                        "to a `.c` file and bridge it as C",
                    )
                    if f is not None:
                        functions.append(f)
        elif kind in ("class_specifier", "struct_specifier"):
            c = _cpp_class(child, path, namespaces, False)
            if c is not None:
                classes.append(c)
        elif kind == "declaration":
            for inner in _named(child):
                if inner.type in ("class_specifier", "struct_specifier"):
                    c = _cpp_class(inner, path, namespaces, False)
                    if c is not None:
                        classes.append(c)


def _cpp_full_exports(root, data, path, using_std):
    """cpp.rs `exports`: the free functions (one per name: an overloaded name is refused
    once, a name its port would share is refused after the first) and the classes."""
    functions = []
    classes = []
    _cpp_visit(root, data, path, [], using_std, functions, classes)
    counts = {}
    for f in functions:
        counts[f["name"]] = counts.get(f["name"], 0) + 1
    seen = set()
    kept = []
    for f in functions:
        if f["name"] not in seen:
            seen.add(f["name"])
            kept.append(f)
    ports = {}
    for f in kept:
        n = counts[f["name"]]
        if n > 1:
            f["blocker"] = (
                "is overloaded (%d definitions): the C ABI shim needs one signature per name; "
                "give each overload its own name in a facade" % n
            )
            continue
        if f["blocker"] is None:
            port = f["name"].split("::")[-1]
            if port in ports:
                f["blocker"] = (
                    "has the same name as `%s`, and the Mojo port names functions without "
                    "their namespace; rename one in a facade" % ports[port]
                )
            else:
                ports[port] = f["name"]
    return kept, classes


def _cpp_exports(root, using_std, data=b""):
    """cpp.rs `exports` for analyze: (blocked, the dialect types) of each function, then
    one refused entry per class."""
    functions, classes = _cpp_full_exports(root, data, "", using_std)
    # A member function is refused before its types are read.
    return [
        (
            f["blocker"] is not None,
            [] if f.get("member") else [p["ts_type"] for p in f["params"]] + [f["returns"]],
        )
        for f in functions
    ] + [(True, []) for _ in classes]


def _ascii_all(v):
    if isinstance(v, str):
        return v.isascii()
    if isinstance(v, dict):
        return all(_ascii_all(x) for x in v.values())
    if isinstance(v, (list, tuple)):
        return all(_ascii_all(x) for x in v)
    return True


def cpp_bridge_exports(root, files):
    """bridge's reading of a C++ unit (cpp.rs `exports` over each implementation file,
    after `use_types`): ("ok", items) (each file's functions, then its classes, marked by
    `is_class`) or ("decline",) when a file does not read as UTF-8, a tree has an error, or
    any name or type is outside ASCII."""
    items = []
    try:
        for rel in files:
            try:
                with open(os.path.join(root, rel), "rb") as f:
                    data = f.read()
                text = data.decode("utf-8")
            except (OSError, UnicodeError):
                return ("decline",)
            if not cpp_is_source(rel):
                continue
            tree = _parse("cpp", data)
            if tree.root_node.has_error:
                return ("decline",)
            fs, cs = _cpp_full_exports(tree.root_node, data, rel, "using namespace std" in text)
            # bridge reads each file's functions, then its classes.
            for f in fs:
                f["is_class"] = False
                items.append(f)
            for c in cs:
                c["is_class"] = True
                items.append(c)
    except (Decline, RecursionError, UnicodeError):
        return ("decline",)
    if not _ascii_all(items):
        return ("decline",)
    return ("ok", items)


def read_file(lang, path):
    """("unreadable",) when read_to_string would fail; ("decline", why) when the tree has an
    error (error recovery may differ between the cores); else ("ok", loc, imports, risks,
    loops, exports) with exports as (blocked, types) pairs."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        text = data.decode("utf-8")
    except (OSError, UnicodeError):
        return ("unreadable",)
    try:
        tree = _parse(lang, data)
        root = tree.root_node
        if root.has_error:
            raise Decline("a syntax error")
        if lang == "java":
            imports, risks, loops = _java_scan(root)
            exports = _java_exports(root) if path.endswith(".java") else []
        elif lang == "go":
            imports, risks, loops = _go_scan(root)
            go = path.endswith(".go") and not path.endswith("_test.go")
            exports = _go_exports(root) if go else []
        elif lang == "ruby":
            imports, risks, loops = _ruby_scan(root)
            exports = _ruby_exports(root) if path.endswith(".rb") else []
        elif lang == "csharp":
            imports, risks, loops = _cs_scan(root)
            exports = _cs_exports(root) if path.endswith(".cs") else []
        elif lang == "kotlin":
            imports, risks, loops = _kt_scan(root)
            exports = _kt_exports(root, data, path) if path.endswith(".kt") else []
        elif lang == "c":
            imports, risks, loops = _c_scan(root)
            exports = _c_exports(root) if path.endswith(".c") else []
        elif lang == "cpp":
            imports, risks, loops = _cpp_scan(root)
            using_std = "using namespace std" in text
            exports = _cpp_exports(root, using_std, data) if cpp_is_source(path) else []
        elif lang == "php":
            imports, risks, loops = _php_scan(root)
            # package_of's kebab case and the PSR-4 lookups use Unicode tables.
            if not all(i.isascii() for i in imports):
                raise Decline("an import outside ASCII")
            exports = _php_exports(root) if path.endswith(".php") else []
        else:
            raise Decline("no reader for " + lang)
        for _, types in exports:
            # js_only_reason splits types into words at characters Rust's tables call
            # alphanumeric.
            if not all(t.isascii() for t in types):
                raise Decline("a type outside ASCII")
    except Decline as e:
        return ("decline", str(e))
    except RecursionError:
        return ("decline", "too deep")
    except Exception as e:  # noqa: BLE001 - any failure of the bindings sends the case back
        return ("decline", "the bindings failed: " + type(e).__name__)
    return ("ok", loc(text), imports, risks, loops, exports)


# ---- Python exports for `bridge` (python.rs `exports`) -------------------------------------

_PY_SAFE_DECORATORS = ("cache", "lru_cache", "functools.cache", "functools.lru_cache", "staticmethod")


def _field(node, name):
    return node.child_by_field_name(name)


def _trim_matches(s, chars):
    i, j = 0, len(s)
    while i < j and s[i] in chars:
        i += 1
    while j > i and s[j - 1] in chars:
        j -= 1
    return s[i:j]


def _py_split_top(text, sep):
    """python.rs `split_top`."""
    out = []
    depth = 0
    current = ""
    for c in text:
        if c in "[(":
            depth += 1
        elif c in "])":
            depth -= 1
        if c == sep and depth == 0:
            out.append(trim(current))
            current = ""
        else:
            current += c
    if trim(current):
        out.append(trim(current))
    return out


def py_to_ts_type(hint):
    """python.rs `to_ts_type`."""
    hint = _trim_matches(trim(hint), "\"'")
    if hint.startswith("typing."):
        hint = hint[len("typing.") :]
    top = _py_split_top(hint, "|")
    if len(top) > 1:
        return " | ".join(py_to_ts_type(p) for p in top)
    i = hint.find("[")
    if i >= 0 and hint.endswith("]"):
        head, args = hint[:i], _py_split_top(hint[i + 1 : -1], ",")
    else:
        head, args = hint, []
    head = trim(head)
    if head.startswith("typing."):
        head = head[len("typing.") :]

    def arg(k):
        return py_to_ts_type(args[k]) if k < len(args) else "unknown"

    if head == "str":
        return "string"
    if head == "int":
        return "int"
    if head == "float":
        return "number"
    if head == "bool":
        return "boolean"
    if head in ("None", "NoneType"):
        return "undefined"
    if head in ("list", "List", "Sequence", "Iterable", "MutableSequence", "Collection"):
        a = arg(0)
        return ("(%s)" % a if "|" in a else a) + "[]"
    if head == "Optional":
        return arg(0) + " | undefined"
    if head == "Union":
        return " | ".join(py_to_ts_type(a) for a in args)
    if head in ("dict", "Dict", "Mapping", "MutableMapping") and arg(0) == "string":
        return "Record<string, %s>" % arg(1)
    if head == "Literal":
        return " | ".join(trim(a).replace('"', "'") for a in args)
    if head == "Callable":
        return "(...args: unknown[]) => unknown"
    if head in ("Any", "object"):
        return "unknown"
    return head


def _py_unwrap_decorated(node):
    if node.type != "decorated_definition":
        return [], node
    decorators = []
    for d in _named(node):
        if d.type != "decorator":
            continue
        t = trim(_trim_start_matches(_text(d), "@"))
        decorators.append(t.split("(")[0])
    return decorators, (_field(node, "definition") or node)


def _py_entry_calls(root, main_module):
    out = []

    def collect(node):
        for n in _walk(node):
            if n.type == "call":
                f = _field(n, "function")
                if f is not None and f.type == "identifier":
                    out.append(_text(f))

    for statement in _named(root):
        guard = False
        if statement.type == "if_statement":
            c = _field(statement, "condition")
            if c is not None:
                c = _text(c).replace(" ", "").replace("'", '"')
                guard = c == '__name__=="__main__"' or c == '"__main__"==__name__'
        if guard:
            body = _field(statement, "consequence")
            if body is not None:
                collect(body)
        elif main_module and statement.type == "expression_statement":
            collect(statement)
    return out


def _py_dunder_all(root):
    """python.rs `dunder_all`: a top-level statement with no assignment in it ends the search
    (its `?`)."""
    for statement in _named(root):
        assignment = next((n for n in _named(statement) if n.type == "assignment"), None)
        if assignment is None:
            return None
        left = _field(assignment, "left")
        if left is not None and _text(left) == "__all__":
            right = _field(assignment, "right")
            if right is None:
                return None
            return [_trim_matches(_text(n), "\"'") for n in _named(right) if n.type == "string"]
    return None


def _py_infer_numbers(params, body):
    unknown = [p["name"] for p in params if p["ts_type"] == "unknown" and p["default"] is None]
    if not unknown:
        return
    numeric = []

    def is_number(n):
        return n.type in ("integer", "float")

    for n in _walk(body):
        if n.type == "binary_operator":
            o = _field(n, "operator")
            op = _text(o) if o is not None else ""
            l, r = _field(n, "left"), _field(n, "right")
            if l is None or r is None:
                continue
            if op in ("-", "*", "/", "//", "**"):
                operands = [l, r]
            elif op in ("+", "%") and (is_number(l) or is_number(r)):
                operands = [l, r]
            else:
                continue
        elif n.type == "comparison_operator":
            parts = _named(n)
            if not any(is_number(p) for p in parts):
                continue
            operands = parts
        elif n.type == "call":
            f = _field(n, "function")
            f = _text(f) if f is not None else ""
            if f not in ("min", "max", "abs", "round", "float", "int", "divmod") and not f.startswith("math."):
                continue
            a = _field(n, "arguments")
            operands = _named(a) if a is not None else []
        else:
            continue
        for o in operands:
            if o.type == "identifier":
                name = _text(o)
                if name in unknown and name not in numeric:
                    numeric.append(name)
    for p in params:
        if p["name"] in numeric:
            p["ts_type"] = "number"


def _py_param(name, ts_type, optional=False, default=None):
    return {"name": name, "ts_type": ts_type, "optional": optional, "default": default, "keyword_only": False}


_PY_LITERAL_TYPES = {"integer": "int", "float": "number", "string": "string", "true": "boolean", "false": "boolean"}


def _py_parameters(node, method):
    params = []
    blocker = None
    keyword_only = False
    for i, p in enumerate(_named(node)):
        if p.type == "identifier":
            param = _py_param(_text(p), "unknown")
        elif p.type == "typed_parameter":
            kids = _named(p)
            inner = kids[0] if kids else None
            t = _field(p, "type")
            ty = py_to_ts_type(_text(t)) if t is not None else "unknown"
            kind = inner.type if inner is not None else None
            if kind == "list_splat_pattern":
                blocker = "takes `*args`"
                continue
            if kind == "dictionary_splat_pattern":
                blocker = "takes `**kwargs`"
                continue
            param = _py_param(_text(inner) if inner is not None else "", ty)
        elif p.type in ("default_parameter", "typed_default_parameter"):
            value = _field(p, "value")
            default = _text(value) if value is not None else None
            t = _field(p, "type")
            if t is not None:
                ty = py_to_ts_type(_text(t))
            else:
                ty = _PY_LITERAL_TYPES.get(value.type if value is not None else None, "unknown")
            n = _field(p, "name")
            param = _py_param(_text(n) if n is not None else "", ty, True, default)
        elif p.type == "list_splat_pattern":
            blocker = "takes `*args`"
            continue
        elif p.type == "dictionary_splat_pattern":
            blocker = "takes `**kwargs`"
            continue
        elif p.type == "keyword_separator":
            keyword_only = True
            continue
        else:
            continue
        if method and i == 0 and param["name"] in ("self", "cls"):
            continue
        param["keyword_only"] = keyword_only
        params.append(param)
    return params, blocker


def _py_function(path, node, decorators, method):
    name = _field(node, "name")
    parameters = _field(node, "parameters")
    if name is None or parameters is None:
        return None
    params, blocker = _py_parameters(parameters, method)
    body = _field(node, "body")
    if body is not None:
        _py_infer_numbers(params, body)
    generator = False
    if body is not None:
        for n in _walk(body):
            if n.type == "yield":
                generator = True
    if body is not None:
        names = [p["name"] for p in params]
        for n in _walk(body):
            if n.type == "call":
                f = _field(n, "function")
                if f is not None and f.type == "identifier" and _text(f) in names and blocker is None:
                    blocker = "calls its parameter `%s`: a callable" % _text(f)
    for d in decorators:
        if d not in _PY_SAFE_DECORATORS:
            if blocker is None:
                blocker = "decorated with `@%s`" % d
            break
    r = _field(node, "return_type")
    return {
        "name": _text(name),
        "file": path,
        "line": _line(node),
        "params": params,
        "returns": py_to_ts_type(_text(r)) if r is not None else "unknown",
        "is_async": _text(node).startswith("async"),
        "is_generator": generator,
        "blocker": blocker,
    }


def _py_words(text):
    """Splits at characters other than alphanumerics and `_` (ASCII text only)."""
    out = []
    word = ""
    for c in text:
        if c.isalnum() or c == "_":
            word += c
        else:
            out.append(word)
            word = ""
    out.append(word)
    return out


def _py_class(path, node, decorators):
    name = _field(node, "name")
    body = _field(node, "body")
    if name is None or body is None:
        return None
    name = _text(name)
    blockers = []
    bases = _field(node, "superclasses")
    if bases is not None:
        names = [_text(b) for b in _named(bases) if _text(b) != "object"]
        if names:
            blockers.append("inherits from " + ", ".join(names))
    if decorators:
        blockers.append("decorated with `@%s`" % decorators[0])
    constructor = []
    methods = []
    for item in _named(body):
        decs, definition = _py_unwrap_decorated(item)
        if definition.type == "function_definition":
            m = _field(definition, "name")
            method_name = _text(m) if m is not None else ""
            if method_name == "__init__":
                parameters = _field(definition, "parameters")
                if parameters is None:
                    return None
                params, blocker = _py_parameters(parameters, True)
                constructor = params
                if blocker is not None:
                    blockers.append(blocker)
                init_body = _field(definition, "body")
                if init_body is not None:
                    for n in _walk(init_body):
                        if n.type == "assignment":
                            left = _field(n, "left")
                            if left is not None and _text(left).startswith("self."):
                                attr = _text(left)[len("self.") :]
                                if not attr.startswith("_") and "." not in attr:
                                    blockers.append("public attribute `%s`" % attr)
            elif method_name.startswith("__") and method_name.endswith("__"):
                blockers.append("special method `%s`" % method_name)
            elif method_name.startswith("_"):
                pass
            elif decs:
                blockers.append("`@%s` method `%s`" % (decs[0], method_name))
            else:
                f = _py_function(path, definition, [], True)
                if f is not None:
                    if f["is_async"] or f["is_generator"]:
                        blockers.append("async or generator method `%s`" % f["name"])
                    if any(w == name or w == "Self" for w in _py_words(f["returns"])):
                        blockers.append("method `%s` returns an instance" % f["name"])
                    methods.append(f)
        elif definition.type == "expression_statement":
            assignment = next((n for n in _named(definition) if n.type == "assignment"), None)
            left = _field(assignment, "left") if assignment is not None else None
            if left is not None and not _text(left).startswith("_"):
                blockers.append("public class attribute `%s`" % _text(left))
    blockers = sorted(set(blockers), key=lambda s: s.encode("utf-8"))
    return {
        "name": name,
        "file": path,
        "line": _line(node),
        "constructor": constructor,
        "methods": methods,
        "blocker": ", ".join(blockers) if blockers else None,
    }


def _py_ascii(value):
    if isinstance(value, str):
        return value.isascii()
    if isinstance(value, dict):
        return all(_py_ascii(v) for v in value.values())
    if isinstance(value, list):
        return all(_py_ascii(v) for v in value)
    return True


def python_exports(path, rel):
    """python.rs `exports` of the file at `path` (`rel` from the root): ("ok", functions,
    classes) as dicts, ("unreadable",) when read_to_string fails, or ("decline", why) when the
    tree has an error or a name, type or default is outside ASCII (Rust's Unicode tables)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        data.decode("utf-8")
    except (OSError, UnicodeError):
        return ("unreadable",)
    try:
        root = _parse("python", data).root_node
        if root.has_error:
            raise Decline("a syntax error")
        names = _py_dunder_all(root)
        entry = _py_entry_calls(root, rel.endswith("__main__.py"))
        functions = []
        classes = []
        for item in _named(root):
            decorators, definition = _py_unwrap_decorated(item)
            if definition.type == "function_definition":
                f = _py_function(rel, definition, decorators, False)
                if f is None:
                    continue
                r = _field(definition, "return_type")
                parser = r is not None and _text(r).endswith("ArgumentParser")
                if parser or f["name"] in entry:
                    f["blocker"] = (
                        "a command-line entry point: it stays in Python, and `app front-door` "
                        "takes the command line over when the whole app moves"
                    )
                public = not f["name"].startswith("_") if names is None else f["name"] in names
                if public:
                    functions.append(f)
            elif definition.type == "class_definition":
                c = _py_class(rel, definition, decorators)
                if c is None:
                    continue
                public = not c["name"].startswith("_") if names is None else c["name"] in names
                if public:
                    classes.append(c)
        if not (_py_ascii(functions) and _py_ascii(classes)):
            raise Decline("text outside ASCII")
    except Decline as e:
        return ("decline", str(e))
    except RecursionError:
        return ("decline", "too deep")
    except Exception as e:  # noqa: BLE001 - any failure of the bindings sends the case back
        return ("decline", "the bindings failed: " + type(e).__name__)
    return ("ok", functions, classes)


def python_dataclass_types(path):
    """python.rs `dataclass_types` of the file at `path`, for `record`: ("ok", [(name, text)]),
    ("unreadable",) when read_to_string fails, or ("decline", why) when the tree has an error,
    a field's target is not a name, or text is outside ASCII."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        data.decode("utf-8")
    except (OSError, UnicodeError):
        return ("unreadable",)
    try:
        root = _parse("python", data).root_node
        if root.has_error:
            raise Decline("a syntax error")
        out = []
        for item in _named(root):
            decorators, definition = _py_unwrap_decorated(item)
            if definition.type != "class_definition" or not any("dataclass" in d for d in decorators):
                continue
            name = _field(definition, "name")
            if name is None:
                continue
            fields = []
            body = _field(definition, "body")
            if body is not None:
                for statement in _named(body):
                    assignment = next((n for n in _named(statement) if n.type == "assignment"), None)
                    if assignment is None:
                        continue
                    left, ty = _field(assignment, "left"), _field(assignment, "type")
                    if left is None or ty is None:
                        continue
                    hint = _text(ty)
                    if hint.startswith("ClassVar") or hint.startswith("typing.ClassVar"):
                        continue
                    if left.type != "identifier":
                        raise Decline("a field that is not a name")
                    optional = "?" if _field(assignment, "right") is not None else ""
                    fields.append("%s%s: %s" % (_text(left), optional, py_to_ts_type(hint)))
            n = _text(name)
            out.append((n, '{ $object: "%s"; attrs: { %s } }' % (n, "; ".join(fields))))
        if not all(n.isascii() and t.isascii() and '"' not in n for n, t in out):
            raise Decline("text outside ASCII")
    except Decline as e:
        return ("decline", str(e))
    except RecursionError:
        return ("decline", "too deep")
    except Exception as e:  # noqa: BLE001 - any failure of the bindings sends the case back
        return ("decline", "the bindings failed: " + type(e).__name__)
    return ("ok", out)
