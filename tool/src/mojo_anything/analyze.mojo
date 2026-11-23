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
            # `src/main/kotlin/build/` can be a real package (e.path(), the
            # root included).
            if name in skip and not _src_component(root + "/" + d):
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
                    # `src/main/java/com/acme/build/` is a package.
                    if _name_of(d) in skip and not _src_component(d):
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
