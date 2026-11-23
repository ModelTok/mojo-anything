# A program writing raw floats (tests/float_files.rs's, with more shapes):
# `wave.py N F32 F64` writes N values of a decaying curve as f32le and f64le.
# SHIFT scales them, NAN puts NaN, infinity and -0.0 in, BIG puts a value near
# f32's limit, SHORT drops the last value.
import math
import os
import struct
import sys

n, f32, f64 = int(sys.argv[1]), sys.argv[2], sys.argv[3]
shift = float(os.environ.get("SHIFT", "0"))
xs = [math.exp(-(4.0 * i / (n - 1))) * (1 + shift) for i in range(n)]
if os.environ.get("NAN"):
    xs[3] = float("nan")
    xs[5] = float("inf")
    xs[7] = -0.0
if os.environ.get("BIG"):
    xs[2] = 3.0e38 * (1 + shift)
if os.environ.get("SHORT"):
    xs = xs[:-1]
with open(f32, "wb") as f:
    f.write(struct.pack("<%df" % len(xs), *xs))
with open(f64, "wb") as f:
    f.write(struct.pack("<%dd" % len(xs), *xs))
finite = [x for x in xs if x == x and abs(x) != float("inf")]
print("wrote", len(xs), "values summing to", sum(finite))
