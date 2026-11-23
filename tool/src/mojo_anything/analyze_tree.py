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

# The grammar module of each language.
_GRAMMARS = {"java": "tree_sitter_java", "go": "tree_sitter_go"}


class Decline(Exception):
    pass


def find_bindings(repo):
    """1 when tree-sitter's bindings import: from this interpreter's path, else from the
    repository's pixi environment (the Mojo tool's CPython is the first `python3` on PATH,
    which outside `pixi run` is not the environment's); 0 otherwise (every file declines)."""
    try:
        import tree_sitter  # noqa: F401

        return 1
    except ImportError:
        pass
    v = "python%d.%d" % sys.version_info[:2]
    site = os.path.join(repo, ".pixi", "envs", "default", "lib", v, "site-packages")
    if os.path.isdir(site) and site not in sys.path:
        sys.path.append(site)
    try:
        import tree_sitter  # noqa: F401,F811

        return 1
    except ImportError:
        return 0


def _language(lang):
    if lang not in _LANGUAGES:
        if lang not in _GRAMMARS:
            raise Decline("no grammar for " + lang)
        try:
            import tree_sitter

            m = importlib.import_module(_GRAMMARS[lang])
            _LANGUAGES[lang] = tree_sitter.Language(m.language())
        except (ImportError, ValueError) as e:
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
                raise _NotBridgeable("keys")
            return "Record<string, " + go_to_ts(rest[close + 1 :], structs) + ">"
    if t.startswith("*") or t.startswith("func") or t.startswith("chan") or t.startswith("<-chan"):
        raise _NotBridgeable(t)
    if t == "any" or t.startswith("interface") or t.startswith("[") or t == "error":
        raise _NotBridgeable(t)
    if "." in t or not _upper_first(t):
        raise _NotBridgeable(t)
    return structs.get(t, "unknown")


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


# ---- the entry point ---------------------------------------------------------------------


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
    return ("ok", loc(text), imports, risks, loops, exports)
