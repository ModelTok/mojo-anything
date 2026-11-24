# The JSON dispatcher (port of src/codegen_ffi.rs `dispatcher_mojo`): one
# Mojo library exporting `mojo_anything_call` (a function name and its
# arguments as JSON in, `{"ok": ...}`, `{"error": ...}` or `{"panic": ...}`
# out) and `mojo_anything_free`. Go and Ruby units use it here; `--batch`
# entries are not written (bridge and refresh decline batches).

from mojo_anything.codegen_mojo import Manifest, PortApi, join
from mojo_anything.embedded import dispatcher_helpers

comptime DISPATCHER = "dispatcher.mojo"


def _mangle(ty: String) -> String:
    var out = String("")
    var bytes = ty.as_bytes()
    for i in range(len(bytes)):
        var b = bytes[i]
        if b == 32 or (b >= 9 and b <= 13) or b == 93:
            continue
        if b == 91 or b == 44:
            out += "_"
        else:
            out += String(ty[byte = i : i + 1])
    return out


def _inner(ty: String, wrapper: String) -> Optional[String]:
    var head = wrapper + "["
    if (
        ty.startswith(head)
        and ty.endswith("]")
        and ty.byte_length() > head.byte_length()
    ):
        return String(ty[byte = head.byte_length() : ty.byte_length() - 1])
    return None


@fieldwise_init
struct _Bounds(Copyable, Movable):
    var signed: Bool
    var lo: String
    var hi: String


def _int_bounds(ty: String) -> Optional[_Bounds]:
    if ty == "Int" or ty == "Int64":
        return _Bounds(True, "Int64.MIN", "Int64.MAX")
    if ty == "Int8":
        return _Bounds(True, "-128", "127")
    if ty == "Int16":
        return _Bounds(True, "-32768", "32767")
    if ty == "Int32":
        return _Bounds(True, "-2147483648", "2147483647")
    if ty == "UInt" or ty == "UInt64":
        return _Bounds(False, "0", "UInt64.MAX")
    if ty == "UInt8":
        return _Bounds(False, "0", "255")
    if ty == "UInt16":
        return _Bounds(False, "0", "65535")
    if ty == "UInt32":
        return _Bounds(False, "0", "4294967295")
    return None


struct Converters(Movable):
    """The type converters a dispatcher needs, each written once."""

    var text: String
    var done: List[String]
    var absent: String

    def __init__(out self, language: String):
        self.text = String("")
        self.done = List[String]()
        if language == "ts":
            self.absent = "_undefined()"
        else:
            self.absent = "JsonValue()"

    def has(self, name: String) -> Bool:
        for d in self.done:
            if d == name:
                return True
        return False


def from_json(mut out: Converters, ty: String) raises -> String:
    """`_from_json_<T>` (JSON value to `ty`) and what it needs; its name."""
    var name = "_from_json_" + _mangle(ty)
    if out.has(name):
        return name
    var body: String
    if ty == "JsonValue":
        body = "return v.copy()"
    elif ty == "Float64":
        body = "return as_float(v)"
    elif ty == "Float32":
        body = "return Float32(as_float(v))"
    elif ty == "String":
        body = "return json_string(v)"
    elif ty == "Bool":
        body = "return json_bool(v)"
    else:
        var bounds = _int_bounds(ty)
        var list = _inner(ty, "List")
        var opt = _inner(ty, "Optional")
        if bounds:
            var bd = bounds.value().copy()
            if bd.signed:
                body = String(
                    "return ", ty, "(json_int(v, ", bd.lo, ", ", bd.hi, "))"
                )
            else:
                body = String("return ", ty, "(json_uint(v, ", bd.hi, "))")
        elif list:
            var t = list.value()
            var item = from_json(out, t)
            body = String(
                "json_array(v)\n    var items = List[",
                t,
                "]()\n    for item in v.array():\n        items.append(",
                item,
                "(item))\n    return items^",
            )
        elif opt:
            var t = opt.value()
            var value = from_json(out, t)
            body = String(
                (
                    "if v.is_null() or (v.is_object() and len(v.object()) == 1"
                    ' and "$undefined" in v.object()):\n        return'
                    " Optional["
                ),
                t,
                "](None)\n    return Optional[",
                t,
                "](",
                value,
                "(v))",
            )
        else:
            raise Error(String("`", ty, "` cannot cross the JSON dispatcher"))
    out.text += String(
        "\n\ndef ", name, "(v: JsonValue) raises -> ", ty, ":\n    ", body, "\n"
    )
    out.done.append(name)
    return name


def to_json(mut out: Converters, ty: String) raises -> String:
    """`_to_json_<T>` (`ty` to a JSON value) and what it needs; its name."""
    var name = "_to_json_" + _mangle(ty)
    if out.has(name):
        return name
    var body: String
    if ty == "JsonValue":
        body = "return v.copy()"
    elif ty == "Float64":
        body = "return json_float(v)"
    elif ty == "Float32":
        body = "return json_float(Float64(v))"
    elif ty == "String":
        body = "return JsonValue(String(v))"
    elif ty == "Bool":
        body = "return JsonValue(v)"
    else:
        var bounds = _int_bounds(ty)
        var list = _inner(ty, "List")
        var opt = _inner(ty, "Optional")
        if bounds:
            if bounds.value().signed:
                body = "return JsonValue(Int64(v))"
            else:
                body = "return JsonValue(UInt64(v))"
        elif list:
            var item = to_json(out, list.value())
            body = String(
                (
                    "var items = Array()\n    for item in v:\n       "
                    " items.append("
                ),
                item,
                "(item))\n    return JsonValue(items^)",
            )
        elif opt:
            var value = to_json(out, opt.value())
            body = String(
                "if not v:\n        return ",
                out.absent,
                "\n    return ",
                value,
                "(v.value())",
            )
        else:
            raise Error(String("`", ty, "` cannot cross the JSON dispatcher"))
    out.text += String(
        "\n\ndef ", name, "(v: ", ty, ") raises -> JsonValue:\n    ", body, "\n"
    )
    out.done.append(name)
    return name


def dispatcher_mojo(m: Manifest, api: PortApi) raises -> String:
    """`dispatcher.mojo` over every port function (codegen_ffi.rs
    `dispatcher_mojo`, no batches)."""
    var conv = Converters(m.language)
    var calls = String("")
    var arms = String("")
    for f in api.functions:
        var n = len(f.param_types)
        var s = String("s")
        if n == 1:
            s = ""
        calls += String(
            "\n\ndef _call_",
            f.rust_name,
            "(args: Array) -> String:\n    if len(args) != ",
            n,
            ':\n        return _panic("',
            f.js_name,
            " takes ",
            n,
            " argument",
            s,
            ', got " + String(len(args)))\n',
        )
        for i in range(n):
            calls += String("    var a", i, ": ", f.param_types[i], "\n")
        if n > 0:
            calls += "    try:\n"
            for i in range(n):
                var conv_name: String
                try:
                    conv_name = from_json(conv, f.param_types[i])
                except e:
                    raise Error(String("`", f.rust_name, "`: ", String(e)))
                calls += String(
                    "        a", i, " = ", conv_name, "(args[", i, "])\n"
                )
            calls += String(
                '    except e:\n        return _panic("',
                f.js_name,
                ': " + String(e))\n',
            )
        var call_args = List[String]()
        for i in range(n):
            call_args.append(String("a", i))
        var call = String("port.", f.rust_name, "(", join(call_args, ", "), ")")
        var result: String
        if f.ret == "None":
            result = String(call, "\n        return _ok(", conv.absent, ")")
        else:
            var to: String
            try:
                to = to_json(conv, f.ret)
            except e:
                raise Error(String("`", f.rust_name, "`: ", String(e)))
            result = String(
                "var out = ", to, "(", call, ")\n        return _ok(out)"
            )
        calls += String(
            "    try:\n        ",
            result,
            "\n    except e:\n        return _error(String(e))\n",
        )
        arms += String(
            '    if name == "',
            f.js_name,
            '":\n        return _call_',
            f.rust_name,
            "(a)\n",
        )
    var refuse = String("False")
    if m.language == "ruby":
        refuse = "True"
    var bind = String("")
    if arms.byte_length() > 0:
        bind = "    ref a = args.array()\n"
    return String(
        "# The JSON dispatcher for the Mojo port of `",
        m.unit,
        "`, generated by mojo-anything. Regenerate\n",
        "# with `mojo-anything refresh`.\n\n",
        "from std.ffi import external_call\nfrom std.memory import Pointer\n\n",
        "from emberjson import Array, Object\nfrom json import JsonValue,",
        " as_float, json_array, json_bool, json_float, json_int, json_string,",
        " json_uint, parse_json, write_json\n\n",
        "import port\n",
        dispatcher_helpers(),
        conv.text,
        calls,
        "\n\n",
        "def _call(name: String, text: String) -> String:\n    ",
        "var args: JsonValue\n    try:\n        args = parse_json(text, ",
        refuse,
        ")\n    ",
        (
            'except e:\n        return _panic("the arguments are not JSON: " +'
            " String(e))\n    "
        ),
        (
            'if not args.is_array():\n        return _panic("the arguments are'
            ' not a JSON array")\n'
        ),
        bind,
        arms,
        '    return _panic("unknown function: " + name)\n\n\n',
        "@export\n",
        (
            "def mojo_anything_call(\n    name: Optional[Pointer[Int8,"
            " ImmutAnyOrigin]],\n    "
        ),
        (
            'args: Optional[Pointer[Int8, ImmutAnyOrigin]],\n) abi("C") ->'
            " Optional[Pointer[Int8, MutAnyOrigin]]:\n    "
        ),
        "return _answer(_call(_bytes_text(name), _bytes_text(args)))\n\n\n",
        "@export\n",
        (
            "def mojo_anything_free(p: Optional[Pointer[Int8, MutAnyOrigin]])"
            ' abi("C"):\n    '
        ),
        'if p:\n        external_call["free", NoneType](p.value())\n',
    )
