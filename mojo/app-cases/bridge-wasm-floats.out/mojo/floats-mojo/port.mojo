# The Mojo port of `src/floats.ts`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.


# Port of `third` (`src/floats.ts:3`).
def third() raises -> Float64:
    raise Error("not ported: third")


# Port of `negZero` (`src/floats.ts:7`).
def neg_zero() raises -> Float64:
    raise Error("not ported: negZero")


# Port of `tiny` (`src/floats.ts:11`).
def tiny() raises -> Float64:
    raise Error("not ported: tiny")


# Port of `huge` (`src/floats.ts:15`).
def huge() raises -> Float64:
    raise Error("not ported: huge")


# Port of `sum` (`src/floats.ts:19`).
def sum(a: Float64, b: Float64) raises -> Float64:
    raise Error("not ported: sum")


# Port of `echoAll` (`src/floats.ts:23`).
def echo_all(xs: List[Float64]) raises -> List[Float64]:
    raise Error("not ported: echoAll")


# Port of `same` (`src/floats.ts:27`).
def same(text: String) raises -> String:
    raise Error("not ported: same")
