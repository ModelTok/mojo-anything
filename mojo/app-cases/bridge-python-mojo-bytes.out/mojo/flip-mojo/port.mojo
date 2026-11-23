# The Mojo port of `flip.py`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from std.python import Python, PythonObject


# Port of `invert` (`flip.py:5`).
# `keep_ascii` defaults to `False` in the source.
def invert(data: PythonObject, keep_ascii: Bool) raises -> PythonObject:
    raise Error("not ported: invert")
