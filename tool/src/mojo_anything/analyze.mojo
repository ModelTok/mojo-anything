# `analyze`: the migration plan of a repository (port of src/analyze.rs,
# src/report.rs, Lang::detect in src/lang/mod.rs and the discovery halves of
# src/ts/discover.rs and src/lang/*.rs).
#
# Slice 1 answers the workspaces with no source file of their language: the
# language is detected as the Rust tool detects it, each language's discovery
# counts the packages its manifests make, and the plan is the empty one, in
# Markdown or JSON, on stdout or in `--out`. A root that is missing or a file
# gets the Rust tool's error. Everything else goes to the Phase 1 binary
# before anything is written (`fallback`): a file with one of the language's
# source extensions anywhere under the root (in any case, ignored, hidden or
# not), a compiled or packaged file (the plan would carry a warning), an
# unreadable folder or a name that is not ASCII, a `package.json` serde_json
# might read otherwise than Python's json, an ignore file in a TS workspace
# with a pattern globset might refuse (the ignore crate's error stops a TS
# walk), and `--whole-app`.

from std.os import listdir
from std.os.path import exists, isdir, isfile, islink
from std.python import Python, PythonObject

from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback
from mojo_anything.plan import (
    Package,
    Report,
    SourceFile,
    build,
    join_dir,
    markdown,
    to_json,
    trim_end_matches,
)
from mojo_anything.python_lang import Facts, py_helpers, read_facts
from mojo_anything.tree_lang import read_tree_facts, tree_helpers
from mojo_anything.walk import canonical, walk

comptime SCHEMA = "mojo-anything/analyze@1"

comptime _PY = """
import json, os

def _ascii(name):
    try:
        name.encode("ascii")
        return True
    except UnicodeError:
        return False

def scan(root, exts):
    # 0: nothing under root has one of `exts` or a compiled extension, every
    # folder was read and every name is ASCII; 1: decline.
    if not os.path.lexists(root):
        return 0
    if not os.path.isdir(root):
        return 1
    bad = []
    def onerror(e):
        bad.append(e)
    for base, dirs, files in os.walk(root, onerror=onerror):
        for name in dirs + files:
            if not _ascii(name):
                return 1
            dot = name.rfind(".")
            if dot >= 0 and name[dot + 1:].lower() in exts:
                return 1
    return 1 if bad else 0

def ignore_files(root, ts):
    # 1 when an ignore file under root holds alternates (globset reads them,
    # walk.mojo does not) or a trailing escape, or cannot be read as UTF-8;
    # in a TS workspace also a class (a pattern globset may refuse stops the
    # TS walk with an error).
    special = "[]{}" if ts else "{}"
    for base, dirs, files in os.walk(root):
        for name in dirs + files:
            if not (name in (".gitignore", ".ignore") or (name == "exclude" and base.endswith("/.git/info"))):
                continue
            try:
                with open(os.path.join(base, name), "rb") as f:
                    text = f.read().decode("utf-8")
            except (OSError, UnicodeError):
                return 1
            for line in text.split("\\n"):
                if line.startswith("#"):
                    continue
                if any(c in line for c in special) or line.rstrip("\\r").endswith("\\\\"):
                    return 1
    return 0

def _depth(text):
    depth = best = 0
    in_str = esc = False
    for c in text:
        if in_str:
            if esc:
                esc = False
            elif c == "\\\\":
                esc = True
            elif c == '"':
                in_str = False
        elif c == '"':
            in_str = True
        elif c in "[{":
            depth += 1
            best = max(best, depth)
        elif c in "]}":
            depth -= 1
    return best

def _const(name):
    raise ValueError(name)

def _finite(v):
    if isinstance(v, float):
        return v == v and v not in (float("inf"), float("-inf"))
    if isinstance(v, int) and not isinstance(v, bool):
        # serde_json reads an integer beyond u64/i64 as f64: out of range
        # past f64's largest.
        try:
            return float(v) not in (float("inf"), float("-inf"))
        except OverflowError:
            return False
    if isinstance(v, list):
        return all(_finite(x) for x in v)
    if isinstance(v, dict):
        return all(_finite(x) for x in v.values())
    return True

def serde_reads(path):
    # 1 when serde_json::from_str::<Value> reads the file as Python's json
    # does (a JSON value), 0 when it may not.
    try:
        with open(path, "rb") as f:
            text = f.read().decode("utf-8")
    except (OSError, UnicodeError):
        return 0
    lower = text.lower()
    if "\\\\ud8" in lower or "\\\\ud9" in lower or "\\\\uda" in lower or "\\\\udb" in lower:
        return 0
    if "\\\\udc" in lower or "\\\\udd" in lower or "\\\\ude" in lower or "\\\\udf" in lower:
        return 0
    if _depth(text) > 100:
        return 0
    try:
        v = json.loads(text, parse_constant=_const)
    except (ValueError, RecursionError):
        return 0
    return 1 if _finite(v) else 0

def root_state(root):
    # "dir", "file", "missing" (nothing there: ENOENT on lstat) or "other".
    try:
        os.lstat(root)
    except FileNotFoundError:
        return "missing"
    except OSError:
        return "other"
    if os.path.islink(root):
        return "other"
    if os.path.isfile(root):
        return "file"
    if os.path.isdir(root):
        return "dir"
    return "other"

def write(path, text):
    try:
        with open(path, "w", encoding="utf-8", newline="") as f:
            f.write(text)
        return 1
    except OSError:
        return 0
"""


def _helpers() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(_PY, scope)
    return scope


def all_langs() -> List[String]:
    """Lang::ALL, in its order (ties in detection go to the earliest)."""
    return [
        "ts",
        "python",
        "c",
        "go",
        "ruby",
        "java",
        "kotlin",
        "php",
        "csharp",
        "cpp",
    ]


def lang_name(lang: String) -> String:
    if lang == "ts":
        return "TypeScript/JavaScript"
    if lang == "python":
        return "Python"
    if lang == "c":
        return "C"
    if lang == "cpp":
        return "C++"
    if lang == "go":
        return "Go"
    if lang == "ruby":
        return "Ruby"
    if lang == "java":
        return "Java"
    if lang == "kotlin":
        return "Kotlin"
    if lang == "php":
        return "PHP"
    return "C#"


def extensions(lang: String) -> List[String]:
    """Lang::extensions: the language's source file extensions."""
    if lang == "ts":
        return [
            "ts",
            "mts",
            "cts",
            "js",
            "mjs",
            "cjs",
            "tsx",
            "jsx",
            "vue",
            "svelte",
            "astro",
        ]
    if lang == "python":
        return ["py"]
    if lang == "c":
        return ["c", "h"]
    if lang == "go":
        return ["go"]
    if lang == "ruby":
        return ["rb"]
    if lang == "java":
        return ["java"]
    if lang == "kotlin":
        return ["kt"]
    if lang == "php":
        return ["php"]
    if lang == "csharp":
        return ["cs"]
    return ["cpp", "cc", "cxx", "hpp", "hh", "hxx"]


def _compiled() -> List[String]:
    """COMPILED in src/analyze.rs."""
    return [
        "apk",
        "aab",
        "ipa",
        "xapk",
        "jar",
        "war",
        "aar",
        "class",
        "dex",
        "exe",
        "dll",
        "so",
        "dylib",
        "wasm",
        "pyc",
        "msi",
        "appimage",
    ]


def _compiled_hint() -> String:
    return (
        "mojo-anything ports source code: it parses functions, records what"
        " they do, and checks the Rust port against the running original. A"
        " compiled app (an APK, a JAR, an .exe) has no source to port and no"
        " way to record it function by function. Point it at the app's source"
        " folder instead; for an app you only have as a binary, writing a new"
        " Rust app from its visible behavior is a separate project"
    )


def _name_of(path: String) -> String:
    var slash = path.rfind("/")
    if slash < 0:
        return path
    return String(path[byte = slash + 1 :])


def _extension(name: String) -> String:
    """Path::extension of a file name ("" for none)."""
    var dot = name.rfind(".")
    if dot <= 0:
        return ""
    return String(name[byte = dot + 1 :])


def _file_name(path: String) -> String:
    """Path::file_name: the last normal component ("" for none: `..`, `/`);
    trailing `/` and `.` components are not components."""
    var parts = List[String]()
    for p in path.split("/"):
        var s = String(p)
        if s.byte_length() > 0 and s != ".":
            parts.append(s)
    if len(parts) == 0 or parts[len(parts) - 1] == "..":
        return ""
    return parts[len(parts) - 1]


def _keep(path: String) -> Bool:
    return True


def _ascii(s: String) -> Bool:
    for b in s.as_bytes():
        if b > 127:
            return False
    return True


def _rel(root: String, path: String) -> String:
    """`path` (`root/...`, as walk gives it) relative to `root`."""
    return String(path[byte = root.byte_length() + 1 :])


def _parts(rel: String) -> List[String]:
    var out = List[String]()
    for p in rel.split("/"):
        if p.byte_length() > 0:
            out.append(String(p))
    return out^


def _skip_dirs(lang: String) -> List[String]:
    """Each discovery's SKIP_DIRS."""
    if lang == "ts":
        return [
            "node_modules",
            "dist",
            "build",
            "out",
            "target",
            "coverage",
            "fixtures",
            "__fixtures__",
            "__snapshots__",
            "playground",
            "examples",
        ]
    if lang == "python":
        return [
            "node_modules",
            "venv",
            ".venv",
            "env",
            "__pycache__",
            "build",
            "dist",
            "site-packages",
            ".tox",
            ".nox",
            "target",
            "fixtures",
            "examples",
            "docs",
        ]
    if lang == "c" or lang == "cpp":
        return [
            "build",
            "dist",
            "target",
            "vendor",
            "third_party",
            "external",
            "fixtures",
            "examples",
            "docs",
        ]
    if lang == "csharp":
        return [
            "bin",
            "obj",
            ".vs",
            "packages",
            "TestResults",
            "node_modules",
            "artifacts",
        ]
    if lang == "go":
        return ["vendor", "testdata", "node_modules", "target", ".git"]
    if lang == "java":
        return [
            "target",
            "build",
            "out",
            ".gradle",
            ".idea",
            "node_modules",
            "bin",
        ]
    if lang == "kotlin":
        return [
            "build",
            ".gradle",
            ".idea",
            "out",
            "target",
            "node_modules",
            "bin",
            ".kotlin",
        ]
    if lang == "php":
        return [
            "vendor",
            "node_modules",
            "var",
            "storage",
            "cache",
            "target",
            ".phpunit.cache",
        ]
    # ruby
    return [
        "vendor",
        "node_modules",
        "tmp",
        "log",
        "coverage",
        "pkg",
        "target",
        ".bundle",
    ]


def _src_component(path: String) -> Bool:
    for p in path.split("/"):
        if p == "src":
            return True
    return False


def _pruned(lang: String, root: String, dirs: List[String]) -> Bool:
    """Whether discovery's filter prunes one of these folders (relative paths
    of a file's ancestors, outermost first). A pruned folder's files are never
    seen, so filtering after the walk equals filtering during it."""
    var skip = _skip_dirs(lang)
    for d in dirs:
        var name = _name_of(d)
        if lang == "kotlin":
            # kotlin.rs keeps a skipped folder whose path (e.path(), the root
            # included) has no `src` component and prunes one that has: the
            # reverse of its comment, but what its walk does.
            if name in skip and _src_component(root + "/" + d):
                return True
        elif lang == "go":
            if name in skip or name.startswith("_"):
                return True
        elif name in skip:
            return True
    return False


def _ancestors(rel: String) -> List[String]:
    var parts = _parts(rel)
    var out = List[String]()
    var acc = String("")
    for i in range(len(parts) - 1):
        if i > 0:
            acc += "/"
        acc += parts[i]
        out.append(acc)
    return out^


def _files(lang: String, root: String) -> List[String]:
    """The files discovery's walk sees (relative, sorted): hidden entries
    skipped, ignore rules read without requiring git, bridge crates and the
    language's SKIP_DIRS pruned."""
    var out = List[String]()
    for path in walk(root, _keep, False):
        var rel = _rel(root, path)
        if not _pruned(lang, root, _ancestors(rel)):
            out.append(rel)
    return out^


def _dir_of(rel: String) -> String:
    var slash = rel.rfind("/")
    if slash < 0:
        return ""
    return String(rel[byte=0:slash])


def _is_manifest(lang: String, name: String) -> Bool:
    if lang == "ts":
        return name == "package.json"
    if lang == "python":
        return (
            name == "pyproject.toml"
            or name == "setup.py"
            or name == "setup.cfg"
        )
    if lang == "c" or lang == "cpp":
        return (
            name == "Makefile"
            or name == "CMakeLists.txt"
            or name == "meson.build"
        )
    if lang == "go":
        return name == "go.mod"
    if lang == "ruby":
        return name.endswith(".gemspec") or name == "Gemfile"
    if lang == "java" or lang == "kotlin":
        return (
            name == "pom.xml"
            or name == "build.gradle"
            or name == "build.gradle.kts"
        )
    if lang == "php":
        return name == "composer.json"
    return name.endswith(".csproj")


def _root_only_when_none(lang: String) -> Bool:
    """Go, Java, Kotlin and C# add a root package only when no manifest made
    one; the others add it whenever no package sits at the root."""
    return (
        lang == "go" or lang == "java" or lang == "kotlin" or lang == "csharp"
    )


struct Discovery(Copyable, Movable):
    var packages: Int
    var declined: Bool

    def __init__(out self, packages: Int, declined: Bool):
        self.packages = packages
        self.declined = declined


def discover_packages(
    lang: String, root: String, py: PythonObject
) raises -> Discovery:
    """How many packages the language's discovery makes, for a workspace with
    no source file. Each manifest's folder is one package (a folder holding
    two manifests is still one), plus the root's."""
    var dirs = List[String]()
    for rel in _files(lang, root):
        var name = _name_of(rel)
        if not _is_manifest(lang, name):
            continue
        if lang == "ts":
            if Int(py=py["serde_reads"](PythonObject(root + "/" + rel))) != 1:
                return Discovery(0, True)
        var dir = _dir_of(rel)
        if not dir in dirs:
            dirs.append(dir)
    var n = len(dirs)
    if _root_only_when_none(lang):
        return Discovery(max(n, 1), False)
    if not "" in dirs:
        n += 1
    return Discovery(n, False)


def _has(root: String, name: String) -> Bool:
    return exists(root + "/" + name)


def detect_lang(root: String) -> String:
    """Lang::detect: from the manifest files, else the most common source
    files."""
    if _has(root, "go.mod"):
        return "go"
    if (
        _has(root, "pom.xml")
        or _has(root, "build.gradle")
        or _has(root, "build.gradle.kts")
    ):
        if not _has(root, "pom.xml"):
            var kt = 0
            var java = 0
            var skip: List[String] = [
                "build",
                ".gradle",
                ".kotlin",
                "out",
                "node_modules",
                "target",
            ]
            for path in walk(root, _keep, False):
                var rel = _rel(root, path)
                var pruned = False
                for d in _ancestors(rel):
                    # Lang::detect keeps a skipped folder with no `src`
                    # component below the root and prunes one with it (the
                    # reverse of its comment, but what its walk does).
                    if _name_of(d) in skip and _src_component(d):
                        pruned = True
                if pruned:
                    continue
                var ext = _extension(_name_of(rel))
                if ext == "kt":
                    kt += 1
                elif ext == "java":
                    java += 1
            if kt > 0 and java == 0:
                return "kotlin"
        return "java"
    var dotnet = False
    try:
        for name in listdir(root):
            if (
                name.endswith(".csproj")
                or name.endswith(".sln")
                or name.endswith(".slnx")
            ):
                dotnet = True
    except:
        pass
    if dotnet or _has(root, "Directory.Build.props"):
        return "csharp"
    if (
        _has(root, "pyproject.toml")
        or _has(root, "setup.py")
        or _has(root, "setup.cfg")
    ):
        return "python"
    if _has(root, "Gemfile"):
        return "ruby"
    if _has(root, "composer.json"):
        return "php"
    if _has(root, "package.json"):
        return "ts"
    var langs = all_langs()
    var counts = List[Int]()
    for _ in range(len(langs)):
        counts.append(0)
    var c_sources = 0
    var headers = 0
    for path in walk(root, _keep, False):
        var ext = _extension(_name_of(path))
        if ext == "c":
            c_sources += 1
        elif ext == "h":
            headers += 1
        for i in range(len(langs)):
            if ext in extensions(langs[i]):
                counts[i] += 1
                break
    # `.h` headers count for C, unless the project has C++ sources and no C
    # ones.
    if counts[9] > 0 and c_sources == 0:
        counts[2] -= headers
        counts[9] += headers
    var best = 0
    for i in range(len(langs)):
        if counts[i] > counts[best]:
            best = i
    return langs[best]


def _title(root: String) -> String:
    """The canonical root's folder name, else the root as given."""
    if not exists(root):
        return root
    var c = canonical(root)
    if c == "/" or c.byte_length() == 0:
        return root
    return _name_of(c)


def empty_markdown(lang: String, title: String, packages: Int) -> String:
    """report::markdown of a plan with no units."""
    var out = String(
        "# Rust migration plan: ", title, " (", lang_name(lang), ")\n\n"
    )
    out += String(
        packages,
        (
            " packages, 0 source files (0 lines), 0 test files, 0 UI files,"
            " grouped into 0 units.\n\n"
        ),
    )
    out += "| Ready | Caution | Blocked | Keep in source language |\n"
    out += "| ---: | ---: | ---: | ---: |\n"
    out += "| 0 | 0 | 0 | 0 |\n\n"
    out += "## Start here\n\n"
    out += (
        "No unit is a safe first port yet. See the blocked units and"
        " dependencies below.\n\n"
    )
    out += "## Order by package\n\n"
    out += (
        "Packages come after the workspace packages they use. Inside a"
        " package, port by wave: a unit's imports are in earlier waves.\n\n"
    )
    out += "## Risk guide\n\n"
    return out^


def empty_json(lang: String, packages: Int) -> String:
    """serde_json::to_string_pretty of a plan with no units, and a newline."""
    var out = String("{\n")
    out += '  "schema": "' + String(SCHEMA) + '",\n'
    out += '  "language": "' + lang + '",\n'
    out += '  "summary": {\n'
    out += String('    "packages": ', packages, ",\n")
    var keys: List[String] = [
        "source_files",
        "test_files",
        "ui_files",
        "loc",
        "units",
        "ready",
        "caution",
        "blocked",
        "keep",
    ]
    for key in keys:
        out += '    "' + key + '": 0,\n'
    out += '    "parse_errors": 0\n'
    out += "  },\n"
    out += '  "packages": [],\n'
    out += '  "units": [],\n'
    out += '  "start_here": [],\n'
    out += '  "dependencies": []\n'
    out += "}\n"
    return out^


def helpers() raises -> PythonObject:
    return _helpers()


def empty_workspace(
    lang: String, root: String, py: PythonObject
) raises -> Discovery:
    """For an existing folder: its package count when `analyze` finds no
    source file of `lang` there and writes no warning (the empty plan), else
    declined."""
    var exts = Python.list()
    for e in extensions(lang):
        exts.append(PythonObject(e))
    if lang == "cpp":
        exts.append(PythonObject("h"))
    for e in _compiled():
        exts.append(PythonObject(e))
    if Int(py=py["scan"](PythonObject(root), exts)) != 0:
        return Discovery(0, True)
    var ts = PythonObject(lang == "ts")
    if Int(py=py["ignore_files"](PythonObject(root), ts)) != 0:
        return Discovery(0, True)
    return discover_packages(lang, root, py)


def _is_test_py(rel: String, name: String) -> Bool:
    if name.startswith("test_") or name.endswith("_test.py"):
        return True
    for part in rel.split("/"):
        if part == "tests" or part == "test" or part == "testing":
            return True
    return False


def _root_name(root: String) -> String:
    """`root.file_name()`, else "root"."""
    var name = _file_name(root)
    if name.byte_length() == 0:
        return "root"
    return name


struct Workspace(Movable):
    var packages: List[Package]
    var files: List[SourceFile]
    var declined: Bool

    def __init__(out self):
        self.packages = List[Package]()
        self.files = List[SourceFile]()
        self.declined = False


def python_workspace(root: String, py: PythonObject) raises -> Workspace:
    """python.rs `discover`: a package per folder with a pyproject.toml,
    setup.py or setup.cfg (plus the root's), and the `.py` files the walk
    keeps; declined for a name outside ASCII or holding a backslash, and for
    a pyproject.toml or requirements.txt tomllib or Rust's character tables
    may read otherwise. With no source file, no package is read and the
    workspace is left empty."""
    var ws = Workspace()
    var manifests = List[String]()
    var found = List[String]()
    var tests = List[Bool]()
    var odd = False
    for rel in _files("python", root):
        if not _ascii(rel) or "\\" in rel:
            odd = True
        var name = _name_of(rel)
        if (
            name == "pyproject.toml"
            or name == "setup.py"
            or name == "setup.cfg"
        ):
            var dir = _dir_of(rel)
            if not dir in manifests:
                manifests.append(dir)
        elif name.endswith(".py") and name != "conftest.py":
            found.append(rel)
            tests.append(_is_test_py(rel, name))
    if len(found) == 0:
        # No source file: the empty plan's path (empty_workspace) answers.
        return ws^
    if odd:
        ws.declined = True
        return ws^
    var has_root = False
    for dir in manifests:
        var r = py["read_package"](
            PythonObject(root + "/" + join_dir(dir, "pyproject.toml")),
            PythonObject(root + "/" + join_dir(dir, "requirements.txt")),
        )
        if Int(py=r[0]) != 1:
            ws.declined = True
            return ws^
        var name: String
        if Int(py=r[1]) == 1:
            name = String(py=r[2])
        elif dir.byte_length() == 0:
            name = _root_name(root)
        else:
            name = dir
        var deps = List[String]()
        for i in range(Int(py=Python.import_module("builtins").len(r[3]))):
            deps.append(String(py=r[3][i]))
        var src = join_dir(dir, "src")
        var src_root = dir
        if isdir(root + "/" + src):
            src_root = src
        if dir.byte_length() == 0:
            has_root = True
        ws.packages.append(Package(name, dir, src_root, deps^))
    if not has_root:
        var src_root = String("")
        if isdir(root + "/src"):
            src_root = "src"
        ws.packages.append(
            Package(_root_name(root), "", src_root, List[String]())
        )
    # Sorted by folder (stable; folders are distinct).
    var sorted = List[Package]()
    for p in ws.packages:
        var at = len(sorted)
        while at > 0 and p.dir < sorted[at - 1].dir:
            at -= 1
        sorted.insert(at, p.copy())
    ws.packages = sorted^
    for i in range(len(found)):
        var best = 0
        var best_len = -1
        for k in range(len(ws.packages)):
            ref d = ws.packages[k].dir
            if d.byte_length() == 0 or found[i].startswith(d + "/"):
                if d.byte_length() >= best_len:
                    best = k
                    best_len = d.byte_length()
        ws.files.append(SourceFile(found[i], best, tests[i]))
    return ws^


def python_plan(
    root: String, ws: Workspace, py: PythonObject, mut declined: Bool
) raises -> Report:
    """The plan of a Python workspace with source files, as analyze_lang
    builds it; `declined` when a file may read otherwise than the Rust tool
    reads it."""
    var facts = List[Facts]()
    for f in ws.files:
        facts.append(read_facts(py, root + "/" + f.path, f.path, declined))
        if declined:
            return Report("python")
    return build("python", "PyPI", ws.packages, ws.files, facts, py)


def _sorted(xs: List[String]) -> List[String]:
    var out = List[String]()
    for x in xs:
        var at = len(out)
        while at > 0 and x < out[at - 1]:
            at -= 1
        out.insert(at, x)
    return out^


def java_workspace(root: String, py: PythonObject) raises -> Workspace:
    """java.rs `discover`: a package per pom.xml, build.gradle or
    build.gradle.kts (named by its first artifactId, else its folder), and
    the `.java` files the walk keeps; declined for a name outside ASCII or
    holding a backslash, a folder holding two manifests (which one names the
    package depends on the walk's order), a root named like a folder the walk
    skips, and ignore files with alternates. With no source file the
    workspace is left empty."""
    var ws = Workspace()
    if _file_name(root) in _skip_dirs("java"):
        ws.declined = True
        return ws^
    var manifests = List[String]()
    var found = List[String]()
    var odd = False
    for rel in _files("java", root):
        if not _ascii(rel) or "\\" in rel:
            odd = True
        var name = _name_of(rel)
        if (
            name == "pom.xml"
            or name == "build.gradle"
            or name == "build.gradle.kts"
        ):
            manifests.append(rel)
        elif name.endswith(".java"):
            found.append(rel)
    if len(found) == 0:
        return ws^
    if odd or Int(py=py["ignore_files"](PythonObject(root), False)) != 0:
        ws.declined = True
        return ws^
    var th = tree_helpers()
    var dirs = List[String]()
    for rel in manifests:
        var dir = _dir_of(rel)
        if dir in dirs:
            ws.declined = True
            return ws^
        dirs.append(dir)
        var m = th["java_manifest"](PythonObject(root + "/" + rel))
        var name: String
        if Int(py=m[0]) == 1:
            name = String(py=m[1])
        elif dir.byte_length() == 0:
            name = _root_name(root)
        else:
            name = dir
        var deps = List[String]()
        for i in range(Int(py=Python.import_module("builtins").len(m[2]))):
            deps.append(String(py=m[2][i]))
        var src_root = dir
        if isdir(root + "/" + join_dir(dir, "src/main/java")):
            src_root = join_dir(dir, "src/main/java")
        ws.packages.append(Package(name, dir, src_root, deps^))
    if len(ws.packages) == 0:
        var src_root = String("")
        if isdir(root + "/src/main/java"):
            src_root = "src/main/java"
        elif isdir(root + "/src"):
            src_root = "src"
        ws.packages.append(
            Package(_root_name(root), "", src_root, List[String]())
        )
    # Sorted by folder (stable; folders are distinct).
    var sorted = List[Package]()
    for p in ws.packages:
        var at = len(sorted)
        while at > 0 and p.dir < sorted[at - 1].dir:
            at -= 1
        sorted.insert(at, p.copy())
    ws.packages = sorted^
    for rel in _sorted(found):
        var name = _name_of(rel)
        var test = (
            "src/test/" in rel
            or name.endswith("Test.java")
            or name.endswith("Tests.java")
            or name.endswith("IT.java")
        )
        var best = 0
        var best_len = -1
        for k in range(len(ws.packages)):
            ref d = ws.packages[k].dir
            if d.byte_length() == 0 or rel.startswith(d + "/"):
                if d.byte_length() >= best_len:
                    best = k
                    best_len = d.byte_length()
        ws.files.append(SourceFile(rel, best, test))
    return ws^


def go_workspace(root: String, py: PythonObject) raises -> Workspace:
    """go.rs `discover`: a package per go.mod (named by its module path,
    else its folder), and the `.go` files the walk keeps (`_test.go` ones
    are tests); declined as java_workspace is."""
    var ws = Workspace()
    var own = _file_name(root)
    if own in _skip_dirs("go") or own.startswith("_"):
        ws.declined = True
        return ws^
    var manifests = List[String]()
    var found = List[String]()
    var odd = False
    for rel in _files("go", root):
        if not _ascii(rel) or "\\" in rel:
            odd = True
        var name = _name_of(rel)
        if name == "go.mod":
            manifests.append(rel)
        elif name.endswith(".go"):
            found.append(rel)
    if len(found) == 0:
        return ws^
    if odd or Int(py=py["ignore_files"](PythonObject(root), False)) != 0:
        ws.declined = True
        return ws^
    var th = tree_helpers()
    for rel in manifests:
        var dir = _dir_of(rel)
        var m = th["go_manifest"](PythonObject(root + "/" + rel))
        var name = dir
        if Int(py=m[0]) == 1:
            name = String(py=m[1])
        var deps = List[String]()
        for i in range(Int(py=Python.import_module("builtins").len(m[2]))):
            deps.append(String(py=m[2][i]))
        ws.packages.append(Package(name, dir, dir, deps^))
    if len(ws.packages) == 0:
        ws.packages.append(Package(_root_name(root), "", "", List[String]()))
    var sorted = List[Package]()
    for p in ws.packages:
        var at = len(sorted)
        while at > 0 and p.dir < sorted[at - 1].dir:
            at -= 1
        sorted.insert(at, p.copy())
    ws.packages = sorted^
    for rel in _sorted(found):
        var best = 0
        var best_len = -1
        for k in range(len(ws.packages)):
            ref d = ws.packages[k].dir
            if d.byte_length() == 0 or rel.startswith(d + "/"):
                if d.byte_length() >= best_len:
                    best = k
                    best_len = d.byte_length()
        ws.files.append(SourceFile(rel, best, rel.endswith("_test.go")))
    return ws^


def _is_ruby_test(rel: String, name: String) -> Bool:
    if (
        name.endswith("_test.rb")
        or name.endswith("_spec.rb")
        or name.startswith("test_")
    ):
        return True
    for part in rel.split("/"):
        if part == "test" or part == "spec" or part == "features":
            return True
    return False


def ruby_workspace(root: String, py: PythonObject) raises -> Workspace:
    """ruby.rs `discover`: a package per folder with a .gemspec or a Gemfile
    (named by the gemspec, else its folder; `lib` its source root when it
    has one) plus the root's, and the `.rb` files the walk keeps; declined
    as java_workspace is, and for a folder with two gemspecs (the walk's
    order would pick the name)."""
    var ws = Workspace()
    if _file_name(root) in _skip_dirs("ruby"):
        ws.declined = True
        return ws^
    var manifests = List[String]()
    var found = List[String]()
    var odd = False
    for rel in _files("ruby", root):
        if not _ascii(rel) or "\\" in rel:
            odd = True
        var name = _name_of(rel)
        if name.endswith(".gemspec") or name == "Gemfile":
            manifests.append(rel)
        elif name.endswith(".rb"):
            found.append(rel)
    if len(found) == 0:
        return ws^
    if odd or Int(py=py["ignore_files"](PythonObject(root), False)) != 0:
        ws.declined = True
        return ws^
    var th = tree_helpers()
    var dirs = List[String]()
    var names = List[String]()
    var gemspecs = List[Int]()
    var deps = List[List[String]]()
    for rel in manifests:
        var dir = _dir_of(rel)
        var file = _name_of(rel)
        var k = -1
        for i in range(len(dirs)):
            if dirs[i] == dir:
                k = i
        if k < 0:
            k = len(dirs)
            dirs.append(dir)
            if dir.byte_length() == 0:
                names.append(_root_name(root))
            else:
                names.append(dir)
            gemspecs.append(0)
            deps.append(List[String]())
        if file.endswith(".gemspec"):
            gemspecs[k] += 1
            if gemspecs[k] > 1:
                ws.declined = True
                return ws^
            names[k] = trim_end_matches(file, ".gemspec")
        var m = th["ruby_manifest"](PythonObject(root + "/" + rel))
        for i in range(Int(py=Python.import_module("builtins").len(m))):
            deps[k].append(String(py=m[i]))
    var has_root = False
    for i in range(len(dirs)):
        var src_root = dirs[i]
        if isdir(root + "/" + join_dir(dirs[i], "lib")):
            src_root = join_dir(dirs[i], "lib")
        if dirs[i].byte_length() == 0:
            has_root = True
        ws.packages.append(Package(names[i], dirs[i], src_root, deps[i].copy()))
    if not has_root:
        var src_root = String("")
        if isdir(root + "/lib"):
            src_root = "lib"
        ws.packages.append(
            Package(_root_name(root), "", src_root, List[String]())
        )
    var sorted = List[Package]()
    for p in ws.packages:
        var at = len(sorted)
        while at > 0 and p.dir < sorted[at - 1].dir:
            at -= 1
        sorted.insert(at, p.copy())
    ws.packages = sorted^
    for rel in _sorted(found):
        var best = 0
        var best_len = -1
        for k in range(len(ws.packages)):
            ref d = ws.packages[k].dir
            if d.byte_length() == 0 or rel.startswith(d + "/"):
                if d.byte_length() >= best_len:
                    best = k
                    best_len = d.byte_length()
        ws.files.append(
            SourceFile(rel, best, _is_ruby_test(rel, _name_of(rel)))
        )
    return ws^


def csharp_workspace(root: String, py: PythonObject) raises -> Workspace:
    """csharp.rs `discover`: a package per .csproj (named by its
    AssemblyName, else the file's stem; a test project when it references a
    test framework or says IsTestProject), and the `.cs` files the walk
    keeps; declined as java_workspace is, and for a folder with two projects
    (dedup keeps the walk's first)."""
    var ws = Workspace()
    if _file_name(root) in _skip_dirs("csharp"):
        ws.declined = True
        return ws^
    var manifests = List[String]()
    var found = List[String]()
    var odd = False
    for rel in _files("csharp", root):
        if not _ascii(rel) or "\\" in rel:
            odd = True
        var name = _name_of(rel)
        if name.endswith(".csproj"):
            manifests.append(rel)
        elif name.endswith(".cs"):
            found.append(rel)
    if len(found) == 0:
        return ws^
    if odd or Int(py=py["ignore_files"](PythonObject(root), False)) != 0:
        ws.declined = True
        return ws^
    var th = tree_helpers()
    var dirs = List[String]()
    var tests = List[String]()
    for rel in manifests:
        var dir = _dir_of(rel)
        if dir in dirs:
            ws.declined = True
            return ws^
        dirs.append(dir)
        var file = _name_of(rel)
        var stem = String(file[byte = 0 : file.byte_length() - 7])
        var m = th["csharp_manifest"](
            PythonObject(root + "/" + rel), PythonObject(stem)
        )
        if Int(py=m[1]) == 1:
            tests.append(dir)
        var deps = List[String]()
        for i in range(Int(py=Python.import_module("builtins").len(m[2]))):
            deps.append(String(py=m[2][i]))
        ws.packages.append(Package(String(py=m[0]), dir, dir, deps^))
    if len(ws.packages) == 0:
        ws.packages.append(Package(_root_name(root), "", "", List[String]()))
    var sorted = List[Package]()
    for p in ws.packages:
        var at = len(sorted)
        while at > 0 and p.dir < sorted[at - 1].dir:
            at -= 1
        sorted.insert(at, p.copy())
    ws.packages = sorted^
    for rel in _sorted(found):
        var best = 0
        var best_len = -1
        for k in range(len(ws.packages)):
            ref d = ws.packages[k].dir
            if d.byte_length() == 0 or rel.startswith(d + "/"):
                if d.byte_length() >= best_len:
                    best = k
                    best_len = d.byte_length()
        var name = _name_of(rel)
        var test = (
            ws.packages[best].dir in tests
            or name.endswith("Tests.cs")
            or name.endswith("Test.cs")
        )
        ws.files.append(SourceFile(rel, best, test))
    return ws^


def kotlin_workspace(root: String, py: PythonObject) raises -> Workspace:
    """kotlin.rs `discover`: a package per pom.xml, build.gradle or
    build.gradle.kts (named by its folder, the root's by the root's name),
    and the `.kt` files the walk keeps; declined as java_workspace is."""
    var ws = Workspace()
    if _file_name(root) in _skip_dirs("kotlin"):
        ws.declined = True
        return ws^
    var manifests = List[String]()
    var found = List[String]()
    var odd = False
    for rel in _files("kotlin", root):
        if not _ascii(rel) or "\\" in rel:
            odd = True
        var name = _name_of(rel)
        if (
            name == "pom.xml"
            or name == "build.gradle"
            or name == "build.gradle.kts"
        ):
            manifests.append(rel)
        elif name.endswith(".kt"):
            found.append(rel)
    if len(found) == 0:
        return ws^
    if odd or Int(py=py["ignore_files"](PythonObject(root), False)) != 0:
        ws.declined = True
        return ws^
    var th = tree_helpers()
    var dirs = List[String]()
    for rel in manifests:
        var dir = _dir_of(rel)
        if dir in dirs:
            ws.declined = True
            return ws^
        dirs.append(dir)
        var m = th["kotlin_manifest"](PythonObject(root + "/" + rel))
        var name = dir
        if dir.byte_length() == 0:
            name = _root_name(root)
        var deps = List[String]()
        for i in range(Int(py=Python.import_module("builtins").len(m))):
            deps.append(String(py=m[i]))
        var src_root = dir
        if isdir(root + "/" + join_dir(dir, "src/main/kotlin")):
            src_root = join_dir(dir, "src/main/kotlin")
        elif isdir(root + "/" + join_dir(dir, "src/main/java")):
            src_root = join_dir(dir, "src/main/java")
        ws.packages.append(Package(name, dir, src_root, deps^))
    if len(ws.packages) == 0:
        var src_root = String("")
        if isdir(root + "/src/main/kotlin"):
            src_root = "src/main/kotlin"
        elif isdir(root + "/src"):
            src_root = "src"
        ws.packages.append(
            Package(_root_name(root), "", src_root, List[String]())
        )
    var sorted = List[Package]()
    for p in ws.packages:
        var at = len(sorted)
        while at > 0 and p.dir < sorted[at - 1].dir:
            at -= 1
        sorted.insert(at, p.copy())
    ws.packages = sorted^
    for rel in _sorted(found):
        var name = _name_of(rel)
        var test = (
            "src/test/" in rel
            or "src/androidTest/" in rel
            or name.endswith("Test.kt")
        )
        var best = 0
        var best_len = -1
        for k in range(len(ws.packages)):
            ref d = ws.packages[k].dir
            if d.byte_length() == 0 or rel.startswith(d + "/"):
                if d.byte_length() >= best_len:
                    best = k
                    best_len = d.byte_length()
        ws.files.append(SourceFile(rel, best, test))
    return ws^


def tree_plan(
    lang: String,
    registry: String,
    root: String,
    ws: Workspace,
    mut declined: Bool,
) raises -> Report:
    """The plan of a workspace of a tree-sitter language with source files;
    `declined` when a file's tree has an error."""
    var th = tree_helpers()
    var facts = List[Facts]()
    for f in ws.files:
        facts.append(read_tree_facts(th, lang, root + "/" + f.path, declined))
        if declined:
            return Report(lang)
    return build(lang, registry, ws.packages, ws.files, facts, py_helpers())


comptime PY_BRIDGE = "Mojo (Python extension)"


def registry(lang: String) -> String:
    """Lang::registry."""
    if lang == "ts":
        return "npm"
    if lang == "python":
        return "PyPI"
    if lang == "c" or lang == "cpp":
        return "system libraries"
    if lang == "go":
        return "Go modules"
    if lang == "ruby":
        return "gems"
    if lang == "java" or lang == "kotlin":
        return "Maven"
    if lang == "php":
        return "Composer"
    return "NuGet"


def bridge_label(lang: String) -> String:
    """Bridge::for_lang(lang).label() (not TS)."""
    if lang == "python":
        return PY_BRIDGE
    if lang == "c" or lang == "cpp":
        return "C ABI"
    if lang == "go":
        return "cgo"
    if lang == "ruby":
        return "Fiddle (C ABI)"
    if lang == "java" or lang == "kotlin":
        return "Mojo (Java FFM)"
    if lang == "php":
        return "PHP FFI (C ABI)"
    return "P/Invoke (C ABI)"


def bridge_id(lang: String) -> String:
    """Bridge::for_lang(lang) in serde's kebab case (not TS)."""
    if lang == "python":
        return "mojo-py"
    if lang == "c" or lang == "cpp":
        return "c-abi"
    if lang == "go":
        return "cgo"
    if lang == "ruby":
        return "fiddle"
    if lang == "java" or lang == "kotlin":
        return "mojo-jvm"
    if lang == "php":
        return "php-ffi"
    return "dotnet-ffi"


struct LangPlan(Movable):
    """The plan of a workspace with source files of a language analyze.mojo
    reads (`planned`), or `declined`; neither when it has no source file."""

    var report: Report
    var planned: Bool
    var declined: Bool

    def __init__(out self, lang: String):
        self.report = Report(lang)
        self.planned = False
        self.declined = False


def lang_plan(lang: String, root: String, py: PythonObject) raises -> LangPlan:
    """analyze_lang for a folder, for the languages with a Mojo reader."""
    var out = LangPlan(lang)
    if lang == "python":
        var pyh = py_helpers()
        var ws = python_workspace(root, pyh)
        if ws.declined:
            out.declined = True
        elif len(ws.files) > 0:
            out.report = python_plan(root, ws, pyh, out.declined)
            out.planned = not out.declined
    elif (
        lang == "java"
        or lang == "go"
        or lang == "ruby"
        or lang == "csharp"
        or lang == "kotlin"
    ):
        var ws: Workspace
        if lang == "java":
            ws = java_workspace(root, py)
        elif lang == "go":
            ws = go_workspace(root, py)
        elif lang == "ruby":
            ws = ruby_workspace(root, py)
        elif lang == "kotlin":
            ws = kotlin_workspace(root, py)
        else:
            ws = csharp_workspace(root, py)
        if ws.declined:
            out.declined = True
        elif len(ws.files) > 0:
            out.report = tree_plan(lang, registry(lang), root, ws, out.declined)
            out.planned = not out.declined
    return out^


def _emit(
    p: Parsed, py: PythonObject, text: String, argv: List[String]
) raises -> Int:
    """The plan on stdout, or in `--out`."""
    var out = p.value("out")
    if out:
        if (
            Int(py=py["write"](PythonObject(out.value()), PythonObject(text)))
            != 1
        ):
            return fallback(argv)
        return 0
    print(text, end="")
    return 0


def run_analyze(p: Parsed, argv: List[String]) raises -> Int:
    if p.flag("whole-app"):
        return fallback(argv)
    var root = p.value("ROOT").or_else(".")
    if root.byte_length() == 0:
        return fallback(argv)
    var py = _helpers()
    var lang = String("")
    var given = p.value("lang")
    if given:
        lang = given.value()
    var state = String(py=py["root_state"](PythonObject(root)))
    if state == "other":
        return fallback(argv)
    if state == "file":
        var ext = _extension(_name_of(root))
        if not _ascii(ext):
            return fallback(argv)
        ext = ext.lower()
        if ext in _compiled():
            raise Error(
                String(
                    "analyzing ",
                    root,
                    ": ",
                    root,
                    " is a compiled .",
                    ext,
                    " file. ",
                    _compiled_hint(),
                )
            )
        raise Error(
            String(
                "analyzing ",
                root,
                ": ",
                root,
                (
                    " is a file; `analyze` takes the folder of a project's"
                    " source code"
                ),
            )
        )
    if lang.byte_length() == 0:
        lang = detect_lang(root)
    if state == "missing":
        if lang == "ts":
            raise Error(
                String(
                    "analyzing ",
                    root,
                    ": ",
                    root,
                    ": IO error for operation on ",
                    root,
                    ": No such file or directory (os error 2)",
                )
            )
    var packages = 1
    if state == "dir":
        # Rust's compiled-file walk sees the root itself (depth 0): a root
        # folder named like a compiled file makes the plan carry a warning.
        var own = _file_name(root)
        if not _ascii(own) or _extension(own).lower() in _compiled():
            return fallback(argv)
        var lp = lang_plan(lang, root, py)
        if lp.declined:
            return fallback(argv)
        if lp.planned:
            if p.flag("json"):
                return _emit(p, py, to_json(lp.report, bridge_id(lang)), argv)
            return _emit(
                p,
                py,
                markdown(
                    lp.report,
                    _title(root),
                    lang_name(lang),
                    registry(lang),
                    bridge_label(lang),
                ),
                argv,
            )
        var d = empty_workspace(lang, root, py)
        if d.declined:
            return fallback(argv)
        packages = d.packages
    var text: String
    if p.flag("json"):
        text = empty_json(lang, packages)
    else:
        text = empty_markdown(lang, _title(root), packages)
    var out = p.value("out")
    if out:
        if (
            Int(py=py["write"](PythonObject(out.value()), PythonObject(text)))
            != 1
        ):
            return fallback(argv)
        return 0
    print(text, end="")
    return 0
