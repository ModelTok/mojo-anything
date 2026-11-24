//! The JDK that Java and Kotlin units need: the Mojo port is called through the Foreign Function
//! & Memory API (`java.lang.foreign`), final in Java 22.

use std::path::PathBuf;
use std::process::Command;

use anyhow::{Result, bail};

/// The oldest Java whose `java.lang.foreign` the generated classes use.
pub const MIN_JAVA: u32 = 22;

/// The major version in `java -version` or `javac -version` output: `"22.0.1"` is 22,
/// `"1.8.0_402"` is 8 and `"23-ea"` is 23.
pub fn java_major(version_output: &str) -> Option<u32> {
    version_output
        .split(|c: char| c.is_whitespace() || c == '"')
        .find_map(|word| {
            let digits: String = word.chars().take_while(char::is_ascii_digit).collect();
            let major: u32 = digits.parse().ok()?;
            if major != 1 {
                return Some(major);
            }
            // The old scheme: `1.8.0_402` is Java 8.
            let rest = word.strip_prefix("1.")?;
            rest.chars()
                .take_while(char::is_ascii_digit)
                .collect::<String>()
                .parse()
                .ok()
        })
}

fn on_path(program: &str) -> Option<PathBuf> {
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(program))
        .find(|p| p.is_file())
}

/// The major version `program -version` reports, with the program's path for messages.
fn version_of(program: &str) -> Result<(u32, String)> {
    let path = on_path(program).map_or_else(|| program.to_string(), |p| p.display().to_string());
    let out = match crate::process::output(
        Command::new(program).arg("-version"),
        crate::process::QUICK,
    ) {
        Ok(out) => out,
        Err(_) => bail!(
            "Java {MIN_JAVA} or newer is needed for Java and Kotlin units; `{program}` was not \
             found on PATH"
        ),
    };
    // `java -version` prints to stderr, `javac -version` to stdout.
    let text = format!("{}\n{}", out.stdout_text(), out.stderr_text());
    match java_major(&text) {
        Some(major) => Ok((major, path)),
        None => bail!(
            "Java {MIN_JAVA} or newer is needed for Java and Kotlin units; `{program} -version` \
             printed no version ({path})"
        ),
    }
}

/// Checks that `java` and `javac` on PATH are Java 22 or newer.
pub fn require_java() -> Result<()> {
    for program in ["java", "javac"] {
        let (major, path) = version_of(program)?;
        if major < MIN_JAVA {
            bail!(
                "Java {MIN_JAVA} or newer is needed for Java and Kotlin units; found {major} \
                 ({path})"
            );
        }
    }
    Ok(())
}

/// [`require_java`] for the unit in `unit_dir` when it is a Java or Kotlin unit; anything
/// else (including a folder without a manifest, which the caller reports) passes.
pub fn require_java_for(unit_dir: &std::path::Path) -> Result<()> {
    match crate::bridge::Manifest::load(unit_dir) {
        Ok(m) if is_jvm(m.language) => require_java(),
        _ => Ok(()),
    }
}

/// Whether a unit in `language` runs on the JVM, and so needs [`require_java`].
pub fn is_jvm(language: crate::lang::Lang) -> bool {
    matches!(
        language,
        crate::lang::Lang::Java | crate::lang::Lang::Kotlin
    )
}

/// The Kotlin declaration a `@JvmStatic` function belongs to besides its static method. Kotlin
/// callers reach a companion object's members through the companion (`getstatic
/// Units.Companion`, then `invokevirtual Units$Companion.parse`), so a wrapper that replaces the
/// class keeps the field and the nested class; an `object` keeps its `INSTANCE`.
#[derive(Clone, Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Holder {
    /// A `companion object`, by its name (`Companion` unless it is named).
    Companion(String),
    /// An `object` declaration.
    Object,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn java_major_reads_versions() {
        assert_eq!(java_major("22.0.1"), Some(22));
        assert_eq!(java_major("1.8.0_402"), Some(8));
        assert_eq!(java_major("23-ea"), Some(23));
        assert_eq!(
            java_major("openjdk version \"25.0.5.1\" 2026-11-17\nOpenJDK Runtime"),
            Some(25)
        );
        assert_eq!(java_major("java version \"1.8.0_281\""), Some(8));
        assert_eq!(java_major("javac 21.0.2"), Some(21));
        assert_eq!(java_major("no version here"), None);
    }
}
