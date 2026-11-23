# A small port for the dispatcher checks (`tests/mojo_dispatcher.rs`).

from json import JsonValue


# Port of `add`.
def add(a: Float64, b: Float64) raises -> Float64:
    return a + b


# Port of `fail`.
def fail(x: String) raises -> String:
    raise Error("ArgumentError: " + x)


# Port of `echo`.
def echo(v: JsonValue) raises -> JsonValue:
    return v.copy()


# Port of `repeat`.
def repeat(words: List[String], times: Optional[Int], small: UInt8) raises -> List[String]:
    var out = List[String]()
    for _ in range(times.value() if times else 1):
        for w in words:
            out.append(w + String(small))
    return out^


# Port of `nothing`.
def nothing() raises:
    pass
