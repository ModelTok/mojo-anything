# The Mojo port of `src/names/`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from py_num import PyNum


# Port of `pick` (`src/names/pick.py:5`).
def pick(type: String, out_: String, port: String) raises -> String:
    raise Error("not ported: pick")


# Port of `match` (`src/names/pick.py:9`).
def match_(case_: String) raises -> String:
    raise Error("not ported: match")


# Port of `lengths` (`src/names/pick.py:13`).
def lengths(items: List[String]) raises -> List[PyNum]:
    raise Error("not ported: lengths")


# Port of `spin` (`src/names/pick.py:17`).
def spin(n: PyNum) raises -> PyNum:
    raise Error("not ported: spin")
