//! Error paths: where the original fails (`throw`, `raise`, an `error` result), and whether a
//! recorded case reaches each of them.

use std::collections::BTreeSet;
use std::ops::Range;
use std::path::Path;

use regex::Regex;
use serde_json::Value;

use crate::bridge::Manifest;
use crate::gate::Check;
use crate::lang::Lang;

/// An export whose original fails on some input, and where.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Raise {
    pub export: String,
    pub site: String,
}

fn indent(line: &str) -> usize {
    line.len() - line.trim_start().len()
}

fn is_comment(lang: Lang, line: &str) -> bool {
    let t = line.trim_start();
    t.starts_with("//")
        || t.starts_with("/*")
        || t.starts_with('*')
        || (matches!(lang, Lang::Python | Lang::Ruby | Lang::Php) && t.starts_with('#'))
}

/// The lines of the definition that starts at `start`.
fn body(lang: Lang, lines: &[&str], start: usize) -> Range<usize> {
    let Some(first) = lines.get(start) else {
        return start..start;
    };
    match lang {
        Lang::Python => {
            let base = indent(first);
            let mut end = start + 1;
            while end < lines.len() && (lines[end].trim().is_empty() || indent(lines[end]) > base) {
                end += 1;
            }
            start..end
        }
        Lang::Ruby => {
            let base = indent(first);
            let end = (start + 1..lines.len())
                .find(|&i| lines[i].trim() == "end" && indent(lines[i]) == base)
                .map_or(lines.len(), |i| i + 1);
            start..end
        }
        _ => {
            let mut depth = 0i32;
            let mut opened = false;
            for (i, line) in lines.iter().enumerate().skip(start) {
                if is_comment(lang, line) {
                    continue;
                }
                let mut in_string: Option<char> = None;
                let mut prev = ' ';
                for c in line.chars() {
                    match in_string {
                        Some(q) if c == q && prev != '\\' => in_string = None,
                        Some(_) => {}
                        None if c == '"' || c == '`' => in_string = Some(c),
                        None if c == '{' => {
                            depth += 1;
                            opened = true;
                        }
                        None if c == '}' => depth -= 1,
                        None => {}
                    }
                    prev = c;
                }
                if opened && depth <= 0 {
                    return start..i + 1;
                }
                if !opened && i > start + 10 {
                    break;
                }
            }
            start..(start + 1).min(lines.len())
        }
    }
}

/// The line, inside `range`, where the function fails on purpose.
fn raise_line(lang: Lang, lines: &[&str], range: Range<usize>) -> Option<usize> {
    let word = |w: &str| Regex::new(&format!(r"\b{w}\b")).expect("valid regex");
    let find = |re: &Regex| {
        range
            .clone()
            .find(|&i| !is_comment(lang, lines[i]) && re.is_match(lines[i]))
    };
    match lang {
        Lang::Ts | Lang::Java | Lang::Kotlin | Lang::Php | Lang::Csharp | Lang::Cpp => {
            find(&word("throw"))
        }
        Lang::Python | Lang::Ruby => find(&word("raise")),
        Lang::Go => {
            let open = range
                .clone()
                .find(|&i| lines[i].contains('{'))
                .unwrap_or(range.start);
            let signature: String = lines[range.start..=open.min(lines.len() - 1)].join(" ");
            let head = signature.split('{').next().unwrap_or_default();
            let returns_error = Regex::new(r"\)\s*(?:\([^)]*\berror\s*\)|error)\s*$")
                .expect("valid regex")
                .is_match(head.trim_end());
            returns_error.then(|| {
                find(
                    &Regex::new(r"errors\.New|fmt\.Errorf|return [^\n]*\berr\b")
                        .expect("valid regex"),
                )
                .unwrap_or(range.start)
            })
        }
        Lang::C => None,
    }
}

/// Exports whose original fails on purpose somewhere, with the place.
pub fn raises(lang: Lang, root: &Path, exports: &[(String, String, u32)]) -> Vec<Raise> {
    let mut out = Vec::new();
    for (name, file, line) in exports {
        let Ok(text) = std::fs::read_to_string(root.join(file)) else {
            continue;
        };
        let lines: Vec<&str> = text.lines().collect();
        let start = (*line as usize).saturating_sub(1);
        if let Some(at) = raise_line(lang, &lines, body(lang, &lines, start)) {
            out.push(Raise {
                export: name.clone(),
                site: format!("{file}:{}", at + 1),
            });
        }
    }
    out
}

/// Names of the functions with at least one recorded case that failed.
pub fn recorded_errors(cases: &str) -> BTreeSet<String> {
    cases
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .filter(|c| c.get("error").is_some() || c.get("panic").is_some())
        .filter_map(|c| c["fn"].as_str().map(str::to_string))
        .collect()
}

/// The `error cases` check of `gate`.
pub fn check(crate_dir: &Path, manifest: &Manifest) -> Check {
    let exports: Vec<(String, String, u32)> = manifest
        .exports
        .iter()
        .map(|f| (f.name.clone(), f.file.clone(), f.line))
        .collect();
    let raised = raises(manifest.language, &manifest.root, &exports);
    let cases = std::fs::read_to_string(crate_dir.join(crate::harness::CASES)).unwrap_or_default();
    let failed = recorded_errors(&cases);
    let unreached: Vec<String> = raised
        .iter()
        .filter(|r| !failed.contains(&r.export))
        .map(|r| format!("{} fails at {}", r.export, r.site))
        .collect();
    Check {
        fix: None,
        name: "error cases",
        passed: unreached.is_empty(),
        detail: if raised.is_empty() {
            "the original fails on purpose nowhere".into()
        } else if unreached.is_empty() {
            format!(
                "each of the {} functions that fail in the original has a recorded failing case",
                raised.len()
            )
        } else {
            format!(
                "no recorded case reaches these error paths: add inputs that fail (record --inputs)\n{}",
                unreached.join("\n")
            )
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn check(lang: Lang, file: &str, source: &str, exports: &[(&str, u32)]) -> Vec<String> {
        let dir = std::env::temp_dir().join(format!(
            "mojo-anything-raises-{}-{file}",
            std::process::id()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(file), source).unwrap();
        let exports: Vec<(String, String, u32)> = exports
            .iter()
            .map(|(n, l)| (n.to_string(), file.to_string(), *l))
            .collect();
        let found = raises(lang, &dir, &exports)
            .into_iter()
            .map(|r| format!("{} {}", r.export, r.site))
            .collect();
        std::fs::remove_dir_all(&dir).unwrap();
        found
    }

    #[test]
    fn finds_where_the_original_fails_in_each_language() {
        assert_eq!(
            check(
                Lang::Ts,
                "a.ts",
                "export function ok(x: number) {\n  return x\n}\nexport function parse(s: string) {\n  // throw in a comment\n  if (!s) { throw new Error('empty') }\n  return s\n}\n",
                &[("ok", 1), ("parse", 4)]
            ),
            ["parse a.ts:6"]
        );
        assert_eq!(
            check(
                Lang::Python,
                "a.py",
                "def ok(x):\n    return x\n\ndef parse(s):\n    if not s:\n        raise ValueError('empty')\n    return s\n",
                &[("ok", 1), ("parse", 4)]
            ),
            ["parse a.py:6"]
        );
        assert_eq!(
            check(
                Lang::Ruby,
                "a.rb",
                "module M\n  def self.ok(x)\n    x\n  end\n\n  def self.parse(s)\n    raise ArgumentError, 'empty' if s.empty?\n    s\n  end\nend\n",
                &[("ok", 2), ("parse", 6)]
            ),
            ["parse a.rb:7"]
        );
        assert_eq!(
            check(
                Lang::Go,
                "a.go",
                "package a\n\nfunc Ok(x int) int {\n\treturn x\n}\n\nfunc Parse(s string) (int, error) {\n\tif s == \"\" {\n\t\treturn 0, errors.New(\"empty\")\n\t}\n\treturn 1, nil\n}\n",
                &[("Ok", 3), ("Parse", 7)]
            ),
            ["Parse a.go:9"]
        );
        assert_eq!(
            check(
                Lang::Java,
                "A.java",
                "class A {\n  public static int ok(int x) { return x; }\n  public static int parse(String s) {\n    if (s.isEmpty()) throw new IllegalArgumentException(\"{\");\n    return 1;\n  }\n}\n",
                &[("ok", 2), ("parse", 3)]
            ),
            ["parse A.java:4"]
        );
        assert!(
            check(
                Lang::C,
                "a.c",
                "int parse(const char *s) { return s ? 1 : -1; }\n",
                &[("parse", 1)]
            )
            .is_empty()
        );
    }

    #[test]
    fn recorded_failures_are_read_by_function() {
        assert_eq!(
            recorded_errors(
                "{\"fn\":\"a\",\"args\":[],\"result\":1}\n{\"fn\":\"b\",\"args\":[],\"error\":{\"name\":\"E\"}}\n"
            ),
            BTreeSet::from(["b".to_string()])
        );
    }
}
