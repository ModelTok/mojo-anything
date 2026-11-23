# `app record` and `app replay` in Mojo: the unit tests of src/app.rs that
# cover what is ported, by name, and the Mojo binary run next to the Phase 1
# binary (tool/fallback/mojo-anything, the recording's source) on the same
# folders, compared byte for byte: stdout, stderr, the exit code and the
# report, with no fallback logged.

from std.os import getenv
from std.python import Python, PythonObject
from std.testing import assert_equal, assert_false, assert_true

from mojo_anything.app.cases import (
    Config,
    DECLINE,
    shell_split,
    shell_tokens,
)
from mojo_anything.app.diff import Normalizers, compare, render_diff
from mojo_anything.app.py import py_helpers
from mojo_anything.tolerance import text_matches

comptime FALLBACK = "tool/fallback/mojo-anything"
comptime MOJO = "tool/build/mojo-anything"


def _py() raises -> PythonObject:
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, shutil, subprocess, tempfile

def fixture(name, src):
    d = os.path.join(tempfile.gettempdir(), "mojo-anything-test-app-%s-%d" % (name, os.getpid()))
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

def get(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except OSError:
        return "<missing>"

def gone(path):
    shutil.rmtree(path, ignore_errors=True)

def run(binary, args, cwd, log):
    env = dict(os.environ)
    env.pop("MOJO_ANYTHING_FALLBACK_LOG", None)
    if log:
        if os.path.exists(log):
            os.remove(log)
        env["MOJO_ANYTHING_FALLBACK_LOG"] = log
    p = subprocess.run([os.path.abspath(binary)] + list(args), cwd=cwd, env=env,
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=600)
    return (p.returncode, p.stdout.decode("utf-8", "replace"), p.stderr.decode("utf-8", "replace"))
""",
        scope,
    )
    return scope


def _bytes(h: PythonObject, s: String) raises -> PythonObject:
    return h["utf8"](PythonObject(s))


def _norm(h: PythonObject, tol: Optional[Float64]) raises -> Normalizers:
    var c = Config()
    c.float_tolerance = tol
    return Normalizers(h, c)


def _same(
    h: PythonObject, norm: Normalizers, e: String, a: String, unordered: Bool
) raises -> Bool:
    return not compare(h, norm, _bytes(h, e), _bytes(h, a), False, unordered)


# --- src/app.rs unit tests ------------------------------------------------------


def test_reports_do_not_carry_sandbox_paths() raises:
    var h = py_helpers()
    var tmp = String(py=h["tmp_root"]()).rstrip("/")
    var line = "-cwd " + tmp + "/mojo-anything-app-run-4242-7/cwd\n"
    var stable = String(py=h["stable_paths"](PythonObject(line)))
    assert_true(stable.find("4242") < 0, stable)
    assert_true(stable.find("$TMPDIR") >= 0, stable)
    assert_equal(
        stable,
        String(
            py=h["stable_paths"](PythonObject(line.replace("4242-7", "99-0")))
        ),
    )


def test_unordered_lines_pair_up_by_value_within_the_tolerance() raises:
    var h = py_helpers()
    var norm = _norm(h, Float64(1e-9))
    var e = "n 2.0\nn 10.0\n"
    var a = "n 2.0\nn 9.999999999999999\n"
    assert_true(_same(h, norm, e, a, False))
    assert_true(_same(h, norm, e, a, True))
    assert_false(_same(h, norm, e, "n 2.0\nn 11.0\n", True))
    assert_true(_same(h, norm, e, "n 9.999999999999999\nn 2.0\n", True))


def test_unordered_lines_pair_up_around_a_wildcard() raises:
    var h = py_helpers()
    var norm = _norm(h, Float64(1e-9))
    var e = "n 10.0\nn [..]\n"
    assert_true(_same(h, norm, e, "n 10.0\nn 2.0\n", True))
    assert_true(_same(h, norm, e, "n 2.0\nn 10.0\n", True))
    assert_true(_same(h, norm, e, "n 2.0\nn 9.999999999999999\n", True))
    assert_false(_same(h, norm, e, "n 2.0\nn 3.0\n", True))


def test_unordered_lines_keep_a_plain_permutation_matching() raises:
    var h = py_helpers()
    var norm = _norm(h, Float64(1e-9))
    assert_true(_same(h, norm, "n 2\nn 2.0\n", "n 2.0\nn 2\n", True))
    assert_false(_same(h, norm, "n 2\nn 2\n", "n 2.0\nn 2.0\n", True))


def test_unordered_lines_without_a_tolerance_still_compare_as_text() raises:
    var h = py_helpers()
    var norm = _norm(h, None)
    assert_true(_same(h, norm, "b\na\n", "a\nb\n", True))
    assert_false(_same(h, norm, "b\na\n", "a\nc\n", True))
    assert_false(_same(h, norm, "b\na\n", "a\n", True))
    assert_false(
        _same(h, norm, "n 10.0\nn 2.0\n", "n 2.0\nn 9.999999999999999\n", True)
    )


def test_replay_deadline_covers_descendants_that_keep_pipes_open() raises:
    var h = py_helpers()
    var t = Python.import_module("time")
    for script in ["sleep 6 & wait", "sleep 6 & exit 0"]:
        var command = Python.list()
        command.append(PythonObject("/bin/sh"))
        command.append(PythonObject("-c"))
        command.append(PythonObject(script))
        var job = h["new_job"](
            command,
            PythonObject("."),
            Python.list(),
            _bytes(h, ""),
            Python.list(),
            Python.list(),
            PythonObject(0.2),
            Python.dict(),
            Python.list(),
        )
        var start = Float64(py=t.monotonic())
        var run = h["run_in"](job)
        assert_true(Float64(py=t.monotonic()) - start < 3.0, script)
        assert_equal(String(py=run["status"][0]), "timeout")


def test_matching_follows_trycmd() raises:
    assert_true(text_matches("a\nb\n", "a\nb\n", None))
    assert_true(text_matches("now: [..]\n", "now: 1234\n", None))
    assert_true(text_matches("x [..] y [..] z\n", "x 1 y 2 y 3 z\n", None))
    assert_false(text_matches("x [..] z\n", "x 1 y\n", None))
    assert_true(text_matches("head\n...\ntail\n", "head\n1\n2\ntail\n", None))
    assert_true(text_matches("head\n...\ntail\n", "head\ntail\n", None))
    assert_false(text_matches("head\ntail\n", "head\nmid\ntail\n", None))
    assert_true(text_matches("a\r\nb", "a\nb\n", None))


def test_numbers_match_within_the_tolerance() raises:
    var e = "step 1\nenergy 0.3\nat [..]\n"
    var a = "step 1\nenergy 0.30000000000000004\nat 12:00\n"
    assert_false(text_matches(e, a, None))
    assert_true(text_matches(e, a, Float64(1e-9)))
    assert_false(
        text_matches(e, "step 2\nenergy 0.3\nat 12:00\n", Float64(1e-9))
    )
    assert_true(render_diff(e, a, Float64(1e-9)).find("energy") < 0)


def test_timestamps_cover_javascript_date_strings() raises:
    var h = py_helpers()
    var c = Config()
    c.normalize.append("timestamps")
    var norm = Normalizers(h, c)
    assert_equal(
        norm.apply(
            h,
            (
                "Generated on Sat Nov 21 2026 01:30:12 GMT+0300 (Türkiye"
                " Standard Time) - ok"
            ),
        ),
        "Generated on [..] - ok",
    )
    assert_equal(norm.apply(h, "Mon Jan 05 2026 09:00:00 GMT-0800"), "[..]")
    assert_equal(norm.apply(h, "at 2026-11-16T10:00:00Z"), "at [..]")
    assert_equal(norm.apply(h, "Saturday 12"), "Saturday 12")


def test_normalizers_by_name() raises:
    var h = py_helpers()
    var c = Config()
    c.normalize.append("timestamps")
    c.normalize.append("uuids")
    c.normalizer_names.append("req")
    c.normalizer_patterns.append("req-\\d+")
    var norm = Normalizers(h, c)
    assert_equal(
        norm.apply(
            h,
            (
                "at 2026-11-16T10:00:00.123Z id"
                " 123e4567-e89b-12d3-a456-426614174000 req-77"
            ),
        ),
        "at [..] id [..] [..]",
    )
    # `key-order` re-writes JSON as serde_json does: not ported, declined.
    c.normalize.append("key-order")
    var declined = False
    try:
        _ = Normalizers(h, c)
    except e:
        declined = String(e) == DECLINE
    assert_true(declined)
    c.normalize.append("nope")
    var refused = String("")
    try:
        _ = Normalizers(h, c)
    except e:
        refused = String(e)
    assert_equal(
        refused,
        (
            "unknown normalizer `nope`: use timestamps, uuids, key-order or"
            " define it as `name=regex`"
        ),
    )


def test_patterns_rust_reads_otherwise_are_declined() raises:
    var h = py_helpers()
    for p in [
        "a$",
        "(?i)x",
        "(?=x)y",
        "x*",
        "\\bq?\\b",
        "[[:alpha:]]",
        "\\pL",
        "a{",
        "a{,3}",
        "(a)\\1",
        "[a-z&&[^x]]",
    ]:
        var r = h["compile_normalizer"](PythonObject(p))
        assert_false(Bool(py=r[0]), p)
    for p in ["req-\\d+", "/tmp/mojo-anything-[A-Za-z0-9_.-]+", "x{2,}"]:
        var r = h["compile_normalizer"](PythonObject(p))
        assert_true(Bool(py=r[0]), p)


def test_shell_words() raises:
    var w = shell_split("cargo run -q -- \"a b\" 'c d' e\\ f")
    assert_equal(len(w), 7)
    assert_equal(w[4], "a b")
    assert_equal(w[5], "c d")
    assert_equal(w[6], "e f")
    var piped = String("")
    try:
        _ = shell_split("a | b")
    except e:
        piped = String(e)
    assert_equal(
        piped,
        (
            "`a | b` uses the shell operator `|`: put the pipeline in a script"
            " and give its path"
        ),
    )
    assert_false(Bool(shell_tokens("echo $(date)")))
    assert_false(Bool(shell_tokens("echo `date`")))
    var esc = shell_split("echo \\$(date) \\`date\\`")
    assert_equal(esc[1], "$(date)")
    assert_equal(esc[2], "`date`")
    assert_equal(shell_split("echo one\\\\two")[1], "one\\two")


# --- the Mojo binary next to the Phase 1 binary ------------------------------------


def _both(
    t: PythonObject, args: List[String], cwd: String, report: String
) raises -> String:
    """Runs both binaries with `args` in `cwd` and returns the log of the
    Mojo run's fallbacks, after checking stdout, stderr, the exit code and
    the report file are the same."""
    var pargs = Python.list()
    for a in args:
        pargs.append(PythonObject(a))
    var none = PythonObject("")
    var old = t["run"](PythonObject(FALLBACK), pargs, PythonObject(cwd), none)
    var old_report = String(py=t["get"](PythonObject(report)))
    var log = cwd + ".fallback.log"
    var new = t["run"](
        PythonObject(MOJO), pargs, PythonObject(cwd), PythonObject(log)
    )
    var new_report = String(py=t["get"](PythonObject(report)))
    var shown = String("")
    for a in args:
        shown += " " + a
    assert_equal(String(py=new[1]), String(py=old[1]), "stdout of" + shown)
    assert_equal(String(py=new[2]), String(py=old[2]), "stderr of" + shown)
    assert_equal(Int(py=new[0]), Int(py=old[0]), "exit code of" + shown)
    assert_equal(new_report, old_report, "report of" + shown)
    return String(py=t["get"](PythonObject(log)))


def _replay_case(
    t: PythonObject, name: String, args: List[String]
) raises -> String:
    var d = String(
        py=t["fixture"](
            PythonObject(name),
            PythonObject("mojo/app-cases/app-replay-cli-python.in"),
        )
    )
    var log = _both(t, args, d, d + "/mojo/app-cases/replay-report.md")
    _ = t["gone"](PythonObject(d))
    return log


def test_replay_matches_the_phase1_binary_on_a_cli() raises:
    var t = _py()
    var runs = List[List[String]]()
    runs.append(["app", "replay", "."])
    runs.append(["app", "replay", ".", "--json"])
    runs.append(["app", "replay", ".", "--case", "example-001-upper"])
    runs.append(["app", "replay", ".", "--case", "nope"])
    runs.append(["app", "replay", ".", "--build", "false"])
    runs.append(["app", "replay", ".", "--build", "false", "--json"])
    runs.append(["app", "replay", ".", "--build", "no-such-program-x"])
    runs.append(["app", "replay", ".", "--build", ""])
    runs.append(["app", "replay", ".", "--build", "a | b"])
    runs.append(["app", "replay", ".", "--build", "'open"])
    runs.append(["app", "replay", "missing-dir"])
    for i in range(len(runs)):
        var log = _replay_case(t, String("cli-", i), runs[i])
        assert_equal(log, "", "fell back")


def test_replay_without_cases_matches_the_phase1_binary() raises:
    var t = _py()
    var d = String(py=t["fixture"](PythonObject("empty"), PythonObject("")))
    var r = d + "/mojo/app-cases/replay-report.md"
    assert_equal(_both(t, ["app", "replay"], d, r), "")
    assert_equal(_both(t, ["app", "replay", ".", "--build", "true"], d, r), "")
    _ = t["put"](PythonObject(d + "/mojo/app-cases/x.txt"), PythonObject(""))
    assert_equal(_both(t, ["app", "replay", ".", "--build", "true"], d, r), "")
    _ = t["gone"](PythonObject(d))


def test_replay_of_a_server_goes_to_the_phase1_binary() raises:
    var t = _py()
    var d = String(
        py=t["fixture"](
            PythonObject("server"),
            PythonObject("mojo/app-cases/app-replay-cli-python.in"),
        )
    )
    var cfg = d + "/mojo/app-cases/mojo-anything.json"
    _ = t["put"](
        PythonObject(cfg),
        PythonObject(
            '{"schema": "mojo-anything/app-cases@1", "name": "x", "run":'
            ' ["python3", "tcli.py"], "normalize": ["key-order"]}'
        ),
    )
    var log = _both(
        t, ["app", "replay", "."], d, d + "/mojo/app-cases/replay-report.md"
    )
    assert_equal(log, "app replay .\n")
    _ = t["gone"](PythonObject(d))


def test_record_checks_match_the_phase1_binary() raises:
    var t = _py()
    var d = String(py=t["fixture"](PythonObject("record"), PythonObject("")))
    var r = d + "/mojo/app-cases/mojo-anything.json"
    var runs = List[List[String]]()
    runs.append(["app", "record"])
    runs.append(["app", "record", "missing-dir", "--", "true"])
    runs.append(["app", "record", ".", "--float-file", "x", "--", "true"])
    runs.append(["app", "record", ".", "--float-file", "a=f16le", "--", "true"])
    runs.append(
        [
            "app",
            "record",
            ".",
            "--float-file",
            "a=b=f64le",
            "--float-file",
            "c",
            "--",
            "true",
        ]
    )
    runs.append(["app", "record", ".", "--normalize", "nope", "--", "true"])
    runs.append(
        [
            "app",
            "record",
            ".",
            "--normalize",
            "id=x",
            "--normalize",
            "uuids",
            "--normalize",
            "z",
            "--",
            "true",
        ]
    )
    for i in range(len(runs)):
        assert_equal(_both(t, runs[i], d, r), "", "fell back")
    _ = t["gone"](PythonObject(d))


def test_a_recording_goes_to_the_phase1_binary() raises:
    var t = _py()
    var d = String(
        py=t["fixture"](
            PythonObject("record-run"),
            PythonObject("mojo/app-cases/app-record-cli-python.in"),
        )
    )
    var log = _both(
        t,
        ["app", "record", ".", "--no-traps", "--", "python3", "tcli.py"],
        d,
        d + "/mojo/app-cases/example-001-upper.stdout",
    )
    assert_equal(log, "app record .\n")
    _ = t["gone"](PythonObject(d))


def main() raises:
    test_reports_do_not_carry_sandbox_paths()
    test_unordered_lines_pair_up_by_value_within_the_tolerance()
    test_unordered_lines_pair_up_around_a_wildcard()
    test_unordered_lines_keep_a_plain_permutation_matching()
    test_unordered_lines_without_a_tolerance_still_compare_as_text()
    test_replay_deadline_covers_descendants_that_keep_pipes_open()
    test_matching_follows_trycmd()
    test_numbers_match_within_the_tolerance()
    test_timestamps_cover_javascript_date_strings()
    test_normalizers_by_name()
    test_patterns_rust_reads_otherwise_are_declined()
    test_shell_words()
    test_replay_matches_the_phase1_binary_on_a_cli()
    test_replay_without_cases_matches_the_phase1_binary()
    test_replay_of_a_server_goes_to_the_phase1_binary()
    test_record_checks_match_the_phase1_binary()
    test_a_recording_goes_to_the_phase1_binary()
    print("test_app: 17 passed")
