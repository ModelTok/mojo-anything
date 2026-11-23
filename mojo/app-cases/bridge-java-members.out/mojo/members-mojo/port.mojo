# The Mojo port of `src/main/java/com/example/members/`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.


# Port of `twice` (`src/main/java/com/example/members/Limits.java:10`).
def twice(value: Int32) raises -> Int32:
    raise Error("not ported: twice")
