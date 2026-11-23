# `mojo-anything app replay` for CLIs (port of `replay`, `check` and the
# report in src/app.rs, and of `say_replay` in src/main.rs): every recorded
# case runs against the build in a fresh working directory, and the report
# names what differs. A server's cases (`http`), a library's and
# anything else this port does not read exactly as the Rust tool does go to
# the Phase 1 binary, decided before a single case runs (or, for an output
# only the run shows, before anything is written).

from std.python import Python, PythonObject

from mojo_anything.app.cases import (
    CASES_DIR,
    CONFIG_FILE,
    DECLINE,
    EXPECT_CODE,
    EXPECT_FAILED,
    EXPECT_KILLED,
    EXPECT_SKIP,
    REPORT_FILE,
    Config,
    Spec,
    load_config,
    load_specs,
    shell_join,
    shell_split,
    join,
    words_quotable,
)
from mojo_anything.app.diff import Normalizers, compare
from mojo_anything.app.floats import compare_floats
from mojo_anything.app.py import py_helpers, py_len, py_list, py_strings
from mojo_anything.cli_parse import Parsed
from mojo_anything.fallback import fallback
from mojo_anything.json import json_float
from mojo_anything.json_text import write_compact, write_string


@fieldwise_init
struct Problem(Copyable, Movable):
    var field: String
    var detail: String


@fieldwise_init
struct Failure(Copyable, Movable):
    var name: String
    var args: List[String]
    var problems: List[Problem]


struct Outcome(Copyable, Movable):
    var build: List[String]
    var passed: Int
    var total: Int
    var skipped: Int
    var failures: List[Failure]
    var reported: Bool
    var fell_back: List[String]
    var fallback_total: Int
    """What the fallback rate counts against: the cases, or (a library) the
    public API's exports (-1: the cases)."""
    var report: String

    def __init__(out self, var build: List[String], report: String):
        self.build = build^
        self.passed = 0
        self.total = 0
        self.skipped = 0
        self.failures = List[Failure]()
        self.reported = False
        self.fell_back = List[String]()
        self.fallback_total = -1
        self.report = report

    def of(self) -> Int:
        """`Fallback::total`."""
        return self.total if self.fallback_total < 0 else self.fallback_total


@fieldwise_init
struct Options(Copyable, Movable):
    var repo: String
    var build: Optional[String]
    var timeout_secs: Optional[Int]
    var only: Optional[String]


def _is_none(h: PythonObject, x: PythonObject) raises -> Bool:
    return Bool(py=h["is_none"](x))


def _status_text(kind: String, code: Int) -> String:
    if kind == "code":
        return String("exit code ", code)
    if kind == "killed":
        return "killed by a signal"
    return "timed out"


def _check(
    h: PythonObject, norm: Normalizers, spec: Spec, run: PythonObject
) raises -> List[Problem]:
    var problems = List[Problem]()
    var status = run["status"]
    var kind = String(py=status[0])
    var code = Int(py=status[1])
    var ok: Bool
    if spec.status == EXPECT_CODE:
        ok = kind == "code" and code == spec.code
    elif spec.status == EXPECT_FAILED:
        ok = kind == "code" and code != 0
    elif spec.status == EXPECT_KILLED:
        ok = kind == "killed"
    else:
        ok = True
    if not ok:
        var expected: String
        if spec.status == EXPECT_CODE:
            expected = String("exit code ", spec.code)
        elif spec.status == EXPECT_FAILED:
            expected = "a non-zero exit code"
        else:
            expected = "killed by a signal"
        problems.append(
            Problem(
                "status",
                "expected "
                + expected
                + ", got "
                + _status_text(kind, code)
                + "\n",
            )
        )
    if spec.has_stdout:
        var d = compare(
            h,
            norm,
            spec.stdout,
            run["stdout"],
            spec.binary,
            norm.is_unordered(spec.name, "stdout"),
        )
        if d:
            problems.append(Problem("stdout", d.value()))
    if spec.has_stderr:
        var d = compare(
            h,
            norm,
            spec.stderr,
            run["stderr"],
            spec.binary,
            norm.is_unordered(spec.name, "stderr"),
        )
        if d:
            problems.append(Problem("stderr", d.value()))
    if spec.has_effects:
        var d = compare(
            h,
            norm,
            spec.effects,
            h["utf8"](PythonObject("")) if _is_none(h, run["effects"]) else run[
                "effects"
            ],
            spec.binary,
            norm.is_unordered(spec.name, "effects"),
        )
        if d:
            problems.append(Problem("effects", d.value()))
    if spec.has_removed:
        var got = py_strings(run["removed"])
        var same = len(got) == len(spec.removed)
        if same:
            for i in range(len(got)):
                if got[i] != spec.removed[i]:
                    same = False
                    break
        if not same:
            var detail = String("expected removed:\n")
            for p in spec.removed:
                detail += "  " + p + "\n"
            detail += "got removed:\n"
            for p in got:
                detail += "  " + p + "\n"
            problems.append(Problem("removed files", detail))
    if spec.out_dir != "":
        var expected = spec.out_files
        var names = py_strings(h["file_names"](expected))
        var files = run["files"]
        for path in names:
            var field = "file " + path
            if not Bool(py=h["has"](files, PythonObject(path))):
                problems.append(Problem(field, "not written\n"))
                continue
            var width = norm.float_width(path)
            var d: Optional[String]
            if width > 0:
                d = compare_floats(
                    h,
                    expected[PythonObject(path)],
                    files[PythonObject(path)],
                    width,
                    norm.float_tolerance,
                )
            else:
                d = compare(
                    h,
                    norm,
                    expected[PythonObject(path)],
                    files[PythonObject(path)],
                    False,
                    norm.is_unordered(spec.name, field),
                )
            if d:
                problems.append(Problem(field, d.value()))
    return problems^


def report_markdown(h: PythonObject, o: Outcome) raises -> String:
    var out = String("# App replay\n\n")
    out += "Build: `" + shell_join(h, o.build) + "`\n\n"
    out += String("Passed: ", o.passed, "/", o.total, "\n\n")
    if o.skipped > 0:
        out += String("Skipped: ", o.skipped, "\n\n")
    if o.reported:
        out += (
            "Fallback rate: "
            + String(
                py=h["percent"](
                    PythonObject(len(o.fell_back)), PythonObject(o.of())
                )
            )
            + String(
                "% (",
                len(o.fell_back),
                "/",
                o.of(),
                " cases answered by the original)\n\n",
            )
        )
    else:
        out += "Fallback rate: not reported by this build\n\n"
    if len(o.failures) == 0:
        out += "Every case matches.\n"
        return String(py=h["stable_paths"](PythonObject(out)))
    out += "## Failing cases\n"
    for f in o.failures:
        out += (
            "\n### "
            + f.name
            + "\n\nArguments: `"
            + shell_join(h, f.args)
            + "`\n"
        )
        for p in f.problems:
            out += (
                "\n"
                + p.field
                + ":\n\n```diff\n"
                + p.detail.replace("```", "`​``")
                + "```\n"
            )
    return String(py=h["stable_paths"](PythonObject(out)))


def _strings_json(items: List[String], indent: String) -> String:
    if len(items) == 0:
        return "[]"
    var out = String("[\n")
    for i in range(len(items)):
        out += indent + "  " + write_string(items[i])
        out += ",\n" if i + 1 < len(items) else "\n"
    return out + indent + "]"


def outcome_json(h: PythonObject, o: Outcome) raises -> String:
    """`ReplayOutcome` as serde_json's `to_string_pretty` writes it."""
    var out = String("{\n")
    out += '  "build": ' + _strings_json(o.build, "  ") + ",\n"
    out += String('  "passed": ', o.passed, ",\n")
    out += String('  "total": ', o.total, ",\n")
    out += String('  "skipped": ', o.skipped, ",\n")
    if len(o.failures) == 0:
        out += '  "failures": [],\n'
    else:
        out += '  "failures": [\n'
        for i in range(len(o.failures)):
            ref f = o.failures[i]
            out += "    {\n"
            out += '      "case": ' + write_string(f.name) + ",\n"
            out += '      "args": ' + _strings_json(f.args, "      ") + ",\n"
            out += '      "problems": [\n'
            for k in range(len(f.problems)):
                out += "        {\n"
                out += (
                    '          "field": '
                    + write_string(f.problems[k].field)
                    + ",\n"
                )
                out += (
                    '          "detail": '
                    + write_string(f.problems[k].detail)
                    + "\n"
                )
                out += "        }"
                out += ",\n" if k + 1 < len(f.problems) else "\n"
            out += "      ]\n"
            out += "    }"
            out += ",\n" if i + 1 < len(o.failures) else "\n"
        out += "  ],\n"
    if o.reported:
        var rate = Float64(
            py=h["rate"](PythonObject(len(o.fell_back)), PythonObject(o.of()))
        )
        out += '  "fallback": {\n'
        out += String('    "cases": ', len(o.fell_back), ",\n")
        out += String('    "total": ', o.of(), ",\n")
        out += '    "rate": ' + write_compact(json_float(rate)) + ",\n"
        out += '    "names": ' + _strings_json(o.fell_back, "    ") + "\n"
        out += "  },\n"
    else:
        out += '  "fallback": null,\n'
    out += '  "report": ' + write_string(o.report) + "\n"
    return out + "}"


def say_replay(h: PythonObject, o: Outcome) raises -> String:
    var out = String(o.passed, "/", o.total, " cases passed\n")
    if o.reported:
        out += (
            "Fallback rate: "
            + String(
                py=h["percent"](
                    PythonObject(len(o.fell_back)), PythonObject(o.of())
                )
            )
            + String("% (", len(o.fell_back), "/", o.of(), ")\n")
        )
    for i in range(min(len(o.failures), 20)):
        ref f = o.failures[i]
        out += "- " + f.name + ": "
        for k in range(len(f.problems)):
            if k > 0:
                out += ", "
            out += f.problems[k].field
        out += "\n"
    if len(o.failures) > 20:
        out += String("- ... and ", len(o.failures) - 20, " more\n")
    out += "Report: " + o.report + "\n"
    return out


def _has_old_front_door(h: PythonObject, repo: String) raises -> Bool:
    """A library's front door (its cases replay through bindings), or a state
    file Rust's `State::load` would read or complain about."""
    for f in [
        "/mojo/app/mojo-anything.json",
        "/rust/app/mojo-anything.json",
        "/rust/app/rust-anything.json",
    ]:
        if Bool(py=h["exists"](PythonObject(repo + String(f)))):
            return True
    return False


comptime _MAX_TIMEOUT = 2_000_000
"""Seconds: Python's `communicate` waits in `poll`, whose milliseconds stop at
INT_MAX; a longer limit goes to the Phase 1 binary."""


def _runnable(
    h: PythonObject,
    norm: Normalizers,
    command: List[String],
    specs: List[Spec],
    timeout: Int,
) raises -> Bool:
    """Whether every case can run and be compared as the Rust tool would,
    checked before any runs: a time limit `communicate` takes, no NUL in a
    word or a variable and no `=` in a name (Python refuses them where Rust's
    `Command` reports or passes them), and recorded outputs `re` normalises
    as `regex` does."""
    if timeout > _MAX_TIMEOUT:
        return False
    for w in command:
        if not Bool(py=h["safe_word"](PythonObject(w))):
            return False
    for s in specs:
        for w in s.args:
            if not Bool(py=h["safe_word"](PythonObject(w))):
                return False
        for k in s.env_keys:
            if not Bool(py=h["safe_env_key"](PythonObject(k))):
                return False
        for v in s.env_values:
            if not Bool(py=h["safe_word"](PythonObject(v))):
                return False
        if s.has_stdout and not _comparable(h, norm, s.stdout, s.binary):
            return False
        if s.has_stderr and not _comparable(h, norm, s.stderr, s.binary):
            return False
        if s.has_effects and not _comparable(h, norm, s.effects, s.binary):
            return False
        var names = py_strings(h["file_names"](s.out_files))
        for n in names:
            if norm.float_width(n) > 0:
                continue
            if not _comparable(h, norm, s.out_files[PythonObject(n)], False):
                return False
    return True


def _comparable(
    h: PythonObject, norm: Normalizers, blob: PythonObject, binary: Bool
) raises -> Bool:
    """Whether a recorded output normalises as the Rust tool's would: its
    classes as `regex` reads them and, with `key-order`, JSON as serde_json
    reads it."""
    if not norm.safe(h, blob):
        return False
    if not norm.key_order or binary:
        return True
    var text = h["text_of"](blob)
    if not Bool(py=text[0]):
        return True
    try:
        _ = norm.canonical(h, norm.apply(h, String(py=text[1])))
    except e:
        if String(e) == DECLINE:
            return False
        raise e
    return True


struct ReplaySetup(Movable):
    """What app.rs `replay` settles before it replays a CLI's cases or a
    server's: the repository, the settings, the build and the time limit;
    or a library's state (library.mojo), whose units replay through their
    bindings instead."""

    var repo: String
    var config: Config
    var norm: Normalizers
    var command: List[String]
    var timeout: Int
    var library: PythonObject
    """py library_state's state, or None when this is no library."""

    def __init__(
        out self,
        repo: String,
        var config: Config,
        var norm: Normalizers,
        var command: List[String],
        timeout: Int,
        library: PythonObject,
    ):
        self.repo = repo
        self.config = config^
        self.norm = norm^
        self.command = command^
        self.timeout = timeout
        self.library = library

    def is_library(self) raises -> Bool:
        return not (self.library is PythonObject(None))


def replay_setup(h: PythonObject, opts: Options) raises -> ReplaySetup:
    var canon = h["canonical"](PythonObject(opts.repo))
    if String(py=canon[0]) == "odd":
        raise Error(DECLINE)
    if String(py=canon[0]) != "ok":
        raise Error("no folder " + opts.repo + ": " + String(py=canon[1]))
    var repo = String(py=canon[1])
    var dir = join(repo, CASES_DIR)
    var loaded = load_config(h, repo)
    if not loaded and _has_old_front_door(h, repo):
        # app.rs: a library's state (State::load), when nothing was
        # recorded; any other state, or one serde might read otherwise, goes
        # to the Phase 1 binary.
        if not Bool(py=h.__contains__("library_state")):
            raise Error(DECLINE)
        var st = h["library_state"](PythonObject(repo))
        if String(py=st[0]) != "lib":
            raise Error(DECLINE)
        if opts.build:
            raise Error(
                String(py=st[1]["name"])
                + " is a library: its cases replay through each unit's"
                " bindings, so --build does not apply"
            )
        var none = Config()
        var norm = Normalizers(h, none)
        return ReplaySetup(repo, none^, norm^, List[String](), 0, st[1])
    var command: List[String]
    if opts.build:
        command = shell_split(opts.build.value())
    elif loaded:
        command = loaded.value().run.copy()
    else:
        raise Error(
            "no "
            + CONFIG_FILE
            + " in "
            + dir
            + ": run `mojo-anything app record` first, or pass --build"
        )
    if len(command) == 0:
        raise Error("the build command is empty")
    var config = loaded.value().copy() if loaded else Config()
    var norm = Normalizers(h, config)
    var timeout = (
        opts.timeout_secs.value() if opts.timeout_secs else config.timeout_secs
    )
    return ReplaySetup(
        repo, config^, norm^, command^, timeout, PythonObject(None)
    )


def replay(h: PythonObject, opts: Options, s: ReplaySetup) raises -> Outcome:
    """The rest of app.rs `replay`, for a CLI's cases."""
    var repo = s.repo
    var dir = join(repo, CASES_DIR)
    ref config = s.config
    ref norm = s.norm
    var command = s.command.copy()
    var timeout = s.timeout
    var all = load_specs(h, dir)
    var specs = List[Spec]()
    if opts.only:
        var names = String("")
        for i in range(len(all)):
            if i > 0:
                names += ", "
            names += all[i].name
            if all[i].name == opts.only.value():
                specs.append(all[i].copy())
        if len(specs) == 0:
            raise Error(
                "no case named "
                + opts.only.value()
                + "; the cases are: "
                + names
            )
    else:
        specs = all^
    var base = PythonObject(None)
    if len(config.fresh) > 0:
        var files_dir = dir + "/files"
        if not Bool(py=h["is_dir"](PythonObject(files_dir))):
            raise Error(
                "no " + files_dir + ": record again to snapshot the fresh files"
            )
        base = PythonObject(files_dir)
    # The report quotes words as Rust's `char::is_alphanumeric` decides.
    if not words_quotable(h, command):
        raise Error(DECLINE)
    for s in specs:
        if not words_quotable(h, s.args):
            raise Error(DECLINE)
    if not _runnable(h, norm, command, specs, timeout):
        raise Error(DECLINE)
    var jobs = Python.list()
    var ran = List[Int]()
    for i in range(len(specs)):
        ref s = specs[i]
        if s.status == EXPECT_SKIP:
            continue
        var env_add = Python.list()
        for k in range(len(s.env_keys)):
            var pair = Python.list()
            pair.append(PythonObject(s.env_keys[k]))
            pair.append(PythonObject(s.env_values[k]))
            env_add.append(pair)
        var stdin = s.stdin
        jobs.append(
            h["new_job"](
                py_list(command),
                PythonObject(repo),
                py_list(s.args),
                stdin,
                env_add,
                py_list(s.env_remove),
                PythonObject(timeout),
                s.files,
                py_list(s.remove),
                base,
                config.effects_job(),
            )
        )
        ran.append(i)
    var results = h["run_all"](jobs, PythonObject(config.serial()))
    var outcome = Outcome(command^, dir + "/" + REPORT_FILE)
    # The first error, in case order, as the Rust tool's `result?`.
    for k in range(py_len(results)):
        var kind = String(py=h["result_kind"](results[k]))
        if kind == "odd":
            raise Error(DECLINE)
        if kind == "error":
            raise Error(String(py=results[k]["error"]))
    var next = 0
    for i in range(len(specs)):
        ref s = specs[i]
        if s.status == EXPECT_SKIP:
            outcome.skipped += 1
            continue
        var run = results[next]
        next += 1
        var problems = _check(h, norm, s, run)
        outcome.total += 1
        if Bool(py=run["reported"]):
            outcome.reported = True
        if Bool(py=run["fallback"]):
            outcome.fell_back.append(s.name)
        if len(problems) == 0:
            outcome.passed += 1
        else:
            outcome.failures.append(Failure(s.name, s.args.copy(), problems^))
    var text = report_markdown(h, outcome)
    var err = String(
        py=h["write_bytes"](
            PythonObject(outcome.report), h["utf8"](PythonObject(text))
        )
    )
    if err != "":
        raise Error("writing " + outcome.report + ": " + err)
    return outcome^
