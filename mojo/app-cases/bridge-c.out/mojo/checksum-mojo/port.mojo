# The Mojo port of `src/checksum.c`: `exports.mojo` exports each function under its C name.
#
# Replace each stub's `abort` with the port of the C function. C has no
# error channel: return what the C code returns. Integers wrap as C's do only where
# the port says so, so use the same widths as the C code. No pointers here: the
# exports read and write them.

from std.os import abort


# Port of `adler32` (`src/checksum.c:5`).
# C: `uint32_t adler32(const char *data)`
# `data`: the C string's bytes without its NUL; `None` for `NULL`.
def adler32(data: Optional[Span[UInt8, ImmutAnyOrigin]]) -> UInt32:
    abort("not ported: adler32")


# Port of `fnv1a` (`src/checksum.c:15`).
# C: `uint32_t fnv1a(const char *data)`
# `data`: the C string's bytes without its NUL; `None` for `NULL`.
def fnv1a(data: Optional[Span[UInt8, ImmutAnyOrigin]]) -> UInt32:
    abort("not ported: fnv1a")


# Port of `clamp` (`src/checksum.c:25`).
# C: `int clamp(int value, int low, int high)`
def clamp(value: Int32, low: Int32, high: Int32) -> Int32:
    abort("not ported: clamp")


# Port of `gcd` (`src/checksum.c:31`).
# C: `long gcd(long a, long b)`
def gcd(a: Int64, b: Int64) -> Int64:
    abort("not ported: gcd")


# Port of `mean3` (`src/checksum.c:42`).
# C: `double mean3(double a, double b, double c)`
def mean3(a: Float64, b: Float64, c: Float64) -> Float64:
    abort("not ported: mean3")
