# Go: the cgo wrapper package (the original API over the Mojo library) and
# `exports.mojo`, its typed C exports (port of src/codegen_go.rs `wrapper`,
# `typed_mojo` and what they use). The wrapper's package name, the unit's
# sources and their `type` declarations are read by analyze_tree.py
# (`go_unit_sources`, `go_type_decls`) and passed in.

from mojo_anything.codegen_ffi import dispatcher_mojo
from mojo_anything.codegen_mojo import (
    ExportedFn,
    Manifest,
    PortApi,
    PortFn,
    go_mojo_type,
    join,
    trim,
    trim_end_matches,
    trim_start_matches,
)
from mojo_anything.codegen_mojo_c import BUILD_DIR
from mojo_anything.embedded import (
    go_call,
    go_helpers,
    go_typed_helpers,
    go_typed_helpers_mojo,
)

comptime EXPORTS = "exports.mojo"


@fieldwise_init
struct Results(Copyable, Movable):
    var types: List[String]
    var fallible: Bool


def _split_top(text: String) -> List[String]:
    var out = List[String]()
    var depth = 0
    var bytes = text.as_bytes()
    var start = 0
    for i in range(len(bytes)):
        var c = bytes[i]
        if c == 91 or c == 40 or c == 123:
            depth += 1
        elif c == 93 or c == 41 or c == 125:
            depth -= 1
        elif c == 44 and depth == 0:
            out.append(trim(String(text[byte=start:i])))
            start = i + 1
    var last = trim(String(text[byte=start:]))
    if last.byte_length() > 0:
        out.append(last)
    return out^


def results(f: ExportedFn) -> Results:
    """The result types of a Go function, without the trailing `error`, and
    whether it has one."""
    var text = f.native_return.or_else("()")
    var inner = trim_end_matches(trim_start_matches(trim(text), "("), ")")
    var parts = _split_top(inner)
    var fallible = len(parts) > 0 and parts[len(parts) - 1] == "error"
    if fallible:
        _ = parts.pop()
    return Results(parts^, fallible)


def _is_word(b: UInt8) -> Bool:
    return (
        (b >= 48 and b <= 57)
        or (b >= 65 and b <= 90)
        or (b >= 97 and b <= 122)
        or b == 95
    )


def local_types(t: String) -> List[String]:
    """Exported identifiers in a Go type: the package's own named types."""
    var out = List[String]()
    var bytes = t.as_bytes()
    var prev: UInt8 = 32
    var start = 0
    var n = len(bytes)
    for i in range(n + 1):
        if i < n and _is_word(bytes[i]):
            continue
        if i > start:
            var first = bytes[start]
            if first >= 65 and first <= 90 and prev != 46:
                out.append(String(t[byte=start:i]))
        if i < n:
            prev = bytes[i]
        start = i + 1
    return out^


def used_types(m: Manifest) -> List[String]:
    """Every named type the exported signatures use, sorted, once each."""
    var names = List[String]()
    for f in m.exports:
        var ts = List[String]()
        for p in f.params:
            if p.native_type:
                ts.append(p.native_type.value())
        for r in results(f).types:
            ts.append(r)
        for t in ts:
            for w in local_types(t):
                names.append(w)
    for i in range(1, len(names)):
        var k = i
        while k > 0 and names[k] < names[k - 1]:
            names.swap_elements(k, k - 1)
            k -= 1
    var out = List[String]()
    for n in names:
        if len(out) == 0 or out[len(out) - 1] != n:
            out.append(n)
    return out^


def typed_c(go: String) -> Optional[String]:
    """The C type of a Go type that crosses cgo directly."""
    var t = trim(go)
    if (
        t == "int"
        or t == "int8"
        or t == "int16"
        or t == "int32"
        or t == "int64"
        or t == "uint8"
        or t == "uint16"
        or t == "uint32"
        or t == "byte"
        or t == "rune"
    ):
        return String("int64_t")
    if t == "uint" or t == "uint64" or t == "uintptr":
        return String("uint64_t")
    if t == "float64" or t == "float32":
        return String("double")
    if t == "bool":
        return String("uint8_t")
    if t == "string":
        return String("string")
    return None


def typed(m: Manifest, f: PortFn) -> Optional[Int]:
    """The export a port function crosses as a typed cgo call, by index."""
    var at = -1
    for i in range(len(m.exports)):
        if m.exports[i].name == f.js_name:
            at = i
            break
    if at < 0:
        return None
    ref e = m.exports[at]
    if len(e.params) != len(f.param_types):
        return None
    for i in range(len(e.params)):
        if not e.params[i].native_type:
            return None
        var native = e.params[i].native_type.value()
        if not typed_c(native):
            return None
        if go_mojo_type(native) != f.param_types[i]:
            return None
    var r = results(e)
    if len(r.types) == 0:
        if f.ret == "None":
            return at
        return None
    if len(r.types) == 1:
        if typed_c(r.types[0]) and go_mojo_type(r.types[0]) == f.ret:
            return at
        return None
    return None


def uses_dispatcher(m: Manifest, api: PortApi) -> Bool:
    for f in api.functions:
        if not typed(m, f):
            return True
    return False


def _typed_c_params(e: ExportedFn) -> List[String]:
    var params = List[String]()
    for i in range(len(e.params)):
        var name = String("ra_arg", i)
        var c = typed_c(e.params[i].native_type.or_else("")).or_else("")
        if c == "string":
            params.append(
                String("const uint8_t *", name, "_ptr, size_t ", name, "_len")
            )
        else:
            params.append(String(c, " ", name))
    var r = results(e)
    if len(r.types) > 0:
        var c = typed_c(r.types[0])
        if c:
            if c.value() == "string":
                params.append("uint8_t *out, size_t out_cap, size_t *out_len")
            else:
                params.append(String(c.value(), " *out"))
    params.append("char **err")
    return params^


def _typed_prototypes(m: Manifest, api: PortApi) -> String:
    var out = String("")
    for f in api.functions:
        var at = typed(m, f)
        if not at:
            continue
        out += String(
            "int mojo_anything_t_",
            f.js_name,
            "(",
            join(_typed_c_params(m.exports[at.value()]), ", "),
            ");\n",
        )
    return out


def _wrapper_params(e: ExportedFn) -> String:
    var parts = List[String]()
    for i in range(len(e.params)):
        parts.append(
            String("raArg", i, " ", e.params[i].native_type.or_else("any"))
        )
    return join(parts, ", ")


def _ret(all: List[String]) -> String:
    if len(all) == 0:
        return ""
    if len(all) == 1:
        return " " + all[0]
    return String(" (", join(all, ", "), ")")


def _typed_go(e: ExportedFn) -> String:
    """The Go wrapper function of a typed export."""
    var r = results(e)
    var result = Optional[String](None)
    if len(r.types) > 0:
        result = r.types[0]
    var params = _wrapper_params(e)
    var sig = List[String]()
    if result:
        sig.append(result.value())
    if r.fallible:
        sig.append("error")
    var ret = _ret(sig)
    var args = List[String]()
    for i in range(len(e.params)):
        var name = String("raArg", i)
        var c = typed_c(e.params[i].native_type.or_else("")).or_else("")
        if c == "string":
            args.append(String("mojoAnythingStr(", name, ")"))
            args.append(String("C.size_t(len(", name, "))"))
        elif c == "uint8_t":
            args.append(String("mojoAnythingBool(", name, ")"))
        else:
            args.append(String("C.", c, "(", name, ")"))
    var rt = Optional[String](None)
    if result:
        rt = typed_c(result.value())
    var zero = String("")
    if rt and rt.value() == "string":
        zero = '""'
    elif rt and rt.value() == "uint8_t":
        zero = "false"
    elif result:
        zero = "0"
    var fail: String
    if r.fallible:
        var back = String("errors.New(mojoAnythingErr(errp))")
        if zero.byte_length() > 0:
            back = String(zero, ", errors.New(mojoAnythingErr(errp))")
        fail = String("\tif status == 1 {\n\t\treturn ", back, "\n\t}\n")
    else:
        fail = "\tif status == 1 {\n\t\tpanic(mojoAnythingErr(errp))\n\t}\n"
    var body = String("\tvar errp *C.char\n")
    var ok_tail = String("")
    if r.fallible:
        ok_tail = ", nil"
    if rt and rt.value() == "string":
        var a = args.copy()
        a.append("(*C.uint8_t)(unsafe.Pointer(&buf[0]))")
        a.append("C.size_t(len(buf))")
        a.append("&n")
        a.append("&errp")
        var call = String("C.mojo_anything_t_", e.name, "(", join(a, ", "), ")")
        body += String(
            (
                "\tvar stack [256]byte\n\tbuf := stack[:]\n\tvar n"
                " C.size_t\n\tstatus := "
            ),
            call,
            "\n",
        )
        body += String(
            (
                "\tfor status == 2 {\n\t\tbuf = make([]byte,"
                " int(n))\n\t\tstatus = "
            ),
            call,
            "\n\t}\n",
        )
        body += fail
        body += String("\treturn string(buf[:n])", ok_tail, "\n")
    elif rt:
        var c = rt.value()
        var a = args.copy()
        a.append("&out")
        a.append("&errp")
        body += String(
            "\tvar out C.",
            c,
            "\n\tstatus := C.mojo_anything_t_",
            e.name,
            "(",
            join(a, ", "),
            ")\n",
        )
        body += fail
        if c == "uint8_t":
            body += String("\treturn out != 0", ok_tail, "\n")
        else:
            body += String(
                "\treturn ", result.or_else(""), "(out)", ok_tail, "\n"
            )
    else:
        var a = args.copy()
        a.append("&errp")
        body += String(
            "\tstatus := C.mojo_anything_t_", e.name, "(", join(a, ", "), ")\n"
        )
        body += fail
        if r.fallible:
            body += "\treturn nil\n"
    return String(
        "\n// ",
        e.name,
        " is the Mojo port of `",
        e.prototype.or_else(e.name),
        "` (`",
        e.file,
        ":",
        e.line,
        "`): a typed call, no JSON.\nfunc ",
        e.name,
        "(",
        params,
        ")",
        ret,
        " {\n",
        body,
        "}\n",
    )


def wrapper(
    m: Manifest, api: PortApi, package: String, types: List[String]
) -> String:
    """The wrapper package: the original package's API, each function calling
    the Mojo library."""
    var lib = m.lib_name()
    var dispatcher = uses_dispatcher(m, api)
    var call_c = String("")
    if dispatcher:
        call_c = (
            "char *mojo_anything_call(const char *name, const char *args);\n"
        )
    var out = String(
        "// Package ",
        package,
        " is the Mojo port of `",
        m.unit,
        "`, generated by mojo-anything: the same API, each\n",
        "// function calling the Mojo library. Regenerate with `mojo-anything",
        " refresh`.\n",
        "package ",
        package,
        "\n\n/*\n#cgo LDFLAGS: -L${SRCDIR}/../",
        BUILD_DIR,
        " -l",
        lib,
        " -Wl,-rpath,${SRCDIR}/../",
        BUILD_DIR,
        "\n#include <stdint.h>\n#include <stdlib.h>\n",
        call_c,
        "void mojo_anything_free(char *ptr);\n",
        _typed_prototypes(m, api),
        '*/\nimport "C"\n\n',
        (
            "import"
            ' (\n\t"encoding/json"\n\t"errors"\n\t"fmt"\n\t"math"\n\t"reflect"\n\t"unicode/utf8"\n\t"unsafe"\n)\n\n'
        ),
        (
            "var _ = json.Marshal\nvar _ = errors.New\nvar _ = fmt.Sprint\nvar"
            " _ = math.NaN\nvar _ = reflect.ValueOf\n"
        ),
        "var _ = utf8.ValidString\nvar _ = unsafe.Pointer(nil)\n",
    )
    for t in types:
        out += String("\n", t, "\n")
    out += go_helpers()
    if dispatcher:
        out += go_call()
    var typed_fns = List[String]()
    for f in api.functions:
        if typed(m, f):
            typed_fns.append(f.js_name)
    if len(typed_fns) > 0:
        out += go_typed_helpers()
    for f in m.exports:
        var is_typed = False
        for n in typed_fns:
            if n == f.name:
                is_typed = True
        if is_typed:
            out += _typed_go(f)
            continue
        var r = results(f)
        var params = _wrapper_params(f)
        var all = r.types.copy()
        if r.fallible:
            all.append("error")
        var ret = _ret(all)
        var args = List[String]()
        for i in range(len(f.params)):
            args.append(String("raArg", i))
        var call_args = String("")
        if len(args) > 0:
            call_args = ", " + join(args, ", ")
        out += String(
            "\n// ",
            f.name,
            " is the Mojo port of `",
            f.prototype.or_else(f.name),
            "` (`",
            f.file,
            ":",
            f.line,
            "`).\nfunc ",
            f.name,
            "(",
            params,
            ")",
            ret,
            " {\n",
        )
        var names = List[String]()
        var decls = String("")
        for i in range(len(r.types)):
            names.append(String("r", i))
            decls += String("\tvar r", i, " ", r.types[i], "\n")
        var raw = String("raw")
        if len(r.types) == 0:
            raw = "_"
        out += String(
            "\t",
            raw,
            ', err := mojoAnythingCall("',
            f.name,
            '"',
            call_args,
            ")\n",
        )
        if r.fallible:
            var back = names.copy()
            back.append("err")
            out += String(
                "\tif err != nil {\n",
                decls,
                "\t\treturn ",
                join(back, ", "),
                "\n\t}\n",
            )
        else:
            out += "\tmojoAnythingMust(err)\n"
        out += decls
        var k = len(r.types)
        if k == 1:
            out += "\tmojoAnythingMust(mojoAnythingDecode(raw, &r0))\n"
        elif k > 1:
            out += String(
                (
                    "\tvar parts"
                    " []json.RawMessage\n\tmojoAnythingMust(json.Unmarshal(raw,"
                    " &parts))\n\tif len(parts) != "
                ),
                k,
                ' {\n\t\tpanic("mojo-anything: expected ',
                k,
                ' results")\n\t}\n',
            )
            for i in range(k):
                out += String(
                    "\tmojoAnythingMust(mojoAnythingDecode(parts[",
                    i,
                    "], &r",
                    i,
                    "))\n",
                )
        var back = names.copy()
        if r.fallible:
            back.append("nil")
        if len(back) == 0:
            out += "}\n"
        else:
            out += String("\treturn ", join(back, ", "), "\n}\n")
    return out


def _c_mojo(c: String) -> String:
    if c == "int64_t":
        return "Int64"
    if c == "uint64_t":
        return "UInt64"
    if c == "double":
        return "Float64"
    return "UInt8"


def typed_mojo(m: Manifest, api: PortApi) raises -> String:
    """`exports.mojo` of a Go unit: one `mojo_anything_t_<name>` per typed
    function, the JSON dispatcher when some function needs it, and
    `mojo_anything_free`."""
    var out: String
    if uses_dispatcher(m, api):
        out = dispatcher_mojo(m, api)
    else:
        out = String(
            "# Typed C exports for the Mojo port of `",
            m.unit,
            "`, generated by mojo-anything. Regenerate\n",
            "# with `mojo-anything refresh`.\n\n",
            "from std.ffi import external_call\nfrom std.memory import",
            " Pointer\n\n",
            "import port\n\n\n",
            "@export\n",
            (
                "def mojo_anything_free(p: Optional[Pointer[Int8,"
                ' MutAnyOrigin]]) abi("C"):\n    '
            ),
            'if p:\n        external_call["free", NoneType](p.value())\n',
        )
    var any = False
    for f in api.functions:
        if typed(m, f):
            any = True
    if not any:
        return out
    out += go_typed_helpers_mojo()
    for f in api.functions:
        var at = typed(m, f)
        if not at:
            continue
        ref e = m.exports[at.value()]
        var params = List[String]()
        var args = List[String]()
        for i in range(len(e.params)):
            var c = typed_c(e.params[i].native_type.or_else("")).or_else("")
            var port = f.param_types[i]
            if c == "string":
                params.append(
                    String(
                        "a",
                        i,
                        "_ptr: Optional[Pointer[UInt8, ImmutAnyOrigin]], a",
                        i,
                        "_len: UInt",
                    )
                )
                args.append(String("_go_str(a", i, "_ptr, a", i, "_len)"))
            else:
                params.append(String("a", i, ": ", _c_mojo(c)))
                if port == "Bool":
                    args.append(String("a", i, " != 0"))
                else:
                    args.append(String(port, "(a", i, ")"))
        var r = results(e)
        var rt = Optional[String](None)
        if len(r.types) > 0:
            rt = typed_c(r.types[0])
        var call = String("port.", f.rust_name, "(", join(args, ", "), ")")
        var ok: String
        if rt and rt.value() == "string":
            params.append(
                "res: Optional[Pointer[UInt8, MutAnyOrigin]], res_cap: UInt,"
                " res_len: Optional[Pointer[UInt, MutAnyOrigin]]"
            )
            ok = String(
                "var value = ",
                call,
                (
                    "\n        var b = value.as_bytes()\n       "
                    " res_len.value()[] = UInt(len(b))\n        if len(b) >"
                    " Int(res_cap):\n            return 2\n        if len(b) >"
                    " 0:\n            var o = res.value()\n            for i in"
                    " range(len(b)):\n                o[unsafe_offset=i] ="
                    " b[i]\n        return 0"
                ),
            )
        elif rt:
            var mojo = _c_mojo(rt.value())
            params.append(
                String("res: Optional[Pointer[", mojo, ", MutAnyOrigin]]")
            )
            var value = String(mojo, "(value)")
            if mojo == "UInt8":
                value = "UInt8(1) if value else UInt8(0)"
            ok = String(
                "var value = ",
                call,
                "\n        res.value()[] = ",
                value,
                "\n        return 0",
            )
        else:
            ok = String(call, "\n        return 0")
        params.append("err: Optional[Pointer[Int, MutAnyOrigin]]")
        out += String(
            "\n\n# `",
            e.prototype.or_else(e.name),
            "`: a typed call.\n@export\ndef mojo_anything_t_",
            f.js_name,
            "(\n    ",
            join(params, ",\n    "),
            ',\n) abi("C") -> Int32:\n    try:\n        ',
            ok,
            "\n    except e:\n        return _fail(err, String(e))\n",
        )
    return out


def wrapper_go_mod(m: Manifest) -> String:
    """harness_go::wrapper_go_mod."""
    return String("module mojo-anything.local/", m.lib_name(), "\n\ngo 1.21\n")
