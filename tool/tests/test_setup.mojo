# `setup` in Mojo: the tests of src/setup.rs, ported by name, and the files it
# writes compared byte for byte with what the Phase 1 binary writes from the
# same settings files (tool/fallback/mojo-anything, the recording's source).

from std.os.path import exists, isdir, isfile
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_false, assert_true

from mojo_anything.json import parse_json
from mojo_anything.process import Command, capture
from mojo_anything.setup import (
    NAME,
    Options,
    handled_in_mojo,
    present,
    agent,
    setup,
    text,
)
from mojo_anything.skill_files import skill_file_text
from mojo_anything.toml_edit import codex_edit
from mojo_anything.walk import canonical

comptime FALLBACK = "tool/fallback/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, stat, tempfile

def temp_home(name):
    d = os.path.join(tempfile.gettempdir(), "mojo-anything-setup-%s-%d" % (name, os.getpid()))
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    return d

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)

def get(path):
    with open(path) as f:
        return f.read()

def gone(path):
    shutil.rmtree(path, ignore_errors=True)

def link(target, path):
    os.symlink(target, path)

def chmod(path, mode):
    os.chmod(path, mode)

def mode(path):
    return stat.S_IMODE(os.stat(path).st_mode)

def is_link(path):
    return os.path.islink(path)
""",
        scope,
    )
    return scope


def _home(py: PythonObject, name: String) raises -> String:
    return String(py=py["temp_home"](PythonObject(name)))


def _put(py: PythonObject, path: String, text: String) raises:
    _ = py["put"](PythonObject(path), PythonObject(text))


def _get(py: PythonObject, path: String) raises -> String:
    return String(py=py["get"](PythonObject(path)))


def _gone(py: PythonObject, path: String) raises:
    _ = py["gone"](PythonObject(path))


def _opts(home: String, *agents: String) -> Options:
    var o = Options(home, "/opt/bin/mojo-anything")
    for a in agents:
        o.agents.append(String(a))
    return o^


def _actions(r: List[String]) -> String:
    var out = String("")
    for a in r:
        out += a + " "
    return out


def test_no_backup_changes_the_file_without_a_copy() raises:
    var py = _py()
    var home = _home(py, "no-backup")
    var cursor = home + "/.cursor/mcp.json"
    _put(py, cursor, '{"mcpServers":{"other":{"command":"x"}}}')
    var copy = home + "/.cursor/mcp.json.mojo-anything.bak"
    var options = _opts(home, "cursor")
    options.backup = False
    var r = setup(options)
    assert_equal(r.changes[0].action, "added")
    assert_equal(r.changes[0].backup, "")
    assert_false(exists(copy))
    assert_true("mojo-anything" in _get(py, cursor))
    options.remove = True
    options.backup = True
    var again = setup(options)
    assert_equal(again.changes[0].backup, copy)
    assert_true(exists(copy))
    _gone(py, home)


def test_adds_keeps_and_removes_entries() raises:
    var py = _py()
    var home = _home(py, "all")
    _put(
        py,
        home + "/.claude.json",
        '{"zeta": 1, "mcpServers": {"other": {"command": "x"}}, "alpha": true}',
    )
    _put(
        py,
        home + "/.codex/config.toml",
        'model = "o4"\n\n[mcp_servers.other]\ncommand = "x"\n',
    )
    var all = _opts(home, "claude", "codex", "cursor", "gemini", "opencode")
    var r = setup(all)
    for c in r.changes:
        assert_equal(c.action, "added", c.file)
    var claude = parse_json(_get(py, home + "/.claude.json"))
    assert_equal(
        String(claude.object()["mcpServers"].object()[NAME].object()["args"]),
        '["mcp"]',
    )
    assert_equal(
        claude.object()["mcpServers"]
        .object()["other"]
        .object()["command"]
        .string(),
        "x",
    )
    # The existing file was copied before the change; new files need no copy.
    assert_true(r.changes[0].backup != "")
    assert_true(_get(py, r.changes[0].backup).startswith('{"zeta": 1'))
    var some_without = False
    for c in r.changes:
        if c.backup == "":
            some_without = True
    assert_true(some_without)
    var keys = String("")
    for k in claude.object().keys():
        keys += k + ","
    assert_equal(keys, "zeta,mcpServers,alpha,", "key order kept")
    var codex = _get(py, home + "/.codex/config.toml")
    assert_true(codex.startswith('model = "o4"'), codex)
    assert_true(
        '[mcp_servers.mojo-anything]\ncommand = "/opt/bin/mojo-anything"\nargs'
        ' = ["mcp"]'
        in codex,
        codex,
    )
    assert_true("[mcp_servers.other]" in codex)
    assert_equal(
        _get(py, home + "/.claude/skills/mojo-anything/SKILL.md"),
        skill_file_text("SKILL.md"),
    )
    assert_true(exists(home + "/.codex/skills/mojo-anything/whole-app.md"))
    var cursor = parse_json(_get(py, home + "/.cursor/mcp.json"))
    assert_equal(
        cursor.object()["mcpServers"]
        .object()[NAME]
        .object()["command"]
        .string(),
        "/opt/bin/mojo-anything",
    )
    assert_true(exists(home + "/.gemini/settings.json"))
    # Running again changes nothing.
    var again = setup(all)
    for c in again.changes:
        assert_equal(c.action, "unchanged", c.file)
    # A moved binary updates the entries.
    var moved = _opts(home, "codex")
    moved.command = "/usr/local/bin/mojo-anything"
    assert_equal(setup(moved).changes[0].action, "updated")
    # Remove takes out only our entries.
    var remove = all.copy()
    remove.remove = True
    _ = setup(remove)
    claude = parse_json(_get(py, home + "/.claude.json"))
    assert_false(NAME in claude.object()["mcpServers"].object())
    assert_equal(
        claude.object()["mcpServers"]
        .object()["other"]
        .object()["command"]
        .string(),
        "x",
    )
    assert_false(exists(home + "/.claude/skills/mojo-anything"))
    codex = _get(py, home + "/.codex/config.toml")
    assert_true(
        "mojo-anything" not in codex and "[mcp_servers.other]" in codex, codex
    )
    _gone(py, home)


def test_reinstall_preserves_custom_options_for_the_same_server() raises:
    var py = _py()
    var home = _home(py, "custom-entry")
    _put(
        py,
        home + "/.cursor/mcp.json",
        '{"mcpServers":{"mojo-anything":{"command":"old","args":["mcp"],"env":{"MODE":"custom"}}}}',
    )
    _put(
        py,
        home + "/.codex/config.toml",
        (
            '[mcp_servers.mojo-anything]\ncommand = "old"\nargs ='
            ' ["mcp"]\ntool_timeout_sec = 120\n'
        ),
    )
    var options = _opts(home, "cursor", "codex")
    _ = setup(options)
    var cursor = parse_json(_get(py, home + "/.cursor/mcp.json"))
    var codex = _get(py, home + "/.codex/config.toml")
    var again = setup(options)
    _gone(py, home)
    ref entry = cursor.object()["mcpServers"].object()[NAME].object()
    assert_equal(entry["env"].object()["MODE"].string(), "custom")
    assert_equal(entry["command"].string(), "/opt/bin/mojo-anything")
    assert_true("tool_timeout_sec = 120" in codex, codex)
    for c in again.changes:
        assert_equal(c.action, "unchanged", c.file)


def test_reinstall_keeps_an_inline_codex_entry() raises:
    # An inline entry is a shape the text edit does not reproduce: the Phase
    # 1 binary edits it (its test, in src/setup.rs, checks the result).
    var py = _py()
    var home = _home(py, "codex-inline")
    _put(
        py,
        home + "/.codex/config.toml",
        (
            '[mcp_servers]\nmojo-anything = { command = "old", args = ["mcp"],'
            ' env = { MODE = "custom" } }\n'
        ),
    )
    assert_false(handled_in_mojo(_opts(home, "codex")))
    _gone(py, home)


def test_opencode_gets_a_local_server_and_the_skill() raises:
    var py = _py()
    var home = _home(py, "opencode")
    var config = home + "/.config/opencode/opencode.json"
    _put(
        py,
        config,
        '{"$schema":"https://opencode.ai/config.json","mcp":{"servers":{"other":{"type":"local","command":["x"]}}},"model":"a/b"}',
    )
    var options = _opts(home, "opencode")
    _ = setup(options)
    var doc = parse_json(_get(py, config))
    ref entry = doc.object()["mcp"].object()["servers"].object()[NAME].object()
    assert_equal(entry["type"].string(), "local")
    assert_equal(String(entry["command"]), '["/opt/bin/mojo-anything","mcp"]')
    assert_false("disabled" in entry)
    var keys = String("")
    for k in doc.object().keys():
        keys += k + ","
    assert_equal(keys, "$schema,mcp,model,", "key order kept")
    assert_equal(
        _get(py, home + "/.config/opencode/skills/mojo-anything/SKILL.md"),
        skill_file_text("SKILL.md"),
    )
    for c in setup(options).changes:
        assert_equal(c.action, "unchanged", c.file)
    # A disabled server is turned back on.
    var text_now = _get(py, config)
    _put(
        py,
        config,
        text_now.replace(
            '"mojo-anything": {\n        "type": "local",',
            '"mojo-anything": {"disabled": true, "type": "local",',
        ),
    )
    assert_equal(setup(options).changes[0].action, "updated")
    var turned_on = parse_json(_get(py, config))
    assert_false(
        "disabled"
        in turned_on.object()["mcp"].object()["servers"].object()[NAME].object()
    )
    # A moved binary updates the entry.
    options.command = "/usr/local/bin/mojo-anything"
    assert_equal(setup(options).changes[0].action, "updated")
    # Remove takes out only ours.
    options.remove = True
    _ = setup(options)
    doc = parse_json(_get(py, config))
    assert_false(NAME in doc.object()["mcp"].object()["servers"].object())
    assert_false(exists(home + "/.config/opencode/skills/mojo-anything"))
    # A file that lists servers in `mcp` by name keeps that shape.
    var flat = _home(py, "opencode-flat")
    var flat_config = flat + "/.config/opencode/opencode.json"
    _put(
        py,
        flat_config,
        '{"mcp":{"other":{"type":"local","command":["x"]},"mojo-anything":{"type":"local","command":["/old/mojo-anything","mcp"],"enabled":true}}}',
    )
    _ = setup(_opts(flat, "opencode"))
    var fdoc = parse_json(_get(py, flat_config))
    ref fentry = fdoc.object()["mcp"].object()[NAME].object()
    assert_equal(String(fentry["command"]), '["/opt/bin/mojo-anything","mcp"]')
    assert_false("enabled" in fentry)
    assert_false("servers" in fdoc.object()["mcp"].object())
    _gone(py, flat)
    # A file that does not parse goes to the Phase 1 binary, untouched.
    _put(py, config, "{ not json")
    assert_false(handled_in_mojo(_opts(home, "opencode")))
    var raised = False
    try:
        _ = setup(_opts(home, "opencode"))
    except e:
        raised = "not valid JSON" in String(e)
    assert_true(raised)
    assert_equal(_get(py, config), "{ not json")
    _gone(py, home)


def test_setup_keeps_rust_anything_entry() raises:
    var py = _py()
    var home = _home(py, "rust-anything")
    var claude = home + "/.claude.json"
    var rust_entry = (
        '{\n      "type": "stdio",\n      "command":'
        ' "/opt/bin/rust-anything",\n      "args": [\n        "mcp"\n      ],\n'
        '      "env": {}\n    }'
    )
    _put(
        py,
        claude,
        '{\n  "mcpServers": {\n    "rust-anything": ' + rust_entry + "\n  }\n}",
    )
    var codex_rust = (
        '[mcp_servers.rust-anything]\ncommand = "/opt/bin/rust-anything"\nargs'
        ' = ["mcp"]\n'
    )
    _put(py, home + "/.codex/config.toml", codex_rust)
    var rust_skill = home + "/.claude/skills/rust-anything/SKILL.md"
    _put(py, rust_skill, "---\nname: rust-anything\n---\n")
    var options = _opts(home, "claude", "codex")
    var said = text(setup(options))
    assert_true("Mojo" in said, said)
    assert_false("Rust" in said, said)
    assert_true(rust_entry in _get(py, claude))
    var toml = _get(py, home + "/.codex/config.toml")
    assert_true(toml.startswith(codex_rust), toml)
    assert_true("[mcp_servers.mojo-anything]" in toml, toml)
    options.remove = True
    _ = setup(options)
    assert_equal(
        _get(py, claude),
        '{\n  "mcpServers": {\n    "rust-anything": '
        + rust_entry
        + "\n  }\n}\n",
    )
    assert_equal(_get(py, home + "/.codex/config.toml"), codex_rust)
    assert_equal(_get(py, rust_skill), "---\nname: rust-anything\n---\n")
    assert_false(exists(home + "/.claude/skills/" + NAME))
    _gone(py, home)


def test_keeps_a_symlinked_settings_file_and_its_permissions() raises:
    var py = _py()
    var home = _home(py, "link")
    var real = home + "/dotfiles/claude.json"
    _put(py, real, '{"token": "secret"}')
    _ = py["chmod"](PythonObject(real), PythonObject(0o600))
    _ = py["link"](PythonObject(real), PythonObject(home + "/.claude.json"))
    _ = setup(_opts(home, "claude"))
    assert_true(Bool(py=py["is_link"](PythonObject(home + "/.claude.json"))))
    assert_true("mojo-anything" in _get(py, real))
    assert_equal(Int(py=py["mode"](PythonObject(real))), 0o600)
    _gone(py, home)


def test_finds_agents_and_never_breaks_a_bad_file() raises:
    var py = _py()
    var home = _home(py, "detect")
    _put(py, home + "/.cursor/mcp.json", "{ not json")
    assert_true(present(agent("cursor"), home))
    var raised = False
    try:
        _ = setup(_opts(home, "cursor"))
    except e:
        raised = "not valid JSON" in String(e)
    assert_true(raised)
    assert_equal(_get(py, home + "/.cursor/mcp.json"), "{ not json")
    # A dry run writes nothing.
    var dry = _opts(home, "gemini")
    dry.dry_run = True
    assert_equal(setup(dry).changes[0].action, "added")
    assert_false(exists(home + "/.gemini"))
    _gone(py, home)


def _phase1(py: PythonObject, home: String, *args: String) raises -> String:
    var cmd = Command(FALLBACK)
    cmd.args.append("setup")
    for a in args:
        cmd.args.append(String(a))
    cmd.env["HOME"] = home
    var out = capture(cmd, 60.0)
    if not out.success:
        raise Error("the Phase 1 binary failed: " + out.stderr_text())
    return out.stdout_text()


def _same_as_phase1(
    py: PythonObject,
    agent_id: String,
    file: String,
    before: String,
    *flags: String,
) raises:
    """Both binaries start from `before` in `file`; their files must match."""
    var command = canonical(FALLBACK)
    var a = _home(py, "diff-a")
    var b = _home(py, "diff-b")
    if before != "<none>":
        _put(py, a + "/" + file, before)
        _put(py, b + "/" + file, before)
    var opts = Options(a, command)
    opts.agents.append(agent_id)
    opts.backup = False
    var args = List[String]()
    args.append("--agent")
    args.append(agent_id)
    args.append("--no-backup")
    for f in flags:
        if f == "--remove":
            opts.remove = True
        args.append(String(f))
    assert_true(handled_in_mojo(opts), before)
    _ = setup(opts)
    var cmd = Command(FALLBACK)
    cmd.args.append("setup")
    for x in args:
        cmd.args.append(x)
    cmd.env["HOME"] = b
    var out = capture(cmd, 60.0)
    assert_true(out.success, out.stderr_text())
    var mine = _get(py, a + "/" + file) if exists(a + "/" + file) else "<none>"
    var theirs = _get(py, b + "/" + file) if exists(
        b + "/" + file
    ) else "<none>"
    _gone(py, a)
    _gone(py, b)
    assert_equal(mine, theirs, before)


def test_codex_text_matches_toml_edit() raises:
    var py = _py()
    var f = ".codex/config.toml"
    var inputs = List[String]()
    inputs.append("<none>")
    inputs.append("")
    inputs.append('model = "o4"\n')
    inputs.append('model = "o4"')
    inputs.append("# only a comment\n")
    inputs.append(
        '# my settings\nmodel = "o3"  # keep'
        ' this\n\n[mcp_servers.other]\ncommand = "other"\n'
    )
    inputs.append(
        '[mcp_servers.other]\ncommand = "x"\n\n# about'
        ' profiles\n[profiles.fast]\nmodel = "o4"\n'
    )
    inputs.append(
        '[mcp_servers.b]\ncommand = "b"\n[other]\nx ='
        ' 1\n[mcp_servers.a]\ncommand = "a"\n'
    )
    inputs.append(
        '[projects."/home/me/repo"]\ntrust_level ='
        ' "trusted"\n\n[mcp_servers.other]\ncommand = "x"\nargs = [\n  "a",\n '
        ' "b",\n]\n'
    )
    inputs.append('[mcp_servers]\nother = { command = "x" }\n')
    inputs.append(
        '[mcp_servers.mojo-anything]\ncommand = "old"\nargs ='
        ' ["mcp"]\ntool_timeout_sec = 120\n'
    )
    inputs.append(
        '# head\n\n[mcp_servers.mojo-anything]\n  command  =  "old" # was\nurl'
        ' = "http://x"\n\n# next\n[profiles.x]\ny = 2\n'
    )
    inputs.append("[mcp_servers.mojo-anything]\ntool_timeout_sec = 5\n")
    inputs.append(
        'a = 1\n\n[mcp_servers.mojo-anything]\ncommand = "old"\nargs = ["mcp"]'
    )
    for i in range(len(inputs)):
        _same_as_phase1(py, "codex", f, inputs[i])
        _same_as_phase1(py, "codex", f, inputs[i], "--remove")


def test_json_text_matches_serde() raises:
    var py = _py()
    var inputs = List[String]()
    inputs.append("<none>")
    inputs.append("")
    inputs.append("  \n")
    inputs.append(
        '{"theme": "dark", "mcpServers": {"other": {"command": "other"}}}'
    )
    inputs.append(
        '{"n": 1.5, "big": 18446744073709551615, "neg": -3, "e": 1e300, "s":'
        ' "\\u00e9\\n\\t\\"", "x": [], "o": {}}'
    )
    inputs.append(
        '{"mcpServers": {"mojo-anything": {"command": "old", "url": "http://x",'
        ' "type": "sse"}}}'
    )
    for i in range(len(inputs)):
        for id in ["claude", "cursor"]:
            var file = ".claude.json" if id == "claude" else ".cursor/mcp.json"
            _same_as_phase1(py, String(id), file, inputs[i])
            _same_as_phase1(py, String(id), file, inputs[i], "--remove")
    _same_as_phase1(
        py,
        "opencode",
        ".config/opencode/opencode.json",
        '{"mcp":{"other":{"type":"local","command":["x"]}}}',
    )


def test_json_serde_reads_otherwise_goes_to_the_phase1_binary() raises:
    var py = _py()
    for body in ['{"x": 1e400}', '{"x": -0}', '{"a": [-0, 1]}']:
        var home = _home(py, "serde")
        _put(py, home + "/.cursor/mcp.json", String(body))
        assert_false(handled_in_mojo(_opts(home, "cursor")), body)
        _gone(py, home)
    var home = _home(py, "serde-ok")
    _put(py, home + "/.cursor/mcp.json", '{"x": -0.5, "y": -10}')
    assert_true(handled_in_mojo(_opts(home, "cursor")))
    _gone(py, home)


def test_a_quoted_header_goes_to_the_phase1_binary() raises:
    var text = '[mcp_servers."mojo-anything"]\ncommand = "old"\n'
    assert_false(
        codex_edit(text, "/opt/bin/mojo-anything", "updated").supported
    )
    assert_true(codex_edit(text, "/opt/bin/mojo-anything", "removed").supported)


def test_unsupported_toml_goes_to_the_phase1_binary() raises:
    var cmd = "/opt/bin/mojo-anything"
    for shape in [
        "a = 1\r\n",
        '[mcp_servers]\nmojo-anything = { command = "x" }\n',
        'mcp_servers.mojo-anything.command = "x"\n',
        '[mcp_servers.mojo-anything.env]\nA = "1"\n',
        "[[mcp_servers.list]]\na = 1\n",
        'x = """\nmulti\n"""\n',
    ]:
        assert_false(codex_edit(String(shape), cmd, "added").supported, shape)
    assert_false(
        codex_edit("", '/opt/"quoted"/mojo-anything', "added").supported
    )
    assert_true(codex_edit("mcp_servers = { }\n", cmd, "added").inline_servers)


def main() raises:
    test_no_backup_changes_the_file_without_a_copy()
    test_adds_keeps_and_removes_entries()
    test_reinstall_preserves_custom_options_for_the_same_server()
    test_reinstall_keeps_an_inline_codex_entry()
    test_opencode_gets_a_local_server_and_the_skill()
    test_setup_keeps_rust_anything_entry()
    test_keeps_a_symlinked_settings_file_and_its_permissions()
    test_finds_agents_and_never_breaks_a_bad_file()
    test_codex_text_matches_toml_edit()
    test_json_text_matches_serde()
    test_unsupported_toml_goes_to_the_phase1_binary()
    test_json_serde_reads_otherwise_goes_to_the_phase1_binary()
    test_a_quoted_header_goes_to_the_phase1_binary()
    print("test_setup: 13 passed")
