//! npm packages and what replaces them in Mojo.
//!
//! The table is deliberately small and opinionated: it names what a port should reach for
//! first. A package missing here is reported as `unknown`, never guessed.

use serde::Serialize;

/// How well the replacement covers what the library does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Fit {
    /// The replacement does the same job.
    Good,
    /// It covers the common case; some behavior needs checking or extra work.
    Partial,
    /// Nothing in Mojo does it: keep this part in the source language or call it across the bridge.
    None,
}

#[derive(Clone, Copy, Debug)]
pub struct CrateMatch {
    pub replacement: &'static str,
    pub fit: Fit,
    pub note: &'static str,
}

/// What replaces an npm package in Mojo, if the table knows it.
pub fn lookup(package: &str) -> Option<CrateMatch> {
    crate::crates::find("ts", package)
}

/// The package part of a bare import specifier: `@scope/name/sub` -> `@scope/name`.
pub fn package_name(specifier: &str) -> &str {
    let mut parts = specifier.splitn(3, '/');
    let first = parts.next().unwrap_or(specifier);
    if first.starts_with('@') {
        match parts.next() {
            Some(second) => &specifier[..first.len() + 1 + second.len()],
            None => specifier,
        }
    } else {
        first
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn splits_package_names() {
        assert_eq!(package_name("yaml"), "yaml");
        assert_eq!(package_name("svelte/compiler"), "svelte");
        assert_eq!(package_name("@x18n/core"), "@x18n/core");
        assert_eq!(package_name("@x18n/builtins/presets"), "@x18n/builtins");
    }

    #[test]
    fn knows_common_packages() {
        assert_eq!(lookup("json5").map(|m| m.fit), Some(Fit::Partial));
        assert_eq!(
            lookup("semver").map(|m| m.replacement),
            Some("python:nodesemver")
        );
        assert_eq!(lookup("jiti").map(|m| m.fit), Some(Fit::None));
        assert!(lookup("left-pad-but-new").is_none());
    }
}
