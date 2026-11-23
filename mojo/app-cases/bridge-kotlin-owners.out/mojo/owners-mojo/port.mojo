# The Mojo port of `src/main/kotlin/com/example/owners/`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.


# Port of `slug` (`src/main/kotlin/com/example/owners/Text.kt:4`).
def slug(s: String) raises -> String:
    raise Error("not ported: slug")


# Port of `parse` (`src/main/kotlin/com/example/owners/Text.kt:13`).
def parse(s: String) raises -> Int64:
    raise Error("not ported: parse")


# Port of `sign` (`src/main/kotlin/com/example/owners/Text.kt:22`).
def sign(n: Int64) raises -> Int64:
    raise Error("not ported: sign")
