//! The C side of the C ABI bridge, shared by the Mojo generator (`codegen_mojo_c`), the
//! recorder and the shadow: how each parameter crosses, prototypes with the original names,
//! the header and the C shadow file.

use std::fmt::Write as _;

use crate::bridge::Manifest;
use crate::ts::exports::{ExportedFn, Param};

/// How a C parameter crosses the bridge.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum CKind {
    Scalar,
    /// `const char *`, NUL-terminated.
    Str,
    /// A `const` byte pointer read for the length in another parameter.
    Bytes,
    /// A byte pointer the function writes, sized by another parameter.
    Buffer,
    /// The length of the buffer parameter at this index.
    Len(usize),
    /// A pointer to one scalar the function may read and write.
    Out,
    /// A struct of scalars, passed by value (`struct:<C name>:<fields>`).
    Struct,
    /// A `char **` whose pointer points into the string or buffer parameter at this index.
    OutPtr(usize),
}

/// A struct of scalar fields that crosses the bridge by value.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CStruct {
    /// The type as C code names it (`AVRational`, `struct point`).
    pub c_name: String,
    /// `(C scalar type, field name)` in declaration order.
    pub fields: Vec<(String, String)>,
}

/// The struct a dialect type stands for (`struct:AVRational:int num,int den`).
pub fn c_struct(ts_type: &str) -> Option<CStruct> {
    let (c_name, fields) = ts_type.strip_prefix("struct:")?.split_once(':')?;
    let fields = fields
        .split(',')
        .map(|f| {
            let (ty, name) = f.trim().rsplit_once(' ')?;
            Some((ty.to_string(), name.to_string()))
        })
        .collect::<Option<Vec<_>>>()?;
    Some(CStruct {
        c_name: c_name.to_string(),
        fields,
    })
}

/// The structs `m`'s functions take or return by value, each once.
pub fn structs(m: &Manifest) -> Vec<CStruct> {
    let mut out: Vec<CStruct> = Vec::new();
    for f in &m.exports {
        for ts in f
            .params
            .iter()
            .map(|p| p.ts_type.as_str())
            .chain([f.returns.as_str()])
        {
            if let Some(s) = c_struct(ts)
                && !out.iter().any(|o| o.c_name == s.c_name)
            {
                out.push(s);
            }
        }
    }
    out
}

/// C definitions of `m`'s structs, for files that do not include the project's headers.
pub fn c_struct_defs(m: &Manifest) -> String {
    let mut out = String::new();
    for s in structs(m) {
        let fields: String = s
            .fields
            .iter()
            .map(|(ty, name)| format!(" {ty} {name};"))
            .collect();
        if s.c_name.starts_with("struct ") {
            let _ = writeln!(out, "{} {{{fields} }};", s.c_name);
        } else {
            let _ = writeln!(out, "typedef struct {{{fields} }} {};", s.c_name);
        }
    }
    out
}

pub fn kind(p: &Param) -> CKind {
    match p.ts_type.as_str() {
        "string" => CKind::Str,
        "bytes" => CKind::Bytes,
        "buffer" => CKind::Buffer,
        "out" => CKind::Out,
        t if t.starts_with("struct:") => CKind::Struct,
        t => {
            if let Some(i) = t.strip_prefix("outptr:").and_then(|i| i.parse().ok()) {
                return CKind::OutPtr(i);
            }
            t.strip_prefix("len:")
                .and_then(|i| i.parse().ok())
                .map_or(CKind::Scalar, CKind::Len)
        }
    }
}

/// The parameter a returned pointer points into (`returns` is `ptr:<index>`).
pub fn returns_into(f: &ExportedFn) -> Option<usize> {
    f.returns.strip_prefix("ptr:").and_then(|i| i.parse().ok())
}

/// Whether recorded results carry what the function wrote through its pointers.
pub fn writes(f: &ExportedFn) -> bool {
    f.params
        .iter()
        .any(|p| matches!(kind(p), CKind::Buffer | CKind::Out | CKind::OutPtr(_)))
}

/// What a pointer type points to, without `const`.
pub fn pointee(c_type: &str) -> String {
    c_type
        .trim_end_matches(['*', ' '])
        .split_whitespace()
        .filter(|w| *w != "const")
        .collect::<Vec<_>>()
        .join(" ")
}

fn native(p: &Param) -> &str {
    p.native_type.as_deref().unwrap_or("int")
}

/// What a `char **` points to (`const char *`).
fn inner(c_type: &str) -> String {
    c_type
        .trim_end()
        .strip_suffix('*')
        .unwrap_or(c_type)
        .trim_end()
        .to_string()
}

/// A C declaration of `name` with type `c_type` (`const uint8_t *in`).
pub fn c_decl(c_type: &str, name: &str) -> String {
    let stars = c_type.matches('*').count();
    let base = c_type.trim_end_matches(['*', ' ']);
    if stars == 0 {
        format!("{base} {name}")
    } else {
        format!("{base} {}{name}", "*".repeat(stars))
    }
}

/// The function's prototype with typedefs resolved to the scalars they stand for, so it
/// compiles without the project's headers.
pub fn c_prototype(f: &ExportedFn, name: &str) -> String {
    let params: Vec<String> = f
        .params
        .iter()
        .map(|p| c_decl(native(p), &p.name))
        .collect();
    let params = if params.is_empty() {
        "void".to_string()
    } else {
        params.join(", ")
    };
    c_decl(
        f.native_return.as_deref().unwrap_or("void"),
        &format!("{name}({params})"),
    )
}

/// `include/<lib>.h`: the prototypes, and the `mojo_anything_` aliases.
pub fn header(m: &Manifest) -> String {
    let guard = format!("{}_H", m.lib_name().to_uppercase());
    let mut out = format!(
        "/* C API of the Mojo port of `{}`, generated by mojo-anything. */\n#ifndef {guard}\n#define {guard}\n\n\
         #include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n#include <sys/types.h>\n\n",
        m.unit
    );
    let defs = c_struct_defs(m);
    if !defs.is_empty() {
        let _ = writeln!(out, "{defs}");
    }
    for f in &m.exports {
        let _ = writeln!(out, "{};", c_prototype(f, &f.name));
    }
    out.push_str("\n/* The same functions under `mojo_anything_` names, for shadow runs. */\n");
    for f in &m.exports {
        let _ = writeln!(
            out,
            "{};",
            c_prototype(f, &format!("mojo_anything_{}", f.name))
        );
    }
    let _ = writeln!(out, "\n#endif /* {guard} */");
    out
}

/// A C expression for the byte length of buffer parameter `i` of `f`.
fn c_len_of(f: &ExportedFn, i: usize) -> String {
    f.params
        .iter()
        .find(|p| kind(p) == CKind::Len(i))
        .map_or_else(
            || "0".to_string(),
            |p| format!("({0} > 0 ? (size_t){0} : 0)", p.name),
        )
}

/// A C shadow file: each function calls the original (compiled renamed) and the Mojo port.
/// The port gets copies of what the function writes, so the caller sees the original's writes
/// once, and both are compared.
pub fn shadow_c(m: &Manifest) -> String {
    let mut out = String::from(
        "/* Generated by mojo-anything: runs the C original and the Mojo port side by side.\n\
         *\n * Build: compile the original sources with `-D<name>=<name>__original` for each function\n\
         * below (see `shadow/flags.txt`), then link this file, those objects and the Mojo unit's\n\
         * shadow library (`lib<name>_shadow.so` from `mojo-anything build`), which exports only the\n\
         * `mojo_anything_` names. Callers get the original's results; differences are counted and reported\n\
         * on stderr.\n */\n\
         #include <stdbool.h>\n#include <stddef.h>\n#include <stdint.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n#include <sys/types.h>\n\n\
         long mojo_anything_shadow_calls = 0;\nlong mojo_anything_shadow_mismatches = 0;\n\n",
    );
    let defs = c_struct_defs(m);
    if !defs.is_empty() {
        let _ = writeln!(out, "{defs}");
    }
    for f in &m.exports {
        let prototype = c_prototype(f, &f.name);
        let _ = writeln!(
            out,
            "{};\n{};\n",
            c_prototype(f, &format!("{}__original", f.name)),
            c_prototype(f, &format!("mojo_anything_{}", f.name))
        );
        let mut before = String::new();
        let mut after = String::new();
        let mut port_args = Vec::new();
        for (i, p) in f.params.iter().enumerate() {
            match kind(p) {
                CKind::Buffer => {
                    let len = c_len_of(f, i);
                    let _ = writeln!(
                        before,
                        "    size_t len_{n} = {len};\n    unsigned char *copy_{n} = len_{n} ? malloc(len_{n}) : NULL;\n    \
                         if (copy_{n}) memcpy(copy_{n}, {n}, len_{n});",
                        n = p.name
                    );
                    let _ = writeln!(
                        after,
                        "    if (copy_{n} && memcmp(copy_{n}, {n}, len_{n}) != 0) differ = 1;\n    free(copy_{n});",
                        n = p.name
                    );
                    port_args.push(format!("({})copy_{}", native(p), p.name));
                }
                CKind::Out => {
                    let ty = pointee(native(p));
                    let _ = writeln!(before, "    {ty} copy_{n} = {n} ? *{n} : 0;", n = p.name);
                    let _ = writeln!(
                        after,
                        "    if ({n} && memcmp(&copy_{n}, {n}, sizeof copy_{n}) != 0) differ = 1;",
                        n = p.name
                    );
                    port_args.push(format!("{n} ? &copy_{n} : NULL", n = p.name));
                }
                CKind::OutPtr(t) => {
                    let target = &f.params[t];
                    let base = if kind(target) == CKind::Buffer {
                        format!("copy_{}", target.name)
                    } else {
                        target.name.clone()
                    };
                    let _ = writeln!(
                        before,
                        "    {} = {n} ? *{n} : NULL;",
                        c_decl(&inner(native(p)), &format!("copy_{}", p.name)),
                        n = p.name
                    );
                    let _ = writeln!(
                        after,
                        "    if ({n} && ((*{n} == NULL) != (copy_{n} == NULL) || (*{n} && (const char *)*{n} - (const char *){t} != (const char *)copy_{n} - (const char *){base}))) differ = 1;",
                        n = p.name,
                        t = target.name
                    );
                    port_args.push(format!("{n} ? &copy_{n} : NULL", n = p.name));
                }
                _ => port_args.push(p.name.clone()),
            }
        }
        let args = f
            .params
            .iter()
            .map(|p| p.name.as_str())
            .collect::<Vec<_>>()
            .join(", ");
        let port_args = port_args.join(", ");
        let void = f.native_return.as_deref() == Some("void");
        let ret = f.native_return.as_deref().unwrap_or("int");
        let compare_ret = match returns_into(f) {
            _ if void => String::new(),
            Some(i) => {
                let target = &f.params[i];
                let base = if kind(target) == CKind::Buffer {
                    format!("(const char *)copy_{}", target.name)
                } else {
                    format!("(const char *){}", target.name)
                };
                format!(
                    "    if ((expected == NULL) != (actual == NULL) || (expected && (const char *)expected - (const char *){} != (const char *)actual - {base})) differ = 1;\n",
                    target.name
                )
            }
            None => match c_struct(&f.returns) {
                Some(s) => s
                    .fields
                    .iter()
                    .map(|(_, n)| {
                        format!(
                            "    if (memcmp(&expected.{n}, &actual.{n}, sizeof expected.{n}) != 0) differ = 1;\n"
                        )
                    })
                    .collect(),
                None => {
                    "    if (memcmp(&expected, &actual, sizeof expected) != 0) differ = 1;\n".into()
                }
            },
        };
        let (call_original, call_port, give) = if void {
            (
                format!("    {}__original({args});\n", f.name),
                format!("    mojo_anything_{}({port_args});\n", f.name),
                String::new(),
            )
        } else {
            (
                format!(
                    "    {} = {}__original({args});\n",
                    c_decl(ret, "expected"),
                    f.name
                ),
                format!(
                    "    {} = mojo_anything_{}({port_args});\n",
                    c_decl(ret, "actual"),
                    f.name
                ),
                "    return expected;\n".to_string(),
            )
        };
        let _ = writeln!(
            out,
            "{prototype} {{\n    int differ = 0;\n{before}{call_original}{call_port}{compare_ret}{after}\
             \x20   mojo_anything_shadow_calls++;\n    if (differ) {{\n\
             \x20       mojo_anything_shadow_mismatches++;\n        if (mojo_anything_shadow_mismatches <= 10)\n\
             \x20           fprintf(stderr, \"[mojo-anything] mismatch in {name}\\n\");\n    }}\n{give}}}\n",
            name = f.name
        );
    }
    out
}

/// `-D` flags that rename the originals for a shadow build.
pub fn shadow_flags(m: &Manifest) -> String {
    m.exports
        .iter()
        .map(|f| format!("-D{0}={0}__original", f.name))
        .collect::<Vec<_>>()
        .join(" ")
        + "\n"
}
