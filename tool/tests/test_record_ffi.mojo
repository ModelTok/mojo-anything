# `record` of Go and Ruby units in Mojo (src/harness.rs `record` for those
# languages, src/harness_go.rs and src/harness_ruby.rs `record`, the `record`
# arm of src/main.rs): a unit is bridged by the Phase 1 binary on two copies
# of a fixture, then each binary records one copy; stdout, stderr, the exit
# code and every file must agree, with no fallback logged. The Go driver
# binary `go build` writes is compared by presence only: its build ID hashes
# the folder it was built in.

from std.python import Python, PythonObject
from std.testing import assert_equal

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-record-ffi-%d" % os.getpid())
PHASE1 = os.path.abspath("tool/fallback/mojo-anything")

def write(d, files):
    # "!gone" removes a file; "!sub OLD=>NEW" replaces text in it.
    for rel, text in files:
        p = os.path.join(d, rel)
        if text == "!gone":
            os.remove(p)
            continue
        if text.startswith("!sub "):
            old, new = text[5:].split("=>")
            with open(p) as f:
                body = f.read()
            assert old in body, (p, old)
            text = body.replace(old, new)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="") as f:
            f.write(text)

def fixture(side, name, source, before, bridge, after):
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    shutil.copytree(source, d, symlinks=True)
    write(d, before)
    p = subprocess.run([PHASE1, "bridge", ".", bridge], cwd=d, capture_output=True,
                       stdin=subprocess.DEVNULL, timeout=300)
    assert p.returncode == 0, p.stderr
    write(d, after)
    return d

def gone():
    shutil.rmtree(BASE, ignore_errors=True)

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for sub in dirs:
            out.append((os.path.relpath(os.path.join(base, sub), d) + "/", b""))
        for f in files:
            p = os.path.join(base, f)
            rel = os.path.relpath(p, d)
            if rel.endswith(".mojo-anything/go-original/driver"):
                out.append((rel, b"<go binary>"))
                continue
            with open(p, "rb") as fh:
                out.append((rel, fh.read().replace(d.encode(), b"<D>")))
    out.sort()
    return out

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    env.pop("MOJO_ANYTHING_CASE_TIMEOUT", None)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=900)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>")
    return (p.returncode, out, err)

def both(name, source, before, bridge, after, args):
    # "" when both binaries agree and nothing fell back; what differs otherwise.
    old = fixture("old", name, source, before, bridge, after)
    new = fixture("new", name, source, before, bridge, after)
    o = run(PHASE1, args, old, "")
    log = new + ".fallback.log"
    n = run("tool/build/mojo-anything", args, new, log)
    shown = " in %s: %s" % (name, " ".join(args))
    for what, a, b in (("stdout", n[1], o[1]), ("stderr", n[2], o[2]), ("exit code", n[0], o[0])):
        if a != b:
            return "%s of%s\\n--- mojo\\n%s\\n--- phase 1\\n%s" % (what, shown, a, b)
    tn, to = tree(new), tree(old)
    if tn != to:
        for x, y in zip(tn, to):
            if x != y:
                return "files of%s: %r vs %r\\n%s\\n---\\n%s" % (
                    shown, x[0], y[0], x[1].decode("utf-8", "replace")[:3000],
                    y[1].decode("utf-8", "replace")[:3000])
        return "files of%s: %d vs %d entries" % (shown, len(tn), len(to))
    try:
        with open(log) as f:
            if f.read():
                return "fell back%s" % shown
    except OSError:
        pass
    if o[0] == 0 and not any(f == "cases.jsonl" for _, _, fs in os.walk(new) for f in fs):
        return "nothing was recorded%s" % shown
    return ""
""",
        scope,
    )
    return scope


@fieldwise_init
struct Case(Copyable, Movable):
    var name: String
    var source: String
    var bridge: String
    var before: List[String]
    """`path=text` files written before the bridge."""
    var after: List[String]
    """`path=text` files written after it."""
    var args: List[String]


def _pairs(items: List[String]) raises -> PythonObject:
    var out = Python.list()
    for s in items:
        var eq = s.find("=")
        out.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    return out


def _check(t: PythonObject, c: Case) raises:
    var args = Python.list()
    for a in c.args:
        args.append(PythonObject(a))
    var r = String(
        py=t["both"](
            PythonObject(c.name),
            PythonObject(c.source),
            _pairs(c.before),
            PythonObject(c.bridge),
            _pairs(c.after),
            args,
        )
    )
    assert_equal(r, "", c.name)


def _case(
    name: String,
    source: String,
    bridge: String,
    crate: String,
    var extra: List[String],
) -> Case:
    var args: List[String] = ["record", crate]
    args += extra^
    return Case(name, source, bridge, List[String](), List[String](), args^)


comptime _GO = "tests/fixtures/go-mojo-ports"
comptime _GO_UNIT = "textkit/textkit.go"
comptime _RB = "tests/fixtures/ruby-mojo-ports"
comptime _RB_UNIT = "textkit/lib/textkit.rb"
comptime _CRATE = "mojo/textkit-mojo"


def test_go_records_match_the_phase1_binary() raises:
    """A Go unit at a small count and at the default one, with `--inputs`
    (the fixture's lines, one that names no export), a package with no
    go.mod above it and one that does not build."""
    var t = _py()
    _check(t, _case("go", _GO, _GO_UNIT, _CRATE, ["--count", "20"]))
    _check(t, _case("go-default", _GO, _GO_UNIT, _CRATE, []))
    _check(
        t,
        _case(
            "go-inputs",
            _GO,
            _GO_UNIT,
            _CRATE,
            ["--count", "3", "--inputs", "inputs.jsonl"],
        ),
    )
    var bad = _case(
        "go-bad-input",
        _GO,
        _GO_UNIT,
        _CRATE,
        ["--count", "3", "--inputs", "bad.jsonl"],
    )
    bad.after = ['bad.jsonl={"fn": "Nope", "args": [1]}\n']
    _check(t, bad^)
    var nomod = _case("go-nomod", _GO, _GO_UNIT, _CRATE, ["--count", "3"])
    nomod.after = ["textkit/go.mod=!gone"]
    _check(t, nomod^)
    var broken = _case("go-broken", _GO, _GO_UNIT, _CRATE, ["--count", "3"])
    broken.after = [
        "textkit/textkit.go=!sub package textkit=>package textkit\nvar x int ="
        ' "no"'
    ]
    _check(t, broken^)
    var std = _case(
        "go-strkit",
        "tests/fixtures/go",
        "strkit/strkit.go",
        "mojo/strkit-mojo",
        ["--count", "10"],
    )
    _check(t, std^)
    _ = t["gone"]()


def test_ruby_records_match_the_phase1_binary() raises:
    """A Ruby unit at a small count and at the default one, with `--inputs`
    (the fixture's lines, one that names no export), a gem with `lib/` on
    the load path, and a source that does not load."""
    var t = _py()
    _check(t, _case("rb", _RB, _RB_UNIT, _CRATE, ["--count", "20"]))
    _check(t, _case("rb-default", _RB, _RB_UNIT, _CRATE, []))
    _check(
        t,
        _case(
            "rb-inputs",
            _RB,
            _RB_UNIT,
            _CRATE,
            ["--count", "3", "--inputs", "inputs.jsonl"],
        ),
    )
    var bad = _case(
        "rb-bad-input",
        _RB,
        _RB_UNIT,
        _CRATE,
        ["--count", "3", "--inputs", "bad.jsonl"],
    )
    bad.after = ['bad.jsonl={"fn": "nope", "args": [1]}\n']
    _check(t, bad^)
    var broken = _case("rb-broken", _RB, _RB_UNIT, _CRATE, ["--count", "3"])
    broken.after = [
        "textkit/lib/textkit.rb=!sub module=>raise 'broken'\nmodule"
    ]
    _check(t, broken^)
    _check(
        t,
        _case(
            "rb-gem",
            "tests/fixtures/ruby",
            "lib/textkit/words.rb",
            "mojo/words-mojo",
            ["--count", "10"],
        ),
    )
    _ = t["gone"]()


def main() raises:
    test_go_records_match_the_phase1_binary()
    test_ruby_records_match_the_phase1_binary()
    print("test_record_ffi: 2 passed")
