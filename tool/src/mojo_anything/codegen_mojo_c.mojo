# C units ported to Mojo (port of src/codegen_mojo_c.rs, and of the parts of
# src/codegen_c.rs it reads: how each parameter crosses, the structs passed by
# value, the prototypes and the header). The port holds no pointers: a
# `const char *` is `Optional[Span[UInt8, ImmutAnyOrigin]]`, a buffer and its
# size one span, a pointer to one value a `mut` `Optional` of it, and a
# `char **` into a string the offset it points to; `exports.mojo` reads and
# writes the pointers. The text handled here is ASCII (the reader declines
# anything else).

from mojo_anything.codegen_mojo import (
    ExportedFn,
    Manifest,
    Param,
    PortApi,
    STUB_MARK,
    is_space,
    join,
    mojo_escape,
    trim,
)

comptime C_STRUCTS = "c_structs"
comptime SHADOW_PREFIX = "mojo_anything_"
comptime EXPORTS = "exports.mojo"
comptime EXPORTS_SHADOW = "exports_shadow.mojo"
comptime BUILD_DIR = ".mojo-anything/build"

comptime SCALAR = 0
comptime STR = 1
comptime BYTES = 2
comptime BUFFER = 3
comptime LEN = 4
comptime OUT = 5
comptime STRUCT = 6
comptime OUTPTR = 7


@fieldwise_init
struct CKind(Copyable, Movable):
    """codegen_c `CKind`: the tag, and the index `Len` and `OutPtr` carry."""

    var tag: Int
    var index: Int

    def same(self, other: CKind) -> Bool:
        return self.tag == other.tag and self.index == other.index


@fieldwise_init
struct CStruct(Copyable, Movable):
    var c_name: String
    var types: List[String]
    var names: List[String]


def _words(s: String) -> List[String]:
    """str::split_whitespace for ASCII text."""
    var out = List[String]()
    var bytes = s.as_bytes()
    var start = -1
    for i in range(len(bytes) + 1):
        var space = i == len(bytes) or is_space(bytes[i])
        if space:
            if start >= 0:
                out.append(String(s[byte=start:i]))
                start = -1
        elif start < 0:
            start = i
    return out^


def c_bare(c: String) -> String:
    """The words of a C type other than `const`, joined by one space."""
    var kept = List[String]()
    for w in _words(c):
        if w != "const":
            kept.append(w)
    return join(kept, " ")


def _trim_stars(c: String) -> String:
    """`trim_end_matches(['*', ' '])`."""
    var bytes = c.as_bytes()
    var b = len(bytes)
    while b > 0 and (bytes[b - 1] == 42 or bytes[b - 1] == 32):
        b -= 1
    return String(c[byte=0:b])


def _index(text: String) -> Optional[Int]:
    """`usize::from_str` for the digits the reader writes."""
    if text.byte_length() == 0 or text.byte_length() > 18:
        return None
    var n = 0
    for b in text.as_bytes():
        if b < 48 or b > 57:
            return None
        n = n * 10 + Int(b) - 48
    return n


def mojo_scalar(c_type: String, char_signed: Bool) -> Optional[String]:
    """The Mojo type of a C scalar (c.rs `scalar`'s Rust type, as Mojo
    names it); `None` for `void` and the types Mojo cannot pass."""
    var c = c_bare(c_type)
    if c == "int" or c == "signed int" or c == "signed":
        return String("Int32")
    if c == "unsigned" or c == "unsigned int":
        return String("UInt32")
    if c == "short" or c == "short int" or c == "signed short":
        return String("Int16")
    if c == "unsigned short" or c == "unsigned short int":
        return String("UInt16")
    if c == "long" or c == "long int" or c == "signed long":
        return String("Int64")
    if c == "unsigned long" or c == "unsigned long int":
        return String("UInt64")
    if c == "long long" or c == "long long int" or c == "signed long long":
        return String("Int64")
    if c == "unsigned long long" or c == "unsigned long long int":
        return String("UInt64")
    if c == "char":
        if char_signed:
            return String("Int8")
        return String("UInt8")
    if c == "signed char" or c == "int8_t":
        return String("Int8")
    if c == "unsigned char" or c == "uint8_t":
        return String("UInt8")
    if c == "int16_t":
        return String("Int16")
    if c == "int32_t":
        return String("Int32")
    if c == "int64_t":
        return String("Int64")
    if c == "uint16_t":
        return String("UInt16")
    if c == "uint32_t":
        return String("UInt32")
    if c == "uint64_t":
        return String("UInt64")
    if c == "size_t":
        return String("UInt")
    if c == "ssize_t" or c == "ptrdiff_t" or c == "intptr_t":
        return String("Int")
    if c == "float":
        return String("Float32")
    if c == "double":
        return String("Float64")
    if c == "bool" or c == "_Bool":
        return String("Bool")
    return None


def c_kind(p: Param) -> CKind:
    """codegen_c `kind`."""
    var t = p.ts_type
    if t == "string":
        return CKind(STR, 0)
    if t == "bytes":
        return CKind(BYTES, 0)
    if t == "buffer":
        return CKind(BUFFER, 0)
    if t == "out":
        return CKind(OUT, 0)
    if t.startswith("struct:"):
        return CKind(STRUCT, 0)
    if t.startswith("outptr:"):
        var i = _index(String(t[byte=7:]))
        if i:
            return CKind(OUTPTR, i.value())
    if t.startswith("len:"):
        var i = _index(String(t[byte=4:]))
        if i:
            return CKind(LEN, i.value())
    return CKind(SCALAR, 0)


def returns_into(f: ExportedFn) -> Optional[Int]:
    if f.returns.startswith("ptr:"):
        return _index(String(f.returns[byte=4:]))
    return None


def pointee(c_type: String) -> String:
    """codegen_c `pointee`: what a pointer type points to, without
    `const`."""
    return c_bare(_trim_stars(c_type))


def _native(p: Param) -> String:
    if p.native_type:
        return p.native_type.value()
    return "int"


def c_struct(ts_type: String) -> Optional[CStruct]:
    """The struct a dialect type stands for (`struct:AVRational:int num,int
    den`)."""
    if not ts_type.startswith("struct:"):
        return None
    var rest = String(ts_type[byte=7:])
    var colon = rest.find(":")
    if colon < 0:
        return None
    var c_name = String(rest[byte=0:colon])
    var fields = String(rest[byte = colon + 1 :])
    var types = List[String]()
    var names = List[String]()
    for raw in fields.split(","):
        var f = trim(String(raw))
        var space = f.rfind(" ")
        if space < 0:
            return None
        types.append(String(f[byte=0:space]))
        names.append(String(f[byte = space + 1 :]))
    return CStruct(c_name, types^, names^)


def structs(m: Manifest) -> List[CStruct]:
    """The structs the unit's functions take or return by value, each
    once."""
    var out = List[CStruct]()
    for f in m.exports:
        var types = List[String]()
        for p in f.params:
            types.append(p.ts_type)
        types.append(f.returns)
        for ts in types:
            var s = c_struct(ts)
            if not s:
                continue
            var seen = False
            for o in out:
                if o.c_name == s.value().c_name:
                    seen = True
            if not seen:
                out.append(s.value().copy())
    return out^


def struct_name(s: CStruct) -> String:
    return mojo_escape(trim(trim_once(s.c_name, "struct ")))


def trim_once(s: String, prefix: String) -> String:
    if s.startswith(prefix):
        return String(s[byte = prefix.byte_length() :])
    return s


def _find_len(f: ExportedFn, i: Int) -> Optional[Int]:
    for k in range(len(f.params)):
        if c_kind(f.params[k]).same(CKind(LEN, i)):
            return k
    return None


@fieldwise_init
struct MojoParam(Copyable, Movable):
    var is_mut: Bool
    var ty: String


def _scalar_or_raise(p: Param, c: String, signed: Bool) raises -> String:
    var t = mojo_scalar(c, signed)
    if not t:
        raise Error(
            String(
                "`", p.name, "` has C type `", c, "`, which Mojo cannot pass"
            )
        )
    return t.value()


def _struct_or_raise(p: Param) raises -> String:
    var s = c_struct(p.ts_type)
    if not s:
        raise Error(String("`", p.name, "`: unreadable struct type"))
    return struct_name(s.value())


def mojo_param(p: Param, signed: Bool) raises -> Optional[MojoParam]:
    """A parameter's type in `port.mojo`; `None` for a length the span
    beside it carries."""
    var k = c_kind(p)
    if k.tag == SCALAR:
        return MojoParam(False, _scalar_or_raise(p, _native(p), signed))
    if k.tag == STR:
        return MojoParam(False, "Optional[Span[UInt8, ImmutAnyOrigin]]")
    if k.tag == BYTES:
        return MojoParam(False, "Span[UInt8, ImmutAnyOrigin]")
    if k.tag == BUFFER:
        return MojoParam(False, "Span[UInt8, MutAnyOrigin]")
    if k.tag == LEN:
        return None
    if k.tag == OUT:
        return MojoParam(
            True,
            String(
                "Optional[",
                _scalar_or_raise(p, pointee(_native(p)), signed),
                "]",
            ),
        )
    if k.tag == STRUCT:
        return MojoParam(False, _struct_or_raise(p))
    return MojoParam(True, "Optional[Int]")


def mojo_ret(f: ExportedFn, signed: Bool) raises -> Optional[String]:
    """The port's return type; `None` for `void`."""
    if returns_into(f):
        return String("Optional[Int]")
    var s = c_struct(f.returns)
    if s:
        return struct_name(s.value())
    var r = String("void")
    if f.native_return:
        r = f.native_return.value()
    if r.find("*") >= 0:
        raise Error(
            String(
                "`",
                f.name,
                "` returns `",
                r,
                "`, a pointer that does not point into a parameter",
            )
        )
    if trim(r) == "void":
        return None
    var t = mojo_scalar(r, signed)
    if not t:
        raise Error(
            String("`", f.name, "` returns `", r, "`, which Mojo cannot pass")
        )
    return t.value()


def c_struct_defs_mojo(m: Manifest, signed: Bool) raises -> String:
    """`c_structs.mojo`; empty when the unit passes no struct."""
    var all = structs(m)
    if len(all) == 0:
        return ""
    var out = String(
        "# The structs `",
        m.unit,
        "` passes by value, as C lays them out. Generated by mojo-anything.\n",
    )
    for s in all:
        out += String(
            "\n\n# `",
            s.c_name,
            "`.\n@fieldwise_init\nstruct ",
            struct_name(s),
            "(Copyable, Movable, TrivialRegisterPassable):\n",
        )
        for i in range(len(s.types)):
            var t = mojo_scalar(s.types[i], signed)
            if not t:
                raise Error(
                    String(
                        "field `",
                        s.names[i],
                        "` of `",
                        s.c_name,
                        "` has C type `",
                        s.types[i],
                        "`",
                    )
                )
            out += String(
                "    var ", mojo_escape(s.names[i]), ": ", t.value(), "\n"
            )
    return out


def _struct_names(m: Manifest) -> List[String]:
    var names = List[String]()
    for s in structs(m):
        names.append(struct_name(s))
    return names^


def port_mojo_c(m: Manifest, signed: Bool) raises -> String:
    """`port.mojo` for a C unit: one stub per function."""
    var body = String("")
    for f in m.exports:
        var params = List[String]()
        for p in f.params:
            var mp = mojo_param(p, signed)
            if mp:
                var pre = String("")
                if mp.value().is_mut:
                    pre = "mut "
                params.append(
                    String(pre, mojo_escape(p.name), ": ", mp.value().ty)
                )
        var ret = String("")
        var r = mojo_ret(f, signed)
        if r:
            ret = String(" -> ", r.value())
        body += String(
            "\n\n# Port of `", f.name, "` (`", f.file, ":", f.line, "`).\n"
        )
        if f.prototype:
            body += String("# C: `", f.prototype.value(), "`\n")
        for i in range(len(f.params)):
            var p = f.params[i].copy()
            var k = c_kind(p)
            var note: String
            if k.tag == STR:
                note = "the C string's bytes without its NUL; `None` for `NULL`"
            elif k.tag == BUFFER or k.tag == BYTES:
                var len_name = String("its length")
                var q = _find_len(f, i)
                if q:
                    len_name = String("`", f.params[q.value()].name, "`")
                note = String("as many bytes as ", len_name, " says")
            elif k.tag == OUT:
                note = "the value behind the pointer; `None` for `NULL`"
            elif k.tag == OUTPTR:
                note = String(
                    "where the pointer behind it points, as an offset into `",
                    f.params[k.index].name,
                    "`; `None` for `NULL`",
                )
            else:
                continue
            body += String("# `", mojo_escape(p.name), "`: ", note, ".\n")
        var into = returns_into(f)
        if into:
            body += String(
                "# Returns the offset into `",
                f.params[into.value()].name,
                "` the C function's pointer points to; `None` for `NULL`.\n",
            )
        body += String(
            "def ",
            mojo_escape(f.name),
            "(",
            join(params, ", "),
            ")",
            ret,
            ':\n    abort("',
            STUB_MARK,
            f.name,
            '")\n',
        )
    var out = String(
        "# The Mojo port of `",
        m.unit,
        (
            "`: `exports.mojo` exports each function under its C name.\n#\n#"
            " Replace each stub's `abort` with the port of the C function. C"
            " has no\n# error channel: return what the C code returns."
            " Integers wrap as C's do only where\n# the port says so, so use"
            " the same widths as the C code. No pointers here: the\n# exports"
            " read and write them.\n\nfrom std.os import abort\n"
        ),
    )
    var names = _struct_names(m)
    if len(names) > 0:
        out += String("\nfrom ", C_STRUCTS, " import ", join(names, ", "), "\n")
    out += body
    return out


comptime _C_STR = """
def _c_str(
    p: Optional[Pointer[Int8, ImmutAnyOrigin]],
) -> Optional[Span[UInt8, ImmutAnyOrigin]]:
    # SAFETY: the C caller passes NULL or a NUL-terminated string valid for the call.
    if not p:
        return None
    var ptr = p.value()
    var n = 0
    while ptr[unsafe_offset=n] != 0:
        n += 1
    return Span[UInt8, ImmutAnyOrigin](
        unsafe_ptr=ptr.unsafe_bitcast[UInt8](), length=n
    )
"""

comptime _BYTES = """
def _bytes(
    p: Optional[Pointer[UInt8, ImmutAnyOrigin]], n: Int
) -> Span[UInt8, ImmutAnyOrigin]:
    # SAFETY: the C caller passes NULL or `n` readable bytes valid for the call.
    if not p or n <= 0:
        return Span[UInt8, ImmutAnyOrigin]()
    return Span[UInt8, ImmutAnyOrigin](unsafe_ptr=p.value(), length=n)
"""

comptime _BYTES_MUT = """
def _bytes_mut(
    p: Optional[Pointer[UInt8, MutAnyOrigin]], n: Int
) -> Span[UInt8, MutAnyOrigin]:
    # SAFETY: the C caller passes NULL or `n` writable bytes, used by nothing else during the
    # call.
    if not p or n <= 0:
        return Span[UInt8, MutAnyOrigin]()
    return Span[UInt8, MutAnyOrigin](unsafe_ptr=p.value(), length=n)
"""

comptime _ADDR = """
def _addr(p: Optional[Pointer[Int8, ImmutAnyOrigin]]) -> Int:
    return Int(p.value()) if p else 0


def _addr(p: Optional[Pointer[UInt8, ImmutAnyOrigin]]) -> Int:
    return Int(p.value()) if p else 0


def _addr(p: Optional[Pointer[UInt8, MutAnyOrigin]]) -> Int:
    return Int(p.value()) if p else 0
"""


def _abi_param(p: Param, signed: Bool) raises -> String:
    """A C argument's type at the ABI, as `exports.mojo` declares it."""
    var k = c_kind(p)
    if k.tag == SCALAR or k.tag == LEN:
        return _scalar_or_raise(p, _native(p), signed)
    if k.tag == STR:
        return "Optional[Pointer[Int8, ImmutAnyOrigin]]"
    if k.tag == BYTES:
        return "Optional[Pointer[UInt8, ImmutAnyOrigin]]"
    if k.tag == BUFFER:
        return "Optional[Pointer[UInt8, MutAnyOrigin]]"
    if k.tag == OUT:
        return String(
            "Optional[Pointer[",
            _scalar_or_raise(p, pointee(_native(p)), signed),
            ", MutAnyOrigin]]",
        )
    if k.tag == STRUCT:
        return _struct_or_raise(p)
    return "Optional[Pointer[Int, MutAnyOrigin]]"


def exports_mojo(
    m: Manifest, api: PortApi, prefix: String, signed: Bool
) raises -> String:
    """`exports.mojo`: each function under its C name (`prefix` empty) or
    under `mojo_anything_<name>` for a shadow build."""
    var any_str = False
    var any_bytes = False
    var any_buffer = False
    var any_addr = False
    for f in m.exports:
        for p in f.params:
            var k = c_kind(p)
            if k.tag == STR:
                any_str = True
            elif k.tag == BYTES:
                any_bytes = True
            elif k.tag == BUFFER:
                any_buffer = True
            elif k.tag == OUTPTR:
                any_addr = True
        if returns_into(f):
            any_addr = True
    var body = String("")
    for f in m.exports:
        if mojo_escape(f.name) != f.name:
            raise Error(
                String(
                    "`",
                    f.name,
                    (
                        "` is a Mojo keyword, so Mojo cannot export a function"
                        " under that name"
                    ),
                )
            )
        body += _export_one(api, f, prefix, signed)
    var out = String(
        "# C exports for the Mojo port of `",
        m.unit,
        (
            "`, generated by mojo-anything from\n# `mojo-anything.json`."
            " Regenerate with `mojo-anything refresh`. Every pointer the"
            " port's\n# functions see as a span or an optional value is read"
            " and written here.\n\nfrom std.memory import Pointer\nfrom std.os"
            " import abort\n\nimport port\n"
        ),
    )
    var names = _struct_names(m)
    if len(names) > 0:
        out += String("from ", C_STRUCTS, " import ", join(names, ", "), "\n")
    if any_str:
        out += "\n" + _C_STR
    if any_bytes:
        out += "\n" + _BYTES
    if any_buffer:
        out += "\n" + _BYTES_MUT
    if any_addr:
        out += "\n" + _ADDR
    out += body
    return out


def _export_one(
    api: PortApi, f: ExportedFn, prefix: String, signed: Bool
) raises -> String:
    var params = List[String]()
    for p in f.params:
        params.append(String("a_", p.name, ": ", _abi_param(p, signed)))
    var before = String("")
    var after = String("")
    var call_args = List[String]()
    for i in range(len(f.params)):
        var p = f.params[i].copy()
        var a = String("a_", p.name)
        var v = String("v_", p.name)
        var k = c_kind(p)
        var len_of = String("0")
        var q = _find_len(f, i)
        if q:
            len_of = String("Int(a_", f.params[q.value()].name, ")")
        if k.tag == SCALAR or k.tag == STRUCT:
            call_args.append(a)
        elif k.tag == LEN:
            pass
        elif k.tag == STR:
            call_args.append(String("_c_str(", a, ")"))
        elif k.tag == BYTES:
            call_args.append(String("_bytes(", a, ", ", len_of, ")"))
        elif k.tag == BUFFER:
            call_args.append(String("_bytes_mut(", a, ", ", len_of, ")"))
        elif k.tag == OUT:
            var t = mojo_scalar(pointee(_native(p)), signed).or_else("Int32")
            before += String(
                "    var ",
                v,
                ": Optional[",
                t,
                "] = None\n    if ",
                a,
                (
                    ":\n        # SAFETY: the C caller passes NULL or a valid"
                    " pointer, unused by anything\n        # else during the"
                    " call.\n        "
                ),
                v,
                " = Optional(",
                a,
                ".value()[])\n",
            )
            after += String(
                "    if ",
                a,
                " and ",
                v,
                ":\n        ",
                a,
                ".value()[] = ",
                v,
                ".value()\n",
            )
            call_args.append(v)
        else:
            var base = String("_addr(a_", f.params[k.index].name, ")")
            before += String(
                "    var ",
                v,
                ": Optional[Int] = None\n    if ",
                a,
                (
                    ":\n        # SAFETY: the C caller passes NULL or a valid"
                    " pointer to a pointer.\n        var at = "
                ),
                a,
                ".value()[]\n        if at != 0:\n            ",
                v,
                " = Optional(at - ",
                base,
                ")\n",
            )
            after += String(
                "    if ",
                a,
                ":\n        ",
                a,
                ".value()[] = ",
                base,
                " + ",
                v,
                ".value() if ",
                v,
                " else 0\n",
            )
            call_args.append(v)
    var ret = mojo_ret(f, signed)
    var into = returns_into(f)
    var abi_ret = String("")
    if into:
        abi_ret = " -> Int"
    elif ret:
        abi_ret = String(" -> ", ret.value())
    var call = String("port.", f.name, "(", join(call_args, ", "), ")")
    var fallible = False
    for g in api.functions:
        if g.rust_name == f.name:
            fallible = g.fallible
            break
    var shown = f.name
    if f.prototype:
        shown = f.prototype.value()
    var text = String(
        "\n\n# `",
        shown,
        "` (`",
        f.file,
        ":",
        f.line,
        "`).\n@export\ndef ",
        prefix,
        f.name,
        "(",
        join(params, ", "),
        ') abi("C")',
        abi_ret,
        ":\n",
        before,
    )
    var result = Bool(ret)
    if fallible:
        if ret:
            text += String("    var result: ", ret.value(), "\n")
        var assign = String("")
        if result:
            assign = "result = "
        text += String(
            "    try:\n        ",
            assign,
            call,
            '\n    except e:\n        abort(String("',
            f.name,
            ' raised: ", e))\n',
        )
    elif result:
        text += String("    var result = ", call, "\n")
    else:
        text += String("    ", call, "\n")
    text += after
    if into:
        text += String(
            "    return _addr(a_",
            f.params[into.value()].name,
            ") + result.value() if result else 0\n",
        )
    elif result:
        text += "    return result\n"
    return text


# ---- codegen_c: the header ------------------------------------------------


def c_struct_defs(m: Manifest) -> String:
    """C definitions of the unit's structs."""
    var out = String("")
    for s in structs(m):
        var fields = String("")
        for i in range(len(s.types)):
            fields += String(" ", s.types[i], " ", s.names[i], ";")
        if s.c_name.startswith("struct "):
            out += String(s.c_name, " {", fields, " };\n")
        else:
            out += String("typedef struct {", fields, " } ", s.c_name, ";\n")
    return out


def c_decl(c_type: String, name: String) -> String:
    var stars = 0
    for b in c_type.as_bytes():
        if b == 42:
            stars += 1
    var base = _trim_stars(c_type)
    var ptr = String("")
    for _ in range(stars):
        ptr += "*"
    return String(base, " ", ptr, name)


def c_prototype(f: ExportedFn, name: String) -> String:
    var params = List[String]()
    for p in f.params:
        params.append(c_decl(_native(p), p.name))
    var joined = String("void")
    if len(params) > 0:
        joined = join(params, ", ")
    var ret = String("void")
    if f.native_return:
        ret = f.native_return.value()
    return c_decl(ret, String(name, "(", joined, ")"))


def header(m: Manifest) -> String:
    """`include/<lib>.h`: the prototypes, and the `mojo_anything_`
    aliases."""
    var guard = String("")
    for b in m.lib_name().as_bytes():
        if b >= 97 and b <= 122:
            guard += chr(Int(b) - 32)
        else:
            guard += chr(Int(b))
    guard += "_H"
    var out = String(
        "/* C API of the Mojo port of `",
        m.unit,
        "`, generated by mojo-anything. */\n#ifndef ",
        guard,
        "\n#define ",
        guard,
        (
            "\n\n#include <stdbool.h>\n#include <stddef.h>\n#include"
            " <stdint.h>\n#include <sys/types.h>\n\n"
        ),
    )
    var defs = c_struct_defs(m)
    if defs.byte_length() > 0:
        out += defs + "\n"
    for f in m.exports:
        out += c_prototype(f, f.name) + ";\n"
    out += (
        "\n/* The same functions under `mojo_anything_` names, for shadow"
        " runs. */\n"
    )
    for f in m.exports:
        out += c_prototype(f, String("mojo_anything_", f.name)) + ";\n"
    out += String("\n#endif /* ", guard, " */\n")
    return out


# ---- bridge.rs `c_bindings` -----------------------------------------------


def _digits_after(t: String, prefix: String) -> Bool:
    """Whether `t` is `prefix` followed by the digits the reader writes."""
    return Bool(_index(String(t[byte = prefix.byte_length() :])))


def c_manifest_reads_alike(m: Manifest) -> Bool:
    """Whether the C generators read a loaded manifest as the Rust ones do:
    every `len:`, `outptr:` and `ptr:` index is plain digits (`usize`'s
    parser also takes a leading `+`), and the parameter an `outptr:` or a
    `ptr:` names exists (Rust indexes `params` with it and panics past the
    end)."""
    for f in m.exports:
        for p in f.params:
            var t = p.ts_type
            if t.startswith("len:") and not _digits_after(t, "len:"):
                return False
            if t.startswith("outptr:"):
                var i = _index(String(t[byte=7:]))
                if not i or i.value() >= len(f.params):
                    return False
        if f.returns.startswith("ptr:"):
            var i = returns_into(f)
            if not i or i.value() >= len(f.params):
                return False
    return True


def c_bindings(
    m: Manifest,
    api: PortApi,
    signed: Bool,
    mut paths: List[String],
    mut texts: List[String],
) raises:
    """The generated C-side files: the exports under the C names and under
    the shadow names, the header, and the structs."""
    paths.append(EXPORTS)
    texts.append(exports_mojo(m, api, "", signed))
    paths.append(EXPORTS_SHADOW)
    texts.append(exports_mojo(m, api, SHADOW_PREFIX, signed))
    paths.append(String("include/", m.lib_name(), ".h"))
    texts.append(header(m))
    var defs = c_struct_defs_mojo(m, signed)
    if defs.byte_length() > 0:
        paths.append(String(C_STRUCTS, ".mojo"))
        texts.append(defs)
