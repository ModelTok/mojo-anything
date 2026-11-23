# `app record` in Mojo: the Mojo binary records next to the Phase 1 binary
# (tool/fallback/mojo-anything) from copies of the same folder, and the two
# runs must agree byte for byte: stdout, stderr, the exit code and every file
# under mojo/app-cases (the trycmd files in toml_edit's layout and
# mojo-anything.json in serde_json's), with no fallback logged. What this port
# does not record yet must reach the Phase 1 binary before anything is
# written.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"

comptime _NOISY = """import os, sys

p = os.environ.get("COUNTER")
n = 0
if p:
    try:
        with open(p) as f:
            n = int(f.read())
    except OSError:
        n = 0
    with open(p, "w") as f:
        f.write(str(n + 1))
mode = sys.argv[1] if len(sys.argv) > 1 else "none"
odd = n % 2
if mode == "order":
    print("\\n".join(["alpha", "beta", "gamma"] if odd else ["gamma", "alpha", "beta"]))
elif mode == "lines":
    print("head")
    print("x" * (1 + odd))
    if odd:
        print("extra")
    print("tail")
elif mode == "values":
    print(f"run {n} of 2, id {1000 + n}")
elif mode == "file":
    with open("out.txt", "w") as f:
        f.write(f"count {n}\\n")
    print("wrote")
elif mode == "binary":
    sys.stdout.buffer.write(b"\\xff\\xfe" + bytes([n % 256]))
elif mode == "exit":
    sys.exit(n % 2)
elif mode == "remove":
    if os.path.exists("gone.txt"):
        os.remove("gone.txt")
    print("removed", sorted(os.listdir(".")))
elif mode == "env":
    print(os.environ.get("GREETING", "-"))
elif mode == "stdin":
    print(sys.stdin.read().upper(), end="")
elif mode == "time":
    print("at 2024-01-0%dT10:00:00Z" % (1 + odd))
else:
    print("usage", file=sys.stderr)
    sys.exit(2)
"""


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

def fixture(name, src):
    d = os.path.join(tempfile.gettempdir(), "mojo-anything-test-rec-%s-%d" % (name, os.getpid()))
    shutil.rmtree(d, ignore_errors=True)
    if src:
        shutil.copytree(src, d, symlinks=True)
    else:
        os.makedirs(d)
    return d

def put(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)

def gone(path):
    shutil.rmtree(path, ignore_errors=True)

def fresh_dir(path):
    shutil.rmtree(path, ignore_errors=True)
    os.makedirs(path)

def tree(d):
    root = os.path.join(d, "mojo", "app-cases")
    out = []
    for base, dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, root), fh.read()))
    out.sort()
    return repr(out)

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


@fieldwise_init
struct Pair(Copyable, Movable):
    var old: String
    var new: String


def _pair(t: PythonObject, name: String, src: String) raises -> Pair:
    return Pair(
        String(py=t["fixture"](PythonObject(name + "-old"), PythonObject(src))),
        String(py=t["fixture"](PythonObject(name + "-new"), PythonObject(src))),
    )


def _put(t: PythonObject, p: Pair, rel: String, text: String) raises:
    _ = t["put"](PythonObject(p.old + "/" + rel), PythonObject(text))
    _ = t["put"](PythonObject(p.new + "/" + rel), PythonObject(text))


def _record(
    t: PythonObject, p: Pair, args: List[String], reset: String = ""
) raises -> String:
    """Runs `args` with both binaries, each in its own copy, and checks the
    output and the recorded files agree; returns the Mojo run's fallback
    log. `reset` is a folder emptied before each run (the noisy app's
    counters)."""
    var pargs = Python.list()
    var shown = String("")
    for a in args:
        pargs.append(PythonObject(a))
        shown += " " + a
    if reset != "":
        _ = t["fresh_dir"](PythonObject(reset))
    var old = t["run"](
        PythonObject(FALLBACK), pargs, PythonObject(p.old), PythonObject("")
    )
    if reset != "":
        _ = t["fresh_dir"](PythonObject(reset))
    var log = p.new + ".fallback.log"
    var new = t["run"](
        PythonObject(MOJO), pargs, PythonObject(p.new), PythonObject(log)
    )
    assert_equal(String(py=new[1]), String(py=old[1]), "stdout of" + shown)
    assert_equal(String(py=new[2]), String(py=old[2]), "stderr of" + shown)
    assert_equal(Int(py=new[0]), Int(py=old[0]), "exit code of" + shown)
    assert_equal(
        String(py=t["tree"](PythonObject(p.new))),
        String(py=t["tree"](PythonObject(p.old))),
        "recorded files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log)))


def _gone(t: PythonObject, p: Pair) raises:
    _ = t["gone"](PythonObject(p.old))
    _ = t["gone"](PythonObject(p.new))


comptime _TCLI = "mojo/app-cases/app-record-cli-python.in"


def test_a_cli_records_as_the_phase1_binary_does() raises:
    var t = _py()
    var p = _pair(t, "tcli", _TCLI)
    var runs = List[List[String]]()
    runs.append(
        ["app", "record", ".", "--no-traps", "--", "python3", "tcli.py"]
    )
    runs.append(
        [
            "app",
            "record",
            ".",
            "--json",
            "--no-traps",
            "--",
            "python3",
            "tcli.py",
        ]
    )
    # Again from the saved command, with traps this time.
    runs.append(["app", "record", "."])
    runs.append(["app", "record", ".", "--json", "--name", "TCLI"])
    for i in range(len(runs)):
        assert_equal(_record(t, p, runs[i]), "", "fell back")
    _gone(t, p)


def test_names_come_from_the_manifests() raises:
    var t = _py()
    var p = _pair(t, "names", _TCLI)
    _put(t, p, "package.json", '{"name": "x", "bin": {"tool-a": "a.js"}}')
    _put(
        t,
        p,
        "pyproject.toml",
        '[project.scripts]\nTool-B = "m:main"\n',
    )
    _put(t, p, "bin/tcli", "#!/bin/sh\n")
    _put(t, p, "cmd/other/main.go", "package main\n")
    _put(
        t,
        p,
        "docs/usage.md",
        (
            "```sh\ntool-b upper one\nGREETING=hi tool-a len two\n```\n"
            "~~~bash\n$ printf 'a\\nb' | ./bin/tcli words\n~~~\n"
            "```text\ntcli upper skipped\n$ tcli upper kept\n```\n"
            "```\ntcli upper unfenced-lang\n```\n"
        ),
    )
    _put(t, p, "scripts/demo.sh", "$ tcli div 9 4\ntcli words < input.txt\n")
    _put(t, p, "rust/README.md", "```sh\ntcli upper generated\n```\n")
    _put(
        t,
        p,
        "a/b/c/d/deep.md",
        "```sh\ntcli upper too-deep\n```\n",
    )
    _put(t, p, "a/b/c/near.md", "```sh\ntcli upper deep-enough\n```\n")
    _put(t, p, "a-b/x.md", "```sh\ntcli upper dashed\n```\n")
    _put(t, p, "a/x.md", "```sh\ntcli upper plain\n```\n")
    var log = _record(
        t, p, ["app", "record", ".", "--no-traps", "--", "python3", "tcli.py"]
    )
    assert_equal(log, "", "fell back")
    _gone(t, p)


def _noisy(t: PythonObject, name: String) raises -> Pair:
    var p = _pair(t, name, "")
    _put(t, p, "noisy.py", _NOISY)
    return p^


def test_noise_is_merged_as_the_phase1_binary_merges_it() raises:
    var t = _py()
    var p = _noisy(t, "noise")
    var c = (
        String(
            py=t["fixture"](PythonObject("noise-counters"), PythonObject(""))
        )
        + "/"
    )
    var lines = String("")
    var modes: List[String] = [
        "order",
        "lines",
        "values",
        "file",
        "binary",
        "exit",
        "time",
    ]
    for i in range(len(modes)):
        lines += (
            '{"name": "'
            + modes[i]
            + '", "args": ["'
            + modes[i]
            + '"], "env": {"COUNTER": "'
            + c
            + modes[i]
            + '"}}\n'
        )
    lines += (
        '{"args": ["remove"], "files": {"gone.txt": "bye\\n", "keep/a.txt":'
        ' "kept"}, "remove": ["old.txt"]}\n'
    )
    lines += (
        '{"name": "stdin json", "args": ["stdin"], "stdin": "{\\"a\\": 1}"}\n'
    )
    lines += '{"name": "", "args": [], "env": {"GREETING": "hi"}}\n'
    lines += "\n"
    lines += '{"name": "Same Name!", "args": ["env"]}\n'
    lines += '{"name": "same name", "args": ["env", "x"]}\n'
    lines += '{"name": "Same Name!", "args": ["env"]}\n'
    lines += '{"args": ["env"], "env": {"GREETING": "h\\u00e9 there"}}\n'
    _put(t, p, "inputs.jsonl", lines)
    var log = _record(
        t,
        p,
        [
            "app",
            "record",
            ".",
            "--no-traps",
            "--inputs",
            "inputs.jsonl",
            "--normalize",
            "id=id \\d+",
            "--",
            "python3",
            "noisy.py",
        ],
        c,
    )
    assert_equal(log, "", "fell back")
    # Traps of an input with JSON on stdin and of one without (no counters:
    # traps of one base share them).
    _put(
        t,
        p,
        "traps.jsonl",
        (
            '{"args": ["stdin"], "stdin": "[1, 2]"}\n{"args": ["stdin"],'
            ' "stdin": "plain\\n"}\n{"args": ["env", "1.5", "-3", "--x",'
            ' "inf", "word"]}\n'
        ),
    )
    log = _record(
        t,
        p,
        [
            "app",
            "record",
            ".",
            "--inputs",
            "traps.jsonl",
            "--normalize",
            "timestamps",
            "--timeout",
            "60",
        ],
    )
    assert_equal(log, "", "fell back")
    _gone(t, p)
    _ = t["gone"](PythonObject(c))


def test_record_errors_match_the_phase1_binary() raises:
    var t = _py()
    var p = _noisy(t, "errors")
    _put(t, p, "up.jsonl", '{"args": []}\n{"files": {"../x": "y"}}\n')
    _put(t, p, "abs.jsonl", '{"remove": ["/abs"]}\n')
    _put(t, p, "dot.jsonl", '{"files": {"./x": "y", "a": "b"}}\n')
    var base: List[String] = ["app", "record", ".", "--no-traps", "--inputs"]
    var runs = List[List[String]]()
    var files: List[String] = [
        "up.jsonl",
        "abs.jsonl",
        "dot.jsonl",
        "missing.jsonl",
    ]
    for f in files:
        var r = base.copy()
        r.append(f)
        r.append("--")
        r.append("python3")
        r.append("noisy.py")
        runs.append(r^)
    runs.append(["app", "record", ".", "--", "no-such-program-x"])
    for i in range(len(runs)):
        assert_equal(_record(t, p, runs[i]), "", "fell back")
    _gone(t, p)


def test_what_is_not_ported_goes_to_the_phase1_binary() raises:
    var t = _py()
    var p = _noisy(t, "declines")
    _put(t, p, "bad.jsonl", '{"args": ["env"], "bogus": 1}\n')
    _put(t, p, "dup.jsonl", '{"args": ["env"], "args": ["x"]}\n')
    var tail: List[String] = ["--", "python3", "noisy.py"]
    var runs = List[List[String]]()
    runs.append(["app", "record", ".", "--inputs", "bad.jsonl"])
    runs.append(["app", "record", ".", "--inputs", "dup.jsonl"])
    runs.append(["app", "record", ".", "--fresh", "noisy.py"])
    runs.append(["app", "record", ".", "--float-tolerance", "0.1"])
    runs.append(["app", "record", ".", "--float-file", "a=f64le"])
    runs.append(["app", "record", ".", "--normalize", "key-order"])
    runs.append(["app", "record", ".", "--name", 'say "hi"'])
    for i in range(len(runs)):
        var r = runs[i].copy()
        for w in tail:
            r.append(w)
        var log = _record(t, p, r)
        assert_true(log.startswith("app record"), "did not fall back")
    _gone(t, p)


def main() raises:
    test_a_cli_records_as_the_phase1_binary_does()
    test_names_come_from_the_manifests()
    test_noise_is_merged_as_the_phase1_binary_merges_it()
    test_record_errors_match_the_phase1_binary()
    test_what_is_not_ported_goes_to_the_phase1_binary()
    print("test_app_record: 5 passed")
