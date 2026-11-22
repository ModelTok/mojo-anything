//! Batch classes for Ruby (magnus) and Java (JNI): the same `run` and `rank` as the
//! TS and Python batches in `codegen_batch`, over items kept in Rust and run on all cores.

use std::fmt::Write as _;

use crate::bridge::Manifest;
use crate::codegen::PortApi;
use crate::codegen_batch::{
    Batch, default_index, fixed, rank_body, rank_for, spec_with, use_custom_rank,
};
use crate::ts::exports::ExportedFn;

/// The export a batch belongs to.
fn export<'m>(m: &'m Manifest, b: &Batch) -> Result<&'m ExportedFn, String> {
    m.exports
        .iter()
        .find(|e| e.name == b.function)
        .ok_or_else(|| format!("`{}` is not an export of the unit", b.function))
}

fn is_value(t: &str) -> bool {
    matches!(t.trim(), "Value" | "serde_json::Value")
}

// ---- Ruby ------------------------------------------------------------------------------------

/// Splits a Ruby parameter list at its top-level commas.
fn split_params(sig: &str) -> Vec<String> {
    let mut out = vec![String::new()];
    let mut depth = 0i32;
    let mut quote: Option<char> = None;
    for c in sig.chars() {
        match (quote, c) {
            (Some(q), c) if c == q => quote = None,
            (Some(_), _) => {}
            (None, '"' | '\'') => quote = Some(c),
            (None, '(' | '[' | '{') => depth += 1,
            (None, ')' | ']' | '}') => depth -= 1,
            (None, ',') if depth == 0 => {
                out.push(String::new());
                continue;
            }
            _ => {}
        }
        if let Some(last) = out.last_mut() {
            last.push(c);
        }
    }
    out.into_iter()
        .map(|p| p.trim().to_string())
        .filter(|p| !p.is_empty())
        .collect()
}

/// The name a Ruby parameter declares: `sep = "-"` is `sep`, `max: nil` is `max`.
fn param_name(p: &str) -> &str {
    let p = p.trim_start_matches(['*', '&']);
    let end = p
        .find(|c: char| !(c.is_alphanumeric() || c == '_'))
        .unwrap_or(p.len());
    &p[..end]
}

/// Batch classes for the magnus extension: `(Rust code, init lines)`.
pub fn ruby_rs(m: &Manifest, api: &PortApi) -> Result<(String, String), String> {
    let mut code = String::new();
    let mut init = String::new();
    for b in &m.batches {
        let s = spec_with(b, api, true)?;
        if !s.custom {
            code.push_str(&default_index(&s, true));
        }
        let fixed = fixed(&s);
        let item_value = is_value(&s.item_ty);
        let ret = s.f.ret.trim();
        let ret_value = is_value(ret);
        let params: Vec<String> = fixed
            .iter()
            .map(|(n, t)| {
                if is_value(t) {
                    format!("{n}: magnus::Value")
                } else {
                    format!("{n}: {t}")
                }
            })
            .collect();
        let mut convert = String::new();
        for (n, t) in fixed.iter().filter(|(_, t)| is_value(t)) {
            let _ = writeln!(
                convert,
                "        let {n}: {t} = rbconv::arg({n}).map_err(|m| error(ruby, m))?;"
            );
        }
        let names: Vec<&str> = fixed.iter().map(|(n, _)| n.as_str()).collect();
        let sep = if params.is_empty() { "" } else { ", " };
        let (items_param, items_convert) = if item_value {
            (
                "items: magnus::RArray".to_string(),
                "        let items = (0..items.len())\n            \
                 .map(|i| rbconv::from_rb(items.entry(isize::try_from(i).unwrap_or(isize::MAX)).map_err(|e| e.to_string())?))\n            \
                 .collect::<Result<Vec<_>, _>>()\n            .map_err(|m| error(ruby, m))?;\n",
            )
        } else {
            (format!("items: Vec<{}>", s.item_ty), "")
        };
        let (run_ret, run_tail) = if ret_value {
            (
                "magnus::RArray".to_string(),
                "\n            .and_then(|out| {\n                let array = ruby.ary_new_capa(out.len());\n                \
                 for v in &out {\n                    array.push(rbconv::to_rb(ruby, v)?)?;\n                }\n                Ok(array)\n            })",
            )
        } else {
            (format!("Vec<{ret}>"), "")
        };
        let _ = write!(
            code,
            "\n/// `{js}` over many `{param}` values kept in Rust: `run` maps them all in one call, on\n\
             /// all cores; `rank` returns the indexes of results >= `min`, best first.\n\
             #[magnus::wrap(class = \"MojoAnythingNative{camel}::{class}\", free_immediately, size)]\n\
             pub struct {class} {{\n    inner: {index},\n}}\n\n\
             impl {class} {{\n    \
             fn new(ruby: &Ruby, {items_param}) -> Result<Self, Error> {{\n{items_convert}        \
             guard(ruby, || Ok(Self {{ inner: {index}::new(items) }}))\n    }}\n\n    \
             fn run(ruby: &Ruby, rb_self: &Self{sep}{params}) -> Result<{run_ret}, Error> {{\n{convert}        \
             guard(ruby, || rb_self.inner.run({names})){run_tail}\n    }}\n",
            js = s.f.js_name,
            param = b.param,
            camel = crate::codegen_ruby::camel(&m.lib_name()),
            class = s.class,
            index = s.index,
            params = params.join(", "),
            names = names.join(", "),
        );
        let n = fixed.len();
        let _ = write!(
            init,
            "    let class = native.define_class(\"{class}\", ruby.class_object())?;\n    \
             class.define_singleton_method(\"new\", function!({class}::new, 1))?;\n    \
             class.define_method(\"run\", method!({class}::run, {n}))?;\n",
            class = s.class,
        );
        if let Some(rank) = rank_for(&s) {
            let from = code.len();
            let _ = write!(
                code,
                "\n    fn rank(ruby: &Ruby, rb_self: &Self{sep}{params}, min: f64) -> Result<Vec<u32>, Error> {{\n{convert}        \
                 let out = guard(ruby, || rb_self.inner.run({names}))?;\n        {rank}\n        Ok(order)\n    }}\n",
                params = params.join(", "),
                names = names.join(", "),
            );
            use_custom_rank(&mut code, from, &s, &names);
            let _ = writeln!(
                init,
                "    class.define_method(\"rank\", method!({}::rank, {}))?;",
                s.class,
                n + 1
            );
        }
        code.push_str("}\n");
    }
    Ok((code, init))
}

/// Ruby classes in the original modules: `Textkit::SlugifyBatch.new(texts)`, then `run` and
/// `rank` with the original's other parameters, defaults and keywords included.
pub fn ruby_wrapper(m: &Manifest, api: &PortApi) -> Result<String, String> {
    let lib = m.lib_name();
    let mut out = String::new();
    for b in &m.batches {
        let s = spec_with(b, api, true)?;
        let e = export(m, b)?;
        let (recv, _) = crate::lang::ruby::receiver(e);
        let item = e
            .params
            .get(s.item)
            .map(|p| p.name.clone())
            .unwrap_or_else(|| b.param.clone());
        let rest: Vec<String> = split_params(&crate::lang::ruby::signature(e))
            .into_iter()
            .filter(|p| param_name(p) != item)
            .collect();
        let args: Vec<&str> = e
            .params
            .iter()
            .filter(|p| p.name != item)
            .map(|p| p.name.as_str())
            .collect();
        let native = format!(
            "MojoAnythingNative{}::{}",
            crate::codegen_ruby::camel(&lib),
            s.class
        );
        let mut rank_sig = rest.clone();
        rank_sig.push("min: 0".into());
        let mut rank_args: Vec<&str> = args.clone();
        rank_args.push("min");
        let rank = if rank_body(s.f.ret.trim()).is_some() {
            format!(
                "\n\n  # Indexes of the items whose result is at least `min`, highest result first.\n  \
                 def rank({})\n    @native.rank({})\n  end",
                rank_sig.join(", "),
                rank_args.join(", ")
            )
        } else {
            String::new()
        };
        let class = format!(
            "# `{name}` over many `{item}` values kept in Rust: built once, then each `run` maps them all\n\
             # in one call, on all cores.\n\
             class {class}\n  def initialize({item}s)\n    @native = {native}.new({item}s.to_a)\n  end\n\n  \
             # The result for every item, in order.\n  def run({sig})\n    @native.run({args})\n  end{rank}\nend",
            name = e.name,
            class = s.class,
            sig = rest.join(", "),
            args = args.join(", "),
        );
        let parts: Vec<&str> = recv.split("::").filter(|p| *p != "Object").collect();
        let mut code = String::new();
        for (depth, part) in parts.iter().enumerate() {
            let _ = writeln!(code, "{}module {part}", "  ".repeat(depth));
        }
        let indent = "  ".repeat(parts.len());
        for line in class.lines() {
            if line.is_empty() {
                code.push('\n');
            } else {
                let _ = writeln!(code, "{indent}{line}");
            }
        }
        for depth in (0..parts.len()).rev() {
            let _ = writeln!(code, "{}end", "  ".repeat(depth));
        }
        let _ = write!(out, "\n{code}");
    }
    Ok(out)
}

// ---- Java ------------------------------------------------------------------------------------

/// A Java type a batch carries: Java name, JNI scalar, JNI array type, port type, and how a
/// port value becomes the JNI scalar.
struct JavaTy {
    java: &'static str,
    scalar: &'static str,
    array: &'static str,
    port: &'static str,
    /// `new_<x>_array` / `<x>_array_region` in the jni crate.
    region: &'static str,
    /// The conversion of a port value to the JNI scalar, as a function path; `None` when it is the
    /// same type.
    to_jni: Option<&'static str>,
    /// The conversion of a JNI scalar to the port value.
    from_jni: Option<&'static str>,
}

/// `expr` converted by `f`.
fn apply(f: Option<&str>, expr: &str) -> String {
    f.map_or_else(|| expr.to_string(), |f| format!("{f}({expr})"))
}

/// `.map(f)` over an iterator, or nothing.
fn map(f: Option<&str>) -> String {
    f.map(|f| format!(".map({f})")).unwrap_or_default()
}

fn java_ty(java: &str) -> Option<JavaTy> {
    Some(match java.trim() {
        "int" => JavaTy {
            java: "int",
            scalar: "jni::sys::jint",
            array: "jni::objects::JIntArray<'local>",
            port: "i64",
            region: "int",
            to_jni: Some("batch_jint"),
            from_jni: Some("i64::from"),
        },
        "long" => JavaTy {
            java: "long",
            scalar: "jni::sys::jlong",
            array: "jni::objects::JLongArray<'local>",
            port: "i64",
            region: "long",
            to_jni: None,
            from_jni: None,
        },
        "double" => JavaTy {
            java: "double",
            scalar: "jni::sys::jdouble",
            array: "jni::objects::JDoubleArray<'local>",
            port: "f64",
            region: "double",
            to_jni: None,
            from_jni: None,
        },
        "boolean" => JavaTy {
            java: "boolean",
            scalar: "jni::sys::jboolean",
            array: "jni::objects::JBooleanArray<'local>",
            port: "bool",
            region: "boolean",
            to_jni: Some("jni::sys::jboolean::from"),
            from_jni: Some("batch_bool"),
        },
        "String" => JavaTy {
            java: "String",
            scalar: "jni::objects::JString<'local>",
            array: "jni::objects::JObjectArray<'local>",
            port: "String",
            region: "",
            to_jni: None,
            from_jni: None,
        },
        _ => return None,
    })
}

struct JavaBatch<'a> {
    e: &'a ExportedFn,
    s: crate::codegen_batch::Spec<'a>,
    package: String,
    item: JavaTy,
    /// `(Rust name, Java name, type)` of the other parameters.
    fixed: Vec<(String, String, JavaTy)>,
    result: JavaTy,
}

fn java_batches<'a>(m: &'a Manifest, api: &'a PortApi) -> Result<Vec<JavaBatch<'a>>, String> {
    let mut out = Vec::new();
    for b in &m.batches {
        let s = spec_with(b, api, false)?;
        let e = export(m, b)?;
        let ty = |java: &str, what: &str| {
            java_ty(java).ok_or_else(|| {
                format!("Java batches take and return int, long, double, boolean or String; {what} is `{java}`")
            })
        };
        let p = e
            .params
            .get(s.item)
            .ok_or("parameter count differs from port.rs")?;
        let item = ty(
            p.native_type.as_deref().unwrap_or_default(),
            &format!("`{}`", p.name),
        )?;
        let mut fixed = Vec::new();
        for (i, p) in e.params.iter().enumerate().filter(|(i, _)| *i != s.item) {
            let t = ty(
                p.native_type.as_deref().unwrap_or_default(),
                &format!("`{}`", p.name),
            )?;
            fixed.push((s.f.params[i].0.clone(), p.name.clone(), t));
        }
        let result = ty(
            e.native_return.as_deref().unwrap_or("void"),
            &format!("`{}`'s result", e.name),
        )?;
        let (class, _) = crate::lang::java::receiver(e);
        let package = class
            .rsplit_once('.')
            .map(|(p, _)| p.to_string())
            .unwrap_or_default();
        out.push(JavaBatch {
            e,
            s,
            package,
            item,
            fixed,
            result,
        });
    }
    Ok(out)
}

/// The JNI symbol of `method` in `package.class`.
fn jni_symbol(package: &str, class: &str, method: &str) -> String {
    let mangle = crate::codegen_java::mangle_jni_component;
    let mut parts: Vec<String> = package
        .split('.')
        .filter(|p| !p.is_empty())
        .map(mangle)
        .collect();
    parts.push(mangle(class));
    parts.push(mangle(method));
    format!("Java_{}", parts.join("_"))
}

const JAVA_BATCH_RS: &str = r#"
/// A batch's handle as Java holds it.
///
/// # Safety
///
/// `handle` comes from a batch's `nNew` and is not freed yet; Java checks it is not 0.
// SAFETY: unsafe to call; callers uphold the contract above.
unsafe fn batch_ref<'a, T>(handle: jni::sys::jlong) -> &'a T {
    // SAFETY: as documented above.
    unsafe { &*(handle as *const T) }
}

/// A Java `String[]` as strings; `None` with a NullPointerException pending for a null element.
fn batch_strings(env: &mut jni::JNIEnv, items: &jni::objects::JObjectArray) -> Option<Vec<String>> {
    let n = env.get_array_length(items).ok()?;
    let mut out = Vec::with_capacity(usize::try_from(n).unwrap_or(0));
    for i in 0..n {
        let item = jni::objects::JString::from(env.get_object_array_element(items, i).ok()?);
        let value = string_arg(env, &item);
        let _ = env.delete_local_ref(item);
        out.push(value?);
    }
    Some(out)
}

/// String results as one `char[]` of UTF-16, each result's length written to `lens`: Java
/// slices it into strings, instead of one JNI call per string. Encoding and freeing run on all
/// cores.
fn batch_utf16(env: &mut jni::JNIEnv, values: Vec<String>, lens: &jni::objects::JIntArray) -> jni::sys::jcharArray {
    use rayon::prelude::*;
    let sizes: Vec<usize> = values.par_iter().with_min_len(256).map(|v| v.encode_utf16().count()).collect();
    let mut chars = vec![0u16; sizes.iter().sum()];
    let mut rest = chars.as_mut_slice();
    let mut parts = Vec::with_capacity(values.len());
    for n in &sizes {
        let (head, tail) = std::mem::take(&mut rest).split_at_mut(*n);
        parts.push(head);
        rest = tail;
    }
    parts.into_par_iter().zip(values.par_iter()).with_min_len(256).for_each(|(dst, v)| {
        for (d, u) in dst.iter_mut().zip(v.encode_utf16()) {
            *d = u;
        }
    });
    values.into_par_iter().with_min_len(256).for_each(drop);
    let counts: Vec<jni::sys::jint> = sizes.iter().map(|&n| jni::sys::jint::try_from(n).unwrap_or(jni::sys::jint::MAX)).collect();
    if env.set_int_array_region(lens, 0, &counts).is_err() {
        return std::ptr::null_mut();
    }
    let Ok(n) = jni::sys::jsize::try_from(chars.len()) else {
        let _ = env.throw_new("java/lang/OutOfMemoryError", "batch results over 2^31 characters");
        return std::ptr::null_mut();
    };
    match env.new_char_array(n) {
        Ok(array) => {
            let _ = env.set_char_array_region(&array, 0, &chars);
            array.into_raw()
        }
        Err(_) => std::ptr::null_mut(),
    }
}

/// A port's integer as a Java `int`, wrapping like a Java cast.
#[allow(dead_code)]
fn batch_jint(v: i64) -> jni::sys::jint {
    v as jni::sys::jint
}

/// A Java `boolean`.
#[allow(dead_code)]
fn batch_bool(v: jni::sys::jboolean) -> bool {
    v != 0
}

/// Indexes as a Java `int[]`.
fn batch_int_array(env: &mut jni::JNIEnv, order: &[u32]) -> jni::sys::jintArray {
    let values: Vec<jni::sys::jint> = order.iter().map(|&i| jni::sys::jint::try_from(i).unwrap_or(jni::sys::jint::MAX)).collect();
    let n = jni::sys::jsize::try_from(values.len()).unwrap_or(jni::sys::jsize::MAX);
    match env.new_int_array(n) {
        Ok(array) => {
            let _ = env.set_int_array_region(&array, 0, &values);
            array.into_raw()
        }
        Err(_) => std::ptr::null_mut(),
    }
}
"#;

/// The batch functions for `lib.rs`.
pub fn java_rs(m: &Manifest, api: &PortApi) -> Result<String, String> {
    let batches = java_batches(m, api)?;
    if batches.is_empty() {
        return Ok(String::new());
    }
    let mut out = JAVA_BATCH_RS.to_string();
    for g in &batches {
        let s = &g.s;
        if !s.custom {
            out.push_str(&default_index(s, true));
        }
        let index = &s.index;
        let sym = |method: &str| jni_symbol(&g.package, &s.class, method);
        let read_items = if g.item.port == "String" {
            "    let Some(items) = batch_strings(&mut env, &items) else {\n        return 0;\n    };\n".to_string()
        } else {
            format!(
                "    let n = env.get_array_length(&items).unwrap_or(0);\n    \
                 let mut raw: Vec<{scalar}> = vec![Default::default(); usize::try_from(n).unwrap_or(0)];\n    \
                 if env.get_{region}_array_region(&items, 0, &mut raw).is_err() {{\n        return 0;\n    }}\n    \
                 let items: Vec<{port}> = raw.into_iter(){from}.collect();\n",
                scalar = g.item.scalar,
                region = g.item.region,
                port = g.item.port,
                from = map(g.item.from_jni),
            )
        };
        let mut params = String::new();
        let mut convert = String::new();
        let mut args = Vec::new();
        for (n, _, t) in &g.fixed {
            let _ = write!(params, ", {n}: {}", t.scalar);
            if t.port == "String" {
                let _ = writeln!(
                    convert,
                    "    let Some({n}) = string_arg(&mut env, &{n}) else {{\n        return std::ptr::null_mut();\n    }};"
                );
            } else {
                if t.from_jni.is_some() {
                    let _ = writeln!(convert, "    let {n} = {};", apply(t.from_jni, n));
                }
            }
            args.push(n.as_str());
        }
        let (array_ty, write) = if g.result.port == "String" {
            (
                "jni::sys::jcharArray".to_string(),
                "batch_utf16(&mut env, values, &lens)".to_string(),
            )
        } else {
            (
                format!("jni::sys::j{}Array", g.result.region),
                format!(
                    "{{\n            let raw: Vec<{scalar}> = values.into_iter(){to}.collect();\n            \
                     let n = jni::sys::jsize::try_from(raw.len()).unwrap_or(jni::sys::jsize::MAX);\n            \
                     match env.new_{region}_array(n) {{\n                Ok(array) => {{\n                    \
                     let _ = env.set_{region}_array_region(&array, 0, &raw);\n                    array.into_raw()\n                }}\n                \
                     Err(_) => std::ptr::null_mut(),\n            }}\n        }}",
                    scalar = g.result.scalar,
                    to = map(g.result.to_jni),
                    region = g.result.region,
                ),
            )
        };
        let _ = write!(
            out,
            "\n/// Builds a `{class}`: the items cross once; Java keeps the handle.\n\
             // SAFETY: the JNI symbol of `{package}.{class}.nNew`; nothing else defines it.\n#[unsafe(no_mangle)]\n\
             pub extern \"system\" fn {new}<'local>(mut env: jni::JNIEnv<'local>, _class: jni::objects::JClass<'local>, items: {item_array}) -> jni::sys::jlong {{\n\
             {read_items}    match std::panic::catch_unwind(|| {index}::new(items)) {{\n        \
             Ok(index) => Box::into_raw(Box::new(index)) as jni::sys::jlong,\n        \
             Err(_) => {{\n            let _ = env.throw_new(\"java/lang/RuntimeException\", \"Rust panic building {class}\");\n            0\n        }}\n    }}\n}}\n\n\
             /// Frees a `{class}`.\n// SAFETY: the JNI symbol of `{package}.{class}.nFree`; nothing else defines it.\n#[unsafe(no_mangle)]\n\
             pub extern \"system\" fn {free}<'local>(_env: jni::JNIEnv<'local>, _class: jni::objects::JClass<'local>, handle: jni::sys::jlong) {{\n    \
             if handle != 0 {{\n        // SAFETY: Java frees each handle from `nNew` once (its Cleaner runs once).\n        \
             drop(unsafe {{ Box::from_raw(handle as *mut {index}) }});\n    }}\n}}\n\n\
             /// `{name}` over every item; errors go to `slot`.\n// SAFETY: the JNI symbol of `{package}.{class}.nRun`; nothing else defines it.\n#[unsafe(no_mangle)]\n\
             pub extern \"system\" fn {run}<'local>(mut env: jni::JNIEnv<'local>, _class: jni::objects::JClass<'local>, handle: jni::sys::jlong{params}{lens_param}, slot: jni::objects::JObjectArray<'local>) -> {array_ty} {{\n\
             {convert}    // SAFETY: Java passes a live handle (it checks for 0 and keeps the batch reachable).\n    \
             let index: &{index} = unsafe {{ batch_ref(handle) }};\n    \
             match run(|| index.run({args})) {{\n        Ok(values) => {write},\n        \
             Err(message) => {{\n            report(&mut env, &slot, &message);\n            std::ptr::null_mut()\n        }}\n    }}\n}}\n",
            class = s.class,
            package = g.package,
            name = g.e.name,
            new = sym("nNew"),
            free = sym("nFree"),
            run = sym("nRun"),
            item_array = g.item.array,
            lens_param = if g.result.port == "String" {
                ", lens: jni::objects::JIntArray<'local>"
            } else {
                ""
            },
            args = args.join(", "),
        );
        if let Some(rank) = rank_for(s) {
            let from = out.len();
            let _ = write!(
                out,
                "\n/// Indexes of the items whose result is at least `min`, best first.\n\
                 // SAFETY: the JNI symbol of `{package}.{class}.nRank`; nothing else defines it.\n#[unsafe(no_mangle)]\n\
                 pub extern \"system\" fn {rank_sym}<'local>(mut env: jni::JNIEnv<'local>, _class: jni::objects::JClass<'local>, handle: jni::sys::jlong{params}, min: jni::sys::jdouble, slot: jni::objects::JObjectArray<'local>) -> jni::sys::jintArray {{\n\
                 {convert}    // SAFETY: Java passes a live handle (it checks for 0 and keeps the batch reachable).\n    \
                 let index: &{index} = unsafe {{ batch_ref(handle) }};\n    \
                 match run(|| index.run({args})) {{\n        Ok(out) => {{\n            {rank}\n            batch_int_array(&mut env, &order)\n        }}\n        \
                 Err(message) => {{\n            report(&mut env, &slot, &message);\n            std::ptr::null_mut()\n        }}\n    }}\n}}\n",
                class = s.class,
                package = g.package,
                rank_sym = sym("nRank"),
                args = args.join(", "),
            );
            use_custom_rank(&mut out, from, s, &args);
        }
    }
    Ok(out)
}

/// The Java classes: `(path, source)`, one `<Fn>Batch` per batch, beside the original class.
pub fn java_files(m: &Manifest, api: &PortApi) -> Result<Vec<(String, String)>, String> {
    let native = crate::codegen_ffi::java_native_class(m);
    let mut files = Vec::new();
    for g in java_batches(m, api)? {
        let class = &g.s.class;
        let item = &g.e.params[g.s.item].name;
        let item_java = g.item.java;
        let params: Vec<String> = g
            .fixed
            .iter()
            .map(|(_, n, t)| format!("{} {n}", t.java))
            .collect();
        let native_params: String = g
            .fixed
            .iter()
            .map(|(_, n, t)| format!(", {} {n}", t.java))
            .collect();
        let args: String = g.fixed.iter().map(|(_, n, _)| format!(", {n}")).collect();
        let list = if item_java == "String" {
            format!(
                "\n    /** Copies the items into Rust. */\n    public {class}(java.util.List<String> {item}s) {{\n        this({item}s.toArray(new String[0]));\n    }}\n"
            )
        } else {
            String::new()
        };
        let rank = if rank_body(g.s.f.ret.trim()).is_some() {
            let mut rank_params = params.clone();
            rank_params.push("double min".into());
            format!(
                "\n    /** Indexes of the items whose result is at least {{@code min}}, highest result first. */\n    \
                 public int[] rank({}) {{\n        String[] slot = MojoAnythingError.slot();\n        \
                 int[] out = nRank(handle(){args}, min, slot);\n        MojoAnythingError.check(slot);\n        \
                 java.lang.ref.Reference.reachabilityFence(this);\n        return out;\n    }}\n\n    \
                 private static native int[] nRank(long handle{native_params}, double min, String[] slot);\n",
                rank_params.join(", ")
            )
        } else {
            String::new()
        };
        let strings = g.result.java == "String";
        let run_body = if strings {
            format!(
                "        String[] slot = MojoAnythingError.slot();\n        int[] lens = new int[count];\n        \
                 char[] chars = nRun(handle(){args}, lens, slot);\n        MojoAnythingError.check(slot);\n        \
                 java.lang.ref.Reference.reachabilityFence(this);\n        \
                 // One array from Rust; each result is a slice of it.\n        \
                 String[] out = new String[count];\n        int at = 0;\n        for (int i = 0; i < count; i++) {{\n            \
                 out[i] = new String(chars, at, lens[i]);\n            at += lens[i];\n        }}\n        return out;\n"
            )
        } else {
            format!(
                "        String[] slot = MojoAnythingError.slot();\n        {ret}[] out = nRun(handle(){args}, slot);\n        \
                 MojoAnythingError.check(slot);\n        java.lang.ref.Reference.reachabilityFence(this);\n        return out;\n",
                ret = g.result.java
            )
        };
        let mut src = String::new();
        if !g.package.is_empty() {
            let _ = writeln!(src, "package {};\n", g.package);
        }
        let _ = write!(
            src,
            "import mojoanything.MojoAnythingError;\n\n\
             /**\n * {{@code {name}}} over many {{@code {item}}} values kept in Rust, generated by mojo-anything: built once,\n \
             * then each {{@link #run}} maps them all in one call, on all cores. Safe for concurrent use;\n \
             * close it when done (a Cleaner frees it otherwise).\n */\n\
             public final class {class} implements AutoCloseable {{\n    \
             static {{\n        try {{\n            Class.forName(\"mojoanything.{native}\");\n        }} catch (ClassNotFoundException e) {{\n            \
             throw new ExceptionInInitializerError(e);\n        }}\n    }}\n\n    \
             private static final java.lang.ref.Cleaner CLEANER = java.lang.ref.Cleaner.create();\n\n    \
             /** The Rust handle; freed once, by {{@link #close}} or the Cleaner. */\n    \
             private static final class State implements Runnable {{\n        private long handle;\n\n        \
             State(long handle) {{\n            this.handle = handle;\n        }}\n\n        \
             @Override\n        public synchronized void run() {{\n            if (handle != 0) {{\n                nFree(handle);\n                handle = 0;\n            }}\n        }}\n\n        \
             synchronized long get() {{\n            if (handle == 0) {{\n                throw new IllegalStateException(\"{class} is closed\");\n            }}\n            return handle;\n        }}\n    }}\n\n    \
             private final State state;\n    private final java.lang.ref.Cleaner.Cleanable cleanable;\n    private final int count;\n\n    \
             /** Copies the items into Rust. */\n    public {class}({item_java}[] {item}s) {{\n        \
             state = new State(nNew({item}s));\n        count = {item}s.length;\n        cleanable = CLEANER.register(this, state);\n    }}\n{list}\n    \
             private long handle() {{\n        return state.get();\n    }}\n\n    \
             /** {{@code {name}}}'s result for every item, in order. */\n    public {ret}[] run({params}) {{\n{run_body}    }}\n{rank}\n    \
             /** Frees the items on the Rust side. */\n    @Override\n    public void close() {{\n        cleanable.clean();\n    }}\n\n    \
             private static native long nNew({item_java}[] items);\n\n    \
             private static native void nFree(long handle);\n\n    \
             private static native {native_ret}[] nRun(long handle{native_params}{lens}, String[] slot);\n}}\n",
            name = g.e.name,
            ret = g.result.java,
            params = params.join(", "),
            native_ret = if strings { "char" } else { g.result.java },
            lens = if strings { ", int[] lens" } else { "" },
        );
        let dir = if g.package.is_empty() {
            "java".to_string()
        } else {
            format!("java/{}", g.package.replace('.', "/"))
        };
        files.push((format!("{dir}/{class}.java"), src));
    }
    Ok(files)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ruby_params() {
        assert_eq!(
            split_params("text, sep = \"-,\", max: nil, opts = {a: 1, b: 2}"),
            ["text", "sep = \"-,\"", "max: nil", "opts = {a: 1, b: 2}"]
        );
        assert_eq!(param_name("max: nil"), "max");
        assert_eq!(param_name("*rest"), "rest");
        assert_eq!(param_name("sep = \"-\""), "sep");
    }
}
