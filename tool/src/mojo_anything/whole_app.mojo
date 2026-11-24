# `analyze --whole-app` (port of src/whole_app.rs and the whole-app section
# of src/report.rs) for Python workspaces analyze.mojo plans: the entry
# points the manifests and the code give away, every dependency imported or
# declared with its replacement, the port order as pieces and the decisions
# for the user. What the manifests and the code say is read by
# analyze_py.py's `whole_app_facts` (tomllib, Python's re over ASCII-safe
# text); the rest is Mojo over analyze's report.

from std.python import Python, PythonObject

from mojo_anything.json_text import write_string
from mojo_anything.plan import (
    BLOCKED,
    FIT_NONE,
    FIT_PARTIAL,
    FIT_UNKNOWN,
    KEEP,
    Crates,
    Report,
    fit_name,
    waves,
)


@fieldwise_init
struct Entry(Copyable, Movable):
    var kind: String
    var path: String
    var name: String
    var named: Bool
    var evidence: String


@fieldwise_init
struct Dep(Copyable, Movable):
    var name: String
    var declared: Bool
    var used_by: Int
    var fit: Int
    var replacement: String
    var note: String


@fieldwise_init
struct Piece(Copyable, Movable):
    var wave: Int
    var units: List[String]
    var loc: Int
    var tangled: Bool


@fieldwise_init
struct Decision(Copyable, Movable):
    var id: String
    var topic: String
    var question: String
    var recommendation: String


struct WholeApp(Movable):
    var shape: String
    var entries: List[Entry]
    var deps: List[Dep]
    var pieces: List[Piece]
    var decisions: List[Decision]

    def __init__(out self):
        self.shape = "library"
        self.entries = List[Entry]()
        self.deps = List[Dep]()
        self.pieces = List[Piece]()
        self.decisions = List[Decision]()


def _rows(given: PythonObject) raises -> List[Entry]:
    var out = List[Entry]()
    var n = Int(py=Python.import_module("builtins").len(given))
    for i in range(n):
        var e = given[i]
        out.append(
            Entry(
                String(py=e[0]),
                String(py=e[1]),
                String(py=e[2]),
                Int(py=e[3]) == 1,
                String(py=e[4]),
            )
        )
    return out^


def _insert_sorted(mut xs: List[String], v: String):
    """Sorted, without duplicates (a BTreeSet)."""
    var at = len(xs)
    while at > 0 and v < xs[at - 1]:
        at -= 1
    if at > 0 and xs[at - 1] == v:
        return
    xs.insert(at, v)


def _rank(fit: Int) -> Int:
    if fit == FIT_NONE:
        return 0
    if fit == FIT_UNKNOWN:
        return 1
    if fit == FIT_PARTIAL:
        return 2
    return 3


def _dep_before(a: Dep, b: Dep) -> Bool:
    """Fit (none, unknown, partial, good), then users (most first), then
    name."""
    if _rank(a.fit) != _rank(b.fit):
        return _rank(a.fit) < _rank(b.fit)
    if a.used_by != b.used_by:
        return a.used_by > b.used_by
    return a.name < b.name


def _list_before(a: List[String], b: List[String]) -> Bool:
    """Vec<String>'s Ord."""
    for i in range(min(len(a), len(b))):
        if a[i] != b[i]:
            return a[i] < b[i]
    return len(a) < len(b)


def _piece_before(a: Piece, b: Piece) -> Bool:
    if a.wave != b.wave:
        return a.wave < b.wave
    return _list_before(a.units, b.units)


def _same(a: List[Int], b: List[Int]) -> Bool:
    if len(a) != len(b):
        return False
    for i in range(len(a)):
        if a[i] != b[i]:
            return False
    return True


def _join(items: List[String], sep: String) -> String:
    var out = String("")
    for i in range(len(items)):
        if i > 0:
            out += sep
        out += items[i]
    return out^


def _trim_dots(s: String) -> String:
    """trim_end_matches('.')."""
    var bytes = s.as_bytes()
    var end = len(bytes)
    while end > 0 and bytes[end - 1] == 46:
        end -= 1
    return String(s[byte=0:end])


def whole_app(
    r: Report, root: String, py: PythonObject, mut declined: Bool
) raises -> WholeApp:
    """whole_app::whole_app for a Python report; `declined` when what the
    manifests or the code say may be read otherwise than in Rust."""
    var w = WholeApp()
    var files = Python.list()
    for u in r.units:
        for f in u.files:
            files.append(PythonObject(f))
    var got = py["whole_app_facts"](PythonObject(root), files)
    if String(py=got[0]) != "ok":
        declined = True
        return w^
    w.entries = _rows(got[1])
    for found in _rows(got[2]):
        var covered = False
        for e in w.entries:
            if e.kind == found.kind and (
                e.path == found.path or found.path.startswith(e.path + "/")
            ):
                covered = True
        if not covered:
            w.entries.append(found.copy())
    for e in w.entries:
        if e.kind == "cli" and w.shape == "library":
            w.shape = "cli"
    for e in w.entries:
        if e.kind == "server":
            w.shape = "server"
    if w.shape == "library":
        for p in r.packages:
            var path = p.dir
            if path.byte_length() == 0:
                path = "."
            w.entries.append(
                Entry(
                    "library",
                    path,
                    p.name,
                    True,
                    "no main and no server: the package's public API",
                )
            )

    # Every dependency: imported by a unit or declared in a manifest.
    var used_names = List[String]()
    var used_counts = List[Int]()
    for u in r.units:
        for d in u.external_deps:
            var found = -1
            for k in range(len(used_names)):
                if used_names[k] == d:
                    found = k
            if found < 0:
                used_names.append(d)
                used_counts.append(1)
            else:
                used_counts[found] += 1
    var declared = List[String]()
    var given = got[3]
    var n = Int(py=Python.import_module("builtins").len(given))
    for i in range(n):
        declared.append(String(py=given[i]))
    var names = List[String]()
    for d in used_names:
        _insert_sorted(names, d)
    for d in declared:
        _insert_sorted(names, d)
    var crates = Crates(py)
    for name in names:
        var m = crates.find("python", name)
        var used_by = 0
        for k in range(len(used_names)):
            if used_names[k] == name:
                used_by = used_counts[k]
        var dep = Dep(
            name, name in declared, used_by, m.fit, m.replacement, m.note
        )
        var at = len(w.deps)
        while at > 0 and _dep_before(dep, w.deps[at - 1]):
            at -= 1
        w.deps.insert(at, dep^)

    # Pieces: one per unit that moves, or one for units that import each
    # other.
    var movable = List[Int]()
    for i in range(len(r.units)):
        if r.units[i].status != KEEP:
            movable.append(i)
    var edges = List[List[Int]]()
    for k in movable:
        var e = List[Int]()
        for d in r.units[k].internal_deps:
            for j in range(len(movable)):
                if r.units[movable[j]].id == d:
                    e.append(j)
        edges.append(e^)
    var wave = List[Int]()
    var members = List[List[Int]]()
    waves(edges, wave, members)
    var seen = List[List[Int]]()
    for k in range(len(movable)):
        var group = members[k].copy()
        if len(group) == 0:
            group.append(k)
        var sorted = List[Int]()
        for g in group:
            var at = len(sorted)
            while at > 0 and g < sorted[at - 1]:
                at -= 1
            sorted.insert(at, g)
        var again = False
        for s in seen:
            if _same(s, sorted):
                again = True
        if again:
            continue
        seen.append(sorted.copy())
        var units = List[String]()
        var loc = 0
        for g in sorted:
            units.append(r.units[movable[g]].id)
            loc += r.units[movable[g]].loc
        var piece = Piece(
            r.units[movable[k]].wave, units^, loc, len(sorted) > 1
        )
        var at = len(w.pieces)
        while at > 0 and _piece_before(piece, w.pieces[at - 1]):
            at -= 1
        w.pieces.insert(at, piece^)

    # Decisions for the grilling round.
    var entries = List[String]()
    for e in w.entries:
        if e.named:
            entries.append(e.name + " (" + e.path + ")")
        else:
            entries.append(e.path)
    var rec = String(
        "Yes: the Rust crate's public API becomes the library's front door"
    )
    if w.shape == "server":
        rec = (
            "Yes: a Mojo server front door (`app front-door`) takes the server"
            " over first"
        )
    elif w.shape == "cli":
        rec = (
            "Yes: a clap front door (`app front-door`) takes every command"
            " over first"
        )
    _ask(
        w,
        "shape",
        "The app is a "
        + w.shape
        + ", entered through "
        + _join(entries, ", ")
        + ". Port every entry point, in that shape?",
        rec,
    )
    for u in r.units:
        if u.status != KEEP:
            continue
        var why = String("no Rust equivalent")
        if len(u.notes) > 0:
            why = _trim_dots(u.notes[0])
        _ask(
            w,
            "keep " + u.id,
            u.id
            + " stays in the source language ("
            + why
            + "). What replaces it in the Rust app, or does it stay outside?",
            (
                "Keep it outside the Rust app, behind the front door, and"
                " decide its replacement once the rest is Rust"
            ),
        )
    for u in r.units:
        if u.status != BLOCKED:
            continue
        var why = String("see its risks")
        if len(u.notes) > 0:
            why = _trim_dots(u.notes[0])
        _ask(
            w,
            "blocked " + u.id,
            u.id
            + " is blocked: "
            + why
            + ". Rework that part in Rust, or keep the unit outside?",
            (
                "Research the blocker first; then port it with the piece that"
                " uses it"
            ),
        )
    for i in range(len(w.deps)):
        var dep = w.deps[i].copy()
        var users = String("used by ", dep.used_by, " units")
        if dep.used_by == 0:
            users = "declared, no unit imports it"
        elif dep.used_by == 1:
            users = "used by 1 unit"
        var note = _trim_dots(dep.note)
        var noted = String("")
        if note.byte_length() > 0:
            noted = "; " + note
        if dep.fit == FIT_NONE:
            _ask(
                w,
                "dependency " + dep.name,
                "Nothing in Mojo, its pixi packages or CPython does what "
                + dep.name
                + " does ("
                + users
                + noted
                + "). Reimplement what the app uses, or drop the feature?",
                (
                    "Reimplement only the part the app uses, proved by its"
                    " recorded cases"
                ),
            )
        elif dep.fit == FIT_UNKNOWN:
            _ask(
                w,
                "dependency " + dep.name,
                "What replaces "
                + dep.name
                + " in Mojo ("
                + users
                + "): a stdlib module, a pixi package or a Python module?",
                "Research it against primary sources into mojo/research/"
                + dep.name.replace("/", "-").replace(":", "-")
                + ".md before porting what uses it",
            )
        elif dep.fit == FIT_PARTIAL:
            _ask(
                w,
                "dependency " + dep.name,
                dep.name
                + " maps to "
                + dep.replacement
                + " only in part ("
                + users
                + noted
                + "). Use it?",
                "Use "
                + dep.replacement
                + ", and record cases for the behavior it does not cover",
            )
    for i in range(len(w.pieces)):
        if not w.pieces[i].tangled:
            continue
        var piece = w.pieces[i].copy()
        _ask(
            w,
            "tangled units",
            _join(piece.units, ", ")
            + " import each other ("
            + String(piece.loc)
            + " lines). Port them as one piece?",
            String(
                "Yes: one piece in wave ",
                piece.wave,
                ", no glue between its parts",
            ),
        )
    return w^


def _ask(
    mut w: WholeApp, topic: String, question: String, recommendation: String
):
    w.decisions.append(
        Decision(
            String("D", len(w.decisions) + 1), topic, question, recommendation
        )
    )


def whole_app_markdown(w: WholeApp) -> String:
    """report.rs `whole_app`: the section after the plan."""
    var out = String("\n## Whole app\n\n")
    out += "Shape: **" + w.shape + "**.\n\n"
    out += "| Entry point | Kind | Found from |\n"
    out += "| --- | --- | --- |\n"
    for e in w.entries:
        var name = String("")
        if e.named:
            name = e.name + ": "
        out += "| " + name + "`" + e.path + "` | " + e.kind + " | " + e.evidence
        out += " |\n"
    out += "\n### Every dependency\n\n"
    if len(w.deps) == 0:
        out += "None.\n"
    else:
        out += "| Dependency | Declared | Used by | Mojo | Fit | Note |\n"
        out += "| --- | --- | --- | --- | --- | --- |\n"
        for d in w.deps:
            var declared = String("no")
            if d.declared:
                declared = "yes"
            var replacement = String("?")
            if d.fit != FIT_UNKNOWN:
                replacement = d.replacement
            out += String(
                "| `",
                d.name,
                "` | ",
                declared,
                " | ",
                d.used_by,
                " | ",
                replacement,
                " | ",
                fit_name(d.fit),
                " | ",
                d.note,
                " |\n",
            )
    out += "\n### Pieces, in port order\n\n"
    for p in w.pieces:
        var units = List[String]()
        for u in p.units:
            units.append("`" + u + "`")
        out += String("- wave ", p.wave, ": ", _join(units, ", "))
        if p.tangled:
            out += ", tangled: one piece"
        out += String(" (", p.loc, " lines)\n")
    out += "\n### Decisions for the user\n\n"
    for d in w.decisions:
        out += (
            "**"
            + d.id
            + "** ("
            + d.topic
            + "): "
            + d.question
            + "\n\n> "
            + d.recommendation
            + "\n\n"
        )
    return out^


def whole_app_json(w: WholeApp) raises -> String:
    """The report's `whole_app` field as serde_json::to_string_pretty writes
    it, at the report's indentation, without a trailing newline."""
    var out = String('  "whole_app": {\n')
    out += '    "shape": ' + write_string(w.shape) + ",\n"
    if len(w.entries) == 0:
        out += '    "entry_points": [],\n'
    else:
        out += '    "entry_points": [\n'
        for i in range(len(w.entries)):
            ref e = w.entries[i]
            out += "      {\n"
            out += '        "kind": ' + write_string(e.kind) + ",\n"
            out += '        "path": ' + write_string(e.path) + ",\n"
            if e.named:
                out += '        "name": ' + write_string(e.name) + ",\n"
            out += '        "evidence": ' + write_string(e.evidence) + "\n"
            out += "      }"
            if i + 1 < len(w.entries):
                out += ","
            out += "\n"
        out += "    ],\n"
    if len(w.deps) == 0:
        out += '    "dependencies": [],\n'
    else:
        out += '    "dependencies": [\n'
        for i in range(len(w.deps)):
            ref d = w.deps[i]
            out += "      {\n"
            out += '        "name": ' + write_string(d.name) + ",\n"
            if d.declared:
                out += '        "declared": true,\n'
            else:
                out += '        "declared": false,\n'
            out += String('        "used_by": ', d.used_by, ",\n")
            if d.fit == FIT_UNKNOWN:
                out += '        "replacement": null,\n'
            else:
                out += (
                    '        "replacement": '
                    + write_string(d.replacement)
                    + ",\n"
                )
            out += '        "fit": "' + fit_name(d.fit) + '",\n'
            out += '        "note": ' + write_string(d.note) + "\n"
            out += "      }"
            if i + 1 < len(w.deps):
                out += ","
            out += "\n"
        out += "    ],\n"
    if len(w.pieces) == 0:
        out += '    "pieces": [],\n'
    else:
        out += '    "pieces": [\n'
        for i in range(len(w.pieces)):
            ref p = w.pieces[i]
            out += "      {\n"
            out += String('        "wave": ', p.wave, ",\n")
            out += '        "units": [\n'
            for j in range(len(p.units)):
                out += "          " + write_string(p.units[j])
                if j + 1 < len(p.units):
                    out += ","
                out += "\n"
            out += "        ],\n"
            out += String('        "loc": ', p.loc, ",\n")
            if p.tangled:
                out += '        "tangled": true\n'
            else:
                out += '        "tangled": false\n'
            out += "      }"
            if i + 1 < len(w.pieces):
                out += ","
            out += "\n"
        out += "    ],\n"
    if len(w.decisions) == 0:
        out += '    "decisions": []\n'
    else:
        out += '    "decisions": [\n'
        for i in range(len(w.decisions)):
            ref d = w.decisions[i]
            out += "      {\n"
            out += '        "id": ' + write_string(d.id) + ",\n"
            out += '        "topic": ' + write_string(d.topic) + ",\n"
            out += '        "question": ' + write_string(d.question) + ",\n"
            out += (
                '        "recommendation": '
                + write_string(d.recommendation)
                + "\n"
            )
            out += "      }"
            if i + 1 < len(w.decisions):
                out += ","
            out += "\n"
        out += "    ]\n"
    out += "  }"
    return out^
