"""What `analyze` reads from a Python file, through CPython's `ast` where the Rust
tool walks tree-sitter-python's tree (src/lang/python.rs `scan` and `exports`).

Embedded into the Mojo tool by tool/embedded.py; the planner, the report and the
bridge rules are Mojo (analyze.mojo, plan.mojo, python_lang.mojo). Where `ast` and
tree-sitter could see the file differently (a syntax error, grammar newer than
tree-sitter-python 0.25 reads, comments inside brackets, parentheses tree-sitter
keeps as nodes, characters that end lines for one and not the other), the file
is declined and the whole command goes to the Phase 1 binary before anything is
written.
"""

import ast
import io
import os
import re
import sys
import tokenize
import tomllib

# The screens below are written for the `ast` and `tokenize` of these
# versions (3.11 has no FSTRING_START; 3.14 adds t-strings, which
# tree-sitter-python 0.25 reads as strings): another interpreter declines
# every file.
_SCREENED = ((3, 12), (3, 13))
_VERSION = tuple(sys.version_info[:2])


class Decline(Exception):
    pass


def _need(cond, why):
    if not cond:
        raise Decline(why)


# Characters that end a line, or start one, differently for tree-sitter (only
# `\n` ends a line) and CPython, or that Python's str.strip treats as space and
# Rust's trim does not.
_BAD = set("\r\x00\x0b\x0c\x1c\x1d\x1e\x1f\x85  ﻿")

# char::is_whitespace (White_Space).
_WS = set(
    "\t\n\x0b\x0c\r \x85\xa0        "
    "        　"
)


def loc(text):
    """syntax::loc: lines (str::lines) that are not blank."""
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    n = 0
    for line in lines:
        if line.endswith("\r"):
            line = line[:-1]
        if any(c not in _WS for c in line):
            n += 1
    return n


class _Src:
    def __init__(self, text):
        self.text = text
        self.lines = text.split("\n")
        self.starts = []
        off = 0
        for line in self.lines:
            self.starts.append(off)
            off += len(line) + 1

    def off(self, lineno, col):
        line = self.lines[lineno - 1]
        return self.starts[lineno - 1] + len(line.encode("utf-8")[:col].decode("utf-8"))

    def start(self, node):
        return self.off(node.lineno, node.col_offset)

    def end(self, node):
        return self.off(node.end_lineno, node.end_col_offset)

    def seg(self, node):
        return self.text[self.start(node) : self.end(node)]

    def prev(self, i):
        """Index of the last character before `i` that is not a space, a tab,
        a newline or a line-continuation backslash (-1 for none)."""
        j = i - 1
        while j >= 0 and self.text[j] in " \t\n\\":
            j -= 1
        return j

    def prev_char(self, i):
        j = self.prev(i)
        return self.text[j] if j >= 0 else ""


# ---- tokens ------------------------------------------------------------------


def _quote(prefixed):
    body = prefixed.lstrip("rRbBuUfF")
    return body[0], body[:3] in ('"""', "'''")


def _tokens(text):
    """Screens the token stream; returns the comments' (line, col) and the
    set of lines whose first token is `@`."""
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(text).readline))
    except (tokenize.TokenError, SyntaxError):
        raise Decline("tokenize")
    depth = 0
    comments = []
    decorator_lines = set()
    first_on_line = {}
    fstrings = []  # (quote, triple, line)
    line_start = True
    for t in toks:
        tt = t.type
        if tt in (tokenize.NEWLINE, tokenize.NL, tokenize.INDENT, tokenize.DEDENT, tokenize.ENCODING):
            line_start = True
            continue
        if tt == tokenize.ENDMARKER:
            continue
        if tt == tokenize.COMMENT:
            _need(depth == 0, "a comment inside brackets")
            comments.append(t.start)
            continue
        first_on_line.setdefault(t.start[0], t.string)
        if tt == tokenize.NAME:
            _need(t.string.isascii(), "a name outside ASCII")
            _need(not (line_start and t.string in ("match", "case", "type")), "a soft keyword starts a line")
        line_start = False
        if fstrings:
            q, triple, line = fstrings[-1]
            if not triple:
                _need(t.start[0] == line and t.end[0] == line, "a single-quoted f-string over lines")
        if tt == tokenize.OP:
            if t.string in ("(", "[", "{"):
                depth += 1
            elif t.string in (")", "]", "}"):
                depth -= 1
        elif tt == tokenize.STRING:
            if fstrings:
                q, _ = _quote(t.string)
                _need(all(q != f[0] for f in fstrings), "a nested string reuses an f-string's quote")
                _need("\\" not in t.string, "a backslash inside an f-string's field")
        elif tt == tokenize.FSTRING_START:
            q, triple = _quote(t.string)
            if fstrings:
                _need(all(q != f[0] for f in fstrings), "a nested f-string reuses a quote")
            fstrings.append((q, triple, t.start[0]))
        elif tt == tokenize.FSTRING_END:
            fstrings.pop()
    for line, first in first_on_line.items():
        if first == "@":
            decorator_lines.add(line)
    for line, _ in comments:
        _need(line not in decorator_lines, "a comment on a decorator line")
    return comments


def _string_starts(seg):
    """How many string literals start at the top level of `seg` (more than
    one: an implicit concatenation, tree-sitter's concatenated_string)."""
    try:
        toks = list(tokenize.generate_tokens(io.StringIO(seg).readline))
    except (tokenize.TokenError, SyntaxError):
        raise Decline("tokenize a string")
    n = 0
    depth = 0
    for t in toks:
        if t.type == tokenize.STRING and depth == 0:
            n += 1
        elif t.type == tokenize.FSTRING_START:
            if depth == 0:
                n += 1
            depth += 1
        elif t.type == tokenize.FSTRING_END:
            depth -= 1
    return n


# ---- screens -----------------------------------------------------------------


def _annotations(fn):
    a = fn.args
    for arg in a.posonlyargs + a.args + a.kwonlyargs + ([a.vararg] if a.vararg else []) + ([a.kwarg] if a.kwarg else []):
        if arg.annotation is not None:
            yield arg.annotation, ":"
    if fn.returns is not None:
        yield fn.returns, ">"


def _screen(tree, src):
    for node in ast.walk(tree):
        _need(not isinstance(node, (ast.Match, ast.TypeAlias, ast.TryStar)), "newer grammar")
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            _need(not node.type_params, "type parameters")
            for d in node.decorator_list:
                i = src.start(d)
                j = src.prev(i)
                _need(j >= 0 and src.text[j] == "@" and "\n" not in src.text[j:i], "a decorator in parentheses")
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            for ann, before in _annotations(node):
                _need(src.prev_char(src.start(ann)) == before, "an annotation in parentheses")
                _check_annotation(ann, src)
            a = node.args
            for star in (a.vararg, a.kwarg):
                if star is not None:
                    _need(src.prev_char(src.start(star)) == "*" and src.text[src.start(star) - 1] == "*", "a splat apart from its name")
        if isinstance(node, ast.AnnAssign):
            _need(src.start(node.target) == src.start(node), "a target in parentheses")
            _need(src.prev_char(src.start(node.annotation)) == ":", "an annotation in parentheses")
            _check_annotation(node.annotation, src)
        if isinstance(node, ast.Assign):
            _need(src.start(node.targets[0]) == src.start(node), "a target in parentheses")
            for t in node.targets[1:]:
                _need(src.prev_char(src.start(t)) == "=", "a target in parentheses")
        if isinstance(node, ast.Call):
            _need(src.start(node) == src.start(node.func), "a callee in parentheses")
        if isinstance(node, ast.Subscript):
            s = node.slice
            elts = s.elts if isinstance(s, ast.Tuple) else [s]
            _need(not any(isinstance(e, ast.Starred) for e in elts), "a starred index")
        if isinstance(node, (ast.With, ast.AsyncWith)):
            seg = src.seg(node)
            k = seg.index("with") + 4
            _need(not seg[k:].lstrip(" \t\\\n").startswith("("), "a parenthesized with")


def _check_annotation(ann, src):
    _need(src.seg(ann).isascii(), "an annotation outside ASCII")
    for n in ast.walk(ann):
        # `int | None` may read as tree-sitter's union_type, not a binary operator.
        _need(not isinstance(n, (ast.BinOp, ast.Slice)), "an operator in an annotation")


# ---- risks (src/risks.rs) ----------------------------------------------------


def compiled_by(decorator):
    d = decorator.strip().lstrip("@")
    name = d.split("(")[0].strip()
    if name.startswith("cython."):
        return "Cython"
    if "." in name:
        module, last = name.rsplit(".", 1)
    else:
        module, last = "", name
    if module == "jax" or module.startswith("jax."):
        return "JAX" if last == "jit" else None
    numba_module = module in ("", "numba", "nb", "cuda", "numba.cuda")
    numba_name = last in ("jit", "njit", "vectorize", "guvectorize", "cfunc", "stencil", "generated_jit")
    return "numba" if numba_module and numba_name else None


def regex_needs_fancy(pattern, flags):
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


_CLOCK = (
    "time.time",
    "time.time_ns",
    "datetime.now",
    "datetime.utcnow",
    "datetime.today",
    "date.today",
    "datetime.datetime.now",
    "datetime.datetime.utcnow",
    "datetime.date.today",
    "uuid.uuid4",
    "os.urandom",
)


def _is_string(node, src, own_paren=-1):
    """Whether tree-sitter reads `node` as a `string`: one literal, not an
    implicit concatenation, not in parentheses of its own (`own_paren` is
    the offset of the bracket that belongs to the call or tuple around it)."""
    if isinstance(node, ast.Constant) and isinstance(node.value, (str, bytes)):
        pass
    elif isinstance(node, ast.JoinedStr):
        pass
    else:
        return False
    j = src.prev(src.start(node))
    if j >= 0 and src.text[j] == "(" and j != own_paren:
        return False
    return _string_starts(src.seg(node)) == 1


def _call_paren(node, src):
    """Offset of a call's argument list bracket."""
    k = src.end(node.func)
    while src.text[k] in " \t\\\n":
        k += 1
    _need(src.text[k] == "(", "a call without its bracket")
    return k


def _scan(tree, src):
    risks = {}
    imports = []
    loops = 0

    def add(name, line, times=1):
        risks.setdefault(name, []).extend([line] * times)

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for a in node.names:
                _need(src.text[src.start(a) :].startswith(a.name), "an import name with spaces")
                imports.append((a.name, False))
        elif isinstance(node, ast.ImportFrom):
            if node.module == "__future__" and node.level == 0:
                continue
            module = "." * node.level + (node.module or "")
            m = re.match(r"from\s*(.*?)\s*import(?![A-Za-z0-9_])", src.seg(node), re.S)
            _need(m is not None and m.group(1) == module, "a module name with spaces")
            imports.append((module, False))
            sep = "" if module.endswith(".") else "."
            for a in node.names:
                if a.name == "*":
                    continue
                _need(src.text[src.start(a) :].startswith(a.name), "an import name with spaces")
                imports.append((module + sep + a.name, True))
        elif isinstance(node, ast.Call):
            callee = src.seg(node.func)
            line = node.lineno
            if callee in ("eval", "exec", "compile", "__import__", "importlib.import_module"):
                add("dynamic-code", line)
            elif callee in ("getattr", "setattr", "hasattr", "delattr", "isinstance", "type"):
                add("dynamic-typing", line)
            elif callee in ("globals", "locals", "vars"):
                add("reflection", line)
            elif callee in _CLOCK:
                add("clock-and-random", line)
            elif callee.startswith("random.") or callee.startswith("secrets."):
                add("clock-and-random", line)
            elif callee in ("set", "frozenset"):
                add("unordered-iteration", line)
            elif callee in ("threading.Thread", "Thread", "ThreadPoolExecutor", "ProcessPoolExecutor", "asyncio.gather"):
                add("concurrency", line)
            elif callee.startswith("re."):
                items = list(node.args) + list(node.keywords)
                items.sort(key=lambda n: src.start(n))
                if items and isinstance(items[0], ast.GeneratorExp):
                    raise Decline("a generator argument to re")
                first = items[0] if items else None
                if first is not None and _is_string(first, src, _call_paren(node, src)):
                    if regex_needs_fancy(src.seg(first), ""):
                        add("regex-syntax", line)
                else:
                    add("dynamic-regex", line)
            elif callee.endswith(".find") or callee.endswith(".index") or callee.endswith(".rfind"):
                add("string-offsets", line)
        elif isinstance(node, ast.Subscript):
            s = node.slice
            elts = s.elts if isinstance(s, ast.Tuple) else [s]
            if any(isinstance(e, ast.Slice) for e in elts):
                add("string-offsets", node.lineno)
        elif isinstance(node, (ast.BinOp, ast.AugAssign)):
            op = node.op
            if isinstance(op, (ast.FloorDiv, ast.Mod)):
                add("division-semantics", node.lineno)
            elif isinstance(op, (ast.Pow, ast.LShift)):
                add("integer-semantics", node.lineno)
            elif isinstance(node, ast.BinOp) and isinstance(op, (ast.BitAnd, ast.BitOr, ast.BitXor, ast.RShift)):
                add("number-semantics", node.lineno)
        elif isinstance(node, (ast.Set, ast.SetComp)):
            add("unordered-iteration", node.lineno)
        elif isinstance(node, (ast.Raise, ast.Try)):
            add("exceptions", node.lineno)
        elif isinstance(node, (ast.Yield, ast.YieldFrom)):
            # tree-sitter's `yield` node and its `yield` keyword: both are visited.
            add("generators", node.lineno, 2)
        elif isinstance(node, ast.Await):
            add("async", node.lineno, 2)
        elif isinstance(node, (ast.For, ast.AsyncFor, ast.While, ast.ListComp, ast.DictComp, ast.GeneratorExp)):
            loops += 1
        elif isinstance(node, ast.ClassDef):
            if _class_paren(node, src) is not None:
                add("class-inheritance", node.lineno)
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            if isinstance(node, ast.AsyncFunctionDef):
                add("async", node.lineno)
            if any(p.annotation is None and d is None and p.arg not in ("self", "cls") for p, d in _plain_params(node.args)):
                add("dynamic-typing", node.lineno)
        elif isinstance(node, ast.Assign):
            for t in node.targets:
                left = src.seg(t)
                if "." in left and not left.startswith("self.") and left[:1].isupper():
                    add("monkeypatching", t.lineno)
        elif isinstance(node, ast.AnnAssign):
            left = src.seg(node.target)
            if "." in left and not left.startswith("self.") and left[:1].isupper():
                add("monkeypatching", node.lineno)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
            for d in node.decorator_list:
                if compiled_by(src.seg(d)) is not None:
                    add("already-compiled", d.lineno)
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
            a = node.args
            for arg in a.posonlyargs + a.args + a.kwonlyargs + ([a.vararg] if a.vararg else []) + ([a.kwarg] if a.kwarg else []):
                if arg.annotation is not None:
                    t = src.seg(arg.annotation)
                    if "ndarray" in t or "NDArray" in t:
                        add("array-parameters", arg.lineno)
    out = []
    for name, lines in risks.items():
        out.append((name, sorted(lines)))
    return imports, out, loops


def _plain_params(args):
    """(arg, default) of every parameter with a name of its own (no splats),
    in order."""
    pos = args.posonlyargs + args.args
    defaults = [None] * (len(pos) - len(args.defaults)) + list(args.defaults)
    out = list(zip(pos, defaults))
    out += list(zip(args.kwonlyargs, args.kw_defaults))
    return out


def _class_paren(node, src):
    """Offset of the `(` after a class's name, None for a class without one
    (tree-sitter's `superclasses` field)."""
    seg_start = src.start(node)
    text = src.text
    i = seg_start + len("class")
    while text[i] in " \t\\\n":
        i += 1
    while i < len(text) and (text[i].isalnum() or text[i] == "_"):
        i += 1
    while text[i] in " \t\\\n":
        i += 1
    return i if text[i] == "(" else None


# ---- exports -----------------------------------------------------------------

_SAFE_DECORATORS = ("cache", "lru_cache", "functools.cache", "functools.lru_cache", "staticmethod")


def _decorators(node, src):
    return [src.seg(d).split("(")[0] for d in getattr(node, "decorator_list", [])]


def _parameters(args, method, src):
    """(names, annotation texts, blocked) of python.rs `parameters`."""
    items = []
    pos = args.posonlyargs + args.args
    for a in pos:
        items.append(("param", a))
    if args.posonlyargs:
        items.insert(len(args.posonlyargs), ("sep", None))
    if args.vararg is not None:
        items.append(("splat", None))
    elif args.kwonlyargs:
        items.append(("sep", None))
    for a in args.kwonlyargs:
        items.append(("param", a))
    if args.kwarg is not None:
        items.append(("splat", None))
    names = []
    types = []
    blocked = False
    for i, (kind, a) in enumerate(items):
        if kind == "splat":
            blocked = True
            continue
        if kind == "sep":
            continue
        if method and i == 0 and a.arg in ("self", "cls"):
            continue
        names.append(a.arg)
        types.append(src.seg(a.annotation) if a.annotation is not None else "")
    return names, types, blocked


def _function(node, src, decorators, method):
    names, types, blocked = _parameters(node.args, method, src)
    generator = False
    for st in node.body:
        for n in ast.walk(st):
            if isinstance(n, (ast.Yield, ast.YieldFrom)):
                generator = True
            if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id in names:
                blocked = True
    if any(d not in _SAFE_DECORATORS for d in decorators):
        blocked = True
    returns = src.seg(node.returns) if node.returns is not None else ""
    return {
        "name": node.name,
        "blocked": blocked,
        "generator": generator,
        "async": isinstance(node, ast.AsyncFunctionDef),
        "types": types,
        "returns": returns,
    }


def _class(node, src, decorators):
    blocked = False
    paren = _class_paren(node, src)
    if paren is not None:
        items = sorted(list(node.bases) + list(node.keywords), key=lambda n: src.start(n))
        for k, item in enumerate(items):
            j = src.prev(src.start(item))
            grouped = src.text[j] == "(" and not (k == 0 and j == paren)
            if grouped or not (isinstance(item, ast.Name) and item.id == "object"):
                blocked = True
    if decorators:
        blocked = True
    returns = []
    for st in node.body:
        decs = _decorators(st, src)
        if isinstance(st, (ast.FunctionDef, ast.AsyncFunctionDef)):
            name = st.name
            if name == "__init__":
                _, _, b = _parameters(st.args, True, src)
                blocked = blocked or b
                for s in st.body:
                    for n in ast.walk(s):
                        targets = n.targets if isinstance(n, ast.Assign) else [n.target] if isinstance(n, ast.AnnAssign) else []
                        for t in targets:
                            left = src.seg(t)
                            if left.startswith("self."):
                                attr = left[5:]
                                if not attr.startswith("_") and "." not in attr:
                                    blocked = True
            elif name.startswith("__") and name.endswith("__"):
                blocked = True
            elif name.startswith("_"):
                pass
            elif decs:
                blocked = True
            else:
                f = _function(st, src, [], True)
                if f["async"] or f["generator"]:
                    blocked = True
                returns.append(f["returns"])
        elif isinstance(st, ast.Assign):
            if not src.seg(st.targets[0]).startswith("_"):
                blocked = True
        elif isinstance(st, ast.AnnAssign):
            if not src.seg(st.target).startswith("_"):
                blocked = True
    return {"name": node.name, "blocked": blocked, "returns": returns}


def _named_children(node):
    if isinstance(node, (ast.List, ast.Tuple, ast.Set)):
        return list(node.elts)
    if isinstance(node, ast.BinOp):
        return [node.left, node.right]
    if isinstance(node, (ast.Name, ast.Attribute, ast.Call, ast.Constant)):
        return []
    raise Decline("an __all__ of another shape")


def _grouping_parens(seg, own_first):
    """True when the value of `__all__` holds parentheses tree-sitter keeps as a
    parenthesized_expression (ast drops them): a `(` after an operator, a comma
    or an opening bracket, other than a tuple's own, which must close last."""
    try:
        toks = [
            t
            for t in tokenize.generate_tokens(io.StringIO(seg).readline)
            if t.type not in (tokenize.NL, tokenize.NEWLINE, tokenize.COMMENT, tokenize.ENDMARKER)
        ]
    except (tokenize.TokenError, SyntaxError):
        return True
    depth = 0
    for i, t in enumerate(toks):
        if t.type != tokenize.OP:
            continue
        if t.string in "([{":
            if t.string == "(" and not (i == 0 and own_first):
                prev = toks[i - 1] if i else None
                if prev is None or (prev.type == tokenize.OP and prev.string not in ")]}"):
                    return True
            depth += 1
        elif t.string in ")]}":
            depth -= 1
            if own_first and depth == 0 and i != len(toks) - 1:
                return True
    return False


def _dunder_all(tree, src, comments):
    for st in tree.body:
        if isinstance(st, ast.Assign):
            left, right, chained = st.targets[0], st.value, len(st.targets) > 1
        elif isinstance(st, ast.AnnAssign):
            left, right, chained = st.target, st.value, False
        else:
            return None
        if src.seg(left) != "__all__":
            continue
        _need(not any((line, col) < (st.lineno, st.col_offset) for line, col in comments), "a comment before __all__")
        _need(not chained, "a chained __all__")
        if right is None:
            return None
        _need(src.prev_char(src.start(right)) in "=:", "an __all__ in parentheses")
        own = -1
        if isinstance(right, ast.Tuple) and src.text[src.start(right)] == "(":
            own = src.start(right)
        _need(not _grouping_parens(src.seg(right), own >= 0), "parentheses in __all__")
        out = []
        for e in _named_children(right):
            if _is_string(e, src, own):
                out.append(src.seg(e).strip("\"'"))
        return out
    return None


def _entry_calls(tree, src, main_module):
    out = []

    def collect(nodes):
        for st in nodes:
            for n in ast.walk(st):
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Name):
                    out.append(n.func.id)

    for st in tree.body:
        guard = False
        if isinstance(st, ast.If):
            gap = src.text[src.start(st) + 2 : src.start(st.test)]
            _need(gap.strip(" \t\\\n") == "", "a condition in parentheses")
            c = src.seg(st.test).replace(" ", "").replace("'", '"')
            guard = c == '__name__=="__main__"' or c == '"__main__"==__name__'
        if guard:
            collect(st.body)
        elif main_module and isinstance(st, (ast.Expr, ast.Assign, ast.AugAssign, ast.AnnAssign)):
            collect([st])
    return out


def _exports(path, tree, src, comments):
    all_ = _dunder_all(tree, src, comments)

    def public(name):
        return (not name.startswith("_")) if all_ is None else name in all_

    entry = _entry_calls(tree, src, path.endswith("__main__.py"))
    functions = []
    classes = []
    for st in tree.body:
        decs = _decorators(st, src)
        if isinstance(st, (ast.FunctionDef, ast.AsyncFunctionDef)):
            f = _function(st, src, decs, False)
            parser = st.returns is not None and src.seg(st.returns).endswith("ArgumentParser")
            if parser or f["name"] in entry:
                f["blocked"] = True
            if public(f["name"]):
                functions.append((f["blocked"], f["generator"], f["types"], f["returns"]))
        elif isinstance(st, ast.ClassDef):
            c = _class(st, src, decs)
            if public(c["name"]):
                classes.append((c["blocked"], c["name"], c["returns"]))
    return functions, classes


# ---- the entry point ---------------------------------------------------------


def read_file(path, rel):
    """("unreadable",) when read_to_string would fail; ("decline", why) when
    `ast` may read the file otherwise than tree-sitter; else ("ok", loc,
    imports, risks, loops, functions, classes)."""
    try:
        with open(path, "rb") as f:
            data = f.read()
        text = data.decode("utf-8")
    except (OSError, UnicodeError):
        return ("unreadable",)
    try:
        _need(_VERSION in _SCREENED, "a Python whose ast and tokenize the screens were not written for")
        _need(not any(c in _BAD for c in text), "a character that ends lines differently")
        try:
            tree = ast.parse(text)
        except (SyntaxError, ValueError, RecursionError, MemoryError):
            raise Decline("a syntax error")
        comments = _tokens(text)
        src = _Src(text)
        _screen(tree, src)
        imports, risks, loops = _scan(tree, src)
        functions, classes = _exports(rel, tree, src, comments)
    except Decline as e:
        return ("decline", str(e))
    except RecursionError:
        return ("decline", "too deep")
    return ("ok", loc(text), imports, risks, loops, functions, classes)


# ---- packages (python.rs read_package) ---------------------------------------


def _alnum_ascii(c):
    return c.isascii() and c.isalnum()


def normalized_name(name):
    return "-".join(p for p in re.split(r"[-_.]", name) if p).lower()


def requirement_name(line):
    i = 0
    while i < len(line) and (_alnum_ascii(line[i]) or line[i] in "-_."):
        i += 1
    return normalized_name(line[:i])


def _read_text(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8")
    except (OSError, UnicodeError):
        return None


def read_package(pyproject, requirements):
    """(ok, has_name, name, deps): ok 0 when tomllib or the requirement rules
    may read a file otherwise than toml_edit and Rust's char tables."""
    r = _read_package(pyproject, requirements)
    return (r[0], 0 if r[1] is None else 1, r[1] or "", r[2])


def toml_as_rust_reads(doc):
    """False when a document tomllib read holds a value toml_edit refuses: an
    integer outside i64 (tomllib's are unbounded) or a float that overflows
    (tomllib gives inf; a literal inf or nan is refused here too, which only
    sends the case back)."""
    import math

    todo = [doc]
    while todo:
        x = todo.pop()
        if isinstance(x, dict):
            todo.extend(x.values())
        elif isinstance(x, list):
            todo.extend(x)
        elif isinstance(x, bool):
            continue
        elif isinstance(x, int):
            if x < -(2**63) or x > 2**63 - 1:
                return False
        elif isinstance(x, float):
            if not math.isfinite(x):
                return False
    return True


def _read_package(pyproject, requirements):
    name = None
    deps = []
    text = _read_text(pyproject)
    if text is not None:
        try:
            doc = tomllib.loads(text)
        except (tomllib.TOMLDecodeError, ValueError, RecursionError):
            return (0, None, [])
        if not toml_as_rust_reads(doc):
            return (0, None, [])
        project = doc.get("project")
        if isinstance(project, dict):
            n = project.get("name")
            if isinstance(n, str):
                if not n.isascii():
                    return (0, None, [])
                name = normalized_name(n)
            d = project.get("dependencies")
            if isinstance(d, list):
                for x in d:
                    if isinstance(x, str):
                        if not x.isascii():
                            return (0, None, [])
                        deps.append(requirement_name(x))
    text = _read_text(requirements)
    if text is not None:
        if not text.isascii():
            return (0, None, [])
        for line in text.split("\n"):
            line = line.strip(" \t\n\r\x0b\x0c")
            if line and not line.startswith("#"):
                deps.append(requirement_name(line))
    return (1, name, deps)


# ---- the crate table (src/crates.rs) -----------------------------------------

_TABLE = {}


def load_table(text):
    _TABLE.clear()
    _TABLE.update(tomllib.loads(text))


def _strings(entry, key):
    v = entry.get(key)
    return [x for x in v if isinstance(x, str)] if isinstance(v, list) else []


def crate_find(lang, name):
    """crates::find: (1, replacement, fit, note) of the first entry whose names
    hold `name` or whose prefixes start it, else (0, "", "", "")."""
    for e in _TABLE.get(lang, []):
        if name in _strings(e, "names") or any(name.startswith(p) for p in _strings(e, "prefixes")):
            return (1, e.get("replacement", ""), e.get("fit", ""), e.get("note", ""))
    return (0, "", "", "")


def longest_prefix(lang, name):
    """crates::longest_prefix: the longest prefix not ending in `.` that starts
    `name` (the last of equal length, as max_by_key), else ""."""
    best = None
    for e in _TABLE.get(lang, []):
        for p in _strings(e, "prefixes"):
            if not p.endswith(".") and name.startswith(p):
                if best is None or len(p) >= len(best):
                    best = p
    return best or ""


# ---- analyze --whole-app (src/whole_app.rs), for Python workspaces --------------------

_WA_SERVER = (
    r"""WebApplication\.Create(?:Slim)?Builder|\bHttpListener\(|\.UseKestrel\(|\$_SERVER\[\s*['"]REQUEST_(?:METHOD|URI)|\$_(?:GET|POST)\[|\.listen\(|createServer\(|ListenAndServe|HTTPServer\(|HttpServer\.create|uvicorn\.run|\bapp\.run\(|SpringApplication\.run|TCPServer\.new|WEBrick::HTTPServer|Sinatra::Base|FastAPI\(|Flask\(|\bexpress\(\)|\blisten\(\s*\w+\s*,\s*\w+\s*\)|\bserve\(\s*listener"""
)
_WA_PY_MAIN = r"""if\s+__name__\s*==\s*['"]__main__['"]"""
# Where SERVER's `\b` and `\w` meet text: outside ASCII, Python's word characters are not
# Rust's (marks, connector punctuation, other numbers).
_WA_WORD_SPOTS = ("HttpListener(", "app.run(", "express()", "listen(", "serve(")
# Python's `\s` takes these (str.isspace), Rust's does not (White_Space).
_WA_SPACES = ("\x1c", "\x1d", "\x1e", "\x1f")


class _WaDecline(Exception):
    pass


def _wa_read(path):
    """read_to_string, or "" (unwrap_or_default)."""
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8")
    except (OSError, UnicodeError):
        return ""


def _wa_lines(text):
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return [l[:-1] if l.endswith("\r") else l for l in lines]


def _wa_ascii(text, what):
    if not text.isascii():
        raise _WaDecline(what + " outside ASCII")
    if any(c in text for c in _WA_SPACES):
        raise _WaDecline(what + " with a character only Python's strip takes")


def _wa_requirement_name(spec):
    """requirement_name, for ASCII text."""
    spec = spec.strip()
    i = 0
    while i < len(spec) and (spec[i].isalnum() or spec[i] in "-_."):
        i += 1
    name = spec[:i]
    if not name or not name[0].isalnum():
        return None
    rest = spec[i:].lstrip()
    if rest == "" or rest[0] in "[(=<>!~;,@#":
        return name
    return None


def _wa_requirements(path, out, seen):
    """requirements_from: `-r` / `--requirement` includes against the including file's
    folder, each file once."""
    key = os.path.realpath(path) if os.path.exists(path) else path
    if key in seen:
        return
    seen.add(key)
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        return
    _wa_ascii(text, "a requirements file")
    folder = os.path.dirname(path)
    for line in _wa_lines(text):
        line = line.strip()
        rest = None
        if line.startswith("--requirement"):
            rest = line[len("--requirement") :]
        elif line.startswith("-r"):
            rest = line[2:]
        if rest is not None:
            included = rest.lstrip("= \t")
            if included:
                _wa_requirements(os.path.join(folder, included), out, seen)
            continue
        if not line or line[0] in "#-":
            continue
        name = _wa_requirement_name(line)
        if name is not None:
            out.add(name)


def _wa_table(doc, *keys):
    for k in keys:
        if not isinstance(doc, dict) or k not in doc:
            return None
        doc = doc[k]
    return doc


def whole_app_facts(root, files):
    """What whole_app reads around analyze's plan of a Python workspace: ("ok", the
    manifests' entry points and those found in the code, each (kind, path, name or None,
    evidence), the declared names) or ("decline", why)
    where Python's readers may read otherwise than Rust's (a package.json, which
    serde_json reads; a pyproject.toml tomllib refuses; text outside ASCII where it
    matters)."""
    import re
    import tomllib

    try:
        if os.path.lexists(os.path.join(root, "package.json")):
            raise _WaDecline("a package.json")
        entries = []
        found = []
        pyproject = _wa_read(os.path.join(root, "pyproject.toml"))
        try:
            doc = tomllib.loads(pyproject)
        except (tomllib.TOMLDecodeError, ValueError, RecursionError):
            raise _WaDecline("a pyproject.toml tomllib refuses")
        if not toml_as_rust_reads(doc):
            raise _WaDecline("a pyproject.toml value toml_edit refuses")
        for table in (_wa_table(doc, "project", "scripts"), _wa_table(doc, "tool", "poetry", "scripts")):
            if not isinstance(table, dict):
                continue
            for name, target in table.items():
                entries.append(("cli", target if isinstance(target, str) else "", name, "pyproject.toml scripts"))
        server = re.compile(_WA_SERVER)
        main = re.compile(_WA_PY_MAIN, re.M)
        for rel in sorted(set(files)):
            text = _wa_read(os.path.join(root, rel))
            if any(c in text for c in _WA_SPACES):
                raise _WaDecline("a character only Python's \\s takes")
            if not text.isascii() and any(s in text for s in _WA_WORD_SPOTS):
                raise _WaDecline("a word boundary next to text outside ASCII")
            m = server.search(text)
            kind = "server"
            if m is None:
                m = main.search(text)
                kind = "cli"
            if m is None:
                continue
            line = text.count("\n", 0, m.start()) + 1
            found.append((kind, rel, None, "`%s` at %s:%d" % (m.group(0).strip(), rel, line)))
        declared = set()
        deps = _wa_table(doc, "project", "dependencies")
        if isinstance(deps, list):
            for v in deps:
                if isinstance(v, str):
                    _wa_ascii(v, "a dependency")
                    n = _wa_requirement_name(v)
                    if n is not None:
                        declared.add(n)
        poetry = _wa_table(doc, "tool", "poetry", "dependencies")
        if isinstance(poetry, dict):
            for k in poetry:
                if k != "python":
                    declared.add(k)
        _wa_requirements(os.path.join(root, "requirements.txt"), declared, set())
        out = set()
        for n in declared:
            if n:
                _wa_ascii(n, "a dependency name")
                out.add(n.lower().replace("_", "-"))
        def row(e):
            return (e[0], e[1], "" if e[2] is None else e[2], 0 if e[2] is None else 1, e[3])

        return ("ok", [row(e) for e in entries], [row(e) for e in found], sorted(out))
    except _WaDecline as e:
        return ("decline", str(e))
    except RecursionError:
        return ("decline", "too deep")


# ---- analyze --whole-app of the other languages (src/whole_app.rs) -----------------------

_WA_MAIN = {
    "python": _WA_PY_MAIN,
    "go": r"^func\s+main\s*\(\s*\)",
    "c": r"\bint\s+main\s*\(",
    "cpp": r"\bint\s+main\s*\(",
    "ruby": r"^#!.*\bruby\b|\bARGV\b|__FILE__\s*==\s*\$0",
    "java": r"public\s+static\s+void\s+main\s*\(",
    "kotlin": r"\bfun\s+main\s*\(",
    "php": r"""^#!.*\bphp\b|\$argv\b|PHP_SAPI\s*===?\s*['"]cli['"]""",
}


def _wa_dir_names(path):
    """read_dir's entries of a folder, in its order, as (name, is_dir without following
    links); None when it does not read. A name outside ASCII declines."""
    try:
        entries = list(os.scandir(path))
    except OSError:
        return None
    out = []
    for e in entries:
        _wa_ascii(e.name, "a file name")
        try:
            is_dir = e.is_dir(follow_symlinks=False)
        except OSError:
            is_dir = False
        out.append((e.name, is_dir))
    return out


def _wa_gemspecs(root):
    """The `*.gemspec` entries of the root, in read_dir's order."""
    names = _wa_dir_names(root) or []
    out = []
    for name, _ in names:
        k = name.rfind(".")
        if k > 0 and name[k + 1 :] == "gemspec":
            out.append(os.path.join(root, name))
    return out


def _wa_lang_entries(root, lang, serde_ok):
    """manifest_entries' language parts (Go's `cmd/` folders, PHP's composer.json `bin` and
    front controller, a gemspec's `executables`)."""
    import json
    import re

    out = []
    if lang == "go":
        names = _wa_dir_names(os.path.join(root, "cmd"))
        for name in sorted(n for n, d in (names or []) if d):
            out.append(("cli", "cmd/" + name, name, "a `cmd/` folder"))
    if lang == "php":
        path = os.path.join(root, "composer.json")
        text = _wa_read(path)
        if os.path.lexists(path) and text:
            if not serde_ok(path):
                raise _WaDecline("a composer.json serde_json may read otherwise")
            _wa_ascii(text, "a composer.json")
            try:
                doc = json.loads(text)
            except ValueError:
                doc = None
            bins = doc.get("bin") if isinstance(doc, dict) else None
            for b in bins if isinstance(bins, list) else []:
                if isinstance(b, str):
                    path_ = b
                    while path_.startswith("./"):
                        path_ = path_[2:]
                    out.append(("cli", path_, b.rsplit("/", 1)[-1], "composer.json `bin`"))
        for front in ("public/index.php", "web/index.php", "index.php"):
            if os.path.isfile(os.path.join(root, front)):
                out.append(("server", front, None,
                            "`%s`, a front controller: serve it with `php -S`" % front))
                break
    if lang == "ruby":
        specs = _wa_gemspecs(root)
        text = _wa_read(specs[0]) if specs else ""
        _wa_ascii(text, "a gemspec")
        c = re.search(r"""executables\s*=\s*(?:\[([^\]]*)\]|%w[\[(]([^\])]*)[\])])""", text)
        if c is not None:
            names = c.group(1) if c.group(1) is not None else (c.group(2) or "")
            for n in re.split(r"[, \n]", names):
                n = n.strip().strip("\"'")
                if n:
                    out.append(("cli", "exe/" + n, n, "gemspec `executables`"))
    return out


def _wa_opens_a_block(line):
    return (line.endswith(" do") or " do |" in line
            or any(line.startswith(k) for k in ("if ", "unless ", "while ", "until ", "case ")))


def _wa_without_xml_comments(text):
    out = []
    rest = text
    while True:
        start = rest.find("<!--")
        if start < 0:
            break
        out.append(rest[:start])
        end = rest.find("-->", start)
        if end < 0:
            rest = ""
            break
        rest = rest[end + 3 :]
    out.append(rest)
    return "".join(out)


def _wa_without_comments(text):
    """whole_app.rs `without_comments` for ASCII text."""
    out = []
    i = 0
    n = len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote is not None:
            out.append(c)
            if c == "\\":
                if i + 1 < n:
                    out.append(text[i + 1])
                    i += 1
            elif c == quote or c == "\n":
                quote = None
        elif c in "\"'":
            quote = c
            out.append(c)
        elif c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            last = " "
            while i < n:
                if last == "*" and text[i] == "/":
                    break
                last = text[i]
                i += 1
        else:
            out.append(c)
        i += 1
    lines = [l for l in _wa_lines("".join(out)) if not l.lstrip().startswith("//")]
    return "\n".join(lines)


def _wa_lang_declared(root, lang):
    """whole_app.rs `declared` for Go, Ruby, Java, Kotlin, C and C++ (no normalising)."""
    import re

    out = set()
    if lang == "go":
        text = _wa_read(os.path.join(root, "go.mod"))
        _wa_ascii(text, "a go.mod")
        in_block = False
        for line in _wa_lines(text):
            line = line.strip()
            if line.startswith("require ("):
                in_block = True
                continue
            if in_block and line == ")":
                in_block = False
                continue
            spec = line if in_block else (line[len("require ") :] if line.startswith("require ") else None)
            if spec is not None and "// indirect" not in spec:
                words = spec.split()
                if words and not words[0].startswith("//"):
                    out.add(words[0])
    elif lang == "ruby":
        gem = re.compile(r"""^\s*gem\s+['"]([^'"]+)['"]""")
        spec = re.compile(r"""add_(?:runtime_)?dependency\s*\(?\s*['"]([^'"]+)['"]""")
        text = _wa_read(os.path.join(root, "Gemfile"))
        for p in _wa_gemspecs(root):
            text += "\n" + _wa_read(p)
        _wa_ascii(text, "a Gemfile or gemspec")
        depth = 0
        group_at = None
        for line in _wa_lines(text):
            t = line.strip()
            if t.startswith("group "):
                group_at = depth
            if _wa_opens_a_block(t):
                depth += 1
            if t == "end" or t.startswith("end "):
                depth = max(depth - 1, 0)
                if group_at is not None and depth <= group_at:
                    group_at = None
            m = gem.search(line)
            if m is not None and group_at is None:
                out.add(m.group(1))
            m = spec.search(line)
            if m is not None:
                out.add(m.group(1))
    elif lang in ("java", "kotlin"):
        pom = _wa_read(os.path.join(root, "pom.xml"))
        _wa_ascii(pom, "a pom.xml")
        pom = _wa_without_xml_comments(pom)

        def tag(block, name):
            m = re.search(r"<%s>\s*([^<]+?)\s*</%s>" % (name, name), block)
            return m.group(1) if m else None

        for m in re.finditer(r"<dependency>(.*?)</dependency>", pom, re.S):
            block = m.group(1)
            if tag(block, "scope") == "test":
                continue
            g, a = tag(block, "groupId"), tag(block, "artifactId")
            if g is not None and a is not None:
                out.add("%s:%s" % (g, a))
        gradle = _wa_read(os.path.join(root, "build.gradle")) + _wa_read(os.path.join(root, "build.gradle.kts"))
        _wa_ascii(gradle, "a Gradle build")
        gradle = _wa_without_comments(gradle)
        for m in re.finditer(r"""\b(?:implementation|api|compile)\s*\(?\s*['"]([^:'"]+:[^:'"]+)""", gradle):
            out.add(m.group(1))
    elif lang == "php":
        import json

        text = _wa_read(os.path.join(root, "composer.json"))
        try:
            doc = json.loads(text) if text else None
        except ValueError:
            doc = None
        req = doc.get("require") if isinstance(doc, dict) else None
        if isinstance(req, dict):
            for k in req:
                if "/" in k and not k.startswith("ext-"):
                    out.add(k)
    return out


def whole_app_lang_facts(root, files, lang, serde_ok):
    """whole_app_facts for a Go, Ruby, Java, Kotlin, PHP, C or C++ workspace: the same
    answer shape; ("decline", why) where Python's readers may read otherwise than Rust's
    (a package.json, a pyproject.toml tomllib refuses, source text outside ASCII, where
    Python's `\\b`, `\\s` and `\\w` are not Rust's)."""
    import re
    import tomllib

    try:
        if os.path.lexists(os.path.join(root, "package.json")):
            raise _WaDecline("a package.json")
        entries = []
        pyproject = _wa_read(os.path.join(root, "pyproject.toml"))
        try:
            doc = tomllib.loads(pyproject)
        except (tomllib.TOMLDecodeError, ValueError, RecursionError):
            raise _WaDecline("a pyproject.toml tomllib refuses")
        if not toml_as_rust_reads(doc):
            raise _WaDecline("a pyproject.toml value toml_edit refuses")
        for table in (_wa_table(doc, "project", "scripts"), _wa_table(doc, "tool", "poetry", "scripts")):
            if not isinstance(table, dict):
                continue
            for name, target in table.items():
                entries.append(("cli", target if isinstance(target, str) else "", name, "pyproject.toml scripts"))
        entries += _wa_lang_entries(root, lang, serde_ok)
        server = re.compile(_WA_SERVER)
        main = re.compile(_WA_MAIN[lang], re.M)
        found = []
        for rel in sorted(set(files)):
            text = _wa_read(os.path.join(root, rel))
            _wa_ascii(text, "source text")
            if lang == "go" and "package main" not in text:
                continue
            m = server.search(text)
            kind = "server"
            if m is None:
                m = main.search(text)
                kind = "cli"
            if m is None:
                continue
            line = text.count("\n", 0, m.start()) + 1
            found.append((kind, rel, None, "`%s` at %s:%d" % (m.group(0).strip(), rel, line)))
        declared = set()
        for n in _wa_lang_declared(root, lang):
            if n:
                _wa_ascii(n, "a dependency name")
                declared.add(n)

        def row(e):
            return (e[0], e[1], "" if e[2] is None else e[2], 0 if e[2] is None else 1, e[3])

        return ("ok", [row(e) for e in entries], [row(e) for e in found], sorted(declared))
    except _WaDecline as e:
        return ("decline", str(e))
    except RecursionError:
        return ("decline", "too deep")
