//! The HTTP front door: a Mojo server in `mojo/app` (`main.mojo` accepts connections, `http.mojo`
//! reads and writes HTTP/1.1 on the C library's sockets) that hands each request to `units.mojo`;
//! every route no unit answers goes to the original server (`original.mojo`), which the front
//! door starts on a port of its own.

use anyhow::{Result, bail, ensure};

use crate::codegen::PortApi;
use crate::front_door::{KILL_SWITCH_PREFIX, State, WiredUnit};
use crate::front_door_mojo::{GLUE_MARKER, mojo_ident, mojo_str, port_listing, port_package};

const METHODS: [&str; 7] = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"];

/// `http.mojo`: requests, responses, sockets and route matching, written into `mojo/app` as is.
pub(crate) const HTTP_MOJO: &str = include_str!("mojo/http.mojo");

/// `original.mojo` of a server, with `{{RUN}}`, `{{IN_ROOT}}`, `{{FALLBACK_ENV}}` and
/// `{{REPO_ENV}}` to fill.
const ORIGINAL_HTTP_MOJO: &str = include_str!("mojo/original_http.mojo");

/// The Mojo sources `front_door` writes for a server, in the order they are formatted.
pub const SOURCES: [&str; 4] = ["main.mojo", "original.mojo", "units.mojo", "http.mojo"];

/// A wired route: `METHOD /path/{param}`, `/path` (any method), or `*` (everything else).
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct Route {
    pub method: Option<String>,
    pub path: String,
}

impl Route {
    pub fn parse(text: &str) -> Result<Route> {
        let text = text.trim();
        if text == "*" {
            return Ok(Route {
                method: None,
                path: "*".to_string(),
            });
        }
        let (method, path) = match text.split_once(' ') {
            Some((m, p)) => (Some(m.trim().to_ascii_uppercase()), p.trim()),
            None => (None, text),
        };
        if let Some(m) = &method {
            ensure!(
                METHODS.contains(&m.as_str()),
                "route `{text}`: the method must be one of {}",
                METHODS.join(", ")
            );
        }
        ensure!(
            path.starts_with('/') && !path.contains(' ') && !path.contains('?'),
            "route `{text}`: give `METHOD /path` (/users/{{id}}, /files/{{*rest}}), `/path` for any method, or `*`"
        );
        Ok(Route {
            method,
            path: path.to_string(),
        })
    }

    pub fn key(&self) -> String {
        match &self.method {
            Some(m) => format!("{m} {}", self.path),
            None => self.path.clone(),
        }
    }

    fn has_params(&self) -> bool {
        self.path.contains('{')
    }
}

/// Rejects routes another unit already answers, and a path both for any method and for one.
pub(crate) fn check_routes(state: &State, unit: &str, routes: &[String]) -> Result<Vec<Route>> {
    let parsed = routes
        .iter()
        .map(|r| Route::parse(r))
        .collect::<Result<Vec<_>>>()?;
    let mut all: Vec<(String, Route)> = state
        .units
        .iter()
        .filter(|u| u.name != unit)
        .flat_map(|u| {
            u.routes
                .iter()
                .filter_map(|r| Route::parse(r).ok())
                .map(|r| (u.name.clone(), r))
                .collect::<Vec<_>>()
        })
        .collect();
    for route in &parsed {
        for (owner, other) in &all {
            if other.path == route.path
                && (other.method == route.method
                    || other.method.is_none()
                    || route.method.is_none())
            {
                bail!(
                    "`{}` overlaps `{}`, already wired to {owner}",
                    route.key(),
                    other.key()
                );
            }
        }
        all.push((unit.to_string(), route.clone()));
    }
    Ok(parsed)
}

/// The glue function that answers each of a unit's routes: `GET /div/{a}/{b}` is
/// `get_div_a_b`, `/any` is `any_any`, `*` is `fallback`; a repeated name gets `_2`, `_3`.
pub(crate) fn route_fns(routes: &[String]) -> Vec<(Route, String)> {
    let mut out: Vec<(Route, String)> = Vec::new();
    for text in routes {
        let Ok(route) = Route::parse(text) else {
            continue;
        };
        let base = if route.path == "*" {
            "fallback".to_string()
        } else {
            let method = route
                .method
                .as_deref()
                .map_or("any".to_string(), str::to_ascii_lowercase);
            let words: Vec<String> = route
                .path
                .split('/')
                .map(|s| s.trim_matches(|c| c == '{' || c == '}' || c == '*'))
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect();
            let path = if words.is_empty() {
                "root".to_string()
            } else {
                words.join("_")
            };
            mojo_ident(&format!("{method}_{path}"))
        };
        let mut name = base.clone();
        let mut n = 2;
        while out.iter().any(|(_, f)| *f == name) {
            name = format!("{base}_{n}");
            n += 1;
        }
        out.push((route, name));
    }
    out
}

/// The accept loop shared by the front door and the lifted server.
fn main_source(state: &State, lifted: bool) -> String {
    let (header, import_original, start) = if lifted {
        (
            format!(
                "`{}`, lifted by mojo-anything: every request is answered by a unit.",
                state.name.replace('\n', " ")
            ),
            "",
            "",
        )
    } else {
        (
            format!(
                "Front door for `{}`, generated by mojo-anything: it owns the server,\n\
                 # and the original answers every request no unit answers yet.",
                state.name.replace('\n', " ")
            ),
            "import original\n",
            "    original.report_fallbacks()\n    original.start()\n",
        )
    };
    format!(
        "# {header}

from std.os import getenv

import http
{import_original}import units


def main() raises:
{start}    var port = 8080
    var given = getenv(\"PORT\")
    if given.byte_length() > 0:
        port = Int(given)
    var listener = http.listen(port)
    while True:
        var fd = http.accept(listener)
        if fd < 0:
            continue
        var conn = http.Conn(fd)
        while True:
            var next: Optional[http.Request]
            try:
                next = http.read_request(conn)
            except e:
                _ = http.write_response(
                    fd, http.text(400, String(\"front door: \", e, \"\\n\")), False, False
                )
                break
            if not next:
                break
            var req = next.take()
            var resp: http.Response
            try:
                resp = units.handle(req)
            except e:
                resp = http.text(500, String(\"front door: \", e, \"\\n\"))
            var keep = req.keep_alive()
            if not http.write_response(fd, resp, req.method == \"HEAD\", keep):
                break
            if not keep or not http.wait_readable(fd, listener, 5000):
                break
        http.close(fd)
"
    )
}

/// `main.mojo` of the front door: starts the original, then answers every request through
/// `units.handle`.
pub(crate) fn main_mojo_http(state: &State) -> String {
    main_source(state, false)
}

/// `main.mojo` of a lifted server: no original left to start.
pub(crate) fn lifted_main_mojo_http(state: &State) -> String {
    main_source(state, true)
}

/// `original.mojo` of a server. `in_root`: the original runs in the repository, as recorded;
/// otherwise in the front door's own working directory (the recording copies fresh files there).
pub(crate) fn original_mojo_http(run: &[String], in_root: bool) -> String {
    let words: Vec<String> = run.iter().map(|w| mojo_str(w)).collect();
    let list = if words.is_empty() {
        "List[String]()".to_string()
    } else {
        format!("[{}]", words.join(", "))
    };
    ORIGINAL_HTTP_MOJO
        .replace("{{RUN}}", &list)
        .replace("{{IN_ROOT}}", if in_root { "True" } else { "False" })
        .replace("{{FALLBACK_ENV}}", crate::app::FALLBACK_ENV)
        .replace("{{REPO_ENV}}", crate::front_door::REPO_ENV)
}

/// `units.mojo` of a server: each wired route goes to its glue function unless the unit's kill
/// switch says `original`; static paths are tried first, then paths with parameters, then `*`;
/// anything else goes to the original (front door) or answers 404 (lifted).
pub(crate) fn units_mojo_http(state: &State, lifted: bool) -> String {
    struct Handler {
        module: String,
        switch: String,
        route: Route,
        function: String,
    }
    let mut handlers: Vec<Handler> = Vec::new();
    for unit in &state.units {
        for (route, function) in route_fns(&unit.routes) {
            handlers.push(Handler {
                module: mojo_ident(&unit.name),
                switch: unit
                    .switch
                    .strip_prefix(KILL_SWITCH_PREFIX)
                    .unwrap_or(&unit.switch)
                    .to_string(),
                route,
                function,
            });
        }
    }
    let mut out = String::from(if lifted {
        "# Written by `mojo-anything app lift`: every route is answered by a unit.\n"
    } else {
        "# Generated by `mojo-anything app wire` from mojo-anything.json; it is\n\
         # rewritten on every wire.\n"
    });
    let guarded = !lifted && !handlers.is_empty();
    out += "\n";
    if guarded {
        out += "from std.os import getenv\n\n";
    }
    out += "import http\n";
    if !lifted {
        out += "import original\n";
    }
    let mut modules: Vec<&str> = handlers.iter().map(|h| h.module.as_str()).collect();
    modules.sort_unstable();
    modules.dedup();
    if !modules.is_empty() {
        out += &format!("from glue import {}\n", modules.join(", "));
    }
    if guarded {
        out += &format!(
            "\n\ndef _sent_to_original(unit: String) -> Bool:\n    \
             \"\"\"`{KILL_SWITCH_PREFIX}<NAME>=original` sends that unit back to the\n    \
             original.\"\"\"\n    \
             return getenv({} + unit) == \"original\"\n",
            mojo_str(KILL_SWITCH_PREFIX)
        );
    }
    out += "\n\ndef handle(req: http.Request) raises -> http.Response:\n    \
            \"\"\"The response of the unit whose route matches `req`.\"\"\"\n";
    let call = |h: &Handler| -> String {
        let guard = if lifted {
            String::new()
        } else {
            format!(
                "if _sent_to_original({}):\n        return original.proxy(req)\n    ",
                mojo_str(&h.switch)
            )
        };
        let params = if h.route.has_params() {
            format!("http.path_params({}, path)", mojo_str(&h.route.path))
        } else {
            "Dict[String, String]()".to_string()
        };
        format!("{guard}return {}.{}(req, {params})\n", h.module, h.function)
    };
    let routed: Vec<&Handler> = handlers
        .iter()
        .filter(|h| h.route.path != "*" && !h.route.has_params())
        .chain(handlers.iter().filter(|h| h.route.has_params()))
        .collect();
    if !routed.is_empty() {
        out += "    var path = req.path()\n";
    }
    for h in routed {
        let path_test = if h.route.has_params() {
            format!("http.matches({}, path)", mojo_str(&h.route.path))
        } else {
            format!("path == {}", mojo_str(&h.route.path))
        };
        let test = match &h.route.method {
            Some(m) => format!("req.method == {} and {path_test}", mojo_str(m)),
            None => path_test,
        };
        out += &format!(
            "    if {test}:\n        {}",
            call(h).replace("\n    ", "\n        ")
        );
    }
    match handlers.iter().find(|h| h.route.path == "*") {
        Some(h) => out += &format!("    {}", call(h)),
        None if lifted => out += "    return http.Response(404)\n",
        None => out += "    return original.proxy(req)\n",
    }
    out
}

fn glue_stub_fn(route: &Route, function: &str) -> String {
    format!(
        "\n\ndef {function}(\n    req: http.Request, params: Dict[String, String]\n) raises -> http.Response:\n    \
         {GLUE_MARKER} `{}`, answered by the original until filled in.\n    \
         return original.proxy(req)\n",
        route.key()
    )
}

/// `mojo/app/glue/<unit>.mojo` of a server: one stub per wired route, each handing its request
/// to the original until it is filled in, and the port's functions listed to call.
pub(crate) fn glue_mojo_http(unit: &WiredUnit, api: &PortApi) -> String {
    let package = port_package(&unit.name);
    let mut out = format!(
        "# Glue for the unit `{}`, written by `mojo-anything app wire`. Each function\n\
         # answers one route: it gets the request and the route's path parameters\n\
         # (percent-decoded) and returns the response, such as `http.text(200, body)` or\n\
         # `http.Response(status, content_type, body)`. Until a function is filled in, it\n\
         # hands its request to the original; a request the port cannot answer yet goes\n\
         # back with `original.proxy(req)`. `app lift` needs every `original.` gone.\n#\n\
         # The port is `from {package} import port`",
        unit.name
    );
    out += &port_listing(api);
    out += "\nimport http\nimport original\n";
    for (route, function) in route_fns(&unit.routes) {
        out += &glue_stub_fn(&route, &function);
    }
    out
}

/// Stubs for the routes `glue` has no function for yet (wiring more routes to a unit).
pub(crate) fn missing_glue_http(glue: &str, routes: &[String]) -> String {
    let mut out = String::new();
    for (route, function) in route_fns(routes) {
        let def = format!("def {function}(");
        if !glue.lines().any(|l| l.starts_with(&def)) {
            out += &glue_stub_fn(&route, &function);
        }
    }
    if out.is_empty() {
        return out;
    }
    let mut imports = String::new();
    for module in ["http", "original"] {
        let line = format!("import {module}");
        if !glue.lines().any(|l| l.trim() == line) {
            imports += &line;
            imports.push('\n');
        }
    }
    if imports.is_empty() {
        out
    } else {
        format!("\n\n{imports}{out}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::front_door::{AppKind, WiredUnit};

    fn state(routes: &[&str]) -> State {
        State {
            schema: String::new(),
            name: "srv".into(),
            commands: Vec::new(),
            units: vec![WiredUnit {
                name: "api".into(),
                crate_name: "api-mojo".into(),
                path: "../api-mojo".into(),
                commands: Vec::new(),
                routes: routes.iter().map(|r| r.to_string()).collect(),
                switch: "MOJO_ANYTHING_UNIT_API".into(),
                unit: None,
                shadow: None,
                kept: Vec::new(),
            }],
            lifted: false,
            kind: AppKind::Http,
            routes: Vec::new(),
            api: Vec::new(),
        }
    }

    #[test]
    fn generated_servers_send_without_nagle_delays() {
        // Every accepted and every outgoing socket gets TCP_NODELAY.
        assert!(HTTP_MOJO.contains("comptime _TCP_NODELAY = Int32(1)"));
        assert_eq!(
            HTTP_MOJO
                .matches("_set_int(fd, _IPPROTO_TCP, _TCP_NODELAY, 1)")
                .count(),
            2,
            "accept and connect"
        );
        for code in [
            main_mojo_http(&state(&[])),
            lifted_main_mojo_http(&state(&[])),
        ] {
            assert!(code.contains("http.accept(listener)"), "{code}");
        }
    }

    #[test]
    fn every_external_call_says_why_it_is_safe() {
        for code in [HTTP_MOJO, ORIGINAL_HTTP_MOJO] {
            let lines: Vec<&str> = code.lines().collect();
            for (i, line) in lines.iter().enumerate() {
                if line.contains("external_call[") {
                    let above = lines[..i]
                        .iter()
                        .rev()
                        .take_while(|l| l.trim_start().starts_with('#'))
                        .any(|l| l.contains("# SAFETY:"));
                    assert!(above, "line {}: {line}", i + 1);
                }
            }
        }
    }

    #[test]
    fn routes_parse_and_overlaps_are_refused() {
        assert_eq!(
            Route::parse("get /div/{a}/{b}").unwrap().key(),
            "GET /div/{a}/{b}"
        );
        assert_eq!(Route::parse("/any").unwrap().method, None);
        assert!(Route::parse("FETCH /x").is_err());
        assert!(Route::parse("GET x").is_err());
        let s = state(&["GET /hello", "*"]);
        assert!(check_routes(&s, "other", &["POST /hello".into()]).is_ok());
        assert!(check_routes(&s, "other", &["GET /hello".into()]).is_err());
        assert!(check_routes(&s, "other", &["/hello".into()]).is_err());
        assert!(check_routes(&s, "other", &["*".into()]).is_err());
        assert!(check_routes(&s, "api", &["GET /hello".into()]).is_ok());
    }

    #[test]
    fn route_functions_are_named_after_their_routes() {
        let names: Vec<String> = route_fns(&[
            "GET /div/{a}/{b}".into(),
            "/files/{*rest}".into(),
            "GET /".into(),
            "*".into(),
            "GET /div/{x}/{y}".into(),
        ])
        .into_iter()
        .map(|(_, f)| f)
        .collect();
        assert_eq!(
            names,
            [
                "get_div_a_b",
                "any_files_rest",
                "get_root",
                "fallback",
                "get_div_x_y"
            ]
        );
        let twice = route_fns(&["GET /a-b".into(), "GET /a_b".into()]);
        assert_eq!(twice[1].1, "get_a_b_2");
    }

    #[test]
    fn units_route_with_kill_switches_and_fallback() {
        let s = state(&["GET /div/{a}/{b}", "POST /div/{a}/{b}", "GET /hello", "*"]);
        let code = units_mojo_http(&s, false);
        let hello = code.find("path == \"/hello\"").unwrap();
        let div = code.find("http.matches(\"/div/{a}/{b}\", path)").unwrap();
        assert!(hello < div, "static paths first: {code}");
        assert!(
            code.contains(
                "    if req.method == \"GET\" and http.matches(\"/div/{a}/{b}\", path):\n        \
                 if _sent_to_original(\"API\"):\n            return original.proxy(req)\n        \
                 return api.get_div_a_b(req, http.path_params(\"/div/{a}/{b}\", path))\n"
            ),
            "{code}"
        );
        assert!(code.contains("return api.post_div_a_b("), "{code}");
        assert!(
            code.contains("    return api.fallback(req, Dict[String, String]())\n"),
            "{code}"
        );
        assert!(code.contains("from glue import api\n"), "{code}");
        let lifted = units_mojo_http(&s, true);
        assert!(!lifted.contains("original"), "{lifted}");
        assert!(!lifted.contains("getenv"), "{lifted}");
        let empty = units_mojo_http(&state(&[]), false);
        assert!(
            empty.contains("    return original.proxy(req)\n"),
            "{empty}"
        );
        assert!(!empty.contains("var path"), "{empty}");
        let no_star = units_mojo_http(&state(&["GET /hello"]), true);
        assert!(no_star.contains("return http.Response(404)"), "{no_star}");
    }

    #[test]
    fn glue_stubs_hand_requests_to_the_original() {
        let api = crate::codegen_mojo::parse_port_mojo(
            "def upper(text: String) -> String:\n    return text.upper()\n",
        );
        let unit = state(&["GET /hello", "*"]).units.remove(0);
        let glue = glue_mojo_http(&unit, &api);
        assert!(crate::front_door::is_stub(&glue), "{glue}");
        assert!(glue.contains("from api import port"), "{glue}");
        assert!(
            glue.contains("#   port.upper(text: String) -> String"),
            "{glue}"
        );
        assert!(glue.contains("def get_hello(\n"), "{glue}");
        assert!(glue.contains("def fallback(\n"), "{glue}");
        assert!(glue.contains("    return original.proxy(req)\n"), "{glue}");
        let filled = "import http\n\n\ndef get_hello(\n    req: http.Request, params: Dict[String, String]\n) raises -> http.Response:\n    return http.text(200, \"hi\")\n";
        let more = missing_glue_http(filled, &["GET /hello".into(), "POST /upper".into()]);
        assert!(more.contains("import original\n"), "{more}");
        assert!(!more.contains("import http\n"), "{more}");
        assert!(more.contains("def post_upper("), "{more}");
        assert!(!more.contains("def get_hello("), "{more}");
        assert!(missing_glue_http(filled, &["GET /hello".into()]).is_empty());
    }
}
