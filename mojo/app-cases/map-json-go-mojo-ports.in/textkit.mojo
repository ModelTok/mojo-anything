# The Mojo port of tests/fixtures/go-mojo-ports/textkit (`tests/go_mojo.rs`).

from emberjson import Array
from json import JsonValue


# Port of `Echo` (`textkit.go:10`).
def echo(s: String) raises -> String:
    return s


# Port of `Repeat` (`textkit.go:13`).
def repeat(s: String, n: Int) raises -> String:
    if n < 0 or n > 8:
        raise Error("bad count")
    var out = String()
    for _ in range(n):
        out += s
    return out


# Port of `Count` (`textkit.go:21`).
def count(s: String) raises -> Int:
    return len(s.as_bytes())


# Port of `Add` (`textkit.go:24`).
def add(a: UInt64, b: UInt64) raises -> UInt64:
    return a + b


# Port of `Split` (`textkit.go:27`).
def split(s: String) raises -> List[String]:
    var out = List[String]()
    for part in s.split(","):
        out.append(String(part))
    return out^


# Port of `Half` (`textkit.go:30`).
def half(x: Float64) raises -> Float64:
    return x / 2


# Port of `IsNeg` (`textkit.go:33`).
def is_neg(x: Float64) raises -> Bool:
    return x < 0


# Port of `Pair` (`textkit.go:36`).
def pair(s: String) raises -> JsonValue:
    var out = Array()
    out.append(JsonValue(s))
    out.append(JsonValue(len(s.as_bytes())))
    return JsonValue(out^)
