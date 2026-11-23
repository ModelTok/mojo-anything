# The Mojo port of `src/main/kotlin/com/example/text/`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from json import JsonValue


# Port of `slugify` (`src/main/kotlin/com/example/text/Strings.kt:4`).
def slugify(text: String, max: Int32) raises -> String:
    raise Error("not ported: slugify")


# Port of `words` (`src/main/kotlin/com/example/text/Strings.kt:27`).
def words(text: String) raises -> List[String]:
    raise Error("not ported: words")


# Port of `frequencies` (`src/main/kotlin/com/example/text/Strings.kt:31`).
def frequencies(text: String) raises -> JsonValue:
    raise Error("not ported: frequencies")


# Port of `gcd` (`src/main/kotlin/com/example/text/Strings.kt:42`).
def gcd(a: Int64, b: Int64) raises -> Int64:
    raise Error("not ported: gcd")


# Port of `pages` (`src/main/kotlin/com/example/text/Strings.kt:55`).
def pages(total: Int32, per_page: Int32) raises -> Int32:
    raise Error("not ported: pages")
