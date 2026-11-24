//! The CLI front door as a Mojo binary: `mojo/app` is a pixi project with `main.mojo` (routing),
//! `original.mojo` (the fallback to the original), `units.mojo` (kill switches and calls into
//! the wired units' glue) and later one glue file per wired unit.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail, ensure};

use crate::codegen::PortApi;
use crate::front_door::{
    Flag, KILL_SWITCH_PREFIX, REPO_ENV, STATE_FILE, State, WiredUnit, package_name,
};
use crate::walk::Canonical;

/// `original.mojo`, with `{{RUN}}`, `{{REPO_FILES}}`, `{{IN_ROOT}}`, `{{FALLBACK_ENV}}` and
/// `{{REPO_ENV}}` to fill, and `#[linux]` / `#[macos]` regions (see [`render_os`]).
pub(crate) const ORIGINAL_MOJO: &str = include_str!("mojo/original.mojo");

/// How a front door finds its own executable, for the repository beside it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExePath {
    /// `readlink("/proc/self/exe")` (Linux).
    ProcSelfExe,
    /// `_NSGetExecutablePath`, then `realpath` (macOS).
    NsGetExecutablePath,
}

/// The values a generated front door uses that differ between the systems Mojo builds on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OsConstants {
    /// `linux` or `macos`: the `CompilationTarget.is_<os>()` the generated code checks.
    pub os: &'static str,
    pub sol_socket: i32,
    pub so_reuseaddr: i32,
    pub so_rcvtimeo: i32,
    /// `sizeof(struct timeval)`.
    pub timeval_size: i32,
    pub af_inet6: i32,
    pub ipv6_v6only: i32,
    /// `MSG_NOSIGNAL` for `send`; 0 where sockets get `SO_NOSIGPIPE` instead (macOS).
    pub msg_nosignal: i32,
    /// `PR_SET_PDEATHSIG`: the original gets SIGTERM when the front door ends, however it ends.
    pub has_pdeathsig: bool,
    pub exe_path: ExePath,
}

/// The constants for `os` (`std::env::consts::OS` spelling); anything but `macos` is Linux,
/// the only other system Mojo builds on.
pub fn os_constants(os: &str) -> OsConstants {
    if os == "macos" {
        OsConstants {
            os: "macos",
            sol_socket: 0xffff,
            so_reuseaddr: 4,
            so_rcvtimeo: 0x1006,
            timeval_size: 16,
            af_inet6: 30,
            ipv6_v6only: 27,
            msg_nosignal: 0,
            has_pdeathsig: false,
            exe_path: ExePath::NsGetExecutablePath,
        }
    } else {
        OsConstants {
            os: "linux",
            sol_socket: 1,
            so_reuseaddr: 2,
            so_rcvtimeo: 20,
            timeval_size: 16,
            af_inet6: 10,
            ipv6_v6only: 26,
            msg_nosignal: 0x4000,
            has_pdeathsig: true,
            exe_path: ExePath::ProcSelfExe,
        }
    }
}

/// The constants of the machine mojo-anything runs on, where the front door is built.
pub fn host_os() -> OsConstants {
    os_constants(std::env::consts::OS)
}

/// A front door template for one system: lines from `#[linux]` or `#[macos]` up to the next such
/// marker or `#[end]` are kept only for that system (the marker lines go), and the `{{OS}}`,
/// `{{SOL_SOCKET}}`, ... placeholders take the values of `c`.
pub(crate) fn render_os(template: &str, c: &OsConstants) -> String {
    let mut out = String::with_capacity(template.len());
    let mut keep = true;
    for line in template.split_inclusive('\n') {
        match line.trim() {
            "#[linux]" => keep = c.os == "linux",
            "#[macos]" => keep = c.os == "macos",
            "#[end]" => keep = true,
            _ if keep => out += line,
            _ => {}
        }
    }
    out.replace("{{OS}}", c.os)
        .replace("{{SOL_SOCKET}}", &c.sol_socket.to_string())
        .replace("{{SO_REUSEADDR}}", &c.so_reuseaddr.to_string())
        .replace("{{SO_RCVTIMEO}}", &c.so_rcvtimeo.to_string())
        .replace("{{TIMEVAL_SIZE}}", &c.timeval_size.to_string())
        .replace("{{AF_INET6}}", &c.af_inet6.to_string())
        .replace("{{IPV6_V6ONLY}}", &c.ipv6_v6only.to_string())
        .replace("{{MSG_NOSIGNAL}}", &c.msg_nosignal.to_string())
}

/// Where the front door's binary is built, inside `mojo/app`; nothing else builds there.
pub const BUILD_DIR: &str = ".mojo-anything/build";

/// The Mojo sources `front_door` writes, in the order they are formatted.
pub const SOURCES: [&str; 3] = ["main.mojo", "original.mojo", "units.mojo"];

/// A Mojo string literal holding `text`.
pub(crate) fn mojo_str(text: &str) -> String {
    let mut out = String::from("\"");
    for c in text.chars() {
        match c {
            '\\' => out += "\\\\",
            '"' => out += "\\\"",
            '\n' => out += "\\n",
            '\t' => out += "\\t",
            '\r' => out += "\\r",
            c => out.push(c),
        }
    }
    out.push('"');
    out
}

fn mojo_list(items: &[String]) -> String {
    if items.is_empty() {
        return "List[String]()".to_string();
    }
    let quoted: Vec<String> = items.iter().map(|i| mojo_str(i)).collect();
    format!("[{}]", quoted.join(", "))
}

/// A Mojo identifier for `name`: keywords and the builtins a glue module would shadow get `_`.
pub(crate) fn mojo_ident(name: &str) -> String {
    const RESERVED: [&str; 52] = [
        "False", "None", "True", "alias", "and", "as", "async", "await", "break", "case",
        "comptime", "continue", "def", "deinit", "del", "elif", "else", "except", "finally", "fn",
        "for", "from", "global", "if", "import", "in", "inout", "is", "lambda", "let", "match",
        "mut", "not", "or", "out", "owned", "pass", "raise", "raises", "ref", "return", "struct",
        "trait", "try", "var", "while", "with", "yield", "len", "print", "range", "input",
    ];
    let mut out: String = name
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() {
                c.to_ascii_lowercase()
            } else {
                '_'
            }
        })
        .collect();
    if out.is_empty() || out.starts_with(|c: char| c.is_ascii_digit()) {
        out = format!("unit_{out}");
    }
    if RESERVED.contains(&out.as_str())
        || [
            "open", "exit", "abs", "min", "max", "chr", "ord", "repr", "hash",
        ]
        .contains(&out.as_str())
    {
        out.push('_');
    }
    out
}

/// The options a command was recorded with, as they are spelled on the command line.
fn seen_options(flags: Option<&BTreeMap<String, Flag>>) -> Vec<String> {
    let mut out = Vec::new();
    for flag in flags.into_iter().flat_map(BTreeMap::values) {
        if let Some(long) = &flag.long {
            out.push(format!("--{long}"));
        }
        if let Some(short) = flag.short {
            out.push(format!("-{short}"));
        }
    }
    out.sort();
    out.dedup();
    out
}

/// `main.mojo`: picks the command from argv and hands it to `units.dispatch` when its options are
/// ones the recording saw; everything else runs the original.
pub(crate) fn main_mojo(state: &State, flags: &BTreeMap<String, BTreeMap<String, Flag>>) -> String {
    let mut seen = String::new();
    for (command, options) in flags {
        let options = seen_options(Some(options));
        if options.is_empty() {
            continue;
        }
        let name = if command.is_empty() {
            &state.name
        } else {
            command
        };
        seen += &format!(
            "    if command == {}:\n        return {}\n",
            mojo_str(name),
            mojo_list(&options)
        );
    }
    seen += "    return List[String]()\n";
    format!(
        "# Front door for `{name}`, generated by mojo-anything: it owns the entry point,
# and the original answers every command no unit answers yet.

from std.sys import argv, exit

import original
import units

comptime ROOT = {root}


def _commands() -> List[String]:
    \"\"\"The commands the original answered while it was recorded.\"\"\"
    return {commands}


def _seen_options(command: String) -> List[String]:
    \"\"\"The options each command was recorded with.\"\"\"
{seen}

def _is_letter(byte: UInt8) -> Bool:
    return (byte >= 65 and byte <= 90) or (byte >= 97 and byte <= 122)


def _known_options(command: String, args: List[String], start: Int) -> Bool:
    \"\"\"Whether every option in `args` was seen while recording. Anything else
    goes to the original, which defines what it means.\"\"\"
    var seen = _seen_options(command)
    for i in range(start, len(args)):
        var arg = args[i]
        if arg == \"--\":
            break
        if arg.startswith(\"--\"):
            var name = arg
            var eq = arg.find(\"=\")
            if eq >= 0:
                name = String(arg[byte=0:eq])
            if not (name in seen):
                return False
        elif (
            arg.byte_length() == 2
            and arg.startswith(\"-\")
            and _is_letter(arg.as_bytes()[1])
        ):
            if not (arg in seen):
                return False
    return True


def main() raises:
    original.report_fallbacks()
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    var command = String(ROOT)
    var start = 0
    if len(args) > 0 and args[0] in _commands():
        command = args[0]
        start = 1
    if _known_options(command, args, start):
        var code = units.dispatch(command, args)
        if code:
            exit(code.value())
    exit(original.run(args))
",
        name = state.name.replace('\n', " "),
        root = mojo_str(&state.name),
        commands = mojo_list(&state.commands),
    )
}

/// `original.mojo`: `run`, `run_with_stdin` and `report_fallbacks`. `in_root`: the original
/// starts in the repository, as recorded; otherwise in the front door's working directory.
/// `repo_files`: the words of `run` that name files in the repository; one missing there
/// stops the front door with an error naming it instead of running whatever has that name in
/// the working directory.
pub(crate) fn original_mojo(
    run: &[String],
    repo_files: &[String],
    in_root: bool,
    os: &OsConstants,
) -> String {
    render_os(ORIGINAL_MOJO, os)
        .replace("{{RUN}}", &mojo_list(run))
        .replace("{{REPO_FILES}}", &mojo_list(repo_files))
        .replace("{{IN_ROOT}}", if in_root { "True" } else { "False" })
        .replace("{{FALLBACK_ENV}}", crate::app::FALLBACK_ENV)
        .replace("{{REPO_ENV}}", REPO_ENV)
}

/// The words of a recorded command that name files in `repo` (options and programs on PATH
/// do not).
pub(crate) fn repo_files(run: &[String], repo: &Path) -> Vec<String> {
    run.iter()
        .filter(|w| !w.starts_with('-') && !w.is_empty() && repo.join(w).is_file())
        .cloned()
        .collect()
}

/// `units.mojo`: each wired command goes to its unit's glue unless the unit's kill switch says
/// `original`; a lifted app has no kill switches.
pub(crate) fn units_mojo(state: &State, lifted: bool) -> String {
    let mut out = String::from(
        "# Generated by `mojo-anything app wire` from mojo-anything.json; it is\n\
         # rewritten on every wire.\n",
    );
    let units: Vec<_> = state
        .units
        .iter()
        .filter(|u| !u.commands.is_empty())
        .collect();
    let mut imports = Vec::new();
    if !lifted && !units.is_empty() {
        imports.push("from std.os import getenv\n".to_string());
    }
    let glue: Vec<String> = units.iter().map(|u| mojo_ident(&u.name)).collect();
    if !glue.is_empty() {
        imports.push(format!("from glue import {}\n", glue.join(", ")));
    }
    if !imports.is_empty() {
        out += "\n";
        out += &imports.join("\n");
    }
    if !lifted && !units.is_empty() {
        out += &format!(
            "\n\ndef _sent_to_original(unit: String) -> Bool:\n    \
             \"\"\"`{KILL_SWITCH_PREFIX}<NAME>=original` sends that unit back to the\n    \
             original.\"\"\"\n    \
             return getenv({} + unit) == \"original\"\n",
            mojo_str(KILL_SWITCH_PREFIX)
        );
    }
    out += "\n\ndef dispatch(command: String, args: List[String]) raises -> Optional[Int]:\n    \
            \"\"\"The exit code of the unit that answers `command`, or None to run the\n    \
            original. `args` holds every argument after the program name.\"\"\"\n";
    for (unit, module) in units.iter().zip(&glue) {
        let switch = unit
            .switch
            .strip_prefix(KILL_SWITCH_PREFIX)
            .unwrap_or(&unit.switch);
        for command in &unit.commands {
            let guard = if lifted {
                String::new()
            } else {
                format!(" and not _sent_to_original({})", mojo_str(switch))
            };
            out += &format!(
                "    if command == {}{guard}:\n        return {module}.{}(args)\n",
                mojo_str(command),
                mojo_ident(command)
            );
        }
    }
    out += "    return None\n";
    out
}

/// `main.mojo` of a lifted app: every command goes to its unit; there is no original left.
pub(crate) fn lifted_main_mojo(state: &State) -> String {
    format!(
        "# `{name}`, lifted by mojo-anything: every command is answered by a unit.

from std.sys import argv, exit, stderr

import units

comptime ROOT = {root}


def _commands() -> List[String]:
    \"\"\"The commands the app answers.\"\"\"
    return {commands}


def main() raises:
    var raw = argv()
    var args = List[String]()
    for i in range(1, len(raw)):
        args.append(String(raw[i]))
    var command = String(ROOT)
    if len(args) > 0 and args[0] in _commands():
        command = args[0]
    var code = units.dispatch(command, args)
    if code:
        exit(code.value())
    print(String(ROOT, \": no unit answers `\", command, \"`\"), file=stderr)
    exit(2)
",
        name = state.name.replace('\n', " "),
        root = mojo_str(&state.name),
        commands = mojo_list(&state.commands),
    )
}

/// `mojo/app/pixi.toml`: the Mojo the front door builds with, the one mojo-anything pins, and
/// EmberJson when a wired unit's port uses `json.mojo`.
pub fn pixi_toml_app(name: &str, json: bool) -> String {
    let quote = |items: &[&str]| {
        items
            .iter()
            .map(|s| format!("\"{s}\""))
            .collect::<Vec<_>>()
            .join(", ")
    };
    let (preview, dep) = if json {
        (
            "preview = [\"pixi-build\"]\n",
            format!("{}\n", crate::codegen_mojo_py::EMBERJSON),
        )
    } else {
        ("", String::new())
    };
    format!(
        "# Generated by mojo-anything: the Mojo the front door builds with.\n\
         [workspace]\nname = \"{name}\"\nchannels = [{}]\nplatforms = [{}]\n{preview}\n\
         [dependencies]\nmojo = \"=={}\"\n{dep}",
        quote(crate::mojo::CHANNELS),
        quote(crate::mojo::PLATFORMS),
        crate::mojo::MOJO_VERSION
    )
}

/// Adds EmberJson to the app's `pixi.toml` when it is missing (a wired port uses `json.mojo`);
/// the rest of the file is left as it is.
pub(crate) fn add_json_dependency(app_dir: &Path) -> Result<()> {
    use toml_edit::{DocumentMut, value};
    let path = app_dir.join("pixi.toml");
    let mut doc: DocumentMut = std::fs::read_to_string(&path)
        .with_context(|| format!("reading {}", path.display()))?
        .parse()
        .with_context(|| format!("parsing {}", path.display()))?;
    if doc
        .get("dependencies")
        .and_then(|d| d.get("emberjson"))
        .is_some()
    {
        return Ok(());
    }
    let ember: DocumentMut = crate::codegen_mojo_py::EMBERJSON.parse()?;
    doc["dependencies"]["emberjson"] = ember["emberjson"].clone();
    if doc["workspace"].get("preview").is_none() {
        let mut preview = toml_edit::Array::new();
        preview.push("pixi-build");
        doc["workspace"]["preview"] = value(preview);
    }
    std::fs::write(&path, doc.to_string()).with_context(|| format!("writing {}", path.display()))
}

/// The marker a glue stub carries until its command is answered in Mojo.
pub const GLUE_MARKER: &str = "# TODO(mojo-anything): glue for";

/// Names the app's own modules take: a unit's package cannot be called that.
const APP_MODULES: [&str; 5] = ["main", "original", "units", "glue", "std"];

/// The Mojo package a wired unit's port is imported from: `from <package> import port`.
pub fn port_package(unit_name: &str) -> String {
    let ident = mojo_ident(unit_name);
    if APP_MODULES.contains(&ident.as_str()) {
        format!("{ident}_unit")
    } else {
        ident
    }
}

/// The module an `import X` / `from X import` line names, the rest of the line, and whether
/// it is a `from` line.
fn imported_module(line: &str) -> Option<(&str, &str, bool)> {
    let trimmed = line.trim_start();
    if let Some(rest) = trimmed.strip_prefix("from ") {
        let end = rest.find(char::is_whitespace)?;
        return Some((&rest[..end], &rest[end..], true));
    }
    let rest = trimmed.strip_prefix("import ")?;
    let end = rest
        .find(|c: char| c.is_whitespace() || c == ',')
        .unwrap_or(rest.len());
    Some((&rest[..end], &rest[end..], false))
}

/// The modules beside `port.mojo` that it imports, transitively (`port` itself not included).
pub fn port_modules(unit_dir: &Path) -> Vec<String> {
    local_modules(unit_dir, &["port"])
}

/// The modules beside `roots` (module names in `unit_dir`) that they import, transitively;
/// `port` and the roots themselves are not included.
pub fn local_modules(unit_dir: &Path, roots: &[&str]) -> Vec<String> {
    let mut found: Vec<String> = Vec::new();
    let mut queue: Vec<String> = roots.iter().map(|r| r.to_string()).collect();
    while let Some(module) = queue.pop() {
        let text =
            std::fs::read_to_string(unit_dir.join(format!("{module}.mojo"))).unwrap_or_default();
        for line in text.lines() {
            let Some((name, _, _)) = imported_module(line) else {
                continue;
            };
            if name != "port"
                && !roots.contains(&name)
                && !name.contains('.')
                && !found.iter().any(|f| f == name)
                && unit_dir.join(format!("{name}.mojo")).is_file()
            {
                found.push(name.to_string());
                queue.push(name.to_string());
            }
        }
    }
    found.sort();
    found
}

/// A unit module's source as a module of the package `package`: imports of the unit's own
/// modules (`locals`) name them through the package, so two units' helpers never collide.
pub(crate) fn package_source(text: &str, package: &str, locals: &[String]) -> String {
    let mut out = String::new();
    for line in text.split_inclusive('\n') {
        let rewritten = imported_module(line).and_then(|(name, rest, from)| {
            if !locals.iter().any(|l| l == name) {
                return None;
            }
            let indent = &line[..line.len() - line.trim_start().len()];
            Some(if from || rest.trim_start().starts_with("as ") {
                let word = if from { "from" } else { "import" };
                format!("{indent}{word} {package}.{name}{rest}")
            } else {
                let newline = if rest.ends_with('\n') { "\n" } else { "" };
                format!(
                    "{indent}import {package}.{name} as {name}{}{newline}",
                    rest.trim_end()
                )
            })
        });
        out += rewritten.as_deref().unwrap_or(line);
    }
    out
}

/// Where the wired units' packages are put together for the build, inside `mojo/app`.
pub const UNITS_BUILD_DIR: &str = ".mojo-anything/build/units";

/// Puts each wired unit's `port.mojo` and the modules it imports into a package of its own
/// under [`UNITS_BUILD_DIR`] (rewritten on every build); returns that folder for `-I`.
fn stage_packages(app_dir: &Path, state: &State) -> Result<PathBuf> {
    let root = app_dir.join(UNITS_BUILD_DIR);
    if root.exists() {
        std::fs::remove_dir_all(&root).with_context(|| format!("clearing {}", root.display()))?;
    }
    std::fs::create_dir_all(&root)?;
    for unit in state
        .units
        .iter()
        .filter(|u| !u.commands.is_empty() || !u.routes.is_empty())
    {
        let dir = app_dir.join(&unit.path);
        ensure!(
            dir.join("port.mojo").is_file(),
            "the unit {} has no port.mojo at {}",
            unit.name,
            dir.display()
        );
        let package = port_package(&unit.name);
        let out = root.join(&package);
        std::fs::create_dir_all(&out)?;
        std::fs::write(
            out.join("__init__.mojo"),
            format!(
                "# The unit `{}` as a package, put together from {} by mojo-anything.\n",
                unit.name, unit.path
            ),
        )?;
        let locals = port_modules(&dir);
        for module in std::iter::once("port".to_string()).chain(locals.iter().cloned()) {
            let source = dir.join(format!("{module}.mojo"));
            let text = std::fs::read_to_string(&source)
                .with_context(|| format!("reading {}", source.display()))?;
            std::fs::write(
                out.join(format!("{module}.mojo")),
                package_source(&text, &package, &locals),
            )?;
        }
    }
    Ok(root)
}

/// The end of a glue file's header: `.` or the port's public functions, one comment line each.
pub(crate) fn port_listing(api: &PortApi) -> String {
    if api.functions.is_empty() {
        return ".\n".to_string();
    }
    let mut out = ", offering:\n".to_string();
    for f in &api.functions {
        let params: Vec<String> = f
            .params
            .iter()
            .map(|(name, ty)| format!("{name}: {ty}"))
            .collect();
        let ret = if f.ret.is_empty() || f.ret == "()" {
            String::new()
        } else {
            format!(" -> {}", f.ret)
        };
        out += &format!("#   port.{}({}){ret}\n", f.rust_name, params.join(", "));
    }
    out
}

/// One stub function of a glue file: hands `command` back to the original.
fn glue_stub_fn(command: &str) -> String {
    format!(
        "\n\ndef {}(args: List[String]) raises -> Int:\n    \
         {GLUE_MARKER} `{command}`, answered by the original until filled in.\n    \
         return original.run(args)\n",
        mojo_ident(command)
    )
}

/// `mojo/app/glue/<unit>.mojo`: one stub per wired command, each handing the command back to
/// the original until it is filled in, and the port's functions listed to call.
pub(crate) fn glue_mojo(unit: &WiredUnit, api: &PortApi) -> String {
    let package = port_package(&unit.name);
    let mut out = format!(
        "# Glue for the unit `{}`, written by `mojo-anything app wire`. Each function\n\
         # answers one command: it gets every argument after the program name (the\n\
         # command word included) and returns the exit code. Until a function is filled\n\
         # in, it hands its command back to the original; a case the port cannot answer\n\
         # yet goes back with `original.run(args)`, or `original.run_with_stdin(args,\n\
         # input)` once stdin was read. `app lift` needs every `original.` gone.\n#\n\
         # The port is `from {package} import port`",
        unit.name
    );
    out += &port_listing(api);
    out += "\nimport original\n";
    for command in &unit.commands {
        out += &glue_stub_fn(command);
    }
    out
}

/// Stubs for the commands `glue` has no function for yet (wiring more commands to a unit).
pub(crate) fn missing_glue(glue: &str, commands: &[String]) -> String {
    let mut out = String::new();
    for command in commands {
        let def = format!("def {}(", mojo_ident(command));
        if !glue.lines().any(|l| l.starts_with(&def)) {
            out += &glue_stub_fn(command);
        }
    }
    if !out.is_empty() && !glue.lines().any(|l| l.trim() == "import original") {
        out = format!("\n\nimport original{out}");
    }
    out
}

/// Formats the front door's Mojo sources with `mojo format`, as `rustfmt` did for the Rust one.
/// Best effort: without Mojo the generated text stays as written.
pub(crate) fn mojo_format(app_dir: &Path, files: &[&str]) {
    mojo_format_in(app_dir, app_dir, files);
}

/// [`mojo_format`] with Mojo from the pixi project in `env_dir`.
pub(crate) fn mojo_format_in(app_dir: &Path, env_dir: &Path, files: &[&str]) {
    let Ok(mut cmd) = crate::mojo::command(env_dir) else {
        return;
    };
    cmd.current_dir(app_dir).arg("format").arg("--quiet");
    cmd.args(files.iter().filter(|f| app_dir.join(f).is_file()));
    let _ = crate::process::output(&mut cmd, crate::process::BUILD);
}

fn binary_name(app_dir: &Path) -> String {
    let state = std::fs::read_to_string(app_dir.join(STATE_FILE))
        .ok()
        .and_then(|text| serde_json::from_str::<serde_json::Value>(&text).ok());
    let name = state
        .as_ref()
        .and_then(|s| s["name"].as_str())
        .unwrap_or("app");
    package_name(name)
}

/// Builds `mojo/app/main.mojo` (warnings are errors) into `mojo/app/.mojo-anything/build`, with
/// the repository the original runs from built in; returns the binary.
pub(crate) fn mojo_build(app_dir: &Path) -> Result<PathBuf> {
    mojo_build_in(app_dir, app_dir)
}

/// [`mojo_build`] with Mojo from the pixi project in `env_dir` (a staged copy of the app has no
/// environment of its own). Each wired unit's port is imported as a package from
/// [`UNITS_BUILD_DIR`].
pub(crate) fn mojo_build_in(app_dir: &Path, env_dir: &Path) -> Result<PathBuf> {
    let app_dir = std::path::absolute(app_dir)?;
    let out_dir = app_dir.join(BUILD_DIR);
    std::fs::create_dir_all(&out_dir).with_context(|| format!("creating {}", out_dir.display()))?;
    let binary = out_dir.join(binary_name(&app_dir));
    let state_path = app_dir.join(STATE_FILE);
    let state: State = serde_json::from_str(
        &std::fs::read_to_string(&state_path)
            .with_context(|| format!("reading {}", state_path.display()))?,
    )
    .with_context(|| format!("parsing {}", state_path.display()))?;
    let packages = stage_packages(&app_dir, &state)?;
    let mut cmd = crate::mojo::command(env_dir)?;
    cmd.current_dir(&app_dir).args(["build", "--Werror"]);
    cmd.arg("-I").arg(&packages);
    if let Some(repo) = app_dir.parent().and_then(Path::parent)
        && let Ok(repo) = repo.canonical()
    {
        cmd.arg("-D")
            .arg(format!("{REPO_ENV}={}", repo.to_string_lossy()));
    }
    cmd.arg("main.mojo").arg("-o").arg(&binary);
    let out = crate::process::output(&mut cmd, crate::process::BUILD)?;
    if !out.success() {
        bail!(
            "mojo build in {} failed:\n{}{}",
            app_dir.display(),
            out.stdout_text(),
            out.stderr_text()
        );
    }
    Ok(binary)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::front_door::{AppKind, WiredUnit};

    fn state(units: Vec<WiredUnit>) -> State {
        State {
            schema: String::new(),
            name: "tcli".into(),
            commands: vec!["div".into(), "words".into()],
            units,
            lifted: false,
            kind: AppKind::Cli,
            routes: Vec::new(),
            api: Vec::new(),
        }
    }

    fn wordcount() -> WiredUnit {
        WiredUnit {
            name: "wordcount".into(),
            crate_name: "wordcount-mojo".into(),
            path: "../wordcount-mojo".into(),
            commands: vec!["words".into(), "len".into()],
            routes: Vec::new(),
            switch: "MOJO_ANYTHING_UNIT_WORDCOUNT".into(),
            unit: None,
            shadow: None,
            kept: Vec::new(),
        }
    }

    #[test]
    fn strings_and_names_are_valid_mojo() {
        assert_eq!(mojo_str("a \"b\" \\ c\n"), r#""a \"b\" \\ c\n""#);
        assert_eq!(mojo_ident("text-kit"), "text_kit");
        assert_eq!(mojo_ident("len"), "len_");
        assert_eq!(mojo_ident("case"), "case_");
        assert_eq!(mojo_ident("7zip"), "unit_7zip");
    }

    #[test]
    fn units_route_commands_behind_kill_switches() {
        let empty = units_mojo(&state(Vec::new()), false);
        assert!(empty.contains("    return None\n"), "{empty}");
        assert!(!empty.contains("import"), "{empty}");
        let code = units_mojo(&state(vec![wordcount()]), false);
        assert!(code.contains("from glue import wordcount\n"), "{code}");
        assert!(
            code.contains(
                "    if command == \"words\" and not _sent_to_original(\"WORDCOUNT\"):\n        return wordcount.words(args)\n"
            ),
            "{code}"
        );
        assert!(code.contains("return wordcount.len_(args)"), "{code}");
        let lifted = units_mojo(&state(vec![wordcount()]), true);
        assert!(!lifted.contains("MOJO_ANYTHING_UNIT"), "{lifted}");
        assert!(!lifted.contains("getenv"), "{lifted}");
    }

    #[test]
    fn main_routes_recorded_commands_and_options() {
        let mut flags: BTreeMap<String, BTreeMap<String, Flag>> = BTreeMap::new();
        flags.entry("div".into()).or_default().insert(
            "json".into(),
            Flag {
                long: Some("json".into()),
                short: None,
                takes_value: false,
            },
        );
        flags.entry("div".into()).or_default().insert(
            "short-v".into(),
            Flag {
                long: None,
                short: Some('v'),
                takes_value: false,
            },
        );
        let code = main_mojo(&state(Vec::new()), &flags);
        assert!(code.contains("return [\"div\", \"words\"]"), "{code}");
        assert!(
            code.contains("    if command == \"div\":\n        return [\"--json\", \"-v\"]\n"),
            "{code}"
        );
        assert!(code.contains("comptime ROOT = \"tcli\""), "{code}");
        assert!(code.contains("exit(original.run(args))"), "{code}");
    }

    #[test]
    fn original_fills_the_template() {
        let linux = os_constants("linux");
        let code = original_mojo(
            &["python3".into(), "tcli.py".into()],
            &["tcli.py".into()],
            false,
            &linux,
        );
        assert!(code.contains("return [\"python3\", \"tcli.py\"]"), "{code}");
        assert!(code.contains("return [\"tcli.py\"]"), "{code}");
        assert!(code.contains("comptime IN_ROOT = False"), "{code}");
        assert!(
            code.contains("comptime FALLBACK_LOG = \"MOJO_ANYTHING_FALLBACK_LOG\""),
            "{code}"
        );
        assert!(!code.contains("{{"), "{code}");
        assert!(!code.contains("#["), "{code}");
        assert!(original_mojo(&[], &[], true, &linux).contains("comptime IN_ROOT = True"));
        // Every external call carries its safety note in the comment block above it.
        let lines: Vec<&str> = code.lines().collect();
        for (i, line) in lines.iter().enumerate() {
            if line.contains("external_call[") {
                let above = lines[..i]
                    .iter()
                    .rev()
                    .take_while(|l| l.trim_start().starts_with('#'))
                    .any(|l| l.contains("# SAFETY:"));
                let same_block = lines[..i]
                    .iter()
                    .rev()
                    .take(3)
                    .any(|l| l.contains("# SAFETY:"));
                assert!(above || same_block, "line {}: {line}", i + 1);
            }
        }
    }

    #[test]
    fn unit_modules_are_imported_through_the_package() {
        let locals = vec!["json".to_string(), "pinned".to_string()];
        let text = "from json import JsonValue\nimport pinned\nimport pinned as p\n\
                    from std.os import abort\n    from json import x\nimport other\n";
        assert_eq!(
            package_source(text, "textops", &locals),
            "from textops.json import JsonValue\nimport textops.pinned as pinned\n\
             import textops.pinned as p\nfrom std.os import abort\n    \
             from textops.json import x\nimport other\n"
        );
        assert_eq!(port_package("text-kit"), "text_kit");
        assert_eq!(port_package("original"), "original_unit");
    }

    #[test]
    fn port_modules_follow_local_imports() {
        let dir = crate::app::temp_dir("port-modules").unwrap();
        std::fs::write(
            dir.join("port.mojo"),
            "from json import JsonValue\nimport std.os\n",
        )
        .unwrap();
        std::fs::write(dir.join("json.mojo"), "import pinned\n").unwrap();
        std::fs::write(dir.join("pinned.mojo"), "").unwrap();
        std::fs::write(dir.join("_native.mojo"), "from port import x\n").unwrap();
        assert_eq!(port_modules(&dir), ["json", "pinned"]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn glue_stubs_hand_commands_back() {
        let api = crate::codegen_mojo::parse_port_mojo(
            "def count_words(data: List[UInt8]) -> Int:\n    return 0\n\n\ndef _hidden() -> Int:\n    return 0\n",
        );
        let glue = glue_mojo(&wordcount(), &api);
        assert!(crate::front_door::is_stub(&glue), "{glue}");
        assert!(glue.contains("from wordcount import port"), "{glue}");
        assert!(
            glue.contains("#   port.count_words(data: List[UInt8]) -> Int"),
            "{glue}"
        );
        assert!(!glue.contains("_hidden"), "{glue}");
        assert!(
            glue.contains("def words(args: List[String]) raises -> Int:"),
            "{glue}"
        );
        assert!(
            glue.contains("def len_(args: List[String]) raises -> Int:"),
            "{glue}"
        );
        assert!(glue.contains("    return original.run(args)\n"), "{glue}");
        // Wiring more commands adds a stub only for the new ones.
        let filled = "from wordcount import port\n\n\ndef words(args: List[String]) raises -> Int:\n    return 0\n";
        let more = missing_glue(filled, &["words".into(), "upper".into()]);
        assert!(more.contains("import original"), "{more}");
        assert!(more.contains("def upper("), "{more}");
        assert!(!more.contains("def words("), "{more}");
        assert!(missing_glue(filled, &["words".into()]).is_empty());
    }

    #[test]
    fn pixi_toml_adds_json_once() {
        let dir = crate::app::temp_dir("pixi-json").unwrap();
        std::fs::write(dir.join("pixi.toml"), pixi_toml_app("tcli", false)).unwrap();
        add_json_dependency(&dir).unwrap();
        let once = std::fs::read_to_string(dir.join("pixi.toml")).unwrap();
        assert!(once.contains("emberjson"), "{once}");
        assert!(once.contains("pixi-build"), "{once}");
        add_json_dependency(&dir).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.join("pixi.toml")).unwrap(),
            once
        );
        std::fs::remove_dir_all(&dir).unwrap();
    }

    /// Review Focus 4: a front door generated for macOS uses the Darwin socket numbers, has no
    /// `prctl` or `/proc/self/exe`, and finds itself with `_NSGetExecutablePath`.
    #[test]
    fn front_door_constants_per_os() {
        let linux = os_constants("linux");
        let mac = os_constants("macos");
        assert_eq!((linux.sol_socket, linux.so_rcvtimeo), (1, 20));
        assert_eq!((mac.sol_socket, mac.so_rcvtimeo), (0xffff, 0x1006));
        assert_eq!((linux.timeval_size, mac.timeval_size), (16, 16));
        assert!(linux.has_pdeathsig && !mac.has_pdeathsig);
        assert_eq!(mac.exe_path, ExePath::NsGetExecutablePath);
        assert_eq!(os_constants("freebsd"), linux);
        let run = ["python3".to_string(), "s.py".to_string()];
        let files = ["s.py".to_string()];
        let sources = |os: &OsConstants| {
            [
                original_mojo(&run, &files, false, os),
                crate::front_door_http::original_mojo_http(&run, &files, &[], true, os),
                crate::front_door_http::http_mojo(os),
            ]
        };
        for code in sources(&mac) {
            for linux_only in [
                "\"prctl\"",
                "\"/proc/self/exe\"",
                "\"open64\"",
                "\"__errno_location\"",
                "\"sigtimedwait\"",
            ] {
                assert!(!code.contains(linux_only), "{linux_only} in\n{code}");
            }
            assert!(!code.contains("{{") && !code.contains("#["), "{code}");
        }
        let [cli, server, http] = sources(&mac);
        assert!(cli.contains("_NSGetExecutablePath") && server.contains("_NSGetExecutablePath"));
        assert!(cli.contains("is_macos()") && http.contains("is_macos()"));
        assert!(
            http.contains("comptime _SOL_SOCKET = Int32(65535)"),
            "{http}"
        );
        assert!(
            http.contains("comptime _SO_RCVTIMEO = Int32(4102)"),
            "{http}"
        );
        assert!(http.contains("comptime _MSG_NOSIGNAL = Int32(0)"), "{http}");
        assert!(http.contains("_SO_NOSIGPIPE"), "{http}");
        assert!(
            http.contains("a[unsafe_offset=0] = UInt8(16)"),
            "sin_len: {http}"
        );
        let [cli, server, http] = sources(&linux);
        assert!(cli.contains("prctl") && server.contains("prctl"));
        assert!(cli.contains("/proc/self/exe") && !cli.contains("_NSGetExecutablePath"));
        assert!(http.contains("comptime _SOL_SOCKET = Int32(1)"), "{http}");
        assert!(http.contains("comptime _SO_RCVTIMEO = Int32(20)"), "{http}");
        assert!(
            http.contains("comptime _MSG_NOSIGNAL = Int32(16384)"),
            "{http}"
        );
        assert!(!http.contains("_SO_NOSIGPIPE"), "{http}");
    }

    /// The child of `fork` runs only async-signal-safe calls on memory allocated before the
    /// fork: no `_cstr` (malloc) and no `perror` between `fork` and `_exit`.
    #[test]
    fn the_forked_child_allocates_nothing() {
        let run = ["sh".to_string()];
        for os in [os_constants("linux"), os_constants("macos")] {
            for code in [
                original_mojo(&run, &[], false, &os),
                crate::front_door_http::original_mojo_http(&run, &[], &[], false, &os),
            ] {
                let fork = code.find("external_call[\"fork\"").unwrap();
                let exit = fork + code[fork..].find("Int32(127)").unwrap();
                let child = &code[fork..exit];
                for unsafe_call in ["_cstr(", "perror", "malloc", "print("] {
                    assert!(!child.contains(unsafe_call), "{unsafe_call} in\n{child}");
                }
            }
        }
    }

    /// The text generated for each system builds with `--Werror` as far as an object file: the
    /// macOS calls are type-checked on Linux, not linked or run.
    #[test]
    fn front_doors_type_check_for_each_os() {
        if !crate::mojo::available() {
            return;
        }
        let env = Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut http_state = state(Vec::new());
        http_state.kind = AppKind::Http;
        for os in [os_constants("linux"), os_constants("macos")] {
            let run = ["sh".to_string(), "tool.sh".to_string()];
            let files = ["tool.sh".to_string()];
            let apps = [
                (
                    "cli",
                    vec![
                        ("main.mojo", main_mojo(&state(Vec::new()), &BTreeMap::new())),
                        ("original.mojo", original_mojo(&run, &files, false, &os)),
                        ("units.mojo", units_mojo(&state(Vec::new()), false)),
                    ],
                ),
                (
                    "server",
                    vec![
                        (
                            "main.mojo",
                            crate::front_door_http::main_mojo_http(&http_state, &[]),
                        ),
                        (
                            "original.mojo",
                            crate::front_door_http::original_mojo_http(
                                &run,
                                &files,
                                &[],
                                true,
                                &os,
                            ),
                        ),
                        (
                            "units.mojo",
                            crate::front_door_http::units_mojo_http(&http_state, false),
                        ),
                        ("http.mojo", crate::front_door_http::http_mojo(&os)),
                    ],
                ),
            ];
            for (kind, files) in apps {
                let dir = crate::app::temp_dir(&format!("typecheck-{}-{kind}", os.os)).unwrap();
                for (name, text) in &files {
                    std::fs::write(dir.join(name), text).unwrap();
                }
                let mut cmd = crate::mojo::command(env).unwrap();
                cmd.current_dir(&dir)
                    .args(["build", "--Werror", "--emit", "object", "main.mojo", "-o"])
                    .arg(dir.join("main.o"));
                let out = crate::process::output(&mut cmd, crate::process::BUILD).unwrap();
                assert!(
                    out.success(),
                    "{} {kind}:\n{}{}",
                    os.os,
                    out.stdout_text(),
                    out.stderr_text()
                );
                std::fs::remove_dir_all(&dir).unwrap();
            }
        }
    }

    #[test]
    fn pixi_toml_pins_the_mojo_version() {
        assert!(pixi_toml_app("tcli", true).contains("emberjson"));
        let toml = pixi_toml_app("tcli", false);
        assert!(toml.contains(&format!("mojo = \"=={}\"", crate::mojo::MOJO_VERSION)));
        assert!(toml.contains("name = \"tcli\""));
    }
}
