# `setup`: register mojo-anything with the coding agents on this machine
# (port of src/setup.rs). For each agent found (or named), the MCP server
# (`<this binary> mcp`) goes into the agent's own settings and, where the agent
# reads skills, the workflow skill into its skills folder. Existing settings
# are kept: only the `mojo-anything` entries are added or replaced, and a file
# that does not parse is left alone with an error. `--remove` takes them out.
#
# JSON settings are read and written with the JSON module (keys keep their
# order) in serde_json's pretty layout. Codex's TOML is checked with Python's
# `tomllib` and edited as text, the way toml_edit rewrites it: the rest of the
# file, comments included, stays as it was. A TOML shape this edit does not
# reproduce exactly (an inline or dotted `mojo-anything` entry, its own
# subtables, arrays of tables, multi-line strings) is handed to the Phase 1
# binary before anything is written (`codex_supported`).

from std.os import getenv
from std.os.path import isdir, isfile
from std.python import Python, PythonObject

from emberjson import Array, Object, Value
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback, own_binary
from mojo_anything.json import parse_json
from mojo_anything.json_text import json_equal, write_pretty, write_string
from mojo_anything.skill_files import skill_file_names, skill_file_text
from mojo_anything.toml_edit import CodexEdit, codex_edit
from mojo_anything.walk import canonical

comptime NAME = "mojo-anything"
comptime ALL = "claude,codex,cursor,gemini,opencode"

comptime _FILES = """
import os, shutil, stat, tomllib

def _err(context, e):
    if isinstance(e, OSError) and e.errno:
        return "%s: %s (os error %d)" % (context, e.strerror, e.errno)
    return "%s: %s" % (context, e)

def read_optional(path):
    try:
        with open(path, "rb") as f:
            data = f.read()
    except FileNotFoundError:
        return ("none", "")
    except OSError as e:
        return ("err", _err("reading " + path, e))
    try:
        return ("ok", data.decode("utf-8"))
    except UnicodeDecodeError:
        return ("err", "reading %s: stream did not contain valid UTF-8" % path)

def read_or_none(path):
    try:
        with open(path, "rb") as f:
            return ("ok", f.read().decode("utf-8"))
    except (OSError, UnicodeDecodeError):
        return ("none", "")

def write_file(path, text):
    try:
        real = os.path.realpath(path, strict=True)
    except OSError:
        real = path
    parent = os.path.dirname(real)
    if parent:
        try:
            os.makedirs(parent, exist_ok=True)
        except OSError as e:
            return _err("creating " + parent, e)
    name = os.path.basename(real)
    dot = name.rfind(".")
    stem = name[:dot] if dot > 0 else name
    tmp = os.path.join(parent, stem + ".mojo-anything.tmp")
    try:
        with open(tmp, "wb") as f:
            try:
                os.chmod(tmp, stat.S_IMODE(os.stat(real).st_mode))
            except FileNotFoundError:
                pass
            f.write(text.encode("utf-8"))
    except OSError as e:
        return _err("writing " + tmp, e)
    try:
        os.replace(tmp, real)
    except OSError as e:
        return _err("replacing " + real, e)
    return ""

def backup(path):
    if not os.path.isfile(path):
        return ("none", "")
    copy = path + ".mojo-anything.bak"
    try:
        shutil.copy(path, copy)
    except OSError as e:
        return ("err", _err("backing up " + path, e))
    return ("ok", copy)

def remove_file(path):
    try:
        os.remove(path)
    except OSError as e:
        return _err("removing " + path, e)
    return ""

def remove_dir(path):
    try:
        os.rmdir(path)
    except OSError:
        pass

def codex_probe(text, command, name):
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        return ("invalid", str(e), False, False)
    servers = data.get("mcp_servers")
    if servers is None:
        return ("absent", "", False, False)
    if not isinstance(servers, dict):
        return ("not-table", "", False, False)
    if name not in servers:
        return ("table", "", False, False)
    e = servers[name]
    same = (isinstance(e, dict) and e.get("command") == command
            and "url" not in e and e.get("args") == ["mcp"])
    return ("table", "", True, same)
"""


@fieldwise_init
struct Agent(Copyable, Movable):
    var id: String
    """`claude`, as `--agent` and the JSON report name it."""
    var name: String
    var folder: String
    var command: String
    var config: String
    var skills: String
    """The skill folder under the home directory, or "" for none."""


def agent(id: String) raises -> Agent:
    if id == "claude":
        return Agent(
            id,
            "Claude Code",
            ".claude",
            "claude",
            ".claude.json",
            ".claude/skills",
        )
    if id == "codex":
        return Agent(
            id,
            "Codex",
            ".codex",
            "codex",
            ".codex/config.toml",
            ".codex/skills",
        )
    if id == "cursor":
        return Agent(id, "Cursor", ".cursor", "cursor", ".cursor/mcp.json", "")
    if id == "gemini":
        return Agent(
            id, "Gemini CLI", ".gemini", "gemini", ".gemini/settings.json", ""
        )
    if id == "opencode":
        return Agent(
            id,
            "OpenCode",
            ".config/opencode",
            "opencode",
            ".config/opencode/opencode.json",
            ".config/opencode/skills",
        )
    raise Error("unknown agent " + id)


def join(dir: String, name: String) -> String:
    """`Path::join`: `dir/name`, without a second slash."""
    if dir == "":
        return name
    if dir.endswith("/"):
        return dir + name
    return dir + "/" + name


def on_path(command: String) -> Bool:
    """Whether `command` (or `command.exe`, `command.cmd`) is a file in a
    folder of PATH."""
    var paths = getenv("PATH")
    if paths.byte_length() == 0:
        return False
    for dir in paths.split(":"):
        var file = join(String(dir), command)
        if isfile(file) or isfile(file + ".exe") or isfile(file + ".cmd"):
            return True
    return False


def present(a: Agent, home: String) -> Bool:
    return isdir(join(home, a.folder)) or on_path(a.command)


@fieldwise_init
struct Change(Copyable, Movable):
    var agent: String
    var file: String
    var action: String
    """`added`, `updated`, `unchanged`, `removed` or `absent`."""
    var backup: String
    """The copy of the file as it was, or ""."""


struct Options(Copyable, Movable):
    var home: String
    var agents: List[String]
    """Agent ids; empty means every agent found."""
    var command: String
    var remove: Bool
    var dry_run: Bool
    var backup: Bool

    def __init__(out self, home: String, command: String):
        self.home = home
        self.agents = List[String]()
        self.command = command
        self.remove = False
        self.dry_run = False
        self.backup = True


struct Report(Copyable, Movable):
    var command: String
    var agents: List[String]
    var changes: List[Change]
    var dry_run: Bool

    def __init__(out self, command: String, dry_run: Bool):
        self.command = command
        self.agents = List[String]()
        self.changes = List[Change]()
        self.dry_run = dry_run


def _files() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(_FILES, scope)
    return scope


def home() raises -> String:
    """`HOME`, or `USERPROFILE`."""
    var h = getenv("HOME")
    if h.byte_length() > 0:
        return h
    var p = getenv("USERPROFILE")
    if p.byte_length() > 0:
        return p
    raise Error("no home directory (HOME is not set)")


def chosen(opts: Options) -> List[String]:
    """The agents to set up: those named, or every agent found."""
    if len(opts.agents) > 0:
        return opts.agents.copy()
    var out = List[String]()
    for id in ALL.split(","):
        try:
            if present(agent(String(id)), opts.home):
                out.append(String(id))
        except:
            pass
    return out^


def _read(f: PythonObject, path: String) raises -> Optional[String]:
    var r = f["read_optional"](path)
    var kind = String(py=r[0])
    if kind == "err":
        raise Error(String(py=r[1]))
    if kind == "none":
        return None
    return String(py=r[1])


def _save(
    f: PythonObject, path: String, text: String, opts: Options
) raises -> String:
    """Backs up (when asked) and writes `path`; returns the backup's path."""
    var saved = String("")
    if opts.backup:
        var b = f["backup"](path)
        var kind = String(py=b[0])
        if kind == "err":
            raise Error(String(py=b[1]))
        if kind == "ok":
            saved = String(py=b[1])
    var err = String(py=f["write_file"](path, text))
    if err != "":
        raise Error(err)
    return saved


def _json_doc(text: Optional[String], path: String) raises -> Value:
    if not text or String(text.value().strip()) == "":
        return Value(Object())
    try:
        return parse_json(String(text.value().strip()))
    except e:
        raise Error(
            path
            + " is not valid JSON; fix it or add the server by hand: "
            + String(e)
        )


def _mcp_args() -> Value:
    var args = Array()
    args.append(Value(String("mcp")))
    return Value(args^)


def _claude_like(
    mut servers: Object, command: String, remove: Bool, stdio_type: Bool
) raises -> String:
    """`mcpServers.mojo-anything` for Claude Code, Cursor and Gemini CLI."""
    if remove:
        if NAME in servers:
            servers.pop(NAME)
            return "removed"
        return "absent"
    var had = NAME in servers
    var entry = Object()
    var old = Value(Object())
    if had:
        old = servers[NAME].copy()
        if old.is_object():
            entry = old.object().copy()
    entry["command"] = Value(command)
    entry["args"] = _mcp_args()
    if stdio_type or "type" in entry:
        entry["type"] = Value(String("stdio"))
    if stdio_type and "env" not in entry:
        entry["env"] = Value(Object())
    if "url" in entry:
        entry.pop("url")
    var new = Value(entry^)
    if had and json_equal(old, new):
        return "unchanged"
    servers[NAME] = new^
    return "updated" if had else "added"


def _opencode_entry(
    mut servers: Object, command: String, remove: Bool
) raises -> String:
    """A local server whose `command` is the whole argv."""
    if remove:
        if NAME in servers:
            servers.pop(NAME)
            return "removed"
        return "absent"
    var had = NAME in servers
    var entry = Object()
    var old = Value(Object())
    if had:
        old = servers[NAME].copy()
        if old.is_object():
            entry = old.object().copy()
    entry["type"] = Value(String("local"))
    var argv = Array()
    argv.append(Value(command))
    argv.append(Value(String("mcp")))
    entry["command"] = Value(argv^)
    # OpenCode keeps a server out of the way with `disabled`, and older files
    # wrote the opposite `enabled`: setting one up means neither key.
    if "disabled" in entry:
        entry.pop("disabled")
    if "enabled" in entry:
        entry.pop("enabled")
    if "url" in entry:
        entry.pop("url")
    var new = Value(entry^)
    if had and json_equal(old, new):
        return "unchanged"
    servers[NAME] = new^
    return "updated" if had else "added"


def _writes(action: String) -> Bool:
    return action == "added" or action == "updated" or action == "removed"


def json_server(
    f: PythonObject, a: Agent, path: String, opts: Options
) raises -> Change:
    var doc = _json_doc(_read(f, path), path)
    if not doc.is_object():
        raise Error(path + " is not a JSON object; add the server by hand")
    ref root = doc.object()
    var action: String
    if a.id == "opencode":
        if "mcp" not in root:
            root["mcp"] = Value(Object())
        ref mcp_v = root["mcp"]
        if not mcp_v.is_object():
            raise Error(
                "`mcp` in " + path + " is not an object; add the server by hand"
            )
        ref mcp = mcp_v.object()
        # Current OpenCode keeps servers under `mcp.servers`; a `mcp` object
        # that already lists servers by name (the older shape) is kept as it
        # is, so the two shapes never end up mixed in one file.
        var nested = len(mcp) == 0
        if "servers" in mcp and mcp["servers"].is_object():
            nested = True
        if nested:
            if "servers" not in mcp:
                mcp["servers"] = Value(Object())
            ref sv = mcp["servers"]
            if not sv.is_object():
                raise Error(
                    "`mcp.servers` in "
                    + path
                    + " is not an object; add the server by hand"
                )
            action = _opencode_entry(sv.object(), opts.command, opts.remove)
        else:
            action = _opencode_entry(mcp, opts.command, opts.remove)
    else:
        if "mcpServers" not in root:
            root["mcpServers"] = Value(Object())
        ref sv = root["mcpServers"]
        if not sv.is_object():
            raise Error(
                "`mcpServers` in "
                + path
                + " is not an object; add the server by hand"
            )
        action = _claude_like(
            sv.object(), opts.command, opts.remove, a.id == "claude"
        )
    var saved = String("")
    if not opts.dry_run and _writes(action):
        saved = _save(f, path, write_pretty(doc) + "\n", opts)
    return Change(a.id, path, action, saved)


def _codex(f: PythonObject, path: String, opts: Options) raises -> CodexEdit:
    """The action for Codex's settings and the edit that makes it."""
    var text = _read(f, path)
    var body = text.value() if text else String("")
    var probe = f["codex_probe"](
        PythonObject(body), PythonObject(opts.command), PythonObject(NAME)
    )
    var kind = String(py=probe[0])
    if kind == "invalid":
        raise Error(
            path
            + " is not valid TOML; fix it or add the server by hand: "
            + String(py=probe[1])
        )
    if kind == "not-table":
        raise Error("`mcp_servers` in " + path + " is not a table")
    var had = Int(py=probe[2]) != 0
    var same = Int(py=probe[3]) != 0
    var action: String
    if opts.remove:
        action = "removed" if had else "absent"
    elif same:
        action = "unchanged"
    else:
        action = "updated" if had else "added"
    var edit = codex_edit(body, opts.command, action)
    if edit.inline_servers:
        raise Error("`mcp_servers` in " + path + " is not a table")
    edit.action = action
    return edit^


def handled_in_mojo(opts: Options) -> Bool:
    """Whether every settings file reads, parses and (Codex's) is a shape the
    text edit reproduces. When not, the whole command goes to the Phase 1
    binary before anything is written, so a file that does not parse gets
    serde_json's or toml_edit's own message."""
    try:
        var f = _files()
        for id in chosen(opts):
            var a = agent(id)
            var path = join(opts.home, a.config)
            if id == "codex":
                if not _codex(f, path, opts).supported:
                    return False
            else:
                _ = _json_doc(_read(f, path), path)
    except:
        return False
    return True


def codex_server(
    f: PythonObject, a: Agent, path: String, opts: Options
) raises -> Change:
    var edit = _codex(f, path, opts)
    if not edit.supported:
        raise Error(
            "the TOML in " + path + " needs the Phase 1 binary to be edited"
        )
    var saved = String("")
    if not opts.dry_run and _writes(edit.action):
        saved = _save(f, path, edit.text, opts)
    return Change(a.id, path, edit.action, saved)


def skill(
    f: PythonObject, a: Agent, dir: String, opts: Options
) raises -> Change:
    var names = skill_file_names()
    var have = List[Optional[String]]()
    for name in names:
        var r = f["read_or_none"](join(dir, name))
        if String(py=r[0]) == "ok":
            have.append(String(py=r[1]))
        else:
            have.append(None)
    var any = False
    var all_same = True
    for i in range(len(names)):
        if have[i]:
            any = True
            if have[i].value() != skill_file_text(names[i]):
                all_same = False
        else:
            all_same = False
    var action: String
    if opts.remove:
        action = "removed" if any else "absent"
    elif not any:
        action = "added"
    elif all_same:
        action = "unchanged"
    else:
        action = "updated"
    if not opts.dry_run:
        for name in names:
            var path = join(dir, name)
            if action == "added" or action == "updated":
                var err = String(
                    py=f["write_file"](path, skill_file_text(name))
                )
                if err != "":
                    raise Error(err)
            elif action == "removed" and isfile(path):
                var err = String(py=f["remove_file"](path))
                if err != "":
                    raise Error(err)
        if action == "removed":
            # The folder is ours; leave it only if someone put other files in.
            _ = f["remove_dir"](dir)
    return Change(a.id, join(dir, "SKILL.md"), action, "")


def setup(opts: Options) raises -> Report:
    var agents = chosen(opts)
    if len(agents) == 0:
        raise Error(
            "no coding agent found (looked for ~/.claude, ~/.codex, ~/.cursor,"
            " ~/.gemini, ~/.config/opencode and their commands); name one with"
            " --agent claude|codex|cursor|gemini|opencode"
        )
    var f = _files()
    var report = Report(opts.command, opts.dry_run)
    report.agents = agents.copy()
    for id in agents:
        var a = agent(id)
        var config = join(opts.home, a.config)
        if a.id == "codex":
            report.changes.append(codex_server(f, a, config, opts))
        else:
            report.changes.append(json_server(f, a, config, opts))
        if a.skills != "":
            report.changes.append(
                skill(f, a, join(join(opts.home, a.skills), NAME), opts)
            )
    return report^


def _pad(s: String, width: Int) -> String:
    var out = s
    for _ in range(width - len(s.codepoints())):
        out += " "
    return out


def text(r: Report) -> String:
    """The report for people."""
    var verb = "Would set up" if r.dry_run else "Set up"
    var out = String(verb) + " mojo-anything for "
    for i in range(len(r.agents)):
        if i > 0:
            out += ", "
        try:
            out += agent(r.agents[i]).name
        except:
            pass
    out += "\n"
    var any_kept = False
    for c in r.changes:
        var name = String("")
        try:
            name = agent(c.agent).name
        except:
            pass
        out += "  " + _pad(name, 10) + " " + _pad(c.action, 9) + " " + c.file
        out += "\n"
        if c.backup != "":
            out += "  " + _pad("", 10) + " " + _pad("backup", 9) + " "
            out += c.backup + "\n"
        if c.action != "removed" and c.action != "absent":
            any_kept = True
    if not r.dry_run and any_kept:
        out += (
            "\nThe agents run `"
            + r.command
            + " mcp`. Restart them, then ask, for example:\n "
            + " \"Profile this repo's slowest workflow with mojo-anything and"
            + ' move the hot loop to Mojo."\n'
        )
    return out


def report_json(r: Report) -> String:
    """`serde_json::to_string_pretty` of the Rust `Report`."""
    var out = String('{\n  "command": ') + write_string(r.command) + ",\n"
    out += '  "agents": ['
    if len(r.agents) == 0:
        out += "]"
    else:
        out += "\n"
        for i in range(len(r.agents)):
            out += "    " + write_string(r.agents[i])
            out += ",\n" if i + 1 < len(r.agents) else "\n"
        out += "  ]"
    out += ',\n  "changes": ['
    if len(r.changes) == 0:
        out += "]"
    else:
        out += "\n"
        for i in range(len(r.changes)):
            ref c = r.changes[i]
            out += '    {\n      "agent": ' + write_string(c.agent) + ",\n"
            out += '      "file": ' + write_string(c.file) + ",\n"
            out += '      "action": ' + write_string(c.action)
            if c.backup != "":
                out += ',\n      "backup": ' + write_string(c.backup)
            out += "\n    }"
            out += ",\n" if i + 1 < len(r.changes) else "\n"
        out += "  ]"
    out += ',\n  "dry_run": ' + ("true" if r.dry_run else "false") + "\n}"
    return out


def run_setup(p: Parsed, argv: List[String]) raises -> Int:
    """`mojo-anything setup`, with the Mojo binary as the command the agents
    run."""
    var opts = Options(home(), canonical(own_binary()))
    opts.agents = p.all("agent")
    opts.remove = p.flag("remove")
    opts.dry_run = p.flag("dry-run")
    opts.backup = not p.flag("no-backup")
    if not handled_in_mojo(opts):
        return fallback(argv)
    var r = setup(opts)
    if p.flag("json"):
        print(report_json(r))
    else:
        print(text(r), end="")
    return 0
