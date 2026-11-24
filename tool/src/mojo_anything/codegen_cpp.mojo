# The C++-aware layers of a C++ unit (`kind: c-abi`, `language: cpp`), port
# of src/codegen_cpp.rs and the parts of src/lang/cpp.rs it reads (`crossing`,
# `symbol`, `port_name`, `namespace`): one C symbol per function
# (`cpp__<namespace>__<name>`), strings and vectors as a pointer and a length,
# a `std::string` or `std::vector` result in `malloc`ed memory, and a final
# `char **` error slot. `cpp/shim.cpp` records the original through those
# symbols, `cpp/wrapper.cpp` gives C++ callers the original signatures over
# the port's, and `exports.mojo` exports them from the Mojo port.

from mojo_anything.codegen_mojo import (
    ExportedFn,
    Manifest,
    Param,
    PortApi,
    STUB_MARK,
    join,
    mojo_escape,
    trim,
)
from mojo_anything.codegen_mojo_c import EXPORTS, c_bare, mojo_scalar

comptime SHIM = "cpp/shim.cpp"
comptime WRAPPER = "cpp/wrapper.cpp"
comptime _LEN = "mojo_anything_len"
comptime _ERROR = "mojo_anything_error"

comptime SCALAR = 0
comptime STR = 1
comptime VEC = 2


@fieldwise_init
struct Crossing(Copyable, Movable):
    """cpp.rs `Crossing`: what crosses (a scalar, `std::string`, a
    `std::vector` of a scalar), its scalar, and whether it is `const&`."""

    var tag: Int
    var scalar: String
    var by_ref: Bool

    def spelled(self) -> String:
        var base: String
        if self.tag == SCALAR:
            base = self.scalar
        elif self.tag == STR:
            base = "std::string"
        else:
            base = String("std::vector<", self.scalar, ">")
        if self.by_ref:
            return String("const ", base, " &")
        return base


def _known(c: String, signed: Bool) -> Bool:
    """Whether c.rs `scalar` knows a type (`void` included)."""
    if mojo_scalar(c, signed):
        return True
    return c_bare(c) == "void"


def crossing(native: String, signed: Bool) -> Optional[Crossing]:
    """Reads back what `Crossing::spelled` wrote (a manifest's
    `native_type`)."""
    var t = trim(native)
    var by_ref = False
    var base = t
    if t.startswith("const ") and t.endswith("&"):
        by_ref = True
        base = trim(String(t[byte = 6 : t.byte_length() - 1]))
    if base == "std::string":
        return Crossing(STR, "", by_ref)
    if base.startswith("std::vector<") and base.endswith(">"):
        return Crossing(
            VEC,
            trim(String(base[byte = 12 : base.byte_length() - 1])),
            by_ref,
        )
    if _known(base, signed):
        return Crossing(SCALAR, base, by_ref)
    return None


def symbol(qualified: String) -> String:
    return "cpp__" + qualified.replace("::", "__")


def port_name(qualified: String) -> String:
    var at = qualified.rfind("::")
    if at < 0:
        return qualified
    return String(qualified[byte = at + 2 :])


def namespace(qualified: String) -> Optional[String]:
    var at = qualified.rfind("::")
    if at < 0:
        return None
    return String(qualified[byte=0:at])


def _param_crossing(f: ExportedFn, p: Param, signed: Bool) raises -> Crossing:
    var c = Optional[Crossing](None)
    if p.native_type:
        c = crossing(p.native_type.value(), signed)
    if not c:
        raise Error(
            String(
                "`",
                p.name,
                "` of `",
                f.name,
                "` has no C++ type the shim knows: bridge again",
            )
        )
    return c.value().copy()


def _result_crossing(f: ExportedFn, signed: Bool) raises -> Optional[Crossing]:
    """A function's result; `None` for `void`."""
    if not f.native_return:
        raise Error(String("`", f.name, "` has no return type: bridge again"))
    var r = f.native_return.value()
    if r == "void":
        return None
    var c = crossing(r, signed)
    if not c:
        raise Error(
            String(
                "`",
                f.name,
                "` returns `",
                r,
                "`, which the shim does not know: bridge again",
            )
        )
    return c.value().copy()


def _owned(c: Optional[Crossing]) -> Bool:
    return Bool(c) and c.value().tag != SCALAR


def _c_params(c: Crossing, name: String) -> String:
    if c.tag == SCALAR:
        return String(c.scalar, " a_", name)
    if c.tag == STR:
        return String("const char *a_", name, ", size_t a_", name, "_len")
    return String("const ", c.scalar, " *a_", name, ", size_t a_", name, "_len")


def _c_ret(c: Optional[Crossing]) -> String:
    if not c:
        return "void"
    if c.value().tag == SCALAR:
        return c.value().scalar
    if c.value().tag == STR:
        return "char *"
    return String(c.value().scalar, " *")


def _c_prototype(f: ExportedFn, signed: Bool) raises -> String:
    var ret = _result_crossing(f, signed)
    var params = List[String]()
    for p in f.params:
        params.append(_c_params(_param_crossing(f, p, signed), p.name))
    if _owned(ret):
        params.append(String("size_t *", _LEN))
    params.append(String("char **", _ERROR))
    var ret_text = _c_ret(ret)
    var sep = String(" ")
    if ret_text.endswith("*"):
        sep = ""
    return String(ret_text, sep, symbol(f.name), "(", join(params, ", "), ")")


def _cpp_declaration(f: ExportedFn, signed: Bool) raises -> String:
    var r = _result_crossing(f, signed)
    var ret = String("void")
    if r:
        ret = r.value().spelled()
    var params = List[String]()
    for p in f.params:
        var spelled = _param_crossing(f, p, signed).spelled()
        var sep = String(" ")
        if spelled.endswith("&"):
            sep = ""
        params.append(String(spelled, sep, p.name))
    return String(ret, " ", port_name(f.name), "(", join(params, ", "), ")")


def _in_namespaces(names: List[String], texts: List[String]) -> String:
    """Groups the items into `namespace a::b { ... }` blocks, in order."""
    var out = String("")
    var opened = False
    var open = Optional[String](None)
    for i in range(len(names)):
        var ns = namespace(names[i])
        var same = opened and (
            (not open and not ns)
            or (Bool(open) and Bool(ns) and open.value() == ns.value())
        )
        if not same:
            if opened and open:
                out += String("}  // namespace ", open.value(), "\n\n")
            if ns:
                out += String("namespace ", ns.value(), " {\n\n")
            open = ns
            opened = True
        out += texts[i]
        out += "\n"
    if opened and open:
        out += String("}  // namespace ", open.value(), "\n")
    return out


comptime _INCLUDES = (
    "#include <cstddef>\n#include <cstdint>\n#include <cstdlib>\n#include"
    " <cstring>\n#include <string>\n#include <vector>\n"
)

comptime _ERROR_TEXT = """// The standard exception `e` is or derives from, of those the wrapper can throw again.
const char *mojo_anything_base(const std::exception &e) noexcept
{
    if (dynamic_cast<const std::invalid_argument *>(&e))
        return "std::invalid_argument";
    if (dynamic_cast<const std::domain_error *>(&e))
        return "std::domain_error";
    if (dynamic_cast<const std::length_error *>(&e))
        return "std::length_error";
    if (dynamic_cast<const std::out_of_range *>(&e))
        return "std::out_of_range";
    if (dynamic_cast<const std::logic_error *>(&e))
        return "std::logic_error";
    if (dynamic_cast<const std::range_error *>(&e))
        return "std::range_error";
    if (dynamic_cast<const std::overflow_error *>(&e))
        return "std::overflow_error";
    if (dynamic_cast<const std::underflow_error *>(&e))
        return "std::underflow_error";
    if (dynamic_cast<const std::runtime_error *>(&e))
        return "std::runtime_error";
    if (dynamic_cast<const std::bad_alloc *>(&e))
        return "std::bad_alloc";
    return "std::exception";
}

// What the error slot receives: `<type>: <what()>` for a standard type the wrapper throws
// again, `<type> (<base>): <what()>` for any other type, which C++ callers of the wrapper get
// as `<base>`, or `unknown exception` for what is not a `std::exception`.
char *mojo_anything_error_text() noexcept
{
    std::string text = "unknown exception";
    try {
        throw;
    } catch (const std::exception &e) {
        int status = 0;
        char *name = abi::__cxa_demangle(typeid(e).name(), nullptr, nullptr, &status);
        std::string type = status == 0 && name ? name : typeid(e).name();
        std::free(name);
        std::string base = mojo_anything_base(e);
        text = (type == base ? type : type + " (" + base + ")") + ": " + e.what();
    } catch (...) {
    }
    char *out = static_cast<char *>(std::malloc(text.size() + 1));
    if (out)
        std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}
"""

comptime _OWNED_STR = """// A result string in memory the caller frees with `free`.
char *mojo_anything_owned(const std::string &s, size_t *len)
{
    *len = s.size();
    char *out = static_cast<char *>(std::malloc(s.empty() ? 1 : s.size()));
    if (out && !s.empty())
        std::memcpy(out, s.data(), s.size());
    return out;
}
"""

comptime _OWNED_VEC = """// A result vector in memory the caller frees with `free`.
template <typename T>
T *mojo_anything_owned(const std::vector<T> &v, size_t *len)
{
    *len = v.size();
    T *out = static_cast<T *>(std::malloc(v.empty() ? 1 : v.size() * sizeof(T)));
    if (out && !v.empty())
        std::memcpy(out, v.data(), v.size() * sizeof(T));
    return out;
}
"""


def shim_cpp(m: Manifest, signed: Bool) raises -> String:
    """`cpp/shim.cpp`: one `extern "C"` symbol per function, calling the
    original."""
    var names = List[String]()
    var decls = List[String]()
    var bodies = String("")
    var any_str = False
    var any_vec = False
    for f in m.exports:
        names.append(f.name)
        decls.append(_cpp_declaration(f, signed) + ";")
        var ret = _result_crossing(f, signed)
        if ret and ret.value().tag == STR:
            any_str = True
        elif ret and ret.value().tag == VEC:
            any_vec = True
        var args = List[String]()
        for p in f.params:
            var n = p.name
            var c = _param_crossing(f, p, signed)
            if c.tag == SCALAR:
                args.append("a_" + n)
            elif c.tag == STR:
                args.append(
                    String(
                        "a_",
                        n,
                        " ? std::string(a_",
                        n,
                        ", a_",
                        n,
                        "_len) : std::string()",
                    )
                )
            else:
                args.append(
                    String(
                        "std::vector<",
                        c.scalar,
                        ">(a_",
                        n,
                        ", a_",
                        n,
                        " + a_",
                        n,
                        "_len)",
                    )
                )
        var call = String(f.name, "(", join(args, ", "), ")")
        var body: String
        var failed: String
        if not ret:
            body = call + ";"
            failed = "return;"
        elif ret.value().tag == SCALAR:
            body = String("return ", call, ";")
            failed = "return {};"
        else:
            body = String("return mojo_anything_owned(", call, ", ", _LEN, ");")
            failed = String("*", _LEN, " = 0;\n        return nullptr;")
        var shown = f.name
        if f.prototype:
            shown = f.prototype.value()
        bodies += String(
            "\n// `",
            shown,
            "` (`",
            f.file,
            ":",
            f.line,
            '`).\nextern "C" ',
            _c_prototype(f, signed),
            "\n{\n    try {\n        ",
            body,
            "\n    } catch (...) {\n        *",
            _ERROR,
            " = mojo_anything_error_text();\n        ",
            failed,
            "\n    }\n}\n",
        )
    var out = String(
        "// The C ABI `",
        m.unit,
        (
            "` is recorded through, generated by mojo-anything from"
            " mojo-anything.json.\n// Regenerate with `mojo-anything refresh`."
            " Each function converts its C arguments, calls\n// the original"
            " and catches every exception into the error slot.\n\n"
        ),
        _INCLUDES,
        (
            "#include <exception>\n#include <new>\n#include"
            " <stdexcept>\n#include <typeinfo>\n\n#include <cxxabi.h>\n\n// The"
            " original functions, as `"
        ),
        m.unit,
        "` defines them.\n",
        _in_namespaces(names, decls),
        "\nnamespace {\n\n",
        _ERROR_TEXT,
    )
    if any_str:
        out += "\n" + _OWNED_STR
    if any_vec:
        out += "\n" + _OWNED_VEC
    out += "\n}  // namespace\n"
    out += bodies
    return out


comptime _THROW = """// A `std::exception` with the original's `what()`, for a type derived from it alone.
struct mojo_anything_exception : std::exception {
    explicit mojo_anything_exception(std::string what) : text(std::move(what)) {}
    const char *what() const noexcept override
    {
        return text.c_str();
    }
    std::string text;
};

// Throws what the port raised: the standard exception named before `: ` (for
// `<type> (<base>): `, the base), with the text after it as `what()`; else
// `std::runtime_error` with the whole text.
[[noreturn]] void mojo_anything_throw(char *error)
{
    std::string text(error);
    std::free(error);
    std::string::size_type colon = text.find(": ");
    std::string type = colon == std::string::npos ? std::string() : text.substr(0, colon);
    std::string what = colon == std::string::npos ? text : text.substr(colon + 2);
    std::string::size_type open = type.rfind(" (");
    if (open != std::string::npos && type.back() == ')')
        type = type.substr(open + 2, type.size() - open - 3);
    if (type == "std::invalid_argument")
        throw std::invalid_argument(what);
    if (type == "std::domain_error")
        throw std::domain_error(what);
    if (type == "std::length_error")
        throw std::length_error(what);
    if (type == "std::out_of_range")
        throw std::out_of_range(what);
    if (type == "std::logic_error")
        throw std::logic_error(what);
    if (type == "std::range_error")
        throw std::range_error(what);
    if (type == "std::overflow_error")
        throw std::overflow_error(what);
    if (type == "std::underflow_error")
        throw std::underflow_error(what);
    if (type == "std::runtime_error")
        throw std::runtime_error(what);
    if (type == "std::bad_alloc")
        throw std::bad_alloc();
    if (type == "std::exception")
        throw mojo_anything_exception(what);
    throw std::runtime_error(text);
}
"""

comptime _TAKE_STR = """// A result string the port `malloc`ed.
std::string mojo_anything_take(char *p, size_t n)
{
    std::string s = p ? std::string(p, n) : std::string();
    std::free(p);
    return s;
}
"""

comptime _TAKE_VEC = """// A result vector the port `malloc`ed.
template <typename T>
std::vector<T> mojo_anything_take(T *p, size_t n)
{
    std::vector<T> v = p ? std::vector<T>(p, p + n) : std::vector<T>();
    std::free(p);
    return v;
}
"""


def wrapper_cpp(m: Manifest, signed: Bool) raises -> String:
    """`cpp/wrapper.cpp`: the original functions with their original
    signatures, forwarding to the Mojo port's C symbols."""
    var externs = String("")
    var names = List[String]()
    var defs = List[String]()
    var any_str = False
    var any_vec = False
    for f in m.exports:
        externs += _c_prototype(f, signed) + ";\n"
        var ret = _result_crossing(f, signed)
        if ret and ret.value().tag == STR:
            any_str = True
        elif ret and ret.value().tag == VEC:
            any_vec = True
        var args = List[String]()
        for p in f.params:
            var n = p.name
            if _param_crossing(f, p, signed).tag == SCALAR:
                args.append(n)
            else:
                args.append(String(n, ".data(), ", n, ".size()"))
        if _owned(ret):
            args.append("&" + _LEN)
        args.append("&" + _ERROR)
        var call = String(symbol(f.name), "(", join(args, ", "), ")")
        var body = String("    char *", _ERROR, " = nullptr;\n")
        if not ret:
            body += String(
                "    ",
                call,
                ";\n    if (",
                _ERROR,
                ")\n        mojo_anything_throw(",
                _ERROR,
                ");\n",
            )
        elif ret.value().tag == SCALAR:
            body += String(
                "    ",
                ret.value().spelled(),
                " mojo_anything_result = ",
                call,
                ";\n    if (",
                _ERROR,
                ")\n        mojo_anything_throw(",
                _ERROR,
                ");\n    return mojo_anything_result;\n",
            )
        else:
            body += String(
                "    size_t ",
                _LEN,
                " = 0;\n    auto mojo_anything_result = ",
                call,
                ";\n    if (",
                _ERROR,
                (
                    ") {\n        std::free(mojo_anything_result);\n       "
                    " mojo_anything_throw("
                ),
                _ERROR,
                (
                    ");\n    }\n    return"
                    " mojo_anything_take(mojo_anything_result, "
                ),
                _LEN,
                ");\n",
            )
        var shown = f.name
        if f.prototype:
            shown = f.prototype.value()
        names.append(f.name)
        defs.append(
            String(
                "// `",
                shown,
                "` (`",
                f.file,
                ":",
                f.line,
                "`).\n",
                _cpp_declaration(f, signed),
                "\n{\n",
                body,
                "}\n",
            )
        )
    var out = String(
        "// `",
        m.unit,
        (
            "`'s functions with their original C++ signatures, over the C"
            " symbols the Mojo port\n// exports. Generated by mojo-anything"
            " from mojo-anything.json; regenerate with\n// `mojo-anything"
            " refresh`. Compile and link this file and lib"
        ),
        m.lib_name(),
        ".so in place of `",
        m.unit,
        (
            "`;\n// it defines only the bridged functions, so keep that file's"
            " other definitions in a\n// file of their own.\n\n"
        ),
        _INCLUDES,
        (
            "#include <exception>\n#include <new>\n#include"
            ' <stdexcept>\n#include <utility>\n\nextern "C" {\n'
        ),
        externs,
        "}\n\nnamespace {\n\n",
        _THROW,
    )
    if any_str:
        out += "\n" + _TAKE_STR
    if any_vec:
        out += "\n" + _TAKE_VEC
    out += "\n}  // namespace\n\n"
    out += _in_namespaces(names, defs)
    return out


# ---- Mojo -----------------------------------------------------------------


def _mojo_of(c: Crossing, signed: Bool) raises -> String:
    if c.tag == STR:
        return "String"
    var t = mojo_scalar(c.scalar, signed)
    if not t:
        raise Error(String("`", c.scalar, "` has no Mojo type"))
    if c.tag == SCALAR:
        return t.value()
    return String("List[", t.value(), "]")


def port_mojo_cpp(m: Manifest, signed: Bool) raises -> String:
    """`port.mojo` for a C++ unit: one stub per function, named without its
    namespaces."""
    var body = String("")
    for f in m.exports:
        var params = List[String]()
        for p in f.params:
            params.append(
                String(
                    mojo_escape(p.name),
                    ": ",
                    _mojo_of(_param_crossing(f, p, signed), signed),
                )
            )
        var ret = String("")
        var r = _result_crossing(f, signed)
        if r:
            ret = " -> " + _mojo_of(r.value(), signed)
        var shown = f.name
        if f.prototype:
            shown = f.prototype.value()
        body += String(
            "\n\n# Port of `",
            f.name,
            "` (`",
            f.file,
            ":",
            f.line,
            "`).\n# C++: `",
            shown,
            "`\ndef ",
            mojo_escape(port_name(f.name)),
            "(",
            join(params, ", "),
            ")",
            ret,
            ':\n    abort("',
            STUB_MARK,
            f.name,
            '")\n',
        )
    return String(
        "# The Mojo port of `",
        m.unit,
        (
            "`.\n#\n# `exports.mojo` exports each function under the C name the"
            " C++ shim gives it\n# (`cpp__<namespace>__<name>`), and"
            " `cpp/wrapper.cpp` gives C++ callers the original\n# signatures."
            " Replace each stub's `abort` with the port of the C++ function."
            " Where the\n# original throws, add `raises` and raise"
            ' `Error("<type>: <what()>")` with the text the\n# recording has'
            " (`std::domain_error: negative input`, or `my::bad"
            " (std::runtime_error):\n# ...` for a type derived from a standard"
            " one); C++ callers get that standard exception\n# (for a derived"
            " type, its base) with the same `what()`. Integers wrap as C++'s"
            " do only where\n# the port says so, so use the same widths as the"
            " C++ code. `build` turns off\n# floating-point contraction"
            " (`--fp-mode contract=off`) and `record` compiles the\n# original"
            " with `-ffp-contract=off`, so `a * b + c` rounds twice on both"
            " sides.\n\nfrom std.os import abort\n"
        ),
        body,
    )


def _helper_tag(e: String, signed: Bool) -> String:
    """The Mojo name of a scalar, lowercased for helper names
    (`float64`)."""
    var out = String("")
    for b in mojo_scalar(e, signed).or_else("Int32").as_bytes():
        if b >= 65 and b <= 90:
            out += chr(Int(b) + 32)
        else:
            out += chr(Int(b))
    return out


def _scalar_size(e: String, signed: Bool) -> Int:
    """The size of a C scalar in bytes (c.rs `scalar`'s Rust type; an unknown
    type counts as `i32`, `void` as 8)."""
    var t = mojo_scalar(e, signed)
    if not t:
        if _known(e, signed):
            return 8
        return 4
    var v = t.value()
    if v == "Int8" or v == "UInt8" or v == "Bool":
        return 1
    if v == "Int16" or v == "UInt16":
        return 2
    if v == "Int32" or v == "UInt32" or v == "Float32":
        return 4
    return 8


comptime _MOJO_STR = """
def _str(
    p: Optional[Pointer[UInt8, ImmutAnyOrigin]], n: UInt, what: String
) raises -> String:
    if not p or n == 0:
        return String()
    # SAFETY: a caller of the C symbol (the wrapper, the driver, any C code) passes NULL or
    # `n` readable bytes, valid for the call; `from_utf8` checks them.
    var bytes = Span[UInt8, ImmutAnyOrigin](unsafe_ptr=p.value(), length=Int(n))
    try:
        return String(from_utf8=bytes)
    except:
        # A Mojo `String` holds UTF-8 only; the original took any bytes.
        raise Error("std::invalid_argument: " + what + " is not valid UTF-8")
"""

comptime _MOJO_OWNED_STR = """
def _owned_str(s: String, len_out: Optional[Pointer[UInt, MutAnyOrigin]]) -> Int:
    var n = s.byte_length()
    # SAFETY: `malloc`ed for the caller, which frees it with `free`; one byte at least, so an
    # empty string is not NULL.
    var p = external_call["malloc", Optional[Pointer[UInt8, MutAnyOrigin]]](
        max(n, 1)
    )
    if not p:
        abort("out of memory")
    var dst = p.value()
    var src = s.as_bytes()
    for i in range(n):
        # SAFETY: `dst` holds `n` bytes.
        dst[unsafe_offset=i] = src[i]
    if len_out:
        # SAFETY: the shim passes a valid `size_t *`.
        len_out.value()[] = UInt(n)
    return Int(dst)
"""

comptime _MOJO_SET_ERROR = """
def _set_error(slot: Optional[Pointer[Int, MutAnyOrigin]], text: String):
    if not slot:
        return
    var n = text.byte_length()
    # SAFETY: `malloc`ed for the caller, which frees it with `free`.
    var p = external_call["malloc", Optional[Pointer[UInt8, MutAnyOrigin]]](
        n + 1
    )
    if not p:
        abort("out of memory")
    var dst = p.value()
    var src = text.as_bytes()
    for i in range(n):
        # SAFETY: `dst` holds `n + 1` bytes.
        dst[unsafe_offset=i] = src[i]
    # SAFETY: as above; the text ends with a NUL.
    dst[unsafe_offset=n] = 0
    # SAFETY: the shim passes a valid `char **`.
    slot.value()[] = Int(dst)
"""


def _mojo_list(e: String, signed: Bool) -> String:
    var t = mojo_scalar(e, signed).or_else("Int32")
    return String(
        "\ndef _list_",
        _helper_tag(e, signed),
        "(p: Optional[Pointer[",
        t,
        ", ImmutAnyOrigin]], n: UInt) -> List[",
        t,
        "]:\n    var out = List[",
        t,
        (
            "](capacity=Int(n))\n    if not p:\n        return out^\n    var"
            " ptr = p.value()\n    for i in range(Int(n)):\n        # SAFETY:"
            " the shim passes NULL or `n` readable elements of a"
            " `std::vector`.\n        out.append(ptr[unsafe_offset=i])\n   "
            " return out^\n"
        ),
    )


def _mojo_owned_list(e: String, signed: Bool) -> String:
    var t = mojo_scalar(e, signed).or_else("Int32")
    return String(
        "\ndef _owned_list_",
        _helper_tag(e, signed),
        "(\n    v: List[",
        t,
        (
            "], len_out: Optional[Pointer[UInt, MutAnyOrigin]]\n) -> Int:\n   "
            " var n = len(v)\n    # SAFETY: `malloc`ed for the caller, which"
            " frees it with `free`; one element at least,\n    # so an empty"
            ' vector is not NULL.\n    var p = external_call["malloc",'
            " Optional[Pointer["
        ),
        t,
        ", MutAnyOrigin]]](\n        max(n, 1) * ",
        _scalar_size(e, signed),
        (
            '\n    )\n    if not p:\n        abort("out of memory")\n    var'
            " dst = p.value()\n    for i in range(n):\n        # SAFETY: `dst`"
            " holds `n` elements.\n        dst[unsafe_offset=i] = v[i]\n    if"
            " len_out:\n        # SAFETY: the shim passes a valid `size_t *`.\n"
            "        len_out.value()[] = UInt(n)\n    return Int(dst)\n"
        ),
    )


def _has_tag(list: List[String], e: String, signed: Bool) -> Bool:
    for l in list:
        if _helper_tag(l, signed) == _helper_tag(e, signed):
            return True
    return False


def exports_mojo_cpp(m: Manifest, api: PortApi, signed: Bool) raises -> String:
    """`exports.mojo` for a C++ unit: each function under its C symbol."""
    var any_str = False
    var any_owned_str = False
    var any_error = False
    var lists = List[String]()
    var owned_lists = List[String]()
    var body = String("")
    for f in m.exports:
        var ret = _result_crossing(f, signed)
        var params = List[String]()
        var args = List[String]()
        var takes_str = False
        for p in f.params:
            var c = _param_crossing(f, p, signed)
            var a = "a_" + p.name
            if c.tag == SCALAR:
                params.append(String(a, ": ", _mojo_of(c, signed)))
                args.append(a)
            elif c.tag == STR:
                any_str = True
                takes_str = True
                params.append(a + ": Optional[Pointer[UInt8, ImmutAnyOrigin]]")
                params.append(a + "_len: UInt")
                args.append(
                    String(
                        "_str(",
                        a,
                        ", ",
                        a,
                        '_len, "`',
                        p.name,
                        "` of `",
                        f.name,
                        '`")',
                    )
                )
            else:
                # Helpers are named by their Mojo type, which several C
                # spellings share (`long` and `int64_t`): one per name.
                if not _has_tag(lists, c.scalar, signed):
                    lists.append(c.scalar)
                var t = mojo_scalar(c.scalar, signed).or_else("Int32")
                params.append(
                    String(a, ": Optional[Pointer[", t, ", ImmutAnyOrigin]]")
                )
                params.append(a + "_len: UInt")
                args.append(
                    String(
                        "_list_",
                        _helper_tag(c.scalar, signed),
                        "(",
                        a,
                        ", ",
                        a,
                        "_len)",
                    )
                )
        if _owned(ret):
            params.append(
                String("a_", _LEN, ": Optional[Pointer[UInt, MutAnyOrigin]]")
            )
        params.append(
            String("a_", _ERROR, ": Optional[Pointer[Int, MutAnyOrigin]]")
        )
        var call = String(
            "port.", mojo_escape(port_name(f.name)), "(", join(args, ", "), ")"
        )
        var abi_ret = String("")
        var value = call
        var zero = Optional[String](None)
        if ret and ret.value().tag == SCALAR:
            var t = mojo_scalar(ret.value().scalar, signed).or_else("Int32")
            abi_ret = " -> " + t
            if t == "Bool":
                zero = String("False")
            else:
                zero = String("0")
        elif ret and ret.value().tag == STR:
            any_owned_str = True
            abi_ret = " -> Int"
            value = String("_owned_str(", call, ", a_", _LEN, ")")
            zero = String("0")
        elif ret:
            var e = ret.value().scalar
            if not _has_tag(owned_lists, e, signed):
                owned_lists.append(e)
            abi_ret = " -> Int"
            value = String(
                "_owned_list_",
                _helper_tag(e, signed),
                "(",
                call,
                ", a_",
                _LEN,
                ")",
            )
            zero = String("0")
        var fallible = False
        var pname = mojo_escape(port_name(f.name))
        for g in api.functions:
            if g.rust_name == pname:
                fallible = g.fallible
                break
        var lines: String
        if fallible or takes_str:
            any_error = True
            var ok = value
            var err = String("")
            if zero:
                ok = "return " + value
                err = "\n        return " + zero.value()
            lines = String(
                "    try:\n        ",
                ok,
                "\n    except e:\n        _set_error(a_",
                _ERROR,
                ", String(e))",
                err,
                "\n",
            )
        elif ret:
            lines = String("    return ", value, "\n")
        else:
            lines = String("    ", value, "\n")
        var shown = f.name
        if f.prototype:
            shown = f.prototype.value()
        body += String(
            "\n\n# `",
            shown,
            "` (`",
            f.file,
            ":",
            f.line,
            "`).\n@export\ndef ",
            symbol(f.name),
            "(\n    ",
            join(params, ",\n    "),
            ',\n) abi("C")',
            abi_ret,
            ":\n",
            lines,
        )
    var out = String(
        "# C exports for the Mojo port of `",
        m.unit,
        (
            "`, generated by mojo-anything from\n# `mojo-anything.json`."
            " Regenerate with `mojo-anything refresh`. These are the C\n#"
            " symbols of `cpp/shim.cpp`: strings and vectors as a pointer and a"
            " length, string and\n# vector results in `malloc`ed memory with"
            " their length in `len_out`, and an error\n# slot a raising port"
            " writes its error to.\n\n"
        ),
    )
    if any_owned_str or len(owned_lists) > 0 or any_error:
        out += "from std.ffi import external_call\n"
    out += (
        "from std.memory import Pointer\nfrom std.os import abort\n\nimport"
        " port\n"
    )
    if any_str:
        out += _MOJO_STR
    for e in lists:
        out += _mojo_list(e, signed)
    if any_owned_str:
        out += _MOJO_OWNED_STR
    for e in owned_lists:
        out += _mojo_owned_list(e, signed)
    if any_error:
        out += _MOJO_SET_ERROR
    out += body
    return out


def cpp_bindings(
    m: Manifest,
    api: PortApi,
    signed: Bool,
    mut paths: List[String],
    mut texts: List[String],
) raises:
    """Every generated file of a C++ unit but `port.mojo`; each is generated
    before any is added."""
    var exports = exports_mojo_cpp(m, api, signed)
    var shim = shim_cpp(m, signed)
    var wrapper = wrapper_cpp(m, signed)
    paths.append(EXPORTS)
    texts.append(exports)
    paths.append(SHIM)
    texts.append(shim)
    paths.append(WRAPPER)
    texts.append(wrapper)
