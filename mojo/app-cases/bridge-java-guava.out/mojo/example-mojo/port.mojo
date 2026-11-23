# The Mojo port of `src/main/java/com/example/`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.


# Port of `pad` (`src/main/java/com/example/Names.java:7`).
def pad(s: String) raises -> String:
    raise Error("not ported: pad")
