# Every outside program runs with stdin closed, in its own process group,
# under a time limit (port of src/process.rs).
#
# The child is started by Python's `subprocess` through Mojo's Python interop:
# `process_group=0` puts it in a group of its own, and at the limit the whole
# group is killed with `os.killpg`, so a test runner's workers or a shell's
# background jobs go with it. Its output goes to temporary files rather than
# pipes, so a descendant that keeps a pipe open cannot hold the caller after
# the group is gone, and the bytes are read by Mojo in one piece.

from std.collections import Dict
from std.os import getenv
from std.python import Python, PythonObject

from mojo_anything.pycache import py_exec

comptime KEEP = 1 << 20
comptime TESTS = 30.0 * 60.0
comptime BUILD = 30.0 * 60.0
comptime QUICK = 60.0

comptime _RUNNER = """
import os, signal, subprocess, tempfile

def run(argv, env_set, env_remove, cwd, limit, capture):
    env = dict(os.environ)
    for key in env_remove:
        env.pop(key, None)
    env.update(env_set)
    paths = ["", ""]
    files = [None, None]
    if capture:
        for i in range(2):
            fd, paths[i] = tempfile.mkstemp(prefix="mojo-anything-out-")
            files[i] = os.fdopen(fd, "wb")
    try:
        try:
            child = subprocess.Popen(
                argv, stdin=subprocess.DEVNULL, stdout=files[0], stderr=files[1],
                cwd=cwd or None, env=env, process_group=0,
            )
        except OSError as e:
            for p in paths:
                if p:
                    os.remove(p)
            return (0, False, "%s (os error %d)" % (e.strerror, e.errno), "", "")
        timed_out = False
        try:
            child.wait(timeout=limit)
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            child.wait()
        return (child.returncode, timed_out, "", paths[0], paths[1])
    finally:
        for f in files:
            if f is not None:
                f.close()

def take(path):
    os.remove(path)
"""


@fieldwise_init
struct Command(Copyable, Movable):
    """A program to run: its arguments, environment changes and folder (an
    empty `cwd` keeps the caller's)."""

    var program: String
    var args: List[String]
    var env: Dict[String, String]
    var env_remove: List[String]
    var cwd: String

    def __init__(out self, program: String):
        self.program = program
        self.args = List[String]()
        self.env = Dict[String, String]()
        self.env_remove = List[String]()
        self.cwd = ""

    def shown(self) -> String:
        """The command line as error messages show it: words joined by spaces.
        """
        var out = self.program
        for a in self.args:
            out += " "
            out += a
        return out


@fieldwise_init
struct Output(Copyable, Movable):
    """What a finished (or stopped) program left: its exit code (negative for a
    signal), the last MiB of each stream, and whether it hit the limit."""

    var success: Bool
    var code: Int
    var stdout: List[UInt8]
    var stderr: List[UInt8]
    var timed_out: Bool

    def stdout_text(self) -> String:
        return String(from_utf8_lossy=Span(self.stdout))

    def stderr_text(self) -> String:
        return String(from_utf8_lossy=Span(self.stderr))


def _is_float_text(text: String) -> Bool:
    """The forms Rust's `f64::from_str` takes that Python's `float` also takes:
    no spaces, no underscores."""
    if text.byte_length() == 0:
        return False
    for b in text.as_bytes():
        if b == 32 or b == 9 or b == 10 or b == 13 or b == 95:
            return False
    return True


def limit(default_s: Float64) -> Float64:
    """`MOJO_ANYTHING_COMMAND_TIMEOUT` seconds when set to a finite positive
    number, else `default_s`."""
    var text = getenv("MOJO_ANYTHING_COMMAND_TIMEOUT")
    if not _is_float_text(text):
        return default_s
    try:
        var builtins = Python.import_module("builtins")
        var value = Float64(py=builtins.float(text))
        if value > 0.0 and value < Float64.MAX and value == value:
            return value
    except:
        pass
    return default_s


def _runner() raises -> PythonObject:
    var scope = Python.dict()
    py_exec(_RUNNER, scope)
    return scope


def _read_last(path: String) raises -> List[UInt8]:
    var bytes = open(path, "r").read_bytes()
    if len(bytes) <= KEEP:
        return bytes^
    var kept = List[UInt8](capacity=KEEP)
    for i in range(len(bytes) - KEEP, len(bytes)):
        kept.append(bytes[i])
    return kept^


def _start(cmd: Command, limit_s: Float64, capture: Bool) raises -> Output:
    var scope = _runner()
    var argv = Python.list()
    argv.append(PythonObject(cmd.program))
    for a in cmd.args:
        argv.append(PythonObject(a))
    var env_set = Python.dict()
    for item in cmd.env.items():
        env_set[PythonObject(item.key)] = PythonObject(item.value)
    var env_remove = Python.list()
    for k in cmd.env_remove:
        env_remove.append(PythonObject(k))
    var result = scope["run"](
        argv,
        env_set,
        env_remove,
        PythonObject(cmd.cwd),
        PythonObject(limit_s),
        PythonObject(capture),
    )
    var failure = String(py=result[2])
    if failure.byte_length() > 0:
        raise Error(String("running `", cmd.shown(), "`: ", failure))
    var code = Int(py=result[0])
    var timed_out = Bool(py=result[1])
    var stdout = List[UInt8]()
    var stderr = List[UInt8]()
    if capture:
        var out_path = String(py=result[3])
        var err_path = String(py=result[4])
        stdout = _read_last(out_path)
        stderr = _read_last(err_path)
        _ = scope["take"](PythonObject(out_path))
        _ = scope["take"](PythonObject(err_path))
    return Output(
        success=(code == 0 and not timed_out),
        code=code,
        stdout=stdout^,
        stderr=stderr^,
        timed_out=timed_out,
    )


def capture(cmd: Command, limit_s: Float64) raises -> Output:
    """Runs `cmd` for at most `limit_s` seconds and captures its output; a
    program past the limit is stopped with its whole group and comes back with
    `timed_out` set. Raises only when the program cannot start."""
    return _start(cmd, limit_s, True)


def _stalled(cmd: Command, limit_s: Float64) -> Error:
    return Error(
        String(
            "`",
            cmd.shown(),
            "` was still running after ",
            Int(limit_s),
            (
                "s and was stopped (set MOJO_ANYTHING_COMMAND_TIMEOUT to allow"
                " longer; a test runner in watch mode never ends, so run it"
                " once, e.g. `vitest run`)"
            ),
        )
    )


def output(cmd: Command, default_s: Float64) raises -> Output:
    """Runs `cmd` and captures its output (the last MiB of each stream), as
    `process::output`: raises when it is still running at the limit."""
    var limit_s = limit(default_s)
    var out = _start(cmd, limit_s, True)
    if out.timed_out:
        raise _stalled(cmd, limit_s)
    return out^


def status(cmd: Command, default_s: Float64) raises -> Int:
    """Runs `cmd` with the caller's output streams and returns its exit code,
    as `process::status`."""
    var limit_s = limit(default_s)
    var out = _start(cmd, limit_s, False)
    if out.timed_out:
        raise _stalled(cmd, limit_s)
    return out.code
