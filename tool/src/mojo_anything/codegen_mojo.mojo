# What `bridge` and `refresh` share: the export family `mojo-anything.json`
# carries (src/ts/exports.rs `Param`, `ExportedFn`, `ExportedClass`, and
# bridge.rs `JsOnly` and `Manifest`, written as serde_json's
# `to_string_pretty` writes them), the port's types (bridge.rs `RType`,
# `param_type`, `snake_case`), and `port.mojo` stubs and the reader that
# reads its signatures back (src/codegen_mojo.rs). The text handled here is
# ASCII: the readers decline names, types and ports outside it, where Rust's
# Unicode tables would apply.

from mojo_anything.json_text import write_string

comptime SCHEMA = "mojo-anything/bridge@1"
comptime MANIFEST = "mojo-anything.json"
comptime STUB_MARK = "not ported: "


@fieldwise_init
struct Param(Copyable, Movable):
    var name: String
    var ts_type: String
    var optional: Bool
    var rest: Bool
    var default: Optional[String]
    var keyword_only: Bool
    var native_type: Optional[String]
    """The exact source type (C: `size_t`)."""


@fieldwise_init
struct ExportedFn(Copyable, Movable):
    var name: String
    var file: String
    var line: Int
    var params: List[Param]
    var returns: String
    var is_async: Bool
    var is_generator: Bool
    var type_params: List[String]
    var uses_instanceof: Bool
    var blocker: Optional[String]
    var native_return: Optional[String]
    """The exact source return type (C: `unsigned long`)."""
    var prototype: Optional[String]
    """The C declaration as written, whitespace collapsed."""
    var jvm_holder: Optional[String]
    """Kotlin: `object`, or `companion:<name>` (jvm::Holder)."""
    var jvm_constructor: Bool
    """Java and Kotlin: the class keeps a public no-arg constructor."""


@fieldwise_init
struct ExportedClass(Copyable, Movable):
    var name: String
    var file: String
    var line: Int
    var constructor: List[Param]
    var methods: List[ExportedFn]
    var blocker: Optional[String]


@fieldwise_init
struct JsOnly(Copyable, Movable):
    var name: String
    var file: String
    var line: Int
    var reason: String


@fieldwise_init
struct Batch(Copyable, Movable):
    """`--batch function:param` (codegen_batch.rs `Batch`)."""

    var function: String
    var param: String


@fieldwise_init
struct Manifest(Copyable, Movable):
    var root: String
    var unit: String
    var language: String
    var kind: String
    """As serialised: `mojo-py`, `c-abi`, ..."""
    var crate_name: String
    var exports: List[ExportedFn]
    var classes: List[ExportedClass]
    var js_only: List[JsOnly]
    var batches: List[Batch]

    def lib_name(self) -> String:
        return self.crate_name.replace("-", "_")


@fieldwise_init
struct PortFn(Copyable, Movable):
    var js_name: String
    var rust_name: String
    var param_names: List[String]
    var param_types: List[String]
    var ret: String
    var fallible: Bool


struct PortApi(Movable):
    var functions: List[PortFn]
    var structs: List[String]

    def __init__(out self):
        self.functions = List[PortFn]()
        self.structs = List[String]()


# ---- small text helpers (ASCII) ----------------------------------------------


def is_space(b: UInt8) -> Bool:
    return b == 32 or (b >= 9 and b <= 13)


def trim(s: String) -> String:
    """str::trim for ASCII text."""
    var bytes = s.as_bytes()
    var a = 0
    var b = len(bytes)
    while a < b and is_space(bytes[a]):
        a += 1
    while b > a and is_space(bytes[b - 1]):
        b -= 1
    return String(s[byte=a:b])


def trim_start(s: String) -> String:
    var bytes = s.as_bytes()
    var a = 0
    while a < len(bytes) and is_space(bytes[a]):
        a += 1
    return String(s[byte=a:])


def trim_end(s: String) -> String:
    var bytes = s.as_bytes()
    var b = len(bytes)
    while b > 0 and is_space(bytes[b - 1]):
        b -= 1
    return String(s[byte=0:b])


def trim_start_matches(s: String, prefix: String) -> String:
    var out = s
    while prefix.byte_length() > 0 and out.startswith(prefix):
        var _t = String(out[byte = prefix.byte_length() :])
        out = _t^
    return out


def trim_end_matches(s: String, suffix: String) -> String:
    var out = s
    while suffix.byte_length() > 0 and out.endswith(suffix):
        var _t = String(
            out[byte = 0 : out.byte_length() - suffix.byte_length()]
        )
        out = _t^
    return out


def is_alnum(b: UInt8) -> Bool:
    return (
        (b >= 48 and b <= 57) or (b >= 65 and b <= 90) or (b >= 97 and b <= 122)
    )


def is_ascii(s: String) -> Bool:
    for b in s.as_bytes():
        if b >= 128:
            return False
    return True


def lines(text: String) -> List[String]:
    """str::lines: split at `\\n`, a final empty piece dropped, a `\\r`
    before each `\\n` taken off."""
    var out = List[String]()
    var bytes = text.as_bytes()
    var start = 0
    for i in range(len(bytes)):
        if bytes[i] == 10:
            var end = i
            if end > start and bytes[end - 1] == 13:
                end -= 1
            out.append(String(text[byte=start:end]))
            start = i + 1
    if start < len(bytes):
        # A last line with no `\n` keeps a `\r` it ends with.
        out.append(String(text[byte=start:]))
    return out^


def join(items: List[String], sep: String) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += sep
        out += items[i]
    return out


# ---- names (bridge.rs `snake_case`, codegen_mojo.rs `mojo_ident`) ------------


def _rust_keywords() -> List[String]:
    var out = List[String]()
    for k in [
        "as",
        "break",
        "const",
        "continue",
        "crate",
        "else",
        "enum",
        "extern",
        "false",
        "fn",
        "for",
        "if",
        "impl",
        "in",
        "let",
        "loop",
        "match",
        "mod",
        "move",
        "mut",
        "pub",
        "ref",
        "return",
        "self",
        "static",
        "struct",
        "super",
        "trait",
        "true",
        "type",
        "unsafe",
        "use",
        "where",
        "while",
        "async",
        "await",
        "dyn",
        "gen",
    ]:
        out.append(k)
    return out^


def _mojo_reserved() -> List[String]:
    var out = List[String]()
    for k in [
        "match",
        "case",
        "out",
        "var",
        "mut",
        "ref",
        "read",
        "deinit",
        "comptime",
        "fn",
        "struct",
        "trait",
        "Self",
        "async",
        "await",
        "yield",
        "imm",
        "Int",
        "String",
        "List",
        "Optional",
        "Float64",
        "Bool",
        "PyNum",
        "PythonObject",
        "Python",
        "False",
        "None",
        "True",
        "and",
        "as",
        "assert",
        "break",
        "class",
        "continue",
        "def",
        "del",
        "elif",
        "else",
        "except",
        "finally",
        "for",
        "from",
        "global",
        "if",
        "import",
        "in",
        "is",
        "lambda",
        "nonlocal",
        "not",
        "or",
        "pass",
        "raise",
        "return",
        "try",
        "while",
        "with",
    ]:
        out.append(k)
    return out^


def _upper(b: UInt8) -> Bool:
    return b >= 65 and b <= 90


def _lower(b: UInt8) -> Bool:
    return b >= 97 and b <= 122


def snake_case(name: String) -> String:
    var bytes = name.as_bytes()
    var n = len(bytes)
    var res = String("")
    for i in range(n):
        var c = bytes[i]
        if _upper(c):
            var boundary = False
            if i > 0:
                var p = bytes[i - 1]
                if _lower(p) or (p >= 48 and p <= 57):
                    boundary = True
                elif _upper(p) and i + 1 < n and _lower(bytes[i + 1]):
                    boundary = True
            if boundary:
                res += "_"
            res += chr(Int(c) + 32)
        elif is_alnum(c):
            res += chr(Int(c))
        else:
            res += "_"
    if res in _rust_keywords():
        return "r#" + res
    return res


def mojo_escape(name: String) -> String:
    if name in _mojo_reserved():
        return name + "_"
    return name


def mojo_ident(name: String) -> String:
    var s = snake_case(name)
    if s.startswith("r#"):
        var _t = String(s[byte=2:])
        s = _t^
    return mojo_escape(s)


# ---- the port's types (bridge.rs `RType`) -----------------------------------
# An RType is written as text: `Str`, `F64`, `Int`, `Bool`, `Unit`, `Json`,
# `Vec:<inner>`, `Opt:<inner>`.


def _is_string_literal(ts: String) -> Bool:
    var t = trim(ts)
    return t.byte_length() >= 2 and (
        (t.startswith("'") and t.endswith("'"))
        or (t.startswith('"') and t.endswith('"'))
    )


def _balanced(ts: String) -> Bool:
    var depth = 0
    for b in ts.as_bytes():
        if b == 40:
            depth += 1
        elif b == 41:
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


def _split_top(ts: String, sep: UInt8) -> List[String]:
    """bridge.rs `split_top`: at `sep` outside brackets, pieces trimmed,
    empty ones dropped."""
    var out = List[String]()
    var bytes = ts.as_bytes()
    var depth = 0
    var start = 0
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == 60 or c == 40 or c == 91 or c == 123:
            depth += 1
        elif c == 62 or c == 41 or c == 93 or c == 125:
            depth -= 1
        elif c == sep and depth == 0:
            out.append(trim(String(ts[byte=start:i])))
            start = i + 1
    out.append(trim(String(ts[byte=start:])))
    var kept = List[String]()
    for p in out:
        if p.byte_length() > 0:
            kept.append(p)
    return kept^


def _wrap_opt(t: String, optional: Bool) -> String:
    if optional:
        return "Opt:" + t
    return t


def rtype_from_ts(given: String) -> String:
    var ts = trim(trim_start_matches(trim(given), "readonly "))
    if ts.startswith("(") and ts.endswith(")") and ts.byte_length() >= 2:
        var inner = String(ts[byte = 1 : ts.byte_length() - 1])
        if _balanced(inner):
            return rtype_from_ts(inner)
    if ts.startswith("Promise<") and ts.endswith(">"):
        return rtype_from_ts(String(ts[byte = 8 : ts.byte_length() - 1]))
    var parts = _split_top(ts, 124)
    if len(parts) > 1:
        var nullish = 0
        var rest = List[String]()
        for p in parts:
            var t = trim(p)
            if t == "undefined" or t == "null" or t == "void":
                nullish += 1
            else:
                rest.append(p)
        var all_literals = True
        for p in rest:
            if not _is_string_literal(p):
                all_literals = False
        if all_literals:
            return _wrap_opt("Str", nullish > 0)
        if len(rest) == 1:
            return _wrap_opt(rtype_from_ts(rest[0]), nullish > 0)
        return "Json"
    if ts.endswith("[]"):
        var inner = String(ts[byte = 0 : ts.byte_length() - 2])
        return "Vec:" + rtype_from_ts(
            trim_end_matches(trim_start_matches(inner, "("), ")")
        )
    for w in ["Array<", "ReadonlyArray<"]:
        if (
            ts.startswith(w)
            and ts.endswith(">")
            and ts.byte_length() > String(w).byte_length()
        ):
            return "Vec:" + rtype_from_ts(
                String(
                    ts[byte = String(w).byte_length() : ts.byte_length() - 1]
                )
            )
    if ts.startswith("asserts "):
        return "Unit"
    var is_at = ts.find(" is ")
    if is_at >= 0:
        var subject = trim(String(ts[byte=0:is_at]))
        var plain = True
        for b in subject.as_bytes():
            if not (is_alnum(b) or b == 95 or b == 36):
                plain = False
        if plain:
            return "Bool"
    if ts == "string":
        return "Str"
    if ts == "number":
        return "F64"
    if ts == "int":
        return "Int"
    if ts == "boolean":
        return "Bool"
    if ts == "void" or ts == "undefined":
        return "Unit"
    if _is_string_literal(ts):
        return "Str"
    return "Json"


def rtype_mojo(t: String, lang: String) -> String:
    """RType::mojo."""
    if t.startswith("Vec:"):
        return "List[" + rtype_mojo(String(t[byte=4:]), lang) + "]"
    if t.startswith("Opt:"):
        return "Optional[" + rtype_mojo(String(t[byte=4:]), lang) + "]"
    if t == "Str":
        return "String"
    if (t == "F64" or t == "Int") and lang == "python":
        return "PyNum"
    if t == "F64":
        return "Float64"
    if t == "Int":
        return "Int"
    if t == "Bool":
        return "Bool"
    if t == "Unit":
        return "None"
    if lang == "python":
        return "PythonObject"
    return "JsonValue"


def param_rtype(p: Param) -> String:
    """bridge.rs `param_type`."""
    var base = rtype_from_ts(p.ts_type)
    if p.rest and not base.startswith("Vec:"):
        base = "Vec:" + base
    if p.optional and not base.startswith("Opt:"):
        return "Opt:" + base
    return base


# ---- Python literal defaults (src/codegen_py.rs) -----------------------------


def _is_i64(d: String) -> Bool:
    """str::parse::<i64> succeeds."""
    var bytes = d.as_bytes()
    var i = 0
    var neg = False
    if len(bytes) > 0 and (bytes[0] == 43 or bytes[0] == 45):
        neg = bytes[0] == 45
        i = 1
    if i >= len(bytes):
        return False
    for k in range(i, len(bytes)):
        if bytes[k] < 48 or bytes[k] > 57:
            return False
    var digits = trim_start_matches(String(d[byte=i:]), "0")
    if digits.byte_length() < 19:
        return True
    if digits.byte_length() > 19:
        return False
    if neg:
        return digits <= "9223372036854775808"
    return digits <= "9223372036854775807"


def _is_f64(d: String) -> Bool:
    """str::parse::<f64> succeeds (ASCII text, no `_`)."""
    var s = d
    if s.startswith("+") or s.startswith("-"):
        var _t = String(s[byte=1:])
        s = _t^
    var low = s.lower()
    if low == "inf" or low == "infinity" or low == "nan":
        return True
    var bytes = s.as_bytes()
    var i = 0
    var n = len(bytes)
    var int_digits = 0
    while i < n and bytes[i] >= 48 and bytes[i] <= 57:
        i += 1
        int_digits += 1
    var frac_digits = 0
    if i < n and bytes[i] == 46:
        i += 1
        while i < n and bytes[i] >= 48 and bytes[i] <= 57:
            i += 1
            frac_digits += 1
    if int_digits + frac_digits == 0:
        return False
    if i < n and (bytes[i] == 101 or bytes[i] == 69):
        i += 1
        if i < n and (bytes[i] == 43 or bytes[i] == 45):
            i += 1
        var exp_digits = 0
        while i < n and bytes[i] >= 48 and bytes[i] <= 57:
            i += 1
            exp_digits += 1
        if exp_digits == 0:
            return False
    return i == n


def rust_literal(default: String) -> Bool:
    """Whether codegen_py::rust_literal gives a value."""
    var d = trim(default)
    if d == "True" or d == "true" or d == "False" or d == "false":
        return True
    if d == "None":
        return False
    var digits = d.replace("_", "")
    if _is_i64(digits):
        return True
    if (digits.find(".") >= 0 or digits.find("e") >= 0) and _is_f64(digits):
        return True
    if not (d.startswith('"') or d.startswith("'")):
        return False
    var quote = String(d[byte=0:1])
    var rest = String(d[byte=1:])
    if not rest.endswith(quote):
        return False
    var inner = String(rest[byte = 0 : rest.byte_length() - 1])
    if inner.find("\\") >= 0 or inner.find('"') >= 0 or inner.find("'") >= 0:
        return False
    return True


def has_literal_default(p: Param) -> Bool:
    return p.optional and p.default and rust_literal(p.default.value())


# ---- port.mojo ---------------------------------------------------------------


def go_mojo_type(go: String) -> String:
    """codegen_mojo::go_mojo_type: anything structured crosses as
    `JsonValue`."""
    var t = trim(go)
    if t == "int":
        return "Int"
    if t == "int8":
        return "Int8"
    if t == "int16":
        return "Int16"
    if t == "int32" or t == "rune":
        return "Int32"
    if t == "int64":
        return "Int64"
    if t == "uint":
        return "UInt"
    if t == "uint8" or t == "byte":
        return "UInt8"
    if t == "uint16":
        return "UInt16"
    if t == "uint32":
        return "UInt32"
    if t == "uint64" or t == "uintptr":
        return "UInt64"
    if t == "float32":
        return "Float32"
    if t == "float64":
        return "Float64"
    if t == "string":
        return "String"
    if t == "bool":
        return "Bool"
    if t == "[]string":
        return "List[String]"
    return "JsonValue"


def _typed_mojo_type(t: String) -> Bool:
    """codegen_mojo.rs `TYPED`."""
    return (
        t == "Int"
        or t == "Int8"
        or t == "Int16"
        or t == "Int32"
        or t == "Int64"
        or t == "UInt"
        or t == "UInt8"
        or t == "UInt16"
        or t == "UInt32"
        or t == "UInt64"
        or t == "Float32"
        or t == "Float64"
        or t == "Bool"
        or t == "String"
    )


def go_typed_eligible(f: PortFn) -> Bool:
    for t in f.param_types:
        if not _typed_mojo_type(t):
            return False
    return f.ret == "None" or _typed_mojo_type(f.ret)


def needs_json_mojo(lang: String, api: PortApi) -> Bool:
    """codegen_mojo::needs_json_mojo (a Mojo port has no classes)."""
    for f in api.functions:
        if f.ret.find("JsonValue") >= 0:
            return True
        for t in f.param_types:
            if t.find("JsonValue") >= 0:
                return True
    if lang == "ruby":
        return True
    if lang == "go":
        for f in api.functions:
            if not go_typed_eligible(f):
                return True
    return False


def _go_ret_mojo(native: String) -> Optional[String]:
    var inner = trim_end_matches(trim_start_matches(trim(native), "("), ")")
    var results = List[String]()
    for piece in inner.split(","):
        var r = trim(String(piece))
        if r.byte_length() > 0 and r != "error":
            results.append(r)
    if len(results) == 0:
        return None
    if len(results) == 1:
        return go_mojo_type(results[0])
    return String("JsonValue")


def java_mojo_type(java: String) -> Optional[String]:
    """The Mojo type of a Java type whose width matters (`int` is `Int32`),
    lists and arrays of them lists; None for the rest."""
    var t = trim(java)
    if t.endswith("[]"):
        var item = java_mojo_type(String(t[byte = 0 : t.byte_length() - 2]))
        if item:
            return "List[" + item.value() + "]"
        return None
    var lt = t.find("<")
    if lt >= 0:
        var whole = trim(String(t[byte=0:lt]))
        var dot = whole.rfind(".")
        var head = whole
        if dot >= 0:
            head = String(whole[byte = dot + 1 :])
        var rest = String(t[byte = lt + 1 :])
        if (
            head == "List"
            or head == "ArrayList"
            or head == "Collection"
            or head == "Iterable"
            or head == "LinkedList"
        ) and rest.endswith(">"):
            var item = java_mojo_type(
                String(rest[byte = 0 : rest.byte_length() - 1])
            )
            if item:
                return "List[" + item.value() + "]"
        return None
    if t == "int" or t == "Integer":
        return String("Int32")
    if t == "long" or t == "Long":
        return String("Int64")
    if t == "short" or t == "Short":
        return String("Int16")
    if t == "byte" or t == "Byte":
        return String("Int8")
    if t == "double" or t == "Double":
        return String("Float64")
    if t == "float" or t == "Float":
        return String("Float32")
    if t == "boolean" or t == "Boolean":
        return String("Bool")
    if t == "String" or t == "CharSequence":
        return String("String")
    return None


def _is_jvm(lang: String) -> Bool:
    return lang == "java" or lang == "kotlin"


def _param_mojo(m: Manifest, p: Param) -> String:
    if m.language == "go" and p.native_type:
        return go_mojo_type(p.native_type.value())
    # A Kotlin export carries the Java types the JVM sees (`Int` is `int`).
    if _is_jvm(m.language) and p.native_type:
        var j = java_mojo_type(p.native_type.value())
        if j:
            return j.value()
    var t: String
    if has_literal_default(p):
        t = rtype_from_ts(p.ts_type)
    else:
        t = param_rtype(p)
    return rtype_mojo(t, m.language)


def port_mojo(m: Manifest) -> String:
    """codegen_mojo::port_mojo for the units whose types need no native
    source type (Python)."""
    var body = String("")
    for f in m.exports:
        var params = List[String]()
        for p in f.params:
            params.append(mojo_ident(p.name) + ": " + _param_mojo(m, p))
        var ret = String("")
        if m.language == "go" and f.native_return:
            var g = _go_ret_mojo(f.native_return.value())
            if g:
                ret = " -> " + g.value()
        elif (
            _is_jvm(m.language)
            and f.native_return
            and java_mojo_type(f.native_return.value())
        ):
            ret = " -> " + java_mojo_type(f.native_return.value()).value()
        else:
            var r = rtype_from_ts(f.returns)
            if r != "Unit":
                ret = " -> " + rtype_mojo(r, m.language)
        body += String(
            "\n\n# Port of `", f.name, "` (`", f.file, ":", f.line, "`).\n"
        )
        for p in f.params:
            if p.default:
                body += String(
                    "# `",
                    mojo_ident(p.name),
                    "` defaults to `",
                    p.default.value(),
                    "` in the source.\n",
                )
        body += String(
            "def ",
            mojo_ident(f.name),
            "(",
            join(params, ", "),
            ") raises",
            ret,
            ':\n    raise Error("',
            STUB_MARK,
            f.name,
            '")\n',
        )
    for c in m.classes:
        body += String(
            "\n\n# Class `",
            c.name,
            "` (`",
            c.file,
            ":",
            c.line,
            "`) is not bridged to Mojo yet; it stays in the source.\n",
        )
    var out = String(
        "# The Mojo port of `",
        m.unit,
        "`.\n#\n",
        '# Replace each `raise Error("',
        STUB_MARK,
        '...")` with the port of the source function.\n',
        (
            '# Raise `Error("ValueError: message")` (any builtin exception'
            " name) where the source\n"
        ),
        (
            "# raises: the caller gets that exception. After changing a"
            " signature, run\n"
        ),
        (
            "# `mojo-anything refresh`; `mojo-anything diff` checks behaviour"
            " against the recording.\n"
        ),
    )
    if body.find("PythonObject") >= 0:
        out += "\nfrom std.python import Python, PythonObject\n"
    if body.find("PyNum") >= 0:
        out += "\nfrom py_num import PyNum\n"
    if body.find("JsonValue") >= 0:
        out += "\nfrom json import JsonValue\n"
    out += body
    return out


# ---- reading port.mojo back (codegen_mojo::parse_port_mojo) ------------------


def _depth(text: String) -> Int:
    var d = 0
    for b in text.as_bytes():
        if b == 40 or b == 91:
            d += 1
        elif b == 41 or b == 93:
            d -= 1
    return d


def _signature_ends(text: String) -> Bool:
    return _depth(text) == 0 and trim_end(text).endswith(":")


def _comment_name(all: List[String], before: Int) -> Optional[String]:
    var i = before - 1
    while i >= 0:
        var l = trim_start(all[i])
        if not (l.startswith("#") or l.startswith("@")):
            break
        if l.startswith("# Port of `"):
            var rest = String(l[byte=11:])
            var tick = rest.find("`")
            if tick < 0:
                return rest
            return String(rest[byte=0:tick])
        i -= 1
    return None


def _split_params(text: String) -> List[String]:
    """codegen_mojo.rs `split_top`."""
    var out = List[String]()
    var bytes = text.as_bytes()
    var d = 0
    var start = 0
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == 40 or c == 91:
            d += 1
        elif c == 41 or c == 93:
            d -= 1
        elif c == 44 and d == 0:
            out.append(String(text[byte=start:i]))
            start = i + 1
    out.append(String(text[byte=start:]))
    var kept = List[String]()
    for p in out:
        var t = trim(p)
        if t.byte_length() > 0:
            kept.append(t)
    return kept^


def _parse_def(
    signature: String, js_name: Optional[String]
) -> Optional[PortFn]:
    var open = signature.find("(")
    if open < 0:
        return None
    var name = trim(String(signature[byte=0:open]))
    if name.find("[") >= 0:
        return None
    var bytes = signature.as_bytes()
    var d = 0
    var close = -1
    for k in range(open, len(bytes)):
        var c = bytes[k]
        if c == 40 or c == 91:
            d += 1
        elif c == 41 or c == 93:
            d -= 1
        if d == 0 and c == 41:
            close = k
            break
    if close < 0:
        return None
    var names = List[String]()
    var types = List[String]()
    for raw in _split_params(String(signature[byte = open + 1 : close])):
        var p = raw
        var eq = p.find("=")
        if eq >= 0:
            var _t = String(p[byte=0:eq])
            p = _t^
        p = trim(p)
        for k in ["var ", "mut ", "read ", "ref ", "owned ", "out "]:
            if p.startswith(k):
                var _t = String(p[byte = String(k).byte_length() :])
                p = _t^
                break
        var colon = p.find(":")
        if colon < 0:
            continue
        names.append(trim(String(p[byte=0:colon])))
        types.append(trim(String(p[byte = colon + 1 :])))
    var tail = trim(
        trim_end_matches(trim(String(signature[byte = close + 1 :])), ":")
    )
    var fallible = tail.startswith("raises")
    var ret = String("None")
    var arrow = tail.find("->")
    if arrow >= 0:
        ret = trim(String(tail[byte = arrow + 2 :]))
    var js = name
    if js_name:
        js = js_name.value()
    return PortFn(js, name, names^, types^, ret, fallible)


def parse_port_mojo(source: String) -> PortApi:
    var all = lines(source)
    var api = PortApi()
    var i = 0
    while i < len(all):
        var line = all[i]
        if line.startswith("struct "):
            var rest = String(line[byte=7:])
            var bytes = rest.as_bytes()
            var k = 0
            while k < len(bytes) and (is_alnum(bytes[k]) or bytes[k] == 95):
                k += 1
            var name = String(rest[byte=0:k])
            if not name.startswith("_"):
                api.structs.append(name)
        if not line.startswith("def "):
            i += 1
            continue
        var signature = trim_end(String(line[byte=4:]))
        var j = i
        while not _signature_ends(signature) and j + 1 < len(all):
            j += 1
            signature += " " + trim(all[j])
        var f = _parse_def(signature, _comment_name(all, i))
        if f and not f.value().rust_name.startswith("_"):
            api.functions.append(f.value().copy())
        i = j + 1
    return api^


def match_export_names(m: Manifest, mut api: PortApi):
    """bridge::match_export_names."""
    for i in range(len(api.functions)):
        var known = False
        for e in m.exports:
            if e.name == api.functions[i].js_name:
                known = True
        if known:
            continue
        var rust = trim_start_matches(api.functions[i].rust_name, "r#")
        for e in m.exports:
            if trim_start_matches(snake_case(e.name), "r#") == rust:
                api.functions[i].js_name = e.name
                break


# ---- mojo-anything.json (serde_json::to_string_pretty) -----------------------


def _bool(b: Bool) -> String:
    if b:
        return "true"
    return "false"


def _param_json(p: Param, ind: String) -> String:
    var i2 = ind + "  "
    var out = String(ind, "{\n")
    out += String(i2, '"name": ', write_string(p.name), ",\n")
    out += String(i2, '"ts_type": ', write_string(p.ts_type), ",\n")
    out += String(i2, '"optional": ', _bool(p.optional), ",\n")
    out += String(i2, '"rest": ', _bool(p.rest))
    if p.default:
        out += String(",\n", i2, '"default": ', write_string(p.default.value()))
    if p.keyword_only:
        out += String(",\n", i2, '"keyword_only": true')
    if p.native_type:
        out += String(
            ",\n", i2, '"native_type": ', write_string(p.native_type.value())
        )
    out += String("\n", ind, "}")
    return out


def _params_json(ps: List[Param], ind: String) -> String:
    if len(ps) == 0:
        return "[]"
    var out = String("[\n")
    for i in range(len(ps)):
        if i > 0:
            out += ",\n"
        out += _param_json(ps[i], ind + "  ")
    out += String("\n", ind, "]")
    return out


def _strings_json(xs: List[String], ind: String) -> String:
    if len(xs) == 0:
        return "[]"
    var out = String("[\n")
    for i in range(len(xs)):
        if i > 0:
            out += ",\n"
        out += String(ind, "  ", write_string(xs[i]))
    out += String("\n", ind, "]")
    return out


def _fn_json(f: ExportedFn, ind: String) -> String:
    var i2 = ind + "  "
    var out = String(ind, "{\n")
    out += String(i2, '"name": ', write_string(f.name), ",\n")
    out += String(i2, '"file": ', write_string(f.file), ",\n")
    out += String(i2, '"line": ', f.line, ",\n")
    out += String(i2, '"params": ', _params_json(f.params, i2), ",\n")
    out += String(i2, '"returns": ', write_string(f.returns), ",\n")
    out += String(i2, '"is_async": ', _bool(f.is_async), ",\n")
    out += String(i2, '"is_generator": ', _bool(f.is_generator), ",\n")
    out += String(
        i2, '"type_params": ', _strings_json(f.type_params, i2), ",\n"
    )
    out += String(i2, '"uses_instanceof": ', _bool(f.uses_instanceof))
    if f.blocker:
        out += String(",\n", i2, '"blocker": ', write_string(f.blocker.value()))
    if f.native_return:
        out += String(
            ",\n",
            i2,
            '"native_return": ',
            write_string(f.native_return.value()),
        )
    if f.prototype:
        out += String(
            ",\n", i2, '"prototype": ', write_string(f.prototype.value())
        )
    if f.jvm_holder:
        var h = f.jvm_holder.value()
        if h.startswith("companion:"):
            out += String(
                ",\n",
                i2,
                '"jvm_holder": {\n',
                i2,
                '  "companion": ',
                write_string(String(h[byte=10:])),
                "\n",
                i2,
                "}",
            )
        else:
            out += String(",\n", i2, '"jvm_holder": "object"')
    if f.jvm_constructor:
        out += String(",\n", i2, '"jvm_constructor": true')
    out += String("\n", ind, "}")
    return out


def _fns_json(fs: List[ExportedFn], ind: String) -> String:
    if len(fs) == 0:
        return "[]"
    var out = String("[\n")
    for i in range(len(fs)):
        if i > 0:
            out += ",\n"
        out += _fn_json(fs[i], ind + "  ")
    out += String("\n", ind, "]")
    return out


def _class_json(c: ExportedClass, ind: String) -> String:
    var i2 = ind + "  "
    var out = String(ind, "{\n")
    out += String(i2, '"name": ', write_string(c.name), ",\n")
    out += String(i2, '"file": ', write_string(c.file), ",\n")
    out += String(i2, '"line": ', c.line, ",\n")
    out += String(i2, '"constructor": ', _params_json(c.constructor, i2), ",\n")
    out += String(i2, '"methods": ', _fns_json(c.methods, i2), ",\n")
    if c.blocker:
        out += String(i2, '"blocker": ', write_string(c.blocker.value()))
    else:
        out += String(i2, '"blocker": null')
    out += String("\n", ind, "}")
    return out


def manifest_json(m: Manifest) -> String:
    """`serde_json::to_string_pretty(m) + "\\n"` (no float tolerance:
    `bridge` writes none, and `refresh --batch` declines one)."""
    var i1 = String("  ")
    var out = String("{\n")
    out += String(i1, '"schema": ', write_string(SCHEMA), ",\n")
    out += String(i1, '"root": ', write_string(m.root), ",\n")
    out += String(i1, '"unit": ', write_string(m.unit), ",\n")
    out += String(i1, '"language": ', write_string(m.language), ",\n")
    out += String(i1, '"kind": ', write_string(m.kind), ",\n")
    out += String(i1, '"crate_name": ', write_string(m.crate_name), ",\n")
    out += String(i1, '"exports": ', _fns_json(m.exports, i1), ",\n")
    if len(m.classes) == 0:
        out += String(i1, '"classes": [],\n')
    else:
        out += String(i1, '"classes": [\n')
        for i in range(len(m.classes)):
            if i > 0:
                out += ",\n"
            out += _class_json(m.classes[i], i1 + "  ")
        out += String("\n", i1, "],\n")
    var tail = String("\n")
    if len(m.batches) > 0:
        tail = ",\n"
    if len(m.js_only) == 0:
        out += String(i1, '"js_only": []', tail)
    else:
        out += String(i1, '"js_only": [\n')
        for i in range(len(m.js_only)):
            if i > 0:
                out += ",\n"
            var j = m.js_only[i].copy()
            out += String(
                "    {\n",
                '      "name": ',
                write_string(j.name),
                ",\n",
                '      "file": ',
                write_string(j.file),
                ",\n",
                '      "line": ',
                j.line,
                ",\n",
                '      "reason": ',
                write_string(j.reason),
                "\n    }",
            )
        out += String("\n", i1, "]", tail)
    if len(m.batches) > 0:
        out += String(i1, '"batches": [\n')
        for i in range(len(m.batches)):
            if i > 0:
                out += ",\n"
            out += String(
                '    {\n      "function": ',
                write_string(m.batches[i].function),
                ',\n      "param": ',
                write_string(m.batches[i].param),
                "\n    }",
            )
        out += String("\n", i1, "]\n")
    out += "}\n"
    return out
