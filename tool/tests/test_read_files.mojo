# analyze_py.py `read_files`: every Python file of a workspace read by
# `read_file`, split over forked worker processes, with the answers in the
# order of the files and equal to reading them one by one in this process.

from std.python import Python, PythonObject
from std.testing import assert_equal, assert_true

from mojo_anything.python_lang import py_helpers


def _fixture() raises -> PythonObject:
    """A folder of files `read_file` answers in each of its ways: ok, declined
    (a syntax error, a comment inside brackets), unreadable (not UTF-8, a
    folder) and missing; returns the (path, rel) pairs."""
    var scope = Python.dict()
    _ = Python.import_module("builtins").exec(
        """
import os, tempfile

def fixture():
    d = os.path.join(tempfile.gettempdir(), "mojo-anything-test-read-files-%d" % os.getpid())
    os.makedirs(os.path.join(d, "pkg"), exist_ok=True)
    files = {
        "a.py": "import os\\n\\ndef f(x: int) -> int:\\n    return x + 1\\n",
        "b.py": "def g(:\\n",
        "c.py": "x = [1,  # here\\n 2]\\n",
        "pkg/d.py": "class C:\\n    def m(self):\\n        while True:\\n            pass\\n",
        "e.py": "",
    }
    for rel, text in files.items():
        with open(os.path.join(d, rel), "w") as f:
            f.write(text)
    with open(os.path.join(d, "bad.py"), "wb") as f:
        f.write(b"x = '\\xff'\\n")
    os.makedirs(os.path.join(d, "dir.py"), exist_ok=True)
    rels = ["a.py", "b.py", "bad.py", "c.py", "dir.py", "missing.py", "pkg/d.py", "e.py"] * 3
    return [(os.path.join(d, r), r) for r in rels]

def pids(h, pairs, workers):
    # Which process read each file.
    real = h["read_file"]
    h["read_file"] = lambda path, rel: ("pid", os.getpid(), rel)
    try:
        return h["read_files"](pairs, workers)
    finally:
        h["read_file"] = real
""",
        scope,
    )
    return scope


def test_same_answers_as_one_by_one() raises:
    var h = py_helpers()
    var t = _fixture()
    var pairs = t["fixture"]()
    var one_by_one = Python.list()
    for i in range(Int(py=Python.import_module("builtins").len(pairs))):
        one_by_one.append(h["read_file"](pairs[i][0], pairs[i][1]))
    var want = String(py=Python.import_module("builtins").repr(one_by_one))
    for workers in [1, 3, 8, 64]:
        var got = h["read_files"](pairs, PythonObject(workers))
        assert_equal(
            String(py=Python.import_module("builtins").repr(got)),
            want,
            "answers with " + String(workers) + " workers",
        )
    var got = h["read_files"](pairs, Python.none())
    assert_equal(
        String(py=Python.import_module("builtins").repr(got)),
        want,
        "answers with the default workers",
    )


def test_workers_are_other_processes() raises:
    var h = py_helpers()
    var t = _fixture()
    var pairs = t["fixture"]()
    var got = t["pids"](h, pairs, PythonObject(3))
    var me = Int(py=Python.import_module("os").getpid())
    var seen = Python.import_module("builtins").set()
    var n = Int(py=Python.import_module("builtins").len(got))
    for i in range(n):
        assert_equal(
            String(py=got[i][2]), String(py=pairs[i][1]), "order of answers"
        )
        assert_true(Int(py=got[i][1]) != me, "read in this process")
        _ = seen.add(got[i][1])
    assert_equal(Int(py=Python.import_module("builtins").len(seen)), 3)


def main() raises:
    test_same_answers_as_one_by_one()
    test_workers_are_other_processes()
    print("test_read_files: 2 passed")
