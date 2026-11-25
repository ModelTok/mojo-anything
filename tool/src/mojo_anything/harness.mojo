# The inputs `record` runs (port of src/harness.rs `generate_cases`,
# `generate`, `trap_args`, `args_for`, `scenarios`, `value`, `Rng`, `intify`
# and `split_keyword_only`): edge cases and seeded random mixes per function,
# the semantic traps, and class scenarios. The xorshift64* generator, its
# seeds and the order every number is drawn in are Rust's, so a recording
# runs the same inputs in the same order.
#
# A value is kept as the text serde_json's `to_string` gives it (its `kind`,
# a string's value and a number's value beside it): the inputs file is that
# text, and the duplicate check compares it, as Rust compares `to_string`.
# Where Rust compares values (`base[i] != v` in `trap_args`), comparing the
# text gives the same answer here: the values met there are scalars, empty
# containers and objects of at most one key, none of them -0.0.
#
# Characters (a string's chars, `to_uppercase`) go through Python's `str`:
# the strings sliced are the generator's own, whose upper case Python and
# Rust agree on.

from std.collections import Dict, Set
from std.python import Python, PythonObject


from mojo_anything.pycache import py_exec
from mojo_anything.codegen_mojo import (
    ExportedClass,
    ExportedFn,
    Param,
    param_rtype,
    trim,
)
from mojo_anything.js_number import json_number_to_string
from mojo_anything.json_text import write_string
from mojo_anything.shape import (
    DECLINE,
    S_ANY,
    S_ARRAY,
    S_BOOL,
    S_INT,
    S_LITBOOL,
    S_LITNUM,
    S_LITSTR,
    S_NULL,
    S_NUM,
    S_OBJECT,
    S_REF,
    S_STR,
    S_TUPLE,
    S_UNDEF,
    S_UNION,
    Shapes,
)

comptime NULL = 0
comptime BOOL = 1
comptime INT = 2
comptime FLOAT = 3
comptime STR = 4
comptime ARRAY = 5
comptime OBJECT = 6

comptime UNDEFINED = '{"$undefined":true}'


@fieldwise_init
struct GV(Copyable, Movable):
    """A generated JSON value: its kind, serde_json's text of it, a string's
    value (`raw`) and a number's value (`num`)."""

    var kind: Int
    var text: String
    var raw: String
    var num: Float64


def gv_str(s: String) -> GV:
    return GV(STR, write_string(s), s, 0.0)


def gv_int(n: Int) -> GV:
    return GV(INT, String(n), "", Float64(n))


def gv_float(x: Float64) -> GV:
    return GV(FLOAT, json_number_to_string(x), "", x)


def gv_text(kind: Int, text: String) -> GV:
    return GV(kind, text, "", 0.0)


def gv_undefined() -> GV:
    return gv_text(OBJECT, UNDEFINED)


def gv_marker(name: String) -> GV:
    """`{"$num": name}`."""
    return gv_text(OBJECT, String('{"$num":"', name, '"}'))


def array_text(items: List[GV]) -> String:
    var out = String("[")
    for i in range(len(items)):
        if i > 0:
            out += ","
        out += items[i].text
    return out + "]"


def gv_array(items: List[GV]) -> GV:
    return gv_text(ARRAY, array_text(items))


struct Obj(Movable):
    """A serde_json map being built (preserve_order): a key inserted again
    keeps its place and takes the new value."""

    var keys: List[String]
    var values: List[String]

    def __init__(out self):
        self.keys = List[String]()
        self.values = List[String]()

    def insert(mut self, key: String, value: String):
        for i in range(len(self.keys)):
            if self.keys[i] == key:
                self.values[i] = value
                return
        self.keys.append(key)
        self.values.append(value)

    def text(self) -> String:
        var out = String("{")
        for i in range(len(self.keys)):
            if i > 0:
                out += ","
            out += write_string(self.keys[i]) + ":" + self.values[i]
        return out + "}"


# ---- the fixed values ---------------------------------------------------------


def _c(cp: Int) -> String:
    return chr(cp)


def strings() -> List[String]:
    """STRINGS: empty, case, whitespace, non-ASCII, astral, combining."""
    var out: List[String] = [
        "",
        "a",
        "ab",
        "abc",
        "hello",
        "hello world",
        "Hello World",
        "HELLO",
        "  padded  ",
        "a.b.c",
        "ns:key.path",
        "a:b:c",
        ":",
        ".leading",
        "trailing.",
        "a..b",
        "src/a/b.ts",
        "./x/**/*.json",
        "key_name-1",
        "{name} has {count} items",
        "line1\nline2",
        "tab\tseparated",
        "ünïcödé",
        "straße",
        "İstanbul",
        "ΣΊΣΥΦΟΣ",
        "日本語のテキスト",
        "emoji 👍🏽 mix",
        "😀",
        "a😀b😀c",
        String("e", _c(0x301)),
        String(_c(0xFEFF), "bom"),
    ]
    return out^


def string_traps() -> List[String]:
    """app.rs STRING_TRAPS and the seven trap_values adds."""
    var zwj = _c(0x200D)
    var out: List[String] = [
        "héllo wörld",
        "👍🏽 thumbs",
        "日本語",
        "",
        String("e", _c(0x301)),
        "İstanbul",
        "straße",
        "ılık ırmak",
        String("👨", zwj, "👩", zwj, "👧 family"),
        String("a", _c(0xA0), "b"),
        "ΣΊΣΥΦΟΣ",
        "a😀b",
        String(_c(0xFEFF), "bom"),
        "a²b x½ y①",
        "aⅠb Ⅻ",
        "a𐐀b 𝐀bc",
        "कि ٣٤",
    ]
    return out^


def regex_traps() -> List[String]:
    """risks.rs REGEX_TRAPS."""
    var zwj = _c(0x200D)
    var out: List[String] = [
        "Iı İi",
        String("K ", _c(0x212A), " k"),
        "ſ s S",
        String("x", zwj, "y 👨", zwj, "👩", zwj, "👧"),
        String("a", _c(0xA0), "b", _c(0x2009), "c", _c(0x3000), "d"),
        "١٢٣ ٤٥",
        "𝟘𝟙 ²³",
        "snake_case foo-bar o'neil",
        "ǅungla Ǆ",
        String("one\r\ntwo", _c(0x2028), "three", _c(0x85), "four"),
        String("cafe", _c(0x301), " café"),
        "ΣΑΣ σας ς",
    ]
    return out^


comptime I64_MAX = 9223372036854775807
comptime I64_MIN = -9223372036854775807 - 1


def _ints() -> List[Int]:
    var out: List[Int] = [
        0,
        1,
        -1,
        2,
        7,
        42,
        100,
        -100,
        255,
        2147483647,
        -2147483648,
        I64_MAX,
    ]
    return out^


def _float(py: PythonObject, text: String) raises -> GV:
    """A float from its decimal text, read by Python's `float` (correctly
    rounded, as Rust's literals are)."""
    return gv_float(Float64(py=py["float"](PythonObject(text))))


def _json_values() -> List[GV]:
    """JSON_VALUES."""
    var out = List[GV]()
    out.append(gv_text(NULL, "null"))
    out.append(gv_text(BOOL, "true"))
    out.append(gv_int(0))
    out.append(gv_str("x"))
    out.append(gv_text(ARRAY, "[]"))
    out.append(gv_text(OBJECT, "{}"))
    out.append(gv_text(OBJECT, '{"a":"b"}'))
    out.append(gv_text(OBJECT, '{"a":{"b":"c"}}'))
    out.append(gv_text(ARRAY, '["a",1]'))
    return out^


# ---- xorshift64* ----------------------------------------------------------------


struct Rng(Movable):
    var state: UInt64

    def __init__(out self, seed: UInt64):
        self.state = seed | 1

    def below(mut self, n: Int) -> Int:
        if n == 0:
            return 0
        self.state ^= self.state >> 12
        self.state ^= self.state << 25
        self.state ^= self.state >> 27
        var x = self.state * 0x2545_F491_4F6C_DD1D
        return Int((x >> 33) % UInt64(n))


def name_seed(name: String, start: UInt64) -> UInt64:
    var h = start
    for b in name.as_bytes():
        h = (h ^ UInt64(b)) * 0x0000_0100_0000_01B3
    return h


# ---- the generator's state ----------------------------------------------------


struct Gen(Movable):
    """What generation reads: the fixed values, Python's `str` for chars,
    the shapes read so far, and the named types in scope: the dataclasses of
    the function's file and its package (`python_types`, read through
    `loader` on the first name looked up), or none for a class's file, where
    a name looked up declines (Rust reads it with the TS reader)."""

    var py: PythonObject
    var shapes: Shapes
    var loader: PythonObject
    var scope_path: String
    var strict: Bool
    var loaded: Bool
    var type_names: List[String]
    var type_texts: List[String]
    var resolved: Dict[String, Int]
    var strings: List[String]
    var ints: List[Int]
    var floats: List[GV]
    var json_values: List[GV]
    var string_traps: List[String]
    var regex_traps: List[String]
    var float_traps: List[GV]
    var float_vec_traps: List[GV]

    def __init__(out self, loader: PythonObject) raises:
        self.shapes = Shapes()
        self.loader = loader
        self.scope_path = ""
        self.strict = True
        self.loaded = False
        self.type_names = List[String]()
        self.type_texts = List[String]()
        self.resolved = Dict[String, Int]()
        var scope = Python.dict()
        py_exec(
            """
def cp_len(s):
    return len(s)

def cp_slice(s, a, b, upper):
    piece = s[a:b]
    return piece.upper() if upper else piece
""",
            scope,
        )
        scope["float"] = Python.import_module("builtins").float
        self.py = scope
        self.strings = strings()
        self.ints = _ints()
        self.floats = List[GV]()
        for t in [
            "0.0",
            "1.0",
            "-1.0",
            "2.0",
            "3.0",
            "10.0",
            "0.5",
            "-2.5",
            "42.0",
            "100.0",
            "1000.0",
            "1e6",
            "2147483648.0",
            "9007199254740992.0",
        ]:
            self.floats.append(_float(scope, t))
        self.json_values = _json_values()
        self.string_traps = string_traps()
        self.regex_traps = regex_traps()
        self.float_traps = List[GV]()
        for t in [
            "-7.5",
            "0.1",
            "0.30000000000000004",
            "1e21",
            "1e-7",
            "5e-324",
            "1.7976931348623157e308",
            "9007199254740992.0",
        ]:
            self.float_traps.append(_float(scope, t))
        self.float_vec_traps = List[GV]()
        for t in ["0.1", "0.2", "-0.5", "1e21"]:
            self.float_vec_traps.append(_float(scope, t))

    def set_scope(mut self, path: String, strict: Bool):
        """The file whose named types the next values are generated with."""
        if path == self.scope_path and strict == self.strict:
            return
        self.scope_path = path
        self.strict = strict
        self.loaded = False
        self.type_names = List[String]()
        self.type_texts = List[String]()
        self.resolved = Dict[String, Int]()

    def lookup(mut self, name: String) raises -> Int:
        """The shape of a named type in scope (shape.rs `resolve`'s last
        arm): the first type of that name, or Any."""
        if self.strict:
            raise Error(DECLINE)
        if name in self.resolved:
            return self.resolved[name]
        if not self.loaded:
            var got = self.loader(PythonObject(self.scope_path))
            if String(py=got[0]) != "ok":
                raise Error(DECLINE)
            var types = got[1]
            var n = Int(py=Python.import_module("builtins").len(types))
            for i in range(n):
                self.type_names.append(String(py=types[i][0]))
                self.type_texts.append(String(py=types[i][1]))
            self.loaded = True
        var s = -1
        for i in range(len(self.type_names)):
            if self.type_names[i] == name:
                s = self.shapes.parse(self.type_texts[i])
                break
        if s < 0:
            s = self.shapes.node(S_ANY)
        self.resolved[name] = s
        return s


def _keys() -> List[String]:
    """KEYS: plain, nested-looking, integer-like, non-ASCII."""
    var out: List[String] = [
        "a",
        "b",
        "nav",
        "home",
        "title",
        "2",
        "10",
        "ünï",
        "😀",
        "a.b",
    ]
    return out^


def resolve(mut g: Gen, r: Int) raises -> Int:
    """shape.rs `resolve` of the reference node `r`."""
    var name = g.shapes.texts[r]
    var args = g.shapes.kids[r].copy()
    var n = len(args)
    if (
        name == "Array"
        or name == "ReadonlyArray"
        or name == "Set"
        or name == "ReadonlySet"
    ) and n == 1:
        var a = g.shapes.node(S_ARRAY)
        g.shapes.kids[a].append(args[0])
        return a
    if name == "Record" and n == 2:
        var o = g.shapes.node(S_OBJECT)
        g.shapes.index[o] = args[1]
        return o
    if (name == "Readonly" or name == "Promise" or name == "NonNullable") and (
        n == 1
    ):
        return args[0]
    if name == "Partial" and n == 1:
        if g.shapes.kinds[args[0]] == S_OBJECT:
            return g.shapes.copy_object(args[0], True)
        return args[0]
    if name == "int" and n == 0:
        return g.shapes.node(S_INT)
    return g.lookup(name)


def shaped(mut g: Gen, s: Int, mut rng: Rng, depth: Int) raises -> GV:
    """harness.rs `shaped`: a value that fits the shape `s`."""
    var k = g.shapes.kinds[s]
    if k == S_STR:
        return value(g, "Str", rng)
    if k == S_NUM:
        return value(g, "F64", rng)
    if k == S_INT:
        return value(g, "Int", rng)
    if k == S_BOOL:
        return value(g, "Bool", rng)
    if k == S_NULL:
        return gv_text(NULL, "null")
    if k == S_UNDEF:
        return gv_undefined()
    if k == S_LITSTR:
        return gv_str(g.shapes.texts[s])
    if k == S_LITNUM:
        return _float(g.py, g.shapes.texts[s])
    if k == S_LITBOOL:
        return gv_text(BOOL, g.shapes.texts[s])
    if k == S_UNION:
        var items = g.shapes.kids[s].copy()
        if len(items) == 0:
            return gv_text(NULL, "null")
        var pick = items[rng.below(len(items))]
        return shaped(g, pick, rng, depth)
    if k == S_ARRAY and depth < 6:
        var item = g.shapes.kids[s][0]
        var out = List[GV]()
        for _ in range(rng.below(4)):
            out.append(shaped(g, item, rng, depth + 1))
        return gv_array(out)
    if k == S_TUPLE:
        var items = g.shapes.kids[s].copy()
        var out = List[GV]()
        for i in items:
            out.append(shaped(g, i, rng, depth + 1))
        return gv_array(out)
    if k == S_OBJECT and depth < 6:
        var kids = g.shapes.kids[s].copy()
        var names = g.shapes.names[s].copy()
        var opts = g.shapes.optional[s].copy()
        var index = g.shapes.index[s]
        var obj = Obj()
        for i in range(len(kids)):
            if opts[i] and rng.below(4) == 0:
                continue
            obj.insert(names[i], shaped(g, kids[i], rng, depth + 1).text)
        if index >= 0:
            var keys = _keys()
            for _ in range(rng.below(4)):
                var key = keys[rng.below(len(keys))]
                obj.insert(key, shaped(g, index, rng, depth + 1).text)
        return gv_text(OBJECT, obj.text())
    if k == S_REF and depth < 6:
        var r = resolve(g, s)
        return shaped(g, r, rng, depth + 1)
    if k == S_ANY:
        return value(g, "Json", rng)
    # Too deep: a leaf ends the recursion.
    return gv_text(NULL, "null")


def contains_json(t: String) -> Bool:
    """RType::contains_json."""
    if t == "Json":
        return True
    if t.startswith("Vec:") or t.startswith("Opt:"):
        return contains_json(String(t[byte=4:]))
    return False


def is_c_pointer(ts_type: String) -> Bool:
    """The C ABI's parameter dialect (`len:`, buffers, out pointers, structs).
    """
    return (
        ts_type.startswith("len:")
        or ts_type == "bytes"
        or ts_type == "buffer"
        or ts_type == "out"
        or ts_type.startswith("outptr:")
        or ts_type.startswith("struct:")
    )


def value(g: Gen, t: String, mut rng: Rng) raises -> GV:
    """harness.rs `value`."""
    if t == "Str":
        var a = g.strings[rng.below(len(g.strings))]
        if rng.below(5) == 0:
            return gv_str(a + g.strings[rng.below(len(g.strings))])
        return gv_str(a)
    if t == "Int":
        return gv_int(g.ints[rng.below(len(g.ints))])
    if t == "F64":
        var n = len(g.floats)
        var i = rng.below(n + 4)
        if i < n:
            return g.floats[i].copy()
        if i == n:
            return gv_marker("-0")
        if i == n + 1:
            return gv_marker("NaN")
        if i == n + 2:
            return gv_marker("Infinity")
        return gv_marker("-Infinity")
    if t == "Bool":
        return gv_text(BOOL, "true" if rng.below(2) == 0 else "false")
    if t == "Unit":
        return gv_undefined()
    if t.startswith("Vec:"):
        var inner = String(t[byte=4:])
        var items = List[GV]()
        for _ in range(rng.below(4)):
            items.append(value(g, inner, rng))
        return gv_array(items)
    if t.startswith("Opt:"):
        if rng.below(4) == 0:
            return gv_undefined()
        return value(g, String(t[byte=4:]), rng)
    # Json
    var k = rng.below(len(g.json_values))
    return g.json_values[k].copy()


def trap_values(g: Gen, t: String) raises -> List[GV]:
    """harness.rs `trap_values`."""
    var out = List[GV]()
    if t == "Str":
        for s in g.string_traps:
            out.append(gv_str(s))
    elif t == "Int":
        var ints: List[Int] = [
            -7,
            -1,
            0,
            2147483648,
            -2147483649,
            9007199254740993,
            I64_MAX,
            I64_MIN,
        ]
        for n in ints:
            out.append(gv_int(n))
    elif t == "F64":
        for v in g.float_traps:
            out.append(v.copy())
        out.append(gv_marker("-0"))
    elif t.startswith("Vec:"):
        var inner = String(t[byte=4:])
        out.append(gv_text(ARRAY, "[]"))
        if inner == "Str":
            var items = List[GV]()
            for s in ["b", "a", "B", "é", "10", "9", "a"]:
                items.append(gv_str(s))
            out.append(gv_array(items))
        elif inner == "Int":
            var items = List[GV]()
            for n in [-7, 3, 0, I64_MAX, -1]:
                items.append(gv_int(n))
            out.append(gv_array(items))
        elif inner == "F64":
            out.append(gv_array(g.float_vec_traps))
    elif t.startswith("Opt:"):
        out.append(gv_undefined())
        for v in trap_values(g, String(t[byte=4:])):
            out.append(v.copy())
    elif t == "Json":
        out.append(
            gv_text(
                OBJECT, '{"zebra":1,"apple":2,"10":3,"2":4,"é":5,"Apple":6}'
            )
        )
        out.append(
            # serde_json writes 1e21 as `1e+21`.
            gv_text(OBJECT, '{"n":9007199254740993,"f":1e+21,"t":0.1,"neg":-7}')
        )
        out.append(gv_text(ARRAY, "[3,1,2]"))
        out.append(gv_text(OBJECT, "{}"))
    return out^


def trap_args(
    g: Gen, params: List[Param], base: List[GV], regex: Bool
) raises -> List[List[GV]]:
    """harness.rs `trap_args`: every trap value in every parameter, one at a
    time, the other arguments as in `base`."""
    var out = List[List[GV]]()
    var kept = List[Param]()
    for p in params:
        if not p.ts_type.startswith("len:"):
            kept.append(p.copy())
    var plain = 0
    for p in kept:
        if not p.rest:
            plain += 1
    if len(base) < plain:
        return out^
    for i in range(len(kept)):
        ref p = kept[i]
        if p.rest or i >= len(base):
            continue
        var t = param_rtype(p)
        var structured = contains_json(t) and t != "Json"
        var shown = trim(p.ts_type)
        var any = (
            shown == "any"
            or shown == "unknown"
            or shown == "object"
            or shown == "Object"
        )
        if structured or (t == "Json" and not any):
            continue
        var values = trap_values(g, t)
        if regex and t == "Str":
            for s in g.regex_traps:
                values.append(gv_str(s))
        for v in values:
            if base[i].text != v.text:
                var args = base.copy()
                args[i] = v.copy()
                out.append(args^)
    return out^


def args_for(mut g: Gen, params: List[Param], mut rng: Rng) raises -> List[GV]:
    """harness.rs `args_for` (C pointer parameters are declined by the
    caller)."""
    var args = List[GV]()
    for p in params:
        if p.ts_type.startswith("len:"):
            continue
        var t = param_rtype(p)
        if p.rest:
            var inner = String(t[byte=4:]) if t.startswith("Vec:") else t
            for _ in range(rng.below(3)):
                args.append(value(g, inner, rng))
        elif contains_json(t):
            # Structured parameters: values that fit the type, and now and
            # then one that does not, so error paths get recorded too.
            var v: GV
            if rng.below(100) < 15:
                v = value(g, "Json", rng)
            else:
                var s = g.shapes.parse(p.ts_type)
                v = shaped(g, s, rng, 0)
            if p.optional and rng.below(5) == 0:
                args.append(gv_undefined())
            else:
                args.append(v^)
        else:
            args.append(value(g, t, rng))
    # Search-like functions: often derive one string from another.
    var strs = List[Int]()
    for i in range(len(args)):
        if args[i].kind == STR:
            strs.append(i)
    if len(strs) >= 2 and rng.below(10) < 5:
        var src = strs[rng.below(len(strs))]
        var to = strs[rng.below(len(strs))]
        if src != to:
            var source = args[src].raw
            var n = Int(py=g.py["cp_len"](PythonObject(source)))
            if n > 0:
                var start = rng.below(n)
                var end = start + 1 + rng.below(n - start)
                var upper = rng.below(4) == 0
                args[to] = gv_str(
                    String(
                        py=g.py["cp_slice"](
                            PythonObject(source),
                            PythonObject(start),
                            PythonObject(end),
                            PythonObject(upper),
                        )
                    )
                )
    # Trailing optional arguments: sometimes omitted.
    while (
        len(args) > 0
        and args[len(args) - 1].text == UNDEFINED
        and rng.below(2) == 0
    ):
        _ = args.pop()
    return args^


def generate(mut g: Gen, f: ExportedFn, count: Int) raises -> List[List[GV]]:
    """harness.rs `generate` (salt 0)."""
    var rng = Rng(name_seed(f.name, 0x9E37_79B9_7F4A_7C15))
    var seen = Set[String]()
    var out = List[List[GV]]()
    var attempts = 0
    while len(out) < count and attempts < count * 20:
        attempts += 1
        var args = args_for(g, f.params, rng)
        var key = array_text(args)
        if key not in seen:
            seen.add(key)
            out.append(args^)
    return out^


def intify(params: List[Param], mut args: List[GV]):
    """Integral float arguments of `number` parameters, as ints."""
    for i in range(min(len(params), len(args))):
        if params[i].ts_type != "number" or args[i].kind != FLOAT:
            continue
        var x = args[i].num
        var whole = x == Float64(Int(x)) if abs(x) < 1e15 else False
        var negative_zero = x == 0.0 and args[i].text.startswith("-")
        if whole and not negative_zero:
            args[i] = gv_int(Int(x))


def case_text(f: ExportedFn, module: String, args: List[GV]) -> String:
    """`{"fn", "module", "args"}`, with keyword-only parameters moved into
    `kwargs` (an omitted one left out)."""
    var head = String('{"fn":', write_string(f.name), ',"module":')
    head += write_string(module) + ',"args":'
    var keyword = False
    for p in f.params:
        if p.keyword_only:
            keyword = True
    if not keyword:
        return head + array_text(args) + "}"
    var positional = List[GV]()
    var kwargs = Obj()
    for i in range(len(args)):
        if i < len(f.params) and f.params[i].keyword_only:
            if args[i].text != UNDEFINED:
                kwargs.insert(f.params[i].name, args[i].text)
        else:
            positional.append(args[i].copy())
    return head + array_text(positional) + ',"kwargs":' + kwargs.text() + "}"


def scenarios(
    mut g: Gen, c: ExportedClass, count: Int, module: String
) raises -> List[String]:
    """harness.rs `scenarios` (salt 0), each with its `module`."""
    var rng = Rng(name_seed(c.name, 0x2545_F491_4F6C_DD1D))
    var out = List[String]()
    for _ in range(count):
        var ctor = args_for(g, c.constructor, rng)
        var steps = 0 if len(c.methods) == 0 else 1 + rng.below(12)
        var seen = List[GV]()
        for v in ctor:
            if v.kind == STR:
                seen.append(v.copy())
        var calls = String("[")
        for k in range(steps):
            ref m = c.methods[rng.below(len(c.methods))]
            var args = args_for(g, m.params, rng)
            for i in range(len(args)):
                if args[i].kind == STR:
                    if len(seen) > 0 and rng.below(2) == 0:
                        args[i] = seen[rng.below(len(seen))].copy()
                    else:
                        seen.append(args[i].copy())
            if k > 0:
                calls += ","
            calls += String(
                '{"method":', write_string(m.name), ',"args":', array_text(args)
            )
            calls += "}"
        calls += "]"
        var text = String('{"class":', write_string(c.name), ',"ctor":')
        text += array_text(ctor) + ',"calls":' + calls
        text += ',"module":' + write_string(module) + "}"
        out.append(text^)
    return out^
