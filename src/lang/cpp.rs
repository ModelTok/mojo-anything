//! C++: build folders, `#include`s, risks, and the free functions a generated `extern "C"` shim
//! can carry to a Mojo port: integers, floating-point numbers, `bool`, `std::string` and
//! `std::vector` of numbers, by value or `const&`. Everything else is refused with a reason.

use std::collections::{HashMap, HashSet};
use std::path::Path;

use anyhow::Result;
use tree_sitter::Node;

use super::syntax::{self, named_children, text};
use crate::risks::Risk;
use crate::ts::deps::CrateMatch;
use crate::ts::discover::{FileKind, Package, SourceFile, Workspace};
use crate::ts::exports::{ExportedClass, ExportedFn, Param};
use crate::ts::scan::{FileFacts, Import};

fn language() -> tree_sitter::Language {
    tree_sitter_cpp::LANGUAGE.into()
}

/// Implementation files.
pub const SOURCES: &[&str] = &["cpp", "cc", "cxx"];
/// Headers (`.h` is shared with C; see `Lang::detect`).
pub const HEADERS: &[&str] = &["h", "hpp", "hh", "hxx"];

/// The advice every refusal ends with.
const FACADE: &str =
    "write a free function with plain arguments over it (a facade) and bridge that";

const SKIP_DIRS: &[&str] = &[
    "build",
    "dist",
    "target",
    "vendor",
    "third_party",
    "external",
    "fixtures",
    "examples",
    "docs",
];

fn extension(name: &str) -> &str {
    name.rsplit_once('.').map_or("", |(_, e)| e)
}

/// Whether `name` is a C++ implementation file.
pub fn is_source(name: &str) -> bool {
    SOURCES.contains(&extension(name))
}

fn is_header(name: &str) -> bool {
    HEADERS.contains(&extension(name))
}

pub fn discover(root: &Path) -> Result<Workspace> {
    let mut manifests = Vec::new();
    let mut files = Vec::new();
    let walker = crate::walk::filtered(root, |e| {
        !(e.file_type().is_some_and(|t| t.is_dir())
            && SKIP_DIRS.contains(&e.file_name().to_string_lossy().as_ref()))
    })
    .hidden(true)
    .require_git(false)
    .build();
    for entry in walker.flatten() {
        if !entry.file_type().is_some_and(|t| t.is_file()) {
            continue;
        }
        let Ok(rel) = entry.path().strip_prefix(root) else {
            continue;
        };
        let rel = rel.to_string_lossy().replace('\\', "/");
        let name = rel.rsplit('/').next().unwrap_or(&rel);
        if matches!(name, "Makefile" | "CMakeLists.txt" | "meson.build") {
            let dir = rel
                .rsplit_once('/')
                .map_or(String::new(), |(d, _)| d.to_string());
            if !manifests.contains(&dir) {
                manifests.push(dir);
            }
        } else if is_source(name) || is_header(name) {
            let stem = name.rsplit_once('.').map_or(name, |(s, _)| s);
            let is_test = name.starts_with("test_")
                || stem.ends_with("_test")
                || rel.split('/').any(|p| matches!(p, "tests" | "test"));
            files.push((
                rel,
                if is_test {
                    FileKind::Test
                } else {
                    FileKind::Source
                },
            ));
        }
    }
    let root_name = || {
        root.file_name()
            .map_or_else(|| "root".into(), |n| n.to_string_lossy().into_owned())
    };
    let mut packages: Vec<Package> = manifests
        .iter()
        .map(|dir| Package {
            name: if dir.is_empty() {
                root_name()
            } else {
                dir.clone()
            },
            src_root: if root.join(dir).join("src").is_dir() {
                join(dir, "src")
            } else {
                dir.clone()
            },
            dir: dir.clone(),
            deps: Vec::new(),
            dev_deps: Vec::new(),
            namespaces: Vec::new(),
        })
        .collect();
    if !packages.iter().any(|p| p.dir.is_empty()) {
        packages.push(Package {
            name: root_name(),
            dir: String::new(),
            src_root: if root.join("src").is_dir() {
                "src".into()
            } else {
                String::new()
            },
            deps: Vec::new(),
            dev_deps: Vec::new(),
            namespaces: Vec::new(),
        });
    }
    packages.sort_by(|a, b| a.dir.cmp(&b.dir));
    // A header with an implementation file is that file's interface: one unit, not two.
    let stems: HashSet<String> = files
        .iter()
        .filter(|(f, _)| is_source(f))
        .filter_map(|(f, _)| f.rsplit_once('.').map(|(s, _)| s.to_string()))
        .collect();
    files.retain(|(f, _)| {
        !is_header(f) || f.rsplit_once('.').is_none_or(|(s, _)| !stems.contains(s))
    });
    files.sort_by(|a, b| a.0.cmp(&b.0));
    let files = files
        .into_iter()
        .map(|(path, kind)| {
            let package = packages
                .iter()
                .enumerate()
                .filter(|(_, p)| p.dir.is_empty() || path.starts_with(&format!("{}/", p.dir)))
                .max_by_key(|(_, p)| p.dir.len())
                .map_or(0, |(i, _)| i);
            SourceFile {
                path,
                package,
                kind,
            }
        })
        .collect();
    Ok(Workspace { packages, files })
}

fn join(dir: &str, rest: &str) -> String {
    if dir.is_empty() {
        rest.to_string()
    } else {
        format!("{dir}/{rest}")
    }
}

pub fn scan(source: &str) -> FileFacts {
    let mut facts = FileFacts {
        loc: syntax::loc(source),
        ..FileFacts::default()
    };
    let Some(tree) = syntax::parse(&language(), source) else {
        return facts;
    };
    let root = tree.root_node();
    facts.parse_errors = usize::from(root.has_error());
    let add = |facts: &mut FileFacts, risk: Risk, node: Node| {
        facts
            .risks
            .entry(risk)
            .or_default()
            .push(syntax::line(node))
    };
    syntax::walk(root, |node| match node.kind() {
        "preproc_include" => {
            if let Some(path) = node.child_by_field_name("path") {
                let raw = text(path, source);
                let spec = if raw.starts_with('"') {
                    raw.trim_matches('"').to_string()
                } else {
                    format!("<{}>", raw.trim_matches(|c| c == '<' || c == '>'))
                };
                facts.imports.push(Import {
                    specifier: spec,
                    type_only: false,
                    dynamic: false,
                });
            }
        }
        "pointer_expression" | "pointer_declarator" | "new_expression" | "delete_expression" => {
            add(&mut facts, Risk::Pointers, node)
        }
        "throw_statement" | "try_statement" => add(&mut facts, Risk::Exceptions, node),
        "template_declaration" => add(&mut facts, Risk::DynamicTyping, node),
        "base_class_clause" => add(&mut facts, Risk::ClassInheritance, node),
        "call_expression" => {
            let callee = node
                .child_by_field_name("function")
                .map_or("", |f| text(f, source));
            let bare = callee.rsplit("::").next().unwrap_or(callee);
            match bare {
                "malloc" | "calloc" | "realloc" | "free" | "memcpy" | "memmove" => {
                    add(&mut facts, Risk::Pointers, node)
                }
                "strlen" | "strcpy" | "strcmp" | "sprintf" | "snprintf" | "substr" => {
                    add(&mut facts, Risk::StringOffsets, node)
                }
                "setjmp" | "longjmp" | "exit" | "abort" | "terminate" => {
                    add(&mut facts, Risk::Exceptions, node)
                }
                _ => {}
            }
        }
        "qualified_identifier" | "qualified_type_identifier" => {
            let t = text(node, source);
            if ["std::thread", "std::mutex", "std::atomic", "std::async"]
                .iter()
                .any(|p| t.starts_with(p))
            {
                add(&mut facts, Risk::Concurrency, node);
            } else if ["std::unordered_map", "std::unordered_set"]
                .iter()
                .any(|p| t.starts_with(p))
            {
                add(&mut facts, Risk::UnorderedIteration, node);
            }
        }
        "binary_expression" => {
            let op = node
                .child_by_field_name("operator")
                .map_or("", |o| text(o, source));
            if matches!(op, "/" | "%") {
                add(&mut facts, Risk::DivisionSemantics, node);
            }
        }
        "cast_expression" => add(&mut facts, Risk::IntegerSemantics, node),
        "gnu_asm_expression" | "ms_declspec_modifier" => {
            add(&mut facts, Risk::PlatformSpecific, node)
        }
        "null" | "nullptr" => add(&mut facts, Risk::NullReferences, node),
        "preproc_function_def" => add(&mut facts, Risk::Reflection, node),
        "for_statement" | "for_range_loop" | "while_statement" | "do_statement" => facts.loops += 1,
        _ => {}
    });
    facts
}

/// `#include "x.hpp"`: the header relative to the including file or the project's include
/// folders, then the implementation beside it, so the unit graph follows implementations.
pub fn resolve(from: &str, spec: &str, index: &HashMap<&str, usize>) -> super::Resolution {
    if spec.starts_with('<') {
        let bare = spec.trim_matches(|c| c == '<' || c == '>');
        let standard = !bare.contains('.') && !bare.contains('/')
            || super::c::STANDARD_HEADERS.contains(&spec);
        return match lookup(spec) {
            Some(m) if m.replacement == "std" => super::Resolution::Stdlib,
            _ if standard => super::Resolution::Stdlib,
            _ => super::Resolution::External(spec.to_string()),
        };
    }
    let dir = from.rsplit_once('/').map_or("", |(d, _)| d);
    let candidates = [
        join(dir, spec),
        spec.to_string(),
        join("include", spec),
        join("src", spec),
    ];
    for header in candidates.iter().filter_map(|c| normalize(c)) {
        let stem = header.rsplit_once('.').map_or(header.as_str(), |(s, _)| s);
        let implementation = SOURCES
            .iter()
            .find_map(|e| index.get(format!("{stem}.{e}").as_str()));
        if let Some(i) = implementation.or_else(|| index.get(header.as_str())) {
            return super::Resolution::File(*i);
        }
    }
    super::Resolution::Unresolved
}

fn normalize(path: &str) -> Option<String> {
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

/// Mojo counterparts of common C and C++ libraries, by header: C++ shares C's table.
pub fn lookup(header: &str) -> Option<CrateMatch> {
    crate::crates::find("c", header)
}

// ---- types -----------------------------------------------------------------------------------

/// How a C++ type crosses the shim.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CppType {
    /// A C scalar, as `lang::c::scalar` spells it (`int64_t`, `double`, `bool`).
    Scalar(String),
    /// `std::string`.
    Str,
    /// `std::vector` of a C scalar.
    Vec(String),
}

/// A parameter or result type: what crosses, and whether it is passed as `const&`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Crossing {
    pub ty: CppType,
    pub by_ref: bool,
}

impl Crossing {
    /// The type as the wrapper and the shim declare it (`const std::vector<double> &`).
    pub fn spelled(&self) -> String {
        let base = match &self.ty {
            CppType::Scalar(s) => s.clone(),
            CppType::Str => "std::string".into(),
            CppType::Vec(e) => format!("std::vector<{e}>"),
        };
        if self.by_ref {
            format!("const {base} &")
        } else {
            base
        }
    }

    /// The type in the dialect the input generator reads.
    pub fn dialect(&self) -> String {
        let scalar =
            |s: &str| super::c::scalar(s).map_or("unknown".to_string(), |(d, ..)| d.to_string());
        match &self.ty {
            CppType::Scalar(s) => scalar(s),
            CppType::Str => "string".into(),
            CppType::Vec(e) => format!("{}[]", scalar(e)),
        }
    }
}

/// Reads back what [`Crossing::spelled`] wrote (a manifest's `native_type`).
pub fn crossing(native: &str) -> Option<Crossing> {
    let t = native.trim();
    let (by_ref, base) = match t.strip_prefix("const ").and_then(|r| r.strip_suffix('&')) {
        Some(inner) => (true, inner.trim()),
        None => (false, t),
    };
    let ty = if base == "std::string" {
        CppType::Str
    } else if let Some(e) = base
        .strip_prefix("std::vector<")
        .and_then(|r| r.strip_suffix('>'))
    {
        CppType::Vec(e.trim().to_string())
    } else if super::c::scalar(base).is_some() {
        CppType::Scalar(base.to_string())
    } else {
        return None;
    };
    Some(Crossing { ty, by_ref })
}

thread_local! {
    static ALIASES: std::cell::RefCell<HashMap<String, String>> =
        std::cell::RefCell::new(HashMap::new());
    static CLASSES: std::cell::RefCell<HashSet<String>> =
        std::cell::RefCell::new(HashSet::new());
}

/// Makes `exports` read the project's scalar aliases (`using Real64 = double;`,
/// `typedef double Real64;`) and the names of its classes and structs, on this thread.
pub fn use_typedefs(root: &Path) {
    let mut raw = HashMap::new();
    let mut classes = HashSet::new();
    for entry in crate::walk::builder(root)
        .require_git(false)
        .build()
        .flatten()
    {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !(is_source(&name) || is_header(&name)) {
            continue;
        }
        if let Ok(source) = std::fs::read_to_string(entry.path()) {
            collect_types(&source, &mut raw, &mut classes);
        }
    }
    let mut aliases = HashMap::new();
    for name in raw.keys() {
        let mut ty: String = raw[name].clone();
        for _ in 0..8 {
            match raw.get(&ty) {
                Some(next) => ty = next.clone(),
                None => break,
            }
        }
        if super::c::scalar(&ty).is_some() {
            aliases.insert(name.clone(), ty);
        }
    }
    ALIASES.with(|a| *a.borrow_mut() = aliases);
    CLASSES.with(|c| *c.borrow_mut() = classes);
}

fn collect_types(
    source: &str,
    aliases: &mut HashMap<String, String>,
    classes: &mut HashSet<String>,
) {
    let Some(tree) = syntax::parse(&language(), source) else {
        return;
    };
    syntax::walk(tree.root_node(), |node| match node.kind() {
        "alias_declaration" => {
            if let (Some(name), Some(ty)) = (
                node.child_by_field_name("name"),
                node.child_by_field_name("type"),
            ) {
                aliases.insert(
                    text(name, source).to_string(),
                    scalar_spelling(text(ty, source)),
                );
            }
        }
        "type_definition" => {
            if let (Some(name), Some(ty)) = (
                node.child_by_field_name("declarator"),
                node.child_by_field_name("type"),
            ) && name.kind() == "type_identifier"
            {
                aliases.insert(
                    text(name, source).to_string(),
                    scalar_spelling(text(ty, source)),
                );
            }
        }
        "class_specifier" | "struct_specifier" | "union_specifier" => {
            if let Some(name) = node.child_by_field_name("name") {
                classes.insert(text(name, source).to_string());
            }
        }
        _ => {}
    });
}

/// A scalar type's words with `std::` and `const` dropped (`std::int64_t` is `int64_t`).
fn scalar_spelling(t: &str) -> String {
    t.split_whitespace()
        .filter(|w| *w != "const")
        .map(|w| w.strip_prefix("std::").unwrap_or(w))
        .collect::<Vec<_>>()
        .join(" ")
}

/// What a type node names, before references and pointers.
enum Named {
    Known(CppType),
    /// A class, struct or other type the subset does not take, as written.
    Other(String),
}

fn named(node: Node, source: &str, using_std: bool) -> Named {
    let written = text(node, source)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    fn template<'t>(t: Node<'t>, source: &str) -> Option<(String, Node<'t>)> {
        let name = t.child_by_field_name("name")?;
        let args = t.child_by_field_name("arguments")?;
        let first = named_children(args).into_iter().next()?;
        Some((text(name, source).to_string(), first))
    }
    let scalar = |s: &str| -> Option<String> {
        let s = scalar_spelling(s);
        let s = ALIASES.with(|a| a.borrow().get(&s).cloned()).unwrap_or(s);
        super::c::scalar(&s)
            .is_some_and(|(d, ..)| d != "void")
            .then_some(s)
    };
    let vector_of = |arg: Node| -> Named {
        let inner = arg.child_by_field_name("type").unwrap_or(arg);
        match named(inner, source, using_std) {
            Named::Known(CppType::Scalar(s)) if s != "bool" => Named::Known(CppType::Vec(s)),
            _ => Named::Other(written.clone()),
        }
    };
    match node.kind() {
        "primitive_type" | "sized_type_specifier" => scalar(&written)
            .map_or(Named::Other(written.clone()), |s| {
                Named::Known(CppType::Scalar(s))
            }),
        "type_identifier" => {
            if using_std && written == "string" {
                return Named::Known(CppType::Str);
            }
            scalar(&written).map_or(Named::Other(written.clone()), |s| {
                Named::Known(CppType::Scalar(s))
            })
        }
        "template_type" if using_std => match template(node, source) {
            Some((name, arg)) if name == "vector" => vector_of(arg),
            _ => Named::Other(written),
        },
        "qualified_identifier" | "qualified_type_identifier" => {
            let scope = node
                .child_by_field_name("scope")
                .map_or("", |s| text(s, source));
            let Some(name) = node.child_by_field_name("name") else {
                return Named::Other(written);
            };
            if scope != "std" {
                return Named::Other(written);
            }
            match name.kind() {
                "type_identifier" if text(name, source) == "string" => Named::Known(CppType::Str),
                "type_identifier" => scalar(&written).map_or(Named::Other(written.clone()), |s| {
                    Named::Known(CppType::Scalar(s))
                }),
                "template_type" => match template(name, source) {
                    Some((n, arg)) if n == "vector" => vector_of(arg),
                    _ => Named::Other(written),
                },
                _ => Named::Other(written),
            }
        }
        _ => Named::Other(written),
    }
}

/// How a declarator wraps its name.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Wrap {
    Value,
    Ref,
    RRef,
    Pointer,
    Array,
    Function,
}

/// A declarator's wrapping (outermost first matters only for the first) and its name.
fn unwrap(mut node: Option<Node>, source: &str) -> (Wrap, Option<String>) {
    let mut wrap = Wrap::Value;
    let mut name = None;
    while let Some(n) = node {
        let next = match n.kind() {
            "reference_declarator" | "abstract_reference_declarator" => {
                if wrap == Wrap::Value {
                    wrap = if text(n, source).trim_start().starts_with("&&") {
                        Wrap::RRef
                    } else {
                        Wrap::Ref
                    };
                }
                named_children(n).into_iter().next()
            }
            "pointer_declarator" | "abstract_pointer_declarator" => {
                if wrap == Wrap::Value {
                    wrap = Wrap::Pointer;
                }
                n.child_by_field_name("declarator")
            }
            "array_declarator" | "abstract_array_declarator" => {
                if wrap == Wrap::Value {
                    wrap = Wrap::Array;
                }
                n.child_by_field_name("declarator")
            }
            "function_declarator" | "abstract_function_declarator" => {
                if wrap == Wrap::Value {
                    wrap = Wrap::Function;
                }
                n.child_by_field_name("declarator")
            }
            "identifier" | "field_identifier" => {
                name = Some(text(n, source).to_string());
                None
            }
            _ => None,
        };
        node = next;
    }
    (wrap, name)
}

/// Whether a declaration's qualifiers (around its type) include `const`, and any other
/// qualifier the subset refuses (`volatile`).
fn qualifiers(node: Node, source: &str) -> (bool, Option<String>) {
    let mut is_const = false;
    let mut other = None;
    for child in named_children(node) {
        if child.kind() == "type_qualifier" {
            match text(child, source) {
                "const" => is_const = true,
                q => other = Some(q.to_string()),
            }
        }
    }
    (is_const, other)
}

/// A parameter's crossing, or why it cannot cross.
fn param_crossing(
    p: Node,
    source: &str,
    using_std: bool,
) -> Result<(Crossing, Option<String>), String> {
    let (is_const, other) = qualifiers(p, source);
    let ty_node = p
        .child_by_field_name("type")
        .ok_or("has a parameter without a type")?;
    let (wrap, name) = unwrap(p.child_by_field_name("declarator"), source);
    let written = text(p, source)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    let written = match &name {
        Some(n) => written
            .strip_suffix(n.as_str())
            .unwrap_or(&written)
            .trim_end()
            .to_string(),
        None => written,
    };
    if let Some(q) = other {
        return Err(format!("takes a `{q}` parameter (`{written}`); {FACADE}"));
    }
    let ty = match named(ty_node, source, using_std) {
        Named::Known(t) => t,
        Named::Other(t) => {
            let class = CLASSES.with(|c| c.borrow().contains(t.rsplit("::").next().unwrap_or(&t)));
            return Err(match wrap {
                Wrap::Ref if !is_const => format!(
                    "takes `{written}`, a state object by non-const reference, which the C ABI \
                     shim cannot pass; {FACADE}"
                ),
                Wrap::Pointer if class => format!(
                    "takes `{written}`, a pointer to a state object, which the C ABI shim cannot \
                     pass; {FACADE}"
                ),
                Wrap::Pointer | Wrap::Array => format!(
                    "takes a pointer (`{written}`), which the C ABI shim does not pass; {FACADE}"
                ),
                _ if t.contains("vector<bool>") => format!(
                    "uses `{t}`, which stores bits, not `bool`s; {FACADE} over `std::vector<int>`"
                ),
                _ if t == "long double" => {
                    format!("uses `long double`, which Mojo cannot pass; {FACADE}")
                }
                _ => format!(
                    "uses `{t}`, which the C++ subset does not take (integers, floating-point \
                     numbers, `bool`, `std::string`, `std::vector` of numbers); {FACADE}"
                ),
            });
        }
    };
    let by_ref = match wrap {
        Wrap::Value => false,
        Wrap::Ref if is_const => true,
        Wrap::Ref => {
            return Err(format!(
                "writes through a non-const reference (`{written}`); {FACADE} (one that returns the value)"
            ));
        }
        Wrap::RRef => {
            return Err(format!(
                "takes an rvalue reference (`{written}`); {FACADE} (one that takes it by value)"
            ));
        }
        Wrap::Pointer | Wrap::Array => {
            return Err(format!(
                "takes a pointer (`{written}`), which the C ABI shim does not pass; {FACADE}"
            ));
        }
        Wrap::Function => return Err(format!("takes a function (`{written}`); {FACADE}")),
    };
    Ok((Crossing { ty, by_ref }, name))
}

// ---- exports ---------------------------------------------------------------------------------

/// The C symbol the shim and the Mojo port export for a function (`kit::text::join` is
/// `cpp__kit__text__join`).
pub fn symbol(qualified: &str) -> String {
    format!("cpp__{}", qualified.replace("::", "__"))
}

/// The function's name without its namespaces: the name of its port in `port.mojo`.
pub fn port_name(qualified: &str) -> &str {
    qualified.rsplit("::").next().unwrap_or(qualified)
}

/// The namespaces of a qualified name (`kit::text` for `kit::text::join`).
pub fn namespace(qualified: &str) -> Option<&str> {
    qualified.rsplit_once("::").map(|(ns, _)| ns)
}

fn uses_std(source: &str) -> bool {
    source.contains("using namespace std")
}

/// Exported free functions in implementation files, every one outside the subset with the
/// reason it stays in C++, and the classes with member functions (which stay in C++).
pub fn exports(path: &str, source: &str) -> (Vec<ExportedFn>, Vec<ExportedClass>) {
    if !is_source(path) {
        return (Vec::new(), Vec::new());
    }
    let Some(tree) = syntax::parse(&language(), source) else {
        return (Vec::new(), Vec::new());
    };
    let using_std = uses_std(source);
    let mut functions = Vec::new();
    let mut classes = Vec::new();
    visit(
        tree.root_node(),
        source,
        path,
        &[],
        using_std,
        &mut functions,
        &mut classes,
    );
    // One C symbol per name: an overloaded name is refused once, for all its definitions.
    let mut counts: HashMap<String, usize> = HashMap::new();
    for f in &functions {
        *counts.entry(f.name.clone()).or_default() += 1;
    }
    let mut seen = HashSet::new();
    functions.retain(|f| seen.insert(f.name.clone()));
    let mut ports: HashMap<String, String> = HashMap::new();
    for f in &mut functions {
        let n = counts[&f.name];
        if n > 1 {
            f.blocker = Some(format!(
                "is overloaded ({n} definitions): the C ABI shim needs one signature per name; \
                 give each overload its own name in a facade"
            ));
            continue;
        }
        if f.blocker.is_none() {
            let port = port_name(&f.name).to_string();
            match ports.get(&port) {
                Some(first) => {
                    f.blocker = Some(format!(
                        "has the same name as `{first}`, and the Mojo port names functions without \
                         their namespace; rename one in a facade"
                    ));
                }
                None => {
                    ports.insert(port, f.name.clone());
                }
            }
        }
    }
    (functions, classes)
}

fn visit(
    node: Node,
    source: &str,
    path: &str,
    namespaces: &[String],
    using_std: bool,
    functions: &mut Vec<ExportedFn>,
    classes: &mut Vec<ExportedClass>,
) {
    for child in named_children(node) {
        match child.kind() {
            "namespace_definition" => {
                // An anonymous namespace has internal linkage: nothing in it is exported.
                let Some(name) = child.child_by_field_name("name") else {
                    continue;
                };
                let mut inner = namespaces.to_vec();
                inner.extend(
                    text(name, source)
                        .split("::")
                        .map(|s| s.trim().to_string())
                        .filter(|s| !s.is_empty()),
                );
                if let Some(body) = child.child_by_field_name("body") {
                    visit(body, source, path, &inner, using_std, functions, classes);
                }
            }
            "function_definition" => {
                if let Some(f) = function(child, source, path, namespaces, using_std, None) {
                    functions.push(f);
                }
            }
            "template_declaration" => {
                for inner in named_children(child) {
                    match inner.kind() {
                        "function_definition" => {
                            if let Some(f) = function(
                                inner,
                                source,
                                path,
                                namespaces,
                                using_std,
                                Some(format!(
                                    "is a template: the C ABI shim needs one concrete signature; \
                                     {FACADE} for each type you use"
                                )),
                            ) {
                                functions.push(f);
                            }
                        }
                        "class_specifier" | "struct_specifier" => {
                            if let Some(c) = class(inner, source, path, namespaces, true) {
                                classes.push(c);
                            }
                        }
                        _ => {}
                    }
                }
            }
            "linkage_specification" => {
                if let Some(body) = child.child_by_field_name("body") {
                    let defs: Vec<Node> = if body.kind() == "function_definition" {
                        vec![body]
                    } else {
                        named_children(body)
                            .into_iter()
                            .filter(|n| n.kind() == "function_definition")
                            .collect()
                    };
                    for def in defs {
                        if let Some(f) = function(
                            def,
                            source,
                            path,
                            namespaces,
                            using_std,
                            Some(
                                "has C linkage (`extern \"C\"`): it is already a C function; \
                                 move it to a `.c` file and bridge it as C"
                                    .into(),
                            ),
                        ) {
                            functions.push(f);
                        }
                    }
                }
            }
            "class_specifier" | "struct_specifier" => {
                if let Some(c) = class(child, source, path, namespaces, false) {
                    classes.push(c);
                }
            }
            "declaration" => {
                // `class Meter { ... } meter;` and the like hold a class too.
                for inner in named_children(child) {
                    if matches!(inner.kind(), "class_specifier" | "struct_specifier")
                        && let Some(c) = class(inner, source, path, namespaces, false)
                    {
                        classes.push(c);
                    }
                }
            }
            _ => {}
        }
    }
}

/// A class or struct with member functions, which stays in C++.
fn class(
    node: Node,
    source: &str,
    path: &str,
    namespaces: &[String],
    template: bool,
) -> Option<ExportedClass> {
    let body = node.child_by_field_name("body")?;
    let has_methods = named_children(body).iter().any(|m| {
        m.kind() == "function_definition"
            || m.kind() == "template_declaration"
            || (matches!(m.kind(), "field_declaration" | "declaration")
                && m.child_by_field_name("declarator")
                    .is_some_and(|d| unwrap(Some(d), source).0 == Wrap::Function))
    });
    if !has_methods && !template {
        return None;
    }
    let name = node.child_by_field_name("name").map_or_else(
        || "(anonymous)".to_string(),
        |n| text(n, source).to_string(),
    );
    let mut qualified = namespaces.to_vec();
    qualified.push(name);
    let qualified = qualified.join("::");
    Some(ExportedClass {
        name: qualified.clone(),
        file: path.to_string(),
        line: syntax::line(node),
        constructor: Vec::new(),
        methods: Vec::new(),
        blocker: Some(format!(
            "is a {}class: member functions do not cross the C ABI shim; {FACADE}",
            if template { "template " } else { "" }
        )),
    })
}

/// One function definition at namespace scope; `None` for one with internal linkage.
fn function(
    node: Node,
    source: &str,
    path: &str,
    namespaces: &[String],
    using_std: bool,
    refused: Option<String>,
) -> Option<ExportedFn> {
    let mut blocker = refused;
    for spec in named_children(node) {
        let word = text(spec, source);
        match spec.kind() {
            "storage_class_specifier" if word == "static" => return None,
            "storage_class_specifier" if word == "inline" => {
                blocker.get_or_insert(format!(
                    "is `inline`, so its file need not emit a symbol the shim could call; drop \
                     `inline` or {FACADE}"
                ));
            }
            "type_qualifier" if matches!(word, "constexpr" | "consteval") => {
                blocker.get_or_insert(format!(
                    "is `{word}` (implicitly inline), so its file need not emit a symbol the shim \
                     could call; {FACADE}"
                ));
            }
            _ => {}
        }
    }
    let declarator = node.child_by_field_name("declarator")?;
    // A function returning a reference or pointer wraps its function declarator.
    let mut function = declarator;
    let mut returns_indirect = None;
    while matches!(
        function.kind(),
        "pointer_declarator" | "reference_declarator"
    ) {
        returns_indirect.get_or_insert(if function.kind() == "pointer_declarator" {
            "pointer"
        } else {
            "reference"
        });
        function = match function.child_by_field_name("declarator") {
            Some(inner) => inner,
            None => named_children(function).into_iter().next()?,
        };
    }
    if function.kind() != "function_declarator" {
        return None;
    }
    let id = function.child_by_field_name("declarator")?;
    let mut qualified = namespaces.to_vec();
    match id.kind() {
        "qualified_identifier" => {
            let full = text(id, source).split_whitespace().collect::<String>();
            let (scope, name) = full.rsplit_once("::")?;
            let class_scope = scope
                .split("::")
                .find(|s| CLASSES.with(|c| c.borrow().contains(*s)));
            let member = class_scope.is_some()
                || named_children(function)
                    .iter()
                    .any(|c| c.kind() == "type_qualifier");
            if member {
                let owner = class_scope.unwrap_or(scope);
                qualified.extend(scope.split("::").map(str::to_string));
                qualified.push(name.to_string());
                return Some(refused_fn(
                    node,
                    path,
                    &qualified.join("::"),
                    format!(
                        "is a member function of `{owner}`: only free functions cross the C ABI \
                         shim; {FACADE}"
                    ),
                ));
            }
            qualified.extend(scope.split("::").map(str::to_string));
            qualified.push(name.to_string());
        }
        "identifier" => qualified.push(text(id, source).to_string()),
        // Operators, destructors and the like.
        _ => return None,
    }
    let name = qualified.join("::");
    if name == "main" {
        return None;
    }
    let mut params = Vec::new();
    if let Some(list) = function.child_by_field_name("parameters") {
        let mut cursor = list.walk();
        if list
            .children(&mut cursor)
            .any(|c| c.kind() == "..." || c.kind() == "variadic_parameter")
        {
            blocker.get_or_insert(format!("is variadic; {FACADE}"));
        }
        for (i, p) in named_children(list).into_iter().enumerate() {
            match p.kind() {
                "parameter_declaration" | "optional_parameter_declaration" => {}
                "variadic_parameter_declaration" | "variadic_parameter" => {
                    blocker.get_or_insert(format!("is variadic; {FACADE}"));
                    continue;
                }
                _ => continue,
            }
            if text(p, source).trim() == "void" {
                continue;
            }
            match param_crossing(p, source, using_std) {
                Ok((c, n)) => params.push(Param {
                    name: n.unwrap_or_else(|| format!("arg{i}")),
                    ts_type: c.dialect(),
                    native_type: Some(c.spelled()),
                    ..Default::default()
                }),
                Err(reason) => {
                    blocker.get_or_insert(reason);
                    params.push(Param {
                        name: format!("arg{i}"),
                        ts_type: "unknown".into(),
                        ..Default::default()
                    });
                }
            }
        }
    }
    let ret_node = node.child_by_field_name("type")?;
    let (returns, native_return) = if let Some(kind) = returns_indirect {
        blocker.get_or_insert(format!(
            "returns a {kind} (`{}`): who owns it must be designed; {FACADE} (one that returns a \
             copy)",
            source[node.start_byte()..function.start_byte()].trim()
        ));
        ("unknown".to_string(), None)
    } else if ret_node.kind() == "placeholder_type_specifier" {
        blocker.get_or_insert("deduces its return type (`auto`): write the type out".into());
        ("unknown".to_string(), None)
    } else if ret_node.kind() == "primitive_type" && text(ret_node, source) == "void" {
        ("void".to_string(), Some("void".to_string()))
    } else {
        match named(ret_node, source, using_std) {
            Named::Known(ty) => {
                let c = Crossing { ty, by_ref: false };
                (c.dialect(), Some(c.spelled()))
            }
            Named::Other(t) => {
                blocker.get_or_insert(format!(
                    "returns `{t}`, which the C++ subset does not take (integers, floating-point \
                     numbers, `bool`, `std::string`, `std::vector` of numbers); {FACADE}"
                ));
                ("unknown".to_string(), None)
            }
        }
    };
    let head = node.child_by_field_name("body").map_or_else(
        || text(node, source).to_string(),
        |b| source[node.start_byte()..b.start_byte()].to_string(),
    );
    Some(ExportedFn {
        name,
        file: path.to_string(),
        line: syntax::line(node),
        params,
        returns,
        native_return,
        prototype: Some(without_comments(&head)),
        blocker,
        ..Default::default()
    })
}

/// A declaration on one line, without its comments (`// barometric pressure` after a
/// parameter).
fn without_comments(head: &str) -> String {
    let mut out = String::new();
    let mut rest = head;
    while let Some(start) = rest.find("/*") {
        out.push_str(&rest[..start]);
        rest = rest[start..]
            .find("*/")
            .map_or("", |end| &rest[start + end + 2..]);
    }
    out.push_str(rest);
    out.lines()
        .map(|l| l.split("//").next().unwrap_or(""))
        .collect::<Vec<_>>()
        .join(" ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .replace("( ", "(")
        .replace(" )", ")")
}

fn refused_fn(node: Node, path: &str, name: &str, reason: String) -> ExportedFn {
    ExportedFn {
        name: name.to_string(),
        file: path.to_string(),
        line: syntax::line(node),
        returns: "unknown".into(),
        blocker: Some(reason),
        ..Default::default()
    }
}

/// Whether a C++ file defines `main`: it cannot go into the library `record` builds.
pub fn defines_main(source: &str) -> bool {
    let Some(tree) = syntax::parse(&language(), source) else {
        return false;
    };
    named_children(tree.root_node()).into_iter().any(|n| {
        n.kind() == "function_definition"
            && n.child_by_field_name("declarator")
                .and_then(|d| d.child_by_field_name("declarator"))
                .is_some_and(|i| text(i, source) == "main")
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn found(source: &str) -> Vec<ExportedFn> {
        exports("x.cpp", source).0
    }

    #[test]
    fn reads_the_subset() {
        let source = "#include <string>\n#include <vector>\n\
            namespace kit {\n\
            int add(int a, int b) { return a + b; }\n\
            std::int64_t wide(std::int64_t a, unsigned long b) { return a; }\n\
            double mean(const std::vector<double> &xs) { return 0; }\n\
            std::vector<int> evens(std::vector<int> xs) { return xs; }\n\
            bool upper(const std::string &s) { return true; }\n\
            std::string shout(std::string s) { return s; }\n\
            void touch() {}\n\
            namespace text { std::string join(std::vector<std::int64_t> const &xs, const std::string &sep) { return sep; } }\n\
            }\n\
            namespace a::b { float half(const float x) { return x; } }\n\
            double kit::later(double x) { return x; }\n";
        let f = found(source);
        let names: Vec<&str> = f.iter().map(|f| f.name.as_str()).collect();
        assert_eq!(
            names,
            [
                "kit::add",
                "kit::wide",
                "kit::mean",
                "kit::evens",
                "kit::upper",
                "kit::shout",
                "kit::touch",
                "kit::text::join",
                "a::b::half",
                "kit::later"
            ]
        );
        for g in &f {
            assert!(g.blocker.is_none(), "{}: {:?}", g.name, g.blocker);
        }
        let types = |i: usize| -> Vec<(String, String)> {
            f[i].params
                .iter()
                .map(|p| (p.ts_type.clone(), p.native_type.clone().unwrap()))
                .collect()
        };
        assert_eq!(
            types(1),
            [
                ("int".into(), "int64_t".into()),
                ("int".into(), "unsigned long".into())
            ]
        );
        assert_eq!(
            types(2),
            [("number[]".into(), "const std::vector<double> &".into())]
        );
        assert_eq!(types(3), [("int[]".into(), "std::vector<int>".into())]);
        assert_eq!(types(4), [("string".into(), "const std::string &".into())]);
        assert_eq!(f[4].returns, "boolean");
        assert_eq!(f[5].native_return.as_deref(), Some("std::string"));
        assert_eq!(f[3].native_return.as_deref(), Some("std::vector<int>"));
        assert_eq!(f[6].returns, "void");
        assert_eq!(
            types(7),
            [
                ("int[]".into(), "const std::vector<int64_t> &".into()),
                ("string".into(), "const std::string &".into())
            ]
        );
        assert_eq!(types(8), [("number".into(), "float".into())]);
        assert_eq!(
            f[2].prototype.as_deref(),
            Some("double mean(const std::vector<double> &xs)")
        );
        let commented = found(
            "double rho(double const pb, // pressure {Pa}\n           double const t /* {C} */\n)\n{ return pb; }\n",
        );
        assert_eq!(
            commented[0].prototype.as_deref(),
            Some("double rho(double const pb, double const t)")
        );
        assert_eq!(symbol(&f[7].name), "cpp__kit__text__join");
        assert_eq!(port_name(&f[7].name), "join");
        assert_eq!(namespace(&f[7].name), Some("kit::text"));
        for g in &f {
            for p in &g.params {
                let native = p.native_type.as_deref().unwrap();
                assert_eq!(crossing(native).unwrap().spelled(), native);
            }
        }
    }

    #[test]
    fn refuses_everything_outside_the_subset() {
        let root = std::env::temp_dir().join(format!("ra-cpp-refuse-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        let source = include_str!("../../tests/fixtures/cpp/src/refused.cpp");
        std::fs::write(root.join("refused.cpp"), source).unwrap();
        use_typedefs(&root);
        std::fs::remove_dir_all(&root).unwrap();
        let (functions, classes) = exports("src/refused.cpp", source);
        let reason = |name: &str| -> String {
            functions
                .iter()
                .filter(|f| f.name == name)
                .map(|f| f.blocker.clone().unwrap_or_default())
                .next()
                .unwrap_or_else(|| panic!("no {name} in {functions:?}"))
        };
        for (name, says) in [
            ("Meter::read", "member function of `Meter`"),
            ("twice", "is a template"),
            ("pick", "is overloaded (2 definitions)"),
            ("step", "state object by non-const reference"),
            ("peek", "pointer to a state object"),
            ("bump", "non-const reference (`int &`)"),
            ("take", "rvalue reference"),
            ("name", "returns a pointer"),
            ("fast", "is `inline`"),
            ("square", "is `constexpr`"),
            ("sizes", "uses `std::map<std::string, int>`"),
            ("flags", "stores bits"),
            ("widen", "`long double`"),
            ("total", "is variadic"),
        ] {
            let r = reason(name);
            assert!(r.contains(says), "{name}: {r}");
            assert!(
                r.contains("facade") || r.contains("write the type"),
                "{name}: {r}"
            );
        }
        assert!(
            functions
                .iter()
                .all(|f| f.name != "hidden" && f.name != "anonymous"),
            "internal linkage is not exported: {functions:?}"
        );
        assert!(
            functions
                .iter()
                .any(|f| f.name == "kept" && f.blocker.is_none())
        );
        let class_names: Vec<&str> = classes.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(class_names, ["Counter", "Meter"]);
        assert!(
            classes[0]
                .blocker
                .as_deref()
                .unwrap()
                .contains("member functions do not cross")
        );
    }

    #[test]
    fn resolves_aliases_and_using_namespace_std() {
        let root = std::env::temp_dir().join(format!("ra-cpp-alias-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("t.hh"),
            "using Real64 = double;\ntypedef Real64 Kelvin;\nstruct State { int n; };\n",
        )
        .unwrap();
        use_typedefs(&root);
        std::fs::remove_dir_all(&root).unwrap();
        let f = found(
            "using namespace std;\n\
             Kelvin warm(Real64 t, const vector<Real64> &ts, string s) { return t; }\n\
             int count(State s) { return 0; }\n",
        );
        assert!(f[0].blocker.is_none(), "{:?}", f[0].blocker);
        let natives: Vec<&str> = f[0]
            .params
            .iter()
            .map(|p| p.native_type.as_deref().unwrap())
            .collect();
        assert_eq!(
            natives,
            ["double", "const std::vector<double> &", "std::string"]
        );
        assert_eq!(f[0].native_return.as_deref(), Some("double"));
        assert!(f[1].blocker.as_deref().unwrap().contains("uses `State`"));
        // Without `using namespace std`, a bare `string` is some other type.
        let g = found("int n(string s) { return 0; }\n");
        assert!(g[0].blocker.is_some());
    }

    #[test]
    fn discovers_cpp_files_and_merges_headers() {
        let root = std::env::temp_dir().join(format!("ra-cpp-discover-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("src")).unwrap();
        std::fs::create_dir_all(root.join("tests")).unwrap();
        for f in [
            "src/kit.cpp",
            "src/kit.hpp",
            "src/only.hh",
            "src/b.cc",
            "src/b.h",
            "tests/test_kit.cpp",
            "CMakeLists.txt",
        ] {
            std::fs::write(root.join(f), "").unwrap();
        }
        let ws = discover(&root).unwrap();
        let files: Vec<(&str, FileKind)> =
            ws.files.iter().map(|f| (f.path.as_str(), f.kind)).collect();
        assert_eq!(
            files,
            [
                ("src/b.cc", FileKind::Source),
                ("src/kit.cpp", FileKind::Source),
                ("src/only.hh", FileKind::Source),
                ("tests/test_kit.cpp", FileKind::Test)
            ]
        );
        std::fs::remove_dir_all(&root).unwrap();
        let mut index = HashMap::new();
        index.insert("src/kit.cpp", 3);
        assert!(matches!(
            resolve("src/main.cpp", "kit.hpp", &index),
            super::super::Resolution::File(3)
        ));
        assert!(matches!(
            resolve("src/main.cpp", "<vector>", &index),
            super::super::Resolution::Stdlib
        ));
        assert!(matches!(
            resolve("src/main.cpp", "<boost/any.hpp>", &index),
            super::super::Resolution::External(_)
        ));
        assert!(defines_main("int main() { return 0; }"));
    }

    #[test]
    fn scans_cpp_risks() {
        let facts = scan(
            "#include \"kit.hpp\"\n#include <vector>\n\
             int f(int *p) { int *q = new int(3); for (int x : {1, 2}) {} throw 1; return *p / 2; }\n",
        );
        for risk in [Risk::Pointers, Risk::Exceptions, Risk::DivisionSemantics] {
            assert!(facts.risks.contains_key(&risk), "{risk:?}");
        }
        assert_eq!(facts.loops, 1);
        let specs: Vec<&str> = facts.imports.iter().map(|i| i.specifier.as_str()).collect();
        assert_eq!(specs, ["kit.hpp", "<vector>"]);
    }
}
