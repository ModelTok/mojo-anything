//! The libraries each source language imports and what replaces them once the code is Mojo: a
//! Mojo stdlib module, a Mojo package on pixi, or a Python module through CPython interop
//! (`python:<module>`), from the data table `replacements.toml`. Adding a mapping is a few lines
//! there, not code.

use std::collections::BTreeMap;
use std::sync::OnceLock;

use crate::ts::deps::{CrateMatch, Fit};

const TABLE: &str = include_str!("replacements.toml");

struct Entry {
    names: Vec<String>,
    prefixes: Vec<String>,
    replacement: String,
    fit: Fit,
    note: String,
}

fn table() -> &'static BTreeMap<String, Vec<Entry>> {
    static PARSED: OnceLock<BTreeMap<String, Vec<Entry>>> = OnceLock::new();
    PARSED.get_or_init(|| parse(TABLE).unwrap_or_default())
}

fn parse(text: &str) -> Result<BTreeMap<String, Vec<Entry>>, String> {
    let doc: toml_edit::DocumentMut = text
        .parse()
        .map_err(|e| format!("replacements.toml: {e}"))?;
    let strings = |t: &toml_edit::Table, key: &str| -> Vec<String> {
        t.get(key)
            .and_then(|v| v.as_array())
            .map(|a| {
                a.iter()
                    .filter_map(|v| v.as_str().map(String::from))
                    .collect()
            })
            .unwrap_or_default()
    };
    let mut out = BTreeMap::new();
    for (lang, item) in doc.iter() {
        let tables = item.as_array_of_tables().ok_or_else(|| {
            format!("replacements.toml: `{lang}` must be a list of [[{lang}]] entries")
        })?;
        let mut entries = Vec::new();
        for t in tables.iter() {
            let text = |key: &str| t.get(key).and_then(|v| v.as_str()).unwrap_or_default();
            let fit = match text("fit") {
                "good" => Fit::Good,
                "partial" => Fit::Partial,
                "none" => Fit::None,
                other => return Err(format!("replacements.toml: [[{lang}]] fit `{other}`")),
            };
            entries.push(Entry {
                names: strings(t, "names"),
                prefixes: strings(t, "prefixes"),
                replacement: text("replacement").to_string(),
                fit,
                note: text("note").to_string(),
            });
        }
        out.insert(lang.to_string(), entries);
    }
    Ok(out)
}

/// The first entry for `lang` whose names hold `name` or whose prefixes start it.
pub fn find(lang: &str, name: &str) -> Option<CrateMatch> {
    table()
        .get(lang)?
        .iter()
        .find(|e| {
            e.names.iter().any(|n| n == name)
                || e.prefixes.iter().any(|p| name.starts_with(p.as_str()))
        })
        .map(|e| CrateMatch {
            replacement: &e.replacement,
            fit: e.fit,
            note: &e.note,
        })
}

/// The longest configured prefix of `lang` that starts `name`, if any. A prefix ending in `.`
/// covers a whole namespace (`androidx.`), not one module, so it is never returned.
pub fn longest_prefix(lang: &str, name: &str) -> Option<&'static str> {
    table()
        .get(lang)?
        .iter()
        .flat_map(|e| e.prefixes.iter().map(String::as_str))
        .filter(|p| !p.ends_with('.') && name.starts_with(p))
        .max_by_key(|p| p.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A replacement is `-` (nothing), or a comma-separated list of Mojo stdlib modules
    /// (`std`, `std.<module>`), pixi packages and `python:<module>` names.
    fn well_formed(replacement: &str) -> bool {
        replacement == "-"
            || replacement.split(", ").all(|part| {
                let module = part.strip_prefix("python:").unwrap_or(part);
                !module.is_empty()
                    && module
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '.')
            })
    }

    #[test]
    fn replacements_table_parses() {
        let parsed = parse(TABLE).unwrap();
        assert_eq!(parsed.len(), 9);
        for (lang, entries) in &parsed {
            for e in entries {
                assert!(
                    !e.names.is_empty() || !e.prefixes.is_empty(),
                    "{lang}: {}",
                    e.replacement
                );
                assert!(
                    well_formed(&e.replacement),
                    "{lang}: {:?} -> {:?}",
                    e.names,
                    e.replacement
                );
                assert!(
                    matches!(e.fit, Fit::Good | Fit::Partial | Fit::None),
                    "{lang}"
                );
                assert_eq!(
                    e.replacement == "-",
                    e.fit == Fit::None,
                    "{lang}: {:?} -> {:?} {:?}",
                    e.names,
                    e.replacement,
                    e.fit
                );
                // A Python module stands in for another language's library only in part.
                if lang != "python" && e.replacement.starts_with("python:") {
                    assert_eq!(e.fit, Fit::Partial, "{lang}: {:?}", e.names);
                }
                assert!(
                    !e.replacement.contains("::") && !e.note.contains("crate"),
                    "{lang}: {:?} still names Rust: {} {}",
                    e.names,
                    e.replacement,
                    e.note
                );
            }
        }
        assert!(parse("[[ts]]\nnames = [\"x\"]\nfit = \"maybe\"\n").is_err());
    }

    #[test]
    fn python_yaml_maps_to_interop() {
        let m = find("python", "yaml").unwrap();
        assert_eq!((m.replacement, m.fit), ("python:yaml", Fit::Good));
        // The distribution name imports as the same module.
        assert_eq!(
            find("python", "pyyaml").map(|m| m.replacement),
            Some("python:yaml")
        );
        // Another language reaches the same module only as a stand-in.
        let ts = find("ts", "js-yaml").unwrap();
        assert_eq!((ts.replacement, ts.fit), ("python:yaml", Fit::Partial));
    }

    #[test]
    fn the_first_match_wins() {
        assert_eq!(
            find("java", "org.slf4j.Logger").map(|m| m.replacement),
            Some("std.logger")
        );
        assert_eq!(
            find("csharp", "Newtonsoft.Json").map(|m| m.replacement),
            Some("emberjson")
        );
        assert!(find("ts", "left-pad-but-new").is_none());
        assert!(find("nope", "json5").is_none());
    }

    #[test]
    fn c_calls_the_libraries_it_links_and_keeps_the_standard_headers() {
        for header in [
            "<zlib.h>",
            "<sqlite3.h>",
            "<libavcodec/avcodec.h>",
            "<opus.h>",
        ] {
            let m = find("c", header).unwrap_or_else(|| panic!("c: {header}"));
            assert_eq!((m.replacement, m.fit), ("std.ffi", Fit::Good), "{header}");
        }
        assert_eq!(find("c", "<stdio.h>").map(|m| m.replacement), Some("std"));
        assert!(find("c", "<not-a-header.h>").is_none());
    }

    #[test]
    fn frameworks_and_tools_stay_in_their_language() {
        for (lang, name) in [
            ("ts", "express"),
            ("python", "django"),
            ("python", "pytest"),
            ("ruby", "rails"),
            ("java", "org.springframework.boot.SpringApplication"),
            ("kotlin", "androidx.core.content.ContextCompat"),
        ] {
            let m = find(lang, name).unwrap_or_else(|| panic!("{lang}: {name}"));
            assert_eq!((m.replacement, m.fit), ("-", Fit::None), "{lang}: {name}");
        }
    }

    #[test]
    fn a_go_subpackage_import_maps_to_the_module_row() {
        assert_eq!(
            find("go", "github.com/spf13/cobra/doc").map(|m| m.replacement),
            Some("std.sys")
        );
        assert_eq!(
            find("go", "github.com/stretchr/testify/assert").map(|m| (m.replacement, m.fit)),
            Some(("std.testing", Fit::Good))
        );
        assert!(find("go", "github.com/not-a-module/x").is_none());
    }

    #[test]
    fn kotlin_prefixes_pick_the_specific_entry() {
        assert_eq!(
            find("kotlin", "androidx.room.Room").map(|m| m.replacement),
            Some("python:sqlite3")
        );
        assert_eq!(
            longest_prefix("kotlin", "androidx.room.Room"),
            Some("androidx.room")
        );
        assert_eq!(
            longest_prefix("kotlin", "androidx.core.content.ContextCompat"),
            None
        );
    }
}
