# The Mojo port of `src/greet.ts`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.


# Port of `greet` (`src/greet.ts:4`).
def greet(name: String, place: String) raises -> String:
    raise Error("not ported: greet")
