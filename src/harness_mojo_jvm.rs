//! Building a `mojo-jvm` unit: `dispatcher.mojo` becomes the shared library the generated Java
//! classes load through the Foreign Function & Memory API. Record, diff and bench run the
//! reflection driver in `harness_java`, compiled against the original sources or the wrappers.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::{Context, Result, bail};

use crate::bridge::Manifest;

/// What the reflection driver is compiled with: the original sources (to record) or the
/// generated wrappers over the port (to diff and bench).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Against {
    Original,
    Port,
}

/// The library the wrappers load, built or not.
pub fn library_path(unit_dir: &Path, m: &Manifest) -> PathBuf {
    crate::harness_mojo_c::library_path(unit_dir, m, false)
}

/// Builds `dispatcher.mojo` with `--emit shared-lib` into the unit's build folder (warnings are
/// errors) and returns the library. The Java sources compile in `diff`.
pub fn build(unit_dir: &Path, m: &Manifest) -> Result<PathBuf> {
    if !crate::mojo::available() {
        bail!("{}", crate::mojo::missing_message());
    }
    let unit_dir = std::path::absolute(unit_dir)?;
    if !unit_dir.join(crate::codegen_ffi::DISPATCHER).is_file() {
        bail!(
            "{} has no {}: run `mojo-anything refresh {}`",
            unit_dir.display(),
            crate::codegen_ffi::DISPATCHER,
            unit_dir.display()
        );
    }
    std::fs::create_dir_all(unit_dir.join(crate::harness_mojo_c::BUILD_DIR))?;
    let lib = library_path(&unit_dir, m);
    crate::harness_mojo_c::build_one(&unit_dir, crate::codegen_ffi::DISPATCHER, &lib)?;
    Ok(lib)
}

/// A public member (method, constructor or field) as `javap` prints it: the declaration
/// (generic types included, without the modifiers that do not change how a caller binds to it)
/// and the JVM descriptor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JvmMember {
    pub declaration: String,
    pub descriptor: String,
}

/// The name constructors are listed under.
const CONSTRUCTOR: &str = "<init>";

/// The parameter type of the synthetic constructors Kotlin gives companion objects and default
/// arguments: no Kotlin or Java source can call one, so a wrapper need not keep it.
const KOTLIN_MARKER: &str = "Lkotlin/jvm/internal/DefaultConstructorMarker;";

/// The members in `javap -public -s` output, by `(class, member name)`; constructors are
/// listed as `<init>`.
pub fn parse_javap(text: &str) -> BTreeMap<(String, String), Vec<JvmMember>> {
    let mut out: BTreeMap<(String, String), Vec<JvmMember>> = BTreeMap::new();
    let mut class = String::new();
    let lines: Vec<&str> = text.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        if !line.starts_with(' ') {
            let mut words = line.split_whitespace();
            if words.any(|w| matches!(w, "class" | "interface" | "enum" | "record"))
                && let Some(name) = words.next()
            {
                class = name.split(['<', '{']).next().unwrap_or(name).to_string();
            }
            continue;
        }
        let decl = line.trim();
        if decl.is_empty() || decl.starts_with("descriptor:") {
            continue;
        }
        let Some(descriptor) = lines
            .get(i + 1)
            .and_then(|l| l.trim().strip_prefix("descriptor:"))
        else {
            continue;
        };
        let decl = decl.trim_end_matches(';');
        // Checked exceptions are left out: the wrappers declare none.
        let decl = decl.split(" throws ").next().unwrap_or(decl);
        // A method or constructor ends its name at `(`; a field's name is its last word.
        let head = decl
            .find('(')
            .and_then(|open| decl.get(..open))
            .unwrap_or(decl);
        let Some(name) = head.split_whitespace().last() else {
            continue;
        };
        let name = if name == class { CONSTRUCTOR } else { name };
        let declaration = decl
            .split_whitespace()
            .filter(|w| !matches!(*w, "final" | "synchronized" | "native" | "strictfp"))
            .collect::<Vec<_>>()
            .join(" ");
        out.entry((class.clone(), name.to_string()))
            .or_default()
            .push(JvmMember {
                declaration,
                descriptor: descriptor.trim().to_string(),
            });
    }
    out
}

/// The public member classes of `outers` in the `InnerClasses` attributes of `javap -v` output,
/// e.g. `public static final #15= #20 of #2; // Companion=class a/b/Units$Companion of class a/b/Units`.
pub fn parse_inner_classes(text: &str, outers: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    let mut inside = false;
    for line in text.lines() {
        if line.starts_with("InnerClasses:") {
            inside = true;
            continue;
        }
        if !line.starts_with(' ') {
            inside = false;
        }
        if !inside {
            continue;
        }
        let Some((flags, comment)) = line.split_once("//") else {
            continue;
        };
        if !flags.split_whitespace().any(|w| w == "public") {
            continue;
        }
        // Anonymous and local classes have no `Name=` and no `of`.
        let Some((_, named)) = comment.split_once('=') else {
            continue;
        };
        let Some((inner, outer)) = named.split_once(" of ") else {
            continue;
        };
        let kind = |t: &str| {
            let t = t.trim();
            t.strip_prefix("class ")
                .or_else(|| t.strip_prefix("interface "))
                .map(|n| n.trim().replace('/', "."))
        };
        if let (Some(inner), Some(outer)) = (kind(inner), kind(outer))
            && outers.contains(&outer)
            && !out.contains(&inner)
        {
            out.push(inner);
        }
    }
    out
}

/// The driver compiled with the original classes or with the wrappers (Kotlin's original as a
/// jar from `kotlinc`).
fn classpath(unit_dir: &Path, m: &Manifest, against: Against) -> Result<Vec<PathBuf>> {
    if m.language == crate::lang::Lang::Kotlin {
        crate::harness_kotlin::classpath(unit_dir, m, against)
    } else {
        crate::harness_java::classpath(unit_dir, m, against)
    }
}

fn javap(flags: &[&str], classpath: &[PathBuf], classes: &[String]) -> Result<String> {
    let mut cmd = Command::new("javap");
    cmd.args(flags)
        .arg("-cp")
        .arg(std::env::join_paths(classpath).context("building Java classpath")?)
        .args(classes);
    let out = crate::process::output(&mut cmd, crate::process::QUICK).context("running javap")?;
    if !out.success() {
        bail!("javap failed:\n{}", out.stderr_text());
    }
    Ok(out.stdout_text())
}

/// The public nested classes of `classes`, and theirs in turn (`Units$Companion` for `Units`).
fn nested_public(classpath: &[PathBuf], classes: &[String]) -> Result<Vec<String>> {
    let mut found: Vec<String> = Vec::new();
    let mut frontier = classes.to_vec();
    while !frontier.is_empty() {
        let text = javap(&["-v"], classpath, &frontier)?;
        let mut next = Vec::new();
        for inner in parse_inner_classes(&text, &frontier) {
            if !found.contains(&inner) && !classes.contains(&inner) {
                found.push(inner.clone());
                next.push(inner);
            }
        }
        frontier = next;
    }
    Ok(found)
}

/// What the `java api` gate check found: the public members of the original classes that the
/// wrappers keep, those they keep with another signature, and those they drop.
#[derive(Debug, Default)]
pub struct ApiCheck {
    pub same: Vec<String>,
    pub different: Vec<String>,
    pub dropped: Vec<String>,
}

/// `Units` for `com.example.owners.Units`, `Units.Companion` for its nested `Units$Companion`.
fn shown_class(class: &str) -> String {
    class.rsplit('.').next().unwrap_or(class).replace('$', ".")
}

fn label(class: &str, name: &str) -> String {
    if name == CONSTRUCTOR {
        format!("{} constructor", shown_class(class))
    } else {
        format!("{}.{name}", shown_class(class))
    }
}

/// Compiles the original classes and the wrappers and compares every public member of each
/// class the unit replaces, and of its public nested classes: declaration and descriptor. A
/// wrapper takes the original's fully qualified name, so a caller compiled against the original
/// links to it only when every member it uses is there with the same descriptor (a return type
/// narrowed from `long` to `int` still compiles at a call site, but the caller's `(JJ)J` call no
/// longer resolves), constants, constructors, fields such as Kotlin's `Companion` and members
/// the bridge did not port included.
pub fn api_check(unit_dir: &Path, m: &Manifest) -> Result<ApiCheck> {
    let mut owners: Vec<String> = m
        .exports
        .iter()
        .map(|f| crate::lang::java::receiver(f).0)
        .collect();
    owners.sort();
    owners.dedup();
    let exported: Vec<(String, String)> =
        m.exports.iter().map(crate::lang::java::receiver).collect();
    let original_cp = classpath(unit_dir, m, Against::Original)?;
    let port_cp = classpath(unit_dir, m, Against::Port)?;
    let original_nested = nested_public(&original_cp, &owners)?;
    let port_nested = nested_public(&port_cp, &owners)?;
    let mut check = ApiCheck::default();
    let mut classes = owners.clone();
    for nested in &original_nested {
        if port_nested.contains(nested) {
            classes.push(nested.clone());
        } else {
            check.dropped.push(format!(
                "{}: the wrapper drops this public nested class",
                shown_class(nested)
            ));
        }
    }
    let original = parse_javap(&javap(&["-public", "-s"], &original_cp, &classes)?);
    let port = parse_javap(&javap(&["-public", "-s"], &port_cp, &classes)?);
    let show = |members: &[JvmMember]| {
        members
            .iter()
            .map(|j| format!("`{}` {}", j.declaration, j.descriptor))
            .collect::<Vec<_>>()
            .join(", ")
    };
    for (key, members) in &original {
        let (class, name) = key;
        let label = label(class, name);
        let wrapped = port.get(key).map_or(&[][..], Vec::as_slice);
        let is_export = exported.contains(key);
        for o in members {
            if o.descriptor.contains(KOTLIN_MARKER) {
                continue;
            }
            match wrapped.iter().find(|p| p.descriptor == o.descriptor) {
                Some(p) if p.declaration == o.declaration => {
                    if !check.same.contains(&label) {
                        check.same.push(label.clone());
                    }
                }
                Some(p) => check.different.push(format!(
                    "{label}: the wrapper has {}, the original {}",
                    show(std::slice::from_ref(p)),
                    show(std::slice::from_ref(o))
                )),
                None if is_export && wrapped.is_empty() => check
                    .different
                    .push(format!("{label}: no such public method in the wrapper")),
                None if is_export => check.different.push(format!(
                    "{label}: the wrapper has {}, the original {}",
                    show(wrapped),
                    show(std::slice::from_ref(o))
                )),
                None => check.dropped.push(format!(
                    "{label}: the wrapper drops {}",
                    show(std::slice::from_ref(o))
                )),
            }
        }
    }
    for (class, name) in &exported {
        if !original.contains_key(&(class.clone(), name.clone())) {
            check.different.push(format!(
                "{}: no such public method in the original",
                label(class, name)
            ));
        }
    }
    Ok(check)
}

/// The built library, or an error asking for `build`.
pub fn built_library(unit_dir: &Path, m: &Manifest) -> Result<PathBuf> {
    let lib = library_path(unit_dir, m);
    if !lib.is_file() {
        bail!(
            "no built library at {} (run `mojo-anything build {}` first)",
            lib.display(),
            unit_dir.display()
        );
    }
    Ok(lib)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn javap_members_by_class_and_name() {
        let text = "Compiled from \"Strings.kt\"\n\
                    public final class com.example.text.StringsKt {\n  \
                    public static final java.lang.String slugify(java.lang.String, int);\n    \
                    descriptor: (Ljava/lang/String;I)Ljava/lang/String;\n  \
                    public static final java.util.List<java.lang.String> words(java.lang.String) throws java.io.IOException;\n    \
                    descriptor: (Ljava/lang/String;)Ljava/util/List;\n}\n\
                    public final class com.example.text.Nums {\n  \
                    public static final com.example.text.Nums INSTANCE;\n    \
                    descriptor: Lcom/example/text/Nums;\n  \
                    public com.example.text.Nums();\n    \
                    descriptor: ()V\n\n  \
                    public static final long gcd(long, long);\n    \
                    descriptor: (JJ)J\n}\n";
        let members = parse_javap(text);
        assert_eq!(members.len(), 5, "{members:?}");
        let get = |c: &str, n: &str| members[&(c.to_string(), n.to_string())][0].clone();
        assert_eq!(
            get("com.example.text.StringsKt", "slugify"),
            JvmMember {
                declaration: "public static java.lang.String slugify(java.lang.String, int)".into(),
                descriptor: "(Ljava/lang/String;I)Ljava/lang/String;".into(),
            }
        );
        assert_eq!(
            get("com.example.text.StringsKt", "words").declaration,
            "public static java.util.List<java.lang.String> words(java.lang.String)"
        );
        assert_eq!(get("com.example.text.Nums", "gcd").descriptor, "(JJ)J");
        assert_eq!(
            get("com.example.text.Nums", "INSTANCE"),
            JvmMember {
                declaration: "public static com.example.text.Nums INSTANCE".into(),
                descriptor: "Lcom/example/text/Nums;".into(),
            }
        );
        assert_eq!(get("com.example.text.Nums", CONSTRUCTOR).descriptor, "()V");
    }

    #[test]
    fn inner_classes_are_the_public_named_members_of_the_class() {
        let text = "  #2 = Class #4 // com/example/owners/Units\n\
                    InnerClasses:\n  \
                    public static final #15= #20 of #2;     // Companion=class com/example/owners/Units$Companion of class com/example/owners/Units\n  \
                    private static final #16= #21 of #2;    // Hidden=class com/example/owners/Units$Hidden of class com/example/owners/Units\n  \
                    public static #22= #23 of #24;          // Entry=interface java/util/Map$Entry of interface java/util/Map\n  \
                    #25;                                    // class com/example/owners/Units$1\n\
                    SourceFile: \"Text.kt\"\n";
        let outers = ["com.example.owners.Units".to_string()];
        assert_eq!(
            parse_inner_classes(text, &outers),
            ["com.example.owners.Units$Companion"]
        );
    }
}
