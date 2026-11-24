//! The port's API, [`PortApi`]: the functions and classes a port declares, read from
//! `port.mojo` by `codegen_mojo::parse_port_mojo`. Types are kept in the spelling the bridges
//! were first written for (`String`, `f64`, `Vec<T>`, `Option<T>`), mapped from Mojo's.
//!
//! The binding layer follows the port, not the source: change a port's types, run
//! `mojo-anything refresh`, and the bindings follow.

use crate::ts::exports::ExportedFn;

/// A port function, as declared in `port.rs`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortFn {
    pub js_name: String,
    pub rust_name: String,
    pub params: Vec<(String, String)>,
    /// The success type, `()` for none.
    pub ret: String,
    /// Returns `Result<T, String>`; an `Err` becomes a thrown JS error.
    pub fallible: bool,
    pub is_async: bool,
}

/// A port class: a struct with `new` and methods taking `&self` or `&mut self`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PortClass {
    pub js_name: String,
    pub rust_name: String,
    pub constructor: PortFn,
    pub methods: Vec<(PortFn, bool)>,
}

/// What `port.rs` offers to JS. `methods` pairs each method with whether it takes `&mut self`.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct PortApi {
    pub functions: Vec<PortFn>,
    pub classes: Vec<PortClass>,
    /// Every `pub struct` of `port.rs` (a batch uses `<Name>Index` when the port defines one).
    pub structs: Vec<String>,
    /// The structs whose `impl` has a `pub fn rank` (an index that ranks by itself).
    pub ranked: Vec<String>,
}

impl PortApi {
    /// Every function and method, for dependency and wire checks.
    pub fn all(&self) -> impl Iterator<Item = &PortFn> {
        self.functions.iter().chain(
            self.classes.iter().flat_map(|c| {
                std::iter::once(&c.constructor).chain(c.methods.iter().map(|(m, _)| m))
            }),
        )
    }

    pub fn needs_json(&self) -> bool {
        self.all().any(|f| {
            wire(&f.ret) == Wire::Json || f.params.iter().any(|(_, t)| wire(t) == Wire::Json)
        })
    }
}

/// How a Rust type crosses the bridge.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Wire {
    Native,
    Json,
    Units,
}

pub fn wire(ty: &str) -> Wire {
    let ty: String = ty.chars().filter(|c| !c.is_whitespace()).collect();
    match ty.as_str() {
        "String" | "f64" | "i64" | "bool" | "()" | "Vec<String>" | "Vec<f64>" | "Vec<i64>"
        | "Option<String>" | "Option<f64>" | "Option<i64>" | "Option<bool>" => Wire::Native,
        "Vec<u16>" => Wire::Units,
        _ => Wire::Json,
    }
}

pub fn is_async(f: &ExportedFn) -> bool {
    f.is_async || f.returns.trim().starts_with("Promise<")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn picks_wires() {
        assert_eq!(wire("Vec<String>"), Wire::Native);
        assert_eq!(wire("Option < f64 >"), Wire::Native);
        assert_eq!(wire("Vec<serde_json::Value>"), Wire::Json);
        assert_eq!(wire("Vec<bool>"), Wire::Json);
        assert_eq!(wire("Vec<u16>"), Wire::Units);
    }
}
