from std.os import makedirs
from std.python import Python
from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns
from std.utils.numerics import inf, nan

from mojo_anything.js_number import js_number_to_string, math_round
from mojo_anything.json import parse_json
from mojo_anything.json_text import (
    JS,
    PYTHON,
    json_equal,
    write_compact,
    write_pretty,
)
from mojo_anything.recording import (
    DiffOutcome,
    apply_known,
    fingerprint,
    known_diffs,
    last_diff,
    save_fingerprint,
    stale,
    track,
    trend,
)
from mojo_anything.tolerance import (
    check,
    line_close,
    lines_match_in_any_order,
    text_matches,
    values_close,
)


def _scratch(tag: String) raises -> String:
    var dir = String("/tmp/mojo-anything-test-cases-") + tag + "-"
    dir += String(Int(perf_counter_ns() % 1_000_000_000))
    makedirs(dir)
    return dir


def _write(path: String, text: String) raises:
    var f = open(path, "w")
    f.write(text)
    f.close()


def _rmtree(path: String) raises:
    _ = Python.import_module("shutil").rmtree(path)


def _lines(text: String) -> List[String]:
    var out = List[String]()
    for l in text.split("\n"):
        out.append(String(l))
    return out^


def _runtime_sum(a: Float64, b: Float64) -> Float64:
    """At run time: literal arithmetic is exact at compile time (0.3)."""
    return a + b


def test_js_number_matches_v8() raises:
    var xs: List[Float64] = [
        0.0,
        -0.0,
        1.0,
        -7.5,
        0.1,
        0.30000000000000004,
        1e21,
        123456789012345680000.0,
        1e-7,
        0.000001,
        5e-324,
        1.7976931348623157e308,
        2.5e-7,
        9007199254740993.0,
        -123456789.0,
        1e300,
        153596401214599.62,
        -25.728225708007812,
        _runtime_sum(0.1, 0.2),
        100.0,
        1e20,
    ]
    var js: List[String] = [
        "0",
        "0",
        "1",
        "-7.5",
        "0.1",
        "0.30000000000000004",
        "1e+21",
        "123456789012345680000",
        "1e-7",
        "0.000001",
        "5e-324",
        "1.7976931348623157e+308",
        "2.5e-7",
        "9007199254740992",
        "-123456789",
        "1e+300",
        "153596401214599.62",
        "-25.728225708007812",
        "0.30000000000000004",
        "100",
        "100000000000000000000",
    ]
    for i in range(len(xs)):
        assert_equal(js_number_to_string(xs[i]), js[i], js[i])
    assert_equal(js_number_to_string(nan[DType.float64]()), "NaN")
    assert_equal(js_number_to_string(-inf[DType.float64]()), "-Infinity")
    assert_equal(js_number_to_string(inf[DType.float64]()), "Infinity")


def test_rounds_as_math_round() raises:
    assert_equal(math_round(2.5), 3.0)
    assert_equal(math_round(-2.5), -2.0)
    assert_equal(math_round(-2.6), -3.0)
    assert_equal(math_round(0.49999999999999994), 0.0)
    assert_equal(math_round(4503599627370495.5), 4503599627370496.0)
    assert_equal(js_number_to_string(math_round(-0.4)), "0")
    assert_true(math_round(-0.4) == 0.0)


def _round_trip(path: String, layout: Int) raises -> Int:
    var text = open(path, "r").read()
    var n = 0
    for raw in text.split("\n"):
        var line = String(raw)
        if line.byte_length() == 0:
            continue
        assert_equal(write_compact(parse_json(line), layout), line)
        n += 1
    return n


def test_case_floats_round_trip() raises:
    # Python units' cases are written by the Python driver, TS units' by Node.
    var n = _round_trip(
        "demo/real-world/python-colorsys-mojo/cases.jsonl", PYTHON
    )
    assert_true(n > 100, String(n))
    n = _round_trip("demo/real-world/vercel-ms-mojo/cases.jsonl", JS)
    assert_true(n > 100, String(n))


def test_json_layout_as_serde() raises:
    var cases: List[String] = [
        "[5e-324,-0.0,1e21,1e16,1e15,100.0,0.0001,1e-5,1e-6,1e-7]",
        '{"zebra":1,"apple":2,"10":3,"é":"\\u0001\\n\\"\\\\/"}',
        "[18446744073709551615,-9223372036854775808,0,true,false,null]",
        "[]",
    ]
    var want: List[String] = [
        "[5e-324,-0.0,1e+21,1e+16,1000000000000000.0,100.0,0.0001,0.00001,1e-6,1e-7]",
        '{"zebra":1,"apple":2,"10":3,"é":"\\u0001\\n\\"\\\\/"}',
        "[18446744073709551615,-9223372036854775808,0,true,false,null]",
        "[]",
    ]
    for i in range(len(cases)):
        assert_equal(write_compact(parse_json(cases[i])), want[i])
    assert_equal(
        write_pretty(parse_json('{"a":[1,{"b":{}}],"c":[]}')),
        '{\n  "a": [\n    1,\n    {\n      "b": {}\n    }\n  ],\n  "c": []\n}',
    )


def test_deep_line_reads() raises:
    var text = String("")
    for _ in range(200):
        text += "["
    text += "1"
    for _ in range(200):
        text += "]"
    assert_equal(write_compact(parse_json(text)), text)


def test_values_within_tolerance() raises:
    var t = 1e-9
    assert_true(
        values_close(parse_json("0.30000000000000004"), parse_json("0.3"), t)
    )
    assert_true(
        values_close(
            parse_json('{"x": [1.0000000001, 2], "n": "a"}'),
            parse_json('{"n": "a", "x": [1.0, 2]}'),
            t,
        )
    )
    assert_false(values_close(parse_json("0.31"), parse_json("0.3"), t))
    assert_false(
        values_close(
            parse_json("1000000000001"), parse_json("1000000000000"), t
        )
    )
    assert_false(values_close(parse_json("3"), parse_json("3.0"), t))
    assert_false(
        values_close(
            parse_json('"0.3"'), parse_json('"0.30000000000000004"'), t
        )
    )
    assert_false(values_close(parse_json("[1.0]"), parse_json("[1.0, 2.0]"), t))
    assert_true(
        values_close(parse_json("1e300"), parse_json("1.0000000000001e300"), t)
    )
    assert_true(check(1e-9))
    assert_false(check(-1.0))
    assert_false(check(1.0))
    assert_false(check(nan[DType.float64]()))


def test_lines_within_tolerance() raises:
    var t = 1e-9
    assert_true(
        line_close(
            "x=0.3 y=-1.5e-3", "x=0.30000000000000004 y=-1.5000000000001e-3", t
        )
    )
    assert_true(line_close("energy 3", "energy 3.0000000000000004", t))
    assert_false(line_close("energy 3", "energy 3.0", t))
    assert_false(line_close("count 10", "count 11", t))
    assert_false(line_close("v1.2", "v1.3", t))
    assert_false(line_close("x=0.3", "y=0.3", t))
    assert_false(line_close("a 0.5", "a 0.5 0.5", t))
    assert_true(line_close("step-2 at 0.1", "step-2 at 0.10000000000000002", t))


def test_unordered_pairs_loose_lines() raises:
    var t = Optional[Float64](1e-9)
    # `10.0` sorts before `2.0` but has to meet `9.999999999999999`.
    assert_true(
        lines_match_in_any_order(
            _lines("2.0\n10.0"), _lines("9.999999999999999\n2.0"), t
        )
    )
    assert_true(
        lines_match_in_any_order(_lines("[..]\n2"), _lines("2.0\n2"), t)
    )
    assert_true(
        lines_match_in_any_order(_lines("b\na\nc"), _lines("c\nb\na"), None)
    )
    assert_false(lines_match_in_any_order(_lines("a\nb"), _lines("a\nc"), None))
    assert_false(
        lines_match_in_any_order(_lines("1.0\n1.0"), _lines("1.0\n2.0"), t)
    )
    assert_true(
        text_matches("a [..] c\n...\nend\n", "a b c\nx\ny\nend\n", None)
    )
    assert_false(text_matches("a\n", "b\n", None))


def test_stale_after_source_edit() raises:
    var root = _scratch("stale")
    makedirs(root + "/src/unit")
    makedirs(root + "/port")
    _write(root + "/src/unit/a.py", "def f(): return 1\n")
    _write(root + "/src/unit/b.py", "def g(): return 2\n")
    var first = fingerprint(root, "src/unit")
    assert_true(first.value()[1] == 2)
    save_fingerprint(root + "/port", root, "src/unit")
    assert_false(stale(root + "/port", root, "src/unit"))
    _write(root + "/src/unit/a.py", "def f(): return 3\n")
    var why = stale(root + "/port", root, "src/unit")
    assert_true(why)
    assert_equal(
        why.value(),
        "src/unit changed since it was recorded: re-run `mojo-anything record "
        + root
        + "/port` so the port is checked against what the original does now",
    )
    _rmtree(root)


def test_fingerprint_matches_rust() raises:
    # FNV-1a over "a.py\0x\0": the Rust hash of the same bytes.
    var root = _scratch("fnv")
    _write(root + "/a.py", "x")
    var got = fingerprint(root, "a.py")
    assert_equal(got.value()[0], "254a5552e059e543")
    _rmtree(root)


def test_trend_and_track() raises:
    assert_false(trend([10, 12, 15], 20).stalled)
    assert_false(trend([10, 12, 12, 12], 20).stalled)
    assert_true(trend([10, 12, 12, 11, 12], 20).stalled)
    assert_false(trend([10, 12, 12, 11, 13], 20).stalled)
    assert_false(trend([20, 20, 20, 20, 20], 20).stalled)
    var dir = _scratch("trend")
    var ports: List[String] = ["a", "b", "c", "d", "e"]
    var passed: List[Int] = [1, 2, 2, 2, 2]
    var last_passed = List[Int]()
    var stalled = False
    for i in range(len(ports)):
        _write(dir + "/port.mojo", ports[i])
        var t = track(dir, passed[i], 5).value().copy()
        last_passed = t.passed.copy()
        stalled = t.stalled
    assert_equal(len(last_passed), 5)
    assert_true(stalled)
    var recorded = last_diff(dir).value()
    assert_equal(recorded[0], 2)
    assert_equal(recorded[1], 5)
    _rmtree(dir)


def test_known_diffs() raises:
    var dir = _scratch("known")
    _write(
        dir + "/known-diffs.jsonl",
        '// comment\n{"fn": "f", "args": [1], "actual": {"ok": 2}}\n',
    )
    var message = String("")
    try:
        _ = known_diffs(dir)
    except e:
        message = String(e)
    assert_true("reason" in message, message)
    _write(
        dir + "/known-diffs.jsonl",
        (
            '{"fn": "f", "args": [1], "actual": {"ok": 2}, "reason": "fixed a'
            ' bug"}\n{"fn": "f", "args": [2], "actual": {"ok": 4}, "reason":'
            ' "other"}\n{"fn": "g", "args": [], "actual": {"ok": 0}, "reason":'
            ' "gone"}\n'
        ),
    )
    var entries = known_diffs(dir)
    var outcome = DiffOutcome(total=3, passed=1, failed=2)
    outcome.mismatches.append(
        parse_json(
            '{"fn": "f", "args": [1], "expected": {"ok": 1}, "actual":'
            ' {"ok": 2}}'
        )
    )
    outcome.mismatches.append(
        parse_json(
            '{"fn": "f", "args": [2], "expected": {"ok": 1}, "actual":'
            ' {"ok": 3}}'
        )
    )
    var out = apply_known(outcome^, entries)
    assert_equal(out.passed, 2)
    assert_equal(out.failed, 1)
    assert_equal(out.accepted, 1)
    assert_equal(len(out.mismatches), 1)
    assert_equal(len(out.stale_known), 2)
    assert_true(
        json_equal(
            out.mismatches[0],
            parse_json(
                '{"actual": {"ok": 3}, "fn": "f", "args": [2], "expected":'
                ' {"ok": 1}}'
            ),
        )
    )
    _rmtree(dir)


def main() raises:
    test_js_number_matches_v8()
    test_rounds_as_math_round()
    test_case_floats_round_trip()
    test_json_layout_as_serde()
    test_deep_line_reads()
    test_values_within_tolerance()
    test_lines_within_tolerance()
    test_unordered_pairs_loose_lines()
    test_stale_after_source_edit()
    test_fingerprint_matches_rust()
    test_trend_and_track()
    test_known_diffs()
    print("test_cases: 12 passed")
