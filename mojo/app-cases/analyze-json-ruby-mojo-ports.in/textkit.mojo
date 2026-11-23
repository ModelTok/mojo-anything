# The Mojo port of tests/fixtures/ruby-mojo-ports/textkit (`tests/ruby_mojo.rs`).

from json import JsonValue


# Port of `Textkit.repeat`.
def repeat(s: String, n: Int) raises -> String:
    if n < 0 or n > 8:
        raise Error("ArgumentError: bad count")
    var out = String()
    for _ in range(n):
        out += s
    return out


# Port of `Textkit.echo`.
def echo(v: JsonValue) raises -> JsonValue:
    return v.copy()


# Port of `Textkit.half`.
def half(x: Float64) raises -> Float64:
    return x / 2
