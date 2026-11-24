# `bridge --batch` and `refresh --batch` in Mojo (src/codegen_batch.rs,
# codegen_ffi.rs `batch_calls`, codegen_mojo_node.rs's batch classes,
# bridge.rs `parse_batches`, `add_batches` and the BATCH_NOT_YET errors): the
# Mojo binary runs next to the Phase 1 binary on copies of the same
# repository, and the two must agree on stdout, stderr, the exit code and
# every file and folder written, byte for byte, with no fallback logged.

from std.python import Python, PythonObject
from std.testing import assert_equal


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, re, shutil, stat, subprocess, tempfile

BASE = os.path.join(tempfile.gettempdir(), "mojo-anything-test-batch-%d" % os.getpid())
PHASE1 = os.path.abspath("tool/fallback/mojo-anything")
MOJO = os.path.abspath("tool/build/mojo-anything")

def _fixture(side, name, source, files, bridge, port):
    d = os.path.join(BASE, side, name)
    shutil.rmtree(d, ignore_errors=True)
    if source:
        shutil.copytree(source, d, symlinks=True)
    else:
        os.makedirs(d)
    # With a bridge first, the files are written into what it made.
    if bridge:
        p = subprocess.run([PHASE1, "bridge", ".", bridge], cwd=d, capture_output=True,
                           stdin=subprocess.DEVNULL, timeout=300)
        assert p.returncode == 0, p.stderr
    for rel, text in files:
        if rel.startswith("!"):
            os.remove(os.path.join(d, rel[1:]))
            continue
        if rel.startswith("~"):
            old, new = text.split("=>", 1)
            with open(os.path.join(d, rel[1:])) as f:
                body = f.read()
            assert old.replace("<D>", d) in body, (rel, old)
            with open(os.path.join(d, rel[1:]), "w", newline="") as f:
                f.write(body.replace(old.replace("<D>", d), new))
            continue
        p = os.path.join(d, rel)
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", newline="") as f:
            f.write(text)
        if rel.startswith("bin/"):
            os.chmod(p, 0o755)
    for crate, src in port:
        # A port.mojo outside ASCII declines (parse_port_mojo's trims use
        # Unicode tables); the fixtures' one such comment is spelled out.
        with open(os.path.abspath(src), encoding="utf-8") as f:
            text = f.read().replace("\\u0130", "capital I with a dot")
        with open(os.path.join(d, crate, "port.mojo"), "w", newline="") as f:
            f.write(text)
    return d

def _tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for sub in dirs:
            out.append((os.path.relpath(os.path.join(base, sub), d) + "/", b""))
        for f in files:
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read().replace(d.encode(), b"<D>")))
    out.sort()
    return out

def _run(binary, args, cwd, log, path):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if path:
        env["PATH"] = path.replace("<D>", cwd)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([binary] + list(args), cwd=cwd, env=env, stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=600)
    out = p.stdout.decode("utf-8", "replace").replace(cwd, "<D>")
    err = p.stderr.decode("utf-8", "replace").replace(cwd, "<D>")
    err = re.sub(r"thread 'main' \\(\\d+\\)", "thread 'main'", err)
    return (p.returncode, out, err)

def both(name, source, files, bridge, port, cwd, args, path):
    # "" when both binaries agree and nothing fell back; what differs otherwise.
    old = _fixture("old", name, source, files, bridge, port)
    new = _fixture("new", name, source, files, bridge, port)
    o = _run(PHASE1, args, old + cwd, "", path)
    log = new + ".fallback.log"
    n = _run(MOJO, args, new + cwd, log, path)
    shown = " in %s: %s" % (name, " ".join(args))
    for what, a, b in (("stdout", n[1], o[1]), ("stderr", n[2], o[2]), ("exit code", n[0], o[0])):
        if a != b:
            return "%s of%s\\n--- mojo\\n%s\\n--- phase 1\\n%s" % (what, shown, a, b)
    tn, to = _tree(new), _tree(old)
    if tn != to:
        for x, y in zip(tn, to):
            if x != y:
                return "files of%s: %r vs %r" % (shown, x[0], y[0]) + "\\n" + x[1].decode("utf-8", "replace")[:3000] + "\\n---\\n" + y[1].decode("utf-8", "replace")[:3000]
        return "files of%s: %d vs %d entries" % (shown, len(tn), len(to))
    try:
        with open(log) as f:
            fell = f.read()
    except OSError:
        fell = ""
    if fell:
        return "fell back%s" % shown
    if o[0] == 0 and bridge == "" and not any(f == "mojo-anything.json" for _, _, fs in os.walk(new) for f in fs):
        return "nothing was bridged%s" % shown
    return ""

def gone():
    shutil.rmtree(BASE, ignore_errors=True)
""",
        scope,
    )
    return scope


@fieldwise_init
struct Case(Copyable, Movable):
    var name: String
    var source: String
    var files: List[String]
    var bridge: String
    var port: List[String]
    """`crate=fixture` pairs copied over port.mojo after the bridge."""
    var cwd: String
    var args: List[String]
    var path: String
    """PATH for both binaries (`<D>` is the fixture), or "" to keep it."""


def _case(name: String, source: String, var args: List[String]) -> Case:
    return Case(
        name,
        source,
        List[String](),
        "",
        List[String](),
        "",
        args^,
        "",
    )


def _check(t: PythonObject, c: Case) raises:
    var files = Python.list()
    for s in c.files:
        var eq = s.find("=")
        files.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    var port = Python.list()
    for s in c.port:
        var eq = s.find("=")
        port.append(
            Python.tuple(
                PythonObject(String(s[byte=0:eq])),
                PythonObject(String(s[byte = eq + 1 :])),
            )
        )
    var args = Python.list()
    for a in c.args:
        args.append(PythonObject(a))
    var r = String(
        py=t["both"](
            PythonObject(c.name),
            PythonObject(c.source),
            files,
            PythonObject(c.bridge),
            port,
            PythonObject(c.cwd),
            args,
            PythonObject(c.path),
        )
    )
    assert_equal(r, "", c.name)


def _bridge(a: String, b: String) -> List[String]:
    return ["bridge", a, b]


comptime _SCORE = """export function fuzzyScore(text: string, query: string): number {
  return text.indexOf(query);
}

export function shout(s: string, times: number): string {
  return s.toUpperCase().repeat(times);
}

export function flag(n: number): boolean {
  return n > 0;
}

export function log(s: string): void {
  console.log(s);
}
"""

comptime _SCORE_DIR = "tool/tests/data/batch-score"
"""The same project as `_SCORE`, for cases that bridge before writing."""


def _ts(name: String, var args: List[String]) -> Case:
    var c = _case(name, "", args^)
    c.files = ['package.json={"name": "score"}\n', "src/score.ts=" + _SCORE]
    return c^


def _batched(unit: String, specs: List[String]) -> List[String]:
    var out: List[String] = ["bridge", ".", unit]
    for s in specs:
        out += ["--batch", s]
    return out^


def test_bridge_batches_match_the_phase1_binary() raises:
    """TS units get the dispatcher's batch entries and the batch classes
    (Node and wasm); Python and C units keep the batches in the manifest;
    Go, Ruby, Java and Kotlin units answer "not yet"; a spec without a
    colon, a function the port lacks and a parameter it lacks are errors."""
    var t = _py()
    var u = "src/score.ts"
    _check(t, _ts("ts-one", _batched(u, ["fuzzyScore:text"])))
    _check(
        t,
        _ts(
            "ts-many",
            _batched(
                u,
                [
                    "fuzzyScore:text",
                    " shout : s ",
                    "flag:n",
                    "log:s",
                    "fuzzyScore:text",
                ],
            ),
        ),
    )
    var wasm = _batched(u, ["shout:times", "fuzzyScore:query"])
    wasm += ["--kind", "wasm"]
    _check(t, _ts("ts-wasm", wasm^))
    _check(t, _ts("ts-nocolon", _batched(u, ["fuzzyScore"])))
    _check(t, _ts("ts-nofn", _batched(u, ["nope:text"])))
    _check(t, _ts("ts-noparam", _batched(u, ["shout:nope"])))
    var kept = _batched(u, ["shout:s"])
    kept += ["--keep", "shout"]
    _check(t, _ts("ts-kept", kept^))
    _check(
        t,
        _case(
            "py",
            "tests/fixtures/python-mojo",
            _batched("src/mathkit/", ["scale:x", "nope:y"]),
        ),
    )
    _check(
        t,
        _case(
            "c", "tests/fixtures/c", _batched("src/checksum.c", ["clamp:value"])
        ),
    )
    _check(
        t,
        _case(
            "go",
            "tests/fixtures/go-mojo-ports",
            _batched("textkit/textkit.go", ["Echo:s"]),
        ),
    )
    _check(
        t,
        _case(
            "ruby",
            "tests/fixtures/ruby-mojo-ports",
            _batched("textkit/lib/textkit.rb", ["repeat:s"]),
        ),
    )
    _check(
        t,
        _case(
            "java",
            "tests/fixtures/java",
            _batched("src/main/java/com/example/text/", ["slugify:text"]),
        ),
    )
    _ = t["gone"]()


def _refresh(
    name: String,
    source: String,
    bridge: String,
    crate: String,
    specs: List[String],
) -> Case:
    var args: List[String] = ["refresh", crate]
    for s in specs:
        args += ["--batch", s]
    var c = _case(name, source, args^)
    c.bridge = bridge
    return c^


def test_refresh_batches_match_the_phase1_binary() raises:
    """`refresh --batch` adds batches (once each) to the manifest, writes
    it back with a relative root as written, and regenerates; a batch the
    port cannot serve, and a unit kind with no batches yet, leave the
    manifest as it was; a manifest's batches are kept by a plain refresh."""
    var t = _py()
    var crate = "mojo/score-mojo"
    var one = _refresh(
        "r-ts", _SCORE_DIR, "src/score.ts", crate, ["fuzzyScore:text"]
    )
    _check(t, one.copy())
    var twice = one.copy()
    twice.name = "r-ts-twice"
    twice.args += ["--batch", "fuzzyScore:text", "--batch", "shout:s"]
    _check(t, twice^)
    var rel = one.copy()
    rel.name = "r-ts-relative"
    rel.files = [
        String("~", crate, '/mojo-anything.json="root": "<D>"=>"root": "../.."')
    ]
    _check(t, rel^)
    var bad = one.copy()
    bad.name = "r-ts-bad"
    bad.args = ["refresh", crate, "--batch", "shout:nope"]
    _check(t, bad^)
    var nocolon = one.copy()
    nocolon.name = "r-ts-nocolon"
    nocolon.args = ["refresh", crate, "--batch", "shout"]
    _check(t, nocolon^)
    var plain = one.copy()
    plain.name = "r-ts-plain"
    plain.args = ["refresh", crate]
    plain.files = [
        String(
            "~",
            crate,
            (
                '/mojo-anything.json="js_only": []=>"js_only": [],\n '
                ' "batches": [{"function": "shout", "param": "s"}]'
            ),
        )
    ]
    _check(t, plain^)
    _check(t, _case("r-missing", "", ["refresh", "nowhere", "--batch", "a:b"]))
    _check(
        t,
        _refresh(
            "r-go",
            "tests/fixtures/go-mojo-ports",
            "textkit/textkit.go",
            "mojo/textkit-mojo",
            ["Echo:s"],
        ),
    )
    _check(
        t,
        _refresh(
            "r-py",
            "tests/fixtures/python-mojo",
            "src/mathkit/",
            "mojo/mathkit-mojo",
            ["scale:x"],
        ),
    )
    _check(
        t,
        _refresh(
            "r-java",
            "tests/fixtures/java",
            "src/main/java/com/example/text/",
            "mojo/text-mojo",
            ["slugify:text"],
        ),
    )
    _ = t["gone"]()


def main() raises:
    test_bridge_batches_match_the_phase1_binary()
    test_refresh_batches_match_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_batch: 2 passed")
