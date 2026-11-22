//! Mojo ports: `port.mojo` stubs typed from the source signatures, and reading the port back to
//! learn which functions it offers.
//!
//! The reader is line based: it reads top-level `def` signatures only, never bodies, so it needs
//! no Mojo parser. Helpers are private by Mojo convention: a leading underscore keeps a function
//! out of the bridged API.

use std::fmt::Write as _;

use crate::bridge::{Manifest, RType, param_type, snake_case};
use crate::codegen::{PortApi, PortFn};

/// Names Mojo 1.2 rejects as parameter or function names (checked by building a probe), and
/// the type names a parameter would shadow.
const MOJO_RESERVED: &[&str] = &[
    "match",
    "case",
    "out",
    "var",
    "mut",
    "ref",
    "read",
    "deinit",
    "comptime",
    "fn",
    "struct",
    "trait",
    "Self",
    "async",
    "await",
    "yield",
    "imm",
    "Int",
    "String",
    "List",
    "Optional",
    "Float64",
    "Bool",
    "PyNum",
    "PythonObject",
    "Python",
    // Python's keywords, which Mojo keeps; only C names can be spelt like them.
    "False",
    "None",
    "True",
    "and",
    "as",
    "assert",
    "break",
    "class",
    "continue",
    "def",
    "del",
    "elif",
    "else",
    "except",
    "finally",
    "for",
    "from",
    "global",
    "if",
    "import",
    "in",
    "is",
    "lambda",
    "nonlocal",
    "not",
    "or",
    "pass",
    "raise",
    "return",
    "try",
    "while",
    "with",
];

/// A source name as a Mojo identifier: snake case, with `_` after a Mojo keyword (`out_`).
pub fn mojo_ident(name: &str) -> String {
    let s = snake_case(name);
    mojo_escape(s.strip_prefix("r#").unwrap_or(&s))
}

/// A name kept as it is, with `_` after a Mojo keyword (`out_`): for C names.
pub fn mojo_escape(name: &str) -> String {
    if MOJO_RESERVED.contains(&name) {
        format!("{name}_")
    } else {
        name.to_string()
    }
}

/// The text every stub raises, which `gate` counts to find functions still to port.
pub const STUB_MARK: &str = "not ported: ";

/// `json.mojo`, the JSON reader and writer emitted into units with structured values.
pub const JSON_MOJO: &str = include_str!("mojo/json.mojo");

/// The Mojo type of a port parameter.
fn param_mojo(m: &Manifest, p: &crate::ts::exports::Param) -> String {
    let t = if crate::codegen_py::has_literal_default(p) {
        RType::from_ts(&p.ts_type)
    } else {
        param_type(p)
    };
    t.mojo(m.language)
}

fn ret_mojo(m: &Manifest, returns: &str) -> Option<String> {
    match RType::from_ts(returns) {
        RType::Unit => None,
        t => Some(t.mojo(m.language)),
    }
}

/// `port.mojo` with one stub per export.
pub fn port_mojo(m: &Manifest) -> String {
    let mut body = String::new();
    for f in &m.exports {
        let params: Vec<String> = f
            .params
            .iter()
            .map(|p| format!("{}: {}", mojo_ident(&p.name), param_mojo(m, p)))
            .collect();
        let ret = ret_mojo(m, &f.returns)
            .map(|t| format!(" -> {t}"))
            .unwrap_or_default();
        let _ = writeln!(
            body,
            "\n\n# Port of `{}` (`{}:{}`).",
            f.name, f.file, f.line
        );
        for p in f.params.iter().filter(|p| p.default.is_some()) {
            let _ = writeln!(
                body,
                "# `{}` defaults to `{}` in the source.",
                mojo_ident(&p.name),
                p.default.as_deref().unwrap_or_default()
            );
        }
        let _ = writeln!(
            body,
            "def {}({}) raises{ret}:\n    raise Error(\"{STUB_MARK}{}\")",
            mojo_ident(&f.name),
            params.join(", "),
            f.name
        );
    }
    for c in &m.classes {
        let _ = writeln!(
            body,
            "\n\n# Class `{}` (`{}:{}`) is not bridged to Mojo yet; it stays in the source.",
            c.name, c.file, c.line
        );
    }
    let mut out = format!(
        "# The Mojo port of `{}`.\n#\n\
         # Replace each `raise Error(\"{STUB_MARK}...\")` with the port of the source function.\n\
         # Raise `Error(\"ValueError: message\")` (any builtin exception name) where the source\n\
         # raises: the caller gets that exception. After changing a signature, run\n\
         # `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.\n",
        m.unit
    );
    if body.contains("PythonObject") {
        out.push_str("\nfrom std.python import Python, PythonObject\n");
    }
    if body.contains("PyNum") {
        out.push_str("\nfrom py_num import PyNum\n");
    }
    out.push_str(&body);
    out
}

/// The public functions `port.mojo` defines.
pub fn parse_port_mojo(source: &str) -> PortApi {
    let lines: Vec<&str> = source.lines().collect();
    let mut api = PortApi::default();
    let mut i = 0;
    while i < lines.len() {
        let line = lines[i];
        if let Some(name) = line.strip_prefix("struct ") {
            let name: String = name
                .chars()
                .take_while(|c| c.is_alphanumeric() || *c == '_')
                .collect();
            if !name.starts_with('_') {
                api.structs.push(name);
            }
        }
        let Some(rest) = line.strip_prefix("def ") else {
            i += 1;
            continue;
        };
        // The signature runs to the `:` that ends it, possibly over several lines.
        let mut signature = rest.trim_end().to_string();
        let mut j = i;
        while !signature_ends(&signature) && j + 1 < lines.len() {
            j += 1;
            signature.push(' ');
            signature.push_str(lines[j].trim());
        }
        let js_name = comment_name(&lines[..i]);
        if let Some(f) = parse_def(&signature, js_name)
            && !f.rust_name.starts_with('_')
        {
            api.functions.push(f);
        }
        i = j + 1;
    }
    api
}

/// The name in a `# Port of `name`` comment right above a `def`.
fn comment_name(before: &[&str]) -> Option<String> {
    before
        .iter()
        .rev()
        .take_while(|l| l.trim_start().starts_with('#') || l.trim_start().starts_with('@'))
        .find_map(|l| {
            let rest = l.trim_start().strip_prefix("# Port of `")?;
            Some(rest.split('`').next()?.to_string())
        })
}

/// Whether a signature is complete: brackets closed and ending in `:`.
fn signature_ends(text: &str) -> bool {
    depth(text) == 0 && text.trim_end().ends_with(':')
}

fn depth(text: &str) -> i32 {
    text.chars().fold(0, |d, c| match c {
        '(' | '[' => d + 1,
        ')' | ']' => d - 1,
        _ => d,
    })
}

/// Splits on `,` outside brackets.
fn split_top(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut d = 0i32;
    let mut current = String::new();
    for c in text.chars() {
        match c {
            '(' | '[' => d += 1,
            ')' | ']' => d -= 1,
            ',' if d == 0 => {
                out.push(std::mem::take(&mut current));
                continue;
            }
            _ => {}
        }
        current.push(c);
    }
    out.push(current);
    out.into_iter()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .collect()
}

/// `name(params) raises -> Ret:` into a `PortFn`.
fn parse_def(signature: &str, js_name: Option<String>) -> Option<PortFn> {
    let open = signature.find('(')?;
    let name = signature[..open].trim();
    // Compile-time parameters (`def f[T: ...](...)`) are not part of a bridged API.
    if name.contains('[') {
        return None;
    }
    let mut d = 0i32;
    let close = signature[open..].char_indices().find_map(|(k, c)| {
        match c {
            '(' | '[' => d += 1,
            ')' | ']' => d -= 1,
            _ => {}
        }
        (d == 0 && c == ')').then_some(open + k)
    })?;
    let params = split_top(&signature[open + 1..close])
        .into_iter()
        .filter_map(|p| {
            let p = p.split('=').next().unwrap_or("").trim();
            let p = ["var ", "mut ", "read ", "ref ", "owned ", "out "]
                .iter()
                .find_map(|k| p.strip_prefix(k))
                .unwrap_or(p);
            let (n, t) = p.split_once(':')?;
            Some((n.trim().to_string(), t.trim().to_string()))
        })
        .collect();
    let tail = signature[close + 1..].trim().trim_end_matches(':').trim();
    let fallible = tail.starts_with("raises");
    let ret = tail
        .split_once("->")
        .map_or("None".to_string(), |(_, r)| r.trim().to_string());
    Some(PortFn {
        js_name: js_name.unwrap_or_else(|| name.to_string()),
        rust_name: name.to_string(),
        params,
        ret,
        fallible,
        is_async: false,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn manifest() -> Manifest {
        serde_json::from_str(
            r#"{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "src/colorsys.py",
                "language": "python", "kind": "mojo-py", "crate_name": "colorsys-mojo",
                "exports": [{"name": "rgb_to_yiq", "file": "src/colorsys.py", "line": 40,
                  "params": [
                    {"name": "r", "ts_type": "number", "optional": false, "rest": false},
                    {"name": "g", "ts_type": "number", "optional": false, "rest": false},
                    {"name": "b", "ts_type": "number", "optional": false, "rest": false}],
                  "returns": "unknown", "is_async": false, "is_generator": false,
                  "type_params": [], "uses_instanceof": false}]}"#,
        )
        .unwrap()
    }

    #[test]
    fn stubs_round_trip() {
        let src = port_mojo(&manifest());
        assert!(src.contains("from py_num import PyNum"), "{src}");
        assert!(
            src.contains(&format!("raise Error(\"{STUB_MARK}rgb_to_yiq\")")),
            "{src}"
        );
        let api = parse_port_mojo(&src);
        assert_eq!(api.functions.len(), 1, "{src}");
        let f = &api.functions[0];
        assert_eq!(f.rust_name, "rgb_to_yiq");
        assert_eq!(f.js_name, "rgb_to_yiq");
        let p = |n: &str| (n.to_string(), "PyNum".to_string());
        assert_eq!(f.params, vec![p("r"), p("g"), p("b")]);
        assert_eq!(f.ret, "PythonObject");
        assert!(f.fallible);
    }

    #[test]
    fn private_helpers_are_not_api() {
        let api = parse_port_mojo(
            "def _clamp(x: Float64) -> Float64:\n    return x\n\n\ndef f() raises:\n    pass\n",
        );
        let names: Vec<&str> = api.functions.iter().map(|f| f.rust_name.as_str()).collect();
        assert_eq!(names, ["f"]);
        assert_eq!(api.functions[0].ret, "None");
    }

    #[test]
    fn multiline_signature() {
        let api = parse_port_mojo(
            "def f(\n    a: List[Int],\n    b: Optional[String] = None,\n) -> Bool:\n    return True\n",
        );
        let f = &api.functions[0];
        assert_eq!(
            f.params,
            vec![
                ("a".to_string(), "List[Int]".to_string()),
                ("b".to_string(), "Optional[String]".to_string())
            ]
        );
        assert_eq!(f.ret, "Bool");
        assert!(!f.fallible);
    }

    #[test]
    fn nested_defs_are_not_api() {
        let api = parse_port_mojo("struct S:\n    def m(self) -> Int:\n        return 1\n");
        assert!(api.functions.is_empty());
        assert_eq!(api.structs, ["S"]);
    }
}
