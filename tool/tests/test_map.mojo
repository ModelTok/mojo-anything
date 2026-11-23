# `map` in Mojo (src/port_map.rs and the `map` arm of src/main.rs): the Mojo
# binary runs next to the Phase 1 binary on copies of the same project; the
# two must agree byte for byte (stdout, stderr, exit code and the files
# written), with no fallback logged where Mojo owns the case and the fallback
# logged where it does not.

from std.python import Python, PythonObject
from std.testing import assert_equal

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

def _base():
    return os.path.join(tempfile.gettempdir(), "mojo-anything-test-map-%d" % os.getpid())

def fixture(side, name, files):
    d = os.path.join(_base(), side, name)
    shutil.rmtree(d, ignore_errors=True)
    os.makedirs(d)
    for rel, text in files:
        p = os.path.join(d, rel)
        if rel.endswith("/"):
            os.makedirs(p, exist_ok=True)
            continue
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w") as f:
            f.write(text)
    return d

def gone():
    shutil.rmtree(_base(), ignore_errors=True)

def tree(d):
    out = []
    for base, dirs, files in os.walk(d):
        for f in files:
            if f.endswith(".fallback.log"):
                continue
            p = os.path.join(base, f)
            with open(p, "rb") as fh:
                out.append((os.path.relpath(p, d), fh.read()))
        for x in dirs:
            out.append((os.path.relpath(os.path.join(base, x), d) + "/", b""))
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
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=300)
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


def _files(spec: List[String]) raises -> PythonObject:
    var out = Python.list()
    for s in spec:
        var eq = s.find("=")
        if eq < 0:
            out.append(Python.tuple(PythonObject(s), PythonObject("")))
        else:
            out.append(
                Python.tuple(
                    PythonObject(String(s[byte=0:eq])),
                    PythonObject(String(s[byte = eq + 1 :])),
                )
            )
    return out


def _both(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises -> String:
    var files = _files(spec)
    var old = String(
        py=t["fixture"](PythonObject("old"), PythonObject(name), files)
    )
    var new = String(
        py=t["fixture"](PythonObject("new"), PythonObject(name), files)
    )
    var pargs = Python.list()
    var shown = String(" in " + name + ":")
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
        String(py=t["tree"](PythonObject(new))),
        String(py=t["tree"](PythonObject(old))),
        "files of" + shown,
    )
    return String(py=t["log_text"](PythonObject(log)))


def _owned(
    t: PythonObject, name: String, spec: List[String], args: List[String]
) raises:
    assert_equal(_both(t, name, spec, args), "", "fell back in " + name)


def test_maps_without_ports_match_the_phase1_binary() raises:
    """No crate under the root and no unit to list: the map says so, as
    Markdown, JSON, a written mojo/PORT_MAP.md, and with `--check`."""
    var t = _py()
    var projects = List[Tuple[String, String]]()
    projects.append(("go-reqs", "go.mod=module x\n"))
    projects.append(("only-mojo", "textops.mojo=def main(): pass\n"))
    projects.append(
        ("ts-pkgs", "package.json={}\n|packages/a/package.json={}\n")
    )
    projects.append(("empty", ""))
    projects.append(("has-mojo-dir", "go.mod=x\n|mojo/notes.txt=x\n"))
    projects.append(("old-map", "go.mod=x\n|mojo/PORT_MAP.md=stale\n"))
    var flags = List[List[String]]()
    flags.append(["map", "."])
    flags.append(["map", ".", "--json"])
    flags.append(["map", ".", "--check"])
    flags.append(["map", ".", "--write"])
    flags.append(["map", ".", "--write", "--check"])
    flags.append(["map", ".", "--json", "--write"])
    flags.append(["map"])
    for pr in projects:
        var spec = List[String]()
        if pr[1].byte_length() > 0:
            for part in pr[1].split("|"):
                spec.append(String(part))
        for f in flags:
            _owned(t, pr[0], spec, f)
    _owned(t, "sub", ["inner/go.mod=x\n"], ["map", "inner", "--json"])
    _owned(t, "sub-write", ["inner/go.mod=x\n"], ["map", "inner/", "--write"])


def test_python_maps_without_ports_match_the_phase1_binary() raises:
    """A Python repository with units and no port: every unit is not ported
    yet, in the order `analyze` suggests (start_here, priority, id)."""
    var t = _py()
    var spec = List[String]()
    spec.append("pyproject.toml=[project]\nname = 'kit'\n")
    for i in range(14):
        var body = String("def f", i, "(s: str) -> str:\n")
        for _ in range(i * 2):
            body += "    s = s[1:] + s.lower()\n"
        if i % 4 == 0:
            body += "    eval(s)\n"
        body += "    return s\n"
        spec.append(String("src/kit/m", i, "/a.py=") + body)
    spec.append("tests/test_m1.py=from kit.m1.a import f1\n")
    var flags = List[List[String]]()
    flags.append(["map", "."])
    flags.append(["map", ".", "--json"])
    flags.append(["map", ".", "--write"])
    flags.append(["map", ".", "--check"])
    for f in flags:
        _owned(t, "python", spec, f)
    _owned(
        t,
        "python-one",
        ["flip.py=def invert(data, keep=False):\n    return data\n"],
        ["map", "."],
    )
    var log = _both(
        t, "python-bad", ["a.py=match x:\n    case 1: pass\n"], ["map", "."]
    )
    assert_equal(log, "map .\n", "fallback of python-bad")


def _java_repo() -> List[String]:
    var spec = List[String]()
    spec.append("pom.xml=<artifactId>kit</artifactId>\n")
    for i in range(6):
        var body = String("package p", i, ";\npublic class M", i, " {\n")
        body += "  public static String f(String s) {\n"
        for _ in range(i * 2):
            body += "    s = s.substring(1) + s.toLowerCase();\n"
        body += "    return s;\n  }\n}\n"
        spec.append(String("src/main/java/p", i, "/M", i, ".java=") + body)
    return spec^


def _go_repo() -> List[String]:
    var spec = List[String]()
    spec.append("go.mod=module example.com/kit\n")
    for i in range(6):
        var body = String("package p", i, "\nfunc F(s string) string {\n")
        for _ in range(i * 2):
            body += "\ts = s[1:] + s\n"
        body += "\treturn s\n}\n"
        spec.append(String("p", i, "/f.go=") + body)
    spec.append(
        'p1/f_test.go=package p1\nimport "example.com/kit/p1"\nfunc T() {}\n'
    )
    return spec^


def _ruby_repo() -> List[String]:
    var spec = List[String]()
    spec.append("kit.gemspec=spec.add_dependency 'nokogiri'\n")
    for i in range(6):
        var body = String("module M", i, "\n  def self.f(s)\n")
        for _ in range(i * 2):
            body += "    s = s[1..] + s\n"
        body += "    s\n  end\nend\n"
        spec.append(String("lib/m", i, ".rb=") + body)
    spec.append("test/m1_test.rb=require 'm1'\n")
    return spec^


def _csharp_repo() -> List[String]:
    var spec = List[String]()
    spec.append("Kit.csproj=<Project></Project>\n")
    for i in range(6):
        var body = String("namespace Kit.M", i, ";\npublic class M", i, " {\n")
        body += "  public static string F(string s) {\n"
        for _ in range(i * 2):
            body += "    s = s.Substring(1) + s;\n"
        body += "    return s;\n  }\n}\n"
        spec.append(String("M", i, "/M.cs=") + body)
    spec.append("M1Tests.cs=using Kit.M1;\nclass M1Tests {}\n")
    return spec^


def test_tree_sitter_maps_without_ports_match_the_phase1_binary() raises:
    """Repositories of the languages read through tree-sitter, with units
    and no port, and ones whose tree has an error (the Phase 1 binary's)."""
    var t = _py()
    var repos = List[Tuple[String, List[String]]]()
    repos.append(("java", _java_repo()))
    repos.append(("go", _go_repo()))
    repos.append(("ruby", _ruby_repo()))
    repos.append(("csharp", _csharp_repo()))
    var flags = List[List[String]]()
    flags.append(["map", "."])
    flags.append(["map", ".", "--json"])
    flags.append(["map", ".", "--write"])
    flags.append(["map", ".", "--check"])
    for r in repos:
        for f in flags:
            _owned(t, r[0], r[1], f)
    var bad = List[Tuple[String, String]]()
    bad.append(("java-bad", "pom.xml=x\n|A.java=class A { int f( }\n"))
    bad.append(("ruby-bad", "Gemfile=x\n|a.rb=def f(\n"))
    bad.append(("csharp-bad", "Kit.csproj=x\n|A.cs=class A { int F( }\n"))
    bad.append(("go-bad", "go.mod=module b\n|a.go=package b\nfunc F( {\n"))
    for c in bad:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        assert_equal(
            _both(t, c[0], spec, ["map", "."]), "map .\n", "fallback of " + c[0]
        )


def test_a_missing_repository_is_an_error_as_in_rust() raises:
    var t = _py()
    var empty = List[String]()
    _owned(t, "missing", empty, ["map", "missing-dir"])
    _owned(t, "missing-json", empty, ["map", "missing-dir", "--json"])


def test_what_is_not_ported_goes_to_the_phase1_binary() raises:
    """Ports, source files, glue and `--crates` still run the Phase 1 binary,
    and it answers them."""
    var t = _py()
    var cases = List[Tuple[String, String]]()
    cases.append(("crate", "go.mod=x\n|port/mojo-anything.json={}\n"))
    cases.append(("source", "package.json={}\n|a.ts=export const x = 1;\n"))
    cases.append(("glue", "go.mod=x\n|mojo/app/glue/a.mojo=x\n"))
    cases.append(("bad-json", "package.json={\n"))
    for c in cases:
        var spec = List[String]()
        for part in c[1].split("|"):
            spec.append(String(part))
        assert_equal(
            _both(t, c[0], spec, ["map", "."]), "map .\n", "fallback of " + c[0]
        )
    var log = _both(
        t, "crates", ["go.mod=x\n", "c/"], ["map", ".", "--crates", "c"]
    )
    assert_equal(log, "map .\n", "fallback of --crates")


def main() raises:
    test_maps_without_ports_match_the_phase1_binary()
    test_python_maps_without_ports_match_the_phase1_binary()
    test_tree_sitter_maps_without_ports_match_the_phase1_binary()
    test_a_missing_repository_is_an_error_as_in_rust()
    test_what_is_not_ported_goes_to_the_phase1_binary()
    _ = _py()["gone"]()
    print("test_map: 5 passed")
