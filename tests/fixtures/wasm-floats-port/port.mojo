# The Mojo port of tests/fixtures/wasm-floats's `src/floats.ts` (`tests/mojo_wasm.rs`).


# Port of `third` (`src/floats.ts:3`).
def third() raises -> Float64:
    # `0.1 + 0.2` on literals is exact in Mojo (0.3): add as Float64, as JS does.
    var a: Float64 = 0.1
    return a + Float64(0.2)


# Port of `negZero` (`src/floats.ts:7`).
def neg_zero() raises -> Float64:
    return -0.0


# Port of `tiny` (`src/floats.ts:11`).
def tiny() raises -> Float64:
    return 5e-324


# Port of `huge` (`src/floats.ts:15`).
def huge() raises -> Float64:
    return 1.7976931348623157e308


# Port of `sum` (`src/floats.ts:19`).
def sum(a: Float64, b: Float64) raises -> Float64:
    return a + b


# Port of `echoAll` (`src/floats.ts:23`).
def echo_all(xs: List[Float64]) raises -> List[Float64]:
    return xs.copy()


# Port of `same` (`src/floats.ts:27`).
def same(text: String) raises -> String:
    return text
