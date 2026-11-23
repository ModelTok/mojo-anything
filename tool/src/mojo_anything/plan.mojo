# The migration plan of a workspace whose files are read (port of
# src/analyze.rs's `build`, `score`, `check_bridgeable`, `start_here`,
# `package_reports`, `dependency_reports`, `priority`, `waves` and
# `topological`, of src/report.rs's Markdown and of the Report's serde JSON).
# This slice plans Python workspaces: no platforms, no UI files, no workspace
# imports, the `Mojo (Python extension)` bridge.

from std.math import floor
from std.python import Python, PythonObject

from mojo_anything.embedded import replacements_toml
from mojo_anything.json_text import write_string
from mojo_anything.python_lang import (
    EXTERNAL,
    FILE,
    Facts,
    Resolution,
    STDLIB,
    UNRESOLVED,
    resolve,
)
from mojo_anything.risks import (
    RISK_COUNT,
    risk_guidance,
    risk_names,
    risk_title,
    severity,
    severity_debug,
    severity_name,
    severity_weight,
)

comptime SCHEMA = "mojo-anything/analyze@1"
comptime SAMPLES_PER_RISK = 3
comptime MIN_CANDIDATE_LOC = 20
comptime DETAILED_CANDIDATES = 5
comptime READY = 0
comptime CAUTION = 1
comptime BLOCKED = 2
comptime KEEP = 3
comptime FIT_GOOD = 0
comptime FIT_PARTIAL = 1
comptime FIT_NONE = 2
comptime FIT_UNKNOWN = 3


@fieldwise_init
struct Package(Copyable, Movable):
    var name: String
    var dir: String
    var src_root: String
    var deps: List[String]


@fieldwise_init
struct SourceFile(Copyable, Movable):
    var path: String
    var package: Int
    var test: Bool


struct _Unit(Copyable, Movable):
    var id: String
    var package: Int
    var files: List[Int]
    var loc: Int
    var loops: Int
    var counts: List[Int]
    var samples: List[List[String]]
    var deps: List[Int]
    """Sorted, as a BTreeSet of unit indices."""
    var external: List[String]
    """Sorted, as a BTreeSet."""
    var unresolved: Int
    var direct_tests: Int
    var fan_in: Int

    def __init__(out self, id: String, package: Int):
        self.id = id
        self.package = package
        self.files = List[Int]()
        self.loc = 0
        self.loops = 0
        self.counts = List[Int]()
        self.samples = List[List[String]]()
        for _ in range(RISK_COUNT):
            self.counts.append(0)
            self.samples.append(List[String]())
        self.deps = List[Int]()
        self.external = List[String]()
        self.unresolved = 0
        self.direct_tests = 0
        self.fan_in = 0


struct UnitReport(Copyable, Movable):
    var id: String
    var package: String
    var files: List[String]
    var loc: Int
    var wave: Int
    var readiness: Int
    var readiness_f: Float64
    var status: Int
    var risks: List[Int]
    var counts: List[Int]
    var samples: List[List[String]]
    var internal_deps: List[String]
    var external_deps: List[String]
    var direct_tests: Int
    var fan_in: Int
    var density: Float64
    var priority: Int
    var exports: Int
    var bridgeable: Int
    var notes: List[String]

    def __init__(out self):
        self.id = ""
        self.package = ""
        self.files = List[String]()
        self.loc = 0
        self.wave = 0
        self.readiness = 0
        self.readiness_f = 0.0
        self.status = READY
        self.risks = List[Int]()
        self.counts = List[Int]()
        self.samples = List[List[String]]()
        self.internal_deps = List[String]()
        self.external_deps = List[String]()
        self.direct_tests = 0
        self.fan_in = 0
        self.density = 0.0
        self.priority = 0
        self.exports = 0
        self.bridgeable = 0
        self.notes = List[String]()


@fieldwise_init
struct PackageReport(Copyable, Movable):
    var name: String
    var dir: String
    var order: Int
    var workspace_deps: List[String]
    var test_files: Int
    var units: List[String]


@fieldwise_init
struct DependencyReport(Copyable, Movable):
    var name: String
    var used_by: Int
    var fit: Int
    var replacement: String
    var note: String


struct Report(Movable):
    var language: String
    var packages_n: Int
    var source_files: Int
    var test_files: Int
    var loc: Int
    var ready: Int
    var caution: Int
    var blocked: Int
    var keep: Int
    var packages: List[PackageReport]
    var units: List[UnitReport]
    var start_here: List[String]
    var dependencies: List[DependencyReport]

    def __init__(out self, language: String):
        self.language = language
        self.packages_n = 0
        self.source_files = 0
        self.test_files = 0
        self.loc = 0
        self.ready = 0
        self.caution = 0
        self.blocked = 0
        self.keep = 0
        self.packages = List[PackageReport]()
        self.units = List[UnitReport]()
        self.start_here = List[String]()
        self.dependencies = List[DependencyReport]()


# ---- small helpers -----------------------------------------------------------


def _insert_int(mut xs: List[Int], v: Int):
    var at = 0
    while at < len(xs) and xs[at] < v:
        at += 1
    if at < len(xs) and xs[at] == v:
        return
    xs.insert(at, v)


def _insert_str(mut xs: List[String], v: String):
    var at = 0
    while at < len(xs) and xs[at] < v:
        at += 1
    if at < len(xs) and xs[at] == v:
        return
    xs.insert(at, v)


def _round(x: Float64) -> Float64:
    """f64::round: halves away from zero."""
    if x < 0:
        return -_round(-x)
    var f = floor(x)
    if x - f >= 0.5:
        return f + 1.0
    return f


def _clamp(x: Float64, lo: Float64, hi: Float64) -> Float64:
    if x < lo:
        return lo
    if x > hi:
        return hi
    return x


def _join(items: List[String], sep: String) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += sep
        out += items[i]
    return out^


def _starts_with_dir(path: String, dir: String) -> Bool:
    return path.startswith(dir + "/")


def join_dir(dir: String, rest: String) -> String:
    """discover::join."""
    if dir.byte_length() == 0:
        return rest
    return dir + "/" + rest


def _unit_id(p: Package, path: String) -> String:
    var base = p.dir
    if p.src_root.byte_length() > 0 and _starts_with_dir(path, p.src_root):
        base = p.src_root
    var rel = path
    if base.byte_length() > 0:
        rel = String(path[byte = base.byte_length() + 1 :])
    var slash = rel.rfind("/")
    if slash < 0:
        return path
    return join_dir(base, String(rel[byte=0:slash])) + "/"


def fit_name(fit: Int) -> String:
    if fit == FIT_GOOD:
        return "good"
    if fit == FIT_PARTIAL:
        return "partial"
    if fit == FIT_NONE:
        return "none"
    return "unknown"


struct Crates(Movable):
    """The crate table (crates::find), read from the embedded
    replacements.toml with tomllib."""

    var py: PythonObject

    def __init__(out self, py: PythonObject) raises:
        self.py = py
        _ = py["load_table"](PythonObject(replacements_toml()))

    def find(self, lang: String, name: String) raises -> DependencyReport:
        """analyze::crate_for: the language's lookup (Java keys a Maven
        coordinate by its group)."""
        var key = name
        if lang == "java":
            var colon = name.find(":")
            if colon >= 0:
                key = String(name[byte=0:colon])
        var r = self.py["crate_find"](PythonObject(lang), PythonObject(key))
        var fit = FIT_UNKNOWN
        if Int(py=r[0]) == 1:
            var f = String(py=r[2])
            if f == "good":
                fit = FIT_GOOD
            elif f == "partial":
                fit = FIT_PARTIAL
            else:
                fit = FIT_NONE
        return DependencyReport(name, 0, fit, String(py=r[1]), String(py=r[3]))

    def longest_prefix(self, lang: String, name: String) raises -> String:
        """crates::longest_prefix ("" for none)."""
        return String(
            py=self.py["longest_prefix"](PythonObject(lang), PythonObject(name))
        )


# ---- resolution of the tree-sitter languages ---------------------------------


def _trim_end_matches(s: String, suffix: String) -> String:
    var out = s
    while out.endswith(suffix):
        var cut = String(
            out[byte = 0 : out.byte_length() - suffix.byte_length()]
        )
        out = cut^
    return out^


def java_resolve(
    spec: String,
    index: Dict[String, Int],
    paths: List[String],
    packages: List[Package],
    crates: Crates,
) raises -> Resolution:
    """java.rs `resolve`: the platform's packages, a file or a folder of a
    package's source root, else the library the crate table's longest
    prefix names (or the first two segments)."""
    var parts = spec.split(".")
    var first = String(parts[0])
    if (
        first == "java"
        or first == "javax"
        or first == "jdk"
        or first == "sun"
        or spec.startswith("com.sun.")
    ):
        return Resolution(STDLIB, -1, "")
    var path = _trim_end_matches(spec, ".*").replace(".", "/")
    for p in packages:
        var file = join_dir(p.src_root, path + ".java")
        if file in index:
            return Resolution(FILE, index[file], "")
        var dir = join_dir(p.src_root, path)
        var best = -1
        for i in range(len(paths)):
            var slash = paths[i].rfind("/")
            if slash < 0 or String(paths[i][byte=0:slash]) != dir:
                continue
            if best < 0 or paths[i] < paths[best]:
                best = i
        if best >= 0:
            return Resolution(FILE, best, "")
    var external = crates.longest_prefix("java", spec)
    if external.byte_length() == 0:
        external = first
        if len(parts) > 1:
            external += "." + String(parts[1])
    return Resolution(EXTERNAL, -1, external)


def go_resolve(
    spec: String,
    index: Dict[String, Int],
    paths: List[String],
    packages: List[Package],
) raises -> Resolution:
    """go.rs `resolve`: the module with the longest path that prefixes the
    import (the first non-test `.go` file of its folder), else the standard
    library (no dot in the first element), else an external module."""
    var best = -1
    for k in range(len(packages)):
        ref name = packages[k].name
        if spec == name or spec.startswith(name + "/"):
            if (
                best < 0
                or name.byte_length() >= packages[best].name.byte_length()
            ):
                best = k
    if best >= 0:
        ref module = packages[best]
        var sub = String(spec[byte = module.name.byte_length() :])
        while sub.startswith("/"):
            var rest = String(sub[byte=1:])
            sub = rest^
        var dir: String
        if module.dir.byte_length() == 0:
            dir = sub
        elif sub.byte_length() == 0:
            dir = module.dir
        else:
            dir = module.dir + "/" + sub
        var file = -1
        for i in range(len(paths)):
            ref path = paths[i]
            var slash = path.rfind("/")
            var parent = String("")
            if slash >= 0:
                parent = String(path[byte=0:slash])
            if (
                parent == dir
                and path.endswith(".go")
                and not path.endswith("_test.go")
                and (file < 0 or path < paths[file])
            ):
                file = i
        if file >= 0:
            return Resolution(FILE, file, "")
        return Resolution(UNRESOLVED, -1, "")
    var first = String(spec.split("/")[0])
    if not "." in first:
        return Resolution(STDLIB, -1, "")
    return Resolution(EXTERNAL, -1, spec)


def _target(
    lang: String,
    from_path: String,
    spec: String,
    index: Dict[String, Int],
    paths: List[String],
    roots: List[String],
    packages: List[Package],
    crates: Crates,
) raises -> Resolution:
    """crate::lang::resolve for the language."""
    if lang == "java":
        return java_resolve(spec, index, paths, packages, crates)
    if lang == "go":
        return go_resolve(spec, index, paths, packages)
    return resolve(from_path, spec, index, paths, roots)


# ---- waves -------------------------------------------------------------------


struct _Tarjan(Movable):
    var index: List[Int]
    var low: List[Int]
    var on_stack: List[Bool]
    var stack: List[Int]
    var next: Int
    var components: List[List[Int]]

    def __init__(out self, n: Int):
        self.index = List[Int]()
        self.low = List[Int]()
        self.on_stack = List[Bool]()
        for _ in range(n):
            self.index.append(-1)
            self.low.append(0)
            self.on_stack.append(False)
        self.stack = List[Int]()
        self.next = 0
        self.components = List[List[Int]]()


def _visit(mut t: _Tarjan, edges: List[List[Int]], v: Int):
    t.index[v] = t.next
    t.low[v] = t.next
    t.next += 1
    t.stack.append(v)
    t.on_stack[v] = True
    for w in edges[v]:
        if t.index[w] < 0:
            _visit(t, edges, w)
            t.low[v] = min(t.low[v], t.low[w])
        elif t.on_stack[w]:
            t.low[v] = min(t.low[v], t.index[w])
    if t.index[v] == t.low[v]:
        var component = List[Int]()
        while len(t.stack) > 0:
            var w = t.stack.pop()
            t.on_stack[w] = False
            component.append(w)
            if w == v:
                break
        t.components.append(component^)


def waves(
    edges: List[List[Int]], mut wave: List[Int], mut members: List[List[Int]]
):
    """Each node's wave and its strongly connected component (analyze.rs
    `waves`)."""
    var n = len(edges)
    var t = _Tarjan(n)
    for v in range(n):
        if t.index[v] < 0:
            _visit(t, edges, v)
    wave = List[Int]()
    members = List[List[Int]]()
    for _ in range(n):
        wave.append(0)
        members.append(List[Int]())
    for component in t.components:
        var w = 0
        for v in component:
            for x in edges[v]:
                if not x in component:
                    w = max(w, wave[x] + 1)
        for v in component:
            wave[v] = w
            members[v] = component.copy()


def topological(deps_of: List[List[Int]]) -> List[Int]:
    """Kahn's algorithm; nodes in cycles are appended in index order."""
    var n = len(deps_of)
    var remaining = List[Int]()
    var done = List[Bool]()
    for d in deps_of:
        remaining.append(len(d))
        done.append(False)
    var order = List[Int]()
    while True:
        var next = -1
        for i in range(n):
            if not done[i] and remaining[i] == 0:
                next = i
                break
        if next < 0:
            break
        done[next] = True
        order.append(next)
        for i in range(n):
            if next in deps_of[i]:
                remaining[i] -= 1
    for i in range(n):
        if not done[i]:
            order.append(i)
    return order^


# ---- scoring -----------------------------------------------------------------


def _priority(
    readiness: Float64,
    density: Float64,
    loc: Int,
    direct_tests: Int,
    package_tests: Int,
) -> Int:
    var compute = min(density * 4.0, 50.0)
    var tests = 0.0
    if direct_tests > 0:
        tests = 30.0
    elif package_tests > 0:
        tests = 15.0
    var size: Float64
    if loc < 80:
        size = Float64(loc) / 4.0
    elif loc < 600:
        size = 20.0
    else:
        size = 10.0
    var value = compute + tests + size
    return Int(_clamp(_round(readiness * 0.5 + value * 0.5), 0.0, 100.0))


def _score(
    u: Int,
    units: List[_Unit],
    packages: List[Package],
    files: List[SourceFile],
    package_tests: List[Int],
    wave: List[Int],
    cycle: List[Int],
    crates: Crates,
    lang: String,
    registry: String,
    ln: PythonObject,
) raises -> UnitReport:
    ref unit = units[u]
    var p_tests = package_tests[unit.package]
    var notes = List[String]()
    var blocking = List[String]()
    var unknown = 0
    for d in unit.external:
        var m = crates.find(lang, d)
        if m.fit == FIT_NONE:
            blocking.append(d)
        elif m.fit == FIT_UNKNOWN:
            unknown += 1
    var risk_points = 0.0
    for r in range(RISK_COUNT):
        if unit.counts[r] > 0:
            risk_points += severity_weight(severity(r)) * Float64(
                py=ln(PythonObject(1.0 + Float64(unit.counts[r])))
            )
    var size_penalty = Float64(unit.loc) / 40.0
    var fan_in_penalty = min(Float64(unit.fan_in) * 1.5, 15.0)
    var dep_penalty = Float64(len(blocking)) * 12.0 + Float64(unknown) * 4.0
    var test_bonus = 0.0
    if unit.direct_tests > 0:
        test_bonus = 10.0
    elif p_tests > 0:
        test_bonus = 4.0
    var readiness = _clamp(
        100.0
        - risk_points
        - size_penalty
        - fan_in_penalty
        - dep_penalty
        + test_bonus,
        0.0,
        100.0,
    )
    var dynamic = unit.counts[3] > 0
    var status: Int
    if len(blocking) > 0 or dynamic:
        for d in blocking:
            notes.append("`" + d + "` has no Rust equivalent.")
        if dynamic:
            notes.append(
                "Uses dynamic code (eval, new Function or computed imports)."
            )
        status = BLOCKED
    elif readiness < 50.0:
        status = CAUTION
    else:
        status = READY
    if unknown > 0:
        notes.append(
            String(
                unknown,
                " ",
                registry,
                " dependencies not in the crate table: check them by hand.",
            )
        )
    if unit.unresolved > 0:
        notes.append(
            String(
                unit.unresolved,
                (
                    " imports use aliases or virtual modules and were not"
                    " followed."
                ),
            )
        )
    if len(cycle) > 1:
        var others = List[String]()
        for v in cycle:
            if units[v].id != unit.id:
                others.append(units[v].id)
        notes.append(
            "Import cycle with " + _join(others, ", ") + ": port them together."
        )
    if len(unit.deps) == 0:
        notes.append("Leaf: imports no other unit.")
    if unit.direct_tests > 0:
        notes.append(
            String(unit.direct_tests, " test files import it directly.")
        )
    elif p_tests == 0:
        notes.append(
            "No tests found: write characterization tests against the original"
            " code first."
        )
    var string_ops = unit.counts[0]
    var density = 0.0
    if unit.loc > 0:
        density = (
            _round(
                Float64(unit.loops + string_ops)
                * 100.0
                / Float64(unit.loc)
                * 10.0
            )
            / 10.0
        )
    var out = UnitReport()
    out.id = unit.id
    out.package = packages[unit.package].name
    for i in unit.files:
        _insert_str(out.files, files[i].path)
    out.loc = unit.loc
    out.wave = wave[u]
    out.readiness_f = readiness
    out.readiness = Int(_round(readiness))
    out.status = status
    # Severity high first, then the larger count; ties keep the risks' order.
    for r in range(RISK_COUNT):
        if unit.counts[r] == 0:
            continue
        var at = len(out.risks)
        while at > 0:
            var q = out.risks[at - 1]
            var before = severity(q) > severity(r) or (
                severity(q) == severity(r) and unit.counts[q] >= unit.counts[r]
            )
            if before:
                break
            at -= 1
        out.risks.insert(at, r)
    for r in out.risks:
        out.counts.append(unit.counts[r])
        out.samples.append(unit.samples[r].copy())
    for v in unit.deps:
        out.internal_deps.append(units[v].id)
    out.external_deps = unit.external.copy()
    out.direct_tests = unit.direct_tests
    out.fan_in = unit.fan_in
    out.density = density
    out.priority = _priority(
        readiness, density, unit.loc, unit.direct_tests, p_tests
    )
    out.notes = notes^
    return out^


def _before(a: UnitReport, b: UnitReport) -> Bool:
    """start_here's order: priority, readiness, wave, density, id."""
    if a.priority != b.priority:
        return a.priority > b.priority
    if a.readiness != b.readiness:
        return a.readiness > b.readiness
    if a.wave != b.wave:
        return a.wave < b.wave
    if a.density != b.density:
        return a.density > b.density
    return a.id < b.id


def _pick(units: List[UnitReport], caution: Bool, min_loc: Int) -> List[Int]:
    var list = List[Int]()
    for i in range(len(units)):
        ref u = units[i]
        var ok = u.status == READY or (caution and u.status == CAUTION)
        if not ok or u.loc < min_loc or u.bridgeable == 0:
            continue
        var at = len(list)
        while at > 0 and _before(u, units[list[at - 1]]):
            at -= 1
        list.insert(at, i)
    return list^


def start_here(units: List[UnitReport]) -> List[String]:
    var list = _pick(units, False, MIN_CANDIDATE_LOC)
    if len(list) < 3:
        list = _pick(units, True, MIN_CANDIDATE_LOC)
    if len(list) == 0:
        list = _pick(units, True, 1)
    var out = List[String]()
    for i in range(min(len(list), 10)):
        out.append(units[list[i]].id)
    return out^


# ---- the plan ----------------------------------------------------------------


def build(
    lang: String,
    registry: String,
    packages: List[Package],
    files: List[SourceFile],
    facts: List[Facts],
    py: PythonObject,
) raises -> Report:
    """build and check_bridgeable for a workspace of a language with a
    resolver (Python)."""
    var index = Dict[String, Int]()
    var paths = List[String]()
    for i in range(len(files)):
        index[files[i].path] = i
        paths.append(files[i].path)
    var roots = List[String]()
    _insert_str(roots, "")
    for p in packages:
        _insert_str(roots, p.src_root)
    var crates = Crates(py)
    var ln = Python.import_module("math").log

    var units = List[_Unit]()
    var unit_ids = Dict[String, Int]()
    var unit_of = List[Int]()
    for i in range(len(files)):
        unit_of.append(-1)
        if files[i].test:
            continue
        var id = _unit_id(packages[files[i].package], files[i].path)
        var u: Int
        if id in unit_ids:
            u = unit_ids[id]
        else:
            u = len(units)
            unit_ids[id] = u
            units.append(_Unit(id, files[i].package))
        units[u].files.append(i)
        unit_of[i] = u

    var report = Report(lang)
    report.packages_n = len(packages)
    var package_tests = List[Int]()
    for _ in range(len(packages)):
        package_tests.append(0)
    for i in range(len(files)):
        ref file = files[i]
        if file.test:
            report.test_files += 1
        else:
            report.source_files += 1
        ref f = facts[i]
        if not f.readable:
            continue
        if file.test:
            package_tests[file.package] += 1
            var hit = List[Int]()
            for k in range(len(f.specs)):
                var r = _target(
                    lang,
                    file.path,
                    f.specs[k],
                    index,
                    paths,
                    roots,
                    packages,
                    crates,
                )
                if r.kind == FILE and unit_of[r.file] >= 0:
                    _insert_int(hit, unit_of[r.file])
            for u in hit:
                units[u].direct_tests += 1
            continue
        var u = unit_of[i]
        report.loc += f.loc
        units[u].loc += f.loc
        units[u].loops += f.loops
        for r in range(RISK_COUNT):
            for line in f.risks[r]:
                units[u].counts[r] += 1
                if len(units[u].samples[r]) < SAMPLES_PER_RISK:
                    units[u].samples[r].append(String(file.path, ":", line))
        for k in range(len(f.specs)):
            var r = _target(
                lang,
                file.path,
                f.specs[k],
                index,
                paths,
                roots,
                packages,
                crates,
            )
            if r.kind == FILE:
                var v = unit_of[r.file]
                if v >= 0 and v != u:
                    _insert_int(units[u].deps, v)
            elif r.kind == EXTERNAL and not f.type_only[k]:
                _insert_str(units[u].external, r.name)
            elif r.kind == UNRESOLVED and not f.type_only[k]:
                units[u].unresolved += 1
    for u in range(len(units)):
        for v in units[u].deps:
            units[v].fan_in += 1

    var edges = List[List[Int]]()
    for u in units:
        edges.append(u.deps.copy())
    var wave = List[Int]()
    var members = List[List[Int]]()
    waves(edges, wave, members)
    var reports = List[UnitReport]()
    for u in range(len(units)):
        var r = _score(
            u,
            units,
            packages,
            files,
            package_tests,
            wave,
            members[u],
            crates,
            lang,
            registry,
            ln,
        )
        var at = len(reports)
        while at > 0 and r.id < reports[at - 1].id:
            at -= 1
        reports.insert(at, r^)

    # check_bridgeable: the exports of every unit that is neither kept nor
    # blocked, with the rules `bridge` applies.
    for k in range(len(reports)):
        if reports[k].status == KEEP or reports[k].status == BLOCKED:
            continue
        var exports = 0
        var bridgeable = 0
        for path in reports[k].files:
            ref f = facts[index[path]]
            if not f.readable:
                continue
            exports += f.exports
            bridgeable += f.bridgeable
        reports[k].exports = exports
        reports[k].bridgeable = bridgeable
        if exports > 0 and bridgeable == 0:
            reports[k].status = CAUTION
            reports[k].notes.insert(
                0,
                (
                    "Every export is JS-shaped (functions, plugin objects,"
                    " iterators): porting the logic means adding a data-only"
                    " function, an API change."
                ),
            )
    for r in reports:
        if r.status == READY:
            report.ready += 1
        elif r.status == CAUTION:
            report.caution += 1
        elif r.status == BLOCKED:
            report.blocked += 1
        else:
            report.keep += 1
    report.start_here = start_here(reports)
    report.packages = _package_reports(packages, reports, package_tests)
    report.dependencies = _dependency_reports(reports, crates, lang)
    report.units = reports^
    return report^


def _package_reports(
    packages: List[Package],
    units: List[UnitReport],
    package_tests: List[Int],
) -> List[PackageReport]:
    var deps_of = List[List[Int]]()
    for i in range(len(packages)):
        var d = List[Int]()
        for n in packages[i].deps:
            # A HashMap of names: the last package with a name wins.
            var j = -1
            for k in range(len(packages)):
                if packages[k].name == n:
                    j = k
            if j >= 0 and j != i:
                _insert_int(d, j)
        deps_of.append(d^)
    var out = List[PackageReport]()
    for i in topological(deps_of):
        ref p = packages[i]
        var ids = List[String]()
        for u in units:
            if u.package == p.name:
                ids.append(u.id)
        if len(ids) == 0:
            continue
        var names = List[String]()
        for j in deps_of[i]:
            names.append(packages[j].name)
        out.append(
            PackageReport(
                p.name, p.dir, len(out) + 1, names^, package_tests[i], ids^
            )
        )
    return out^


def _rank(fit: Int) -> Int:
    if fit == FIT_NONE:
        return 0
    if fit == FIT_UNKNOWN:
        return 1
    if fit == FIT_PARTIAL:
        return 2
    return 3


def _dependency_reports(
    units: List[UnitReport], crates: Crates, lang: String
) raises -> List[DependencyReport]:
    var names = List[String]()
    var used = List[Int]()
    for u in units:
        if u.status == KEEP:
            continue
        for d in u.external_deps:
            var at = 0
            while at < len(names) and names[at] < d:
                at += 1
            if at < len(names) and names[at] == d:
                used[at] += 1
            else:
                names.insert(at, d)
                used.insert(at, 1)
    var out = List[DependencyReport]()
    for i in range(len(names)):
        var m = crates.find(lang, names[i])
        m.used_by = used[i]
        var at = len(out)
        while at > 0:
            ref q = out[at - 1]
            var before = _rank(q.fit) < _rank(m.fit) or (
                _rank(q.fit) == _rank(m.fit) and q.used_by >= m.used_by
            )
            if before:
                break
            at -= 1
        out.insert(at, m^)
    return out^


# ---- report.rs ---------------------------------------------------------------


def _status_label(s: Int) -> String:
    if s == READY:
        return "ready"
    if s == CAUTION:
        return "caution"
    if s == BLOCKED:
        return "blocked"
    return "keep"


def _top_risks(u: UnitReport, n: Int) -> String:
    if len(u.risks) == 0:
        return "-"
    var parts = List[String]()
    for k in range(min(n, len(u.risks))):
        parts.append(String(risk_title(u.risks[k]), " (", u.counts[k], ")"))
    return _join(parts, "; ")


def _unit_of(r: Report, id: String) -> Int:
    for i in range(len(r.units)):
        if r.units[i].id == id:
            return i
    return -1


def markdown(
    r: Report,
    title: String,
    lang_name: String,
    registry: String,
    bridge: String,
) -> String:
    var out = String("# Rust migration plan: ", title, " (", lang_name, ")\n\n")
    out += String(
        r.packages_n,
        " packages, ",
        r.source_files,
        " source files (",
        r.loc,
        " lines), ",
        r.test_files,
        " test files, 0 UI files, grouped into ",
        len(r.units),
        " units.\n\n",
    )
    out += "| Ready | Caution | Blocked | Keep in source language |\n"
    out += "| ---: | ---: | ---: | ---: |\n"
    out += String(
        "| ",
        r.ready,
        " | ",
        r.caution,
        " | ",
        r.blocked,
        " | ",
        r.keep,
        " |\n\n",
    )
    out += "## Start here\n\n"
    if len(r.start_here) == 0:
        out += (
            "No unit is a safe first port yet. See the blocked units and"
            " dependencies below.\n\n"
        )
    else:
        out += (
            "Best first ports: safe to port (readiness) and worth porting"
            " (loops and string work, tests, size).\n\n"
        )
        out += (
            "| # | Unit | Lines | Priority | Readiness | Tests | Bridge | Main"
            " risks |\n"
        )
        out += "| ---: | --- | ---: | ---: | ---: | ---: | --- | --- |\n"
        for i in range(len(r.start_here)):
            var k = _unit_of(r, r.start_here[i])
            if k < 0:
                continue
            ref u = r.units[k]
            out += String(
                "| ",
                i + 1,
                " | `",
                u.id,
                "` | ",
                u.loc,
                " | ",
                u.priority,
                " | ",
                u.readiness,
                " | ",
                u.direct_tests,
                " | ",
                bridge,
                " | ",
                _top_risks(u, 3),
                " |\n",
            )
        out += "\n"
        for i in range(min(len(r.start_here), DETAILED_CANDIDATES)):
            var k = _unit_of(r, r.start_here[i])
            if k < 0:
                continue
            ref u = r.units[k]
            out += "### `" + u.id + "`\n\n"
            out += String(
                u.loc,
                " lines in ",
                len(u.files),
                " files, wave ",
                u.wave,
                ", priority ",
                u.priority,
                ", readiness ",
                u.readiness,
                ", bridge **",
                bridge,
                "**.\n\n",
            )
            for note in u.notes:
                out += "- " + note + "\n"
            for j in range(len(u.risks)):
                var shown = List[String]()
                for s in u.samples[j]:
                    shown.append("`" + s + "`")
                out += String(
                    "- ",
                    risk_title(u.risks[j]),
                    " x",
                    u.counts[j],
                    ": ",
                    _join(shown, ", "),
                    "\n",
                )
            out += "\n"
    out += "## Order by package\n\n"
    out += (
        "Packages come after the workspace packages they use. Inside a"
        " package, port by wave: a unit's imports are in earlier waves.\n\n"
    )
    for p in r.packages:
        var deps = String("")
        if len(p.workspace_deps) > 0:
            deps = ", uses " + _join(p.workspace_deps, ", ")
        var dir = p.dir
        if dir.byte_length() == 0:
            dir = "."
        out += String(
            "### ",
            p.order,
            ". ",
            p.name,
            " (`",
            dir,
            "`, portable, ",
            p.test_files,
            " test files",
            deps,
            ")\n\n",
        )
        out += (
            "| Wave | Unit | Status | Lines | Readiness | Bridge | Main"
            " risks |\n"
        )
        out += "| ---: | --- | --- | ---: | ---: | --- | --- |\n"
        var shown = List[Int]()
        for i in range(len(r.units)):
            if r.units[i].package != p.name:
                continue
            var at = len(shown)
            while at > 0:
                ref q = r.units[shown[at - 1]]
                ref u = r.units[i]
                var before = q.wave < u.wave or (
                    q.wave == u.wave and q.readiness >= u.readiness
                )
                if before:
                    break
                at -= 1
            shown.insert(at, i)
        for i in shown:
            ref u = r.units[i]
            out += String(
                "| ",
                u.wave,
                " | `",
                u.id,
                "` | ",
                _status_label(u.status),
                " | ",
                u.loc,
                " | ",
                u.readiness,
                " | ",
                bridge,
                " | ",
                _top_risks(u, 2),
                " |\n",
            )
        out += "\n"
    if len(r.dependencies) > 0:
        out += "## " + registry + " dependencies\n\n"
        out += "| Package | Units | Mojo | Fit | Note |\n"
        out += "| --- | ---: | --- | --- | --- |\n"
        for d in r.dependencies:
            var repl = d.replacement
            if d.fit == FIT_UNKNOWN:
                repl = "?"
            out += String(
                "| `",
                d.name,
                "` | ",
                d.used_by,
                " | ",
                repl,
                " | ",
                fit_name(d.fit),
                " | ",
                d.note,
                " |\n",
            )
        out += "\n"
    var blocked = List[Int]()
    for i in range(len(r.units)):
        if r.units[i].status == BLOCKED:
            blocked.append(i)
    if len(blocked) > 0:
        out += "## Blocked\n\n"
        for i in blocked:
            ref u = r.units[i]
            var first = String("")
            if len(u.notes) > 0:
                first = u.notes[0]
            out += "- `" + u.id + "`: " + first + "\n"
        out += "\n"
    out += "## Risk guide\n\n"
    var seen = List[Bool]()
    for _ in range(RISK_COUNT):
        seen.append(False)
    for u in r.units:
        for k in u.risks:
            seen[k] = True
    for k in range(RISK_COUNT):
        if seen[k]:
            out += String(
                "- **",
                risk_title(k),
                "** (",
                severity_debug(severity(k)),
                "): ",
                risk_guidance(k),
                "\n",
            )
    return out^


# ---- serde_json::to_string_pretty --------------------------------------------


def _strings(items: List[String], indent: String) -> String:
    if len(items) == 0:
        return "[]"
    var out = String("[\n")
    for i in range(len(items)):
        out += indent + "  " + write_string(items[i])
        if i + 1 < len(items):
            out += ","
        out += "\n"
    out += indent + "]"
    return out^


def _float(x: Float64) raises -> String:
    """serde_json's f64 (ryu): the shortest digits, `.0` on whole numbers;
    Python's repr gives the same for the densities a plan can hold."""
    var text = String(py=Python.import_module("builtins").repr(PythonObject(x)))
    if "e" in text or "n" in text:
        raise Error("density out of range: " + text)
    return text


def to_json(r: Report, bridge_id: String) raises -> String:
    var out = String("{\n")
    out += '  "schema": "' + String(SCHEMA) + '",\n'
    out += '  "language": "' + r.language + '",\n'
    out += '  "summary": {\n'
    out += String('    "packages": ', r.packages_n, ",\n")
    out += String('    "source_files": ', r.source_files, ",\n")
    out += String('    "test_files": ', r.test_files, ",\n")
    out += '    "ui_files": 0,\n'
    out += String('    "loc": ', r.loc, ",\n")
    out += String('    "units": ', len(r.units), ",\n")
    out += String('    "ready": ', r.ready, ",\n")
    out += String('    "caution": ', r.caution, ",\n")
    out += String('    "blocked": ', r.blocked, ",\n")
    out += String('    "keep": ', r.keep, ",\n")
    out += '    "parse_errors": 0\n'
    out += "  },\n"
    if len(r.packages) == 0:
        out += '  "packages": [],\n'
    else:
        out += '  "packages": [\n'
        for i in range(len(r.packages)):
            ref p = r.packages[i]
            out += "    {\n"
            out += '      "name": ' + write_string(p.name) + ",\n"
            out += '      "dir": ' + write_string(p.dir) + ",\n"
            out += String('      "order": ', p.order, ",\n")
            out += '      "runtime": "portable",\n'
            out += (
                '      "workspace_deps": '
                + _strings(p.workspace_deps, "      ")
                + ",\n"
            )
            out += String('      "test_files": ', p.test_files, ",\n")
            out += '      "units": ' + _strings(p.units, "      ") + "\n"
            out += "    }"
            if i + 1 < len(r.packages):
                out += ","
            out += "\n"
        out += "  ],\n"
    if len(r.units) == 0:
        out += '  "units": [],\n'
    else:
        out += '  "units": [\n'
        for i in range(len(r.units)):
            ref u = r.units[i]
            var ind = String("      ")
            out += "    {\n"
            out += ind + '"id": ' + write_string(u.id) + ",\n"
            out += ind + '"package": ' + write_string(u.package) + ",\n"
            out += ind + '"files": ' + _strings(u.files, ind) + ",\n"
            out += ind + String('"loc": ', u.loc, ",\n")
            out += ind + String('"wave": ', u.wave, ",\n")
            out += ind + String('"readiness": ', u.readiness, ",\n")
            out += ind + '"status": "' + _status_label(u.status) + '",\n'
            out += ind + '"bridge": "' + bridge_id + '",\n'
            out += ind + '"platforms": [],\n'
            if len(u.risks) == 0:
                out += ind + '"risks": [],\n'
            else:
                out += ind + '"risks": [\n'
                for k in range(len(u.risks)):
                    var s = severity(u.risks[k])
                    out += ind + "  {\n"
                    out += (
                        ind
                        + '    "risk": "'
                        + risk_names()[u.risks[k]]
                        + '",\n'
                    )
                    out += ind + '    "severity": "' + severity_name(s) + '",\n'
                    out += ind + String('    "count": ', u.counts[k], ",\n")
                    out += (
                        ind
                        + '    "samples": '
                        + _strings(u.samples[k], ind + "    ")
                        + "\n"
                    )
                    out += ind + "  }"
                    if k + 1 < len(u.risks):
                        out += ","
                    out += "\n"
                out += ind + "],\n"
            out += (
                ind
                + '"internal_deps": '
                + _strings(u.internal_deps, ind)
                + ",\n"
            )
            out += ind + '"workspace_deps": [],\n'
            out += (
                ind
                + '"external_deps": '
                + _strings(u.external_deps, ind)
                + ",\n"
            )
            out += ind + String('"direct_tests": ', u.direct_tests, ",\n")
            out += ind + String('"fan_in": ', u.fan_in, ",\n")
            out += ind + '"density": ' + _float(u.density) + ",\n"
            out += ind + String('"priority": ', u.priority, ",\n")
            out += ind + String('"exports": ', u.exports, ",\n")
            out += ind + String('"bridgeable": ', u.bridgeable, ",\n")
            out += ind + '"notes": ' + _strings(u.notes, ind) + "\n"
            out += "    }"
            if i + 1 < len(r.units):
                out += ","
            out += "\n"
        out += "  ],\n"
    out += '  "start_here": ' + _strings(r.start_here, "  ") + ",\n"
    if len(r.dependencies) == 0:
        out += '  "dependencies": []\n'
    else:
        out += '  "dependencies": [\n'
        for i in range(len(r.dependencies)):
            ref d = r.dependencies[i]
            out += "    {\n"
            out += '      "name": ' + write_string(d.name) + ",\n"
            out += String('      "used_by": ', d.used_by, ",\n")
            if d.fit == FIT_UNKNOWN:
                out += '      "replacement": null,\n'
            else:
                out += (
                    '      "replacement": '
                    + write_string(d.replacement)
                    + ",\n"
                )
            out += '      "fit": "' + fit_name(d.fit) + '",\n'
            if d.fit == FIT_UNKNOWN:
                out += '      "note": ""\n'
            else:
                out += '      "note": ' + write_string(d.note) + "\n"
            out += "    }"
            if i + 1 < len(r.dependencies):
                out += ","
            out += "\n"
        out += "  ]\n"
    out += "}\n"
    return out^
