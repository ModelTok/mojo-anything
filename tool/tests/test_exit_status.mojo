# The error text of a driver or build killed by a signal (Rust's ExitStatus
# Display on Linux: `signal: N (NAME)`, `signal: N` for a signal with no
# name, ` (core dumped)` after either), as harness_py.mojo's `_status` and
# harness_ffi.mojo's `run_status` give it.

from std.python import Python, PythonObject
from std.testing import assert_equal

from mojo_anything.harness_ffi import _ffi
from mojo_anything.harness_py import _helpers


def test_status_text() raises:
    var h = _helpers()
    assert_equal(
        String(py=h["_status"](PythonObject(3 << 8))), "exit status: 3"
    )
    assert_equal(
        String(py=h["_status"](PythonObject(11))), "signal: 11 (SIGSEGV)"
    )
    assert_equal(
        String(py=h["_status"](PythonObject(11 | 0x80))),
        "signal: 11 (SIGSEGV) (core dumped)",
    )
    assert_equal(String(py=h["_status"](PythonObject(40))), "signal: 40")
    assert_equal(
        String(py=h["_status"](PythonObject(40 | 0x80))),
        "signal: 40 (core dumped)",
    )


def test_a_signal_reaches_the_text() raises:
    """A program killed by a signal keeps its wait status, so the text can say
    which signal and whether it dumped core."""
    var f = _ffi()
    var h = _helpers()
    var argv = Python.list()
    for a in ["sh", "-c", "kill -40 $$"]:
        argv.append(PythonObject(a))
    var r = f["run_status"](
        argv, PythonObject("/"), Python.import_module("os").environ.copy()
    )
    assert_equal(String(py=h["_status"](r[0])), "signal: 40")


def main() raises:
    test_status_text()
    test_a_signal_reaches_the_text()
    print("test_exit_status: 2 passed")
