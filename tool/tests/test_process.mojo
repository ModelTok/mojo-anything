from std.os import setenv, unsetenv
from std.os.path import exists
from std.testing import assert_equal, assert_false, assert_true
from std.time import perf_counter_ns

from mojo_anything.process import Command, capture, limit, output, status


def _sh(script: String) -> Command:
    var cmd = Command("sh")
    cmd.args.append("-c")
    cmd.args.append(script)
    return cmd^


def test_captures_both_streams() raises:
    var out = output(_sh("echo out; echo err >&2; exit 3"), 10.0)
    assert_equal(out.code, 3)
    assert_false(out.success)
    assert_false(out.timed_out)
    assert_equal(out.stdout_text(), "out\n")
    assert_equal(out.stderr_text(), "err\n")


def test_stdout_text_is_lossy() raises:
    var out = output(_sh("printf 'a\\377b'"), 10.0)
    assert_equal(len(out.stdout), 3)
    assert_equal(out.stdout_text(), "a�b")


def test_stdin_is_closed() raises:
    var start = perf_counter_ns()
    var out = output(Command("cat"), 10.0)
    assert_true(out.success)
    assert_equal(len(out.stdout), 0)
    assert_true(perf_counter_ns() - start < 5_000_000_000)


def test_env_and_cwd() raises:
    var cmd = _sh('printf "%s|%s|%s" "$MA_SET" "${MA_GONE-unset}" "$(pwd)"')
    cmd.env["MA_SET"] = "yes"
    _ = setenv("MA_GONE", "here")
    cmd.env_remove.append("MA_GONE")
    cmd.cwd = "/"
    var out = output(cmd, 10.0)
    _ = unsetenv("MA_GONE")
    assert_equal(out.stdout_text(), "yes|unset|/")


def test_kills_group_at_limit() raises:
    var pidfile = String("/tmp/mojo-anything-test-process-")
    pidfile += String(Int(perf_counter_ns() % 1_000_000_000))
    var start = perf_counter_ns()
    var out = capture(_sh("sleep 100 & echo $! > " + pidfile + "; wait"), 0.5)
    var took = Float64(perf_counter_ns() - start) / 1e9
    assert_true(out.timed_out)
    assert_true(took < 1.5, String(took))
    var pid = open(pidfile, "r").read().strip()
    # The sleep was in the group: killed with it, so it is gone once reaped.
    var gone = False
    for _ in range(50):
        var state = String("")
        if exists("/proc/" + pid + "/stat"):
            try:
                state = open("/proc/" + pid + "/stat", "r").read()
            except:
                state = ""
        if state.byte_length() == 0 or ") Z " in state:
            gone = True
            break
        _ = output(_sh("sleep 0.05"), 5.0)
    assert_true(gone, "sleep " + pid + " outlived its group")


def test_output_reports_the_limit() raises:
    var message = String("")
    try:
        _ = output(_sh("sleep 30"), 0.3)
    except e:
        message = String(e)
    assert_true(
        message.startswith(
            "`sh -c sleep 30` was still running after 0s and was stopped"
            " (set MOJO_ANYTHING_COMMAND_TIMEOUT to allow longer;"
        ),
        message,
    )


def test_missing_program() raises:
    var message = String("")
    try:
        _ = output(Command("/no/such/program"), 5.0)
    except e:
        message = String(e)
    assert_equal(
        message,
        "running `/no/such/program`: No such file or directory (os error 2)",
    )


def test_status_inherits_streams() raises:
    assert_equal(status(_sh("exit 4"), 10.0), 4)


def test_output_is_kept_and_capped() raises:
    var out = output(_sh("yes | head -c 3000000; echo err >&2"), 20.0)
    assert_equal(len(out.stdout), 1 << 20)
    assert_equal(out.stderr_text(), "err\n")


def test_env_override_of_limit() raises:
    _ = unsetenv("MOJO_ANYTHING_COMMAND_TIMEOUT")
    assert_equal(limit(60.0), 60.0)
    for v in ["2.5", "1e1", "+3"]:
        _ = setenv("MOJO_ANYTHING_COMMAND_TIMEOUT", v)
        assert_true(limit(60.0) != 60.0, v)
    _ = setenv("MOJO_ANYTHING_COMMAND_TIMEOUT", "2.5")
    assert_equal(limit(60.0), 2.5)
    for v in ["abc", "-1", "0", "inf", "nan", " 3", "1_0", ""]:
        _ = setenv("MOJO_ANYTHING_COMMAND_TIMEOUT", v)
        assert_equal(limit(60.0), 60.0, v)
    _ = unsetenv("MOJO_ANYTHING_COMMAND_TIMEOUT")


def main() raises:
    test_captures_both_streams()
    test_stdout_text_is_lossy()
    test_stdin_is_closed()
    test_env_and_cwd()
    test_kills_group_at_limit()
    test_output_reports_the_limit()
    test_missing_program()
    test_status_inherits_streams()
    test_output_is_kept_and_capped()
    test_env_override_of_limit()
    print("test_process: 10 passed")
