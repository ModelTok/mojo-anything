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

/// A public method as `javap` prints it: the declaration (generic types included, without the
/// modifiers that do not change how a caller binds to it) and the JVM descriptor.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct JvmMethod {
    pub declaration: String,
    pub descriptor: String,
}

/// The methods in `javap -public -s` output, by `(class, method name)`.
pub fn parse_javap(text: &str) -> BTreeMap<(String, String), Vec<JvmMethod>> {
    let mut out: BTreeMap<(String, String), Vec<JvmMethod>> = BTreeMap::new();
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
        if decl.starts_with("descriptor:") {
            continue;
        }
        let Some(open) = decl.find('(') else {
            continue;
        };
        let Some(descriptor) = lines
            .get(i + 1)
            .and_then(|l| l.trim().strip_prefix("descriptor:"))
        else {
            continue;
        };
        let decl = decl.trim_end_matches(';');
        // Checked exceptions are left out: the wrappers declare none.
        let decl = decl.split(" throws ").next().unwrap_or(decl);
        let Some(name) = decl
            .get(..open)
            .and_then(|head| head.split_whitespace().last())
        else {
            continue;
        };
        let declaration = decl
            .split_whitespace()
            .filter(|w| !matches!(*w, "final" | "synchronized" | "native" | "strictfp"))
            .collect::<Vec<_>>()
            .join(" ");
        out.entry((class.clone(), name.to_string()))
            .or_default()
            .push(JvmMethod {
                declaration,
                descriptor: descriptor.trim().to_string(),
            });
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

fn javap(classpath: &[PathBuf], classes: &[String]) -> Result<String> {
    let mut cmd = Command::new("javap");
    cmd.args(["-public", "-s", "-cp"])
        .arg(std::env::join_paths(classpath).context("building Java classpath")?)
        .args(classes);
    let out = crate::process::output(&mut cmd, crate::process::QUICK).context("running javap")?;
    if !out.success() {
        bail!("javap failed:\n{}", out.stderr_text());
    }
    Ok(out.stdout_text())
}

/// What the `java api` gate check found: each export whose wrapper a caller compiled against
/// the original binds to unchanged, and each one it does not.
#[derive(Debug, Default)]
pub struct ApiCheck {
    pub same: Vec<String>,
    pub different: Vec<String>,
}

/// Compiles the original classes and the wrappers and compares every export's declaration and
/// descriptor: a caller compiled against the original links to the wrapper only when both are
/// the same (a return type narrowed from `long` to `int` still compiles at a call site, but the
/// caller's `(JJ)J` call no longer resolves).
pub fn api_check(unit_dir: &Path, m: &Manifest) -> Result<ApiCheck> {
    let mut owners: Vec<String> = m
        .exports
        .iter()
        .map(|f| crate::lang::java::receiver(f).0)
        .collect();
    owners.sort();
    owners.dedup();
    let original = parse_javap(&javap(
        &classpath(unit_dir, m, Against::Original)?,
        &owners,
    )?);
    let port = parse_javap(&javap(&classpath(unit_dir, m, Against::Port)?, &owners)?);
    let mut check = ApiCheck::default();
    let show = |methods: &[JvmMethod]| {
        methods
            .iter()
            .map(|j| format!("`{}` {}", j.declaration, j.descriptor))
            .collect::<Vec<_>>()
            .join(", ")
    };
    for f in &m.exports {
        let (class, name) = crate::lang::java::receiver(f);
        let simple = class.rsplit('.').next().unwrap_or(&class);
        let key = (class.clone(), name.clone());
        let label = format!("{simple}.{name}");
        match (original.get(&key), port.get(&key)) {
            (Some(o), Some(p)) if o == p => check.same.push(label),
            (Some(o), Some(p)) => check.different.push(format!(
                "{label}: the wrapper has {}, the original {}",
                show(p),
                show(o)
            )),
            (Some(_), None) => check
                .different
                .push(format!("{label}: no such public method in the wrapper")),
            (None, _) => check
                .different
                .push(format!("{label}: no such public method in the original")),
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
    fn javap_methods_by_class_and_name() {
        let text = "Compiled from \"Strings.kt\"\n\
                    public final class com.example.text.StringsKt {\n  \
                    public static final java.lang.String slugify(java.lang.String, int);\n    \
                    descriptor: (Ljava/lang/String;I)Ljava/lang/String;\n  \
                    public static final java.util.List<java.lang.String> words(java.lang.String) throws java.io.IOException;\n    \
                    descriptor: (Ljava/lang/String;)Ljava/util/List;\n}\n\
                    public final class com.example.text.Nums {\n  \
                    public static final com.example.text.Nums INSTANCE;\n    \
                    descriptor: Lcom/example/text/Nums;\n  \
                    public static final long gcd(long, long);\n    \
                    descriptor: (JJ)J\n}\n";
        let methods = parse_javap(text);
        assert_eq!(methods.len(), 3, "{methods:?}");
        let get = |c: &str, n: &str| methods[&(c.to_string(), n.to_string())][0].clone();
        assert_eq!(
            get("com.example.text.StringsKt", "slugify"),
            JvmMethod {
                declaration: "public static java.lang.String slugify(java.lang.String, int)".into(),
                descriptor: "(Ljava/lang/String;I)Ljava/lang/String;".into(),
            }
        );
        assert_eq!(
            get("com.example.text.StringsKt", "words").declaration,
            "public static java.util.List<java.lang.String> words(java.lang.String)"
        );
        assert_eq!(get("com.example.text.Nums", "gcd").descriptor, "(JJ)J");
    }
}
