//! The port's API: `port.rs` stubs from the source signatures, and the functions and classes a
//! `port.rs` declares, which the Java and Kotlin JNI layers are generated from (Mojo ports are
//! read by `codegen_mojo::parse_port_mojo` into the same [`PortApi`]).
//!
//! The binding layer follows the port, not the source: change a port's types, run
//! `mojo-anything refresh`, and the bindings follow.

use std::fmt::Write as _;

use crate::bridge::{Manifest, RType, param_type, snake_case};
use crate::ts::exports::ExportedFn;

/// A port function, as declared in `port.rs`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortFn {
    pub js_name: String,
    pub rust_name: String,
    pub params: Vec<(String, String)>,
    /// The success type, `()` for none.
    pub ret: String,
    /// Returns `Result<T, String>`; an `Err` becomes a thrown JS error.
    pub fallible: bool,
    pub is_async: bool,
}

/// A port class: a struct with `new` and methods taking `&self` or `&mut self`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortClass {
    pub js_name: String,
    pub rust_name: String,
    pub constructor: PortFn,
    pub methods: Vec<(PortFn, bool)>,
}

/// What `port.rs` offers to JS. `methods` pairs each method with whether it takes `&mut self`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PortApi {
    pub functions: Vec<PortFn>,
    pub classes: Vec<PortClass>,
    /// Every `pub struct` of `port.rs` (a batch uses `<Name>Index` when the port defines one).
    pub structs: Vec<String>,
    /// The structs whose `impl` has a `pub fn rank` (an index that ranks by itself).
    pub ranked: Vec<String>,
}

impl PortApi {
    /// Every function and method, for dependency and wire checks.
    pub fn all(&self) -> impl Iterator<Item = &PortFn> {
        self.functions.iter().chain(
            self.classes.iter().flat_map(|c| {
                std::iter::once(&c.constructor).chain(c.methods.iter().map(|(m, _)| m))
            }),
        )
    }

    pub fn needs_json(&self) -> bool {
        self.all().any(|f| {
            wire(&f.ret) == Wire::Json || f.params.iter().any(|(_, t)| wire(t) == Wire::Json)
        })
    }
}

/// How a Rust type crosses the bridge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wire {
    Native,
    Json,
    Units,
}

pub fn wire(ty: &str) -> Wire {
    let ty: String = ty.chars().filter(|c| !c.is_whitespace()).collect();
    match ty.as_str() {
        "String" | "f64" | "i64" | "bool" | "()" | "Vec<String>" | "Vec<f64>" | "Vec<i64>"
        | "Option<String>" | "Option<f64>" | "Option<i64>" | "Option<bool>" => Wire::Native,
        "Vec<u16>" => Wire::Units,
        _ => Wire::Json,
    }
}

// ---- port.rs stubs ---------------------------------------------------------------------------

/// `port.rs` with one stub per export, typed from the TS signature.
pub fn port_rs(m: &Manifest) -> String {
    let mut out = format!(
        "//! The Rust port of `{}`.\n//!\n\
         //! Replace each `unimplemented!` with the port of the source function. Return `Err` where\n\
         //! the source throws or raises: the caller gets an error there too. After changing a\n\
         //! signature, run `mojo-anything refresh` to regenerate the bindings. `mojo-anything diff` checks\n\
         //! behavior against what the source recorded.\n\n\
         #![forbid(unsafe_code)]\n",
        m.unit
    );
    for f in &m.exports {
        let params = f
            .params
            .iter()
            .map(|p| format!("{}: {}", snake_case(&p.name), port_param_type(m, p).rust()))
            .collect::<Vec<_>>()
            .join(", ");
        let ret = match RType::from_ts(&f.returns) {
            RType::Unit => "()".to_string(),
            t => t.rust(),
        };
        let names: Vec<String> = f.params.iter().map(|p| snake_case(&p.name)).collect();
        let asyncness = if is_async(f) { "async " } else { "" };
        out.push('\n');
        let _ = writeln!(out, "/// Port of `{}` (`{}:{}`).", f.name, f.file, f.line);
        for p in f.params.iter().filter(|p| p.default.is_some()) {
            let _ = writeln!(
                out,
                "///\n/// `{}` defaults to `{}` in the source.",
                snake_case(&p.name),
                p.default.as_deref().unwrap_or_default()
            );
        }
        let _ = writeln!(
            out,
            "pub {asyncness}fn {}({params}) -> Result<{ret}, String> {{",
            snake_case(&f.name)
        );
        match names.len() {
            0 => {}
            1 => {
                let _ = writeln!(out, "    let _ = &{};", names[0]);
            }
            _ => {
                let refs: Vec<String> = names.iter().map(|n| format!("&{n}")).collect();
                let _ = writeln!(out, "    let _ = ({});", refs.join(", "));
            }
        }
        let _ = writeln!(
            out,
            "    unimplemented!(\"port `{}` from {}\")",
            f.name, f.file
        );
        out.push_str("}\n");
    }
    for c in &m.classes {
        let _ = writeln!(
            out,
            "\n/// Port of class `{}` (`{}:{}`): holds the instance state.",
            c.name, c.file, c.line
        );
        let _ = writeln!(out, "pub struct {} {{}}\n", c.name);
        let _ = writeln!(out, "impl {} {{", c.name);
        let ctor = stub_params(m, &c.constructor);
        let _ = writeln!(
            out,
            "    /// Port of `{}` constructor (`{}:{}`).",
            c.name, c.file, c.line
        );
        let _ = writeln!(out, "    pub fn new({}) -> Result<Self, String> {{", ctor.0);
        let _ = write!(out, "{}", ctor.1);
        let _ = writeln!(
            out,
            "        unimplemented!(\"port the `{}` constructor\")\n    }}",
            c.name
        );
        for f in &c.methods {
            let (params, unused) = stub_params(m, &f.params);
            let ret = match RType::from_ts(&f.returns) {
                RType::Unit => "()".to_string(),
                t => t.rust(),
            };
            let receiver = if params.is_empty() {
                "&mut self".to_string()
            } else {
                format!("&mut self, {params}")
            };
            let _ = writeln!(
                out,
                "\n    /// Port of `{}.{}` (`{}:{}`).",
                c.name, f.name, f.file, f.line
            );
            let _ = writeln!(
                out,
                "    pub fn {}({receiver}) -> Result<{ret}, String> {{",
                snake_case(&f.name)
            );
            let _ = write!(out, "{unused}");
            let _ = writeln!(
                out,
                "        unimplemented!(\"port `{}.{}`\")\n    }}",
                c.name, f.name
            );
        }
        out.push_str("}\n");
    }
    out
}

/// A parameter's type in the port. Python parameters with a literal default (`sep="-"`) are
/// plain values: the binding fills in the default, and an explicit `None` stays an error, as in Python.
fn port_param_type(m: &Manifest, p: &crate::ts::exports::Param) -> RType {
    if matches!(
        m.language,
        crate::lang::Lang::Python | crate::lang::Lang::Ruby
    ) && crate::codegen_py::has_literal_default(p)
    {
        RType::from_ts(&p.ts_type)
    } else {
        param_type(p)
    }
}

/// Parameters of a method stub, and a line marking them used.
fn stub_params(m: &Manifest, params: &[crate::ts::exports::Param]) -> (String, String) {
    let list = params
        .iter()
        .map(|p| format!("{}: {}", snake_case(&p.name), port_param_type(m, p).rust()))
        .collect::<Vec<_>>()
        .join(", ");
    let names: Vec<String> = params
        .iter()
        .map(|p| format!("&{}", snake_case(&p.name)))
        .collect();
    let unused = match names.len() {
        0 => String::new(),
        1 => format!("        let _ = {};\n", names[0]),
        _ => format!("        let _ = ({});\n", names.join(", ")),
    };
    (list, unused)
}

pub fn is_async(f: &ExportedFn) -> bool {
    f.is_async || f.returns.trim().starts_with("Promise<")
}

// ---- reading port.rs -------------------------------------------------------------------------

/// The functions and classes `port.rs` offers. A function's JS name comes from its
/// `/// Port of `name`` doc line (else its Rust name in camelCase); a class is a `pub struct`
/// documented `/// Port of class `Name``, with an `impl` holding `new` and its methods.
pub fn parse_port(source: &str) -> PortApi {
    let lines: Vec<&str> = source.lines().collect();
    let mut api = PortApi {
        functions: functions_in(&lines, ""),
        classes: Vec::new(),
        structs: lines
            .iter()
            .filter_map(|l| l.trim_start().strip_prefix("pub struct "))
            .map(|r| {
                r.chars()
                    .take_while(|c| c.is_alphanumeric() || *c == '_')
                    .collect()
            })
            .collect(),
        ranked: Vec::new(),
    };
    // `impl Name {` ... `}` at column 0: does it define `pub fn rank`?
    for (i, line) in lines.iter().enumerate() {
        let Some(rest) = line.strip_prefix("impl ") else {
            continue;
        };
        let name: String = rest
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        let body = lines[i + 1..].iter().take_while(|l| !l.starts_with('}'));
        if body
            .into_iter()
            .any(|l| l.trim_start().starts_with("pub fn rank("))
        {
            api.ranked.push(name);
        }
    }
    for (i, line) in lines.iter().enumerate() {
        let Some(rest) = line.strip_prefix("pub struct ") else {
            continue;
        };
        let rust_name: String = rest
            .chars()
            .take_while(|c| c.is_alphanumeric() || *c == '_')
            .collect();
        let Some(js_name) = doc_name(&lines[..i], "Port of class `") else {
            continue;
        };
        // The `impl Name {` block, up to its closing `}` at column 0.
        let Some(start) = lines
            .iter()
            .position(|l| l.trim_end() == format!("impl {rust_name} {{"))
        else {
            continue;
        };
        let end = lines[start..]
            .iter()
            .position(|l| *l == "}")
            .map_or(lines.len(), |e| start + e);
        let block = &lines[start + 1..end];
        let mut constructor = None;
        let mut methods = Vec::new();
        for f in functions_in(block, "    ") {
            if f.rust_name == "new" {
                constructor = Some(f);
            } else {
                let signature_line = block
                    .iter()
                    .find(|l| l.contains(&format!("fn {}(", f.rust_name)))
                    .copied()
                    .unwrap_or("");
                let block_text = block.join("\n");
                let mutable = signature_line.contains("&mut self") || {
                    let at = block_text
                        .find(&format!("fn {}(", f.rust_name))
                        .unwrap_or(0);
                    block_text[at..]
                        .split('{')
                        .next()
                        .unwrap_or("")
                        .contains("&mut self")
                };
                methods.push((f, mutable));
            }
        }
        if let Some(constructor) = constructor {
            api.classes.push(PortClass {
                js_name,
                rust_name,
                constructor,
                methods,
            });
        }
    }
    api
}

fn doc_name(before: &[&str], prefix: &str) -> Option<String> {
    before
        .iter()
        .rev()
        .take_while(|l| l.trim_start().starts_with("///") || l.trim_start().starts_with("#["))
        .find_map(|l| {
            let doc = l.trim_start().strip_prefix("///")?.trim();
            let rest = doc.strip_prefix(prefix)?;
            Some(rest.split('`').next()?.to_string())
        })
}

/// `pub fn` items at one indentation level. In an `impl`, `Port of `Class.method`` names the
/// method `method`.
fn functions_in(lines: &[&str], indent: &str) -> Vec<PortFn> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i].strip_prefix(indent).unwrap_or("");
        let (is_async, rest) = if let Some(rest) = line.strip_prefix("pub async fn ") {
            (true, rest)
        } else if let Some(rest) = line.strip_prefix("pub fn ") {
            (false, rest)
        } else {
            i += 1;
            continue;
        };
        // The signature runs to the `{` that opens the body, possibly over several lines.
        let mut signature = rest.to_string();
        let mut j = i;
        while !balanced_open_brace(&signature) && j + 1 < lines.len() {
            j += 1;
            signature.push(' ');
            signature.push_str(lines[j].trim());
        }
        let js_name = doc_name(&lines[..i], "Port of `")
            .map(|n| n.rsplit('.').next().unwrap_or(&n).to_string());
        if let Some(f) = parse_signature(&signature, is_async, js_name) {
            out.push(f);
        }
        i = j + 1;
    }
    out
}

/// Whether the text reaches the body's `{` outside parentheses and angle brackets.
fn balanced_open_brace(text: &str) -> bool {
    let mut depth = 0i32;
    let mut previous = ' ';
    for c in text.chars() {
        let arrow = c == '>' && previous == '-';
        previous = c;
        match c {
            '(' | '<' | '[' => depth += 1,
            // `->` is not a closing bracket.
            '>' if arrow => {}
            ')' | '>' | ']' => depth -= 1,
            '{' if depth == 0 => return true,
            _ => {}
        }
    }
    false
}

fn parse_signature(signature: &str, is_async: bool, js_name: Option<String>) -> Option<PortFn> {
    let open = signature.find('(')?;
    let rust_name = signature[..open].trim().to_string();
    let mut depth = 0i32;
    let mut close = None;
    for (i, c) in signature.char_indices().skip(open) {
        match c {
            '(' | '<' | '[' => depth += 1,
            ')' | '>' | ']' => {
                depth -= 1;
                if depth == 0 && c == ')' {
                    close = Some(i);
                    break;
                }
            }
            _ => {}
        }
    }
    let close = close?;
    let params = split_top(&signature[open + 1..close])
        .into_iter()
        .filter(|p| !p.trim().is_empty())
        .filter_map(|p| {
            let (name, ty) = p.split_once(':')?;
            Some((
                name.trim().trim_start_matches("mut ").to_string(),
                ty.trim().to_string(),
            ))
        })
        .collect();
    let after = &signature[close + 1..];
    let body = after.find('{').unwrap_or(after.len());
    let ret_text = after[..body].trim();
    let ret_text = ret_text.strip_prefix("->").map_or("()", str::trim);
    let (ret, fallible) = match ret_text
        .strip_prefix("Result<")
        .and_then(|r| r.strip_suffix('>'))
    {
        Some(inner) => (
            split_top(inner)
                .first()
                .map_or("()", |t| t.trim())
                .to_string(),
            true,
        ),
        None => (ret_text.to_string(), false),
    };
    Some(PortFn {
        js_name: js_name.unwrap_or_else(|| camel_case(&rust_name)),
        rust_name,
        params,
        ret,
        fallible,
        is_async,
    })
}

fn split_top(text: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut start = 0;
    for (i, c) in text.char_indices() {
        match c {
            '(' | '<' | '[' => depth += 1,
            ')' | '>' | ']' => depth -= 1,
            ',' if depth == 0 => {
                out.push(&text[start..i]);
                start = i + 1;
            }
            _ => {}
        }
    }
    out.push(&text[start..]);
    out
}

fn camel_case(name: &str) -> String {
    let name = name.trim_start_matches("r#");
    let mut out = String::new();
    let mut upper = false;
    for c in name.chars() {
        if c == '_' {
            upper = true;
        } else if upper {
            out.extend(c.to_uppercase());
            upper = false;
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_port_signatures() {
        let source = "//! doc\n\n#![forbid(unsafe_code)]\n\n/// Port of `fuzzyScore` (`a.ts:1`).\n\
            pub fn fuzzy_score(query: String, text: String) -> Result<f64, String> {\n    Ok(1.0)\n}\n\n\
            /// Port of `load` (`a.ts:9`).\npub async fn load(\n    path: Option<String>,\n    data: Vec<serde_json::Value>,\n) -> Result<serde_json::Value, String> {\n    todo!()\n}\n\n\
            fn helper(x: Vec<u8>) -> u8 { 0 }\n\npub fn plain_name(a: f64) -> Vec<u16> {\n    vec![]\n}\n";
        let fns = parse_port(source).functions;
        assert_eq!(fns.len(), 3);
        assert_eq!(fns[0].js_name, "fuzzyScore");
        assert_eq!(
            fns[0].params,
            [
                ("query".into(), "String".into()),
                ("text".into(), "String".into())
            ]
        );
        assert_eq!(
            (fns[0].ret.as_str(), fns[0].fallible, fns[0].is_async),
            ("f64", true, false)
        );
        assert_eq!(fns[1].params[1].1, "Vec<serde_json::Value>");
        assert_eq!(
            (fns[1].ret.as_str(), fns[1].is_async),
            ("serde_json::Value", true)
        );
        assert_eq!(
            (
                fns[2].js_name.as_str(),
                fns[2].ret.as_str(),
                fns[2].fallible
            ),
            ("plainName", "Vec<u16>", false)
        );
    }

    #[test]
    fn picks_wires() {
        assert_eq!(wire("Vec<String>"), Wire::Native);
        assert_eq!(wire("Option < f64 >"), Wire::Native);
        assert_eq!(wire("Vec<serde_json::Value>"), Wire::Json);
        assert_eq!(wire("Vec<bool>"), Wire::Json);
        assert_eq!(wire("Vec<u16>"), Wire::Units);
    }
}
