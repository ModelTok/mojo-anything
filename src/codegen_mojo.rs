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

/// The Mojo type for a Go source type; anything structured crosses as `JsonValue`.
pub fn go_mojo_type(go: &str) -> String {
    match go.trim() {
        "int" => "Int",
        "int8" => "Int8",
        "int16" => "Int16",
        "int32" | "rune" => "Int32",
        "int64" => "Int64",
        "uint" => "UInt",
        "uint8" | "byte" => "UInt8",
        "uint16" => "UInt16",
        "uint32" => "UInt32",
        "uint64" | "uintptr" => "UInt64",
        "float32" => "Float32",
        "float64" => "Float64",
        "string" => "String",
        "bool" => "Bool",
        "[]string" => "List[String]",
        _ => "JsonValue",
    }
    .to_string()
}

/// The Mojo types the typed C path carries: scalars and strings.
const TYPED: &[&str] = &[
    "Int", "Int8", "Int16", "Int32", "Int64", "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "Float32", "Float64", "Bool", "String",
];

/// Whether a Go port function gets a typed `mojo_anything_t_<name>` export: every parameter and
/// the result are scalars or strings.
pub fn go_typed_eligible(f: &PortFn) -> bool {
    f.params.iter().all(|(_, t)| TYPED.contains(&t.as_str()))
        && (f.ret == "None" || TYPED.contains(&f.ret.as_str()))
}

/// Whether a unit needs `json.mojo`: a `JsonValue` in its API, or a function reached through the
/// JSON dispatcher (every Ruby function; Go functions that are not typed-eligible).
pub fn needs_json_mojo(lang: crate::lang::Lang, api: &PortApi) -> bool {
    use crate::lang::Lang;
    let json_in_api = api.all().any(|f| {
        f.ret.contains("JsonValue") || f.params.iter().any(|(_, t)| t.contains("JsonValue"))
    });
    json_in_api
        || match lang {
            Lang::Ruby => true,
            Lang::Go => !api.functions.iter().all(go_typed_eligible),
            _ => false,
        }
}

/// A Go result list as written in the manifest (`(T, error)`): its Mojo type, `None` for none.
/// Several results cross as one JSON array.
fn go_ret_mojo(native: &str) -> Option<String> {
    let inner = native.trim().trim_start_matches('(').trim_end_matches(')');
    let results: Vec<&str> = inner
        .split(',')
        .map(str::trim)
        .filter(|r| !r.is_empty() && *r != "error")
        .collect();
    match results.as_slice() {
        [] => None,
        [one] => Some(go_mojo_type(one)),
        _ => Some("JsonValue".into()),
    }
}

/// The Mojo type for a Java type whose width matters: `int` is `Int32`, `long` `Int64`, arrays
/// and lists of them lists. `None` for the rest, which take the general mapping (`String`,
/// `JsonValue` for maps, `Optional` for `Optional<T>`).
pub fn java_mojo_type(java: &str) -> Option<String> {
    let t = java.trim();
    if let Some(item) = t.strip_suffix("[]") {
        return java_mojo_type(item).map(|i| format!("List[{i}]"));
    }
    if let Some((head, rest)) = t.split_once('<') {
        let head = head.trim().rsplit('.').next().unwrap_or(head);
        if matches!(
            head,
            "List" | "ArrayList" | "Collection" | "Iterable" | "LinkedList"
        ) {
            return java_mojo_type(rest.strip_suffix('>')?).map(|i| format!("List[{i}]"));
        }
        return None;
    }
    Some(
        match t {
            "int" | "Integer" => "Int32",
            "long" | "Long" => "Int64",
            "short" | "Short" => "Int16",
            "byte" | "Byte" => "Int8",
            "double" | "Double" => "Float64",
            "float" | "Float" => "Float32",
            "boolean" | "Boolean" => "Bool",
            "String" | "CharSequence" => "String",
            _ => return None,
        }
        .to_string(),
    )
}

/// The Mojo type of a port parameter.
fn param_mojo(m: &Manifest, p: &crate::ts::exports::Param) -> String {
    if m.language == crate::lang::Lang::Go
        && let Some(go) = &p.native_type
    {
        return go_mojo_type(go);
    }
    if m.language == crate::lang::Lang::Java
        && let Some(t) = p.native_type.as_deref().and_then(java_mojo_type)
    {
        return t;
    }
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
        let ret = match (&f.native_return, m.language) {
            (Some(native), crate::lang::Lang::Go) => go_ret_mojo(native),
            (Some(native), crate::lang::Lang::Java) if java_mojo_type(native).is_some() => {
                java_mojo_type(native)
            }
            _ => ret_mojo(m, &f.returns),
        };
        let ret = ret.map(|t| format!(" -> {t}")).unwrap_or_default();
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
    if body.contains("JsonValue") {
        out.push_str("\nfrom json import JsonValue\n");
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

    fn unit(language: &str, exports: &str) -> Manifest {
        serde_json::from_str(&format!(
            r#"{{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "u",
                "language": "{language}", "kind": "ffi", "crate_name": "u-mojo",
                "exports": [{exports}]}}"#
        ))
        .unwrap()
    }

    fn go_fn(name: &str, params: &[(&str, &str)], ret: &str) -> String {
        let params: Vec<String> = params
            .iter()
            .map(|(n, t)| {
                format!(
                    r#"{{"name": "{n}", "ts_type": "int", "optional": false, "rest": false,
                         "native_type": "{t}"}}"#
                )
            })
            .collect();
        format!(
            r#"{{"name": "{name}", "file": "p.go", "line": 1, "params": [{}],
                "returns": "unknown", "native_return": "{ret}", "is_async": false,
                "is_generator": false, "type_params": [], "uses_instanceof": false}}"#,
            params.join(", ")
        )
    }

    #[test]
    fn go_mojo_types() {
        for (go, mojo) in [
            ("int", "Int"),
            ("int64", "Int64"),
            ("uint64", "UInt64"),
            ("float64", "Float64"),
            ("string", "String"),
            ("bool", "Bool"),
            ("[]string", "List[String]"),
            ("map[string]int", "JsonValue"),
            ("Point", "JsonValue"),
        ] {
            assert_eq!(go_mojo_type(go), mojo, "{go}");
        }
        let src = port_mojo(&unit(
            "go",
            &go_fn(
                "Split",
                &[("s", "string"), ("n", "uint64")],
                "([]string, error)",
            ),
        ));
        assert!(
            src.contains("def split(s: String, n: UInt64) raises -> List[String]:"),
            "{src}"
        );
        let src = port_mojo(&unit("go", &go_fn("Pair", &[], "(int, string)")));
        assert!(src.contains("def pair() raises -> JsonValue:"), "{src}");
        assert!(src.contains("from json import JsonValue"), "{src}");
        let src = port_mojo(&unit("go", &go_fn("Check", &[], "(error)")));
        assert!(src.contains("def check() raises:"), "{src}");
    }

    #[test]
    fn scalar_go_unit_has_no_json() {
        let src = port_mojo(&unit(
            "go",
            &go_fn("Clean", &[("path", "string")], "(string)"),
        ));
        assert!(!src.contains("json"), "{src}");
        let api = parse_port_mojo(&src);
        assert!(api.functions.iter().all(go_typed_eligible));
        assert!(!needs_json_mojo(crate::lang::Lang::Go, &api), "{src}");
        let src = port_mojo(&unit(
            "go",
            &go_fn("Fields", &[("s", "string")], "([]string)"),
        ));
        let api = parse_port_mojo(&src);
        assert!(!go_typed_eligible(&api.functions[0]));
        assert!(needs_json_mojo(crate::lang::Lang::Go, &api), "{src}");
    }

    #[test]
    fn ruby_unit_has_json() {
        let m = unit(
            "ruby",
            r#"{"name": "shellsplit", "file": "s.rb", "line": 1,
                "params": [{"name": "line", "ts_type": "unknown", "optional": false,
                            "rest": false}],
                "returns": "unknown", "is_async": false, "is_generator": false,
                "type_params": [], "uses_instanceof": false}"#,
        );
        let src = port_mojo(&m);
        assert!(
            src.contains("def shellsplit(line: JsonValue) raises -> JsonValue:"),
            "{src}"
        );
        assert!(src.contains("from json import JsonValue"), "{src}");
        assert!(needs_json_mojo(
            crate::lang::Lang::Ruby,
            &parse_port_mojo(&src)
        ));
        assert!(needs_json_mojo(
            crate::lang::Lang::Ruby,
            &parse_port_mojo("def f() raises:\n    pass\n")
        ));
    }

    #[test]
    fn nested_defs_are_not_api() {
        let api = parse_port_mojo("struct S:\n    def m(self) -> Int:\n        return 1\n");
        assert!(api.functions.is_empty());
        assert_eq!(api.structs, ["S"]);
    }
}
