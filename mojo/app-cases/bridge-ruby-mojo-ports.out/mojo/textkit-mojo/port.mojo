# The Mojo port of `textkit/lib/textkit.rb`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from json import JsonValue


# Port of `repeat` (`textkit/lib/textkit.rb:10`).
def repeat(s: String, n: Int) raises -> String:
    raise Error("not ported: repeat")


# Port of `echo` (`textkit/lib/textkit.rb:20`).
def echo(v: JsonValue) raises -> JsonValue:
    raise Error("not ported: echo")


# Port of `half` (`textkit/lib/textkit.rb:28`).
def half(x: Float64) raises -> Float64:
    raise Error("not ported: half")
