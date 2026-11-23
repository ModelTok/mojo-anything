# The Mojo port of `textkit/textkit.go`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from json import JsonValue


# Port of `Echo` (`textkit/textkit.go:10`).
def echo(s: String) raises -> String:
    raise Error("not ported: Echo")


# Port of `Repeat` (`textkit/textkit.go:13`).
def repeat(s: String, n: Int) raises -> String:
    raise Error("not ported: Repeat")


# Port of `Count` (`textkit/textkit.go:21`).
def count(s: String) raises -> Int:
    raise Error("not ported: Count")


# Port of `Add` (`textkit/textkit.go:24`).
def add(a: UInt64, b: UInt64) raises -> UInt64:
    raise Error("not ported: Add")


# Port of `Split` (`textkit/textkit.go:27`).
def split(s: String) raises -> List[String]:
    raise Error("not ported: Split")


# Port of `Half` (`textkit/textkit.go:30`).
def half(x: Float64) raises -> Float64:
    raise Error("not ported: Half")


# Port of `IsNeg` (`textkit/textkit.go:33`).
def is_neg(x: Float64) raises -> Bool:
    raise Error("not ported: IsNeg")


# Port of `Pair` (`textkit/textkit.go:36`).
def pair(s: String) raises -> JsonValue:
    raise Error("not ported: Pair")
