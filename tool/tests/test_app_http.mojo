# Servers in `app record` and `app replay` (tests/http.rs for the Phase 1
# tool): the server starts on a port of its own, the recorded requests go to
# it in order, and what it answers is stored or compared. No recorded case is
# a server, so the Mojo binary runs next to the Phase 1 binary on copies of
# the same folder, and the two must agree byte for byte: stdout, stderr, the
# exit code and every file under mojo/app-cases, the replay report included.

from std.python import Python, PythonObject
from std.testing import assert_equal

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import json, os, shutil, socket, subprocess, tempfile

DATA = os.path.join("tool", "tests", "data", "http")

def lines(path, items):
    with open(path, "w") as f:
        for item in items:
            f.write(json.dumps(item) + "\\n")

def fixture(name):
    d = os.path.join(tempfile.gettempdir(), "mojo-anything-test-http-%s-%d" % (name, os.getpid()))
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(os.path.join(d, "data"))
    for f in ("srv.py", "counter.py", "README.md"):
        shutil.copy(os.path.join(DATA, f), d)
    with open(os.path.join(d, "data", "body.txt"), "wb") as f:
        f.write(b"one\\r\\ntwo\\0\\nthree")
    with open(os.path.join(d, "data", "count.txt"), "w") as f:
        f.write("0")
    with open(os.path.join(d, "absent.sh"), "w") as f:
        f.write(': >> "$MOJO_ANYTHING_FALLBACK_LOG"\\nunset MOJO_ANYTHING_FALLBACK_LOG\\n'
                'exec python3 srv.py "$@"\\n')
    lines(os.path.join(d, "inputs.jsonl"), [
        {"name": "request", "path": "/hello"},
        {"name": "request-003", "path": "/div/1/1"},
        {"name": "request", "path": "/div/2/1"},
        {"name": "q1", "method": "POST", "path": "/echo", "body": "it's \\"q\\" ''' x"},
        {"name": "q2", "method": "POST", "path": "/echo", "body": "tab\\there \\\\ back"},
        {"name": "q3", "method": "POST", "path": "/echo", "body": "ends'"},
        {"name": "q4", "method": "POST", "path": "/echo", "body": "a\\\\b'"},
        {"name": "q5", "method": "POST", "path": "/echo", "body": "line1\\nline \\"2\\"\\n"},
        {"name": "q6", "method": "POST", "path": "/echo", "body": "x\\u007fy\\u0001"},
        {"name": "q7", "method": "PUT", "path": "/echo",
         "headers": {"X-Q": "say \\"hi\\"", "x-low": "v", "Host": "skipped"}},
        {"name": "q8", "method": "POST", "path": "/echo", "body": "it's \\\\ ok", "extra": 1},
        {"name": "q9", "method": "POST", "path": "/echo", "body": "a\\nb\\r\\nc'''d"},
        {"name": "q10", "method": "POST", "path": "/echo", "body": "x\\"y\\r\\n"},
        {"name": "q11", "method": "POST", "path": "/echo", "body": "a\\tb\\u0001\\"c\\\\"},
        {"name": "q12", "method": "POST", "path": "/echo", "body": "end\\"\\"\\"x\\n"},
        {"name": "q13", "method": "POST", "path": "/echo", "body": "\\nlead\\\\"},
        {"name": "q14", "method": "POST", "path": "/echo", "body": "t\\tq\\\\\\r\\n"},
        {"name": "head", "method": "HEAD", "path": "/hello"},
        {"name": None, "method": "DELETE", "path": "/div/9/3"},
        {"name": "", "path": "/hello?x=1"},
        {"name": "Same Name!", "path": "/search?q=1"},
        {"name": "same-name", "path": "/search?q=2"},
    ])
    lines(os.path.join(d, "bad.jsonl"), [{"path": "/hello"}, {"path": "hello"}])
    lines(os.path.join(d, "hook.jsonl"), [{"name": "hook", "path": "/hook"},
                                          {"name": "plain", "path": "/hello"}])
    lines(os.path.join(d, "counter.jsonl"), [{"name": "a1", "method": "POST", "path": "/"},
                                             {"name": "a2", "path": "/"}])
    lines(os.path.join(d, "port.jsonl"), [{"name": "p", "path": "/div/8/3"}])
    return d

def free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p

def gone(path):
    shutil.rmtree(path, ignore_errors=True)

def tree(d):
    root = os.path.join(d, "mojo", "app-cases")
    out = []
    for base, dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, root), fh.read().replace(d.encode(), b"<D>")))
    out.sort()
    with open(os.path.join(d, "data", "count.txt"), "rb") as fh:
        out.append(("data/count.txt", fh.read()))
    return out

def tree_diff(new, old):
    # "" when both folders hold the same files, else what differs.
    a, b = dict(tree(new)), dict(tree(old))
    out = []
    for k in sorted(set(a) | set(b)):
        if a.get(k) != b.get(k):
            out.append("%s:\\n  mojo:    %r\\n  phase 1: %r" % (k, a.get(k), b.get(k)))
    return "\\n".join(out)

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=900)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>")
    return (p.returncode, out, err)

def log_text(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return ""
""",
        scope,
    )
    return scope


def _both(
    t: PythonObject, old: String, new: String, args: List[String]
) raises -> String:
    """Runs `args` with both binaries and returns the Mojo run's fallback
    log."""
    var pargs = Python.list()
    var shown = String("")
    for a in args:
        pargs.append(PythonObject(a))
        shown += " " + a
    var o = t["run"](
        PythonObject(FALLBACK), pargs, PythonObject(old), PythonObject("")
    )
    var log = new + ".fallback.log"
    var n = t["run"](
        PythonObject(MOJO), pargs, PythonObject(new), PythonObject(log)
    )
    assert_equal(String(py=n[1]), String(py=o[1]), "stdout of" + shown)
    assert_equal(String(py=n[2]), String(py=o[2]), "stderr of" + shown)
    assert_equal(Int(py=n[0]), Int(py=o[0]), "exit code of" + shown)
    assert_equal(
        String(py=t["tree_diff"](PythonObject(new), PythonObject(old))),
        "",
        "files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log)))


def _each(t: PythonObject, runs: List[List[String]], tag: String) raises:
    var old = String(py=t["fixture"](PythonObject(tag + "-old")))
    var new = String(py=t["fixture"](PythonObject(tag + "-new")))
    for i in range(len(runs)):
        var shown = String("")
        for a in runs[i]:
            shown += " " + a
        assert_equal(_both(t, old, new, runs[i]), "", "fell back on" + shown)
    _ = t["gone"](PythonObject(old))
    _ = t["gone"](PythonObject(new))


def test_servers_match_the_phase1_binary() raises:
    var t = _py()
    var port = String(Int(py=t["free_port"]()))
    var runs = List[List[String]]()
    # The README's curl lines, then traps on their paths, queries and bodies.
    runs.append(["app", "record", ".", "--http", "--", "python3", "srv.py"])
    runs.append(["app", "replay", "."])
    runs.append(["app", "replay", ".", "--build", "env BUG=1 python3 srv.py"])
    # A build that says it counts fallbacks but leaves every request to
    # another process (the report names the port: a fixed one).
    runs.append(
        [
            "app",
            "replay",
            ".",
            "--build",
            "sh absent.sh",
            "--json",
            "--port",
            port,
        ]
    )
    runs.append(["app", "replay", ".", "--case", "example-001-get-hello"])
    runs.append(["app", "replay", ".", "--case", "nope"])
    runs.append(
        [
            "app",
            "replay",
            ".",
            "--build",
            "python3 nothere.py",
            "--port",
            port,
        ]
    )
    # Again from the saved settings, with inputs: names, odd strings, methods.
    runs.append(
        [
            "app",
            "record",
            ".",
            "--no-traps",
            "--inputs",
            "inputs.jsonl",
            "--json",
        ]
    )
    runs.append(["app", "replay", ".", "--json"])
    runs.append(["app", "record", ".", "--inputs", "bad.jsonl"])
    _each(t, runs, "a")


def test_ports_arguments_and_fresh_files() raises:
    var t = _py()
    var port = String(Int(py=t["free_port"]()))
    var runs = List[List[String]]()
    # A fixed port is saved, and used again by the next record and replay.
    runs.append(
        [
            "app",
            "record",
            ".",
            "--port",
            port,
            "--no-traps",
            "--inputs",
            "port.jsonl",
            "--",
            "python3",
            "srv.py",
        ]
    )
    runs.append(["app", "record", ".", "--no-traps", "--inputs", "port.jsonl"])
    runs.append(["app", "replay", ".", "--port", port])
    runs.append(["app", "replay", "."])
    # `{port}` in an argument, and --pace 0 removing a pace.
    runs.append(
        [
            "app",
            "record",
            ".",
            "--pace",
            "0",
            "--arg",
            "--port={port}",
            "--no-traps",
            "--inputs",
            "port.jsonl",
            "--",
            "python3",
            "srv.py",
        ]
    )
    runs.append(["app", "replay", "."])
    _each(t, runs, "b")


def test_fresh_state_and_effects() raises:
    var t = _py()
    var runs = List[List[String]]()
    # State the server writes starts again at every start, from a snapshot.
    runs.append(
        [
            "app",
            "record",
            ".",
            "--inputs",
            "counter.jsonl",
            "--no-traps",
            "--arg",
            "data/count.txt",
            "--fresh",
            "data",
            "--pace",
            "5",
            "--",
            "python3",
            "counter.py",
        ]
    )
    runs.append(["app", "replay", "."])
    # A server's webhook reaches the effects sink.
    runs.append(
        [
            "app",
            "record",
            ".",
            "--inputs",
            "hook.jsonl",
            "--no-traps",
            "--effects",
            "http",
            "--",
            "python3",
            "srv.py",
        ]
    )
    runs.append(["app", "replay", "."])
    runs.append(
        ["app", "replay", ".", "--build", "env NOHOOK=1 python3 srv.py"]
    )
    _each(t, runs, "c")


def main() raises:
    test_servers_match_the_phase1_binary()
    test_ports_arguments_and_fresh_files()
    test_fresh_state_and_effects()
    print("test_app_http: 3 passed")
