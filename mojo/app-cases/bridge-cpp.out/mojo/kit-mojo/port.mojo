# The Mojo port of `src/kit.cpp`.
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


# Port of `kit::add` (`src/kit.cpp:9`).
# C++: `int add(int a, int b)`
def add(a: Int32, b: Int32) -> Int32:
    abort("not ported: kit::add")


# Port of `kit::wide` (`src/kit.cpp:14`).
# C++: `std::int64_t wide(std::int64_t a, std::int64_t b)`
def wide(a: Int64, b: Int64) -> Int64:
    abort("not ported: kit::wide")


# Port of `kit::wrap` (`src/kit.cpp:19`).
# C++: `unsigned wrap(unsigned a, unsigned b)`
def wrap(a: UInt32, b: UInt32) -> UInt32:
    abort("not ported: kit::wrap")


# Port of `kit::count_bytes` (`src/kit.cpp:24`).
# C++: `std::size_t count_bytes(const std::string &s)`
def count_bytes(s: String) -> UInt:
    abort("not ported: kit::count_bytes")


# Port of `kit::half` (`src/kit.cpp:29`).
# C++: `float half(float x)`
def half(x: Float32) -> Float32:
    abort("not ported: kit::half")


# Port of `kit::mean` (`src/kit.cpp:34`).
# C++: `double mean(const std::vector<double> &xs)`
def mean(xs: List[Float64]) -> Float64:
    abort("not ported: kit::mean")


# Port of `kit::evens` (`src/kit.cpp:42`).
# C++: `std::vector<int> evens(std::vector<int> xs)`
def evens(xs: List[Int32]) -> List[Int32]:
    abort("not ported: kit::evens")


# Port of `kit::scale` (`src/kit.cpp:51`).
# C++: `std::vector<double> scale(const std::vector<double> &xs, double k)`
def scale(xs: List[Float64], k: Float64) -> List[Float64]:
    abort("not ported: kit::scale")


# Port of `kit::is_upper` (`src/kit.cpp:59`).
# C++: `bool is_upper(const std::string &s)`
def is_upper(s: String) -> Bool:
    abort("not ported: kit::is_upper")


# Port of `kit::shout` (`src/kit.cpp:67`).
# C++: `std::string shout(std::string s)`
def shout(s: String) -> String:
    abort("not ported: kit::shout")


# Port of `kit::checked_sqrt` (`src/kit.cpp:74`).
# C++: `double checked_sqrt(double x)`
def checked_sqrt(x: Float64) -> Float64:
    abort("not ported: kit::checked_sqrt")


# Port of `kit::touch` (`src/kit.cpp:81`).
# C++: `void touch()`
def touch():
    abort("not ported: kit::touch")


# Port of `kit::text::join` (`src/kit.cpp:85`).
# C++: `std::string join(const std::vector<std::int64_t> &xs, const std::string &sep)`
def join(xs: List[Int64], sep: String) -> String:
    abort("not ported: kit::text::join")
