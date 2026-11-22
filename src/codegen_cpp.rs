//! The C++-aware layers of a C++ unit (`kind: c-abi`, `language: cpp`). Everything else treats
//! the unit as C: one C symbol per function (`cpp__<namespace>__<name>`), strings and vectors as
//! a pointer and a length, a `std::string` or `std::vector` result in memory the callee
//! `malloc`s (its length through a `size_t *`), and a final `char **` error slot.
//!
//! - `cpp/shim.cpp`: the C symbols over the original functions, for recording. Every call is
//!   wrapped in `try`: an exception becomes `<type>: <what()>` in the error slot.
//! - `cpp/wrapper.cpp`: the original functions with their original signatures over the Mojo
//!   port's C symbols, rethrowing an error as the same standard exception type.
//! - `port.mojo` stubs over Mojo types, and `exports.mojo`, which exports the C symbols.

use std::fmt::Write as _;

use crate::bridge::Manifest;
use crate::codegen_mojo::{STUB_MARK, mojo_escape};
use crate::codegen_mojo_c::mojo_scalar;
use crate::lang::cpp::{CppType, Crossing, crossing, namespace, port_name, symbol};
use crate::ts::exports::{ExportedFn, Param};

/// The shim the original is recorded through, and the wrapper C++ callers link against.
pub const SHIM: &str = "cpp/shim.cpp";
pub const WRAPPER: &str = "cpp/wrapper.cpp";

/// The names of the hidden parameters every symbol may take.
const LEN: &str = "mojo_anything_len";
const ERROR: &str = "mojo_anything_error";

fn param_crossing(f: &ExportedFn, p: &Param) -> Result<Crossing, String> {
    p.native_type.as_deref().and_then(crossing).ok_or_else(|| {
        format!(
            "`{}` of `{}` has no C++ type the shim knows: bridge again",
            p.name, f.name
        )
    })
}

/// A function's result; `None` for `void`.
fn result_crossing(f: &ExportedFn) -> Result<Option<Crossing>, String> {
    match f.native_return.as_deref() {
        Some("void") => Ok(None),
        Some(r) => crossing(r).map(Some).ok_or_else(|| {
            format!(
                "`{}` returns `{r}`, which the shim does not know: bridge again",
                f.name
            )
        }),
        None => Err(format!("`{}` has no return type: bridge again", f.name)),
    }
}

fn owned(c: &Option<Crossing>) -> bool {
    matches!(
        c,
        Some(Crossing {
            ty: CppType::Str | CppType::Vec(_),
            ..
        })
    )
}

/// The C parameters a C++ parameter crosses as (`const char *a_s, size_t a_s_len`).
fn c_params(c: &Crossing, name: &str) -> String {
    match &c.ty {
        CppType::Scalar(s) => format!("{s} a_{name}"),
        CppType::Str => format!("const char *a_{name}, size_t a_{name}_len"),
        CppType::Vec(e) => format!("const {e} *a_{name}, size_t a_{name}_len"),
    }
}

/// The C return type of a symbol.
fn c_ret(c: &Option<Crossing>) -> String {
    match c.as_ref().map(|c| &c.ty) {
        None => "void".into(),
        Some(CppType::Scalar(s)) => s.clone(),
        Some(CppType::Str) => "char *".into(),
        Some(CppType::Vec(e)) => format!("{e} *"),
    }
}

/// The symbol's C prototype, as both the shim and the wrapper declare it.
fn c_prototype(f: &ExportedFn) -> Result<String, String> {
    let ret = result_crossing(f)?;
    let mut params = Vec::new();
    for p in &f.params {
        params.push(c_params(&param_crossing(f, p)?, &p.name));
    }
    if owned(&ret) {
        params.push(format!("size_t *{LEN}"));
    }
    params.push(format!("char **{ERROR}"));
    let ret_text = c_ret(&ret);
    let sep = if ret_text.ends_with('*') { "" } else { " " };
    Ok(format!(
        "{ret_text}{sep}{}({})",
        symbol(&f.name),
        params.join(", ")
    ))
}

/// `int add(int a, int b)`: the original declaration, without its namespaces.
fn cpp_declaration(f: &ExportedFn) -> Result<String, String> {
    let ret = result_crossing(f)?.map_or_else(|| "void".to_string(), |c| c.spelled());
    let mut params = Vec::new();
    for p in &f.params {
        let spelled = param_crossing(f, p)?.spelled();
        let sep = if spelled.ends_with('&') { "" } else { " " };
        params.push(format!("{spelled}{sep}{}", p.name));
    }
    Ok(format!(
        "{ret} {}({})",
        port_name(&f.name),
        params.join(", ")
    ))
}

/// Groups `items` (function name, text) into `namespace a::b { ... }` blocks, in order.
fn in_namespaces(items: &[(String, String)]) -> String {
    let mut out = String::new();
    let mut open: Option<Option<&str>> = None;
    for (name, text) in items {
        let ns = namespace(name);
        if open != Some(ns) {
            if let Some(Some(prev)) = open {
                let _ = writeln!(out, "}}  // namespace {prev}\n");
            }
            if let Some(ns) = ns {
                let _ = writeln!(out, "namespace {ns} {{\n");
            }
            open = Some(ns);
        }
        out.push_str(text);
        out.push('\n');
    }
    if let Some(Some(prev)) = open {
        let _ = writeln!(out, "}}  // namespace {prev}");
    }
    out
}

const INCLUDES: &str = "#include <cstddef>\n#include <cstdint>\n#include <cstdlib>\n#include <cstring>\n\
                        #include <string>\n#include <vector>\n";

const ERROR_TEXT: &str = r#"// What the error slot receives: `<type>: <what()>`, or `unknown exception`.
char *mojo_anything_error_text() noexcept
{
    std::string text = "unknown exception";
    try {
        throw;
    } catch (const std::exception &e) {
        int status = 0;
        char *name = abi::__cxa_demangle(typeid(e).name(), nullptr, nullptr, &status);
        text = std::string(status == 0 && name ? name : typeid(e).name()) + ": " + e.what();
        std::free(name);
    } catch (...) {
    }
    char *out = static_cast<char *>(std::malloc(text.size() + 1));
    if (out)
        std::memcpy(out, text.c_str(), text.size() + 1);
    return out;
}
"#;

const OWNED_STR: &str = r#"// A result string in memory the caller frees with `free`.
char *mojo_anything_owned(const std::string &s, size_t *len)
{
    *len = s.size();
    char *out = static_cast<char *>(std::malloc(s.empty() ? 1 : s.size()));
    if (out && !s.empty())
        std::memcpy(out, s.data(), s.size());
    return out;
}
"#;

const OWNED_VEC: &str = r#"// A result vector in memory the caller frees with `free`.
template <typename T>
T *mojo_anything_owned(const std::vector<T> &v, size_t *len)
{
    *len = v.size();
    T *out = static_cast<T *>(std::malloc(v.empty() ? 1 : v.size() * sizeof(T)));
    if (out && !v.empty())
        std::memcpy(out, v.data(), v.size() * sizeof(T));
    return out;
}
"#;

/// `cpp/shim.cpp`: one `extern "C"` symbol per function, calling the original.
pub fn shim_cpp(m: &Manifest) -> Result<String, String> {
    let mut decls = Vec::new();
    let mut bodies = String::new();
    let (mut any_str, mut any_vec) = (false, false);
    for f in &m.exports {
        decls.push((f.name.clone(), format!("{};", cpp_declaration(f)?)));
        let ret = result_crossing(f)?;
        match ret.as_ref().map(|c| &c.ty) {
            Some(CppType::Str) => any_str = true,
            Some(CppType::Vec(_)) => any_vec = true,
            _ => {}
        }
        let mut args = Vec::new();
        for p in &f.params {
            let n = &p.name;
            args.push(match param_crossing(f, p)?.ty {
                CppType::Scalar(_) => format!("a_{n}"),
                CppType::Str => format!("a_{n} ? std::string(a_{n}, a_{n}_len) : std::string()"),
                CppType::Vec(e) => format!("std::vector<{e}>(a_{n}, a_{n} + a_{n}_len)"),
            });
        }
        let call = format!("{}({})", f.name, args.join(", "));
        let (body, failed) = match &ret {
            None => (format!("{call};"), "return;".to_string()),
            Some(c) if matches!(c.ty, CppType::Scalar(_)) => {
                (format!("return {call};"), "return {};".to_string())
            }
            Some(_) => (
                format!("return mojo_anything_owned({call}, {LEN});"),
                format!("*{LEN} = 0;\n        return nullptr;"),
            ),
        };
        let _ = write!(
            bodies,
            "\n// `{}` (`{}:{}`).\nextern \"C\" {}\n{{\n    try {{\n        {body}\n    }} catch (...) {{\n        \
             *{ERROR} = mojo_anything_error_text();\n        {failed}\n    }}\n}}\n",
            f.prototype.as_deref().unwrap_or(&f.name),
            f.file,
            f.line,
            c_prototype(f)?
        );
    }
    let mut out = format!(
        "// The C ABI `{}` is recorded through, generated by mojo-anything from mojo-anything.json.\n\
         // Regenerate with `mojo-anything refresh`. Each function converts its C arguments, calls\n\
         // the original and catches every exception into the error slot.\n\n{INCLUDES}\
         #include <exception>\n#include <typeinfo>\n\n#include <cxxabi.h>\n\n\
         // The original functions, as `{}` defines them.\n{}\nnamespace {{\n\n{ERROR_TEXT}",
        m.unit,
        m.unit,
        in_namespaces(&decls)
    );
    if any_str {
        out.push('\n');
        out.push_str(OWNED_STR);
    }
    if any_vec {
        out.push('\n');
        out.push_str(OWNED_VEC);
    }
    out.push_str("\n}  // namespace\n");
    out.push_str(&bodies);
    Ok(out)
}

const THROW: &str = r#"// Throws what the port raised: the standard exception named before `: `, or
// `std::runtime_error` with the whole text.
[[noreturn]] void mojo_anything_throw(char *error)
{
    std::string text(error);
    std::free(error);
    std::string::size_type colon = text.find(": ");
    std::string type = colon == std::string::npos ? std::string() : text.substr(0, colon);
    std::string what = colon == std::string::npos ? text : text.substr(colon + 2);
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
    throw std::runtime_error(text);
}
"#;

const TAKE_STR: &str = r#"// A result string the port `malloc`ed.
std::string mojo_anything_take(char *p, size_t n)
{
    std::string s = p ? std::string(p, n) : std::string();
    std::free(p);
    return s;
}
"#;

const TAKE_VEC: &str = r#"// A result vector the port `malloc`ed.
template <typename T>
std::vector<T> mojo_anything_take(T *p, size_t n)
{
    std::vector<T> v = p ? std::vector<T>(p, p + n) : std::vector<T>();
    std::free(p);
    return v;
}
"#;

/// `cpp/wrapper.cpp`: the original functions with their original signatures, forwarding to
/// the Mojo port's C symbols.
pub fn wrapper_cpp(m: &Manifest) -> Result<String, String> {
    let mut externs = String::new();
    let mut defs = Vec::new();
    let (mut any_str, mut any_vec) = (false, false);
    for f in &m.exports {
        let _ = writeln!(externs, "{};", c_prototype(f)?);
        let ret = result_crossing(f)?;
        match ret.as_ref().map(|c| &c.ty) {
            Some(CppType::Str) => any_str = true,
            Some(CppType::Vec(_)) => any_vec = true,
            _ => {}
        }
        let mut args = Vec::new();
        for p in &f.params {
            let n = &p.name;
            args.push(match param_crossing(f, p)?.ty {
                CppType::Scalar(_) => n.clone(),
                CppType::Str | CppType::Vec(_) => format!("{n}.data(), {n}.size()"),
            });
        }
        if owned(&ret) {
            args.push(format!("&{LEN}"));
        }
        args.push(format!("&{ERROR}"));
        let call = format!("{}({})", symbol(&f.name), args.join(", "));
        let mut body = format!("    char *{ERROR} = nullptr;\n");
        match &ret {
            None => {
                let _ = write!(
                    body,
                    "    {call};\n    if ({ERROR})\n        mojo_anything_throw({ERROR});\n"
                );
            }
            Some(c) if matches!(c.ty, CppType::Scalar(_)) => {
                let _ = write!(
                    body,
                    "    {} mojo_anything_result = {call};\n    if ({ERROR})\n        \
                     mojo_anything_throw({ERROR});\n    return mojo_anything_result;\n",
                    c.spelled()
                );
            }
            Some(_) => {
                let _ = write!(
                    body,
                    "    size_t {LEN} = 0;\n    auto mojo_anything_result = {call};\n    if ({ERROR}) {{\n        \
                     std::free(mojo_anything_result);\n        mojo_anything_throw({ERROR});\n    }}\n    \
                     return mojo_anything_take(mojo_anything_result, {LEN});\n"
                );
            }
        }
        defs.push((
            f.name.clone(),
            format!(
                "// `{}` (`{}:{}`).\n{}\n{{\n{body}}}\n",
                f.prototype.as_deref().unwrap_or(&f.name),
                f.file,
                f.line,
                cpp_declaration(f)?
            ),
        ));
    }
    let mut out = format!(
        "// `{}`'s functions with their original C++ signatures, over the C symbols the Mojo port\n\
         // exports. Generated by mojo-anything from mojo-anything.json; regenerate with\n\
         // `mojo-anything refresh`. Compile and link this file and lib{}.so in place of `{}`.\n\n\
         {INCLUDES}#include <stdexcept>\n\nextern \"C\" {{\n{externs}}}\n\nnamespace {{\n\n{THROW}",
        m.unit,
        m.lib_name(),
        m.unit
    );
    if any_str {
        out.push('\n');
        out.push_str(TAKE_STR);
    }
    if any_vec {
        out.push('\n');
        out.push_str(TAKE_VEC);
    }
    out.push_str("\n}  // namespace\n\n");
    out.push_str(&in_namespaces(&defs));
    Ok(out)
}

// ---- Mojo ------------------------------------------------------------------------------------

fn mojo_of(c: &Crossing) -> Result<String, String> {
    let scalar = |s: &str| {
        mojo_scalar(s)
            .map(str::to_string)
            .ok_or_else(|| format!("`{s}` has no Mojo type"))
    };
    Ok(match &c.ty {
        CppType::Scalar(s) => scalar(s)?,
        CppType::Str => "String".into(),
        CppType::Vec(e) => format!("List[{}]", scalar(e)?),
    })
}

/// `port.mojo` for a C++ unit: one stub per function, named without its namespaces.
pub fn port_mojo_cpp(m: &Manifest) -> Result<String, String> {
    let mut body = String::new();
    for f in &m.exports {
        let mut params = Vec::new();
        for p in &f.params {
            params.push(format!(
                "{}: {}",
                mojo_escape(&p.name),
                mojo_of(&param_crossing(f, p)?)?
            ));
        }
        let ret = match result_crossing(f)? {
            Some(c) => format!(" -> {}", mojo_of(&c)?),
            None => String::new(),
        };
        let _ = write!(
            body,
            "\n\n# Port of `{}` (`{}:{}`).\n# C++: `{}`\ndef {}({}){ret}:\n    abort(\"{STUB_MARK}{}\")\n",
            f.name,
            f.file,
            f.line,
            f.prototype.as_deref().unwrap_or(&f.name),
            mojo_escape(port_name(&f.name)),
            params.join(", "),
            f.name
        );
    }
    Ok(format!(
        "# The Mojo port of `{}`.\n#\n\
         # `exports.mojo` exports each function under the C name the C++ shim gives it\n\
         # (`cpp__<namespace>__<name>`), and `cpp/wrapper.cpp` gives C++ callers the original\n\
         # signatures. Replace each stub's `abort` with the port of the C++ function. Where the\n\
         # original throws, add `raises` and raise `Error(\"<type>: <what()>\")`, the exception's\n\
         # type and message as the recording has them (`std::domain_error: negative input`);\n\
         # C++ callers get the same standard exception. Integers wrap as C++'s do only where\n\
         # the port says so, so use the same widths as the C++ code. Mojo fuses `a * b + c`\n\
         # into one multiply-add where C++ compilers for x86-64 round twice: round a product\n\
         # on its own (a `@no_inline` multiply) where results must match bit for bit.\n\n\
         from std.os import abort\n{body}",
        m.unit
    ))
}

/// The Mojo name of a scalar, lowercased for helper names (`float64`).
fn helper_tag(e: &str) -> String {
    mojo_scalar(e).unwrap_or("Int32").to_ascii_lowercase()
}

/// The size of a C scalar in bytes.
fn scalar_size(e: &str) -> usize {
    match crate::lang::c::scalar(e).map_or("i32", |(_, rust, ..)| rust) {
        "i8" | "u8" | "bool" => 1,
        "i16" | "u16" => 2,
        "i32" | "u32" | "f32" => 4,
        _ => 8,
    }
}

const MOJO_STR: &str = r#"
def _str(p: Optional[Pointer[UInt8, ImmutAnyOrigin]], n: UInt) -> String:
    if not p or n == 0:
        return String()
    # SAFETY: the shim passes NULL or `n` readable bytes of a `std::string`, valid for the call.
    return String(
        unsafe_from_utf8=Span[UInt8, ImmutAnyOrigin](
            unsafe_ptr=p.value(), length=Int(n)
        )
    )
"#;

const MOJO_OWNED_STR: &str = r#"
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
"#;

const MOJO_SET_ERROR: &str = r#"
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
"#;

fn mojo_list(e: &str) -> String {
    let t = mojo_scalar(e).unwrap_or("Int32");
    format!(
        "\ndef _list_{tag}(p: Optional[Pointer[{t}, ImmutAnyOrigin]], n: UInt) -> List[{t}]:\n    \
         var out = List[{t}](capacity=Int(n))\n    if not p:\n        return out^\n    \
         var ptr = p.value()\n    for i in range(Int(n)):\n        \
         # SAFETY: the shim passes NULL or `n` readable elements of a `std::vector`.\n        \
         out.append(ptr[unsafe_offset=i])\n    return out^\n",
        tag = helper_tag(e)
    )
}

fn mojo_owned_list(e: &str) -> String {
    let t = mojo_scalar(e).unwrap_or("Int32");
    format!(
        "\ndef _owned_list_{tag}(\n    v: List[{t}], len_out: Optional[Pointer[UInt, MutAnyOrigin]]\n) -> Int:\n    \
         var n = len(v)\n    \
         # SAFETY: `malloc`ed for the caller, which frees it with `free`; one element at least,\n    \
         # so an empty vector is not NULL.\n    \
         var p = external_call[\"malloc\", Optional[Pointer[{t}, MutAnyOrigin]]](\n        max(n, 1) * {size}\n    )\n    \
         if not p:\n        abort(\"out of memory\")\n    var dst = p.value()\n    for i in range(n):\n        \
         # SAFETY: `dst` holds `n` elements.\n        dst[unsafe_offset=i] = v[i]\n    \
         if len_out:\n        # SAFETY: the shim passes a valid `size_t *`.\n        \
         len_out.value()[] = UInt(n)\n    return Int(dst)\n",
        tag = helper_tag(e),
        size = scalar_size(e)
    )
}

/// `exports.mojo` for a C++ unit: each function under its C symbol, converting the shim's C
/// arguments to the port's types and its results back; a port that raises writes its error to
/// the error slot.
pub fn exports_mojo_cpp(m: &Manifest, api: &crate::codegen::PortApi) -> Result<String, String> {
    let fallible = |f: &ExportedFn| {
        api.functions
            .iter()
            .find(|g| g.rust_name == mojo_escape(port_name(&f.name)))
            .is_some_and(|g| g.fallible)
    };
    let (mut any_str, mut any_owned_str, mut any_error) = (false, false, false);
    let (mut lists, mut owned_lists): (Vec<String>, Vec<String>) = (Vec::new(), Vec::new());
    let mut body = String::new();
    for f in &m.exports {
        let ret = result_crossing(f)?;
        let mut params = Vec::new();
        let mut args = Vec::new();
        for p in &f.params {
            let c = param_crossing(f, p)?;
            let a = format!("a_{}", p.name);
            match &c.ty {
                CppType::Scalar(_) => {
                    params.push(format!("{a}: {}", mojo_of(&c)?));
                    args.push(a);
                }
                CppType::Str => {
                    any_str = true;
                    params.push(format!("{a}: Optional[Pointer[UInt8, ImmutAnyOrigin]]"));
                    params.push(format!("{a}_len: UInt"));
                    args.push(format!("_str({a}, {a}_len)"));
                }
                CppType::Vec(e) => {
                    if !lists.contains(e) {
                        lists.push(e.clone());
                    }
                    let t = mojo_scalar(e).unwrap_or("Int32");
                    params.push(format!("{a}: Optional[Pointer[{t}, ImmutAnyOrigin]]"));
                    params.push(format!("{a}_len: UInt"));
                    args.push(format!("_list_{}({a}, {a}_len)", helper_tag(e)));
                }
            }
        }
        if owned(&ret) {
            params.push(format!("a_{LEN}: Optional[Pointer[UInt, MutAnyOrigin]]"));
        }
        params.push(format!("a_{ERROR}: Optional[Pointer[Int, MutAnyOrigin]]"));
        let call = format!(
            "port.{}({})",
            mojo_escape(port_name(&f.name)),
            args.join(", ")
        );
        let (abi_ret, value, failed) = match ret.as_ref().map(|c| &c.ty) {
            None => (String::new(), call.clone(), None),
            Some(CppType::Scalar(s)) => {
                let t = mojo_scalar(s).unwrap_or("Int32");
                let zero = if t == "Bool" { "False" } else { "0" };
                (format!(" -> {t}"), call.clone(), Some(zero))
            }
            Some(CppType::Str) => {
                any_owned_str = true;
                (
                    " -> Int".to_string(),
                    format!("_owned_str({call}, a_{LEN})"),
                    Some("0"),
                )
            }
            Some(CppType::Vec(e)) => {
                if !owned_lists.contains(e) {
                    owned_lists.push(e.clone());
                }
                (
                    " -> Int".to_string(),
                    format!("_owned_list_{}({call}, a_{LEN})", helper_tag(e)),
                    Some("0"),
                )
            }
        };
        let returns = ret.is_some();
        let lines = if fallible(f) {
            any_error = true;
            let (ok, err) = match failed {
                Some(zero) => (
                    format!("return {value}"),
                    format!("\n        return {zero}"),
                ),
                None => (value, String::new()),
            };
            format!(
                "    try:\n        {ok}\n    except e:\n        _set_error(a_{ERROR}, String(e)){err}\n"
            )
        } else if returns {
            format!("    return {value}\n")
        } else {
            format!("    {value}\n")
        };
        let _ = write!(
            body,
            "\n\n# `{}` (`{}:{}`).\n@export\ndef {}(\n    {},\n) abi(\"C\"){abi_ret}:\n{lines}",
            f.prototype.as_deref().unwrap_or(&f.name),
            f.file,
            f.line,
            symbol(&f.name),
            params.join(",\n    ")
        );
    }
    let mut out = format!(
        "# C exports for the Mojo port of `{}`, generated by mojo-anything from\n\
         # `mojo-anything.json`. Regenerate with `mojo-anything refresh`. These are the C\n\
         # symbols of `cpp/shim.cpp`: strings and vectors as a pointer and a length, string and\n\
         # vector results in `malloc`ed memory with their length in `len_out`, and an error\n\
         # slot a raising port writes its error to.\n\n",
        m.unit
    );
    if any_owned_str || !owned_lists.is_empty() || any_error {
        out.push_str("from std.ffi import external_call\n");
    }
    out.push_str("from std.memory import Pointer\nfrom std.os import abort\n\nimport port\n");
    if any_str {
        out.push_str(MOJO_STR);
    }
    for e in &lists {
        out.push_str(&mojo_list(e));
    }
    if any_owned_str {
        out.push_str(MOJO_OWNED_STR);
    }
    for e in &owned_lists {
        out.push_str(&mojo_owned_list(e));
    }
    if any_error {
        out.push_str(MOJO_SET_ERROR);
    }
    out.push_str(&body);
    Ok(out)
}

/// Every generated file of a C++ unit but `port.mojo`.
pub fn bindings(
    m: &Manifest,
    api: &crate::codegen::PortApi,
) -> Result<Vec<(String, String)>, String> {
    Ok(vec![
        (
            crate::harness_mojo_c::EXPORTS.to_string(),
            exports_mojo_cpp(m, api)?,
        ),
        (SHIM.to_string(), shim_cpp(m)?),
        (WRAPPER.to_string(), wrapper_cpp(m)?),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> Manifest {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/cpp");
        crate::lang::cpp::use_typedefs(&root);
        let source = std::fs::read_to_string(root.join("src/kit.cpp")).unwrap();
        let (exports, _) = crate::lang::cpp::exports("src/kit.cpp", &source);
        let mut m: Manifest = serde_json::from_str(
            r#"{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "src/kit.cpp",
                "language": "cpp", "kind": "c-abi", "crate_name": "kit-mojo", "exports": []}"#,
        )
        .unwrap();
        m.exports = exports;
        m
    }

    fn api(port: &str) -> crate::codegen::PortApi {
        crate::codegen_mojo::parse_port_mojo(port)
    }

    #[test]
    fn port_stubs_over_mojo_types() {
        let m = manifest();
        let port = port_mojo_cpp(&m).unwrap();
        for expected in [
            "def add(a: Int32, b: Int32) -> Int32:",
            "def wide(a: Int64, b: Int64) -> Int64:",
            "def count_bytes(s: String) -> UInt:",
            "def mean(xs: List[Float64]) -> Float64:",
            "def evens(xs: List[Int32]) -> List[Int32]:",
            "def is_upper(s: String) -> Bool:",
            "def shout(s: String) -> String:",
            "def touch():",
            "def join(xs: List[Int64], sep: String) -> String:",
            "# Port of `kit::text::join` (`src/kit.cpp:",
        ] {
            assert!(port.contains(expected), "{expected} in {port}");
        }
        assert_eq!(crate::gate::mojo_stubs(&port), m.exports.len(), "{port}");
        assert!(!port.contains("Pointer"), "{port}");
    }

    #[test]
    fn shim_converts_and_catches() {
        let shim = shim_cpp(&manifest()).unwrap();
        for expected in [
            "namespace kit {\n\nint add(int a, int b);",
            "namespace kit::text {\n\nstd::string join(const std::vector<int64_t> &xs, const std::string &sep);",
            "extern \"C\" char *cpp__kit__shout(const char *a_s, size_t a_s_len, size_t *mojo_anything_len, char **mojo_anything_error)",
            "return mojo_anything_owned(kit::shout(a_s ? std::string(a_s, a_s_len) : std::string()), mojo_anything_len);",
            "return kit::mean(std::vector<double>(a_xs, a_xs + a_xs_len));",
            "extern \"C\" void cpp__kit__touch(char **mojo_anything_error)",
            "*mojo_anything_error = mojo_anything_error_text();",
            "abi::__cxa_demangle",
        ] {
            assert!(shim.contains(expected), "{expected} in {shim}");
        }
    }

    #[test]
    fn wrapper_keeps_original_signatures() {
        let wrapper = wrapper_cpp(&manifest()).unwrap();
        for expected in [
            "double mean(const std::vector<double> &xs)\n{",
            "std::vector<int> evens(std::vector<int> xs)\n{",
            "std::string shout(std::string s)\n{",
            "auto mojo_anything_result = cpp__kit__shout(s.data(), s.size(), &mojo_anything_len, &mojo_anything_error);",
            "double mojo_anything_result = cpp__kit__checked_sqrt(x, &mojo_anything_error);",
            "throw std::domain_error(what);",
            "}  // namespace kit\n\nnamespace kit::text {",
            "libkit_mojo.so in place of `src/kit.cpp`",
        ] {
            assert!(wrapper.contains(expected), "{expected} in {wrapper}");
        }
    }

    #[test]
    fn exports_mojo_emits_only_used_helpers() {
        let m = manifest();
        let stubs = port_mojo_cpp(&m).unwrap();
        let plain = exports_mojo_cpp(&m, &api(&stubs)).unwrap();
        assert!(plain.contains("@export\ndef cpp__kit__add(\n    a_a: Int32,\n    a_b: Int32,\n    a_mojo_anything_error: Optional[Pointer[Int, MutAnyOrigin]],\n) abi(\"C\") -> Int32:\n    return port.add(a_a, a_b)\n"), "{plain}");
        assert!(plain.contains("def _list_float64("), "{plain}");
        assert!(plain.contains("def _list_int64("), "{plain}");
        assert!(plain.contains("def _owned_list_int32("), "{plain}");
        assert!(plain.contains("def _owned_list_float64("), "{plain}");
        assert!(plain.contains("def _owned_str("), "{plain}");
        assert!(!plain.contains("_set_error"), "no port raises yet: {plain}");
        let raising = stubs.replace(
            "def checked_sqrt(x: Float64) -> Float64:",
            "def checked_sqrt(x: Float64) raises -> Float64:",
        );
        let with = exports_mojo_cpp(&m, &api(&raising)).unwrap();
        assert!(with.contains("def _set_error("), "{with}");
        assert!(
            with.contains("    try:\n        return port.checked_sqrt(a_x)\n    except e:\n        _set_error(a_mojo_anything_error, String(e))\n        return 0\n"),
            "{with}"
        );
        // A unit with scalars only needs neither `external_call` nor list helpers.
        let mut scalars = m.clone();
        scalars.exports.retain(|f| f.name == "kit::add");
        let small = exports_mojo_cpp(&scalars, &api(&stubs)).unwrap();
        assert!(
            !small.contains("external_call") && !small.contains("def _"),
            "{small}"
        );
    }
}
