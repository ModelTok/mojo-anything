# The Mojo port of `src/main/java/com/example/text/`.
#
# Replace each `raise Error("not ported: ...")` with the port of the source function.
# Raise `Error("ValueError: message")` (any builtin exception name) where the source
# raises: the caller gets that exception. After changing a signature, run
# `mojo-anything refresh`; `mojo-anything diff` checks behaviour against the recording.

from json import JsonValue


# Port of `gcd` (`src/main/java/com/example/text/Nums.java:7`).
def gcd(a: Int64, b: Int64) raises -> Int64:
    raise Error("not ported: gcd")


# Port of `mean` (`src/main/java/com/example/text/Nums.java:18`).
def mean(values: List[Float64]) raises -> Float64:
    raise Error("not ported: mean")


# Port of `pages` (`src/main/java/com/example/text/Nums.java:29`).
def pages(total: Int32, per_page: Int32) raises -> Int32:
    raise Error("not ported: pages")


# Port of `slugify` (`src/main/java/com/example/text/Strings.java:14`).
def slugify(text: String, max: Int32) raises -> String:
    raise Error("not ported: slugify")


# Port of `words` (`src/main/java/com/example/text/Strings.java:37`).
def words(text: String) raises -> List[String]:
    raise Error("not ported: words")


# Port of `frequencies` (`src/main/java/com/example/text/Strings.java:48`).
def frequencies(text: String) raises -> JsonValue:
    raise Error("not ported: frequencies")


# Port of `parsePort` (`src/main/java/com/example/text/Strings.java:57`).
def parse_port(text: String) raises -> Int32:
    raise Error("not ported: parsePort")


# Port of `hash` (`src/main/java/com/example/text/Strings.java:66`).
def hash(text: String) raises -> Int32:
    raise Error("not ported: hash")
