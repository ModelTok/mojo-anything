# `doctor`: check pixi and the pinned Mojo, the language runtimes, the agent
# setup and the MCP server on this machine, and say the command that fixes
# each problem (port of src/doctor.rs).
#
# Language runtimes are optional: each matters only for the languages being
# ported. pixi, the pinned Mojo, the MCP server and the setup of every agent
# found on the machine are required. The Rust tool runs the probes on threads;
# here they run one after another, with the same rows in the same order.

from std.os import getenv
from std.os.path import exists, isfile
from std.python import Python, PythonObject

from emberjson import Value
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback, fallback_path, own_binary
from mojo_anything.json import parse_json
from mojo_anything.json_text import write_string
from mojo_anything.process import Command, QUICK, output
from mojo_anything.setup import NAME, Agent, agent, home, join, present
from mojo_anything.skill_files import skill_file_names, skill_file_text
from mojo_anything.walk import canonical

comptime MOJO_VERSION = "1.2.0"
comptime MIN_JAVA = 22
comptime PKG_VERSION = "0.1.0"
comptime WSL = "wsl -d Ubuntu-24.04 --cd ~/github/mojo-anything"
comptime PIXI_INSTALL = "curl -fsSL https://pixi.sh/install.sh | sh"
comptime MOJO_PROBE = 300.0
comptime INSTALL = (
    "`npm install -g mojo-anything` (Linux x64/arm64, macOS arm64), or the"
    " archive for your platform from"
    " https://github.com/ModelTok/mojo-anything/releases"
)

comptime OK = "ok"
comptime MISSING = "missing"
comptime OUTDATED = "outdated"
comptime FOREIGN = "foreign"

comptime MACOS = 0
comptime WINDOWS = 1
comptime OTHER = 2

comptime _MCP = """
import json, queue, subprocess, threading, time

def _compact(v):
    return json.dumps(v, separators=(",", ":"), ensure_ascii=False)

def talk(exe, limit, version):
    try:
        child = subprocess.Popen([exe, "mcp"], stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except OSError as e:
        return ("err", "could not start: %s (os error %d)" % (e.strerror, e.errno))
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "mojo-anything-doctor", "version": version}}},
        {"jsonrpc": "2.0", "method": "notifications/initialized"},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
    ]
    try:
        for r in requests:
            child.stdin.write((_compact(r) + "\\n").encode())
        child.stdin.close()
    except OSError:
        pass
    lines = queue.Queue()
    def read():
        for raw in child.stdout:
            try:
                line = raw.decode("utf-8")
            except UnicodeDecodeError:
                break
            if line.endswith("\\n"):
                line = line[:-1]
                if line.endswith("\\r"):
                    line = line[:-1]
            lines.put(line)
        lines.put(None)
    threading.Thread(target=read, daemon=True).start()
    deadline = time.monotonic() + limit
    init = list_ = None
    outcome = None
    while not (init is not None and list_ is not None):
        left = max(0.0, deadline - time.monotonic())
        try:
            line = lines.get(timeout=left)
        except queue.Empty:
            outcome = "no answer within %ds" % int(limit)
            break
        if line is None:
            outcome = "exited before answering"
            break
        try:
            reply = json.loads(line)
        except ValueError:
            outcome = "printed a line that is not JSON: " + line
            break
        rid = reply.get("id") if isinstance(reply, dict) else None
        if isinstance(rid, int) and not isinstance(rid, bool):
            if rid == 1:
                init = reply
            elif rid == 2:
                list_ = reply
    try:
        child.kill()
    except OSError:
        pass
    child.wait()
    if outcome is not None:
        return ("err", outcome)
    result = init.get("result") if isinstance(init, dict) else None
    if not (isinstance(result, dict) and isinstance(result.get("protocolVersion"), str)):
        return ("err", "`initialize` gave no protocol version: " + _compact(init))
    result = list_.get("result") if isinstance(list_, dict) else None
    tools = result.get("tools") if isinstance(result, dict) else None
    if isinstance(tools, list) and tools:
        return ("ok", str(len(tools)))
    return ("err", "`tools/list` listed no tools: " + _compact(list_))

def platform():
    import sys
    return "macos" if sys.platform == "darwin" else ("windows" if sys.platform == "win32" else "other")

def codex_entry(text, name):
    import tomllib
    try:
        data = tomllib.loads(text)
    except tomllib.TOMLDecodeError:
        return ("invalid",)
    servers = data.get("mcp_servers")
    server = servers.get(name) if isinstance(servers, dict) else None
    if not isinstance(server, dict):
        return ("none", 0, "", [], 0)
    command = server.get("command")
    args = server.get("args")
    args = [a for a in args if isinstance(a, str)] if isinstance(args, list) else []
    if isinstance(command, str):
        return ("some", 1, command, args, int("url" in server))
    return ("some", 0, "", args, int("url" in server))
"""


@fieldwise_init
struct Version(Copyable, ImplicitlyCopyable, Movable):
    var major: Int
    var minor: Int
    var patch: Int

    def __eq__(self, other: Self) -> Bool:
        return (
            self.major == other.major
            and self.minor == other.minor
            and self.patch == other.patch
        )

    def __lt__(self, other: Self) -> Bool:
        if self.major != other.major:
            return self.major < other.major
        if self.minor != other.minor:
            return self.minor < other.minor
        return self.patch < other.patch

    def text(self) -> String:
        return String(self.major, ".", self.minor, ".", self.patch)


@fieldwise_init
struct Check(Copyable, Movable):
    var name: String
    var status: String
    var required: Bool
    """A problem here makes `doctor` exit 1."""
    var detail: String
    var fix: Optional[String]


struct Report(Copyable, Movable):
    var checks: List[Check]

    def __init__(out self):
        self.checks = List[Check]()

    def ok(self) -> Bool:
        """Whether every required check passed."""
        for c in self.checks:
            if c.required and c.status != OK:
                return False
        return True


def _u32(digits: String) -> Optional[Int]:
    if digits.byte_length() == 0 or digits.byte_length() > 10:
        return None
    var n = 0
    for b in digits.as_bytes():
        if b < 48 or b > 57:
            return None
        n = n * 10 + Int(b - 48)
    if n > 4294967295:
        return None
    return n


def parse_version(text: String) -> Optional[Version]:
    """The first `N[.N[.N]]` in a version banner."""
    var s = text.as_bytes()
    var start = -1
    for i in range(len(s)):
        if s[i] >= 48 and s[i] <= 57:
            start = i
            break
    if start < 0:
        return None
    var end = start
    while end < len(s) and ((s[end] >= 48 and s[end] <= 57) or s[end] == 46):
        end += 1
    var parts = String(text[byte=start:end]).split(".")
    var major = _u32(String(parts[0]))
    if not major:
        return None
    var minor = 0
    var patch = 0
    if len(parts) > 1:
        minor = _u32(String(parts[1])).or_else(0)
    if len(parts) > 2:
        patch = _u32(String(parts[2])).or_else(0)
    return Version(major.value(), minor, patch)


def parse_java_version(text: String) -> Optional[Version]:
    """Java's version, reading the old `1.8.0` scheme as 8."""
    var v = parse_version(text)
    if v and v.value().major == 1:
        return Version(v.value().minor, v.value().patch, 0)
    return v


def grade(
    ran: Bool, version: Optional[Version], minimum: Optional[Version]
) -> String:
    if not ran:
        return MISSING
    if version and minimum and version.value() < minimum.value():
        return OUTDATED
    return OK


@fieldwise_init
struct Runtime(Copyable, Movable):
    var name: String
    var program: String
    var args: List[String]
    var minimum: Optional[Version]
    var java: Bool
    var fix_macos: String
    var fix_linux: String


def _rt(
    name: String,
    program: String,
    arg: String,
    minimum: Optional[Version],
    java: Bool,
    fix_macos: String,
    fix_linux: String,
) -> Runtime:
    var args = List[String]()
    args.append(arg)
    return Runtime(name, program, args^, minimum, java, fix_macos, fix_linux)


def runtimes() -> List[Runtime]:
    var r = List[Runtime]()
    r.append(
        _rt(
            "python",
            "python3",
            "--version",
            Version(3, 9, 0),
            False,
            "brew install python@3.13",
            "sudo apt install python3",
        )
    )
    r.append(
        _rt(
            "node",
            "node",
            "--version",
            Version(24, 0, 0),
            False,
            "brew install node@24",
            "fnm install 24 && fnm default 24",
        )
    )
    r.append(
        _rt(
            "cc",
            "cc",
            "--version",
            None,
            False,
            "xcode-select --install",
            "sudo apt install build-essential",
        )
    )
    r.append(
        _rt(
            "go",
            "go",
            "version",
            Version(1, 22, 0),
            False,
            "brew install go",
            "install Go 1.22+ from https://go.dev/dl",
        )
    )
    r.append(
        _rt(
            "ruby",
            "ruby",
            "--version",
            Version(3, 0, 0),
            False,
            (
                'brew install ruby && export PATH="$(brew --prefix'
                ' ruby)/bin:$PATH"'
            ),
            "sudo apt install ruby-full",
        )
    )
    r.append(
        _rt(
            "java",
            "java",
            "-version",
            Version(MIN_JAVA, 0, 0),
            True,
            "brew install openjdk",
            "sudo apt install openjdk-25-jdk",
        )
    )
    r.append(
        _rt(
            "javac",
            "javac",
            "-version",
            Version(MIN_JAVA, 0, 0),
            True,
            "brew install openjdk",
            "sudo apt install openjdk-25-jdk",
        )
    )
    r.append(
        _rt(
            "kotlinc",
            "kotlinc",
            "-version",
            None,
            False,
            "brew install kotlin",
            "sdk install kotlin",
        )
    )
    r.append(
        _rt(
            "php",
            "php",
            "--version",
            Version(8, 0, 0),
            False,
            "brew install php",
            "sudo apt install php-cli",
        )
    )
    r.append(
        _rt(
            "dotnet",
            "dotnet",
            "--version",
            None,
            False,
            "brew install --cask dotnet-sdk",
            "install the .NET SDK from https://dotnet.microsoft.com/download",
        )
    )
    return r^


def pick(platform: Int, r: Runtime) -> String:
    """The fix for this platform: on Windows the Linux command, run in WSL."""
    if platform == MACOS:
        return r.fix_macos
    if platform == OTHER:
        return r.fix_linux
    return "in WSL (" + WSL + "): " + r.fix_linux


def runtime_fix(r: Runtime, status: String, platform: Int) -> Optional[String]:
    if status == OK:
        return None
    var fix = pick(platform, r)
    if r.java:
        fix += String(
            "\n(Java and Kotlin units need Java ",
            MIN_JAVA,
            " or newer, for the Foreign Function & Memory API)",
        )
    return fix


def _first_line(text: String) -> String:
    var cut = text.find("\n")
    var line = String(text[byte=0:cut]) if cut >= 0 else text
    if line.endswith("\r"):
        var cut_cr = String(line[byte = 0 : line.byte_length() - 1])
        line = cut_cr^
    return String(line.strip())


def probe(program: String, args: List[String]) -> Optional[String]:
    """The program's banner (stdout, else stderr), or None when it did not
    run."""
    var cmd = Command(program)
    cmd.args = args.copy()
    try:
        var out = output(cmd, QUICK)
        if not out.success:
            return None
        var text = out.stdout_text()
        if String(text.strip()) == "":
            text = out.stderr_text()
        return _first_line(text)
    except:
        return None


def assess(r: Runtime, banner: Optional[String], platform: Int) -> Check:
    var version: Optional[Version] = None
    if banner:
        if r.java:
            version = parse_java_version(banner.value())
        else:
            version = parse_version(banner.value())
    var status = grade(Bool(banner), version, r.minimum)
    var outdated = status == OUTDATED
    var detail: String
    if not banner:
        detail = "`" + r.program + "` not found or did not run"
    else:
        var b = banner.value()
        if r.minimum and outdated and r.java:
            detail = String(
                b,
                "; Java and Kotlin units need Java ",
                r.minimum.value().major,
                "+ (the Foreign Function & Memory API)",
            )
        elif r.minimum and outdated and r.name == "node":
            if version and version.value() < Version(22, 6, 0):
                detail = (
                    b
                    + "; TS and JS units need Node 22.6+, and the wasm bridge"
                    " (`mojo-wasm`) and `profile` need Node 24+"
                )
            else:
                detail = (
                    b
                    + "; TS and JS units work, but the wasm bridge"
                    " (`mojo-wasm`)"
                    " and `profile` need Node 24+"
                )
        elif r.minimum and outdated:
            detail = String(
                b,
                "; mojo-anything needs ",
                r.minimum.value().major,
                ".",
                r.minimum.value().minor,
                "+",
            )
        elif r.minimum and r.java:
            detail = String(
                b,
                " (Java and Kotlin units need ",
                r.minimum.value().major,
                "+)",
            )
        else:
            detail = b
    return Check(
        r.name, status, False, detail, runtime_fix(r, status, platform)
    )


def _which(program: String) -> Optional[String]:
    var paths = getenv("PATH")
    if paths.byte_length() == 0:
        return None
    for dir in paths.split(":"):
        var file = join(String(dir), program)
        if isfile(file):
            return file
    return None


def runtime(r: Runtime, platform: Int) -> Check:
    var check = assess(r, probe(r.program, r.args), platform)
    if r.name == "ruby" and check.status == OUTDATED and platform == MACOS:
        var at = _which("ruby")
        if at and at.value().startswith("/usr/bin"):
            check.detail += "; this is macOS's system Ruby"
    return check^


def pinned_mojo_args() -> List[String]:
    var args = List[String]()
    args.append("exec")
    args.append("-c")
    args.append("https://conda.modular.com/max")
    args.append("-c")
    args.append("conda-forge")
    args.append("--spec")
    args.append("mojo==" + MOJO_VERSION)
    args.append("mojo")
    args.append("--version")
    return args^


def quoted(path: String) -> String:
    if " " in path:
        return '"' + path + '"'
    return path


def find_pixi() -> Optional[String]:
    """`pixi` on PATH, else `~/.pixi/bin/pixi`."""
    var on_path = _which("pixi")
    if on_path:
        return on_path
    var h = getenv("HOME")
    if h.byte_length() == 0:
        return None
    var p = join(join(join(h, ".pixi"), "bin"), "pixi")
    if isfile(p):
        return p
    return None


def _join(words: List[String]) -> String:
    var out = String("")
    for i in range(len(words)):
        if i > 0:
            out += " "
        out += words[i]
    return out


def _temp_dir() -> String:
    var t = getenv("TMPDIR")
    if t.byte_length() > 0:
        return t
    return "/tmp"


def pinned_mojo(pixi: String) -> Check:
    """Runs the pinned Mojo through `pixi exec`, as every generated unit
    gets it."""
    var args = pinned_mojo_args()
    var by_hand = quoted(pixi) + " " + _join(args)
    var cmd = Command(pixi)
    cmd.args = args.copy()
    cmd.cwd = _temp_dir()
    var status: String
    var detail: String
    try:
        var out = output(cmd, MOJO_PROBE)
        if not out.success:
            var last = String("no message")
            var lines = out.stderr_text().split("\n")
            for i in range(len(lines) - 1, -1, -1):
                if String(lines[i].strip()) != "":
                    last = String(lines[i].strip())
                    break
            status = MISSING
            detail = "pixi could not run Mojo " + MOJO_VERSION + ": " + last
        else:
            var banner = _first_line(out.stdout_text())
            var got = parse_version(banner)
            var want = parse_version(MOJO_VERSION)
            if (not got and not want) or (
                got and want and got.value() == want.value()
            ):
                status = OK
                detail = banner + ", through pixi (the Mojo every unit pins)"
            else:
                status = OUTDATED
                detail = (
                    "pixi ran `"
                    + banner
                    + "`, not the pinned Mojo "
                    + MOJO_VERSION
                )
    except e:
        status = MISSING
        detail = String(
            "pixi did not get Mojo ",
            MOJO_VERSION,
            ": ",
            e,
            " (the first run downloads it)",
        )
    var fix: Optional[String] = None
    if status != OK:
        fix = by_hand + "\n(run it to see the whole error)"
    return Check("mojo", status, True, detail, fix)


def mojo_toolchain(platform: Int) -> List[Check]:
    """The `pixi` and `mojo` rows; on Windows both fail and point at WSL."""
    var out = List[Check]()
    if platform == WINDOWS:
        var fix = "use the WSL clone: " + WSL
        out.append(
            Check(
                "pixi",
                MISSING,
                True,
                (
                    "Mojo builds only on Linux and macOS: on Windows,"
                    " mojo-anything runs in WSL"
                ),
                fix,
            )
        )
        out.append(
            Check(
                "mojo",
                MISSING,
                True,
                "Mojo " + MOJO_VERSION + " runs only on Linux and macOS",
                fix,
            )
        )
        return out^
    var pixi = find_pixi()
    var banner: Optional[String] = None
    if pixi:
        var a = List[String]()
        a.append("--version")
        banner = probe(pixi.value(), a)
    var detail: String
    if pixi and banner:
        detail = banner.value() + " (" + pixi.value() + ")"
    elif pixi:
        detail = "`" + pixi.value() + " --version` did not run"
    else:
        detail = "`pixi` is not on PATH or in ~/.pixi/bin"
    var fix: Optional[String] = None
    if not banner:
        fix = String(PIXI_INSTALL)
    out.append(Check("pixi", OK if banner else MISSING, True, detail, fix))
    if pixi and banner:
        out.append(pinned_mojo(pixi.value()))
    else:
        out.append(
            Check(
                "mojo",
                MISSING,
                True,
                "pixi runs the pinned Mojo "
                + MOJO_VERSION
                + ", and pixi is missing",
                String(PIXI_INSTALL) + "\n(then run doctor again)",
            )
        )
    return out^


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(_MCP, scope)
    return scope


def mcp_self_test(exe: String) -> Check:
    """Starts `<exe> mcp`, asks for `initialize` and `tools/list`, and
    expects both answers in 10 s."""
    var status = MISSING
    var detail: String
    try:
        var r = _py()["talk"](
            PythonObject(exe), PythonObject(10.0), PythonObject(PKG_VERSION)
        )
        if String(py=r[0]) == "ok":
            status = OK
            detail = (
                "`" + exe + " mcp` answered with " + String(py=r[1]) + " tools"
            )
        else:
            detail = "`" + exe + " mcp`: " + String(py=r[1])
    except e:
        detail = String("`", exe, " mcp`: ", e)
    var fix: Optional[String] = None
    if status != OK:
        fix = (
            "run `"
            + quoted(exe)
            + " mcp` by hand and look at what it prints; reinstall with "
            + INSTALL
        )
    return Check("mcp", status, True, detail, fix)


@fieldwise_init
struct Entry(Copyable, Movable):
    """An agent's `mojo-anything` MCP server entry, as read from its
    settings."""

    var command: Optional[String]
    var args: List[String]
    var url: Bool
    var disabled: Bool
    """OpenCode keeps a configured server out of the way with `disabled`."""


comptime INSTALL_MISSING = 0
comptime INSTALL_CURRENT = 1
comptime INSTALL_OUTDATED = 2
comptime INSTALL_FOREIGN = 3


def install_status(i: Int) -> String:
    if i == INSTALL_MISSING:
        return MISSING
    if i == INSTALL_CURRENT:
        return OK
    if i == INSTALL_OUTDATED:
        return OUTDATED
    return FOREIGN


def entry_state(
    entry: Optional[Entry], exe: String, phase1: String = ""
) -> Int:
    """Ours and current when it runs `<exe> mcp`, or `mcp` on the Phase 1
    binary this one falls back to (`phase1`, what a `setup` handed over to
    it registers); outdated when it runs `mcp` on another binary."""
    if not entry:
        return INSTALL_MISSING
    ref e = entry.value()
    if not e.command:
        return INSTALL_FOREIGN
    if e.url or len(e.args) != 1 or e.args[0] != "mcp":
        return INSTALL_FOREIGN
    if e.disabled:
        return INSTALL_OUTDATED
    var command = e.command.value()
    if command == exe or (exists(command) and canonical(command) == exe):
        return INSTALL_CURRENT
    if phase1 != "" and (
        command == phase1 or (exists(command) and canonical(command) == phase1)
    ):
        return INSTALL_CURRENT
    return INSTALL_OUTDATED


def skill_state(installed: List[Optional[String]]) -> Int:
    """The installed skill files, in order, against this build's."""
    if not installed[0]:
        for i in range(len(installed)):
            if installed[i]:
                return INSTALL_OUTDATED
        return INSTALL_MISSING
    var names = skill_file_names()
    var all_same = True
    for i in range(len(installed)):
        if not installed[i] or installed[i].value() != skill_file_text(
            names[i]
        ):
            all_same = False
    if all_same:
        return INSTALL_CURRENT
    for line in installed[0].value().splitlines():
        if String(line) == "":
            break
        if String(line.strip()) == "name: " + NAME:
            return INSTALL_OUTDATED
    return INSTALL_FOREIGN


def _strings(v: Value) -> List[String]:
    var out = List[String]()
    if v.is_array():
        for item in v.array():
            if item.is_string():
                out.append(item.string())
    return out^


def _field(v: Value, key: String) -> Optional[Value]:
    if v.is_object() and key in v.object():
        try:
            return v.object()[key].copy()
        except:
            pass
    return None


def read_entry(agent_id: String, path: String) raises -> Optional[Entry]:
    """The agent's `mojo-anything` entry; raises with the row's detail when
    the settings file cannot be read as settings."""
    if not exists(path):
        return None
    var text: String
    try:
        text = open(path, "r").read()
    except e:
        raise Error(String("reading ", path, ": ", e))
    if String(text.strip()) == "":
        return None
    if agent_id == "codex":
        var r = _py()["codex_entry"](PythonObject(text), PythonObject(NAME))
        var kind = String(py=r[0])
        if kind == "invalid":
            raise Error(path + " is not valid TOML")
        if kind == "none":
            return None
        var command: Optional[String] = None
        if Int(py=r[1]) != 0:
            command = String(py=r[2])
        var args = List[String]()
        var n = Int(py=Python.import_module("builtins").len(r[3]))
        for i in range(n):
            args.append(String(py=r[3][i]))
        return Entry(command, args^, Int(py=r[4]) != 0, False)
    var doc: Value
    try:
        doc = parse_json(text)
    except:
        raise Error(path + " is not valid JSON")
    if agent_id == "opencode":
        var mcp = _field(doc, "mcp").or_else(Value())
        var servers = mcp.copy()
        var nested = _field(mcp, "servers")
        if nested:
            servers = nested.value().copy()
        var server = _field(servers, NAME)
        if not server:
            return None
        var argv = _strings(_field(server.value(), "command").or_else(Value()))
        var command: Optional[String] = None
        var args = List[String]()
        for i in range(len(argv)):
            if i == 0:
                command = argv[0]
            else:
                args.append(argv[i])
        var disabled = _field(server.value(), "disabled")
        return Entry(
            command,
            args^,
            Bool(_field(server.value(), "url")),
            Bool(disabled)
            and disabled.value().is_bool()
            and disabled.value().bool(),
        )
    var servers = _field(doc, "mcpServers").or_else(Value())
    var server = _field(servers, NAME)
    if not server:
        return None
    var command: Optional[String] = None
    var c = _field(server.value(), "command")
    if c and c.value().is_string():
        command = c.value().string()
    return Entry(
        command,
        _strings(_field(server.value(), "args").or_else(Value())),
        Bool(_field(server.value(), "url")),
        False,
    )


def _fix_for(
    state: Int, setup_fix: String, foreign: String
) -> Optional[String]:
    if state == INSTALL_CURRENT:
        return None
    if state == INSTALL_FOREIGN:
        return foreign
    return setup_fix


def agents(exe: String) -> List[Check]:
    var out = List[Check]()
    # A `setup` this binary hands over registers the Phase 1 binary (its
    # current_exe); that entry runs this tool's MCP server all the same.
    var phase1 = String("")
    var fb = fallback_path()
    if exists(fb):
        phase1 = canonical(fb)
    var h: String
    try:
        h = home()
    except e:
        out.append(
            Check("agents", MISSING, False, String(e), String("set HOME"))
        )
        return out^
    var found = List[String]()
    for id in "claude,codex,cursor,gemini,opencode".split(","):
        try:
            if present(agent(String(id)), h):
                found.append(String(id))
        except:
            pass
    if len(found) == 0:
        out.append(
            Check(
                "agents",
                MISSING,
                False,
                (
                    "no coding agent found (Claude Code, Codex, Cursor, Gemini"
                    " CLI, OpenCode); the CLI works without one"
                ),
                quoted(exe) + " setup --agent claude",
            )
        )
        return out^
    for id in found:
        var a: Agent
        try:
            a = agent(id)
        except:
            continue
        var config = join(h, a.config)
        var setup_fix = quoted(exe) + " setup --agent " + id
        var state: Int
        var detail: String
        try:
            var entry = read_entry(id, config)
            state = entry_state(entry, exe, phase1)
            if state == INSTALL_MISSING:
                detail = "no `" + NAME + "` server in " + config
            elif entry.value().disabled:
                detail = "`" + NAME + "` in " + config + " is disabled"
            elif entry.value().command:
                detail = (
                    config + " runs `" + entry.value().command.value() + "`"
                )
            else:
                detail = (
                    "`" + NAME + "` in " + config + " is not `" + exe + " mcp`"
                )
        except e:
            state = INSTALL_FOREIGN
            detail = String(e)
        out.append(
            Check(
                a.name + " mcp",
                install_status(state),
                True,
                detail,
                _fix_for(
                    state,
                    setup_fix,
                    "fix or remove the `"
                    + NAME
                    + "` entry in "
                    + config
                    + ", then run `"
                    + setup_fix
                    + "`",
                ),
            )
        )
        if a.skills != "":
            var dir = join(join(h, a.skills), NAME)
            var installed = List[Optional[String]]()
            for name in skill_file_names():
                var path = join(dir, name)
                var got: Optional[String] = None
                if isfile(path):
                    try:
                        got = open(path, "r").read()
                    except:
                        pass
                installed.append(got)
            var s = skill_state(installed)
            var skill_md = join(dir, "SKILL.md")
            var sd: String
            if s == INSTALL_MISSING:
                sd = skill_md + " not installed"
            elif s == INSTALL_CURRENT:
                sd = skill_md + " matches this version"
            elif s == INSTALL_OUTDATED:
                sd = skill_md + " is from another version"
            else:
                sd = skill_md + " is not mojo-anything's skill"
            out.append(
                Check(
                    a.name + " skill",
                    install_status(s),
                    True,
                    sd,
                    _fix_for(
                        s,
                        setup_fix,
                        "move " + dir + " aside, then run `" + setup_fix + "`",
                    ),
                )
            )
    return out^


def platform_here() -> Int:
    try:
        var p = String(py=_py()["platform"]())
        if p == "macos":
            return MACOS
        if p == "windows":
            return WINDOWS
    except:
        pass
    return OTHER


def run() -> Report:
    var exe = canonical(own_binary())
    if exe == "":
        exe = NAME
    var platform = platform_here()
    var r = Report()
    for c in mojo_toolchain(platform):
        r.checks.append(c.copy())
    for rt in runtimes():
        r.checks.append(runtime(rt, platform))
    r.checks.append(mcp_self_test(exe))
    for c in agents(exe):
        r.checks.append(c.copy())
    return r^


def _pad(s: String, width: Int) -> String:
    var out = s
    for _ in range(width - len(s.codepoints())):
        out += " "
    return out


def text(r: Report) -> String:
    """One line per check, the fix under each problem."""
    var width = 0
    for c in r.checks:
        width = max(width, c.name.byte_length())
    var out = String("")
    for c in r.checks:
        var optional = "" if c.required or c.status == OK else " (optional)"
        out += _pad(c.status, 9) + " " + _pad(c.name, width) + "  " + c.detail
        out += optional + "\n"
        if c.fix:
            var lines = c.fix.value().split("\n")
            for i in range(len(lines)):
                var label = "fix:" if i == 0 else ""
                out += _pad("", 9) + " " + _pad("", width) + "  "
                out += _pad(label, 4) + " " + String(lines[i]) + "\n"
    if r.ok():
        out += (
            "\nEverything required is in place. Language runtimes are"
            " optional: each matters only for the languages you port.\n"
        )
    else:
        out += (
            "\nSomething required is missing: pixi or the pinned Mojo, the MCP"
            " server, or the setup of an agent found here. Run the fix"
            " commands above.\n"
        )
    return out


def report_json(r: Report) -> String:
    """`serde_json::to_string_pretty` of the Rust `Report`."""
    if len(r.checks) == 0:
        return '{\n  "checks": []\n}'
    var out = String('{\n  "checks": [\n')
    for i in range(len(r.checks)):
        ref c = r.checks[i]
        out += '    {\n      "name": ' + write_string(c.name) + ",\n"
        out += '      "status": ' + write_string(c.status) + ",\n"
        out += (
            '      "required": ' + ("true" if c.required else "false") + ",\n"
        )
        out += '      "detail": ' + write_string(c.detail) + ",\n"
        out += '      "fix": '
        out += write_string(c.fix.value()) if c.fix else "null"
        out += "\n    }"
        out += ",\n" if i + 1 < len(r.checks) else "\n"
    return out + "  ]\n}"


def toml_reads_alike() -> Bool:
    """Whether Codex's settings, when there are any, parse as TOML 1.0.
    toml_edit reads TOML 1.1 (multi-line inline tables, trailing commas), and
    `tomllib` only 1.0, so a file `tomllib` refuses could be fine for the
    Rust tool: such a run goes to the Phase 1 binary (doctor writes nothing,
    so handing it over first changes nothing)."""
    try:
        var path = join(home(), ".codex/config.toml")
        if not isfile(path):
            return True
        var text = open(path, "r").read()
        if String(text.strip()) == "":
            return True
        var r = _py()["codex_entry"](PythonObject(text), PythonObject(NAME))
        return String(py=r[0]) != "invalid"
    except:
        return False


def run_doctor(p: Parsed, argv: List[String]) -> Int:
    if not toml_reads_alike():
        return fallback(argv)
    var r = run()
    if p.flag("json"):
        print(report_json(r))
    else:
        print(text(r), end="")
    return 0 if r.ok() else 1
