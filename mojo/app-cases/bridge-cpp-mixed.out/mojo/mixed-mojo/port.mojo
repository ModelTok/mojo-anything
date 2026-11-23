# The Mojo port of `src/mixed.cpp`.
#
# `exports.mojo` exports each function under the C name the C++ shim gives it
# (`cpp__<namespace>__<name>`), and `cpp/wrapper.cpp` gives C++ callers the original
# signatures. Replace each stub's `abort` with the port of the C++ function. Where the
# original throws, add `raises` and raise `Error("<type>: <what()>")` with the text the
# recording has (`std::domain_error: negative input`, or `my::bad (std::runtime_error):
# ...` for a type derived from a standard one); C++ callers get that standard exception
# (for a derived type, its base) with the same `what()`. Integers wrap as C++'s do only where
# the port says so, so use the same widths as the C++ code. `build` turns off
# floating-point contraction (`--fp-mode contract=off`) and `record` compiles the
# original with `-ffp-contract=off`, so `a * b + c` rounds twice on both sides.

from std.os import abort


# Port of `mixed::sum_long` (`src/mixed.cpp:19`).
# C++: `long sum_long(const std::vector<long> &xs)`
def sum_long(xs: List[Int64]) -> Int64:
    abort("not ported: mixed::sum_long")


# Port of `mixed::sum_int64` (`src/mixed.cpp:27`).
# C++: `std::int64_t sum_int64(const std::vector<std::int64_t> &xs)`
def sum_int64(xs: List[Int64]) -> Int64:
    abort("not ported: mixed::sum_int64")


# Port of `mixed::twice_long` (`src/mixed.cpp:35`).
# C++: `std::vector<long> twice_long(const std::vector<long> &xs)`
def twice_long(xs: List[Int64]) -> List[Int64]:
    abort("not ported: mixed::twice_long")


# Port of `mixed::twice_int64` (`src/mixed.cpp:43`).
# C++: `std::vector<std::int64_t> twice_int64(const std::vector<std::int64_t> &xs)`
def twice_int64(xs: List[Int64]) -> List[Int64]:
    abort("not ported: mixed::twice_int64")


# Port of `mixed::check` (`src/mixed.cpp:51`).
# C++: `int check(int x)`
def check(x: Int32) -> Int32:
    abort("not ported: mixed::check")


# Port of `mixed::even` (`src/mixed.cpp:58`).
# C++: `int even(int x)`
def even(x: Int32) -> Int32:
    abort("not ported: mixed::even")


# Port of `mixed::fused` (`src/mixed.cpp:65`).
# C++: `double fused(double a, double b, double c)`
def fused(a: Float64, b: Float64, c: Float64) -> Float64:
    abort("not ported: mixed::fused")


# Port of `mixed::length` (`src/mixed.cpp:70`).
# C++: `std::size_t length(const std::string &s)`
def length(s: String) -> UInt:
    abort("not ported: mixed::length")
