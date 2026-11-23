# The Mojo port of `src/mathkit/`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from py_num import PyNum


# Port of `scale` (`src/mathkit/ops.py:4`).
# `factor` defaults to `2.0` in the source.
def scale(x: PyNum, factor: PyNum) raises -> PyNum:
    raise Error("not ported: scale")


# Port of `safe_div` (`src/mathkit/ops.py:8`).
def safe_div(a: PyNum, b: PyNum) raises -> PyNum:
    raise Error("not ported: safe_div")


# Port of `exclaim` (`src/mathkit/ops.py:14`).
def exclaim(text: String) raises -> String:
    raise Error("not ported: exclaim")


# Port of `count_items` (`src/mathkit/ops.py:18`).
def count_items(items: List[String]) raises -> PyNum:
    raise Error("not ported: count_items")
