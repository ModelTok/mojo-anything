//! Python literal defaults (`sep="-"`), shared by the bridges that keep a source default as a
//! plain value: the Mojo Python extension and the Ruby and Java wrappers.

use crate::ts::exports::Param;

/// A literal default (Python, Ruby or Java source) as a Rust expression: strings,
/// numbers and booleans. `None` and other expressions return `None` (the parameter is an
/// `Option`, and `None` stands for the default).
pub fn rust_literal(default: &str) -> Option<String> {
    let d = default.trim();
    match d {
        // Python's `True`; Ruby's and Java's `true`.
        "True" | "true" => return Some("true".into()),
        "False" | "false" => return Some("false".into()),
        "None" => return None,
        _ => {}
    }
    let digits = d.replace('_', "");
    if digits.parse::<i64>().is_ok() {
        return Some(digits);
    }
    if (digits.contains('.') || digits.contains('e')) && digits.parse::<f64>().is_ok() {
        return Some(if digits.contains('.') {
            digits
        } else {
            format!("{digits}_f64")
        });
    }
    let quote = d.chars().next().filter(|c| *c == '"' || *c == '\'')?;
    let inner = d.strip_prefix(quote)?.strip_suffix(quote)?;
    // Plain literals only: escapes and quotes inside would need Python's own parser.
    if inner.contains('\\') || inner.contains('"') || inner.contains('\'') {
        return None;
    }
    Some(format!("String::from(\"{inner}\")"))
}

/// Whether a parameter keeps Python's literal default (and is a plain, non-`Option` type).
pub fn has_literal_default(p: &Param) -> bool {
    p.optional && p.default.as_deref().and_then(rust_literal).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converts_python_literals() {
        assert_eq!(rust_literal("'-'").as_deref(), Some("String::from(\"-\")"));
        assert_eq!(rust_literal("8").as_deref(), Some("8"));
        assert_eq!(rust_literal("1_000").as_deref(), Some("1000"));
        assert_eq!(rust_literal("0.5").as_deref(), Some("0.5"));
        assert_eq!(rust_literal("True").as_deref(), Some("true"));
        assert_eq!(rust_literal("None"), None);
        assert_eq!(rust_literal("[]"), None);
        assert_eq!(rust_literal("'a\\nb'"), None);
    }
}
