//! Step 2: scaffold the port of one unit, with the bindings its callers need and a manifest the
//! later steps read.
//!
//! The port (`port.mojo`, or `src/port.rs` for a Java or Kotlin unit bridged with `--kind ffi`)
//! holds the logic;
//! the generated layers around it (dispatcher, Node-API shim, Python extension, Java wrappers)
//! are rewritten by `refresh` and never edited by hand.

use crate::walk::Canonical;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};

use crate::analyze::{self, Bridge, Status};
use crate::codegen;
use crate::ts::exports::{
    ExportedClass, ExportedFn, LocalType, exported_classes, exported_functions, local_types,
};

pub const MANIFEST: &str = "mojo-anything.json";
pub const SCHEMA: &str = "mojo-anything/bridge@1";
/// The manifest's name before the tool was renamed from rust-anything.
pub const OLD_MANIFEST: &str = "rust-anything.json";

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Kind {
    /// `extern "C"` functions with the original names: a drop-in replacement for C code.
    #[serde(rename = "c-abi")]
    CAbi,
    /// A JSON dispatcher over the port, called from a generated Go or Ruby wrapper.
    Ffi,
    /// A Python extension module written in Mojo, imported by a generated wrapper package.
    #[serde(rename = "mojo-py")]
    MojoPy,
    /// A Mojo port of a TS/JS unit, reached from Node through a Node-API C shim over the JSON
    /// dispatcher.
    #[serde(rename = "mojo-node")]
    MojoNode,
    /// A Mojo port of a TS/JS unit compiled to a WebAssembly module, which the generated
    /// `index.cjs` loads in place of the Node-API addon.
    #[serde(rename = "mojo-wasm")]
    MojoWasm,
    /// A Mojo port of a Java or Kotlin unit, reached from generated Java classes through the
    /// Foreign Function & Memory API (Java 22+) over the JSON dispatcher.
    #[serde(rename = "mojo-jvm")]
    MojoJvm,
}

impl Kind {
    /// A TS/JS unit ported to Mojo: the original API in `index.cjs` over the JSON dispatcher,
    /// reached through a Node-API addon or a wasm module.
    pub fn mojo_js(self) -> bool {
        matches!(self, Kind::MojoNode | Kind::MojoWasm)
    }
}

/// Why `--batch` fails for `mojo-jvm` units.
pub const JVM_BATCH_NOT_YET: &str =
    "not yet: batches for Java units ported to Mojo come after correctness";

/// Whether a unit of this kind and language is ported to Mojo (the rest are still Rust).
pub fn mojo_unit(kind: Kind, language: crate::lang::Lang) -> bool {
    use crate::lang::Lang;
    match kind {
        Kind::MojoPy | Kind::CAbi | Kind::MojoNode | Kind::MojoWasm | Kind::MojoJvm => true,
        Kind::Ffi => matches!(language, Lang::Go | Lang::Ruby),
    }
}

/// Why `--batch` fails for Go and Ruby units.
pub const BATCH_NOT_YET: &str = "not yet: batches for Go and Ruby come after correctness";

/// What `bridge` generated; every later step starts from it.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Manifest {
    pub schema: String,
    /// The repository root: absolute, or relative to the crate folder (so a crate kept inside
    /// the repository it ports works in any clone). Resolved when the manifest is loaded.
    pub root: PathBuf,
    /// `root` as written in the file, when it was relative; written back instead of the resolved
    /// path.
    #[serde(skip)]
    pub root_written: Option<PathBuf>,
    pub unit: String,
    #[serde(default)]
    pub language: crate::lang::Lang,
    pub kind: Kind,
    pub crate_name: String,
    /// Exports ported to Rust.
    pub exports: Vec<ExportedFn>,
    /// Exported classes ported to Rust: a struct with `new` and methods.
    #[serde(default)]
    pub classes: Vec<ExportedClass>,
    /// Exports that cannot cross the bridge as they are; they stay in TS and the shadow module
    /// re-exports them from the original.
    #[serde(default)]
    pub js_only: Vec<JsOnly>,
    /// Functions run over many items kept in Rust (`--batch function:param`).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub batches: Vec<crate::codegen_batch::Batch>,
    /// Floats match within this relative tolerance (`record --float-tolerance`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub float_tolerance: Option<f64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct JsOnly {
    pub name: String,
    pub file: String,
    pub line: u32,
    pub reason: String,
}

/// Whether values of the local type `name` can hold functions: the type has a function or
/// method member, or extends or mentions a type that does.
fn has_functions(name: &str, local_types: &[LocalType], seen: &mut Vec<String>) -> bool {
    if seen.iter().any(|s| s == name) {
        return false;
    }
    seen.push(name.to_string());
    let Some(t) = local_types.iter().find(|t| t.name == name) else {
        return false;
    };
    let text = &t.text;
    let method = text.lines().skip(1).any(|l| {
        let l = l.trim().trim_start_matches("readonly ");
        l.contains('(')
            && l.split('(').next().is_some_and(|head| {
                !head.is_empty()
                    && head
                        .chars()
                        .all(|c| c.is_alphanumeric() || c == '_' || c == '?')
            })
    });
    if text.contains("=>") || method {
        return true;
    }
    text.split(|c: char| !(c.is_alphanumeric() || c == '_' || c == '$'))
        .filter(|w| !w.is_empty() && *w != name)
        .any(|w| has_functions(w, local_types, seen))
}

/// Why an export cannot cross a JS/Rust bridge unchanged, if it cannot.
///
/// Functions, iterators, RegExp objects and objects with function members are JS values a
/// Rust function can neither take nor return; porting them would change the public API.
pub fn js_only_reason(f: &ExportedFn, local_types: &[LocalType]) -> Option<String> {
    if let Some(blocker) = &f.blocker {
        return Some(blocker.clone());
    }
    if f.is_generator {
        return Some("generator: returns a lazy iterator".into());
    }
    if f.uses_instanceof {
        return Some("checks `instanceof`: class identity does not survive the bridge".into());
    }
    let types: Vec<&str> = f
        .params
        .iter()
        .map(|p| p.ts_type.as_str())
        .chain(std::iter::once(f.returns.as_str()))
        .collect();
    if types.iter().any(|t| t.contains("=>")) {
        return Some("takes or returns a function".into());
    }
    let words = |t: &str| -> Vec<String> {
        t.split(|c: char| !(c.is_alphanumeric() || c == '_' || c == '$'))
            .filter(|w| !w.is_empty())
            .map(str::to_string)
            .collect()
    };
    for t in &types {
        for word in words(t) {
            match word.as_str() {
                "RegExp" => return Some("takes or returns a RegExp".into()),
                "Generator" | "Iterator" | "IterableIterator" | "AsyncGenerator"
                | "AsyncIterable" => {
                    return Some(format!("uses `{word}`, a lazy iterator"));
                }
                "Function" => return Some("takes or returns a function".into()),
                _ => {}
            }
            if f.type_params.contains(&word) {
                return Some(format!(
                    "generic over `{word}`: values of any shape, functions included"
                ));
            }
            if has_functions(&word, local_types, &mut Vec::new()) {
                return Some(format!("uses `{word}`, which has function members"));
            }
        }
    }
    None
}

impl Manifest {
    pub fn load(crate_dir: &Path) -> Result<Self> {
        let mut path = crate_dir.join(MANIFEST);
        if !path.exists() && crate_dir.join(OLD_MANIFEST).exists() {
            // Bridged before the rename; read as it is, written back under the new name.
            path = crate_dir.join(OLD_MANIFEST);
        }
        let text = std::fs::read_to_string(&path).with_context(|| {
            format!(
                "reading {} (run `mojo-anything bridge` first)",
                path.display()
            )
        })?;
        let old_kind = serde_json::from_str::<serde_json::Value>(&text)
            .ok()
            .and_then(|v| v["kind"].as_str().map(str::to_string));
        let old_bridge = match old_kind.as_deref() {
            Some("pyo3") => Some("PyO3"),
            Some("napi") => Some("napi-rs"),
            Some("wasm") => Some("wasm-bindgen"),
            _ => None,
        };
        if let Some(old) = old_bridge {
            bail!(
                "{} was bridged with {old}, which mojo-anything no longer generates: run bridge again to port the unit to Mojo",
                path.display()
            );
        }
        let mut manifest: Self =
            serde_json::from_str(&text).with_context(|| format!("parsing {}", path.display()))?;
        if manifest.kind == Kind::Ffi && crate::jvm::is_jvm(manifest.language) {
            bail!(
                "{} is a Rust JNI crate, which mojo-anything no longer generates: run bridge again \
                 to port the unit to Mojo (Java's Foreign Function & Memory API, Java 22+)",
                crate_dir.display()
            );
        }
        if manifest.kind == Kind::CAbi && crate_dir.join("Cargo.toml").exists() {
            bail!(
                "{} is a Rust C ABI crate, which mojo-anything no longer generates: run bridge again to port the unit to Mojo",
                crate_dir.display()
            );
        }
        if manifest.root.is_relative() {
            let resolved = crate_dir.join(&manifest.root);
            let resolved = resolved.canonical().unwrap_or(resolved);
            manifest.root_written = Some(std::mem::replace(&mut manifest.root, resolved));
        }
        Ok(manifest)
    }

    /// Writes the manifest back, keeping a relative root relative.
    pub fn save(&self, crate_dir: &Path) -> Result<()> {
        let mut m = self.clone();
        if let Some(written) = m.root_written.take() {
            m.root = written;
        }
        let path = crate_dir.join(MANIFEST);
        std::fs::write(&path, serde_json::to_string_pretty(&m)? + "\n")
            .with_context(|| format!("writing {}", path.display()))
    }

    /// Rust library name: the crate name with `-` replaced.
    pub fn lib_name(&self) -> String {
        self.crate_name.replace('-', "_")
    }
}

pub struct Options<'a> {
    pub root: &'a Path,
    pub unit: &'a str,
    pub kind: Option<Kind>,
    pub out: Option<PathBuf>,
    pub name: Option<String>,
    /// Bridge a unit the plan marks blocked or keep.
    pub force: bool,
    /// Exports to keep in TS, with an optional reason: `name` or `name: reason`.
    pub keep: Vec<String>,
    /// Source language; detected from the repository when `None`.
    pub lang: Option<crate::lang::Lang>,
    /// `function:param` pairs: batch classes running `function` over many `param` values.
    pub batch: Vec<String>,
    /// Type parameters the app only fills with data: bridged as JSON values instead of keeping
    /// the export in TS.
    pub as_json: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct Outcome {
    pub crate_dir: PathBuf,
    pub kind: Kind,
    pub files: Vec<String>,
    pub exports: Vec<String>,
    pub notes: Vec<String>,
}

/// A Rust type as seen by the port, from a TS type annotation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RType {
    Str,
    F64,
    /// A whole number (`int` in the type dialect: Python, Go, Java and C have one; JS does not).
    Int,
    Bool,
    Unit,
    Vec(Box<RType>),
    Opt(Box<RType>),
    /// Anything structured: crosses the bridge as JSON.
    Json,
}

impl RType {
    pub fn from_ts(ts: &str) -> Self {
        let ts = ts.trim().trim_start_matches("readonly ").trim();
        // `(string | null)`: one parenthesized group around the whole type.
        if let Some(inner) = ts.strip_prefix('(').and_then(|t| t.strip_suffix(')'))
            && balanced(inner)
        {
            return Self::from_ts(inner);
        }
        if let Some(inner) = ts
            .strip_prefix("Promise<")
            .and_then(|t| t.strip_suffix('>'))
        {
            return Self::from_ts(inner);
        }
        let parts = split_top(ts, '|');
        if parts.len() > 1 {
            let (nullish, rest): (Vec<&str>, Vec<&str>) = parts
                .iter()
                .partition(|p| matches!(p.trim(), "undefined" | "null" | "void"));
            if rest.iter().all(|p| is_string_literal(p)) {
                return Self::wrap_opt(Self::Str, !nullish.is_empty());
            }
            if rest.len() == 1 {
                return Self::wrap_opt(Self::from_ts(rest[0]), !nullish.is_empty());
            }
            return Self::Json;
        }
        if let Some(inner) = ts.strip_suffix("[]") {
            return Self::Vec(Box::new(Self::from_ts(
                inner.trim_start_matches('(').trim_end_matches(')'),
            )));
        }
        for wrapper in ["Array<", "ReadonlyArray<"] {
            if let Some(inner) = ts.strip_prefix(wrapper).and_then(|t| t.strip_suffix('>')) {
                return Self::Vec(Box::new(Self::from_ts(inner)));
            }
        }
        // `value is MessageLeaf`: a type predicate returns a boolean; `asserts x` returns nothing.
        if ts.starts_with("asserts ") {
            return Self::Unit;
        }
        if let Some((subject, _)) = ts.split_once(" is ")
            && subject
                .trim()
                .chars()
                .all(|c| c.is_alphanumeric() || c == '_' || c == '$')
        {
            return Self::Bool;
        }
        match ts {
            "string" => Self::Str,
            "number" => Self::F64,
            "int" => Self::Int,
            "boolean" => Self::Bool,
            "void" | "undefined" => Self::Unit,
            _ if is_string_literal(ts) => Self::Str,
            _ => Self::Json,
        }
    }

    fn wrap_opt(t: Self, optional: bool) -> Self {
        if optional { Self::Opt(Box::new(t)) } else { t }
    }

    pub fn rust(&self) -> String {
        match self {
            Self::Str => "String".into(),
            Self::F64 => "f64".into(),
            Self::Int => "i64".into(),
            Self::Bool => "bool".into(),
            Self::Unit => "()".into(),
            Self::Vec(t) => format!("Vec<{}>", t.rust()),
            Self::Opt(t) => format!("Option<{}>", t.rust()),
            Self::Json => "serde_json::Value".into(),
        }
    }

    /// The Mojo type a port uses for this value. Python's numbers keep their int-or-float,
    /// unbounded semantics (`PyNum`); structured values stay Python objects.
    pub fn mojo(&self, lang: crate::lang::Lang) -> String {
        use crate::lang::Lang;
        match self {
            Self::Str => "String".into(),
            Self::F64 | Self::Int if lang == Lang::Python => "PyNum".into(),
            Self::F64 => "Float64".into(),
            Self::Int => "Int".into(),
            Self::Bool => "Bool".into(),
            Self::Unit => "None".into(),
            Self::Vec(t) => format!("List[{}]", t.mojo(lang)),
            Self::Opt(t) => format!("Optional[{}]", t.mojo(lang)),
            Self::Json if lang == Lang::Python => "PythonObject".into(),
            Self::Json => "JsonValue".into(),
        }
    }

    pub fn contains_json(&self) -> bool {
        match self {
            Self::Json => true,
            Self::Vec(t) | Self::Opt(t) => t.contains_json(),
            _ => false,
        }
    }
}

fn is_string_literal(ts: &str) -> bool {
    let ts = ts.trim();
    ts.len() >= 2
        && ((ts.starts_with('\'') && ts.ends_with('\''))
            || (ts.starts_with('"') && ts.ends_with('"')))
}

fn balanced(ts: &str) -> bool {
    let mut depth = 0i32;
    for c in ts.chars() {
        match c {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if depth < 0 {
                    return false;
                }
            }
            _ => {}
        }
    }
    depth == 0
}

/// Splits on `sep` outside brackets.
fn split_top(ts: &str, sep: char) -> Vec<&str> {
    let mut out = Vec::new();
    let mut depth = 0i32;
    let mut start = 0;
    for (i, c) in ts.char_indices() {
        match c {
            '<' | '(' | '[' | '{' => depth += 1,
            '>' | ')' | ']' | '}' => depth -= 1,
            c if c == sep && depth == 0 => {
                out.push(ts[start..i].trim());
                start = i + c.len_utf8();
            }
            _ => {}
        }
    }
    out.push(ts[start..].trim());
    out.retain(|p| !p.is_empty());
    out
}

/// A parameter's type for the port, rest and optional parameters included.
pub fn param_type(p: &crate::ts::exports::Param) -> RType {
    let base = RType::from_ts(&p.ts_type);
    let base = if p.rest {
        match base {
            RType::Vec(_) => base,
            other => RType::Vec(Box::new(other)),
        }
    } else {
        base
    };
    if p.optional && !matches!(base, RType::Opt(_)) {
        RType::Opt(Box::new(base))
    } else {
        base
    }
}

pub fn snake_case(name: &str) -> String {
    let chars: Vec<char> = name.chars().collect();
    let mut out = String::new();
    for (i, &c) in chars.iter().enumerate() {
        if c.is_uppercase() {
            let prev = i.checked_sub(1).map(|j| chars[j]);
            let next = chars.get(i + 1);
            let boundary = prev.is_some_and(|p| p.is_lowercase() || p.is_ascii_digit())
                || (prev.is_some_and(char::is_uppercase) && next.is_some_and(|n| n.is_lowercase()));
            if boundary {
                out.push('_');
            }
            out.extend(c.to_lowercase());
        } else if c.is_alphanumeric() {
            out.push(c);
        } else {
            out.push('_');
        }
    }
    const KEYWORDS: &[&str] = &[
        "as", "break", "const", "continue", "crate", "else", "enum", "extern", "false", "fn",
        "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref",
        "return", "self", "static", "struct", "super", "trait", "true", "type", "unsafe", "use",
        "where", "while", "async", "await", "dyn", "gen",
    ];
    if KEYWORDS.contains(&out.as_str()) {
        format!("r#{out}")
    } else {
        out
    }
}

/// Types declared in `file` and in the files it imports relatively (one level deep).
pub fn types_in_scope(root: &Path, file: &str, text: &str) -> Vec<LocalType> {
    let mut types = Vec::new();
    let mut seen = std::collections::HashSet::new();
    collect_types(root, file, text, 0, &mut seen, &mut types);
    types
}

/// Types of a file and of the files it imports or re-exports, a few levels deep
/// (`./types` -> `types/index.ts` -> `export * from './host'`).
fn collect_types(
    root: &Path,
    file: &str,
    text: &str,
    depth: usize,
    seen: &mut std::collections::HashSet<String>,
    types: &mut Vec<LocalType>,
) {
    if depth > 4 || !seen.insert(file.to_string()) {
        return;
    }
    types.extend(local_types(file, text));
    let dir = file.rsplit_once('/').map_or("", |(d, _)| d);
    for import in crate::ts::scan::scan(file, text).imports {
        let spec = import.specifier;
        // Workspace packages (`@x18n/core`) are followed to their source entry.
        let base = if spec.starts_with('.') {
            let joined = if dir.is_empty() {
                spec.clone()
            } else {
                format!("{dir}/{spec}")
            };
            match normalize_rel(&joined) {
                Some(base) => base,
                None => continue,
            }
        } else {
            let name = crate::ts::deps::package_name(&spec);
            let Some(pkg_dir) = workspace_packages(root).get(name).cloned() else {
                continue;
            };
            let sub = spec[name.len()..].trim_start_matches('/');
            let src = if root.join(&pkg_dir).join("src").is_dir() {
                format!("{pkg_dir}/src")
            } else {
                pkg_dir
            };
            let src = src.trim_start_matches('/').to_string();
            if sub.is_empty() {
                format!("{src}/index")
            } else {
                format!("{src}/{sub}")
            }
        };
        let stem = base.trim_end_matches(".js");
        let candidates = [
            format!("{stem}.ts"),
            format!("{stem}.mts"),
            format!("{stem}.d.ts"),
            format!("{stem}/index.ts"),
            base.clone(),
        ];
        if let Some(found) = candidates.iter().find(|c| root.join(c).is_file())
            && let Ok(imported) = std::fs::read_to_string(root.join(found))
        {
            collect_types(root, found, &imported, depth + 1, seen, types);
        }
    }
}

/// Workspace package names and their root-relative folders, read once per root.
fn workspace_packages(root: &Path) -> std::collections::HashMap<String, String> {
    use std::sync::{Mutex, OnceLock};
    static CACHE: OnceLock<
        Mutex<std::collections::HashMap<PathBuf, std::collections::HashMap<String, String>>>,
    > = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(std::collections::HashMap::new()));
    let mut cache = cache
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    cache
        .entry(root.to_path_buf())
        .or_insert_with(|| {
            crate::ts::discover::discover(root)
                .map(|ws| ws.packages.into_iter().map(|p| (p.name, p.dir)).collect())
                .unwrap_or_default()
        })
        .clone()
}

/// Collapses `.` and `..` in a root-relative path.
fn normalize_rel(path: &str) -> Option<String> {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop()?;
            }
            _ => parts.push(part),
        }
    }
    Some(parts.join("/"))
}

/// `f<T extends string>(s: T)` takes a string: type parameters with a simple constraint are
/// replaced by it. The rest stay listed, and keep the function in TS.
pub fn substitute_constraints(f: &mut ExportedFn, types: &[LocalType]) {
    let mut remaining = Vec::new();
    for tp in std::mem::take(&mut f.type_params) {
        let Some((name, constraint)) = tp.split_once(" extends ") else {
            remaining.push(tp);
            continue;
        };
        let constraint = resolve_aliases(constraint, types);
        // Data constraints (`string`, `string | readonly string[]`) are substituted; anything that
        // could hold a function keeps the type parameter, and the function stays in TS.
        let open_ended = constraint.contains("=>")
            || constraint
                .split(|c: char| !(c.is_alphanumeric() || c == '_'))
                .any(|w| {
                    matches!(w, "Function" | "object" | "unknown" | "any")
                        || has_functions(w, types, &mut Vec::new())
                });
        if open_ended {
            remaining.push(name.to_string());
            continue;
        }
        let replacement = format!("({constraint})");
        for p in &mut f.params {
            p.ts_type = replace_word(&p.ts_type, name, &replacement);
        }
        f.returns = replace_word(&f.returns, name, &replacement);
    }
    f.type_params = remaining;
}

/// Turns the type parameters named in `names` into `unknown` (a JSON value on the Rust side).
pub fn substitute_json(f: &mut ExportedFn, names: &[String]) {
    let mut remaining = Vec::new();
    for tp in std::mem::take(&mut f.type_params) {
        let name = tp
            .split_once(" extends ")
            .map_or(tp.as_str(), |(n, _)| n)
            .trim();
        if !names.iter().any(|n| n == name) {
            remaining.push(tp);
            continue;
        }
        for p in &mut f.params {
            p.ts_type = replace_word(&p.ts_type, name, "unknown");
        }
        f.returns = replace_word(&f.returns, name, "unknown");
    }
    f.type_params = remaining;
}

fn replace_word(text: &str, word: &str, with: &str) -> String {
    let mut out = String::new();
    let mut current = String::new();
    for c in text.chars().chain(std::iter::once(' ')) {
        if c.is_alphanumeric() || c == '_' || c == '$' {
            current.push(c);
        } else {
            out.push_str(if current == word { with } else { &current });
            current.clear();
            out.push(c);
        }
    }
    out.pop();
    out
}

/// Replaces simple type aliases (`type KeyString = string`) by what they stand for.
pub fn resolve_aliases(ts: &str, types: &[LocalType]) -> String {
    let mut out = ts.to_string();
    for _ in 0..4 {
        let mut changed = false;
        let mut next = String::with_capacity(out.len());
        let mut word = String::new();
        let flush = |word: &mut String, next: &mut String, changed: &mut bool| {
            if let Some(t) = types.iter().find(|t| t.alias && t.name == *word) {
                let text = t.text.trim();
                if text.contains('|') {
                    next.push('(');
                    next.push_str(text);
                    next.push(')');
                } else {
                    next.push_str(text);
                }
                *changed = true;
            } else {
                next.push_str(word);
            }
            word.clear();
        };
        for c in out.chars() {
            if c.is_alphanumeric() || c == '_' || c == '$' {
                word.push(c);
            } else {
                flush(&mut word, &mut next, &mut changed);
                next.push(c);
            }
        }
        flush(&mut word, &mut next, &mut changed);
        out = next;
        if !changed {
            break;
        }
    }
    out
}

/// The reason given with `--keep name` or `--keep "name: reason"`, if `name` is kept.
fn keep_reason(keep: &[String], name: &str) -> Option<String> {
    keep.iter().find_map(|k| {
        let (kept, reason) = k
            .split_once(':')
            .map_or((k.as_str(), ""), |(n, r)| (n.trim(), r.trim()));
        (kept == name).then(|| {
            if reason.is_empty() {
                "kept on request".to_string()
            } else {
                reason.to_string()
            }
        })
    })
}

/// Formats a generated Go wrapper with `gofmt`, best effort.
fn format_wrapper(crate_dir: &Path) {
    if crate_dir.join("go").is_dir() {
        let _ = std::process::Command::new("gofmt")
            .arg("-w")
            .arg(crate_dir.join("go"))
            .output();
    }
}

fn parse_batches(specs: &[String]) -> Result<Vec<crate::codegen_batch::Batch>> {
    specs
        .iter()
        .map(|s| {
            crate::codegen_batch::Batch::parse(s)
                .with_context(|| format!("`--batch {s}`: write it as function:param"))
        })
        .collect()
}

/// Adds batch classes to a bridged crate, then regenerates its bindings.
pub fn add_batches(crate_dir: &Path, specs: &[String]) -> Result<Refreshed> {
    let path = crate_dir.join(MANIFEST);
    let before = std::fs::read_to_string(&path).with_context(|| format!("{}", path.display()))?;
    let mut manifest = Manifest::load(crate_dir)?;
    for b in parse_batches(specs)? {
        if !manifest.batches.contains(&b) {
            manifest.batches.push(b);
        }
    }
    if let Some(written) = manifest.root_written.clone() {
        manifest.root = written;
    }
    std::fs::write(&path, serde_json::to_string_pretty(&manifest)? + "\n")?;
    // A batch the port cannot serve leaves the crate as it was.
    refresh(crate_dir).inspect_err(|_| {
        let _ = std::fs::write(&path, &before);
    })
}

/// A port function whose doc line does not name an export (`/// Port of \`Integer.toString\``)
/// takes the name of the export it was generated for, matched by its Rust name.
pub fn match_export_names(m: &Manifest, api: &mut codegen::PortApi) {
    for f in &mut api.functions {
        if m.exports.iter().any(|e| e.name == f.js_name) {
            continue;
        }
        let rust = f.rust_name.trim_start_matches("r#");
        if let Some(e) = m
            .exports
            .iter()
            .find(|e| snake_case(&e.name).trim_start_matches("r#") == rust)
        {
            f.js_name = e.name.clone();
        }
    }
}

/// What `refresh` rewrote.
#[derive(Debug, Serialize)]
pub struct Refreshed {
    pub functions: Vec<String>,
    pub files: Vec<String>,
}

/// Regenerates the binding layers from the signatures in the port (`port.mojo`, or `src/port.rs`
/// for a Rust-era Java or Kotlin crate, whose Cargo.toml also gets the dependencies it needs).
/// Never touches the port.
pub fn refresh(crate_dir: &Path) -> Result<Refreshed> {
    let manifest = Manifest::load(crate_dir)?;
    if manifest.kind == Kind::MojoJvm {
        if crate_dir.join("Cargo.toml").exists() {
            bail!(
                "{} is a Rust port from before mojo-anything targeted Mojo: bridge again to get a \
                 Mojo port (port.mojo)",
                crate_dir.display()
            );
        }
        let port =
            std::fs::read_to_string(crate_dir.join("port.mojo")).context("reading port.mojo")?;
        let mut api = crate::codegen_mojo::parse_port_mojo(&port);
        match_export_names(&manifest, &mut api);
        let files = mojo_jvm_bindings(&manifest, &api)?;
        write_files(crate_dir, &files)?;
        return Ok(Refreshed {
            functions: api.functions.iter().map(|f| f.js_name.clone()).collect(),
            files: files.into_iter().map(|(p, _)| p).collect(),
        });
    }
    if manifest.kind == Kind::MojoPy {
        let port =
            std::fs::read_to_string(crate_dir.join("port.mojo")).context("reading port.mojo")?;
        let mut api = crate::codegen_mojo::parse_port_mojo(&port);
        match_export_names(&manifest, &mut api);
        if api.functions.is_empty() {
            bail!("port.mojo has no public `def`: nothing to bind");
        }
        let files = mojo_py_bindings(&manifest, &api)?;
        write_files(crate_dir, &files)?;
        return Ok(Refreshed {
            functions: api.functions.iter().map(|f| f.js_name.clone()).collect(),
            files: files.into_iter().map(|(p, _)| p).collect(),
        });
    }
    if manifest.kind == Kind::CAbi {
        let port =
            std::fs::read_to_string(crate_dir.join("port.mojo")).context("reading port.mojo")?;
        let api = crate::codegen_mojo::parse_port_mojo(&port);
        let files = if manifest.language == crate::lang::Lang::Cpp {
            crate::codegen_cpp::bindings(&manifest, &api).map_err(anyhow::Error::msg)?
        } else {
            c_bindings(&manifest, &api)?
        };
        write_files(crate_dir, &files)?;
        return Ok(Refreshed {
            functions: manifest.exports.iter().map(|f| f.name.clone()).collect(),
            files: files.into_iter().map(|(p, _)| p).collect(),
        });
    }
    if manifest.kind.mojo_js() {
        let port =
            std::fs::read_to_string(crate_dir.join("port.mojo")).context("reading port.mojo")?;
        let mut api = crate::codegen_mojo::parse_port_mojo(&port);
        match_export_names(&manifest, &mut api);
        let files = mojo_node_bindings(&manifest, &api)?;
        write_files(crate_dir, &files)?;
        return Ok(Refreshed {
            functions: manifest.exports.iter().map(|f| f.name.clone()).collect(),
            files: files.into_iter().map(|(p, _)| p).collect(),
        });
    }
    if manifest.kind == Kind::Ffi && mojo_unit(manifest.kind, manifest.language) {
        if crate_dir.join("Cargo.toml").exists() {
            bail!(
                "{} is a Rust port from before mojo-anything targeted Mojo: bridge again to get a \
                 Mojo port (port.mojo)",
                crate_dir.display()
            );
        }
        let port =
            std::fs::read_to_string(crate_dir.join("port.mojo")).context("reading port.mojo")?;
        let mut api = crate::codegen_mojo::parse_port_mojo(&port);
        match_export_names(&manifest, &mut api);
        let files = mojo_ffi_bindings(&manifest, &api)?;
        write_files(crate_dir, &files)?;
        format_wrapper(crate_dir);
        return Ok(Refreshed {
            functions: api.functions.iter().map(|f| f.js_name.clone()).collect(),
            files: files.into_iter().map(|(p, _)| p).collect(),
        });
    }
    bail!(
        "`refresh` has no bindings for a {} unit of kind `ffi`: bridge again",
        manifest.language.name()
    )
}

pub fn bridge(opts: &Options) -> Result<Outcome> {
    let root = opts
        .root
        .canonical()
        .with_context(|| format!("resolving {}", opts.root.display()))?;
    let lang = opts
        .lang
        .unwrap_or_else(|| crate::lang::Lang::detect(&root));
    if crate::jvm::is_jvm(lang) {
        crate::jvm::require_java()?;
    }
    let report = analyze::analyze_lang(&root, lang)?;
    let wanted = opts.unit.trim_start_matches("./");
    let whole = report
        .units
        .iter()
        .find(|u| u.id == wanted || u.id.trim_end_matches('/') == wanted.trim_end_matches('/'));
    let single = || {
        report
            .units
            .iter()
            .find(|u| u.files.iter().any(|f| f == wanted))
            .map(|u| {
                let mut one = u.clone();
                one.id = wanted.to_string();
                one.files = vec![wanted.to_string()];
                one
            })
    };
    let unit = match whole.cloned().or_else(single) {
        Some(unit) => unit,
        None => bail!(
            "no unit or source file `{wanted}`; `mojo-anything analyze` lists unit ids, and any \
             source file inside a unit can be bridged on its own"
        ),
    };
    let unit = &unit;
    if matches!(unit.status, Status::Keep | Status::Blocked) && !opts.force {
        bail!(
            "unit `{}` is {:?}: {}. Pass --force to bridge it anyway.",
            unit.id,
            unit.status,
            unit.notes.first().map_or("", String::as_str)
        );
    }
    if unit.bridge == Bridge::PhpFfi {
        bail!(
            "bridging PHP units into Rust comes next (PHP FFI over a C ABI); for now a PHP app can \
             be analyzed, recorded and replayed (`app record`, `app replay`) and get a Rust front \
             door (`app front-door`) that hands everything to the original"
        );
    }
    if unit.bridge == Bridge::DotnetFfi {
        bail!(
            "bridging C# units into Rust comes next (P/Invoke over a C ABI); for now a C# app can \
             be analyzed, recorded and replayed (`app record`, `app replay`) and get a Rust front \
             door (`app front-door`) that hands everything to the original"
        );
    }
    let kind = opts.kind.unwrap_or(match unit.bridge {
        Bridge::MojoPy => Kind::MojoPy,
        Bridge::CAbi => Kind::CAbi,
        Bridge::MojoJvm => Kind::MojoJvm,
        Bridge::Cgo | Bridge::Fiddle => Kind::Ffi,
        // Code that could also run in browsers goes to Node too, unless `--kind wasm` asks for
        // the wasm module, whose toolchain is a separate install.
        _ => Kind::MojoNode,
    });
    if kind == Kind::MojoWasm && lang != crate::lang::Lang::Ts {
        bail!(
            "`--kind wasm` is for TS/JS units; a {} unit bridges with its own kind (leave out \
             --kind)",
            lang.name()
        );
    }

    let mut exports = Vec::new();
    let mut classes = Vec::new();
    let mut js_only = Vec::new();
    if lang == crate::lang::Lang::C {
        crate::lang::c::use_typedefs(&root);
    }
    if lang == crate::lang::Lang::Cpp {
        crate::lang::cpp::use_typedefs(&root);
    }
    for file in &unit.files {
        if file.ends_with(".vue") || file.ends_with(".svelte") || file.ends_with(".astro") {
            continue;
        }
        let text =
            std::fs::read_to_string(root.join(file)).with_context(|| format!("reading {file}"))?;
        if lang != crate::lang::Lang::Ts {
            let (functions, foreign_classes) = crate::lang::exports(lang, file, &text);
            for f in functions {
                match keep_reason(&opts.keep, &f.name).or_else(|| js_only_reason(&f, &[])) {
                    Some(reason) => js_only.push(JsOnly {
                        name: f.name,
                        file: f.file,
                        line: f.line,
                        reason,
                    }),
                    None => exports.push(f),
                }
            }
            for class in foreign_classes {
                let method_reason = class
                    .methods
                    .iter()
                    .find_map(|m| js_only_reason(m, &[]).map(|r| format!("`{}`: {r}", m.name)));
                match keep_reason(&opts.keep, &class.name)
                    .or_else(|| class.blocker.clone())
                    .or(method_reason)
                {
                    Some(reason) => js_only.push(JsOnly {
                        name: class.name,
                        file: class.file,
                        line: class.line,
                        reason: format!("class: {reason}"),
                    }),
                    None => classes.push(class),
                }
            }
            continue;
        }
        let types = types_in_scope(&root, file, &text);
        for mut class in exported_classes(file, &text) {
            let kept = keep_reason(&opts.keep, &class.name);
            let constructor = ExportedFn {
                name: format!("{} constructor", class.name),
                file: class.file.clone(),
                line: class.line,
                params: class.constructor.clone(),
                returns: "void".into(),
                is_async: false,
                is_generator: false,
                type_params: Vec::new(),
                uses_instanceof: false,
                ..Default::default()
            };
            let method_reason = std::iter::once(&constructor)
                .chain(&class.methods)
                .find_map(|m| js_only_reason(m, &types).map(|r| format!("`{}`: {r}", m.name)));
            match kept.or_else(|| class.blocker.clone()).or(method_reason) {
                Some(reason) => js_only.push(JsOnly {
                    name: class.name,
                    file: class.file,
                    line: class.line,
                    reason: format!("class: {reason}"),
                }),
                None => {
                    for p in &mut class.constructor {
                        p.ts_type = resolve_aliases(&p.ts_type, &types);
                    }
                    for m in &mut class.methods {
                        for p in &mut m.params {
                            p.ts_type = resolve_aliases(&p.ts_type, &types);
                        }
                        m.returns = resolve_aliases(&m.returns, &types);
                    }
                    classes.push(class);
                }
            }
        }
        let mut functions = exported_functions(file, &text);
        crate::ts::jsdoc::apply_declarations(&root, file, &mut functions);
        for mut f in functions {
            for p in &mut f.params {
                p.ts_type = resolve_aliases(&p.ts_type, &types);
            }
            f.returns = resolve_aliases(&f.returns, &types);
            substitute_constraints(&mut f, &types);
            substitute_json(&mut f, &opts.as_json);
            let kept = keep_reason(&opts.keep, &f.name);
            match kept.or_else(|| js_only_reason(&f, &types)) {
                Some(reason) => js_only.push(JsOnly {
                    name: f.name,
                    file: f.file,
                    line: f.line,
                    reason,
                }),
                None => exports.push(f),
            }
        }
    }
    let mut defined: Vec<(&str, String)> = exports
        .iter()
        .map(|f| (f.name.as_str(), format!("{}:{}", f.file, f.line)))
        .chain(
            classes
                .iter()
                .map(|c| (c.name.as_str(), format!("{}:{}", c.file, c.line))),
        )
        .chain(
            js_only
                .iter()
                .map(|j| (j.name.as_str(), format!("{}:{}", j.file, j.line))),
        )
        .collect();
    defined.sort();
    if let Some(pair) = defined.windows(2).find(|w| w[0].0 == w[1].0) {
        bail!(
            "`{}` is defined twice in `{}` ({} and {}), and the bridge names every export by \
             itself, so one would silently replace the other. Bridge the module you want on its \
             own (`mojo-anything bridge <root> <that file>`), or rename one of them",
            pair[0].0,
            unit.id,
            pair[0].1,
            pair[1].1
        );
    }
    if exports.is_empty() && classes.is_empty() && !js_only.is_empty() {
        bail!(
            "every export of `{}` must stay in {}: {}",
            unit.id,
            lang.name(),
            js_only
                .iter()
                .map(|j| format!("{} ({})", j.name, j.reason))
                .collect::<Vec<_>>()
                .join(", ")
        );
    }
    if exports.is_empty() && classes.is_empty() {
        bail!(
            "unit `{}` exports no functions; bridge a unit with an exported function API",
            unit.id
        );
    }

    let stem = unit
        .id
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("unit")
        .split('.')
        .next()
        .unwrap_or("unit");
    let crate_name = opts.name.clone().unwrap_or_else(|| {
        let clean: String = stem
            .chars()
            .map(|c| {
                if c.is_ascii_alphanumeric() {
                    c.to_ascii_lowercase()
                } else {
                    '-'
                }
            })
            .collect();
        let suffix = if mojo_unit(kind, lang) { "mojo" } else { "rs" };
        format!("{}-{suffix}", clean.trim_matches('-'))
    });
    let crate_dir = opts.out.clone().unwrap_or_else(|| {
        let folder = if mojo_unit(kind, lang) {
            "mojo"
        } else {
            "rust"
        };
        root.join(folder).join(&crate_name)
    });
    if crate_dir.exists() && std::fs::read_dir(&crate_dir)?.next().is_some() {
        bail!(
            "{} already exists and is not empty; mojo-anything never overwrites a port in progress",
            crate_dir.display()
        );
    }

    let mut classes = classes.clone();
    let mut js_only = js_only.clone();
    if kind.mojo_js() {
        // The Node and wasm bridges have no Mojo classes yet: a class stays in TS, where `record`, `gate`
        // and the shadow leave it to the original instead of expecting it from the port.
        for c in classes.drain(..) {
            js_only.push(JsOnly {
                name: c.name,
                file: c.file,
                line: c.line,
                reason: "class: not ported to Mojo yet".into(),
            });
        }
    }
    let manifest = Manifest {
        schema: SCHEMA.into(),
        root: root.clone(),
        root_written: None,
        unit: unit.id.clone(),
        language: lang,
        kind,
        crate_name: crate_name.clone(),
        exports: exports.clone(),
        classes: classes.clone(),
        js_only: js_only.clone(),
        batches: parse_batches(&opts.batch)?,
        float_tolerance: None,
    };
    match kind {
        Kind::CAbi if lang == crate::lang::Lang::Cpp => bridge_cpp(&manifest, &crate_dir, &js_only),
        Kind::CAbi => bridge_c(&manifest, &crate_dir, &js_only),
        Kind::Ffi if mojo_unit(kind, lang) => bridge_ffi_mojo(&manifest, &crate_dir, &js_only),
        Kind::Ffi => bail!(
            "the `ffi` kind is for Go and Ruby units; {} units bridge to Mojo with their own kind",
            lang.name()
        ),
        Kind::MojoPy => bridge_mojo_py(&manifest, &crate_dir, &js_only),
        Kind::MojoNode | Kind::MojoWasm => bridge_mojo_node(&manifest, &crate_dir, &js_only),
        Kind::MojoJvm => bridge_mojo_jvm(&manifest, &crate_dir, &js_only),
    }
}

/// The generated layers of a Python unit's Mojo port: the extension module, `PyNum` when the
/// port uses Python numbers, and the wrapper package.
fn mojo_py_bindings(m: &Manifest, api: &codegen::PortApi) -> Result<Vec<(String, String)>> {
    use crate::codegen_mojo_py as py;
    let mut files = vec![
        (
            format!("{}.mojo", py::NATIVE),
            py::native_mojo(m, api).map_err(anyhow::Error::msg)?,
        ),
        (
            format!("python/{}/__init__.py", m.lib_name()),
            py::package_init_mojo(m, api),
        ),
    ];
    if py::needs_py_num(api) {
        files.push(("py_num.mojo".into(), py::PY_NUM_MOJO.into()));
    }
    Ok(files)
}

fn bridge_mojo_py(m: &Manifest, crate_dir: &Path, js_only: &[JsOnly]) -> Result<Outcome> {
    let port = crate::codegen_mojo::port_mojo(m);
    let mut api = crate::codegen_mojo::parse_port_mojo(&port);
    match_export_names(m, &mut api);
    let mut files = vec![
        ("port.mojo".to_string(), port),
        ("pixi.toml".into(), crate::codegen_mojo_py::pixi_toml(m)),
        (
            ".gitignore".into(),
            ".pixi/
.mojo-anything/
*.so
__pycache__/
"
            .into(),
        ),
        ("README.md".into(), mojo_readme(m)),
        (
            MANIFEST.into(),
            serde_json::to_string_pretty(m)?
                + "
",
        ),
    ];
    files.extend(mojo_py_bindings(m, &api)?);
    write_files(crate_dir, &files)?;
    let mut notes = vec![format!(
        "Port each function in port.mojo, then: mojo-anything record {0} && mojo-anything build {0} && mojo-anything diff {0}",
        crate_dir.display()
    )];
    for c in &m.classes {
        notes.push(format!(
            "Class `{}` is not bridged to Mojo yet; it stays in Python.",
            c.name
        ));
    }
    for j in js_only {
        notes.push(format!(
            "`{}` stays in {}: {}.",
            j.name,
            m.language.name(),
            j.reason
        ));
    }
    Ok(Outcome {
        crate_dir: crate_dir.to_path_buf(),
        kind: m.kind,
        files: files.into_iter().map(|(p, _)| p).collect(),
        exports: m.exports.iter().map(|f| f.name.clone()).collect(),
        notes,
    })
}

fn bridge_mojo_node(m: &Manifest, crate_dir: &Path, js_only: &[JsOnly]) -> Result<Outcome> {
    let port = crate::codegen_mojo::port_mojo(m);
    let mut api = crate::codegen_mojo::parse_port_mojo(&port);
    match_export_names(m, &mut api);
    let mut files = vec![
        ("port.mojo".to_string(), port),
        (
            ".gitignore".into(),
            ".pixi/
.mojo-anything/
*.node
*.so
*.dylib
*.wasm
"
            .into(),
        ),
        ("README.md".into(), readme(m)),
        (
            MANIFEST.into(),
            serde_json::to_string_pretty(m)?
                + "
",
        ),
    ];
    files.extend(mojo_node_bindings(m, &api)?);
    write_files(crate_dir, &files)?;
    let mut notes = vec![format!(
        "Port each function in port.mojo, then: mojo-anything record {0} && mojo-anything build {0} && mojo-anything diff {0}",
        crate_dir.display()
    )];
    for c in &m.classes {
        notes.push(format!(
            "Class `{}` is not bridged to Mojo yet; it stays in {}.",
            c.name,
            m.language.name()
        ));
    }
    for j in js_only {
        notes.push(format!(
            "`{}` stays in {}: {}.",
            j.name,
            m.language.name(),
            j.reason
        ));
    }
    Ok(Outcome {
        crate_dir: crate_dir.to_path_buf(),
        kind: m.kind,
        files: files.into_iter().map(|(p, _)| p).collect(),
        exports: m.exports.iter().map(|f| f.name.clone()).collect(),
        notes,
    })
}

/// The generated layers of a `mojo-node` unit: `pixi.toml`, `json.mojo`, the dispatcher, the
/// Node-API addon source, `binding.gyp` and `index.cjs`.
fn mojo_node_bindings(m: &Manifest, api: &codegen::PortApi) -> Result<Vec<(String, String)>> {
    let mut exported = api.clone();
    exported
        .functions
        .retain(|f| m.exports.iter().any(|e| e.name == f.js_name));
    let api = &exported;
    let mut files = vec![
        (
            "pixi.toml".to_string(),
            crate::codegen_mojo_py::unit_pixi_toml(m, true),
        ),
        (
            "json.mojo".into(),
            crate::codegen_mojo::JSON_MOJO.to_string(),
        ),
        (
            crate::codegen_ffi::DISPATCHER.into(),
            crate::codegen_ffi::dispatcher_mojo(m, api).map_err(anyhow::Error::msg)?,
        ),
    ];
    // A wasm unit loads its module from `index.cjs`; only a Node unit has an addon to build.
    if m.kind == Kind::MojoNode {
        files.push((
            crate::harness_mojo_node::NODE_SHIM.into(),
            crate::codegen_mojo_node::node_shim_c(m),
        ));
        files.push((
            "binding.gyp".into(),
            crate::codegen_mojo_node::binding_gyp(m),
        ));
    }
    files.push((
        "index.cjs".into(),
        crate::codegen_mojo_node::index_cjs_mojo(m, api),
    ));
    Ok(files)
}

fn mojo_readme(m: &Manifest) -> String {
    let mut out = format!(
        "# {}

Mojo port of `{}`, a Python extension module. Generated by mojo-anything.

## Functions

",
        m.crate_name, m.unit
    );
    for f in &m.exports {
        out.push_str(&format!(
            "- `{}` (`{}:{}`)
",
            f.name, f.file, f.line
        ));
    }
    out.push_str(
        "
## Loop

```sh
mojo-anything record .   # record what the Python code does
mojo-anything build .    # build the Mojo extension module
mojo-anything diff .     # replay the recorded cases against Mojo
mojo-anything gate .     # format, warnings, tests, ported, API, diff
```
",
    );
    out
}

fn write_files(crate_dir: &Path, files: &[(String, String)]) -> Result<()> {
    for (path, text) in files {
        let target = crate_dir.join(path);
        if let Some(parent) = target.parent() {
            std::fs::create_dir_all(parent)?;
        }
        std::fs::write(&target, text).with_context(|| format!("writing {}", target.display()))?;
    }
    Ok(())
}

/// The generated C-side files: the exports under the C names and under the shadow names, the
/// structs, and the header. C signatures are fixed by the original, so they come from the
/// manifest; the port only says which functions raise.
fn c_bindings(m: &Manifest, api: &codegen::PortApi) -> Result<Vec<(String, String)>> {
    use crate::codegen_mojo_c as c;
    let mut files = vec![
        (
            crate::harness_mojo_c::EXPORTS.into(),
            c::exports_mojo(m, api, "").map_err(anyhow::Error::msg)?,
        ),
        (
            crate::harness_mojo_c::EXPORTS_SHADOW.into(),
            c::exports_mojo(m, api, c::SHADOW_PREFIX).map_err(anyhow::Error::msg)?,
        ),
        (
            format!("include/{}.h", m.lib_name()),
            crate::codegen_c::header(m),
        ),
    ];
    let structs = c::c_struct_defs_mojo(m).map_err(anyhow::Error::msg)?;
    if !structs.is_empty() {
        files.push((format!("{}.mojo", c::C_STRUCTS), structs));
    }
    Ok(files)
}

/// The generated layers of a Go or Ruby unit's Mojo port: `pixi.toml`, `json.mojo` when the
/// unit needs it, the library source and the language-side wrapper.
fn mojo_ffi_bindings(m: &Manifest, api: &codegen::PortApi) -> Result<Vec<(String, String)>> {
    if !m.batches.is_empty() {
        bail!("{BATCH_NOT_YET}");
    }
    // Only the unit's exports cross; a public helper in port.mojo stays inside the library.
    let mut exported = api.clone();
    exported
        .functions
        .retain(|f| m.exports.iter().any(|e| e.name == f.js_name));
    let api = &exported;
    // Go's typed path also needs the port's types to match the Go ones; a function that does
    // not falls back to the dispatcher, and so needs JSON.
    let json = crate::codegen_mojo::needs_json_mojo(m.language, api)
        || (m.language == crate::lang::Lang::Go && crate::codegen_go::uses_dispatcher(m, api));
    let mut files = vec![(
        "pixi.toml".to_string(),
        crate::codegen_mojo_py::unit_pixi_toml(m, json),
    )];
    if json {
        files.push((
            "json.mojo".into(),
            crate::codegen_mojo::JSON_MOJO.to_string(),
        ));
    }
    match m.language {
        crate::lang::Lang::Go => {
            // The wrapper package takes its name and types from the original sources: without
            // them it would be written under a wrong name beside the old one.
            if crate::codegen_go::unit_sources(m).is_empty() {
                bail!(
                    "cannot read the Go sources of `{}` under {}: is `root` in {MANIFEST} right?",
                    m.unit,
                    m.root.display()
                );
            }
            files.push((
                crate::codegen_go::EXPORTS.into(),
                crate::codegen_go::typed_mojo(m, api).map_err(anyhow::Error::msg)?,
            ));
            files.push(("go/go.mod".into(), crate::harness_go::wrapper_go_mod(m)));
            files.push((
                format!("go/{}.go", crate::codegen_go::package_name(m)),
                crate::codegen_go::wrapper(m, api),
            ));
        }
        crate::lang::Lang::Ruby => {
            files.push((
                crate::codegen_ffi::DISPATCHER.into(),
                crate::codegen_ffi::dispatcher_mojo(m, api).map_err(anyhow::Error::msg)?,
            ));
            files.push((
                format!("ruby/{}_native.rb", m.lib_name()),
                crate::codegen_ruby::native(m),
            ));
            files.push((
                crate::harness_ruby::wrapper_path(m),
                crate::codegen_ruby::wrapper(m, api).map_err(anyhow::Error::msg)?,
            ));
        }
        other => bail!("{} units are not ported to Mojo yet", other.name()),
    }
    Ok(files)
}

/// The generated layers of a `mojo-jvm` unit: `pixi.toml`, `json.mojo`, the dispatcher, and
/// the Java classes (the FFM native class, the codec, the error mapping and the wrappers).
fn mojo_jvm_bindings(m: &Manifest, api: &codegen::PortApi) -> Result<Vec<(String, String)>> {
    if !m.batches.is_empty() {
        bail!("{JVM_BATCH_NOT_YET}");
    }
    if !crate::jvm::is_jvm(m.language) {
        bail!("{} units do not bridge through Java", m.language.name());
    }
    // Only the unit's exports cross; a public helper in port.mojo stays inside the library.
    let mut exported = api.clone();
    exported
        .functions
        .retain(|f| m.exports.iter().any(|e| e.name == f.js_name));
    let api = &exported;
    let mut files = vec![
        (
            "pixi.toml".to_string(),
            crate::codegen_mojo_py::unit_pixi_toml(m, true),
        ),
        (
            "json.mojo".into(),
            crate::codegen_mojo::JSON_MOJO.to_string(),
        ),
        (
            crate::codegen_ffi::DISPATCHER.into(),
            crate::codegen_ffi::dispatcher_mojo(m, api).map_err(anyhow::Error::msg)?,
        ),
    ];
    files.extend(crate::codegen_mojo_jvm::support_files(m));
    files.extend(crate::codegen_mojo_jvm::wrappers_ffm(m, api));
    Ok(files)
}

fn bridge_mojo_jvm(m: &Manifest, crate_dir: &Path, kept: &[JsOnly]) -> Result<Outcome> {
    let port = crate::codegen_mojo::port_mojo(m);
    let mut api = crate::codegen_mojo::parse_port_mojo(&port);
    match_export_names(m, &mut api);
    // Everything is generated before anything is written: a unit that cannot cross leaves no
    // folder behind.
    let mut files = vec![
        ("port.mojo".to_string(), port),
        (".gitignore".into(), ".pixi/\n.mojo-anything/\n".into()),
        ("README.md".into(), readme(m)),
        (MANIFEST.into(), serde_json::to_string_pretty(m)? + "\n"),
    ];
    files.extend(mojo_jvm_bindings(m, &api)?);
    write_files(crate_dir, &files)?;
    let mut notes = vec![
        format!(
            "Port each function in port.mojo, then: mojo-anything record {0} && mojo-anything build {0} && mojo-anything diff {0}",
            crate_dir.display()
        ),
        "Callers compile the classes in java/ and load the library `build` writes (system \
         property mojo-anything.lib.<name>, MOJO_ANYTHING_LIB, or next to the classes); run the \
         JVM with --enable-native-access=ALL-UNNAMED (Java 22+)."
            .to_string(),
    ];
    let language = m.language.name();
    for c in &m.classes {
        notes.push(format!(
            "Class `{}` is not bridged to Mojo yet; it stays in {language}.",
            c.name
        ));
    }
    for j in kept {
        // A wrapper replaces the whole class it is named after, so a member it leaves out is
        // gone for callers, not kept in the original.
        if m.exports.iter().any(|f| f.file == j.file) {
            notes.push(format!(
                "`{}` is not ported ({}), but the wrappers in java/ replace the classes of {}: \
                 `gate`'s `java api` check fails until it is ported or moved to a class the unit \
                 does not replace.",
                j.name, j.reason, j.file
            ));
        } else {
            notes.push(format!("`{}` stays in {language}: {}.", j.name, j.reason));
        }
    }
    Ok(Outcome {
        crate_dir: crate_dir.to_path_buf(),
        kind: Kind::MojoJvm,
        files: files.into_iter().map(|(p, _)| p).collect(),
        exports: m.exports.iter().map(|f| f.name.clone()).collect(),
        notes,
    })
}

fn bridge_ffi_mojo(manifest: &Manifest, crate_dir: &Path, kept: &[JsOnly]) -> Result<Outcome> {
    let port = crate::codegen_mojo::port_mojo(manifest);
    let mut api = crate::codegen_mojo::parse_port_mojo(&port);
    match_export_names(manifest, &mut api);
    let mut files = vec![
        ("port.mojo".to_string(), port),
        (".gitignore".into(), ".pixi/\n.mojo-anything/\n".into()),
        ("README.md".into(), readme(manifest)),
        (
            MANIFEST.into(),
            serde_json::to_string_pretty(manifest)? + "\n",
        ),
    ];
    files.extend(mojo_ffi_bindings(manifest, &api)?);
    write_files(crate_dir, &files)?;
    format_wrapper(crate_dir);
    let mut notes = vec![format!(
        "Port each function in port.mojo, then: mojo-anything record {0} && mojo-anything build {0} && mojo-anything diff {0}",
        crate_dir.display()
    )];
    for j in kept {
        notes.push(format!(
            "`{}` stays in {}: {}.",
            j.name,
            manifest.language.name(),
            j.reason
        ));
    }
    Ok(Outcome {
        crate_dir: crate_dir.to_path_buf(),
        kind: Kind::Ffi,
        files: files.into_iter().map(|(p, _)| p).collect(),
        exports: manifest.exports.iter().map(|f| f.name.clone()).collect(),
        notes,
    })
}

fn bridge_c(manifest: &Manifest, crate_dir: &Path, kept: &[JsOnly]) -> Result<Outcome> {
    let port = crate::codegen_mojo_c::port_mojo_c(manifest).map_err(anyhow::Error::msg)?;
    let api = crate::codegen_mojo::parse_port_mojo(&port);
    let mut files = vec![
        ("port.mojo".to_string(), port),
        (
            "pixi.toml".into(),
            crate::codegen_mojo_py::pixi_toml(manifest),
        ),
        (".gitignore".into(), ".mojo-anything/\n.pixi/\n".into()),
        ("README.md".into(), readme(manifest)),
        (
            MANIFEST.into(),
            serde_json::to_string_pretty(manifest)? + "\n",
        ),
    ];
    files.extend(c_bindings(manifest, &api)?);
    write_files(crate_dir, &files)?;
    let mut notes = vec![
        format!(
            "Port each function in port.mojo, then: mojo-anything record {0} && mojo-anything build {0} && mojo-anything diff {0}",
            crate_dir.display()
        ),
        format!(
            "Link {}/{} instead of the C objects; include/{}.h has the prototypes.",
            crate::harness_mojo_c::BUILD_DIR,
            crate::harness_mojo_c::library_path(Path::new(""), manifest, false)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default(),
            manifest.lib_name()
        ),
        "The library is not self-contained yet: once it uses the Mojo standard library it needs \
         libKGENCompilerRTShared (.so, or .dylib on macOS) from the unit's \
         .pixi/envs/default/lib, and it finds it \
         there through an absolute RUNPATH. Ship that file beside it (and set the runpath to \
         $ORIGIN) before linking it into a program that runs elsewhere."
            .to_string(),
    ];
    for j in kept {
        notes.push(format!("`{}` stays in C: {}.", j.name, j.reason));
    }
    Ok(Outcome {
        crate_dir: crate_dir.to_path_buf(),
        kind: Kind::CAbi,
        files: files.into_iter().map(|(p, _)| p).collect(),
        exports: manifest.exports.iter().map(|f| f.name.clone()).collect(),
        notes,
    })
}

fn bridge_cpp(manifest: &Manifest, crate_dir: &Path, kept: &[JsOnly]) -> Result<Outcome> {
    let port = crate::codegen_cpp::port_mojo_cpp(manifest).map_err(anyhow::Error::msg)?;
    let api = crate::codegen_mojo::parse_port_mojo(&port);
    let mut files = vec![
        ("port.mojo".to_string(), port),
        (
            "pixi.toml".into(),
            crate::codegen_mojo_py::pixi_toml(manifest),
        ),
        (".gitignore".into(), ".mojo-anything/\n.pixi/\n".into()),
        ("README.md".into(), readme(manifest)),
        (
            MANIFEST.into(),
            serde_json::to_string_pretty(manifest)? + "\n",
        ),
    ];
    files.extend(crate::codegen_cpp::bindings(manifest, &api).map_err(anyhow::Error::msg)?);
    write_files(crate_dir, &files)?;
    let library = crate::harness_mojo_c::library_path(Path::new(""), manifest, false)
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_default();
    let mut notes = vec![
        format!(
            "Port each function in port.mojo, then: mojo-anything record {0} && mojo-anything build {0} && mojo-anything diff {0}",
            crate_dir.display()
        ),
        format!(
            "C++ callers keep the original header: compile {0} and link {1}/{library} instead of \
             {2}. The wrapper replaces only the bridged functions of {2}, so move its other \
             definitions into a file of their own that stays in the build (`gate`'s `cpp api` \
             names any left behind).",
            crate::codegen_cpp::WRAPPER,
            crate::harness_mojo_c::BUILD_DIR,
            manifest.unit
        ),
        "The library is not self-contained yet: once it uses the Mojo standard library it needs \
         libKGENCompilerRTShared (.so, or .dylib on macOS) from the unit's \
         .pixi/envs/default/lib, and it finds it \
         there through an absolute RUNPATH. Ship that file beside it (and set the runpath to \
         $ORIGIN) before linking it into a program that runs elsewhere."
            .to_string(),
    ];
    for j in kept {
        // Classes carry the generic `class: ` prefix; the C++ reason already says so.
        let reason = j.reason.strip_prefix("class: ").unwrap_or(&j.reason);
        notes.push(format!("`{}` stays in C++: {reason}.", j.name));
    }
    Ok(Outcome {
        crate_dir: crate_dir.to_path_buf(),
        kind: Kind::CAbi,
        files: files.into_iter().map(|(p, _)| p).collect(),
        exports: manifest.exports.iter().map(|f| f.name.clone()).collect(),
        notes,
    })
}

fn readme(m: &Manifest) -> String {
    let functions: String = m
        .exports
        .iter()
        .map(|f| format!("- `{}` (`{}:{}`)\n", f.name, f.file, f.line))
        .collect();
    format!(
        "# {name}\n\n{lang} port of `{unit}`, bridged with {kind}. Generated by mojo-anything.\n\n## Functions\n\n{functions}\n\
         ## Loop\n\n```sh\nmojo-anything record .   # record what the original does\nmojo-anything build .    # build {kind}\n\
         mojo-anything diff .     # run the recorded cases against the port\nmojo-anything shadow .   # run both in the app, log mismatches\n\
         mojo-anything gate .     # format, lint, tests, unsafe, API, diff\n```\n",
        name = m.crate_name,
        unit = m.unit,
        lang = if mojo_unit(m.kind, m.language) {
            "Mojo"
        } else {
            "Rust"
        },
        kind = match m.kind {
            Kind::MojoPy => "a Mojo Python extension",
            Kind::CAbi if m.language == crate::lang::Lang::Cpp => {
                "a C ABI shim (`cpp/shim.cpp`) and a C++ wrapper with the original signatures (`cpp/wrapper.cpp`)"
            }
            Kind::CAbi => "the C ABI",
            Kind::Ffi => "a JSON dispatcher",
            Kind::MojoNode => "a Node-API addon over the JSON dispatcher",
            Kind::MojoWasm => "a WebAssembly module of the JSON dispatcher",
            Kind::MojoJvm => "Java's Foreign Function & Memory API over the JSON dispatcher",
        },
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn node_kind_round_trips() {
        assert_eq!(serde_json::to_value(Kind::MojoNode).unwrap(), "mojo-node");
        let k: Kind = serde_json::from_value(serde_json::json!("mojo-node")).unwrap();
        assert_eq!(k, Kind::MojoNode);
        assert!(mojo_unit(Kind::MojoNode, crate::lang::Lang::Ts));
    }

    #[test]
    fn wasm_kind_round_trips() {
        assert_eq!(serde_json::to_value(Kind::MojoWasm).unwrap(), "mojo-wasm");
        let k: Kind = serde_json::from_value(serde_json::json!("mojo-wasm")).unwrap();
        assert_eq!(k, Kind::MojoWasm);
        assert!(mojo_unit(Kind::MojoWasm, crate::lang::Lang::Ts));
        assert!(k.mojo_js() && Kind::MojoNode.mojo_js() && !Kind::MojoPy.mojo_js());
    }

    #[test]
    fn readmes_name_the_port_language() {
        let m = |language: &str, kind: &str| -> Manifest {
            serde_json::from_str(&format!(
                r#"{{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "u",
                    "language": "{language}", "kind": "{kind}", "crate_name": "u-mojo",
                    "exports": []}}"#
            ))
            .unwrap()
        };
        for (language, kind) in [("go", "ffi"), ("ruby", "ffi")] {
            let text = readme(&m(language, kind));
            assert!(
                text.contains(
                    "
Mojo port of `u`"
                ),
                "{text}"
            );
        }
        assert!(readme(&m("java", "ffi")).contains(
            "
Rust port of `u`"
        ));
        // Every loop line starts at the margin, so the block reads as shell.
        let text = mojo_readme(&m("python", "mojo-py"));
        assert!(
            text.lines()
                .all(|l| !l.trim_start().starts_with("mojo-anything ")
                    || l.starts_with("mojo-anything ")),
            "{text}"
        );
    }

    #[test]
    fn mojo_types_from_ts() {
        use crate::lang::Lang;
        let ts = |t: &str, l: Lang| RType::from_ts(t).mojo(l);
        assert_eq!(ts("string", Lang::Ts), "String");
        assert_eq!(ts("number", Lang::Ts), "Float64");
        assert_eq!(ts("int", Lang::Go), "Int");
        assert_eq!(ts("boolean", Lang::Ts), "Bool");
        assert_eq!(ts("void", Lang::Ts), "None");
        assert_eq!(ts("string[]", Lang::Ts), "List[String]");
        assert_eq!(ts("string | null", Lang::Ts), "Optional[String]");
        assert_eq!(ts("(string | null)[]", Lang::Ts), "List[Optional[String]]");
        assert_eq!(ts("unknown", Lang::Python), "PythonObject");
        // Python's `number` and `int` keep Python's int-or-float, unbounded semantics.
        assert_eq!(ts("number", Lang::Python), "PyNum");
        assert_eq!(ts("int", Lang::Python), "PyNum");
        assert_eq!(ts("number[]", Lang::Python), "List[PyNum]");
    }

    #[test]
    fn mojo_py_kind_serialises() {
        assert_eq!(serde_json::to_string(&Kind::MojoPy).unwrap(), "\"mojo-py\"");
        let k: Kind = serde_json::from_str("\"mojo-py\"").unwrap();
        assert_eq!(k, Kind::MojoPy);
    }

    #[test]
    fn pyo3_manifest_says_rebridge() {
        let dir = std::env::temp_dir().join(format!("mojo-anything-pyo3-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(MANIFEST),
            r#"{"schema": "rust-anything/bridge@1", "root": "/r", "unit": "src/x.py", "language": "python", "kind": "pyo3", "crate_name": "x-rs", "exports": []}"#,
        )
        .unwrap();
        let err = format!("{:#}", Manifest::load(&dir).unwrap_err());
        assert!(err.contains("bridge again"), "{err}");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn napi_manifest_says_rebridge() {
        for kind in ["napi", "wasm"] {
            let dir = std::env::temp_dir().join(format!(
                "mojo-anything-{kind}-rebridge-{}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(
                dir.join(MANIFEST),
                format!(
                    r#"{{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "src/x.ts", "kind": "{kind}", "crate_name": "x-rs", "exports": []}}"#
                ),
            )
            .unwrap();
            let err = format!("{:#}", Manifest::load(&dir).unwrap_err());
            assert!(err.contains("bridge again"), "{kind}: {err}");
            std::fs::remove_dir_all(&dir).unwrap();
        }
    }

    #[test]
    fn java_ffi_manifest_says_rebridge() {
        for lang in ["java", "kotlin"] {
            let dir = std::env::temp_dir().join(format!(
                "mojo-anything-{lang}-ffi-rebridge-{}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            std::fs::write(
                dir.join(MANIFEST),
                format!(
                    r#"{{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "src/main/x/", "language": "{lang}", "kind": "ffi", "crate_name": "x-rs", "exports": []}}"#
                ),
            )
            .unwrap();
            // With or without its Cargo.toml: the JNI crate cannot be built any more.
            let err = format!("{:#}", Manifest::load(&dir).unwrap_err());
            assert!(err.contains("bridge again"), "{lang}: {err}");
            assert!(err.contains("JNI"), "{lang}: {err}");
            std::fs::remove_dir_all(&dir).unwrap();
        }
    }

    #[test]
    fn rust_c_unit_says_rebridge() {
        let dir = std::env::temp_dir().join(format!("mojo-anything-rust-c-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(MANIFEST),
            r#"{"schema": "mojo-anything/bridge@1", "root": "/r", "unit": "x.c", "language": "c", "kind": "c-abi", "crate_name": "x-rs", "exports": []}"#,
        )
        .unwrap();
        std::fs::write(dir.join("Cargo.toml"), "[package]\nname = \"x-rs\"\n").unwrap();
        let err = format!("{:#}", Manifest::load(&dir).unwrap_err());
        assert!(err.contains("bridge again"), "{err}");
        // The same manifest without the Rust crate is a Mojo unit and loads.
        std::fs::remove_file(dir.join("Cargo.toml")).unwrap();
        assert!(Manifest::load(&dir).is_ok());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn loads_old_manifest_name() {
        let dir = std::env::temp_dir().join(format!("mojo-anything-old-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(
            dir.join(OLD_MANIFEST),
            r#"{"schema": "rust-anything/bridge@1", "root": "/r", "unit": "src/x.ts", "kind": "mojo-node", "crate_name": "x-mojo", "exports": []}"#,
        )
        .unwrap();
        let m = Manifest::load(&dir).unwrap();
        assert_eq!(m.crate_name, "x-mojo");
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn a_relative_root_is_resolved_from_the_crate_and_kept_relative() {
        let base = std::env::temp_dir().join(format!("mojo-anything-root-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        let crate_dir = base.join("repo/rust/x-rs");
        std::fs::create_dir_all(&crate_dir).unwrap();
        std::fs::write(
            crate_dir.join(MANIFEST),
            r#"{"schema": "mojo-anything/bridge@1", "root": "../..", "unit": "src/x.ts", "kind": "mojo-node", "crate_name": "x-rs", "exports": []}"#,
        )
        .unwrap();
        let m = Manifest::load(&crate_dir).unwrap();
        assert_eq!(m.root, base.join("repo").canonical().unwrap());
        assert_eq!(m.root_written.as_deref(), Some(Path::new("../..")));
        // Written back, the file keeps the relative root.
        let mut back = m.clone();
        if let Some(w) = back.root_written.clone() {
            back.root = w;
        }
        assert!(
            serde_json::to_string(&back)
                .unwrap()
                .contains(r#""root":"../..""#)
        );
        std::fs::remove_dir_all(&base).unwrap();
    }

    #[test]
    fn maps_ts_types() {
        assert_eq!(RType::from_ts("string").rust(), "String");
        assert_eq!(RType::from_ts("readonly string[]").rust(), "Vec<String>");
        assert_eq!(RType::from_ts("Array<number>").rust(), "Vec<f64>");
        assert_eq!(
            RType::from_ts("string | undefined").rust(),
            "Option<String>"
        );
        assert_eq!(RType::from_ts("'a' | 'b'").rust(), "String");
        assert_eq!(RType::from_ts("Promise<boolean>").rust(), "bool");
        assert_eq!(
            RType::from_ts("Map<string, number>").rust(),
            "serde_json::Value"
        );
        assert_eq!(
            RType::from_ts("string | number").rust(),
            "serde_json::Value"
        );
        assert_eq!(
            RType::from_ts("Record<string, string | number>").rust(),
            "serde_json::Value"
        );
        assert_eq!(
            RType::from_ts("(string | undefined)").rust(),
            "Option<String>"
        );
        assert_eq!(RType::from_ts("(a) | (b)").rust(), "serde_json::Value");
    }

    #[test]
    fn keeps_unbridgeable_exports_in_js() {
        let source = "export interface LineIndex {\n  readonly lineCount: number\n  position(offset: number): number\n}\n\
            export interface Range { start: number, end: number }\n\
            export function keyMatcher(globs: readonly string[]): (key: string) => boolean { return () => true }\n\
            export function globToRegExp(glob: string): RegExp { return /x/ }\n\
            export function createLineIndex(text: string): LineIndex { return null! }\n\
            export function* walk(tree: object) {}\n\
            export function sortTree(tree: object, compare: (a: string, b: string) => number) {}\n\
            export function contains(range: Range, offset: number): boolean { return true }\n";
        let types = local_types("a.ts", source);
        let reasons: Vec<(String, Option<String>)> = exported_functions("a.ts", source)
            .iter()
            .map(|f| (f.name.clone(), js_only_reason(f, &types)))
            .collect();
        let js_only: Vec<&str> = reasons
            .iter()
            .filter(|(_, r)| r.is_some())
            .map(|(n, _)| n.as_str())
            .collect();
        assert_eq!(
            js_only,
            [
                "keyMatcher",
                "globToRegExp",
                "createLineIndex",
                "walk",
                "sortTree"
            ]
        );
    }

    #[test]
    fn resolves_simple_aliases() {
        let types = local_types(
            "m.ts",
            "export type KeyString = string\nexport type Leaf = string | null\nexport type Map2<T> = T\n",
        );
        assert_eq!(
            resolve_aliases("readonly KeyString[]", &types),
            "readonly string[]"
        );
        assert_eq!(resolve_aliases("Leaf", &types), "(string | null)");
        assert_eq!(resolve_aliases("Map2<KeyString>", &types), "Map2<string>");
    }

    #[test]
    fn substitutes_simple_constraints() {
        let found = exported_functions(
            "a.ts",
            "export function up<T extends string>(s: T): Uppercase<T> { return s as any }\n\
             export function pick<T>(x: T): T { return x }\n\
             export function first<S extends readonly string[]>(xs: S, n?: number): string { return '' }\n",
        );
        let mut fns = found;
        for f in &mut fns {
            substitute_constraints(f, &[]);
        }
        assert_eq!(fns[0].params[0].ts_type, "(string)");
        assert!(fns[0].type_params.is_empty());
        assert_eq!(fns[1].type_params, ["T"]);
        assert_eq!(fns[2].params[0].ts_type, "(readonly string[])");
        assert!(js_only_reason(&fns[0], &[]).is_none() && js_only_reason(&fns[1], &[]).is_some());
    }

    #[test]
    fn as_json_bridges_a_data_generic() {
        let mut fns = exported_functions(
            "a.ts",
            "export function paginate<T>(items: T[], page: number): { data: T[] } { return { data: items } }\n",
        );
        assert!(js_only_reason(&fns[0], &[]).is_some());
        substitute_json(&mut fns[0], &["T".to_string()]);
        assert!(fns[0].type_params.is_empty());
        assert_eq!(fns[0].params[0].ts_type, "unknown[]");
        assert_eq!(fns[0].returns, "{ data: unknown[] }");
        assert!(js_only_reason(&fns[0], &[]).is_none());
    }

    #[test]
    fn makes_rust_names() {
        assert_eq!(snake_case("fuzzyScore"), "fuzzy_score");
        assert_eq!(snake_case("type"), "r#type");
        assert_eq!(snake_case("toURL"), "to_url");
        assert_eq!(snake_case("parseHTMLString"), "parse_html_string");
    }
}
