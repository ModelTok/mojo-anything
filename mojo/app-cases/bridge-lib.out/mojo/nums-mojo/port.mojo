# The Mojo port of `ts/src/nums.ts`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.


# Port of `clamp` (`ts/src/nums.ts:1`).
def clamp(n: Float64, low: Float64, high: Float64) raises -> Float64:
    raise Error("not ported: clamp")
