//! The JSON bridge for Go, Ruby and Java: the port is plain Rust over serde types, and one
//! dispatcher takes a function name and its arguments as JSON and answers
//! `{"ok": value}`, `{"error": message}` or `{"panic": message}`.
//!
//! Go and Ruby reach the dispatcher through two C functions, `mojo_anything_call` and
//! `mojo_anything_free`; Java through one JNI method. The language side is a generated wrapper with
//! the original names and signatures, so callers do not change.

use crate::MIN_RUST;
use std::fmt::Write as _;

use crate::bridge::Manifest;
use crate::codegen::{PortApi, PortFn};
use crate::lang::Lang;

/// How a wrapper class or package names the JNI entry point: `mojo-anything.<Lib>Native`.
pub fn java_native_class(m: &Manifest) -> String {
    let mut out = String::new();
    for part in m.lib_name().split('_') {
        let mut chars = part.chars();
        if let Some(first) = chars.next() {
            out.extend(first.to_uppercase());
            out.push_str(chars.as_str());
        }
    }
    format!("{out}Native")
}

fn arg_expr(f: &PortFn, i: usize) -> String {
    match f.params[i].1.as_str() {
        "f64" => format!("num(args, {i})?"),
        "Option<f64>" => format!("opt_num(args, {i})?"),
        "Vec<f64>" => format!("num_vec(args, {i})?"),
        _ => format!("arg(args, {i})?"),
    }
}

fn out_expr(f: &PortFn) -> &'static str {
    match f.ret.as_str() {
        "f64" => "out_num(out)",
        "Option<f64>" => "out.map_or(Value::Null, out_num)",
        "Vec<f64>" => "Value::Array(out.into_iter().map(out_num).collect())",
        "()" => "Value::Null",
        _ => "serde_json::to_value(out).map_err(|e| e.to_string())?",
    }
}

pub fn lib_rs(m: &Manifest, api: &PortApi) -> String {
    let mut arms = String::new();
    for f in &api.functions {
        let args: Vec<String> = (0..f.params.len()).map(|i| arg_expr(f, i)).collect();
        let call = format!("port::{}({})", f.rust_name, args.join(", "));
        let call = if f.fallible { format!("{call}?") } else { call };
        let binding = if f.ret == "()" {
            "let () ="
        } else {
            "let out ="
        };
        let _ = writeln!(
            arms,
            "        \"{name}\" => {{\n            {binding} {call};\n            Ok({out})\n        }}",
            name = f.js_name,
            out = out_expr(f),
        );
    }
    let entry = if matches!(m.language, Lang::Java | Lang::Kotlin) {
        format!(
            r#"
/// `static native String call(String name, String args)` of `mojoanything.{class}`.
// SAFETY: the JNI symbol name of that method; nothing else defines it.
#[unsafe(no_mangle)]
pub extern "system" fn Java_mojoanything_{mangled}_call<'local>(
    mut env: jni::JNIEnv<'local>,
    _class: jni::objects::JClass<'local>,
    name: jni::objects::JString<'local>,
    args: jni::objects::JString<'local>,
) -> jni::sys::jstring {{
    let read = |env: &mut jni::JNIEnv<'local>, s: &jni::objects::JString<'local>| -> String {{
        env.get_string(s).map(Into::into).unwrap_or_default()
    }};
    let name = read(&mut env, &name);
    let args = read(&mut env, &args);
    env.new_string(call_json(&name, &args))
        .map_or(std::ptr::null_mut(), jni::objects::JString::into_raw)
}}
"#,
            class = java_native_class(m),
            mangled = crate::codegen_java::mangle_jni_component(&java_native_class(m)),
        )
    } else {
        r#"
/// The C entry point: `char *mojo_anything_call(const char *name, const char *args)`. Free the
/// answer with `mojo_anything_free`.
///
/// # Safety
///
/// `name` and `args` must be NUL-terminated strings, valid for the call.
// SAFETY: exported unmangled under a name only mojo-anything defines.
#[unsafe(no_mangle)]
// SAFETY: callers uphold the contract under `# Safety`.
pub unsafe extern "C" fn mojo_anything_call(name: *const c_char, args: *const c_char) -> *mut c_char {
    let text = |ptr: *const c_char| -> String {
        if ptr.is_null() {
            return String::new();
        }
        // SAFETY: the caller passes NUL-terminated strings that live for the call (see above).
        unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
    };
    let answer = call_json(&text(name), &text(args));
    // A JSON text never contains NUL: serde_json escapes it as \u0000.
    CString::new(answer).map_or(std::ptr::null_mut(), CString::into_raw)
}

/// Frees an answer of `mojo_anything_call`.
///
/// # Safety
///
/// `ptr` must come from `mojo_anything_call` and not be freed before; NULL is ignored.
// SAFETY: exported unmangled under a name only mojo-anything defines.
#[unsafe(no_mangle)]
// SAFETY: callers uphold the contract under `# Safety`.
pub unsafe extern "C" fn mojo_anything_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: `ptr` was made by `CString::into_raw` in `mojo_anything_call` (see above).
        drop(unsafe { CString::from_raw(ptr) });
    }
}
"#
        .to_string()
    };
    let imports = if matches!(m.language, Lang::Java | Lang::Kotlin) {
        "use serde_json::{Value, json};\n"
    } else {
        "use std::ffi::{CStr, CString, c_char};\n\nuse serde_json::{Value, json};\n"
    };
    format!(
        r#"//! The {lang} bridge for `{unit}`, generated by mojo-anything from `src/port.rs`: a JSON
//! dispatcher over the port, and its entry point. Regenerate with `mojo-anything refresh`.

{imports}
pub mod port;

/// Argument `i`, decoded from JSON into the port's parameter type.
fn arg<T: serde::de::DeserializeOwned>(args: &[Value], i: usize) -> Result<T, String> {{
    serde_json::from_value(args.get(i).cloned().unwrap_or(Value::Null))
        .map_err(|e| format!("argument {{i}}: {{e}}"))
}}

/// A float argument: JSON has no NaN or infinities, so they arrive as `{{"$num": "NaN"}}`.
#[allow(dead_code)]
fn num(args: &[Value], i: usize) -> Result<f64, String> {{
    match args.get(i) {{
        Some(Value::Object(o)) => match o.get("$num").and_then(Value::as_str) {{
            Some("NaN") => Ok(f64::NAN),
            Some("Infinity") => Ok(f64::INFINITY),
            Some("-Infinity") => Ok(f64::NEG_INFINITY),
            Some("-0") => Ok(-0.0),
            _ => Err(format!("argument {{i}}: not a number")),
        }},
        _ => arg(args, i),
    }}
}}

#[allow(dead_code)]
fn num_vec(args: &[Value], i: usize) -> Result<Vec<f64>, String> {{
    match args.get(i) {{
        Some(Value::Array(items)) => (0..items.len()).map(|j| num(items, j)).collect(),
        _ => arg(args, i),
    }}
}}

#[allow(dead_code)]
fn opt_num(args: &[Value], i: usize) -> Result<Option<f64>, String> {{
    match args.get(i) {{
        None | Some(Value::Null) => Ok(None),
        Some(_) => num(args, i).map(Some),
    }}
}}

#[allow(dead_code)]
fn out_num(x: f64) -> Value {{
    if x.is_nan() {{
        json!({{"$num": "NaN"}})
    }} else if x.is_infinite() {{
        json!({{"$num": if x > 0.0 {{ "Infinity" }} else {{ "-Infinity" }}}})
    }} else if x == 0.0 && x.is_sign_negative() {{
        json!({{"$num": "-0"}})
    }} else {{
        json!(x)
    }}
}}

fn dispatch(name: &str, args: &[Value]) -> Result<Value, String> {{
    match name {{
{arms}        _ => Err(format!("no function `{{name}}`")),
    }}
}}

/// Runs `name` on the JSON array `args`; never unwinds into the caller.
pub fn call_json(name: &str, args: &str) -> String {{
    let result = std::panic::catch_unwind(|| {{
        let args: Vec<Value> = serde_json::from_str(args).map_err(|e| e.to_string())?;
        dispatch(name, &args)
    }});
    match result {{
        Ok(Ok(value)) => json!({{"ok": value}}),
        Ok(Err(message)) => json!({{"error": message}}),
        Err(panic) => {{
            let message = panic
                .downcast_ref::<&str>()
                .map(ToString::to_string)
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".into());
            json!({{"panic": message}})
        }}
    }}
    .to_string()
}}
{entry}"#,
        lang = m.language.name(),
        unit = m.unit,
    )
}

/// The generated dispatcher of a Go or Ruby unit.
pub const DISPATCHER: &str = "dispatcher.mojo";

fn mangle(ty: &str) -> String {
    ty.chars()
        .filter(|c| !c.is_whitespace() && *c != ']')
        .map(|c| if c == '[' || c == ',' { '_' } else { c })
        .collect()
}

fn inner<'a>(ty: &'a str, wrapper: &str) -> Option<&'a str> {
    ty.strip_prefix(wrapper)?
        .strip_prefix('[')?
        .strip_suffix(']')
}

/// Signed and unsigned Mojo integer types with their bounds.
fn int_bounds(ty: &str) -> Option<(bool, &'static str, &'static str)> {
    Some(match ty {
        "Int" | "Int64" => (true, "Int64.MIN", "Int64.MAX"),
        "Int8" => (true, "-128", "127"),
        "Int16" => (true, "-32768", "32767"),
        "Int32" => (true, "-2147483648", "2147483647"),
        "UInt" | "UInt64" => (false, "0", "UInt64.MAX"),
        "UInt8" => (false, "0", "255"),
        "UInt16" => (false, "0", "65535"),
        "UInt32" => (false, "0", "4294967295"),
        _ => return None,
    })
}

/// The type converters a dispatcher needs, each written once.
#[derive(Default)]
struct Converters {
    text: String,
    done: std::collections::BTreeSet<String>,
}

/// Emits `_from_json_<T>` (JSON value to `ty`) and what it needs; returns its name.
fn from_json(out: &mut Converters, ty: &str) -> Result<String, String> {
    let name = format!("_from_json_{}", mangle(ty));
    if out.done.contains(&name) {
        return Ok(name);
    }
    let body = match ty {
        "JsonValue" => "return v.copy()".to_string(),
        "Float64" => "return as_float(v)".into(),
        "Float32" => "return Float32(as_float(v))".into(),
        "String" => "return json_string(v)".into(),
        "Bool" => "return json_bool(v)".into(),
        _ => {
            if let Some((signed, lo, hi)) = int_bounds(ty) {
                if signed {
                    format!("return {ty}(json_int(v, {lo}, {hi}))")
                } else {
                    format!("return {ty}(json_uint(v, {hi}))")
                }
            } else if let Some(t) = inner(ty, "List") {
                let item = from_json(out, t)?;
                format!(
                    "json_array(v)\n    var items = List[{t}]()\n    for item in v.array():\n        \
                     items.append({item}(item))\n    return items^"
                )
            } else if let Some(t) = inner(ty, "Optional") {
                let value = from_json(out, t)?;
                format!(
                    "if v.is_null():\n        return Optional[{t}](None)\n    return Optional[{t}]({value}(v))"
                )
            } else {
                return Err(format!("`{ty}` cannot cross the JSON dispatcher"));
            }
        }
    };
    let _ = writeln!(
        out.text,
        "\n\ndef {name}(v: JsonValue) raises -> {ty}:\n    {body}"
    );
    out.done.insert(name.clone());
    Ok(name)
}

/// Emits `_to_json_<T>` (`ty` to a JSON value) and what it needs; returns its name.
fn to_json(out: &mut Converters, ty: &str) -> Result<String, String> {
    let name = format!("_to_json_{}", mangle(ty));
    if out.done.contains(&name) {
        return Ok(name);
    }
    let body = match ty {
        "JsonValue" => "return v.copy()".to_string(),
        "Float64" => "return json_float(v)".into(),
        "Float32" => "return json_float(Float64(v))".into(),
        "String" => "return JsonValue(String(v))".into(),
        "Bool" => "return JsonValue(v)".into(),
        _ => {
            if let Some((signed, _, _)) = int_bounds(ty) {
                if signed {
                    "return JsonValue(Int64(v))".into()
                } else {
                    "return JsonValue(UInt64(v))".into()
                }
            } else if let Some(t) = inner(ty, "List") {
                let item = to_json(out, t)?;
                format!(
                    "var items = Array()\n    for item in v:\n        items.append({item}(item))\n    \
                     return JsonValue(items^)"
                )
            } else if let Some(t) = inner(ty, "Optional") {
                let value = to_json(out, t)?;
                format!("if not v:\n        return JsonValue()\n    return {value}(v.value())")
            } else {
                return Err(format!("`{ty}` cannot cross the JSON dispatcher"));
            }
        }
    };
    let _ = writeln!(
        out.text,
        "\n\ndef {name}(v: {ty}) raises -> JsonValue:\n    {body}"
    );
    out.done.insert(name.clone());
    Ok(name)
}

const DISPATCHER_HELPERS: &str = r#"

def _bytes_text(p: Optional[Pointer[Int8, ImmutAnyOrigin]]) -> String:
    # SAFETY: the caller passes NULL or a NUL-terminated string valid for the call. The bytes
    # are UTF-8 JSON; they are copied as they are.
    if not p:
        return String()
    var ptr = p.value().unsafe_bitcast[UInt8]()
    var n = 0
    while ptr[unsafe_offset=n] != 0:
        n += 1
    return String(
        unsafe_from_utf8=Span[UInt8, ImmutAnyOrigin](unsafe_ptr=ptr, length=n)
    )


def _answer(s: String) -> Optional[Pointer[Int8, MutAnyOrigin]]:
    var b = s.as_bytes()
    var n = len(b)
    var p = external_call["malloc", Optional[Pointer[UInt8, MutAnyOrigin]]](n + 1)
    if not p:
        return None
    var q = p.value()
    for i in range(n):
        q[unsafe_offset=i] = b[i]
    q[unsafe_offset=n] = 0
    return q.unsafe_bitcast[Int8]()


def _tagged(tag: String, message: String) -> String:
    var o = Object()
    o[tag] = JsonValue(message)
    try:
        return write_json(JsonValue(o^))
    except:
        return '{"panic":"the dispatcher could not write its answer"}'


def _panic(message: String) -> String:
    return _tagged("panic", message)


def _error(message: String) -> String:
    return _tagged("error", message)


def _ok(v: JsonValue) -> String:
    try:
        return '{"ok":' + write_json(v) + "}"
    except e:
        return _panic("the result does not write as JSON: " + String(e))
"#;

/// `dispatcher.mojo`: `mojo_anything_call(name, args) -> answer` over every port function, and
/// `mojo_anything_free(answer)`. `args` is a JSON array; the answer is `{"ok": value}`,
/// `{"error": message}` when the port raises, or `{"panic": message}` when the call itself is
/// wrong (unknown name, argument count, a value the port's type cannot hold). Mojo has no
/// unwinding panics: a port that aborts ends the process.
pub fn dispatcher_mojo(m: &Manifest, api: &PortApi) -> Result<String, String> {
    let mut conv = Converters::default();
    let mut calls = String::new();
    let mut arms = String::new();
    for f in &api.functions {
        let at = |e: String| format!("`{}`: {e}", f.rust_name);
        let n = f.params.len();
        let _ = writeln!(
            calls,
            "\n\ndef _call_{}(args: Array) -> String:\n    if len(args) != {n}:\n        \
             return _panic(\"{} takes {n} argument{}, got \" + String(len(args)))",
            f.rust_name,
            f.js_name,
            if n == 1 { "" } else { "s" }
        );
        for (i, (_, t)) in f.params.iter().enumerate() {
            let _ = writeln!(calls, "    var a{i}: {t}");
        }
        if n > 0 {
            calls.push_str("    try:\n");
            for (i, (_, t)) in f.params.iter().enumerate() {
                let from = from_json(&mut conv, t).map_err(at)?;
                let _ = writeln!(calls, "        a{i} = {from}(args[{i}])");
            }
            let _ = writeln!(
                calls,
                "    except e:\n        return _panic(\"{}: \" + String(e))",
                f.js_name
            );
        }
        let call_args: Vec<String> = (0..n).map(|i| format!("a{i}")).collect();
        let call = format!("port.{}({})", f.rust_name, call_args.join(", "));
        let result = if f.ret == "None" {
            format!("{call}\n        return _ok(JsonValue())")
        } else {
            let to = to_json(&mut conv, &f.ret).map_err(at)?;
            format!("var out = {to}({call})\n        return _ok(out)")
        };
        let _ = writeln!(
            calls,
            "    try:\n        {result}\n    except e:\n        return _error(String(e))"
        );
        let _ = writeln!(
            arms,
            "    if name == \"{}\":\n        return _call_{}(a)",
            f.js_name, f.rust_name
        );
    }
    // Ruby's bignums would otherwise read as floats (see json.mojo).
    let refuse = if m.language == Lang::Ruby {
        "True"
    } else {
        "False"
    };
    Ok(format!(
        "# The JSON dispatcher for the Mojo port of `{unit}`, generated by mojo-anything. Regenerate\n\
         # with `mojo-anything refresh`.\n\n\
         from std.ffi import external_call\nfrom std.memory import Pointer\n\n\
         from emberjson import Array, Object\nfrom json import JsonValue, as_float, json_array, json_bool, \
         json_float, json_int, json_string, json_uint, parse_json, write_json\n\n\
         import port\n{helpers}{conv}{calls}\n\n\
         def _call(name: String, text: String) -> String:\n    \
         var args: JsonValue\n    try:\n        args = parse_json(text, {refuse})\n    \
         except e:\n        return _panic(\"the arguments are not JSON: \" + String(e))\n    \
         if not args.is_array():\n        return _panic(\"the arguments are not a JSON array\")\n    \
         ref a = args.array()\n{arms}    return _panic(\"unknown function: \" + name)\n\n\n\
         @export\n\
         def mojo_anything_call(\n    name: Optional[Pointer[Int8, ImmutAnyOrigin]],\n    \
         args: Optional[Pointer[Int8, ImmutAnyOrigin]],\n) abi(\"C\") -> Optional[Pointer[Int8, MutAnyOrigin]]:\n    \
         return _answer(_call(_bytes_text(name), _bytes_text(args)))\n\n\n\
         @export\n\
         def mojo_anything_free(p: Optional[Pointer[Int8, MutAnyOrigin]]) abi(\"C\"):\n    \
         if p:\n        external_call[\"free\", NoneType](p.value())\n",
        unit = m.unit,
        helpers = DISPATCHER_HELPERS,
        conv = conv.text,
    ))
}

pub fn cargo_toml(m: &Manifest) -> String {
    let (crate_types, extra) = match m.language {
        Lang::Java | Lang::Kotlin => ("\"cdylib\", \"rlib\"", "jni = \"0.21\"\n"),
        _ => ("\"cdylib\", \"staticlib\", \"rlib\"", ""),
    };
    // Java's LinkedHashMap keeps insertion order. `float_roundtrip`: the default float parser
    // can be off by one ULP.
    let serde_json =
        "serde_json = { version = \"1\", features = [\"preserve_order\", \"float_roundtrip\"] }\n";
    format!(
        "[package]\nname = \"{}\"\nversion = \"0.1.0\"\nedition = \"2024\"\nrust-version = \"{MIN_RUST}\"\npublish = false\n\
         description = \"Rust port of `{}`, generated by mojo-anything\"\n\n\
         [lib]\ncrate-type = [{crate_types}]\n\n[dependencies]\nserde = {{ version = \"1\", features = [\"derive\"] }}\n\
         {serde_json}{extra}\n[profile.release]\nlto = true\n\n[lints.clippy]\nall = {{ level = \"warn\", priority = -1 }}\n\n[lints.rust]\nunused_lifetimes = \"warn\"\ntrivial_numeric_casts = \"warn\"\n",
        m.crate_name, m.unit
    )
}
